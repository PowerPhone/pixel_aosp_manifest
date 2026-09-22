#!/usr/bin/env python3
"""Apply guarded, length-preserving Frankel AoC non-GSA boot selectors.

Frankel's exact AoC kernel module selects secure GSA boot when either the
``gsa-enabled`` device-tree property exists or the ``aoc_enable_gsa_boot``
module parameter is true.  Both selectors must be disabled to exercise the
module's built-in direct reset/IOMMU firmware-loading path.

The patch is intentionally limited to equal-length byte substitutions so the
vendor boot header and concatenated DTB layout remain unchanged.  AVB footers
must still be regenerated after patching an image payload.
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import sys


PATCHES = {
    "vendor-boot": (
        b"aoc_core.aoc_enable_gsa_boot=1",
        b"aoc_core.aoc_enable_gsa_boot=0",
        1,
    ),
    "dtb": (b"gsa-enabled\x00", b"xsa-enabled\x00", 2),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Patch or verify Frankel's two AoC secure-boot selectors."
    )
    parser.add_argument("kind", choices=PATCHES)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument(
        "--check",
        choices=("stock", "patched"),
        help="verify the selected state without writing",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.check and args.output is not None:
        raise ValueError("--check cannot be combined with OUTPUT")
    if not args.check and args.output is None:
        raise ValueError("apply mode requires OUTPUT")

    before, after, expected_count = PATCHES[args.kind]
    if len(before) != len(after):
        raise AssertionError("non-GSA patches must preserve payload length")

    data = args.input.read_bytes()
    stock_count = data.count(before)
    patched_count = data.count(after)
    if stock_count == expected_count and patched_count == 0:
        state = "stock"
    elif stock_count == 0 and patched_count == expected_count:
        state = "patched"
    else:
        raise ValueError(
            f"unexpected {args.kind} selector counts: stock={stock_count}, "
            f"patched={patched_count}, expected={expected_count}"
        )

    if args.check:
        if state != args.check:
            raise ValueError(f"expected {args.check}, found {state}")
        print(f"verified {state}: {args.input}")
        return 0

    assert args.output is not None
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if state == "patched":
        shutil.copy2(args.input, args.output)
        print(f"already patched: {args.output}")
        return 0

    args.output.write_bytes(data.replace(before, after))
    shutil.copymode(args.input, args.output)
    print(f"patched {args.kind}: {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
