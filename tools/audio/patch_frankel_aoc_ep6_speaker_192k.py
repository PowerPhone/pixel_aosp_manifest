#!/usr/bin/env python3
"""Select 192 kHz admission on Frankel's EP6/source-5 speaker frontend.

Frankel's ordinary primary and deep-buffer routes use PCM0,D5 (EP6/source 5).
The general PowerPhone AoC ALSA transform widens the runtime and TDM backend,
but EP6 has an independent 8--48 kHz DAI mask.  This reversible selector
changes only that mask and accepts only a known complete base-module state.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import sys
import tempfile


PATCH_OFFSET = 0x3F728
BEFORE = bytes.fromhex("fe000000")
AFTER = bytes.fromhex("fe1f0000")
D5_TIMER_PATCHES = (
    (0x1A46C, bytes.fromhex("1f0800f9"), bytes.fromhex("360b43f9")),
    (0x1A5C8, bytes.fromhex("2a0b43f9"), bytes.fromhex("c80208aa")),
    (0x1A5CC, bytes.fromhex("480108aa"), bytes.fromhex("895e01b9")),
    (0x1A5DC, bytes.fromhex("895e01b9"), bytes.fromhex("bf160071")),
    (0x1A5E4, bytes.fromhex("5f110071"), bytes.fromhex("4019447a")),
)

# Digests are calculated after normalizing the EP6 word to BEFORE.  This lets
# EP6 remain orthogonal to the selected D0 progress implementation while still
# refusing every unreviewed module identity.
NORMALIZED_SHA256 = {
    "d71b906b3e386ed8c14d219e767e4bd4a9fda3f0fb45c6d8a75e1bb00b9afe5a",
    "d0278904c384a61d9d25a44236a3e4a36c087be077b2bd6f0b971ab74b2b3cf8",
    "fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0",
    "9dd7fad9c61c56d3da79fc162594d1ace8238fa02c270f68f79ad2df4ff6b871",
    "14f768697dfdce17869d91360da54ab9e4f7b8d291e718ff8919f524e7010e98",
    "37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6",
    # Retained so the original isolated EP6 experiment remains reproducible.
    "f7c7f9dcdf1efde705be45fc0beeb29a2c958e2db774fd4692e53ae41134dba8",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "patched"))
    parser.add_argument("--set-state", choices=("stock", "patched"))
    parser.add_argument("--in-place", action="store_true")
    return parser.parse_args()


def classify(data: bytes | bytearray) -> str:
    actual = bytes(data[PATCH_OFFSET : PATCH_OFFSET + len(BEFORE)])
    if actual == BEFORE:
        state = "stock"
    elif actual == AFTER:
        state = "patched"
    else:
        raise ValueError(
            f"EP6 rate-mask guard mismatch at 0x{PATCH_OFFSET:x}: {actual.hex()}"
        )
    normalized = bytearray(data)
    normalized[PATCH_OFFSET : PATCH_OFFSET + len(BEFORE)] = BEFORE
    d5_states = []
    for offset, disabled, enabled in D5_TIMER_PATCHES:
        word = bytes(normalized[offset : offset + len(disabled)])
        if word == disabled:
            d5_states.append("disabled")
        elif word == enabled:
            d5_states.append("enabled")
        else:
            d5_states = []
            break
    if d5_states:
        if len(set(d5_states)) != 1:
            raise ValueError("partially selected D5 timer transform")
        if d5_states[0] == "enabled":
            for offset, disabled, _enabled in D5_TIMER_PATCHES:
                normalized[offset : offset + len(disabled)] = disabled
    digest = hashlib.sha256(normalized).hexdigest()
    if digest not in NORMALIZED_SHA256:
        raise ValueError(f"refusing unexpected normalized module SHA-256 {digest}")
    return state


def write_atomic(destination: pathlib.Path, data: bytes, mode: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or (
        destination.exists() and not destination.is_file()
    ):
        raise ValueError(f"refusing unsafe output path: {destination}")
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, destination)
        temporary_name = None
    finally:
        if temporary_name is not None:
            pathlib.Path(temporary_name).unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError(f"unsafe input: {args.input}")
    if args.in_place and args.output is not None:
        raise ValueError("OUTPUT and --in-place are mutually exclusive")
    if args.check and (args.output is not None or args.in_place or args.set_state):
        raise ValueError("--check cannot be combined with a write option")
    if not args.check and not args.in_place and args.output is None:
        raise ValueError("apply mode requires OUTPUT or --in-place")

    data = bytearray(args.input.read_bytes())
    state = classify(data)
    if args.check:
        if state != args.check:
            print(f"module is {state}, not {args.check}: {args.input}", file=sys.stderr)
            return 1
        print(f"verified EP6 {state}: {args.input}")
        return 0

    target = args.set_state or "patched"
    if state != target:
        replacement = AFTER if target == "patched" else BEFORE
        data[PATCH_OFFSET : PATCH_OFFSET + len(replacement)] = replacement
        if classify(data) != target:
            raise AssertionError("EP6 transform failed self-validation")
    destination = args.input if args.in_place else args.output
    assert destination is not None
    if destination != args.input or state != target:
        write_atomic(destination, bytes(data), stat.S_IMODE(args.input.stat().st_mode))
    print(f"selected EP6 {target}: {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
