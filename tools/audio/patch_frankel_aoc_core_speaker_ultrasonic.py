#!/usr/bin/env python3
"""Enable Frankel's firmware-native speaker-ultrasonic boot-data flag.

The matching Google AoC core driver exposes this as ioctl 0x4004acd1, but the
value is only copied into firmware boot data during an AoC cold boot.  Force
the same reviewed value in the stock module so every device boot supplies
`kAOCForceSpeakerUltrasonic` (0x1010) as one.  This avoids an unreliable
in-system GSA reload and leaves the signed AoC firmware itself untouched.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


STOCK_SHA256 = "23acc08d0539657e72a0bc506abf6cef9950b90b192c51fd0dd9bf2177e4f2ad"
PATCHED_SHA256 = "7bac5a28c07aaf93e30b8b1916a771047fd6c49798a2ee0656887a38b1e4f0b9"
OFFSET = 0x3350
STOCK = bytes.fromhex("68aa43b9")  # ldr w8, [x19, #0x3a8]
PATCHED = bytes.fromhex("28008052")  # mov w8, #1


def classify(data: bytes) -> str:
    actual = data[OFFSET : OFFSET + len(STOCK)]
    if actual == STOCK:
        state = "stock"
        expected = STOCK_SHA256
    elif actual == PATCHED:
        state = "patched"
        expected = PATCHED_SHA256
    else:
        raise ValueError(
            f"unexpected bytes at 0x{OFFSET:x}: {actual.hex()} "
            f"(expected {STOCK.hex()} or {PATCHED.hex()})"
        )
    observed = hashlib.sha256(data).hexdigest()
    if observed != expected:
        raise ValueError(
            f"{state} module hash mismatch: {observed}; expected {expected}"
        )
    return state


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, stat.S_IMODE(mode))
        os.replace(name, path)
    except BaseException:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--in-place", action="store_true")
    parser.add_argument("--check", choices=("stock", "patched"))
    parser.add_argument("--set-state", choices=("stock", "patched"), default="patched")
    args = parser.parse_args()

    data = args.input.read_bytes()
    state = classify(data)
    if args.check:
        if state != args.check:
            raise ValueError(f"module is {state}, expected {args.check}")
        print(f"verified {args.input} is {state}")
        return 0

    output = args.input if args.in_place else args.output
    if output is None:
        parser.error("OUTPUT is required unless --in-place is used")
    wanted = args.set_state
    if state != wanted:
        changed = bytearray(data)
        changed[OFFSET : OFFSET + len(STOCK)] = PATCHED if wanted == "patched" else STOCK
        data = bytes(changed)
        classified = classify(data)
        if classified != wanted:
            raise AssertionError(classified)
    atomic_write(output, data, args.input.stat().st_mode)
    print(f"wrote {wanted} {output} ({hashlib.sha256(data).hexdigest()})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)
