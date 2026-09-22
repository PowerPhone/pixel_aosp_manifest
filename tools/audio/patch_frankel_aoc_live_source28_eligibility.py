#!/usr/bin/env python3
"""Guard and live-patch Frankel AoC SOURCE-28 eligibility checks.

The patch raises the Audio Output Source enable/disable range limit from 10
to 32 while preserving the endpoint ID in ``a2``.  It is tied to the reviewed
Frankel vendor build by the shared speaker-patch preflight and is volatile
across an AoC/device reset.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_speaker_192k import (
    Patch,
    flush_instruction_cache,
    preflight,
    write_patch,
)


# Each entry is the first aligned word of one eight-byte F1 FLIX bundle.  The
# only changed byte is the signed B4CONST selector: 9 means 10 and C means 32.
# The remaining word, including the branch displacement, is left untouched.
PATCHES = (
    Patch(
        "Audio Output Source enable eligibility 10 -> 32",
        0x403966F4,
        bytes.fromhex("bf9c3210"),
        bytes.fromhex("bfcc3210"),
        "hook",
    ),
    Patch(
        "Audio Output Source disable eligibility 10 -> 32",
        0x403967F0,
        bytes.fromhex("3f9c3218"),
        bytes.fromhex("3fcc3218"),
        "hook",
    ),
)


def integer(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description=(
            "Inspect or change the reboot-volatile Frankel AoC SOURCE-28 "
            "enable/disable eligibility checks"
        )
    )
    parser.add_argument("action", choices=("status", "apply", "revert"))
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=integer)
    parser.add_argument(
        "--allow-active-pcm28",
        "--allow-active-playback",
        dest="allow_active_pcm28",
        action="store_true",
        help=(
            "permit a deliberate operation while PCM 0,28 is not closed; "
            "the default is to refuse even status inspection"
        ),
    )
    return parser.parse_args()


def classify(actual: bytes, patch: Patch) -> str:
    if actual == patch.before:
        return "stock"
    if actual == patch.after:
        return "patched"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
        f"{actual.hex()} (stock {patch.before.hex()}, patched "
        f"{patch.after.hex()})"
    )


def read_states(
    transport: AocFactoryDiag, *, announce: bool = True
) -> dict[Patch, str]:
    states: dict[Patch, str] = {}
    for patch in PATCHES:
        actual = transport.dump(patch.address, 4)
        state = classify(actual, patch)
        states[patch] = state
        if announce:
            print(
                f"{state:7s} 0x{patch.address:08x} {actual.hex()}  "
                f"{patch.name}"
            )
    return states


def state_summary(states: dict[Patch, str]) -> str:
    unique = set(states.values())
    return unique.pop() if len(unique) == 1 else "mixed"


def rollback_to_snapshot(
    transport: AocFactoryDiag, snapshot: dict[Patch, str]
) -> list[str]:
    """Best-effort restore of every site, followed by one I-cache flush."""

    errors: list[str] = []
    for patch in reversed(PATCHES):
        wanted = snapshot[patch]
        try:
            actual = transport.dump(patch.address, 4)
            if classify(actual, patch) == wanted:
                continue
            # write_patch's action names describe the desired final state.
            write_patch(
                transport,
                patch,
                "revert" if wanted == "stock" else "apply",
            )
        except BaseException as error:
            errors.append(f"0x{patch.address:08x}: {error}")

    try:
        restored = read_states(transport, announce=False)
        mismatches = [
            f"0x{patch.address:08x}={restored[patch]} "
            f"(wanted {snapshot[patch]})"
            for patch in PATCHES
            if restored[patch] != snapshot[patch]
        ]
        if mismatches:
            errors.append("snapshot verification: " + ", ".join(mismatches))
    except BaseException as error:
        errors.append(f"snapshot verification: {error}")

    # A failed write may have reached AoC RAM even if its readback failed.
    # Always synchronize the restored code path after a mutation was tried.
    try:
        flush_instruction_cache(transport)
    except BaseException as error:
        errors.append(f"rollback I-cache flush: {error}")
    return errors


def change_state(
    transport: AocFactoryDiag, action: str, snapshot: dict[Patch, str]
) -> None:
    destination = "patched" if action == "apply" else "stock"
    mutation_attempted = False
    try:
        # Update all data words first.  A single cache invalidation below makes
        # the complete pair visible as executable code.
        for patch in PATCHES:
            if snapshot[patch] == destination:
                continue
            mutation_attempted = True
            write_patch(transport, patch, action)

        final = read_states(transport, announce=False)
        if any(state != destination for state in final.values()):
            raise RuntimeError(
                f"eligibility patch did not reach uniform {destination} state"
            )
        if mutation_attempted:
            flush_instruction_cache(transport)
    except BaseException as error:
        if not mutation_attempted:
            raise
        rollback_errors = rollback_to_snapshot(transport, snapshot)
        if rollback_errors:
            raise RuntimeError(
                f"{action} failed ({error}); rollback was incomplete: "
                + "; ".join(rollback_errors)
            ) from error
        raise RuntimeError(
            f"{action} failed ({error}); restored the original two-word "
            "snapshot and flushed the AoC I-cache"
        ) from error

    print(
        f"verified both SOURCE eligibility checks uniformly {destination}; "
        "live changes disappear on AoC/device reboot"
    )


def main() -> int:
    args = parse_args()
    transport = AocFactoryDiag(
        argparse.Namespace(
            adb=args.adb,
            adb_server_port=args.adb_server_port,
            serial=args.serial,
            core=2,
            counter=args.counter,
        )
    )
    preflight(transport, args.allow_active_pcm28)
    snapshot = read_states(transport)
    summary = state_summary(snapshot)

    if args.action == "status":
        print(f"SOURCE-28 eligibility patch state: {summary}")
        return 0

    destination = "patched" if args.action == "apply" else "stock"
    if summary == destination:
        print(f"both SOURCE eligibility checks are already {destination}")
        return 0
    change_state(transport, args.action, snapshot)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
