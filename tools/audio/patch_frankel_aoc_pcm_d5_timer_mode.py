#!/usr/bin/env python3
"""Select the host timer for Frankel PCM0,D5 / AoC EP6.

This selector is deliberately narrow: it accepts the exact PowerPhone
``one-period-lag`` AoC ALSA module, independently of the orthogonal EP6 rate
mask, and changes only ``snd_aoc_pcm_open``. D0 retains its 1 ms timer plus
real-counter progress, D5 gains that same existing 1 ms timer, and every other
main PCM retains the stock mailbox-type decision.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import sys
import tempfile


EP6_RATE_OFFSET = 0x3F728
EP6_RATE_STOCK = bytes.fromhex("fe000000")
EP6_RATE_PATCHED = bytes.fromhex("fe1f0000")
NORMALIZED_ONE_PERIOD_LAG_SHA256 = (
    "37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6"
)

# Reclaim the redundant cstream=0 store (the object came from kzalloc), retain
# chip->opened in x22, and fold the second draining=1 store into the former ORR
# slot. The two recovered instructions let the existing mailbox predicate
# become: timer iff idx == 5 OR mailbox_type != 4. The following D0 cbz from
# the one-period-lag state remains intact, so D0 also continues to use timer.
PATCHES = (
    (0x1A46C, bytes.fromhex("1f0800f9"), bytes.fromhex("360b43f9")),
    (0x1A5C8, bytes.fromhex("2a0b43f9"), bytes.fromhex("c80208aa")),
    (0x1A5CC, bytes.fromhex("480108aa"), bytes.fromhex("895e01b9")),
    (0x1A5DC, bytes.fromhex("895e01b9"), bytes.fromhex("bf160071")),
    # cmp w10,#4 -> ccmp w10,#4,#0,ne, paired with cmp w21,#5 above.
    (0x1A5E4, bytes.fromhex("5f110071"), bytes.fromhex("4019447a")),
)


def normalized_digest(data: bytes | bytearray) -> str:
    normalized = bytearray(data)
    for offset, before, after in PATCHES:
        actual = bytes(normalized[offset : offset + len(before)])
        if actual not in (before, after):
            raise ValueError(
                f"D5 timer guard mismatch at 0x{offset:x}: {actual.hex()}"
            )
        normalized[offset : offset + len(before)] = before
    rate = bytes(
        normalized[EP6_RATE_OFFSET : EP6_RATE_OFFSET + len(EP6_RATE_STOCK)]
    )
    if rate not in (EP6_RATE_STOCK, EP6_RATE_PATCHED):
        raise ValueError(f"EP6 rate guard mismatch: {rate.hex()}")
    normalized[
        EP6_RATE_OFFSET : EP6_RATE_OFFSET + len(EP6_RATE_STOCK)
    ] = EP6_RATE_STOCK
    return hashlib.sha256(normalized).hexdigest()


def classify(data: bytes | bytearray) -> str:
    states = []
    for offset, before, after in PATCHES:
        actual = bytes(data[offset : offset + len(before)])
        if actual == before:
            states.append("disabled")
        elif actual == after:
            states.append("enabled")
        else:
            raise ValueError(
                f"D5 timer guard mismatch at 0x{offset:x}: {actual.hex()}"
            )
    if len(set(states)) != 1:
        raise ValueError("refusing partially selected D5 timer transform")
    observed = normalized_digest(data)
    if observed != NORMALIZED_ONE_PERIOD_LAG_SHA256:
        raise ValueError(
            "input is not the exact one-period-lag module: "
            f"normalized sha256={observed}"
        )
    return states[0]


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"refusing unsafe output: {path}")
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
        pathlib.Path(temporary).unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("disabled", "enabled"))
    parser.add_argument("--set-state", choices=("disabled", "enabled"), default="enabled")
    parser.add_argument("--in-place", action="store_true")
    args = parser.parse_args()

    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError(f"unsafe input: {args.input}")
    if args.check and (args.output is not None or args.in_place):
        parser.error("--check cannot write")
    if args.in_place and args.output is not None:
        parser.error("OUTPUT and --in-place are mutually exclusive")
    if not args.check and not args.in_place and args.output is None:
        parser.error("OUTPUT or --in-place is required")

    data = bytearray(args.input.read_bytes())
    current = classify(data)
    if args.check:
        if current != args.check:
            raise ValueError(f"D5 timer is {current}, expected {args.check}")
        print(f"verified D5 timer {args.check}: {args.input}")
        return 0

    wanted = args.set_state
    if current != wanted:
        for offset, before, after in PATCHES:
            source, replacement = (
                (before, after) if wanted == "enabled" else (after, before)
            )
            if bytes(data[offset : offset + len(source)]) != source:
                raise AssertionError(f"unexpected D5 timer bytes at 0x{offset:x}")
            data[offset : offset + len(source)] = replacement
    if classify(data) != wanted:
        raise AssertionError("D5 timer post-transform validation failed")
    destination = args.input if args.in_place else args.output
    assert destination is not None
    atomic_write(destination, bytes(data), args.input.stat().st_mode)
    print(f"selected D5 timer {wanted}: {destination}")
    print(f"sha256={hashlib.sha256(data).hexdigest()}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
