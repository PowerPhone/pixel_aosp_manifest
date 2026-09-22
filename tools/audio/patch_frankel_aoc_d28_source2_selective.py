#!/usr/bin/env python3
"""Use AoC SOURCE2 only for Frankel's D28 ultrasonic playback stream.

Frankel's F1 accepts endpoint 28 through command 0x1401, as used by the Cubs
driver, while ordinary Frankel playback still requires legacy command 0x00c9.
The exact Pixel 10 CPU has LSE atomics; use the otherwise unreachable LL/SC
fallback tails in aoc_audio_start/stop for the two guarded conditional stubs.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


STOCK_SHA256 = "f7c7f9dcdf1efde705be45fc0beeb29a2c958e2db774fd4692e53ae41134dba8"
PATCHED_SHA256 = "35475a07f0c2f21da078f4ae7163562bc6677a1bf03496b7efd7fa0e46f986d8"

# Each fallback tail is unreachable on Frankel because arm64 alternatives
# replace the preceding branch with a NOP when the detected LSE feature is on.
# No relocation-bearing instruction is overwritten.
PATCHES = (
    (
        0x1270C,
        bytes.fromhex("2919a072"),
        bytes.fromhex("2f000014"),
        "aoc_audio_start: branch to D28 command selector",
    ),
    (
        0x127C8,
        bytes.fromhex(
            "510180f9 497d5f88 29050011 49fd0b88 abffff35 bf3b03d5"
        ),
        bytes.fromhex(
            "1f710071 61000054 2980a272 cfffff17 2919a072 cdffff17"
        ),
        "aoc_audio_start: D28=0x1401, other=0x00c9",
    ),
    (
        0x12A6C,
        bytes.fromhex("2919a072"),
        bytes.fromhex("2e000014"),
        "aoc_audio_stop: branch to D28 command selector",
    ),
    (
        0x12B24,
        bytes.fromhex(
            "510180f9 497d5f88 29050011 49fd0b88 abffff35 bf3b03d5"
        ),
        bytes.fromhex(
            "1f710071 61000054 2980a272 d0ffff17 2919a072 ceffff17"
        ),
        "aoc_audio_stop: D28=0x1401, other=0x00c9",
    ),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    observed = tuple(bytes(data[o : o + len(before)]) for o, before, _, _ in PATCHES)
    stock = tuple(before for _, before, _, _ in PATCHES)
    patched = tuple(after for _, _, after, _ in PATCHES)
    if observed == stock and digest(data) == STOCK_SHA256:
        return "stock"
    if observed == patched and digest(data) == PATCHED_SHA256:
        return "patched"
    raise ValueError(
        "unexpected or partially patched module: "
        f"sha256={digest(data)}, guarded={[part.hex() for part in observed]}"
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
        for offset, before, after, description in PATCHES:
            source, destination = (before, after) if wanted == "patched" else (after, before)
            actual = bytes(data[offset : offset + len(source)])
            if actual != source:
                raise ValueError(f"guard mismatch for {description} at 0x{offset:x}")
            data[offset : offset + len(source)] = destination
            print(f"patched 0x{offset:x}: {description}")
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
