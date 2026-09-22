#!/usr/bin/env python3
"""Guard the post-resize Frankel D12 192-frame ring-output repacker."""

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
REPACK_CAVE = bytes.fromhex(
    "00" * 3
    + "36410062211662069066761a42211440449090441162a6003221126aa34ab3cd"
    + "04810eeee008001df0"
    + "00" * 7
)

DMA_RING_TOTAL = 0xC00
US_RING_TOTAL = 0x3000
CAPACITY_CHECK_GROWN = bytes.fromhex("3e0a31719081")
BASE_ADVANCE_REGION = bytes.fromhex("00" * 6 + "21e3fd862500" + "00" * 2)
REPACK_ADVANCE_REGION = bytes.fromhex("e5b23b21e3fd462600" + "00" * 5)

PATCHES = (
    Patch(
        "replace the full-ring sync trampoline with a direct literal load",
        0x403E882D,
        bytes.fromhex("061737f02000"),
        bytes.fromhex("403490c13146"),
    ),
    Patch(
        "replace the retired sync/scratch region with the ring-8 repacker",
        0x403F648D,
        FULL_SYNC_CAVE,
        REPACK_CAVE,
    ),
    Patch(
        "call the repacker and force a 0xc00-byte stream-8 commit",
        0x403BA962,
        BASE_ADVANCE_REGION,
        REPACK_ADVANCE_REGION,
    ),
    Patch(
        "call the post-tap ring-8 repacker before the resized-ring commit",
        0x403BACB8,
        bytes.fromhex("062bff"),
        bytes.fromhex("8629ff"),
    ),
)


FOUNDATION_ADDRESSES = (
    0x403F0C44,  # two-pass Fullband drain
    0x403F0C70,  # doubled invocation-count period geometry
    0x403B8880,  # native 192-frame PDM callback
    0x403B88DD,  # native 192 kHz output rate
    0x403B88FE,  # native 192-frame bookkeeping
    0x403BA0F4,  # explicit 0xc00-byte full-ring literal
    0x403BAAD5,  # 192-frame fanout quantum before post-tap repack
    0x403E867E,  # period-geometry hook
    0x4027C768,  # two-pass drain callback
)
MEMMOVE_LITERAL_ADDRESS = 0x403F1CEC
MEMMOVE_LITERAL = bytes.fromhex("90674840")


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description=(
            "Guard the grown-MIC_US native-192 D12 ring-output layout repacker"
        )
    )
    parser.add_argument(
        "action", choices=("apply", "revert", "check-full", "check-repacked")
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
        return "full"
    if actual == patch.after:
        return "repacked"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
        f"{actual.hex()}"
    )


def require_foundation(transport: AocFactoryDiag) -> None:
    by_address = {patch.address: patch for patch in BASE_PATCHES}
    for address in FOUNDATION_ADDRESSES:
        patch = by_address[address]
        actual = transport.dump(address, len(patch.after))
        if actual != patch.after:
            raise ValueError(
                f"native-192 foundation is missing {patch.name} at "
                f"0x{address:08x}: {actual.hex()}"
            )
    literal = transport.dump(MEMMOVE_LITERAL_ADDRESS, len(MEMMOVE_LITERAL))
    if literal != MEMMOVE_LITERAL:
        raise ValueError(
            f"memmove literal changed at 0x{MEMMOVE_LITERAL_ADDRESS:08x}: "
            f"{literal.hex()}"
        )
    print("verified native-192/two-pass foundation and memmove literal")


