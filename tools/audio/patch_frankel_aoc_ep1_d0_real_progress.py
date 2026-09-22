#!/usr/bin/env python3
"""Give Frankel PCM0/D0 bounded, hardware-backed 192 kHz progress.

``audio_playback0`` is a pull ring.  The stock driver nevertheless selects
its mailbox-only PCM progress path.  At 192 kHz AoC can drain the complete
15,360-byte ring before one useful period notification reaches ALSA.  The
resulting position is zero modulo the four-period ALSA buffer, so the next
``WRITEI_FRAMES`` sleeps until its short device timeout and fails.

This exact-module transform makes only PCM device 0 use the driver's existing
hrtimer path, at a 1 ms observation interval.  It also bounds each D0 report
to ``min(actual_aoc_rx, last_reported_rx + period_bytes)``.  A full-ring AoC
counter jump is therefore exposed as four period-sized updates rather than an
ambiguous zero-position wrap.  The bound never advances beyond the real AoC
read counter and stops when hardware stops; it is not a synthetic clock.

Mailbox callbacks are made inert for D0 by clearing ``dev->prvdata`` before
the timer selection.  Other main PCM devices retain their stock mailbox
selection.  The patch does not alter ring availability, copy, write, or
prefill behavior and must be paired with the ``aoc_core`` zero-wp reset fix.
Apply only to the exact EP1/source-0 clean module named by ``BASE_SHA256``.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "d0278904c384a61d9d25a44236a3e4a36c087be077b2bd6f0b971ab74b2b3cf8"
PATCHED_SHA256 = "9dd7fad9c61c56d3da79fc162594d1ace8238fa02c270f68f79ad2df4ff6b871"

PATCHES = (
    # D0-only timer selection.  cstream is already NULL after kzalloc, so x22
    # can retain chip->opened while the initialization sequence is rearranged.
    (0x1A46C, bytes.fromhex("1f0800f9"), bytes.fromhex("360b43f9"),
     "preload chip->opened in x22"),
    (0x1A5C8, bytes.fromhex("2a0b43f9"), bytes.fromhex("c80208aa"),
     "update chip->opened from saved x22"),
    (0x1A5CC, bytes.fromhex("480108aa"), bytes.fromhex("895e01b9"),
     "move initial draining store"),
    (0x1A5DC, bytes.fromhex("895e01b9"), bytes.fromhex("1ff901f9"),
     "clear service IRQ private data"),
    (0x1A5E0, bytes.fromhex("08015039"), bytes.fromhex("f5000034"),
     "select timer for D0"),
    (0x1A5E4, bytes.fromhex("1f110071"), bytes.fromhex("0a015039"),
     "load mailbox index into w10"),
    (0x1A5E8, bytes.fromhex("a1000054"), bytes.fromhex("5f110071"),
     "retain stock non-D0 mailbox comparison"),
    (0x1A5EC, bytes.fromhex("e80340f9"), bytes.fromhex("81000054"),
     "route non-mailbox services to timer"),
    # Shared fallback interval: 10,000,000 ns -> 1,000,000 ns.  D0 is the
    # newly selected fallback; pre-existing non-mailbox PCMs also observe at
    # 1 ms, but their progress remains their real AoC counter.
    (0x1A5FC, bytes.fromhex("08d09252"), bytes.fromhex("08488852"),
     "1 ms timer low immediate"),
    (0x1A608, bytes.fromhex("0813a072"), bytes.fromhex("e801a072"),
     "1 ms timer high immediate"),
    # D0 counter clamp in two LSE-selected, unreachable LL/SC alternative
    # tails, followed by the single direct branch from aoc_pcm_irq_process().
    (0xD680,
     bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5caffff17"),
     bytes.fromhex("68f240b968000034e10315aaaf32001462a640f904000014"),
     "D0 selector and previous-counter reload cave"),
    (0xD6A4,
     bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5cfffff17"),
     bytes.fromhex("692241b94a40298bbf020aeb5581959ae10315aaa4320014"),
     "min(actual, previous plus period) cave"),
    (0x1A144, bytes.fromhex("e10315aa"), bytes.fromhex("4fcdff17"),
     "redirect real consumed-counter path through D0 clamp"),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def site_state(data: bytes | bytearray) -> str:
    actual = tuple(bytes(data[o:o + len(a)]) for o, a, _b, _d in PATCHES)
    stock = tuple(a for _o, a, _b, _d in PATCHES)
    patched = tuple(b for _o, _a, b, _d in PATCHES)
    if actual == stock:
        return "stock"
    if actual == patched:
        return "d0-real-progress"
    raise ValueError(f"mixed or unknown sites: {[value.hex() for value in actual]}")


def classify(data: bytes | bytearray) -> str:
    state = site_state(data)
    expected = BASE_SHA256 if state == "stock" else PATCHED_SHA256
    observed = digest(data)
    if expected != "TO_BE_FILLED" and observed != expected:
        raise ValueError(f"unexpected {state} whole-file SHA-256: {observed}")
    return state


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    for offset, stock, patched, description in PATCHES:
        before, after = ((stock, patched) if wanted == "d0-real-progress"
                         else (patched, stock))
        if bytes(data[offset:offset + len(before)]) != before:
            raise ValueError(f"guard mismatch at 0x{offset:x}: {description}")
        data[offset:offset + len(before)] = after
        print(f"patched 0x{offset:x}: {description}")
    if site_state(data) != wanted:
        raise AssertionError("post-patch site classification failed")


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"refusing unsafe output: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(mode))
        os.replace(temporary, path)
    except BaseException:
        pathlib.Path(temporary).unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "d0-real-progress"))
    parser.add_argument("--set-state", choices=("stock", "d0-real-progress"),
                        default="d0-real-progress")
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
        parser.error("OUTPUT is required when patching")
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
