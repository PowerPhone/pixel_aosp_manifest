#!/usr/bin/env python3
"""Give Frankel PCM0/EP1 hybrid mailbox plus 1 ms host progress.

Frankel's ``audio_playback0`` service advertises the main-PCM interrupt
mailbox, but its 192 kHz trial does not deliver a usable second period
notification.  A buffer-sized second ``WRITEI_FRAMES`` consequently expires
at the driver's 200 ms wait timeout with ``-EIO`` even though AoC consumed the
first buffer and the physical TDM sink remains healthy.

This guarded, reversible transform enables the driver's existing hrtimer
fallback only when ``entry_point_idx == 0``.  It deliberately also installs
``dev->prvdata`` for D0, leaving the already-registered mailbox handler live:
the timer guarantees progress while any valid mailbox notification remains
useful, and the shared ``prev_consumed`` check suppresses duplicates.  Every
other main PCM retains the stock mailbox decision.  The fallback interval is
reduced from 10 ms to 1 ms: a 480-frame period is only 2.5 ms at 192 kHz, so
the stock interval would itself allow a full four-period buffer to underrun
before the first host progress update.

The selector reclaims an explicit ``cstream = NULL`` store that is redundant
after ``kzalloc``.  It preserves the ``chip->opened`` update, hoists the
interrupt ``prvdata`` store into the common path, and reclaims the initial
``draining = 1`` store (``kzalloc`` initializes it and START sets it before it
is observed).  It adds no relocation or code cave.  Do not apply this
transform to any module other than the exact Frankel EP1/source-0/ring-prefill
candidate.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "99bde9252fff1ade24b49e66a9f0938d6e70e2d0c41768f73be582bdb0483105"
PATCHED_SHA256 = "a25094fcb9f1d01a883f2c9830b31a85ed161062de34f0de54f5bc15037e0c31"

PATCHES = (
    # cstream is already zero after kzalloc.  Use x22 to retain chip->opened
    # while rearranging the later initialization sequence.
    (0x1A46C, bytes.fromhex("1f0800f9"), bytes.fromhex("360b43f9"),
     "preload chip->opened in x22"),
    (0x1A5C8, bytes.fromhex("2a0b43f9"), bytes.fromhex("c80208aa"),
     "update chip->opened from saved x22"),
    (0x1A5CC, bytes.fromhex("480108aa"), bytes.fromhex("bf020071"),
     "compare entry-point index with D0"),
    # cmp idx,#0; ccmp mbox,#4,#0,ne; b.ne timer.  For D0 the ccmp
    # condition is false and supplied Z=0 selects the timer.  Other devices
    # execute the original mbox==4 interrupt test.
    (0x1A5DC, bytes.fromhex("895e01b9"), bytes.fromhex("14f901f9"),
     "install dev->prvdata for hybrid progress"),
    (0x1A5E4, bytes.fromhex("1f110071"), bytes.fromhex("0019447a"),
     "conditionally retain mailbox interrupt test"),
    # timer_interval_ns: 10,000,000 -> 1,000,000.
    (0x1A5FC, bytes.fromhex("08d09252"), bytes.fromhex("08488852"),
     "1 ms timer low immediate"),
    (0x1A608, bytes.fromhex("0813a072"), bytes.fromhex("e801a072"),
     "1 ms timer high immediate"),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    observed = tuple(
        bytes(data[offset : offset + len(stock)])
        for offset, stock, _patched, _description in PATCHES
    )
    stock = tuple(stock for _offset, stock, _patched, _description in PATCHES)
    patched = tuple(patched for _offset, _stock, patched, _description in PATCHES)
    observed_digest = digest(data)
    if observed == stock and observed_digest == BASE_SHA256:
        return "interrupt"
    if observed == patched and observed_digest == PATCHED_SHA256:
        return "d0-hybrid-1ms"
    raise ValueError(
        "unexpected or partially patched module: "
        f"sha256={observed_digest}, guarded={[part.hex() for part in observed]}"
    )


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    for offset, stock, patched, description in PATCHES:
        source, destination = (
            (stock, patched) if wanted == "d0-hybrid-1ms" else (patched, stock)
        )
        actual = bytes(data[offset : offset + len(source)])
        if actual != source:
            raise ValueError(
                f"guard mismatch for {description} at 0x{offset:x}: "
                f"got {actual.hex()}, expected {source.hex()}"
            )
        data[offset : offset + len(source)] = destination
        print(f"patched 0x{offset:x}: {description}")
    if classify(data) != wanted:
        raise AssertionError("post-patch classification failed")


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"refusing unsafe output path: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(mode))
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("interrupt", "d0-hybrid-1ms"))
    parser.add_argument(
        "--set-state",
        choices=("interrupt", "d0-hybrid-1ms"),
        default="d0-hybrid-1ms",
    )
    args = parser.parse_args()

    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError(f"unsafe input: {args.input}")
    data = bytearray(args.input.read_bytes())
    current = classify(data)
    if args.check:
        if args.output is not None:
            parser.error("OUTPUT is incompatible with --check")
        if current != args.check:
            raise ValueError(f"module is {current}, expected {args.check}")
        print(f"verified {args.input} is {current}")
        return 0
    if args.output is None:
        parser.error("OUTPUT is required when applying a patch")

    transform(data, args.set_state)
    atomic_write(args.output, bytes(data), args.input.stat().st_mode)
    print(f"wrote {args.set_state} {args.output} ({digest(data)})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)
