#!/usr/bin/env python3
"""Switch Frankel D12 from two 96-frame passes to one mono 192-frame pass.

This volatile CP2A.260805.005 F1 transition requires the qualified
native-192/two-pass/no-repack profile and the independently grown 0x3000-byte
MIC_US ring.  It emits one 0x300-byte S32 mono block per millisecond, reducing
Fullband RingBufferHost commits and notifications from 2,000/s to 1,000/s.

The target is intentionally mono-only.  The Fullband constructor rejects a
channel count other than one, and the no-sync helper independently validates
the process descriptor's low three channel bits on every invocation.  A
bounded cap-four occupancy callback recovers coalesced producer notifications.

Both profiles point the callback table at 0x403f0c44, whose complete body is
rewritten by this transition.  Apply and revert therefore first redirect the
table to the untouched stock wrapper at 0x403e87d0.  Only after every cave and
instruction site verifies does the installer reconnect 0x403f0c44.  Capture
nodes stay chmod 000 across the whole transaction and remain fail-closed after
any exception or interruption.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable
import dataclasses
import pathlib
import struct
import sys
import time

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_d12_halfms96_grown_cap8 import (
    NO_REPACK_REGIONS,
    require_grown_idle_geometry,
)
from patch_frankel_aoc_d12_occupancy_drain_192k import (
    STOCK_CALLBACK,
    TWO_PASS_AND_PERIOD,
)
from patch_frankel_aoc_d12_repack_192k import FULL_SYNC_CAVE
from patch_frankel_aoc_live_d12_192k import (
    PATCHES as BASE_PATCHES,
    PROFILE_EXCLUDED_ADDRESSES,
    require_d12_idle,
    write_changed_chunks,
)
from trigger_frankel_aoc_d12_ring_resize import (
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
    wholeblock: bytes


def padded(code: str, size: int) -> bytes:
    value = bytes.fromhex(code)
    if len(value) > size:
        raise ValueError(f"code is {len(value)} bytes, exceeds {size}-byte cave")
    return value + bytes(size - len(value))


MONO_CONSTRUCTOR_GUARD = bytes.fromhex("ff10751007008014")
NO_SYNC_MONO_HELPER = padded(
    "00000036410042030040402466140a5d0262d50840349086e4c81df0", 51
)
WHOLEBLOCK_CALLBACK = bytes.fromhex(
    "364100fc230c456204078c96a2224f880a82281ce00800"
    "612625a2224f880a822810b2d208b8abe00800673a0bad02"
    "bd04a581050b555605fe1df000"
)

# Apply restores stock period geometry before replacing the old period cave,
# then installs the new helper and leaf sites, and writes the disconnected
# callback last.  Revert walks this tuple backward: it restores the callback
# (including its period helper) first and reconnects the period hook last.
PATCHES = (
    Patch(
        "restore one-invocation Fullband period geometry",
        0x403E867E,
        bytes.fromhex("867b21f02000"),
        bytes.fromhex("7ef3bc0f0771"),
    ),
    Patch(
        "replace the full-sync hook with an inline 0xc00 ReaderSync count",
        0x403E882D,
        bytes.fromhex("061737f02000"),
        bytes.fromhex("403490c13146"),
    ),
    Patch(
        "replace the retired full-sync cave with guarded mono no-sync helper",
        0x403F648D,
        FULL_SYNC_CAVE,
        NO_SYNC_MONO_HELPER,
    ),
    Patch(
        "restrict Fullband construction to exactly one channel",
        0x403E872D,
        bytes.fromhex("ff52711107008014"),
        MONO_CONSTRUCTOR_GUARD,
    ),
    Patch(
        "double mono output bytes from 0x180 to 0x300",
        0x403E877D,
        bytes.fromhex("907711"),
        bytes.fromhex("807711"),
    ),
    Patch(
        "double the scalar copy loop from 96 to 192 mono frames",
        0x403E883A,
        bytes.fromhex("aee5bc8e1b93"),
        bytes.fromhex("aee5b88e1b93"),
    ),
    Patch(
        "advance the Fullband input reader by one 0xc00-byte native block",
        0x403E886A,
        bytes.fromhex("4e1530030087"),
        bytes.fromhex("42d508c12146"),
    ),
    Patch(
        "replace two-pass callback and period cave with cap-four whole blocks",
        0x403F0C44,
        TWO_PASS_AND_PERIOD,
        WHOLEBLOCK_CALLBACK,
    ),
)

CALLBACK_TABLE_ADDRESS = 0x4027C768
CALLBACK_TWO_PASS = bytes.fromhex("440c3f40")
CALLBACK_STOCK = bytes.fromhex("d0873e40")

FULLBAND_OBJECT = 0x4059F2D8
FULLBAND_VTABLE = 0x4027C738
FULLBAND_INPUT = 0x40552988
FULLBAND_OUTPUT = 0x404D2E20
OUTPUT_VTABLE = 0x4036F660
OUTPUT_WAKE_THRESHOLD_BYTES = 0x1E00
OUTPUT_DESCRIPTOR_OFFSET = 0xBC
OUTPUT_BASE_COMPONENT_OFFSET = 0xC4
OUTPUT_DESCRIPTOR_CAPACITY = 0x16800
MONO_BLOCK_BYTES = 0x300
NATIVE_BLOCK_BYTES = 0xC00
FULLBAND_MINIMUM_OUTPUT_BYTES = 0x7800

# Full-profile sites owned by this transition or by its exact no-repack
# prerequisite.  All other base sites must remain in the qualified "full"
# state, including the stock pre-commit notification behavior.
OWNED_BASE_ADDRESSES = frozenset(
    (0x403E867E, 0x403F0C44, 0x403F0C70, 0x403F648D, 0x403E882D, 0x4027C768)
)

STATIC_PRECONDITIONS = (
    (
        "Fullband constructor channel/output prefix",
        0x403E8770,
        bytes.fromhex("720308ad0488042e123c9d0bb7"),
    ),
    (
        "Fullband constructor output store and capacity product",
        0x403E8780,
        bytes.fromhex(
            "79c2722813e007002e82b0150e71f2051d402282f022823df0273a216ec3"
            "c82102d14ee3c80400811df0"
        ),
    ),
    ("untouched stock callback wrapper", 0x403E87D0, STOCK_CALLBACK),
    (
        "Fullband process preamble",
        0x403E87FC,
        bytes.fromhex(
            "364100420300404024ff585a0441488617f203078cefa2254f280a22221c"
            "f020003df0e002006e1538960765b8a6222a00"
        ),
    ),
    (
        "post-sync virtual call tail",
        0x403E8833,
        bytes.fromhex("28a23df0e00200"),
    ),
    (
        "scalar S32 scratch-copy body",
        0x403E8840,
        bytes.fromhex(
            "280ab8a6222214e002009e040df3d082fa350e37ca00088fae8a20290061"
            "2044104e13ad0c0221a2254f"
        ),
    ),
    (
        "output memcpy/cache/commit/notify tail",
        0x403E8870,
        bytes.fromhex(
            "280ab8a628e2e0020022d50822023416d2053e1538160865280a2ee2a2b1"
            "0083e002004ec5a14f96612d0a81a922e00800be83b8080dc981b047e008"
            "00c02000a22550480ab8c3422406f02000e00400aee5a24f1661ee010c03"
            "e080bd02811a44e00800"
        ),
    ),
    (
        "first live word after the 60-byte callback cave",
        0x403F0C80,
        bytes.fromhex("a0583640"),
    ),
    (
        "Fullband output RingBufferHost consumer ABI",
        0x403E8A2C,
        bytes.fromhex("ae06ae1e156b5024c0f80af02000322f10e00300"),
    ),
)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action", choices=("apply", "revert", "check-full", "check-wholeblock")
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
    if actual == patch.wholeblock:
        return "wholeblock"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
        f"{actual.hex()} (full {patch.full.hex()}, wholeblock "
        f"{patch.wholeblock.hex()})"
    )


def callback_state(transport: AocFactoryDiag) -> str:
    actual = transport.dump(CALLBACK_TABLE_ADDRESS, 4)
    if actual == CALLBACK_TWO_PASS:
        return "connected"
    if actual == CALLBACK_STOCK:
        return "quarantined"
    raise ValueError(
        f"unexpected callback table at 0x{CALLBACK_TABLE_ADDRESS:08x}: "
        f"{actual.hex()}"
    )


def read_states(transport: AocFactoryDiag) -> tuple[list[str], str]:
    states: list[str] = []
    for patch in PATCHES:
        actual = transport.dump(patch.address, len(patch.full))
        state = classify(actual, patch)
        states.append(state)
        print(f"{state:10s} 0x{patch.address:08x} {patch.name}")
    table = callback_state(transport)
    print(f"{table:10s} 0x{CALLBACK_TABLE_ADDRESS:08x} callback table")
    return states, table


def checked_patch(
    transport: AocFactoryDiag, patch: Patch, source: bytes, destination: bytes
) -> None:
    actual = transport.dump(patch.address, len(source))
    if actual != source:
        raise ValueError(
            f"{patch.name}: changed before write at 0x{patch.address:08x}: "
            f"{actual.hex()}"
        )
    write_changed_chunks(transport, patch, source, destination)
    actual = transport.dump(patch.address, len(destination))
    if actual != destination:
        raise RuntimeError(
            f"{patch.name}: verification failed at 0x{patch.address:08x}: "
            f"{actual.hex()}"
        )


def set_callback_quarantine(transport: AocFactoryDiag, quarantine: bool) -> None:
    source, destination, name = (
        (CALLBACK_TWO_PASS, CALLBACK_STOCK, "quarantine Fullband callback")
        if quarantine
        else (CALLBACK_STOCK, CALLBACK_TWO_PASS, "reconnect Fullband callback")
    )
    patch = Patch(name, CALLBACK_TABLE_ADDRESS, source, destination)
    checked_patch(transport, patch, source, destination)


def transition_profile(
    transport: AocFactoryDiag,
    action: str,
    before_reconnect: Callable[[], None] | None = None,
) -> None:
    """Perform the hook-quarantined transition; usable by offline fake tests."""

    if action not in ("apply", "revert"):
        raise ValueError(f"invalid transition action: {action}")
    states, table = read_states(transport)
    wanted = "wholeblock" if action == "apply" else "full"
    if all(state == wanted for state in states) and table == "connected":
        print(f"D12 is already uniformly {wanted} with callback connected")
        return

    # Both stable profiles use the same table value.  Its temporary stock
    # target is a transaction marker and a safe callback while all capture
    # opens are blocked.  An interrupted transaction may already be here.
    if table == "connected":
        set_callback_quarantine(transport, True)

    patch_states = list(zip(PATCHES, states, strict=True))
    if action == "revert":
        patch_states.reverse()
    for patch, state in patch_states:
        if state == wanted:
            continue
        source = patch.full if action == "apply" else patch.wholeblock
        destination = patch.wholeblock if action == "apply" else patch.full
        checked_patch(transport, patch, source, destination)

    final_states, table = read_states(transport)
    if any(state != wanted for state in final_states):
        raise RuntimeError(f"transition did not reach uniformly {wanted}")
    if table != "quarantined":
        raise RuntimeError("callback table escaped quarantine during transition")
    if before_reconnect is not None:
        before_reconnect()
    set_callback_quarantine(transport, False)

    final_states, table = read_states(transport)
    if any(state != wanted for state in final_states) or table != "connected":
        raise RuntimeError(f"verification did not reach connected {wanted}")


def require_foundation(transport: AocFactoryDiag) -> None:
    full_excluded = PROFILE_EXCLUDED_ADDRESSES["full"]
    for patch in BASE_PATCHES:
        if patch.address in OWNED_BASE_ADDRESSES:
            continue
        expected = patch.before if patch.address in full_excluded else patch.after
        actual = transport.dump(patch.address, len(expected))
        if actual != expected:
            raise ValueError(
                f"native-192 full foundation is missing {patch.name} at "
                f"0x{patch.address:08x}: {actual.hex()}"
            )

    for name, address, expected in NO_REPACK_REGIONS:
        if address in (0x403E882D, 0x403F648D):
            # Both are owned and classified as ordered transition patches.
            continue
        actual = transport.dump(address, len(expected))
        if actual != expected:
            raise ValueError(
                f"{name} changed at 0x{address:08x}: {actual.hex()} "
                f"(expected {expected.hex()})"
            )

    for name, address, expected in STATIC_PRECONDITIONS:
        actual = transport.dump(address, len(expected))
        if actual != expected:
            raise ValueError(
                f"{name} changed at 0x{address:08x}: {actual.hex()} "
                f"(expected {expected.hex()})"
            )

    if MONO_BLOCK_BYTES > 0x81C - 0x21C:
        raise AssertionError("mono scratch copy crosses Fullband metadata")
    if 0x403F0C44 + len(WHOLEBLOCK_CALLBACK) != 0x403F0C80:
        raise AssertionError("whole-block callback crosses its reviewed cave")
    print("verified exact native-192/no-repack and Fullband static ABI")


def require_fullband_runtime(transport: AocFactoryDiag) -> tuple[int, ...]:
    vtable = struct.unpack("<I", transport.dump(FULLBAND_OBJECT, 4))[0]
    if vtable != FULLBAND_VTABLE:
        raise ValueError(f"Fullband vtable changed: 0x{vtable:08x}")

    input_ring = pointer(transport, FULLBAND_OBJECT + 0x13C, "Fullband input")
    output_ring = pointer(transport, FULLBAND_OBJECT + 0x140, "Fullband output")
    if input_ring != FULLBAND_INPUT:
        raise ValueError(f"Fullband input changed: 0x{input_ring:08x}")
    if output_ring != FULLBAND_OUTPUT:
        raise ValueError(f"Fullband output changed: 0x{output_ring:08x}")

    rings = dict(ring_objects(transport))
    if rings.get("MIC_US_RING") != input_ring:
        raise ValueError("Fullband input is not the qualified MIC_US ring")
    output_vtable = struct.unpack("<I", transport.dump(output_ring, 4))[0]
    if output_vtable != OUTPUT_VTABLE:
        raise ValueError(f"output RingBufferHost vtable changed: 0x{output_vtable:08x}")
    wake_threshold = struct.unpack(
        "<I", transport.dump(output_ring + 0xC0, 4)
    )[0]
    if (
        wake_threshold != OUTPUT_WAKE_THRESHOLD_BYTES
        or wake_threshold % MONO_BLOCK_BYTES
    ):
        raise ValueError(
            "output wake threshold is not 0x1e00/0x300 compatible: "
            f"0x{wake_threshold:x}"
        )

    # RingBufferHost::GetWritePointer does not accept a requested length and
    # therefore cannot split a memcpy at the end of its shared ring.  Guard
    # the actual region-0 descriptor, not merely the +0xc0 wake threshold.
    # A 0x300-aligned writer in a capacity divisible by 0x300 can never make
    # the widened copy cross the ring end, even if an idle close retained a
    # small amount of unread data.
    descriptor = struct.unpack(
        "<I", transport.dump(output_ring + OUTPUT_DESCRIPTOR_OFFSET, 4)
    )[0]
    if not 0x80000000 <= descriptor < 0xC0000000 or descriptor & 0x3F:
        raise ValueError(
            "output shared descriptor is outside the aligned host window: "
            f"0x{descriptor:08x}"
        )
    descriptor_bytes = transport.dump(descriptor, 0x40)
    if descriptor_bytes[:0x20].split(b"\0", 1)[0] != b"ultrasonic_capture":
        raise ValueError("output shared descriptor name changed")
    (
        flags,
        descriptor_base,
        capacity,
        enabled,
        writer_total,
        reader_total,
        writer_cursor,
        reader_cursor,
    ) = struct.unpack_from("<IIIIIIII", descriptor_bytes, 0x20)
    object_base = struct.unpack(
        "<I", transport.dump(output_ring + OUTPUT_BASE_COMPONENT_OFFSET, 4)
    )[0]
    if flags & 0x70000 != 0x10000:
        raise ValueError(f"output shared-ring mode changed: 0x{flags:08x}")
    write_base = descriptor_base + object_base
    if (
        not descriptor_base
        or not object_base
        or write_base > 0xFFFFFFFF - capacity
        or not 0x80000000 <= write_base < 0xC0000000
        or write_base + capacity > 0xC0000000
        or write_base & 0x3F
    ):
        raise ValueError(
            "output shared-ring base components are missing or unaligned: "
            f"0x{descriptor_base:08x}+0x{object_base:08x}"
        )
    if (
        capacity != OUTPUT_DESCRIPTOR_CAPACITY
        or capacity % MONO_BLOCK_BYTES
        or capacity % wake_threshold
    ):
        raise ValueError(
            "output shared-ring capacity is not 0x16800/0x300 compatible: "
            f"0x{capacity:x}"
        )
    if enabled != 1:
        raise ValueError(
            f"output shared-ring region 0 byte-unit enable changed: {enabled}"
        )
    if writer_cursor >= capacity or reader_cursor >= capacity:
        raise ValueError(
            "output shared-ring cursor is outside its capacity: "
            f"0x{writer_cursor:x}/0x{reader_cursor:x}"
        )
    if writer_total % capacity != writer_cursor or reader_total % capacity != reader_cursor:
        raise ValueError("output shared-ring totals and modulo cursors disagree")
    if writer_cursor % MONO_BLOCK_BYTES or reader_cursor % MONO_BLOCK_BYTES:
        raise ValueError(
            "output shared-ring is not on a 0x300-byte boundary: "
            f"0x{writer_cursor:x}/0x{reader_cursor:x}"
        )
    queued = (writer_total - reader_total) & 0xFFFFFFFF
    if queued > capacity:
        raise ValueError(f"output shared ring is overcommitted by 0x{queued:x} bytes")
    free = capacity - queued
    if queued % MONO_BLOCK_BYTES or free < MONO_BLOCK_BYTES:
        raise ValueError(
            "output shared-ring occupancy cannot accept a complete 0x300-byte "
            f"write: queued=0x{queued:x} free=0x{free:x}"
        )
    transport.dump(write_base, 4)
    transport.dump(write_base + capacity - 4, 4)

    period_count, invocation_count, process_counter = transport.dump(
        FULLBAND_OBJECT + 0x81C, 3
    )
    write_size = struct.unpack(
        "<I", transport.dump(FULLBAND_OBJECT + 0x830, 4)
    )[0]
    approved = ((0x180, 20), (MONO_BLOCK_BYTES, 10))
    if (write_size, invocation_count) not in approved:
        raise ValueError(
            "Fullband idle write-size/invocation state is not a qualified "
            f"pre/post-open pair: 0x{write_size:x}/{invocation_count}"
        )
    if (
        period_count != 4
        or process_counter > period_count * invocation_count
    ):
        raise ValueError(
            f"Fullband runtime bytes +0x81c changed: "
            f"{period_count},{invocation_count},{process_counter}"
        )
    if write_size * invocation_count != wake_threshold:
        raise ValueError("Fullband write-size/invocation product is not 0x1e00")
    if wake_threshold * period_count != FULLBAND_MINIMUM_OUTPUT_BYTES:
        raise ValueError("Fullband minimum output requirement is not 0x7800")
    print(
        "Fullband runtime: mono state "
        f"write=0x{write_size:x} invocations={invocation_count} "
        f"wake=0x{wake_threshold:x} shared_capacity=0x{capacity:x} "
        f"writer=0x{writer_cursor:x} reader=0x{reader_cursor:x} "
        f"queued=0x{queued:x} free=0x{free:x} minimum=0x7800"
    )
    return (
        descriptor,
        flags,
        descriptor_base,
        object_base,
        capacity,
        enabled,
        writer_total,
        reader_total,
        writer_cursor,
        reader_cursor,
        wake_threshold,
        period_count,
        invocation_count,
        process_counter,
        write_size,
    )


def require_quiescent_fullband_runtime(transport: AocFactoryDiag) -> None:
    """Prove no old 0x180-byte callback can race the widened writer."""

    first = require_fullband_runtime(transport)
    time.sleep(0.05)
    second = require_fullband_runtime(transport)
    if first != second:
        raise RuntimeError(
            "Fullband/output state moved while the callback table was "
            "quarantined; leave capture nodes blocked and retry only after "
            "the old worker is quiescent"
        )
    print("Fullband/output state is unchanged across quarantined snapshots")


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
    require_grown_idle_geometry(transport, NATIVE_BLOCK_BYTES)

    if args.action.startswith("check-"):
        require_fullband_runtime(transport)
        wanted = args.action.removeprefix("check-")
        states, table = read_states(transport)
        if any(state != wanted for state in states) or table != "connected":
            raise ValueError(f"D12 is not uniformly connected {wanted}")
        return 0

    states, table = read_states(transport)
    wanted = "wholeblock" if args.action == "apply" else "full"
    transition_needed = not (
        all(state == wanted for state in states) and table == "connected"
    )
    if transition_needed:
        if table == "connected":
            set_callback_quarantine(transport, True)
        require_quiescent_fullband_runtime(transport)
    else:
        require_fullband_runtime(transport)

    transition_profile(
        transport,
        args.action,
        before_reconnect=(
            lambda: require_quiescent_fullband_runtime(transport)
            if transition_needed
            else None
        ),
    )
    require_foundation(transport)
    require_grown_idle_geometry(transport, NATIVE_BLOCK_BYTES)
    require_fullband_runtime(transport)
    states, table = read_states(transport)
    if any(state != wanted for state in states) or table != "connected":
        raise RuntimeError(f"postflight did not retain connected {wanted}")

    if capture_modes is not None:
        restore_capture_modes(transport, capture_modes)
    print(
        f"verified connected {wanted}; mono-only changes are volatile and "
        "disappear on AoC/device reboot"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
