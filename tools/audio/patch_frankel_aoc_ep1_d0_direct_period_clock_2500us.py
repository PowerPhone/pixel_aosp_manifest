#!/usr/bin/env python3
"""Give Frankel PCM0/D0 a direct 2.5 ms ALSA period clock.

The qualified 192 kHz EP1/source-0 transport starts, but its shared AoC
consumer counter remains equal to the prepare-time base until teardown.  A
host timer therefore cannot reach the stock position-update path.  This
exact-module transform makes only PCM device 0 advance its modulo ALSA
position by one runtime-selected period per timer callback and then enters
the stock period-work path directly.  It deliberately leaves
``prev_consumed`` and every AoC ring counter untouched.  Every non-D0 stream
replays the original counter comparison and follows the unmodified code.

The interval is 2,500,000 ns, exactly 480 frames at 192 kHz.  The three code
fragments occupy relocation-free portions of arm64 LL/SC fallback tails that
are unreachable on Frankel's LSE-capable CPU.  In particular, the relocated
ADRP/ADD prefixes at 0x6674, 0x6698, and 0x6a58 are not modified.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "053900e08ffb5fb62ce7b4929f3bf6ef1db3d66991d4824ee37a008563f5f42f"
PATCHED_SHA256 = "1ce8ca36e915d5c3cd05d5e5f731f5374caf9f4c349111dadb01c4ed684f84e2"

PATCHES = (
    (
        0xD680,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5caffff17"),
        bytes.fromhex("68f240b908010034bf0202ebab3200141f2003d51f2003d5"),
        "D0 selector and stock non-D0 comparison",
    ),
    (
        0xD6A4,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5cfffff17"),
        bytes.fromhex("682241b9692a41b96a2641b92901080b3f010a6beb000014"),
        "load period/position/buffer and compute next D0 position",
    ),
    (
        0xDA64,
        bytes.fromhex("497d5f882905001149fd0b88abffff35bf3b03d5d9ffff17"),
        bytes.fromhex("2a010a4b4921891a692a01b9b93100141f2003d51f2003d5"),
        "wrap/store D0 position and enter stock period-work path",
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
    (
        0x1A134,
        bytes.fromhex("bf0202eb"),
        bytes.fromhex("53cdff17"),
        "route D0/non-D0 position selection through guarded caves",
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
        return "pure-timer-1ms"
    if observed == patched and sha == PATCHED_SHA256:
        return "d0-direct-period-clock-2500us"
    raise ValueError(
        f"unexpected module sha256={sha}; sites={[part.hex() for part in observed]}"
    )


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    for offset, base, patched, description in PATCHES:
        before, after = (
            (base, patched)
            if wanted == "d0-direct-period-clock-2500us"
            else (patched, base)
        )
        if bytes(data[offset : offset + len(before)]) != before:
            raise ValueError(f"guard mismatch at 0x{offset:x}: {description}")
        data[offset : offset + len(before)] = after
        print(f"patched 0x{offset:x}: {description}")
    if classify(data) != wanted:
        raise AssertionError("post-patch classification failed")


def write_atomic(path: pathlib.Path, data: bytes, mode: int) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"refusing unsafe output: {path}")
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
    parser.add_argument(
        "--check",
        choices=("pure-timer-1ms", "d0-direct-period-clock-2500us"),
    )
    parser.add_argument(
        "--set-state",
        choices=("pure-timer-1ms", "d0-direct-period-clock-2500us"),
        default="d0-direct-period-clock-2500us",
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
        parser.error("OUTPUT is required when patching")
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
