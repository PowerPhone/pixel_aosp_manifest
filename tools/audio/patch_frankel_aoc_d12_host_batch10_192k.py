#!/usr/bin/env python3
"""Install the guarded Frankel D12 10-ms Fullband host-batching overlay.

The prerequisite is the exact whole-block mono-192 profile: one physical
192-frame/0x300-byte S32 mono block is produced each millisecond and the
MIC_US input ring retains its cap-four catch-up callback.  This overlay stages
ten native blocks, then cache-cleans, advances and notifies one fixed 0x1e00
byte RingBufferHost batch.  The audio remains 192 kHz; only host wake traffic
falls from 1000 to 100 events per second.

This is a volatile, build-specific CP2A.260805.005 F1 patch.  Mutating actions
block every card-0 capture node, require all capture PCMs closed, redirect the
cap-four callback to an inert entry, prove quiescence, and leave capture nodes
chmod 000 after any failure.  Apply/revert also normalize the closed output
descriptor and explicitly zero pending state before reconnecting cap four.

The start hook clears pending count/base before publishing each new open as
active.  A close may intentionally discard a final partial 1..9 ms batch; it
cannot splice that stale state into the next open.  Do not use period sizes
other than the qualified 0x300-byte/10-invocation p1920 geometry.
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
import patch_frankel_aoc_d12_wholeblock_mono_192k as wholeblock
from patch_frankel_aoc_d12_halfms96_grown_cap8 import require_grown_idle_geometry
from patch_frankel_aoc_live_d12_192k import require_d12_idle, write_changed_chunks
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
    wholeblock: bytes
    batch10: bytes


@dataclasses.dataclass(frozen=True)
class OutputState:
    descriptor: int
    flags: int
    descriptor_base: int
    object_base: int
    capacity: int
    enabled: int
    writer_total: int
    reader_total: int
    writer_cursor: int
    reader_cursor: int
    wake_threshold: int
    period_count: int
    invocation_count: int
    process_counter: int
    write_size: int

    @property
    def queued(self) -> int:
        return (self.writer_total - self.reader_total) & 0xFFFFFFFF

    @property
    def free(self) -> int:
        return self.capacity - self.queued

    @property
    def write_base(self) -> int:
        return self.descriptor_base + self.object_base


ZERO28 = bytes(28)
ZERO20 = bytes(20)

WHOLEBLOCK_HELPER = wholeblock.NO_SYNC_MONO_HELPER
START_RESET_HELPER = bytes.fromhex(
    "36410079567966c020000c144246341df0000000"
)
START_HOOK_STOCK = bytes.fromhex("5e8eca440081")
START_HOOK_BATCH10 = bytes.fromhex("25f7b522a001")

# At count ten the tail passes 3*count=30 in caller a13, which call8 maps to A
# a5.  A and B each shift that guarded value by eight.  This retains the inert
# entry's required four-byte alignment at +0x14 without loading output+0xc0.
FLUSH_AND_INERT = bytes.fromhex(
    "364100ad0380b51181d3e3e00800c02000c68200"
    "3641001df0000000"
)
ADVANCE_AND_NOTIFY = bytes.fromhex(
    "680462260680b511ad04e00600cd04ad02bd0325a6341df000000000"
)
NO_SYNC_AND_NOTIFY = bytes.fromhex(
    "0000003641004203004040246614095d0262d5080c33c6e4c81df0"
    "364100a22277bd031cec80cc110c1e0c0fa5e88e1df00000"
)

WHOLEBLOCK_OUTPUT_TAIL = bytes.fromhex(
    "16d2053e1538160865280a2ee2a2b10083e002004ec5a14f96612d0a81a922e0"
    "0800be83b8080dc981b047e00800c02000a22550480ab8c3422406f02000e0040"
    "0aee5a24f1661ee010c03e080bd02811a44e00800"
)
BATCH10_OUTPUT_TAIL = bytes.fromhex(
    "566200295629668615007856dc07a22550480a422417e004002d0a296616120328"
    "6670479080441140a28042a21c40b580c2a30081a322e008001b77795666971070"
    "d7900c077956ad05bd02c2255065f4d8603620"
)

PATCH_FLUSH = Patch(
    "install fixed-0x1e00 flush helper and inert callback",
    0x403C1814,
    ZERO28,
    FLUSH_AND_INERT,
)
PATCH_START_RESET = Patch(
    "install ordered per-open pending-state reset helper",
    0x4039E4FC,
    ZERO20,
    START_RESET_HELPER,
)
PATCH_ADVANCE = Patch(
    "install fixed-0x1e00 advance/notify ABI wrapper",
    0x403C1A34,
    ZERO28,
    ADVANCE_AND_NOTIFY,
)
PATCH_HELPERS = Patch(
    "replace whole-block helper and add fixed-0x1e00 notify helper",
    0x403F648D,
    WHOLEBLOCK_HELPER,
    NO_SYNC_AND_NOTIFY,
)
PATCH_TAIL = Patch(
    "batch ten 0x300-byte blocks with a NULL-safe output pointer",
    0x403E887F,
    WHOLEBLOCK_OUTPUT_TAIL,
    BATCH10_OUTPUT_TAIL,
)
PATCH_START_HOOK = Patch(
    "reset batch state before publishing a new Fullband open",
    0x403E8588,
    START_HOOK_STOCK,
    START_HOOK_BATCH10,
)

PATCHES = (
    PATCH_FLUSH,
    PATCH_START_RESET,
    PATCH_ADVANCE,
    PATCH_HELPERS,
    PATCH_TAIL,
    PATCH_START_HOOK,
)
APPLY_AFTER_QUARANTINE = (
    PATCH_START_RESET,
    PATCH_ADVANCE,
    PATCH_HELPERS,
    PATCH_TAIL,
    PATCH_START_HOOK,
)
REVERT_UNDER_QUARANTINE = (
    PATCH_START_HOOK,
    PATCH_TAIL,
    PATCH_HELPERS,
    PATCH_ADVANCE,
    PATCH_START_RESET,
)

CALLBACK_TABLE_ADDRESS = wholeblock.CALLBACK_TABLE_ADDRESS
CALLBACK_CAP4 = wholeblock.CALLBACK_TWO_PASS
CALLBACK_INERT = struct.pack("<I", 0x403C1828)

FULLBAND_OBJECT = wholeblock.FULLBAND_OBJECT
FULLBAND_INPUT = wholeblock.FULLBAND_INPUT
FULLBAND_OUTPUT = wholeblock.FULLBAND_OUTPUT
FULLBAND_VTABLE = wholeblock.FULLBAND_VTABLE
OUTPUT_VTABLE = wholeblock.OUTPUT_VTABLE
OUTPUT_DESCRIPTOR_OFFSET = wholeblock.OUTPUT_DESCRIPTOR_OFFSET
OUTPUT_BASE_COMPONENT_OFFSET = wholeblock.OUTPUT_BASE_COMPONENT_OFFSET
OUTPUT_CAPACITY = wholeblock.OUTPUT_DESCRIPTOR_CAPACITY
NATIVE_BLOCK_BYTES = wholeblock.NATIVE_BLOCK_BYTES
MONO_BLOCK_BYTES = wholeblock.MONO_BLOCK_BYTES
BATCH_BLOCKS = 10
BATCH_BYTES = BATCH_BLOCKS * MONO_BLOCK_BYTES
OUTPUT_MINIMUM_BYTES = wholeblock.FULLBAND_MINIMUM_OUTPUT_BYTES

PENDING_COUNT_ADDRESS = FULLBAND_OBJECT + 0x814
PENDING_BASE_ADDRESS = FULLBAND_OBJECT + 0x818
RUNTIME_BYTES_ADDRESS = FULLBAND_OBJECT + 0x81C
INACTIVE_STAT_ADDRESS = FULLBAND_OBJECT + 0x824
INPUT_READER_STAT_ADDRESS = FULLBAND_OBJECT + 0x828
WRITE_SIZE_ADDRESS = FULLBAND_OBJECT + 0x830
ACTIVE_ADDRESS = FULLBAND_OBJECT + 0x834

# Immutable instructions/data adjacent to every borrowed cave plus all
# indirect targets used by the overlay.  The start context proves caller
# a15=0 and a14=object+0x800 before the reset call8.
STATIC_GUARDS = (
    ("start-reset leading zeros", 0x4039E4FA, bytes(2)),
    ("first live start-reset successor", 0x4039E510,
     bytes.fromhex("36c1002e9259c790813e42be830081ee")),
    ("start-hook register proof", 0x403E8570,
     bytes.fromhex("4e12aa4120815e0108a1e7d07e22a0be0f8fee14084bd430")),
    ("start-hook continuation", 0x403E858E, bytes.fromhex("624306f243071df0")),
    ("first live word after A/inert cave", 0x403C1830, bytes.fromhex("3661009e")),
    ("first live word after B cave", 0x403C1A50, bytes.fromhex("366100ae")),
    ("first live word after no-sync/C cave", 0x403F64C0, bytes.fromhex("f0694840")),
    ("first live word after output tail", 0x403E88D4, bytes.fromhex("388322d5")),
    ("cache-clean literal", 0x403BA768, struct.pack("<I", 0x4038819C)),
    ("memcpy literal", 0x403B1340, struct.pack("<I", 0x404869F0)),
    ("cache-clean entry", 0x4038819C, bytes.fromhex("3641002e92bccc9dc981ecff")),
    ("memcpy entry", 0x404869F0, bytes.fromhex("36210020522007e2c617e2d8")),
    ("AdvanceWritePointer entry", 0x4040D954, bytes.fromhex("364100414ef70c1c0c0e5804")),
    ("GetWritePointer entry", 0x4040DE84, bytes.fromhex("3641003102f60c1c0c0e4803")),
    ("Notify entry", 0x40385344, bytes.fromhex("36a100bf1c5418650080148e")),
)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=(
            "apply",
            "revert",
            "check-batch10",
            "check-wholeblock",
            "normalize-idle",
        ),
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
    if actual == patch.wholeblock:
        return "wholeblock"
    if actual == patch.batch10:
        return "batch10"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
        f"{actual.hex()} (wholeblock {patch.wholeblock.hex()}, batch10 "
        f"{patch.batch10.hex()})"
    )


def callback_state(transport: AocFactoryDiag) -> str:
    actual = transport.dump(CALLBACK_TABLE_ADDRESS, 4)
    if actual == CALLBACK_CAP4:
        return "cap4"
    if actual == CALLBACK_INERT:
        return "inert"
    raise ValueError(
        f"unexpected Fullband callback pointer at 0x{CALLBACK_TABLE_ADDRESS:08x}: "
        f"{actual.hex()}"
    )


def read_states(transport: AocFactoryDiag) -> tuple[list[str], str]:
    states: list[str] = []
    for patch in PATCHES:
        state = classify(transport.dump(patch.address, len(patch.wholeblock)), patch)
        states.append(state)
        print(f"{state:10s} 0x{patch.address:08x} {patch.name}")
    table = callback_state(transport)
    print(f"{table:10s} 0x{CALLBACK_TABLE_ADDRESS:08x} callback table")

    if table == "inert" and states[0] != "batch10":
        raise ValueError("callback table points into an absent A/inert cave")
    if table == "cap4" and len(set(states)) != 1:
        # The only safe cap4 partial state is A staged by apply, or A retained
        # after revert reconnect and before its final delayed clear.
        if states[0] != "batch10" or any(
            state != "wholeblock" for state in states[1:]
        ):
            raise ValueError("cap4 exposes an unapproved mixed batch10 cutpoint")
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


def checked_word(
    transport: AocFactoryDiag, address: int, source: int, destination: int, name: str
) -> None:
    actual = struct.unpack("<I", transport.dump(address, 4))[0]
    if actual != source:
        raise RuntimeError(
            f"{name} moved before write at 0x{address:08x}: "
            f"0x{actual:08x} != 0x{source:08x}"
        )
    if source != destination:
        transport.write(address, destination, 32)
    actual = struct.unpack("<I", transport.dump(address, 4))[0]
    if actual != destination:
        raise RuntimeError(
            f"{name} verification failed at 0x{address:08x}: 0x{actual:08x}"
        )


def checked_byte(
    transport: AocFactoryDiag, address: int, source: int, destination: int, name: str
) -> None:
    actual = transport.dump(address, 1)[0]
    if actual != source:
        raise RuntimeError(
            f"{name} moved before write at 0x{address:08x}: {actual} != {source}"
        )
    if source != destination:
        transport.write(address, destination, 8)
    actual = transport.dump(address, 1)[0]
    if actual != destination:
        raise RuntimeError(
            f"{name} verification failed at 0x{address:08x}: {actual}"
        )


def set_callback(transport: AocFactoryDiag, source: bytes, destination: bytes) -> None:
    patch = Patch("switch Fullband callback atomically", CALLBACK_TABLE_ADDRESS,
                  source, destination)
    checked_patch(transport, patch, source, destination)


def require_foundation(transport: AocFactoryDiag) -> None:
    """Verify whole-block prerequisites while allowing our exact owned sites."""

    full_excluded = wholeblock.PROFILE_EXCLUDED_ADDRESSES["full"]
    for patch in wholeblock.BASE_PATCHES:
        if patch.address in wholeblock.OWNED_BASE_ADDRESSES:
            continue
        expected = patch.before if patch.address in full_excluded else patch.after
        actual = transport.dump(patch.address, len(expected))
        if actual != expected:
            raise ValueError(
                f"native-192 foundation changed at 0x{patch.address:08x}: "
                f"{actual.hex()}"
            )

    owned_no_repack_addresses = {
        PATCH_FLUSH.address,
        PATCH_ADVANCE.address,
        0x403E882D,
        PATCH_HELPERS.address,
    }
    for name, address, expected in wholeblock.NO_REPACK_REGIONS:
        if address in owned_no_repack_addresses:
            continue
        actual = transport.dump(address, len(expected))
        if actual != expected:
            raise ValueError(f"{name} changed at 0x{address:08x}: {actual.hex()}")

    for name, address, expected in wholeblock.STATIC_PRECONDITIONS:
        if address == 0x403E8870:
            # The first 15 bytes precede our exact 85-byte owned tail.
            expected = expected[:15]
        actual = transport.dump(address, len(expected))
        if actual != expected:
            raise ValueError(f"{name} changed at 0x{address:08x}: {actual.hex()}")

    for name, address, expected in STATIC_GUARDS:
        actual = transport.dump(address, len(expected))
        if actual != expected:
            raise ValueError(
                f"{name} changed at 0x{address:08x}: {actual.hex()} "
                f"(expected {expected.hex()})"
            )

    callback = transport.dump(0x403F0C44, len(wholeblock.WHOLEBLOCK_CALLBACK))
    if callback != wholeblock.WHOLEBLOCK_CALLBACK:
        raise ValueError("cap-four whole-block callback body changed")
    if struct.unpack("<I", transport.dump(OUTPUT_VTABLE + 0x18, 4))[0] != 0x4040D954:
        raise ValueError("output AdvanceWritePointer vtable slot changed")
    if struct.unpack("<I", transport.dump(OUTPUT_VTABLE + 0x5C, 4))[0] != 0x4040DE84:
        raise ValueError("output GetWritePointer vtable slot changed")

    if len(START_RESET_HELPER) != 0x4039E510 - 0x4039E4FC:
        raise AssertionError("start reset crosses its zero cave")
    if len(FLUSH_AND_INERT) != 0x403C1830 - 0x403C1814:
        raise AssertionError("A/inert crosses its cave")
    if len(ADVANCE_AND_NOTIFY) != 0x403C1A50 - 0x403C1A34:
        raise AssertionError("B crosses its cave")
    if len(NO_SYNC_AND_NOTIFY) != 0x403F64C0 - 0x403F648D:
        raise AssertionError("no-sync/C crosses its cave")
    if len(BATCH10_OUTPUT_TAIL) != 0x403E88D4 - 0x403E887F:
        raise AssertionError("batch tail crosses its replaced window")
    if BATCH_BYTES != 0x1E00 or OUTPUT_CAPACITY % BATCH_BYTES:
        raise AssertionError("fixed batch/capacity arithmetic changed")
    if MONO_BLOCK_BYTES > 0x814 - 0x21C:
        raise AssertionError("mono scratch crosses pending batch state")
    print("verified exact whole-block, cap-four, start-hook and host ABI foundation")


def read_output_state(
    transport: AocFactoryDiag,
    *,
    require_batch_alignment: bool,
    require_empty: bool = False,
    require_batch_geometry: bool = True,
) -> OutputState:
    vtable = struct.unpack("<I", transport.dump(FULLBAND_OBJECT, 4))[0]
    if vtable != FULLBAND_VTABLE:
        raise ValueError(f"Fullband vtable changed: 0x{vtable:08x}")
    input_ring = pointer(transport, FULLBAND_OBJECT + 0x13C, "Fullband input")
    output_ring = pointer(transport, FULLBAND_OBJECT + 0x140, "Fullband output")
    if input_ring != FULLBAND_INPUT or output_ring != FULLBAND_OUTPUT:
        raise ValueError(
            f"Fullband rings changed: 0x{input_ring:08x}/0x{output_ring:08x}"
        )
    rings = dict(ring_objects(transport))
    if rings.get("MIC_US_RING") != input_ring:
        raise ValueError("Fullband input is not the qualified MIC_US ring")
    if struct.unpack("<I", transport.dump(output_ring, 4))[0] != OUTPUT_VTABLE:
        raise ValueError("Fullband output vtable changed")

    wake_threshold = struct.unpack(
        "<I", transport.dump(output_ring + 0xC0, 4)
    )[0]
    if wake_threshold != BATCH_BYTES:
        raise ValueError(
            f"output wake threshold must be fixed 0x1e00, got 0x{wake_threshold:x}"
        )
    descriptor = struct.unpack(
        "<I", transport.dump(output_ring + OUTPUT_DESCRIPTOR_OFFSET, 4)
    )[0]
    if not 0x80000000 <= descriptor < 0xC0000000 or descriptor & 0x3F:
        raise ValueError(f"invalid output descriptor pointer 0x{descriptor:08x}")
    raw = transport.dump(descriptor, 0x40)
    if raw[:0x20].split(b"\0", 1)[0] != b"ultrasonic_capture":
        raise ValueError("output descriptor name changed")
    values = struct.unpack_from("<IIIIIIII", raw, 0x20)
    (
        flags,
        descriptor_base,
        capacity,
        enabled,
        writer_total,
        reader_total,
        writer_cursor,
        reader_cursor,
    ) = values
    object_base = struct.unpack(
        "<I", transport.dump(output_ring + OUTPUT_BASE_COMPONENT_OFFSET, 4)
    )[0]
    write_base = descriptor_base + object_base
    if flags & 0x70000 != 0x10000 or enabled != 1:
        raise ValueError(f"output descriptor mode/enable changed: 0x{flags:x}/{enabled}")
    if capacity != OUTPUT_CAPACITY or capacity % BATCH_BYTES:
        raise ValueError(f"output capacity is not 12 batches: 0x{capacity:x}")
    if (
        not descriptor_base
        or not object_base
        or write_base > 0xFFFFFFFF - capacity
        or not 0x80000000 <= write_base < 0xC0000000
        or write_base + capacity > 0xC0000000
        or write_base & 0x3F
    ):
        raise ValueError(
            f"invalid output base components 0x{descriptor_base:08x}+0x{object_base:08x}"
        )
    if writer_cursor >= capacity or reader_cursor >= capacity:
        raise ValueError("output cursor is outside capacity")
    if writer_total % capacity != writer_cursor or reader_total % capacity != reader_cursor:
        raise ValueError("output totals and modulo cursors disagree")
    queued = (writer_total - reader_total) & 0xFFFFFFFF
    if queued > capacity:
        raise ValueError(f"output shared ring is overcommitted by 0x{queued:x}")
    if require_batch_alignment:
        fields = (writer_total, reader_total, writer_cursor, reader_cursor, queued)
        if any(value % BATCH_BYTES for value in fields):
            raise ValueError(
                "output state is not 0x1e00 batch aligned: "
                + "/".join(f"0x{value:x}" for value in fields)
            )
        if capacity - queued < BATCH_BYTES:
            raise ValueError(
                f"output has less than one batch free: 0x{capacity - queued:x}"
            )
        if writer_cursor + BATCH_BYTES > capacity:
            raise ValueError("one contiguous batch would cross the output ring end")
    elif writer_cursor % MONO_BLOCK_BYTES or reader_cursor % MONO_BLOCK_BYTES:
        raise ValueError("pre-normalization output cursors are not block aligned")
    if require_empty and any((writer_total, reader_total, writer_cursor, reader_cursor)):
        raise ValueError("output descriptor is not normalized to zero")
    transport.dump(write_base, 4)
    transport.dump(write_base + capacity - 4, 4)

    period_count, invocation_count, process_counter = transport.dump(
        RUNTIME_BYTES_ADDRESS, 3
    )
    write_size = struct.unpack("<I", transport.dump(WRITE_SIZE_ADDRESS, 4))[0]
    geometry = (period_count, invocation_count, write_size)
    approved_geometry = (
        (4, BATCH_BLOCKS, MONO_BLOCK_BYTES),
        (4, 20, 0x180),
    )
    if geometry not in approved_geometry:
        raise ValueError(
            "Fullband geometry is not an approved inactive/open pair, got "
            f"{period_count}/{invocation_count}/0x{write_size:x}"
        )
    if require_batch_geometry and geometry != approved_geometry[0]:
        raise ValueError(
            "Fullband must be normalized to period=4/invocations=10/write=0x300"
        )
    if process_counter > period_count * invocation_count:
        raise ValueError(f"Fullband process counter is invalid: {process_counter}")
    if write_size * invocation_count != BATCH_BYTES:
        raise ValueError("Fullband invocation product is not 0x1e00")
    if wake_threshold * period_count != OUTPUT_MINIMUM_BYTES:
        raise ValueError("Fullband minimum output product is not 0x7800")
    state = OutputState(
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
    print(
        "Fullband output: fixed batch=0x1e00 "
        f"writer=0x{writer_cursor:x} reader=0x{reader_cursor:x} "
        f"queued=0x{state.queued:x} free=0x{state.free:x}"
    )
    return state


def read_batch_state(transport: AocFactoryDiag) -> tuple[int, int, int]:
    count, base = struct.unpack(
        "<II", transport.dump(PENDING_COUNT_ADDRESS, 8)
    )
    active = transport.dump(ACTIVE_ADDRESS, 1)[0]
    if count >= BATCH_BLOCKS:
        raise ValueError(f"pending batch count is outside 0..9: {count}")
    if active not in (0, 1):
        raise ValueError(f"Fullband active byte changed: {active}")
    # A completed batch resets count before the flush but intentionally leaves
    # its cached base.  It is ignored at count zero and cleared by the next
    # open/reset or by installer maintenance.
    if base and not 0x80000000 <= base < 0xC0000000:
        raise ValueError(f"pending batch base is invalid: 0x{base:08x}")
    return count, base, active


def zero_batch_state(transport: AocFactoryDiag) -> None:
    count, base, active = read_batch_state(transport)
    if active:
        raise RuntimeError("refusing to clear batch state while Fullband is active")
    checked_word(transport, PENDING_COUNT_ADDRESS, count, 0, "pending batch count")
    checked_word(transport, PENDING_BASE_ADDRESS, base, 0, "pending batch base")
    if read_batch_state(transport) != (0, 0, 0):
        raise RuntimeError("pending batch state did not stay zero")
    print("zeroed pending batch count/base under inactive quarantine")


def quiescence_snapshot(transport: AocFactoryDiag) -> tuple[bytes, ...]:
    input_ring = pointer(transport, FULLBAND_OBJECT + 0x13C, "Fullband input")
    input_descriptor = pointer(transport, input_ring + 0x44, "MIC_US descriptor")
    output_descriptor = struct.unpack(
        "<I", transport.dump(FULLBAND_OUTPUT + OUTPUT_DESCRIPTOR_OFFSET, 4)
    )[0]
    return (
        transport.dump(PENDING_COUNT_ADDRESS, 0x24),
        transport.dump(input_descriptor, 28),
        transport.dump(output_descriptor, 0x40),
    )


def require_stable_idle(
    transport: AocFactoryDiag, expected_callback: str, delay: float = 0.05
) -> None:
    if callback_state(transport) != expected_callback:
        raise RuntimeError(f"callback is not {expected_callback} for idle snapshot")
    if read_batch_state(transport)[2] != 0:
        raise RuntimeError("Fullband remains active with capture nodes blocked")
    first = quiescence_snapshot(transport)
    time.sleep(delay)
    if callback_state(transport) != expected_callback:
        raise RuntimeError("callback changed during idle snapshot")
    second = quiescence_snapshot(transport)
    if first != second:
        raise RuntimeError(
            "Fullband/MIC_US/output state moved while all captures were closed"
        )
    print(f"stable inactive snapshot with callback {expected_callback}")


def normalize_output_descriptor(transport: AocFactoryDiag) -> OutputState:
    """Reset a closed host descriptor after proving inert exclusive access."""

    if callback_state(transport) != "inert":
        raise RuntimeError("output normalization requires the inert callback")
    require_stable_idle(transport, "inert")
    state = read_output_state(
        transport,
        require_batch_alignment=False,
        require_batch_geometry=False,
    )
    addresses = (
        (state.descriptor + 0x30, state.writer_total, "output writer total"),
        (state.descriptor + 0x34, state.reader_total, "output reader total"),
        (state.descriptor + 0x38, state.writer_cursor, "output writer cursor"),
        (state.descriptor + 0x3C, state.reader_cursor, "output reader cursor"),
    )
    # Sequential writes are safe only because capture nodes are 000, no PCM
    # owns this descriptor, the callback is inert, and two snapshots matched.
    for address, current, name in addresses:
        checked_word(transport, address, current, 0, name)
    normalized = read_output_state(
        transport, require_batch_alignment=True, require_empty=True
    )
    require_stable_idle(transport, "inert")
    print("normalized closed output descriptor totals/cursors to zero")
    return normalized


def normalize_fullband_runtime(transport: AocFactoryDiag) -> None:
    """Normalize the approved inactive 0x180/20 pair to 0x300/10."""

    if callback_state(transport) != "inert":
        raise RuntimeError("runtime normalization requires the inert callback")
    if read_batch_state(transport)[2]:
        raise RuntimeError("runtime normalization requires inactive Fullband")
    period, invocations, process_counter = transport.dump(RUNTIME_BYTES_ADDRESS, 3)
    write_size = struct.unpack("<I", transport.dump(WRITE_SIZE_ADDRESS, 4))[0]
    if period != 4 or (write_size, invocations) not in ((0x180, 20), (0x300, 10)):
        raise ValueError(
            "inactive Fullband runtime is not an approved 0x180/20 or 0x300/10 pair"
        )
    checked_byte(
        transport, RUNTIME_BYTES_ADDRESS + 1, invocations, 10,
        "Fullband invocation count",
    )
    checked_byte(
        transport, RUNTIME_BYTES_ADDRESS + 2, process_counter, 0,
        "Fullband process counter",
    )
    checked_word(
        transport, WRITE_SIZE_ADDRESS, write_size, MONO_BLOCK_BYTES,
        "Fullband write size",
    )
    actual = transport.dump(RUNTIME_BYTES_ADDRESS, 3)
    if actual != bytes((4, 10, 0)):
        raise RuntimeError(f"Fullband runtime normalization failed: {actual.hex()}")
    print("normalized inactive Fullband runtime to 0x300 bytes / 10 invocations")


def transition_profile(
    transport: AocFactoryDiag,
    action: str,
    *,
    after_quarantine: Callable[[], None] | None = None,
    before_reconnect: Callable[[], None] | None = None,
    after_reconnect: Callable[[], None] | None = None,
) -> None:
    """Perform an exact-cutpoint transition; fake transports use this in tests."""

    if action not in ("apply", "revert"):
        raise ValueError(f"invalid transition action: {action}")
    states, table = read_states(transport)
    wanted = "batch10" if action == "apply" else "wholeblock"
    if all(state == wanted for state in states) and table == "cap4":
        print(f"already uniformly connected {wanted}")
        return

    if action == "apply" and states[0] == "wholeblock":
        checked_patch(transport, PATCH_FLUSH, ZERO28, FLUSH_AND_INERT)
        states[0] = "batch10"
    if states[0] != "batch10":
        raise ValueError("A/inert cave must exist before callback quarantine")
    if table == "cap4":
        set_callback(transport, CALLBACK_CAP4, CALLBACK_INERT)
        table = "inert"
    if callback_state(transport) != "inert":
        raise RuntimeError("callback escaped inert quarantine")
    if after_quarantine is not None:
        after_quarantine()

    ordered = APPLY_AFTER_QUARANTINE if action == "apply" else REVERT_UNDER_QUARANTINE
    for patch in ordered:
        index = PATCHES.index(patch)
        if states[index] == wanted:
            continue
        source = patch.wholeblock if action == "apply" else patch.batch10
        destination = patch.batch10 if action == "apply" else patch.wholeblock
        checked_patch(transport, patch, source, destination)
        states[index] = wanted

    if action == "apply":
        final_states, final_table = read_states(transport)
        if any(state != "batch10" for state in final_states) or final_table != "inert":
            raise RuntimeError("apply did not reach uniform quarantined batch10")
        if before_reconnect is not None:
            before_reconnect()
        set_callback(transport, CALLBACK_INERT, CALLBACK_CAP4)
    else:
        # A still owns the inert target and is deliberately cleared only after
        # cap4 is restored and another stable idle interval has elapsed.
        if any(state != "wholeblock" for state in states[1:]):
            raise RuntimeError("revert helpers did not reach wholeblock")
        if before_reconnect is not None:
            before_reconnect()
        set_callback(transport, CALLBACK_INERT, CALLBACK_CAP4)
        if after_reconnect is not None:
            after_reconnect()
        checked_patch(transport, PATCH_FLUSH, FLUSH_AND_INERT, ZERO28)

    final_states, final_table = read_states(transport)
    if any(state != wanted for state in final_states) or final_table != "cap4":
        raise RuntimeError(f"transition did not reach connected {wanted}")


def normalize_connected_batch10(transport: AocFactoryDiag) -> None:
    states, table = read_states(transport)
    if any(state != "batch10" for state in states) or table != "cap4":
        raise ValueError("normalize-idle requires a uniformly connected batch10 profile")
    set_callback(transport, CALLBACK_CAP4, CALLBACK_INERT)
    require_stable_idle(transport, "inert")
    normalize_fullband_runtime(transport)
    normalize_output_descriptor(transport)
    zero_batch_state(transport)
    require_stable_idle(transport, "inert")
    set_callback(transport, CALLBACK_INERT, CALLBACK_CAP4)
    require_stable_idle(transport, "cap4")


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

    mutating = args.action in ("apply", "revert", "normalize-idle")
    capture_modes: list[tuple[str, str]] | None = None
    if mutating:
        capture_modes = block_capture_opens(transport)
        require_all_capture_idle(transport)

    require_foundation(transport)
    require_grown_idle_geometry(transport, NATIVE_BLOCK_BYTES)
    states, table = read_states(transport)

    if args.action.startswith("check-"):
        wanted = args.action.removeprefix("check-")
        if any(state != wanted for state in states) or table != "cap4":
            raise ValueError(f"profile is not uniformly connected {wanted}")
        strict = wanted == "batch10"
        read_output_state(
            transport,
            require_batch_alignment=strict,
            require_batch_geometry=strict,
        )
        count, base, active = read_batch_state(transport)
        print(f"pending count={count} base=0x{base:08x} active={active}")
        return 0

    if args.action == "normalize-idle":
        normalize_connected_batch10(transport)
        read_output_state(
            transport, require_batch_alignment=True, require_empty=True
        )
    else:
        transition_needed = not (
            all(
                state == ("batch10" if args.action == "apply" else "wholeblock")
                for state in states
            )
            and table == "cap4"
        )
        if transition_needed:
            transition_profile(
                transport,
                args.action,
                after_quarantine=lambda: require_stable_idle(transport, "inert"),
                before_reconnect=lambda: (
                    normalize_fullband_runtime(transport),
                    normalize_output_descriptor(transport),
                    zero_batch_state(transport),
                    require_stable_idle(transport, "inert"),
                ),
                after_reconnect=lambda: require_stable_idle(transport, "cap4"),
            )
        wanted = "batch10" if args.action == "apply" else "wholeblock"
        final_states, final_table = read_states(transport)
        if any(state != wanted for state in final_states) or final_table != "cap4":
            raise RuntimeError(f"postflight is not connected {wanted}")
        read_output_state(
            transport,
            require_batch_alignment=wanted == "batch10",
            require_empty=transition_needed,
            require_batch_geometry=wanted == "batch10",
        )

    require_foundation(transport)
    require_grown_idle_geometry(transport, NATIVE_BLOCK_BYTES)
    if capture_modes is not None:
        restore_capture_modes(transport, capture_modes)
    print(
        f"verified {args.action}; fixed 0x1e00 batching is volatile and disappears "
        "on AoC/device reboot"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
