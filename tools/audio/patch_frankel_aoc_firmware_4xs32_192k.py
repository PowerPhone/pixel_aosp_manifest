#!/usr/bin/env python3
"""Cold-patch Frankel AoC for the qualified D0 four-S32 192 kHz profile.

The profile is tied to CP2A.260805.005.  It mirrors the exact F1 words used by
``patch_frankel_aoc_live_speaker_192k.py`` and redirects the reviewed A32
work-item allocator's dynamic-allocation failure to its existing static
freelist.  This retains the assertion for genuine exhaustion while making the
allocator use its remaining static reserve.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import pathlib
import shutil
import sys

from patch_frankel_aoc_live_speaker_192k import profile_patches


EXPECTED_SIZE = 24_791_040
EXPECTED_STOCK_SHA256 = "ac6d7d86e6aa78379bfa3db5eaea4dadebf8113dc8f46aab52d55f3987064abd"
EXPECTED_PATCHED_SHA256 = "686d0099eb31d9bc7f24dff46b02962a2ed783b7dd37504296a8cf612ecc3eab"
PROFILE = "experimental-enum7-early-q48-tdm24576-192-4xs32-source0"
F1_FILE_BIAS = 0x00A6FDC0


@dataclasses.dataclass(frozen=True)
class FilePatch:
    name: str
    offset: int
    before: bytes
    after: bytes


def file_patches() -> tuple[FilePatch, ...]:
    f1 = tuple(
        FilePatch(
            patch.name,
            F1_FILE_BIAS + patch.address - 0x40000000,
            patch.before,
            patch.after,
        )
        for patch in profile_patches(PROFILE)
    )
    return f1 + (
        FilePatch(
            "A32 work allocator: dynamic failure -> existing static freelist",
            0x00B10F0E,
            bytes.fromhex("70d0"),
            bytes.fromhex("25d0"),
        ),
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "patched"))
    parser.add_argument("--in-place", action="store_true")
    return parser.parse_args()


def classify(data: bytes, patch: FilePatch) -> str:
    actual = data[patch.offset : patch.offset + len(patch.before)]
    if actual == patch.before:
        return "stock"
    if actual == patch.after:
        return "patched"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.offset:08x}: "
        f"{actual.hex()} (stock {patch.before.hex()}, patched {patch.after.hex()})"
    )


def main() -> int:
    args = parse_args()
    if args.in_place and args.output is not None:
        raise ValueError("OUTPUT and --in-place are mutually exclusive")
    if args.check and (args.in_place or args.output is not None):
        raise ValueError("--check cannot be combined with an output option")
    if not args.check and not args.in_place and args.output is None:
        raise ValueError("apply mode requires OUTPUT or --in-place")

    data = bytearray(args.input.read_bytes())
    if len(data) != EXPECTED_SIZE:
        raise ValueError(f"unexpected size {len(data)}; expected {EXPECTED_SIZE}")
    patches = file_patches()
    states = tuple(classify(data, patch) for patch in patches)
    digest = hashlib.sha256(data).hexdigest()

    if args.check:
        if any(state != args.check for state in states):
            raise ValueError(f"firmware is not uniformly {args.check}")
        expected_digest = (
            EXPECTED_STOCK_SHA256
            if args.check == "stock"
            else EXPECTED_PATCHED_SHA256
        )
        if digest != expected_digest:
            raise ValueError(
                f"unexpected {args.check} SHA-256 {digest}; "
                f"expected {expected_digest}"
            )
        print(f"verified {args.check}: {args.input} ({len(patches)} sites)")
        return 0

    state_set = set(states)
    if state_set == {"patched"}:
        if digest != EXPECTED_PATCHED_SHA256:
            raise ValueError(
                f"unexpected patched SHA-256 {digest}; "
                f"expected {EXPECTED_PATCHED_SHA256}"
            )
        destination = args.input if args.in_place else args.output
        assert destination is not None
        if destination != args.input:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(args.input, destination)
        print(f"already patched: {destination}")
        return 0
    if state_set != {"stock"}:
        raise ValueError("refusing a partially patched firmware image")
    if digest != EXPECTED_STOCK_SHA256:
        raise ValueError(f"unexpected stock SHA-256 {digest}")

    for patch in patches:
        end = patch.offset + len(patch.before)
        data[patch.offset:end] = patch.after
    if any(classify(data, patch) != "patched" for patch in patches):
        raise AssertionError("internal patch verification failed")
    patched_digest = hashlib.sha256(data).hexdigest()
    if patched_digest != EXPECTED_PATCHED_SHA256:
        raise AssertionError(
            f"patched firmware SHA-256 {patched_digest}; "
            f"expected {EXPECTED_PATCHED_SHA256}"
        )

    destination = args.input if args.in_place else args.output
    assert destination is not None
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    shutil.copymode(args.input, destination)
    print(
        f"patched {len(patches)} sites: {destination} "
        f"sha256={patched_digest}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
