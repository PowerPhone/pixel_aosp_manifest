#!/usr/bin/env python3
"""Allow 192 kHz on Frankel's EP3/audio_capture2 CPU DAI.

This is deliberately a one-site transform layered on the exact, already
qualified Frankel module that contains both the general 192 kHz allowances and
the 1 ms AoC host-poll timer.  EP3 is the CPU DAI used by PCM 0,10
(``audio_capture2``); its stock standard-rate mask stops at 96 kHz even though
the INTERNAL_MIC_TX backend has already been extended through 192 kHz.

Google has not published the matching CP2A.260805.005 module source.  Refuse
anything except the exact input or exact output binary and write atomically.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import sys
import tempfile


BASE_SHA256 = "7f835a60ac15dec171710b5c54730cd8f2accacbb8dbab846fd7bb4b81c06dfb"
PATCHED_SHA256 = "b546932830465a6edaf92648c5f14d207b04c93708d55bc6ec2a055bc49d4756"

EP3_RATE_MASK_OFFSET = 0x40300
STOCK_RATE_MASK = bytes.fromhex("fe070000")
RATE_MASK_THROUGH_192K = bytes.fromhex("fe1f0000")

# Guard the complete EP3 capture DAI capability record surrounding the mask,
# not merely a common four-byte value which appears in several other DAIs.
CONTEXT_OFFSET = 0x402F8
STOCK_CONTEXT = bytes.fromhex(
    "4404000000000000"
    "fe07000000000000"
    "0000000001000000"
    "0400000000000000"
)
PATCHED_CONTEXT = bytes.fromhex(
    "4404000000000000"
    "fe1f000000000000"
    "0000000001000000"
    "0400000000000000"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("base", "patched"))
    parser.add_argument("--set-state", choices=("base", "patched"), default="patched")
    parser.add_argument("--in-place", action="store_true")
    return parser.parse_args()


def classify(data: bytes) -> str:
    if len(data) <= CONTEXT_OFFSET + len(STOCK_CONTEXT):
        raise ValueError("input is too small for the guarded EP3 DAI record")
    context = data[CONTEXT_OFFSET : CONTEXT_OFFSET + len(STOCK_CONTEXT)]
    digest = hashlib.sha256(data).hexdigest()
    if context == STOCK_CONTEXT and digest == BASE_SHA256:
        return "base"
    if context == PATCHED_CONTEXT and digest == PATCHED_SHA256:
        return "patched"
    raise ValueError(
        "input is neither the exact 1 ms timer base nor its exact EP3-192k "
        f"transform (sha256={digest}, context={context.hex()})"
    )


def transform(data: bytearray, target: str) -> None:
    current = classify(data)
    if current == target:
        return
    before = STOCK_RATE_MASK if current == "base" else RATE_MASK_THROUGH_192K
    after = RATE_MASK_THROUGH_192K if target == "patched" else STOCK_RATE_MASK
    actual = data[EP3_RATE_MASK_OFFSET : EP3_RATE_MASK_OFFSET + len(before)]
    if actual != before:
        raise ValueError(
            f"EP3 rate mask changed at 0x{EP3_RATE_MASK_OFFSET:x}: {actual.hex()}"
        )
    data[EP3_RATE_MASK_OFFSET : EP3_RATE_MASK_OFFSET + len(before)] = after
    if classify(data) != target:
        raise AssertionError("transformed module failed exact self-validation")


def write_atomic(path: pathlib.Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"refusing unsafe output path: {path}")
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, stat.S_IMODE(mode))
        os.replace(temporary_name, path)
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
    if args.check and (args.output is not None or args.in_place):
        raise ValueError("--check cannot be combined with a write destination")
    if not args.check and not args.in_place and args.output is None:
        raise ValueError("apply mode requires OUTPUT or --in-place")

    data = bytearray(args.input.read_bytes())
    current = classify(data)
    if args.check:
        if current != args.check:
            raise ValueError(f"expected {args.check}, found {current}")
        print(f"verified {current}: {args.input}")
        return 0

    transform(data, args.set_state)
    destination = args.input if args.in_place else args.output
    assert destination is not None
    write_atomic(destination, data, args.input.stat().st_mode)
    print(f"selected {args.set_state} EP3 capture rate mask: {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
