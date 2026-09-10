#!/usr/bin/env python3
"""Enable 192 kHz on Frankel's EP1/source-0 playback frontend.

The input is the exact pre-SOURCE2, live-qualified Frankel AoC ALSA module.
Its generic PCM runtime and TDM_0_RX backend already admit 192 kHz, but the
EP1 playback DAI retains its stock 8--48 kHz mask.  This guarded transform
changes only that one per-DAI mask and is reversible.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


STOCK_SHA256 = "f7c7f9dcdf1efde705be45fc0beeb29a2c958e2db774fd4692e53ae41134dba8"
PATCHED_SHA256 = "d0278904c384a61d9d25a44236a3e4a36c087be077b2bd6f0b971ab74b2b3cf8"
PATCH_OFFSET = 0x3F368
STOCK_MASK = bytes.fromhex("fe000000")
PATCHED_MASK = bytes.fromhex("fe1f0000")


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    observed_mask = bytes(data[PATCH_OFFSET : PATCH_OFFSET + len(STOCK_MASK)])
    observed_digest = digest(data)
    if observed_mask == STOCK_MASK and observed_digest == STOCK_SHA256:
        return "stock"
    if observed_mask == PATCHED_MASK and observed_digest == PATCHED_SHA256:
        return "patched"
    raise ValueError(
        "unexpected or partially patched module: "
        f"sha256={observed_digest}, mask@0x{PATCH_OFFSET:x}={observed_mask.hex()}"
    )


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

    wanted = args.set_state
    if state != wanted:
        source, destination = (
            (STOCK_MASK, PATCHED_MASK)
            if wanted == "patched"
            else (PATCHED_MASK, STOCK_MASK)
        )
        actual = bytes(data[PATCH_OFFSET : PATCH_OFFSET + len(source)])
        if actual != source:
            raise ValueError(f"guard mismatch at 0x{PATCH_OFFSET:x}")
        data[PATCH_OFFSET : PATCH_OFFSET + len(source)] = destination
        print(
            f"patched EP1 playback rate mask at 0x{PATCH_OFFSET:x}: "
            f"{source.hex()} -> {destination.hex()}"
        )

    if classify(data) != wanted:
        raise AssertionError("post-patch classification failed")
    atomic_write(args.output, bytes(data), args.input.stat().st_mode)
    print(f"wrote {wanted} {args.output} ({digest(data)})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)
