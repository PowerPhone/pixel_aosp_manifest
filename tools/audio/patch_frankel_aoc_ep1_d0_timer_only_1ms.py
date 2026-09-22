#!/usr/bin/env python3
"""Give Frankel PCM0/EP1 timer-only 1 ms host progress.

The stock ``audio_playback0`` service advertises the main-PCM mailbox, but
Frankel's 192 kHz source-0 trial does not receive usable period progress from
that mailbox.  AoC consumes the first 15360-byte ring and ALSA's next write
then fails after its 200 ms wait.

This exact-module transform makes only entry point D0 select the driver's
existing hrtimer progress path.  It explicitly clears ``dev->prvdata`` before
the selection: the AoC core may still install the PCM mailbox handler, but it
therefore becomes inert for D0 and cannot race the timer's lockless
``prev_consumed``/position updates (or dereference stale data after reopen).
For every non-D0 main PCM the original mailbox selection is preserved.

The shared fallback interval is changed from 10 ms to 1 ms.  A 480-frame
period lasts 2.5 ms at 192 kHz, while the complete four-period D0 ring lasts
only 10 ms, so the stock interval cannot report reliable sub-ring progress.
Consequently non-mailbox main-PCMs also poll at 1 ms in this experimental
module; that is the one intentional non-D0 effect.

The selector fits in place by retaining ``chip->opened`` in x22 across the
function, moving the initial ``draining = 1`` store four bytes earlier, and
using x10 for the mailbox byte so x8 remains the service pointer.  No code
cave or relocation is used.  Do not apply it to anything except the exact
Frankel EP1/source-0/ring-prefill candidate named by ``BASE_SHA256``.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "99bde9252fff1ade24b49e66a9f0938d6e70e2d0c41768f73be582bdb0483105"
PATCHED_SHA256 = "e24c6c20dddc055108bcd1ce841106d21e7251eff0f5eb8bd349d7a315f43cbb"

PATCHES = (
    # cstream is already NULL after kzalloc; keep chip->opened in x22.
    (0x1A46C, bytes.fromhex("1f0800f9"), bytes.fromhex("360b43f9"),
     "preload chip->opened in x22"),
    (0x1A5C8, bytes.fromhex("2a0b43f9"), bytes.fromhex("c80208aa"),
     "update chip->opened from saved x22"),
    # Preserve the stock initial draining=1 store in the reclaimed slot.
    (0x1A5CC, bytes.fromhex("480108aa"), bytes.fromhex("895e01b9"),
     "move initial draining store"),
    # Clear stale IRQ private data for every service before reselecting it.
    (0x1A5DC, bytes.fromhex("895e01b9"), bytes.fromhex("1ff901f9"),
     "clear service IRQ private data"),
    # D0 takes the timer path.  Non-D0 retains the stock mailbox test.  Load
    # the mailbox byte into w10 so x8 remains usable as the service pointer.
    (0x1A5E0, bytes.fromhex("08015039"), bytes.fromhex("f5000034"),
     "select timer for D0"),
    (0x1A5E4, bytes.fromhex("1f110071"), bytes.fromhex("0a015039"),
     "load mailbox index without clobbering service pointer"),
    (0x1A5E8, bytes.fromhex("a1000054"), bytes.fromhex("5f110071"),
     "compare non-D0 mailbox index"),
    (0x1A5EC, bytes.fromhex("e80340f9"), bytes.fromhex("81000054"),
     "send non-mailbox services to timer"),
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
        return "d0-timer-only-1ms"
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
            (stock, patched) if wanted == "d0-timer-only-1ms" else (patched, stock)
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
    parser.add_argument("--check", choices=("interrupt", "d0-timer-only-1ms"))
    parser.add_argument(
        "--set-state",
        choices=("interrupt", "d0-timer-only-1ms"),
        default="d0-timer-only-1ms",
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
