#!/usr/bin/env python3
"""Select immediate framework idle standby for the Frankel research image.

This changes one property, not AudioFlinger code. It removes the normal
three-second hold after completed playback; it does not arbitrate concurrent
primary/BUS clients. Only the reviewed absent/zero property states are accepted.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import stat

from patch_frankel_primary_hal_192k import write_atomic


KEY = "ro.audio.flinger_standbytime_ms"
SELECTED = f"{KEY}=0\n"
ANCHOR = "ro.audio.monitorRotation=true\n"


def transform(text: str, state: str) -> tuple[str, str]:
    lines = text.splitlines(keepends=True)
    if lines.count(ANCHOR) != 1:
        raise ValueError("reviewed Frankel audio-property anchor is missing or duplicated")
    matching = [line for line in lines
                if line.split("=", 1)[0].strip().removesuffix("?").rstrip() == KEY]
    if len(matching) > 1 or (matching and matching[0] != SELECTED):
        raise ValueError("refusing duplicate, malformed, or unknown standby property")
    before = "research" if matching else "stock"
    if state == "research" and not matching:
        lines.insert(lines.index(ANCHOR), SELECTED)
    elif state == "stock" and matching:
        lines.remove(SELECTED)
    return before, "".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--state", choices=("stock", "research"), default="research")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--in-place", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        if not args.input.is_file() or args.input.is_symlink():
            raise ValueError("input must be a regular non-symlink file")
        if args.check and args.output is not None:
            raise ValueError("--check does not accept an output")
        if not args.check and args.in_place == (args.output is not None):
            raise ValueError("choose exactly one of OUTPUT or --in-place")
        before, result = transform(args.input.read_bytes().decode("utf-8"), args.state)
        if args.check:
            if before != args.state:
                raise ValueError(f"standby property is {before}, expected {args.state}")
            print(f"standby property is {before}: {args.input}")
            return 0
        destination = args.input if args.in_place else args.output
        if before != args.state or destination != args.input:
            write_atomic(destination, result.encode(), stat.S_IMODE(args.input.stat().st_mode))
        print(f"selected {args.state} standby property (was {before}): {destination}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
