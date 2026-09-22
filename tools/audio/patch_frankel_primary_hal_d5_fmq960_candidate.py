#!/usr/bin/env python3
"""Stage scoped D1/D5 playback FIFO/90 plus a 960-frame HAL minimum.

The ALSA ring remains 192x20 with a full 3840-frame autostart threshold.
Only the PCM interface's frame-count getter is changed, so Android can use
five-millisecond FMQ transactions without slowing real kernel notifications.
The input is never modified and no image is packed or flashed.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import stat

from patch_frankel_primary_hal_192k import Patch, write_atomic
from patch_frankel_primary_hal_d5_fifo90_candidate import transform as fifo_transform


PATCHES = (
    Patch("PCM minimum-frame getter -> scoped FMQ960", 0x28E308,
          bytes.fromhex("006840b9"), bytes.fromhex("a7cb0014")),
    Patch("minimum-frame getter D1/D5 device guard", 0x2C11A4, bytes(12),
          bytes.fromhex("084040b9 1f150071 aa030014")),
    Patch("minimum-frame getter direction load", 0x2C2054, bytes(12),
          bytes.fromhex("0419417a 09f04039 aa100014")),
    Patch("minimum-frame getter direction guard and original value", 0x2C6304, bytes(12),
          bytes.fromhex("2009417a 006840b9 e6000014")),
    Patch("minimum-frame getter scoped 960-frame return", 0x2C66A4, bytes(12),
          bytes.fromhex("09788052 2001801a c0035fd6")),
)


def transform(data: bytes, restore: bool = False) -> bytes:
    if data[0x2EF298:0x2EF2A0] != bytes.fromhex("f0e2280000000000"):
        raise ValueError("reviewed PCM minimum-frame getter vtable entry changed")
    if data[0x28E2F0:0x28E308] != bytes.fromhex(
            "5f2403d5 08a44339 1f050071 61000054 00a00291 ffeeff17"):
        raise ValueError("reviewed PCM alternate-interface getter path changed")
    original = all(data[p.offset:p.offset + len(p.before)] == p.before for p in PATCHES)
    patched = all(data[p.offset:p.offset + len(p.after)] == p.after for p in PATCHES)
    if original == patched:
        raise ValueError("refusing mixed or unknown FMQ candidate words")
    baseline = bytearray(data)
    if patched:
        for item in PATCHES:
            baseline[item.offset:item.offset + len(item.before)] = item.before
    baseline = bytearray(fifo_transform(bytes(baseline), restore))
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
        print(f"staged {'baseline' if args.restore else 'FIFO90/FMQ960 candidate'}: {args.output}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
