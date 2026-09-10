#!/usr/bin/env python3
"""Skip the phantom full-ring alignment only for Frankel PCM0/D0 playback.

``aoc_ring_reset_write_pointer()`` advances ``size - wp`` bytes.  At the
normal aligned state (``wp == 0``), that advances a complete 15,360-byte D0
ring before any user samples have been copied.  The endpoint-0 selector below
skips that call only for aligned D0 playback.  Misaligned D0 rings, every
other playback endpoint, and the stock capture path retain the reset call.
Ring writes, mailbox IRQs, and ALSA pointer accounting are otherwise
untouched.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


STOCK_SHA256 = "d0278904c384a61d9d25a44236a3e4a36c087be077b2bd6f0b971ab74b2b3cf8"
PATCHED_SHA256 = "da9024019f5afb75a77715719f9ed544f965b53c96f0acb0cd775109bad93cd2"

PATCHES = (
    (
        0xD680,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35"),
        bytes.fromhex("88a2063589f240b9c9a1063506000014"),
        "D0-only reset selector in unreachable arm64 LL/SC tail",
    ),
    (
        0xD6A4,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35"),
        bytes.fromhex("a9ee41f9295540b929a1063404350014"),
        "D0 Down-ring wp==0 test in unreachable arm64 LL/SC tail",
    ),
    (
        0x1AABC,
        bytes.fromhex("a8000035"),
        bytes.fromhex("f1caff17"),
        "route playback reset decision through D0 selector",
    ),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def site_state(data: bytes | bytearray) -> str:
    actual = tuple(bytes(data[o : o + len(a)]) for o, a, _, _ in PATCHES)
    stock = tuple(a for _, a, _, _ in PATCHES)
    patched = tuple(b for _, _, b, _ in PATCHES)
    if actual == stock:
        return "stock"
    if actual == patched:
        return "patched"
    raise ValueError(f"mixed or unknown patch sites: {[value.hex() for value in actual]}")


def classify(data: bytes | bytearray) -> str:
    state = site_state(data)
    expected = STOCK_SHA256 if state == "stock" else PATCHED_SHA256
    actual = digest(data)
    if expected != "TO_BE_FILLED" and actual != expected:
        raise ValueError(f"unexpected {state} whole-file SHA-256: {actual}")
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
        for offset, stock, patched, description in PATCHES:
            before, after = (
                (stock, patched) if args.set_state == "patched" else (patched, stock)
            )
            if bytes(data[offset : offset + len(before)]) != before:
                raise ValueError(f"guard mismatch for {description} at 0x{offset:x}")
            data[offset : offset + len(before)] = after
            print(f"patched 0x{offset:x}: {description}")
    if site_state(data) != args.set_state:
        raise AssertionError("post-patch site classification failed")
    atomic_write(args.output, bytes(data), args.input.stat().st_mode)
    print(f"wrote {args.set_state} {args.output} ({digest(data)})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)
