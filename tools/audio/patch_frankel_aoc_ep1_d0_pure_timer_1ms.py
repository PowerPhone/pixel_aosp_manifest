#!/usr/bin/env python3
"""Convert Frankel PCM0's 1 ms hybrid progress trial to a pure host timer.

The input already selects the hrtimer path only for PCM0/D0.  Its one
remaining deviation from a stock timer-backed stream is the deliberately
hoisted ``dev->prvdata = alsa_stream`` store, which leaves the PCM mailbox ISR
active alongside the timer.  Explicitly clear ``dev->prvdata`` at that
instruction.  The interrupt arm still installs ``dev->prvdata`` for all
non-D0 PCM services, while D0 now has exactly one progress producer.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


HYBRID_SHA256 = "a25094fcb9f1d01a883f2c9830b31a85ed161062de34f0de54f5bc15037e0c31"
PURE_TIMER_SHA256 = "0b7150789ed60b53fff596a1239ecc6c968730d7d800f05ecb1128ce70057ebe"
OFFSET = 0x1A5DC
HYBRID = bytes.fromhex("14f901f9")  # str x20, [x8, #1008] (dev->prvdata)
PURE_TIMER = bytes.fromhex("1ff901f9")  # str xzr, [x8, #1008] (dev->prvdata)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    observed = bytes(data[OFFSET : OFFSET + 4])
    sha = digest(data)
    if observed == HYBRID and sha == HYBRID_SHA256:
        return "hybrid"
    if observed == PURE_TIMER and sha == PURE_TIMER_SHA256:
        return "pure-timer"
    raise ValueError(f"unexpected module: sha256={sha}, site={observed.hex()}")


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    before, after = (
        (HYBRID, PURE_TIMER) if wanted == "pure-timer" else (PURE_TIMER, HYBRID)
    )
    if bytes(data[OFFSET : OFFSET + 4]) != before:
        raise ValueError("guard mismatch at D0 mailbox-private-data store")
    data[OFFSET : OFFSET + 4] = after
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
    parser.add_argument("--check", choices=("hybrid", "pure-timer"))
    parser.add_argument(
        "--set-state", choices=("hybrid", "pure-timer"), default="pure-timer"
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
