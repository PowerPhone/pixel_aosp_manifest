#!/usr/bin/env python3
"""Stage a guarded FIFO/90 continuation of Frankel's D1/D5 prefill gate.

This experimental overlay accepts the complete primary 192k/192x20/prefill
profile. It never promotes other PCM paths or changes capture and never
modifies its input. Hardware qualification, not this transformation, decides
whether it belongs in the final profile. No hashes are computed.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import stat

from patch_frankel_primary_hal_192k import Patch, classify, write_atomic


PATCHES = (
    Patch("prefill success -> own-thread FIFO/90 setup", 0x2C1A68,
          bytes.fromhex("00008052 b0010014"),
          bytes.fromhex("00008052 ce2cff17")),
    Patch("FIFO priority in Start frame unused slot", 0x28CDA4, bytes(12),
          bytes.fromhex("480b8052 e81b00b9 46000014")),
    Patch("FIFO and RESET_ON_FORK policy", 0x28CEC4, bytes(12),
          bytes.fromhex("21008052 0100a872 46ffff17")),
    Patch("tail-call existing sched_setscheduler import", 0x28CBE4, bytes(12),
          bytes.fromhex("e2630091 0e5f0114 00000000")),
)

# The trampoline uses the Start frame's spare sp+0x18 word. Guard its exact
# allocation and saved-register placement as well as the original PLT import.
CONTEXT = (
    (0x28CDB0, bytes.fromhex(
        "3f2303d5 fd7bbca9 f70b00f9 f65702a9 f44f03a9 fd030091")),
    (0x2E4820, bytes.fromhex("90000090 111e46f9 10e23091 20021fd6")),
)


def transform(data: bytes, restore: bool = False) -> bytes:
    for offset, expected in CONTEXT:
        if data[offset:offset + len(expected)] != expected:
            raise ValueError(f"reviewed caller/import context changed at {offset:#x}")
    original = all(data[p.offset:p.offset + len(p.before)] == p.before for p in PATCHES)
    patched = all(data[p.offset:p.offset + len(p.after)] == p.after for p in PATCHES)
    if original == patched:
        raise ValueError("refusing mixed or unknown FIFO candidate words")
    baseline = bytearray(data)
    if patched:
        for item in PATCHES:
            baseline[item.offset:item.offset + len(item.before)] = item.before
    if classify(bytes(baseline)) not in ("patched", "period1-prefill-start"):
        raise ValueError("requires the complete primary 192k/192x20/prefill profile")
    if not restore:
        for item in PATCHES:
            baseline[item.offset:item.offset + len(item.after)] = item.after
    return bytes(baseline)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    try:
        if not args.input.is_file() or args.input.is_symlink():
            raise ValueError("input must be a regular non-symlink file")
        if args.output.exists() or args.output.is_symlink():
            raise ValueError("output already exists; choose a fresh candidate path")
        if args.input.resolve() == args.output.resolve():
            raise ValueError("candidate output must differ from the baseline")
        result = transform(args.input.read_bytes(), args.restore)
        write_atomic(args.output, result, stat.S_IMODE(args.input.stat().st_mode))
        print(f"staged {'baseline' if args.restore else 'FIFO/90 candidate'}: {args.output}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
