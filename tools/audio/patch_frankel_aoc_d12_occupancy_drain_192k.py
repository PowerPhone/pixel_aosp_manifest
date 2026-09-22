#!/usr/bin/env python3
"""Install the guarded occupancy-driven Frankel D12 192 kHz drain."""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_d12_repack_192k import (
    PATCHES as REPACK_PATCHES,
    require_resized_idle_geometry,
)
from patch_frankel_aoc_live_d12_192k import (
    PATCHES as BASE_PATCHES,
    require_d12_idle,
    write_changed_chunks,
)
from trigger_frankel_aoc_d12_ring_resize import (
    block_capture_opens,
    require_all_capture_idle,
    restore_capture_modes,
)


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    address: int
    before: bytes
    after: bytes


STOCK_CALLBACK = bytes.fromhex(
    "3641005e030848ddc81df000bd04e501"
    "001df000000000000000000000000000"
)
NO_SYNC_AND_PERIOD = bytes.fromhex(
    "3641004203004040245d0262d508403490461500"
    "72030ff2030ef0ff11c6a4ff"
)
TWO_PASS_AND_PERIOD = bytes.fromhex(
    "36410056f30020a22040b420a5baf7ad"
    "02bd046500001df03641004203004040"
    "245d0262d50840349046f2de"
    "72030ff2030ef0ff11c681de"
    + "00" * 4
)
OCCUPANCY_DRAIN = bytes.fromhex(
    # Drain at most the complete eight-half MIC_US queue per callback.  A
    # cap-two hardware trial fell behind immediately, while cap five remained
    # continuously runnable and starved AoC control after about 0.56 seconds.
    # Static setup requires enough mono output capacity for this eight-half
    # burst.  The per-iteration availability check still stops at real input.
    "364100fc230c856204078c96a2224f88"
    "0a82281ce0080062a600a2224f880a82"
    "2810b2d208b8abe00800673a0bad02bd"
    "04a5b5f70b555605fe1df0"
    + "00"
)


PATCHES = (
    Patch(
        "replace the retired stock callback with no-sync and period helpers",
        0x403E87D0,
        STOCK_CALLBACK,
        NO_SYNC_AND_PERIOD,
    ),
    Patch(
        "redirect period geometry to the helper beside the stock callback",
        0x403E867E,
        bytes.fromhex("867b21f02000"),
        bytes.fromhex("865800f02000"),
    ),
    Patch(
        "replace the two-pass drain and old period cave with occupancy drain",
        0x403F0C44,
        TWO_PASS_AND_PERIOD,
        OCCUPANCY_DRAIN,
    ),
)


# These full-profile sites are not replaced by the occupancy patch and prove
# that its exact 192-frame producer/fanout/callback prerequisites remain live.
FOUNDATION_ADDRESSES = (
    0x403B75C9,
    0x403B7670,
    0x403B9EAC,
    0x403B84B0,
    0x403B85F6,
    0x403B8880,
    0x403B88DD,
    0x403B88FE,
    0x403BA0F4,
    0x403BAAD5,
    0x403BAA7B,
    0x403E8695,
    0x4027C768,
)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action", choices=("apply", "revert", "check-two-pass", "check-occupancy")
    )
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    return parser.parse_args()


def classify(actual: bytes, patch: Patch) -> str:
    if actual == patch.before:
        return "two-pass"
    if actual == patch.after:
        return "occupancy"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
        f"{actual.hex()}"
    )


def require_foundation(transport: AocFactoryDiag) -> None:
    base_by_address = {patch.address: patch for patch in BASE_PATCHES}
    for address in FOUNDATION_ADDRESSES:
        patch = base_by_address[address]
        actual = transport.dump(address, len(patch.after))
        if actual != patch.after:
            raise ValueError(
                f"192 kHz foundation is missing {patch.name} at "
                f"0x{address:08x}: {actual.hex()}"
            )
    for patch in REPACK_PATCHES:
        actual = transport.dump(patch.address, len(patch.after))
        if actual != patch.after:
            raise ValueError(
                f"grown-ring repacker is missing {patch.name} at "
                f"0x{patch.address:08x}: {actual.hex()}"
            )
    print("verified native-192 foundation and grown-ring repacker")


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
    require_d12_idle(transport)
    require_all_capture_idle(transport)
    capture_modes: list[tuple[str, str]] | None = None
    if args.action in ("apply", "revert"):
        capture_modes = block_capture_opens(transport)
        require_all_capture_idle(transport)
    require_foundation(transport)
    require_resized_idle_geometry(transport)

    states: list[str] = []
    for patch in PATCHES:
        actual = transport.dump(patch.address, len(patch.before))
        state = classify(actual, patch)
        states.append(state)
        print(f"{state:9s} 0x{patch.address:08x} {patch.name}")

    if args.action.startswith("check-"):
        wanted = args.action.removeprefix("check-")
        if any(state != wanted for state in states):
            raise ValueError(f"D12 drain is not uniformly {wanted}")
        return 0

    wanted = "occupancy" if args.action == "apply" else "two-pass"
    if all(state == wanted for state in states):
        if capture_modes is not None:
            restore_capture_modes(transport, capture_modes)
        print(f"D12 drain is already uniformly {wanted}")
        return 0

    patch_states = list(zip(PATCHES, states, strict=True))
    if args.action == "revert":
        patch_states.reverse()
    for patch, state in patch_states:
        if state == wanted:
            continue
        source = patch.before if args.action == "apply" else patch.after
        destination = patch.after if args.action == "apply" else patch.before
        write_changed_chunks(transport, patch, source, destination)

    for patch in PATCHES:
        expected = patch.after if args.action == "apply" else patch.before
        actual = transport.dump(patch.address, len(expected))
        if actual != expected:
            raise RuntimeError(
                f"verification failed at 0x{patch.address:08x}: "
                f"got {actual.hex()}, expected {expected.hex()}"
            )
    if capture_modes is not None:
        restore_capture_modes(transport, capture_modes)
    print(
        f"verified uniformly {wanted}; changes are volatile and disappear on "
        "AoC/device reboot"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
