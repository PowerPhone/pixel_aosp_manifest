#!/usr/bin/env python3
"""Switch Frankel D12 host output between two- and ten-block batching.

This reboot-volatile CP2A.260805.005 F1 overlay is layered on the guarded
``host_batch10`` profile.  The underlying native-192, grown MIC_US,
whole-block mono and cap-four callback geometry is unchanged.

Batch two commits 0x600 bytes (two 192-frame mono S32 blocks) every 2 ms.
The RingBufferHost wake threshold remains 0x1e00, so five batch-two commits
still produce one 10 ms / 1,920-frame host period.  This is an experimental
hardware-isolation profile for the repeatable batch-ten control-path stall.

Mutating actions block every card-0 capture PCM, require a stable inactive
Fullband object, atomically redirect its callback to the batch10 inert entry,
normalize closed runtime/ring state, change only the two exact instruction
sites, invalidate the complete F1 instruction cache, and reconnect cap four
only after exact postflight.  Any failure after quarantine deliberately leaves
the callback inert and capture nodes mode 000 for audit or reboot.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag
import patch_frankel_aoc_d12_host_batch10_192k as batch10
from patch_frankel_aoc_live_d10_raw_192k import (
    flush_instruction_cache,
    require_identity,
    select_native_helper,
)
from patch_frankel_aoc_live_d12_192k import require_d12_idle
from trigger_frankel_aoc_d12_ring_resize import (
    block_capture_opens,
    require_all_capture_idle,
    restore_capture_modes,
)


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    address: int
    batch10: bytes
    batch2: bytes


@dataclasses.dataclass(frozen=True)
class WriteChunk:
    patch: Patch
    address: int
    before: bytes
    after: bytes

    @property
    def width(self) -> int:
        return len(self.before) * 8


# At count two, the existing addx2 a13,a7,a7 computes six.  The batch10 A/B
# helpers shift callee a5 by eight, so cache clean and AdvanceWritePointer both
# become 6 << 8 = 0x600 without another live-site change.  C constructs the
# same byte count independently at its one mutable instruction below.
PATCH_NOTIFY_BYTES = Patch(
    "D12 host notification 30<<8 -> 6<<8 bytes",
    0x403F64B0,
    bytes.fromhex("1cec"),       # movi.n a12,30
    bytes.fromhex("0c6c"),       # movi.n a12,6
)
PATCH_BATCH_COUNT = Patch(
    "D12 host flush after ten -> two whole blocks",
    0x403E88BD,
    bytes.fromhex("669710"),     # bnei a7,10,0x403e88d1
    bytes.fromhex("662710"),     # bnei a7,2,0x403e88d1
)

# Install the downstream byte-count semantics before the batching threshold.
# Revert walks this tuple backward.  The callback is inert throughout, but the
# ordering also makes the threshold instruction the final activation site.
PATCHES = (PATCH_NOTIFY_BYTES, PATCH_BATCH_COUNT)

BATCH2_BLOCKS = 2
BATCH2_BYTES = BATCH2_BLOCKS * batch10.MONO_BLOCK_BYTES


def replace_exact(
    region_address: int,
    region: bytes,
    patch: Patch,
) -> bytes:
    offset = patch.address - region_address
    if offset < 0 or offset + len(patch.batch10) > len(region):
        raise AssertionError(f"{patch.name} is outside its owned batch10 region")
    if region[offset : offset + len(patch.batch10)] != patch.batch10:
        raise AssertionError(f"{patch.name} does not match the batch10 golden bytes")
    return region[:offset] + patch.batch2 + region[offset + len(patch.batch10) :]


BATCH2_HELPERS = replace_exact(
    batch10.PATCH_HELPERS.address,
    batch10.PATCH_HELPERS.batch10,
    PATCH_NOTIFY_BYTES,
)
BATCH2_OUTPUT_TAIL = replace_exact(
    batch10.PATCH_TAIL.address,
    batch10.PATCH_TAIL.batch10,
    PATCH_BATCH_COUNT,
)

if BATCH2_BYTES != 0x600:
    raise AssertionError("batch-two geometry must be exactly 0x600 bytes")
if batch10.OUTPUT_CAPACITY % BATCH2_BYTES:
    raise AssertionError("Fullband output capacity must contain whole batch-two quanta")
if batch10.BATCH_BYTES % BATCH2_BYTES:
    raise AssertionError("one 10 ms host wake must contain whole batch-two quanta")


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=("apply", "revert", "check-batch10", "check-batch2"),
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


def profile_region_expected(patch: batch10.Patch, profile: str) -> bytes:
    if profile == "batch10":
        return patch.batch10
    if profile != "batch2":
        raise ValueError(f"unknown profile {profile!r}")
    if patch is batch10.PATCH_HELPERS:
        return BATCH2_HELPERS
    if patch is batch10.PATCH_TAIL:
        return BATCH2_OUTPUT_TAIL
    return patch.batch10


def read_profile_state(
    transport: AocFactoryDiag,
    *,
    allowed_callback: str | None = None,
) -> tuple[str, str]:
    """Classify every complete batch10-owned region and the callback table."""

    mutable_states: list[str] = []
    for patch in batch10.PATCHES:
        actual = transport.dump(patch.address, len(patch.batch10))
        expected10 = profile_region_expected(patch, "batch10")
        expected2 = profile_region_expected(patch, "batch2")
        if expected10 == expected2:
            if actual != expected10:
                raise ValueError(
                    f"{patch.name}: changed at 0x{patch.address:08x}: "
                    f"{actual.hex()} (expected {expected10.hex()})"
                )
            state = "shared"
        elif actual == expected10:
            state = "batch10"
            mutable_states.append(state)
        elif actual == expected2:
            state = "batch2"
            mutable_states.append(state)
        else:
            raise ValueError(
                f"{patch.name}: unknown bytes at 0x{patch.address:08x}: "
                f"{actual.hex()}"
            )
        print(f"{state:8s} 0x{patch.address:08x} {patch.name}")

    if not mutable_states or len(set(mutable_states)) != 1:
        raise ValueError(f"mixed D12 host-batch sites: {mutable_states}")
    profile = mutable_states[0]
    callback = batch10.callback_state(transport)
    print(
        f"{callback:8s} 0x{batch10.CALLBACK_TABLE_ADDRESS:08x} "
        "Fullband callback table"
    )
    if allowed_callback is not None and callback != allowed_callback:
        raise ValueError(
            f"Fullband callback is {callback}, expected {allowed_callback}"
        )
    return profile, callback


def read_runtime_state(transport: AocFactoryDiag, profile: str) -> None:
    state = batch10.read_output_state(
        transport,
        require_batch_alignment=False,
        require_batch_geometry=True,
    )
    quantum = batch10.BATCH_BYTES if profile == "batch10" else BATCH2_BYTES
    fields = (
        state.writer_total,
        state.reader_total,
        state.writer_cursor,
        state.reader_cursor,
        state.queued,
    )
    if any(value % quantum for value in fields):
        raise ValueError(
            f"output state is not 0x{quantum:x}-aligned for {profile}: "
            + "/".join(f"0x{value:x}" for value in fields)
        )
    if state.free < quantum:
        raise ValueError(
            f"output has only 0x{state.free:x} free for 0x{quantum:x} {profile}"
        )
    if state.writer_cursor + quantum > state.capacity:
        raise ValueError(f"one contiguous {profile} commit would cross ring end")

    count, base, active = batch10.read_batch_state(transport)
    limit = batch10.BATCH_BLOCKS if profile == "batch10" else BATCH2_BLOCKS
    if count >= limit:
        raise ValueError(
            f"pending {profile} count {count} is outside 0..{limit - 1}"
        )
    print(
        f"{profile}: quantum=0x{quantum:x} pending={count} "
        f"base=0x{base:08x} active={active}"
    )


def changed_chunks(patch: Patch, action: str) -> tuple[WriteChunk, ...]:
    source = patch.batch10 if action == "apply" else patch.batch2
    destination = patch.batch2 if action == "apply" else patch.batch10
    chunks: list[WriteChunk] = []
    offset = 0
    while offset < len(source):
        address = patch.address + offset
        remaining = len(source) - offset
        width_bytes = next(
            width
            for width in (4, 2, 1)
            if remaining >= width and address % width == 0
        )
        before = source[offset : offset + width_bytes]
        after = destination[offset : offset + width_bytes]
        if before != after:
            chunks.append(WriteChunk(patch, address, before, after))
        offset += width_bytes
    return tuple(chunks)


def write_chunk(transport: AocFactoryDiag, chunk: WriteChunk) -> None:
    actual = transport.dump(chunk.address, len(chunk.before))
    if actual != chunk.before:
        raise ValueError(
            f"{chunk.patch.name}: changed before write at "
            f"0x{chunk.address:08x}: {actual.hex()} != {chunk.before.hex()}"
        )
    transport.write(
        chunk.address,
        int.from_bytes(chunk.after, "little"),
        chunk.width,
    )
    actual = transport.dump(chunk.address, len(chunk.after))
    if actual != chunk.after:
        raise RuntimeError(
            f"{chunk.patch.name}: verification failed at "
            f"0x{chunk.address:08x}: {actual.hex()} != {chunk.after.hex()}"
        )
    print(
        f"write{chunk.width:<2d} 0x{chunk.address:08x} "
        f"{chunk.before.hex()}->{chunk.after.hex()}  {chunk.patch.name}"
    )


def transition(transport: AocFactoryDiag, action: str, initial: str) -> None:
    wanted = "batch2" if action == "apply" else "batch10"
    if initial == wanted:
        print(f"already uniformly connected {wanted}")
        return
    required = "batch10" if action == "apply" else "batch2"
    if initial != required:
        raise ValueError(f"{action} requires {required}, found {initial}")

    batch10.set_callback(
        transport,
        batch10.CALLBACK_CAP4,
        batch10.CALLBACK_INERT,
    )
    batch10.require_stable_idle(transport, "inert")

    # Closed descriptors and pending state are normalized on both directions.
    # This is necessary when reverting after batch2 because a 0x600-aligned
    # cursor is not necessarily aligned to the restored 0x1e00 quantum.
    batch10.normalize_fullband_runtime(transport)
    batch10.normalize_output_descriptor(transport)
    batch10.zero_batch_state(transport)
    batch10.require_stable_idle(transport, "inert")

    attempted: list[WriteChunk] = []
    ordered = PATCHES if action == "apply" else tuple(reversed(PATCHES))
    try:
        for patch in ordered:
            for chunk in changed_chunks(patch, action):
                attempted.append(chunk)
                write_chunk(transport, chunk)

        profile, _ = read_profile_state(transport, allowed_callback="inert")
        if profile != wanted:
            raise RuntimeError(f"transition reached {profile}, expected {wanted}")

        # Factory diagnostic writes are data-coherent but do not invalidate the
        # executing F1 I-cache.  Use the reviewed whole-cache invalidator before
        # reconnecting the live callback.
        flush_instruction_cache(transport)
        profile, _ = read_profile_state(transport, allowed_callback="inert")
        if profile != wanted:
            raise RuntimeError("profile changed during F1 I-cache synchronization")

        batch10.set_callback(
            transport,
            batch10.CALLBACK_INERT,
            batch10.CALLBACK_CAP4,
        )
        batch10.require_stable_idle(transport, "cap4")
        read_runtime_state(transport, wanted)
    except BaseException as error:
        # A failure can occur just after the final reconnect.  Never roll code
        # back merely because capture nodes are blocked: first prove that the
        # callback is inert again and that the object is quiescent.  If either
        # proof fails, make no further instruction writes.
        rollback_errors: list[str] = []
        rollback_safe = False
        try:
            callback = batch10.callback_state(transport)
            if callback == "cap4":
                batch10.set_callback(
                    transport,
                    batch10.CALLBACK_CAP4,
                    batch10.CALLBACK_INERT,
                )
            batch10.require_stable_idle(transport, "inert")
            rollback_safe = True
        except (OSError, RuntimeError, ValueError) as quarantine_error:
            rollback_errors.append(f"cannot prove inert quarantine: {quarantine_error}")

        rolled_back = False
        for chunk in reversed(attempted) if rollback_safe else ():
            try:
                actual = transport.dump(chunk.address, len(chunk.after))
                if actual == chunk.before:
                    continue
                if actual != chunk.after:
                    rollback_errors.append(
                        f"0x{chunk.address:08x}=unknown:{actual.hex()}"
                    )
                    continue
                reverse = WriteChunk(
                    chunk.patch,
                    chunk.address,
                    chunk.after,
                    chunk.before,
                )
                write_chunk(transport, reverse)
            except (OSError, RuntimeError, ValueError) as rollback_error:
                rollback_errors.append(
                    f"0x{chunk.address:08x}={rollback_error}"
                )
        if rollback_safe and not rollback_errors:
            try:
                # The failed forward flush may have populated either version
                # in F1 I-cache.  Synchronize the restored byte profile too.
                flush_instruction_cache(transport)
                batch10.require_stable_idle(transport, "inert")
                rolled_back = True
            except (OSError, RuntimeError, ValueError) as rollback_error:
                rollback_errors.append(f"rollback I-cache sync: {rollback_error}")
        detail = (
            "; rollback issues: " + "; ".join(rollback_errors)
            if rollback_errors
            else "; code bytes rolled back and I-cache synchronized"
            if rolled_back
            else "; no code bytes needed rollback"
        )
        raise RuntimeError(
            f"{action} failed under inert quarantine ({error}){detail}; "
            "capture nodes remain blocked"
        ) from error

    print(
        f"verified uniformly connected {wanted}; changes are volatile and "
        "disappear on AoC/device reboot"
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
    require_identity(transport)
    select_native_helper(transport)
    require_d12_idle(transport)
    require_all_capture_idle(transport)
    batch10.require_foundation(transport)
    batch10.require_grown_idle_geometry(transport, batch10.NATIVE_BLOCK_BYTES)
    profile, callback = read_profile_state(transport, allowed_callback="cap4")

    if args.action.startswith("check-"):
        wanted = args.action.removeprefix("check-")
        if profile != wanted:
            raise ValueError(f"profile is {profile}, expected {wanted}")
        read_runtime_state(transport, profile)
        return 0

    capture_modes = block_capture_opens(transport)
    operation_error: BaseException | None = None
    try:
        require_all_capture_idle(transport)
        batch10.require_stable_idle(transport, callback)
        transition(transport, args.action, profile)
        batch10.require_foundation(transport)
        batch10.require_grown_idle_geometry(
            transport,
            batch10.NATIVE_BLOCK_BYTES,
        )
        final_profile, _ = read_profile_state(
            transport,
            allowed_callback="cap4",
        )
        wanted = "batch2" if args.action == "apply" else "batch10"
        if final_profile != wanted:
            raise RuntimeError(
                f"postflight profile is {final_profile}, expected {wanted}"
            )
    except BaseException as error:
        operation_error = error

    if operation_error is None:
        restore_capture_modes(transport, capture_modes)
    else:
        # Fail closed: unlike a successful transition, do not restore device
        # modes after any error that may have followed callback quarantine.
        raise operation_error
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
