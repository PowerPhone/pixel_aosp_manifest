#!/usr/bin/env python3
"""Select the exact 10 ms or 1 ms AoC PCM host-poll state for Frankel.

The ultrasonic AoC service does not use the PCM mailbox.  Google's host ALSA
driver therefore polls its RingBufferHost producer counter with an hrtimer.
The stock 10 ms poll interval is equal to the experimental native-192 period,
which leaves no scheduling margin before the small AoC output ring fills.

This research-only transform changes only the two AArch64 immediates that
materialize ``timer_interval_ns`` in ``snd_aoc_pcm_open()``.  It accepts only
the exact already-192-kHz Frankel module used by CP2A.260805.005, or the exact
result of this transform, and writes atomically.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import struct
import sys
import tempfile


BASE_SHA256 = "e2ed0cad956634993290a807c9bcbd3d77352b2d31a16c3d8697de12f620671d"
FAST_SHA256 = "7f835a60ac15dec171710b5c54730cd8f2accacbb8dbab846fd7bb4b81c06dfb"

# Section-relative instruction offsets in snd_aoc_pcm_open().
LOW_OFFSET = 0x106BC
HIGH_OFFSET = 0x106C8
STOCK_LOW = bytes.fromhex("08d09252")  # mov  w8, #0x9680
STOCK_HIGH = bytes.fromhex("0813a072")  # movk w8, #0x98, lsl #16
FAST_LOW = bytes.fromhex("08488852")  # mov  w8, #0x4240
FAST_HIGH = bytes.fromhex("e801a072")  # movk w8, #0x000f, lsl #16

# Guard the surrounding control flow as well as the whole-file digest.
CONTEXT_OFFSET = 0x106AC
STOCK_CONTEXT = bytes.fromhex(
    "e80340f914f901f9280080520c000014"
    "08d0925280420291210080520813a072"
    "22008052886e00f9"
)
FAST_CONTEXT = bytes.fromhex(
    "e80340f914f901f9280080520c000014"
    "084888528042029121008052e801a072"
    "22008052886e00f9"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "fast"))
    parser.add_argument("--set-state", choices=("stock", "fast"), default="fast")
    parser.add_argument("--in-place", action="store_true")
    return parser.parse_args()


def elf_text(data: bytes) -> tuple[int, int]:
    if data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("input is not a little-endian ELF64 file")
    section_offset = struct.unpack_from("<Q", data, 0x28)[0]
    entry_size, count, names_index = struct.unpack_from("<HHH", data, 0x3A)
    if entry_size != 64 or not count or names_index >= count:
        raise ValueError("unexpected ELF section-header layout")
    headers = [
        struct.unpack_from("<IIQQQQIIQQ", data, section_offset + i * entry_size)
        for i in range(count)
    ]
    names_header = headers[names_index]
    names = data[names_header[4] : names_header[4] + names_header[5]]
    if len(names) != names_header[5]:
        raise ValueError("truncated ELF section-name table")
    for header in headers:
        start = header[0]
        end = names.find(b"\0", start)
        if end >= 0 and names[start:end] == b".text":
            return header[4], header[5]
    raise ValueError("missing .text section")


def classify(data: bytes) -> str:
    text_offset, text_size = elf_text(data)
    if CONTEXT_OFFSET + len(STOCK_CONTEXT) > text_size:
        raise ValueError(".text is too small for guarded timer instructions")
    context = data[
        text_offset + CONTEXT_OFFSET : text_offset + CONTEXT_OFFSET + len(STOCK_CONTEXT)
    ]
    digest = hashlib.sha256(data).hexdigest()
    if context == STOCK_CONTEXT and digest == BASE_SHA256:
        return "stock"
    if context == FAST_CONTEXT and digest == FAST_SHA256:
        return "fast"
    raise ValueError(
        "input is neither the exact 10 ms base nor exact 1 ms transformed module "
        f"(sha256={digest}, context={context.hex()})"
    )


def transform(data: bytearray, target: str) -> None:
    current = classify(data)
    if current == target:
        return
    text_offset, _ = elf_text(data)
    replacements = (
        (LOW_OFFSET, STOCK_LOW, FAST_LOW),
        (HIGH_OFFSET, STOCK_HIGH, FAST_HIGH),
    )
    for offset, stock, fast in replacements:
        before = stock if current == "stock" else fast
        after = fast if target == "fast" else stock
        absolute = text_offset + offset
        if data[absolute : absolute + 4] != before:
            raise ValueError(f"timer instruction changed at .text+0x{offset:x}")
        data[absolute : absolute + 4] = after
    if classify(data) != target:
        raise AssertionError("transformed module failed exact self-validation")


def write_atomic(path: pathlib.Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"refusing unsafe output path: {path}")
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, stat.S_IMODE(mode))
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            pathlib.Path(temporary_name).unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError(f"unsafe input: {args.input}")
    if args.in_place and args.output is not None:
        raise ValueError("OUTPUT and --in-place are mutually exclusive")
    if args.check and (args.output is not None or args.in_place):
        raise ValueError("--check cannot be combined with a write destination")
    if not args.check and not args.in_place and args.output is None:
        raise ValueError("apply mode requires OUTPUT or --in-place")

    data = bytearray(args.input.read_bytes())
    current = classify(data)
    if args.check:
        if current != args.check:
            raise ValueError(f"expected {args.check}, found {current}")
        print(f"verified {current}: {args.input}")
        return 0

    transform(data, args.set_state)
    destination = args.input if args.in_place else args.output
    assert destination is not None
    write_atomic(destination, data, args.input.stat().st_mode)
    print(f"selected {args.set_state} AoC host timer: {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
