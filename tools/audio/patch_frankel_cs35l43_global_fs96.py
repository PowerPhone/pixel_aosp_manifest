#!/usr/bin/env python3
"""Select stock or 96 kHz ultrasonic GLOBAL_FS in Frankel's CS35L43 module.

Google has not published source matching this exact module.  The only change
is the AArch64 immediate passed to regmap_update_bits_base() by
cs35l43_pcm_hw_params() when Ultrasonic Mode is non-disabled: GLOBAL_FS code
3 (48 kHz) becomes code 4 (96 kHz).  CS35L43's FSX2 high-rate amplifier path
therefore runs at 192 kHz.  Ordinary (Ultrasonic Mode Disabled) paths retain
the stock rate table.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import sys
import tempfile


STOCK_SHA256 = "8db0c2795f11585cb3d30382169606130e5f8aa9b6c001b6508b758b29ca99d3"
PATCHED_SHA256 = "fc631fc227ab2e7e8cfa2d664e97ac7cca4c14324fb2a39479fc8e79aa358a3a"
PATCH_OFFSET = 0x5DDC
STOCK_WORD = bytes.fromhex("63008052")  # mov w3, #3
PATCHED_WORD = bytes.fromhex("83008052")  # mov w3, #4


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Select or verify Frankel CS35L43 ultrasonic GLOBAL_FS."
    )
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "patched"))
    parser.add_argument("--set-state", choices=("stock", "patched"))
    parser.add_argument("--in-place", action="store_true")
    return parser.parse_args()


def classify(data: bytes) -> str:
    word = data[PATCH_OFFSET : PATCH_OFFSET + 4]
    if word == STOCK_WORD:
        state, expected = "stock", STOCK_SHA256
    elif word == PATCHED_WORD:
        state, expected = "patched", PATCHED_SHA256
    else:
        raise ValueError(
            f"unexpected instruction at 0x{PATCH_OFFSET:x}: {word.hex()}"
        )
    observed = hashlib.sha256(data).hexdigest()
    if observed != expected:
        raise ValueError(
            f"unexpected {state} whole-file SHA-256: {observed} "
            f"(expected {expected})"
        )
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
        raise ValueError(f"input is not a safe regular file: {args.input}")
    if args.in_place and args.output is not None:
        raise ValueError("OUTPUT and --in-place are mutually exclusive")
    if not args.check and not args.in_place and args.output is None:
        raise ValueError("apply mode requires OUTPUT or --in-place")
    if args.check and (
        args.in_place or args.output is not None or args.set_state is not None
    ):
        raise ValueError("--check cannot be combined with a write option")

    data = bytearray(args.input.read_bytes())
    current = classify(data)
    if args.check:
        if current != args.check:
            print(f"module is {current}, not {args.check}: {args.input}", file=sys.stderr)
            return 1
        print(f"verified {current}: {args.input}")
        return 0

    target = args.set_state or "patched"
    if current != target:
        expected = STOCK_WORD if current == "stock" else PATCHED_WORD
        replacement = PATCHED_WORD if target == "patched" else STOCK_WORD
        if data[PATCH_OFFSET : PATCH_OFFSET + 4] != expected:
            raise ValueError("module changed while preparing transformation")
        data[PATCH_OFFSET : PATCH_OFFSET + 4] = replacement
        if classify(data) != target:
            raise AssertionError("transformed module failed exact validation")

    destination = args.input if args.in_place else args.output
    assert destination is not None
    if destination != args.input or current != target:
        write_atomic(destination, data, stat.S_IMODE(args.input.stat().st_mode))
    action = "already" if current == target else "selected"
    print(f"{action} {target}: {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
