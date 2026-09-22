#!/usr/bin/env python3
"""Redirect Frankel GSA AoC unload to legacy raw mailbox command 92.

Only the first two instructions of the exact reviewed ``gsa.ko`` export are
changed.  The replacement tail-calls its existing ``gsa_send_simple_cmd``;
the remainder of the original Trusty HWMGR unload function is unreachable but
left intact, including all relocations.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import shutil
import struct
import sys


EXPECTED_SIZE = 82688
EXPECTED_STOCK_SHA256 = "ae9ea9662c1eb7e30832235aef54c385b40521291a896fac4eb89c73945922e4"
TEXT_FILE_OFFSET = 0x2000
TEXT_FUNCTION_OFFSET = 0x0AC8
FILE_OFFSET = TEXT_FILE_OFFSET + TEXT_FUNCTION_OFFSET
STOCK = bytes.fromhex("3f2303d5 ffc300d1")  # paciasp; sub sp,sp,#0x30
PATCHED = bytes.fromhex("810b8052 b9ffff17")  # mov w1,#92; b 0x9b0


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def state(data: bytes | bytearray) -> str:
    if len(data) != EXPECTED_SIZE or data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("input is not the exact guarded gsa.ko layout")
    site = bytes(data[FILE_OFFSET:FILE_OFFSET + len(STOCK)])
    if site == STOCK:
        if digest(data) != EXPECTED_STOCK_SHA256:
            raise ValueError("stock-looking gsa.ko has unexpected whole-file digest")
        return "stock"
    if site == PATCHED:
        restored = bytearray(data)
        restored[FILE_OFFSET:FILE_OFFSET + len(STOCK)] = STOCK
        if digest(restored) != EXPECTED_STOCK_SHA256:
            raise ValueError("patched-looking gsa.ko fails guarded reconstruction")
        return "patched"
    raise ValueError(f"unexpected bytes at gsa.ko file offset {FILE_OFFSET:#x}: {site.hex()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "patched"))
    args = parser.parse_args()
    if bool(args.check) == bool(args.output):
        raise ValueError("provide exactly one of OUTPUT or --check")
    data = bytearray(args.input.read_bytes())
    observed = state(data)
    if args.check:
        if observed != args.check:
            raise ValueError(f"expected {args.check}, found {observed}")
        print(f"verified {observed}: {args.input} sha256={digest(data)}")
        return 0
    assert args.output is not None
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if observed == "stock":
        data[FILE_OFFSET:FILE_OFFSET + len(STOCK)] = PATCHED
    if state(data) != "patched":
        raise AssertionError("post-patch validation failed")
    args.output.write_bytes(data)
    shutil.copymode(args.input, args.output)
    print(f"patched legacy raw GSA unload: {args.output} sha256={digest(data)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
