#!/usr/bin/env python3
"""Switch Frankel D12 between native-192/two-pass and halfms96/cap-eight.

This volatile CP2A.260805.005 F1 transition is for a device whose MIC_DMA
ring remains the stock 0xc00 bytes and whose MIC_US ring has already been
grown to 0x3000 bytes.  The half-millisecond profile keeps the proven 6.4 MHz
PDM clock and 192 kHz output rate, but returns PdmV3 and fanout to one compact
96-frame block every 0.5 ms.  Fullband Ultrasonic drains every queued 0x600
byte half, up to the complete eight-half MIC_US ring per callback.

The stream-8 writer must not return to stock SizeGet()/2: that would advance
0x1800 bytes in the grown ring after writing only 0x600.  Both directions
therefore retain the explicit 0x403bacb8 -> 0x403ba968 advance hook and change
only its guarded literal between 0xc00 (native-192) and 0x600 (halfms96).
There is no ring-output repack/memmove in either classified state.

All mutations require idle capture paths.  Apply installs the no-sync helper
and cap-eight callback before changing producer geometry.  Revert restores
native producer geometry before disconnecting those helpers.  Any exception
after capture nodes are chmod 000 deliberately leaves them fail closed.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import struct
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_d12_occupancy_drain_192k import (
    PATCHES as OCCUPANCY_PATCHES,
)
from patch_frankel_aoc_d12_repack_192k import (
    BASE_ADVANCE_REGION,
    FULL_SYNC_CAVE,
)
from patch_frankel_aoc_live_d12_192k import (
    PATCHES as BASE_PATCHES,
    require_d12_idle,
    write_changed_chunks,
)
from trigger_frankel_aoc_d12_ring_resize import (
    CAPACITY_CHECK_ADDRESS,
    block_capture_opens,
    pointer,
    require_all_capture_idle,
    restore_capture_modes,
    ring_objects,
)


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    address: int
    full: bytes
    halfms: bytes


BASE_BY_ADDRESS = {patch.address: patch for patch in BASE_PATCHES}
OCCUPANCY_BY_ADDRESS = {patch.address: patch for patch in OCCUPANCY_PATCHES}


def base_transition(name: str, address: int, *, reverse: bool = False) -> Patch:
    patch = BASE_BY_ADDRESS[address]
    full, halfms = (
        (patch.before, patch.after) if reverse else (patch.after, patch.before)
    )
    return Patch(name, address, full, halfms)


def occupancy_transition(address: int) -> Patch:
    patch = OCCUPANCY_BY_ADDRESS[address]
    return Patch(patch.name, address, patch.before, patch.after)


# Apply leaf code first, connect the callback next, then change producer
# geometry.  Revert walks this tuple backward, restoring native geometry and
# the 0xc00 commit before it disconnects the cap-eight callback/helper.
PATCHES = (
    occupancy_transition(0x403E87D0),
    occupancy_transition(0x403F0C44),
    occupancy_transition(0x403E867E),
    Patch(
        "stream-8 explicit writer commit 0xc00 -> 0x600 bytes",
        0x403BA0F4,
        bytes.fromhex("000c0000"),
        bytes.fromhex("00060000"),
    ),
    base_transition(
        "fanout quantum 192 -> 96 frames for enum 7", 0x403BAAD5
    ),
    base_transition("native PDM callback quantum 192 -> 96 frames", 0x403B8880),
    base_transition(
        "native PDM bookkeeping quantum 192 -> 96 frames", 0x403B88FE
    ),
    base_transition(
        "native timestamp interval 1 ms -> 0.5 ms", 0x403BA544, reverse=True
    ),
    base_transition(
        "native timestamp diagnostic 1 ms -> 0.5 ms", 0x403BA585, reverse=True
    ),
)


MUTABLE_BASE_ADDRESSES = {
    0x403B8880,
    0x403B88FE,
    0x403BA0F4,
    0x403BA544,
    0x403BA585,
    0x403BAAD5,
    0x403E867E,
    0x403F0C44,
    0x403F0C70,
}

CAPACITY_CHECK_GROWN = bytes.fromhex("3e0a31719081")
RING_VTABLE = 0x40359C38
DMA_RING_TOTAL = 0xC00
US_RING_TOTAL = 0x3000
HALF_BYTES = 0x600

# These exact regions prove that neither direction contains the native-192
# repacker.  The stream-8 explicit advance code is embedded at +6 in the
# 0x403ba962 region and is deliberately shared by both profiles.
NO_REPACK_REGIONS = (
    (
        "retired sync/repacker cave",
        0x403F648D,
        FULL_SYNC_CAVE,
    ),
    (
        "stream-8 explicit-advance cave",
        0x403BA962,
        BASE_ADVANCE_REGION,
    ),
    (
        "stream-8 explicit-advance hook",
        0x403BACB8,
        bytes.fromhex("062bff"),
    ),
    (
        "full-input reader-sync hook",
        0x403E882D,
        bytes.fromhex("061737f02000"),
    ),
    (
        "stock pre-commit downstream notification",
        0x403BACB5,
        bytes.fromhex("e00800"),
    ),
    (
        "retired post-commit writer helper cave",
        0x403C1814,
        bytes(28),
    ),
    (
        "retired post-commit notify helper cave",
        0x403C1A34,
        bytes(28),
    ),
)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action", choices=("apply", "revert", "check-full", "check-halfms")
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
    if actual == patch.full:
        return "full"
    if actual == patch.halfms:
        return "halfms"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
        f"{actual.hex()} (full {patch.full.hex()}, halfms {patch.halfms.hex()})"
    )


def require_immutable_foundation(transport: AocFactoryDiag) -> None:
    """Require every full-profile site not owned by this transition."""

    for patch in BASE_PATCHES:
        if patch.address in MUTABLE_BASE_ADDRESSES:
            continue
        actual = transport.dump(patch.address, len(patch.after))
        if actual != patch.after:
            raise ValueError(
                f"native-192 foundation is missing {patch.name} at "
                f"0x{patch.address:08x}: {actual.hex()}"
            )

    for name, address, expected in NO_REPACK_REGIONS:
        actual = transport.dump(address, len(expected))
        if actual != expected:
            raise ValueError(
                f"{name} changed at 0x{address:08x}: {actual.hex()} "
                f"(expected {expected.hex()})"
            )
    print("verified immutable 6.4-MHz/192-kHz foundation and no-repack path")


def require_grown_idle_geometry(
    transport: AocFactoryDiag, cursor_quantum: int
) -> None:
    """Require idle stock MIC_DMA and independent eight-half MIC_US rings."""

    capacity = transport.dump(CAPACITY_CHECK_ADDRESS, len(CAPACITY_CHECK_GROWN))
    if capacity != CAPACITY_CHECK_GROWN:
        raise ValueError(
            "D12 setup is not coupled to the grown 0x3000 MIC_US ring: "
            + capacity.hex()
        )

    intervals: list[tuple[int, int, str]] = []
    for name, ring in ring_objects(transport):
        vtable = struct.unpack("<I", transport.dump(ring, 4))[0]
        if vtable != RING_VTABLE:
            raise ValueError(f"{name} has unexpected vtable 0x{vtable:08x}")
        backing = pointer(transport, ring + 0x40, f"{name} backing")
        state = pointer(transport, ring + 0x44, f"{name} descriptor")
        if state != ring + 0x9C:
            raise ValueError(f"{name} descriptor 0x{state:08x} != object+0x9c")
        words = struct.unpack("<IIIIIII", transport.dump(state, 28))
        total = DMA_RING_TOTAL if name == "MIC_DMA_RING" else US_RING_TOTAL
        if words[1] != total or words[3] != total:
            raise ValueError(
                f"{name} does not retain 0x{total:x} end/size geometry: "
                + ",".join(f"0x{word:x}" for word in words)
            )
        for cursor_name, cursor in (("write", words[0]), ("read", words[2])):
            if cursor % cursor_quantum or cursor >= total:
                raise ValueError(
                    f"{name} idle {cursor_name} cursor is not on a "
                    f"0x{cursor_quantum:x}-byte boundary: 0x{cursor:x}"
                )
        if backing & 0x3F:
            raise ValueError(f"{name} backing is not 64-byte aligned")
        if name == "MIC_DMA_RING" and backing != ring + 0x178:
            raise ValueError(
                "MIC_DMA_RING is not in its stock inline backing: "
                f"0x{backing:08x}"
            )
        if name == "MIC_US_RING" and backing == ring + 0x178:
            raise ValueError("MIC_US_RING still uses its undersized inline backing")
        for reader_offset in (0x48, 0x58, 0x68, 0x78, 0x88):
            guard = struct.unpack(
                "<I", transport.dump(ring + reader_offset + 8, 4)
            )[0]
            if guard != 0xA5A5A500:
                raise ValueError(
                    f"{name} reader +0x{reader_offset:x} remains active or "
                    f"changed: 0x{guard:08x}"
                )
        transport.dump(backing, 4)
        transport.dump(backing + total - 4, 4)
        intervals.append((backing, backing + total, name))
        print(
            f"{name}: idle backing=0x{backing:08x} total=0x{total:x} "
            f"write=0x{words[0]:x} read=0x{words[2]:x} "
            f"counter=0x{words[4]:x} generation=0x{words[6]:x}"
        )

    (dma_start, dma_end, _), (us_start, us_end, _) = intervals
    if max(dma_start, us_start) < min(dma_end, us_end):
        raise ValueError("MIC_DMA and MIC_US backings overlap")
    print("verified idle MIC_DMA=0xc00 and MIC_US=0x3000 geometry")


def read_states(transport: AocFactoryDiag) -> list[str]:
    states: list[str] = []
    for patch in PATCHES:
        actual = transport.dump(patch.address, len(patch.full))
        state = classify(actual, patch)
        states.append(state)
        print(f"{state:6s} 0x{patch.address:08x} {patch.name}")
    return states


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

    require_immutable_foundation(transport)
    states = read_states(transport)
    # Native-192 writes a contiguous 0xc00 bytes.  Require a c00-aligned idle
    # cursor before either live transition so a stale halfms cursor can never
    # make a native block cross the end of the non-mirrored static backing.
    # Read-only or idempotent halfms checks may observe any valid 0x600-byte
    # cursor; a real apply from full/mixed code still requires c00 alignment.
    cursor_quantum = (
        HALF_BYTES
        if args.action == "check-halfms"
        or (args.action == "apply" and all(state == "halfms" for state in states))
        else DMA_RING_TOTAL
    )
    require_grown_idle_geometry(transport, cursor_quantum)

    if args.action.startswith("check-"):
        wanted = args.action.removeprefix("check-")
        if any(state != wanted for state in states):
            raise ValueError(f"composite D12 profile is not uniformly {wanted}")
        return 0

    wanted = "halfms" if args.action == "apply" else "full"
    if all(state == wanted for state in states):
        if capture_modes is not None:
            restore_capture_modes(transport, capture_modes)
        print(f"composite D12 profile is already uniformly {wanted}")
        return 0

    patch_states = list(zip(PATCHES, states, strict=True))
    if args.action == "revert":
        patch_states.reverse()
    for patch, state in patch_states:
        if state == wanted:
            continue
        source = patch.full if args.action == "apply" else patch.halfms
        destination = patch.halfms if args.action == "apply" else patch.full
        write_changed_chunks(transport, patch, source, destination)

    require_immutable_foundation(transport)
    final_cursor_quantum = HALF_BYTES if wanted == "halfms" else DMA_RING_TOTAL
    require_grown_idle_geometry(transport, final_cursor_quantum)
    final_states = read_states(transport)
    if any(state != wanted for state in final_states):
        raise RuntimeError(f"verification did not reach uniformly {wanted}")

    if capture_modes is not None:
        restore_capture_modes(transport, capture_modes)
    print(
        f"verified uniformly {wanted}; MIC_DMA remains 0xc00, MIC_US remains "
        "0x3000, and changes disappear on AoC/device reboot"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
