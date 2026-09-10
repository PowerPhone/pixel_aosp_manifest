#!/usr/bin/env python3
"""Add a D0-only synthetic period fallback to Frankel's pure host timer.

The normal path still trusts AoC's monotonic ring-consumer counter.  Only when
that counter is unchanged on a timer tick, and only for PCM0/D0, synthesize
one ALSA period (the runtime-selected ``period_size``).  A 2.5 ms timer matches
480 frames at 192 kHz.  This diagnostic distinguishes a stale counter from a
ring which AoC genuinely does not consume.

The cave occupies an arm64 LL/SC fallback tail replaced by LSE alternatives on
Frankel.  All bytes and whole-file states are exact and reversible.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "0b7150789ed60b53fff596a1239ecc6c968730d7d800f05ecb1128ce70057ebe"
PATCHED_SHA256 = "f9a5edd7c25d69dd8f15d1a0ff1e54f8ed853269cbbc574e3ce4285bea1ae254"

PATCHES = (
    (
        0xDA58,
        bytes.fromhex("0a0000904a010091510180f9497d5f8829050011"),
        bytes.fromhex("68f240b968380635682241b95540288bb6310014"),
        "D0 unchanged-consumer synthetic-period cave",
    ),
    (
        0x1A138,
        bytes.fromhex("80010054"),
        bytes.fromhex("48ceff17"),
        "route unchanged-consumer branch through D0 cave",
    ),
    (
        0x1A5FC,
        bytes.fromhex("08488852"),
        bytes.fromhex("08b48452"),
        "timer interval low half 1 ms -> 2.5 ms",
    ),
    (
        0x1A608,
        bytes.fromhex("e801a072"),
        bytes.fromhex("c804a072"),
        "timer interval high half 1 ms -> 2.5 ms",
    ),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    observed = tuple(bytes(data[o : o + len(a)]) for o, a, _b, _n in PATCHES)
    base = tuple(a for _o, a, _b, _n in PATCHES)
    patched = tuple(b for _o, _a, b, _n in PATCHES)
    sha = digest(data)
    if observed == base and sha == BASE_SHA256:
        return "pure-timer"
    if observed == patched and sha == PATCHED_SHA256:
        return "synthetic-2500us"
    raise ValueError(
        f"unexpected module: sha256={sha}, sites={[part.hex() for part in observed]}"
    )


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    for offset, base, patched, name in PATCHES:
        before, after = (
            (base, patched) if wanted == "synthetic-2500us" else (patched, base)
        )
        if bytes(data[offset : offset + len(before)]) != before:
            raise ValueError(f"guard mismatch for {name} at 0x{offset:x}")
        data[offset : offset + len(before)] = after
    if classify(data) != wanted:
        raise AssertionError("post-patch classification failed")


def write_atomic(path: pathlib.Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(mode))
        os.replace(temporary, path)
    except BaseException:
        pathlib.Path(temporary).unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("pure-timer", "synthetic-2500us"))
    parser.add_argument(
        "--set-state",
        choices=("pure-timer", "synthetic-2500us"),
        default="synthetic-2500us",
    )
    args = parser.parse_args()
    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError(f"unsafe input: {args.input}")
    data = bytearray(args.input.read_bytes())
    current = classify(data)
    if args.check:
        if args.output is not None:
            parser.error("OUTPUT is incompatible with --check")
        if current != args.check:
            raise ValueError(f"module is {current}, expected {args.check}")
        print(f"verified {args.input} is {current}")
        return 0
    if args.output is None:
        parser.error("OUTPUT is required when applying a patch")
    transform(data, args.set_state)
    write_atomic(args.output, bytes(data), args.input.stat().st_mode)
    print(f"wrote {args.set_state} {args.output} ({digest(data)})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)
