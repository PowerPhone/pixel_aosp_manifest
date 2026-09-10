#!/usr/bin/env python3
"""Make AoC ring write-pointer alignment a no-op when wp is already zero.

Frankel's stock ``aoc_ring_reset_write_pointer()`` calculates ``size - wp``
and tests that result before advancing Tx.  Consequently ``wp == 0`` advances
one complete ring, manufacturing a full ring before any PCM has been copied.
Test the already-loaded ``wp`` value instead.  Non-zero pointers still advance
by the stock ``size - wp`` amount; every other instruction is unchanged.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


OFFSET = 0xA190
STOCK = bytes.fromhex("ff060071")  # cmp w23, #1 (w23 = size - wp)
PATCHED = bytes.fromhex("1f040071")  # cmp w0, #1 (w0 = wp)
STOCK_SHA256 = "23acc08d0539657e72a0bc506abf6cef9950b90b192c51fd0dd9bf2177e4f2ad"
PATCHED_SHA256 = "f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c"


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    site = bytes(data[OFFSET : OFFSET + 4])
    if site == STOCK:
        state, expected = "stock", STOCK_SHA256
    elif site == PATCHED:
        state, expected = "patched", PATCHED_SHA256
    else:
        raise ValueError(
            f"unexpected bytes at 0x{OFFSET:x}: {site.hex()} "
            f"(expected {STOCK.hex()} or {PATCHED.hex()})"
        )
    observed = digest(data)
    if observed != expected:
        raise ValueError(
            f"unexpected {state} whole-file SHA-256: {observed}; expected {expected}"
        )
    return state


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
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
    parser.add_argument("--check", choices=("stock", "patched"))
    parser.add_argument("--set-state", choices=("stock", "patched"), default="patched")
    args = parser.parse_args()

    data = bytearray(args.input.read_bytes())
    state = classify(data)
    if args.check:
        if state != args.check:
            raise ValueError(f"module is {state}, expected {args.check}")
        print(f"verified {args.input} is {state}")
        return 0
    if args.output is None:
        parser.error("OUTPUT is required when applying a patch")

    if state != args.set_state:
        before, after = (
            (STOCK, PATCHED)
            if args.set_state == "patched"
            else (PATCHED, STOCK)
        )
        if bytes(data[OFFSET : OFFSET + 4]) != before:
            raise ValueError(f"guard mismatch at 0x{OFFSET:x}")
        data[OFFSET : OFFSET + 4] = after
    if classify(data) != args.set_state:
        raise AssertionError("post-patch classification failed")
    atomic_write(args.output, bytes(data), args.input.stat().st_mode)
    print(f"wrote {args.set_state} {args.output} ({digest(data)})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)
