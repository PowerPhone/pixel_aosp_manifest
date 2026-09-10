#!/usr/bin/env python3
"""Guardedly disconnect the superseded dual-0x1800 D12 repacker."""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import struct
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_d12_192k import (
    PATCHES as BASE_PATCHES,
    require_d12_idle,
    write_changed_chunks,
)
from trigger_frankel_aoc_d12_ring_resize import (
    CAPACITY_CHECK_ADDRESS,
    CAPACITY_CHECK_RESIZED,
    block_capture_opens,
    require_all_capture_idle,
    restore_capture_modes,
    ring_objects,
)


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    address: int
    before: bytes
    after: bytes


FULL_SYNC_CAVE = bytes.fromhex(
    "403490c2a600f0cc1128a2e00200c6e6c8" + "00" * 34
)
LEGACY_REPACK_CAVE = bytes.fromhex(
    "00" * 3
    + "36410062211662069066761a42211440449090441162a6003221126aa34ab3cd"
    + "04810eeee008005221112225571df0"
    + "00"
)

PATCHES = (
    Patch(
        "legacy direct full-ring sync",
        0x403E882D,
        bytes.fromhex("061737f02000"),
        bytes.fromhex("403490c13146"),
    ),
    Patch(
        "legacy post-tap repacker cave",
        0x403F648D,
        FULL_SYNC_CAVE,
        LEGACY_REPACK_CAVE,
    ),
    Patch(
        "legacy post-tap repacker call",
        0x403BACB8,
        bytes.fromhex("062bff"),
        bytes.fromhex("657d3b"),
    ),
)

FOUNDATION_ADDRESSES = (
    0x403F0C44,
    0x403F0C70,
    0x403B8880,
    0x403B88DD,
    0x403B88FE,
    0x403BA0F4,
    0x403BAAD5,
    0x403E867E,
    0x4027C768,
)


def require_legacy_geometry(transport: AocFactoryDiag) -> None:
    """Accept only the retired single-allocation, dual-0x1800 layout."""

    capacity = transport.dump(CAPACITY_CHECK_ADDRESS, len(CAPACITY_CHECK_RESIZED))
    if capacity != CAPACITY_CHECK_RESIZED:
        raise ValueError(
            "legacy D12 capacity assertion is not 0x1800: " + capacity.hex()
        )
    backings: list[int] = []
    for name, ring in ring_objects(transport):
        vtable, backing, state = struct.unpack(
            "<III", transport.dump(ring, 4)
            + transport.dump(ring + 0x40, 8)
        )
        if vtable != 0x40359C38 or state != ring + 0x9C:
            raise ValueError(f"{name} is not the expected RingBufferStatic")
        if backing & 0x3F:
            raise ValueError(f"{name} backing is not 64-byte aligned")
        words = struct.unpack("<IIII", transport.dump(state, 16))
        if words[1] != 0x1800 or words[3] != 0x1800:
            raise ValueError(f"{name} is not a legacy 0x1800 ring")
        backings.append(backing)
    if backings[1] != backings[0] + 0x1800:
        raise ValueError("legacy dual-ring backings are not contiguous")
    print("verified retired contiguous dual-0x1800 ring geometry")


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check-legacy", "revert"))
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    return parser.parse_args()


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
    if args.action == "revert":
        capture_modes = block_capture_opens(transport)
        require_all_capture_idle(transport)

    base_by_address = {patch.address: patch for patch in BASE_PATCHES}
    for address in FOUNDATION_ADDRESSES:
        patch = base_by_address[address]
        actual = transport.dump(address, len(patch.after))
        if actual != patch.after:
            raise ValueError(
                f"legacy foundation is missing {patch.name} at "
                f"0x{address:08x}: {actual.hex()}"
            )
    require_legacy_geometry(transport)

    states: list[str] = []
    for patch in PATCHES:
        actual = transport.dump(patch.address, len(patch.before))
        if actual == patch.before:
            state = "full"
        elif actual == patch.after:
            state = "legacy"
        else:
            raise ValueError(
                f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
                f"{actual.hex()}"
            )
        states.append(state)
        print(f"{state:6s} 0x{patch.address:08x} {patch.name}")

    if args.action == "check-legacy":
        if any(state != "legacy" for state in states):
            raise ValueError("legacy repacker is not uniformly installed")
        return 0

    for patch, state in reversed(list(zip(PATCHES, states, strict=True))):
        if state == "full":
            continue
        write_changed_chunks(transport, patch, patch.after, patch.before)
    for patch in PATCHES:
        actual = transport.dump(patch.address, len(patch.before))
        if actual != patch.before:
            raise RuntimeError(
                f"legacy revert verification failed at 0x{patch.address:08x}: "
                f"{actual.hex()}"
            )
    if capture_modes is not None:
        restore_capture_modes(transport, capture_modes)
    print("legacy repacker reverted; allocation scratch region is safe to reuse")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
