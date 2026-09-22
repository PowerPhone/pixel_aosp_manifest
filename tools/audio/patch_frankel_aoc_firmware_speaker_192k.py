#!/usr/bin/env python3
"""Patch one reviewed Frankel aoc.bin with guarded high-rate audio edits.

The historical default remains the original six-site speaker experiment.
``--profile source0-4s32-allocator-fallback`` selects the PowerPhone F1
PCM0/EP1 four-S32 speaker profile plus the narrow A32 work-item allocator
fallback.  The older global UsfTimer assertion bypass remains available only
for reproducing historical experiments.  All profiles are tied to the exact
reviewed CP2A.260805.005 image and exact whole-file digests. ``--set-state``
provides guarded, symmetric stock/patched selection for reproducible builds.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import os
import pathlib
import stat
import sys
import tempfile


EXPECTED_SIZE = 24_791_040
EXPECTED_STOCK_SHA256 = "ac6d7d86e6aa78379bfa3db5eaea4dadebf8113dc8f46aab52d55f3987064abd"
F1_RUNTIME_BASE = 0x40000000
FIRMWARE_IMAGE_FILE_OFFSET = 0x00A6FDC0


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    offset: int
    before: bytes
    after: bytes


# aoc.bin file offsets are F1 local offsets plus 0x00a6fdc0 for this exact
# image.  The runtime targets and return addresses are encoded in the cave and
# hook instructions; do not relocate these byte sequences to another build.
LEGACY_PATCHES = (
    Patch(
        "speaker rate/quantum code cave at F1 0x4038aee8",
        0x00DFACA8,
        bytes(24),
        bytes.fromhex(
            "924bfca2257188410c5b562800b20c8a625c3946e1020000"
        ),
    ),
    Patch(
        "speaker sink/source guard code cave at F1 0x4039d521",
        0x00E0D2E1,
        bytes(26),
        bytes.fromhex(
            "8214327223da2841ccb20c52e7670462a0c00c7222448a8645b9"
        ),
    ),
    Patch(
        "speaker TDM clock code cave at F1 0x403d36f1",
        0x00E434B1,
        bytes(20),
        bytes.fromhex("2213e39042114263a22263a6a2236f0c0b064602"),
    ),
    Patch(
        "route speaker rate/quantum store through guarded cave",
        0x00DFB838,
        bytes.fromhex("9e8bdad6"),
        bytes.fromhex("061bfdd6"),
    ),
    Patch(
        "derive speaker TDM rate and clock from the selected quantum",
        0x00E43DD8,
        bytes.fromhex("aee3bc42"),
        bytes.fromhex("46b5fd42"),
    ),
    Patch(
        "route configureMixer guard through guarded cave",
        0x00DFB80C,
        bytes.fromhex("8e548f4d"),
        bytes.fromhex("46b4464d"),
    ),
)


# UsfTimer::InvokeCallback calls the global worker enqueue routine and asserts
# when it cannot allocate one of its 0x28-byte work items.  Replace only the
# CBNZ-to-assert at A32 0x4009e0ce with a Thumb NOP.  This makes exhaustion
# drop that timer callback instead of resetting AoC; it does not enlarge or
# otherwise alter the shared work pool.
A32_OUTPUTTER_TIMER_NOP = Patch(
    "A32 UsfTimer worker-enqueue failure: drop callback instead of assert",
    0x00B0DE8E,
    bytes.fromhex("90bb"),
    bytes.fromhex("00bf"),
)


# At A32 0x400a114e, a failed 40-byte dynamic work-item allocation jumps
# directly to error 6 even when the 128-entry static pool still has its
# 31-entry reserve.  Redirect only that conditional branch to the allocator's
# existing locked static-freelist path at 0x400a119c.  If the freelist is also
# empty, the unchanged path still records a static failure and returns 6.
A32_ALLOCATOR_FALLBACK = Patch(
    "A32 work allocator: dynamic failure -> existing static freelist",
    0x00B10F0E,
    bytes.fromhex("70d0"),
    bytes.fromhex("25d0"),
)


def source0_four_s32_patches() -> tuple[Patch, ...]:
    """Translate the qualified live F1 profile to signed-image offsets."""

    # Keep one canonical definition of the 31 words: the live patcher owns
    # their reviewed code-cave/hook ordering and this offline tool changes
    # only their address domain.
    import patch_frankel_aoc_live_speaker_192k as live

    return tuple(
        Patch(
            f"F1 source0-4s32: {patch.name}",
            FIRMWARE_IMAGE_FILE_OFFSET
            + (patch.address - F1_RUNTIME_BASE),
            patch.before,
            patch.after,
        )
        for patch in live.profile_patches(live.SOURCE0_4S32_PROFILE)
    )


def profile_patches(profile: str) -> tuple[Patch, ...]:
    if profile == "legacy":
        return LEGACY_PATCHES
    if profile == "source0-4s32":
        return source0_four_s32_patches()
    if profile == "a32-outputter-nop":
        return (A32_OUTPUTTER_TIMER_NOP,)
    if profile == "source0-4s32-outputter-nop":
        return source0_four_s32_patches() + (A32_OUTPUTTER_TIMER_NOP,)
    if profile == "a32-allocator-fallback":
        return (A32_ALLOCATOR_FALLBACK,)
    if profile == "source0-4s32-allocator-fallback":
        return source0_four_s32_patches() + (A32_ALLOCATOR_FALLBACK,)
    raise ValueError(f"unknown profile: {profile}")


EXPECTED_PATCHED_SHA256 = {
    "legacy": "7634012064276089a78a413ad82b1c8a885b103dd27251338584c157c2fc713e",
    "source0-4s32": "dd01f5b8a5484750bf3ae7b15af5e8f88766d9b92ab37242b8fdb7b8a965b44f",
    "a32-outputter-nop": "d4150a3bc90de6de0cb53e18fcbd44051939ef773d7ef8af57f66c8868d6915c",
    "source0-4s32-outputter-nop": "fc7ff0c927c1d11b3f3e9d186ab1687baee1bab33c804ab1a4a4fe58699d5779",
    "a32-allocator-fallback": "0687b00bcc5a02e834921e6cf3e9e6d7d6048b502de8fc69f7f446282c85827b",
    "source0-4s32-allocator-fallback": "686d0099eb31d9bc7f24dff46b02962a2ed783b7dd37504296a8cf612ecc3eab",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply or verify the guarded Frankel speaker AoC firmware patch"
    )
    parser.add_argument("input", type=pathlib.Path, help="reviewed stock aoc.bin")
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument(
        "--profile",
        choices=(
            "legacy",
            "source0-4s32",
            "a32-outputter-nop",
            "source0-4s32-outputter-nop",
            "a32-allocator-fallback",
            "source0-4s32-allocator-fallback",
        ),
        default="legacy",
        help="guarded patch set (default: legacy six-site experiment)",
    )
    parser.add_argument("--check", choices=("stock", "patched"))
    parser.add_argument(
        "--set-state", choices=("stock", "patched"), default="patched"
    )
    parser.add_argument("--in-place", action="store_true")
    return parser.parse_args()


def classify(data: bytes, patch: Patch) -> str:
    actual = data[patch.offset : patch.offset + len(patch.before)]
    if actual == patch.before:
        return "stock"
    if actual == patch.after:
        return "patched"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.offset:x}: {actual.hex()} "
        f"(stock {patch.before.hex()}, patched {patch.after.hex()})"
    )


def profile_state(data: bytes | bytearray, profile: str) -> str:
    patches = profile_patches(profile)
    states = {classify(data, patch) for patch in patches}
    if len(states) != 1:
        raise ValueError("refusing a partially patched AoC firmware")
    state = states.pop()
    expected_digest = (
        EXPECTED_STOCK_SHA256
        if state == "stock"
        else EXPECTED_PATCHED_SHA256[profile]
    )
    observed_digest = hashlib.sha256(data).hexdigest()
    if observed_digest != expected_digest:
        raise ValueError(
            f"unexpected {state} SHA-256 {observed_digest}; "
            f"expected {expected_digest}"
        )
    return state


def select_profile_state(
    data: bytearray, profile: str, wanted: str
) -> None:
    current = profile_state(data, profile)
    if current == wanted:
        return
    for patch in profile_patches(profile):
        before, after = (
            (patch.before, patch.after)
            if wanted == "patched"
            else (patch.after, patch.before)
        )
        end = patch.offset + len(before)
        if bytes(data[patch.offset:end]) != before:
            raise ValueError(
                f"guard mismatch at 0x{patch.offset:x}: {patch.name}"
            )
        data[patch.offset:end] = after
    if profile_state(data, profile) != wanted:
        raise AssertionError("post-transform state mismatch")


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"refusing unsafe output: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
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
    args = parse_args()
    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError(f"unsafe input: {args.input}")
    if args.in_place and args.output is not None:
        raise ValueError("OUTPUT and --in-place are mutually exclusive")
    if not args.check and not args.in_place and args.output is None:
        raise ValueError("apply mode requires OUTPUT or --in-place")
    if args.check and (args.in_place or args.output is not None):
        raise ValueError("--check cannot be combined with an output option")

    data = bytearray(args.input.read_bytes())
    if len(data) != EXPECTED_SIZE:
        raise ValueError(
            f"unexpected aoc.bin size {len(data)}; expected {EXPECTED_SIZE}"
        )
    current = profile_state(data, args.profile)
    if args.check:
        if current != args.check:
            raise ValueError(f"firmware is {current}, expected {args.check}")
        print(f"verified {args.check}: {args.input}")
        return 0

    # Offline image mutation has no execution race, but retain cave-first,
    # hook-last order so the layout mirrors the safe live procedure. Reverting
    # walks the same reviewed records in the same deterministic order.
    select_profile_state(data, args.profile, args.set_state)
    destination = args.input if args.in_place else args.output
    assert destination is not None
    atomic_write(destination, bytes(data), args.input.stat().st_mode)
    print(f"selected {args.set_state}: {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