def require_resized_idle_geometry(transport: AocFactoryDiag) -> None:
    """Validate the committed rings without requiring reset cursor parity."""

    capacity = transport.dump(CAPACITY_CHECK_ADDRESS, len(CAPACITY_CHECK_GROWN))
    if capacity != CAPACITY_CHECK_GROWN:
        raise ValueError(
            "ultrasonic capacity assertion is not coupled to the 0x3000 "
            "MIC_US ring: "
            + capacity.hex()
        )

    backings: list[tuple[int, int]] = []
    for name, ring in ring_objects(transport):
        vtable = struct.unpack("<I", transport.dump(ring, 4))[0]
        if vtable != 0x40359C38:
            raise ValueError(f"{name} has unexpected vtable 0x{vtable:08x}")
        backing = struct.unpack("<I", transport.dump(ring + 0x40, 4))[0]
        state = struct.unpack("<I", transport.dump(ring + 0x44, 4))[0]
        if state != ring + 0x9C:
            raise ValueError(f"{name} descriptor 0x{state:08x} != object+0x9c")
        if backing & 0x3F:
            raise ValueError(f"{name} backing is not 64-byte aligned")
        if name == "MIC_DMA_RING" and backing != ring + 0x178:
            raise ValueError(
                "MIC_DMA_RING no longer has its stock inline backing: "
                f"0x{backing:08x}"
            )
        words = struct.unpack("<IIIII", transport.dump(state, 20))
        total = DMA_RING_TOTAL if name == "MIC_DMA_RING" else US_RING_TOTAL
        if words[1] != total or words[3] != total:
            raise ValueError(
                f"{name} does not retain 0x{total:x} end/size geometry: "
                + ",".join(f"0x{word:x}" for word in words)
            )
        for cursor_name, cursor in (("write", words[0]), ("read", words[2])):
            if cursor % 0xC00 or cursor >= total:
                raise ValueError(
                    f"{name} idle {cursor_name} cursor is not on a native-block "
                    f"boundary: 0x{cursor:x}"
                )
        for reader_offset in (0x48, 0x58, 0x68, 0x78, 0x88):
            guard = struct.unpack(
                "<I", transport.dump(ring + reader_offset + 8, 4)
            )[0]
            if guard != 0xA5A5A500:
                raise ValueError(
                    f"{name} reader +0x{reader_offset:x} remains active or "
                    f"changed: 0x{guard:08x}"
                )
        backings.append((backing, total))
        print(
            f"{name}: idle geometry 0x{total:x} verified "
            f"(write=0x{words[0]:x}, read=0x{words[2]:x}, "
            f"byte_counter=0x{words[4]:x})"
        )
    if max(backings[0][0], backings[1][0]) < min(
        backings[0][0] + backings[0][1],
        backings[1][0] + backings[1][1],
    ):
        raise ValueError("MIC_DMA and MIC_US backings overlap")

    # The exact 51-byte patch classification below covers the old allocator
    # scratch word.  FULL_SYNC_CAVE requires it to be zero before apply, while
    # REPACK_CAVE requires the exact executable bytes before check/revert.
    print("verified inactive readers and independent non-overlapping backings")


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
        # The three-byte live hook requires two factory-diag writes.  Block all
        # card-0 capture opens before any preflight or mutation, and leave the
        # nodes fail-closed on every exception or interrupted transition.
        capture_modes = block_capture_opens(transport)
        require_all_capture_idle(transport)
    require_foundation(transport)
    require_resized_idle_geometry(transport)

    states: list[str] = []
    for patch in PATCHES:
        actual = transport.dump(patch.address, len(patch.before))
        state = classify(actual, patch)
        states.append(state)
        print(f"{state:8s} 0x{patch.address:08x} {patch.name}")

    if args.action.startswith("check-"):
        wanted = args.action.removeprefix("check-")
        if any(state != wanted for state in states):
            raise ValueError(f"ring-output repacker is not uniformly {wanted}")
        return 0

    wanted = "repacked" if args.action == "apply" else "full"
    if all(state == wanted for state in states):
        if capture_modes is not None:
            restore_capture_modes(transport, capture_modes)
        print(f"ring-output repacker is already uniformly {wanted}")
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
    print(
        f"verified uniformly {wanted}; changes are volatile and disappear on "
        "AoC/device reboot"
    )
    if capture_modes is not None:
        restore_capture_modes(transport, capture_modes)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
