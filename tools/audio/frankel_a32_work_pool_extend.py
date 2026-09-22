#!/usr/bin/env python3
"""Guarded reboot-volatile extension of Frankel's A32 USF work pool.

This experiment appends 64 synthetic 0x28-byte static work items carved from
the historically unused low end of the CHRELogs task stack.  It is deliberately
finite: it can absorb a transient burst, but cannot repair an unbounded queue.
There is no live revert.  Reboot AoC/the phone to restore all touched SRAM.
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys
import time

from aoc_factory_diag import AocFactoryDiag


EXPECTED_DEVICE = "frankel"
EXPECTED_VENDOR_BUILD_ID = "CP2A.260805.005"

POOL_POINTER = 0x40131094
POOL = 0x40164110
POOL_VTABLE = 0x40109D10
STATIC_POOL_FIRST = 0x40164288
STATIC_POOL_TAIL_NEXT = STATIC_POOL_FIRST + 0x10
STATIC_POOL_CAPACITY = 128

CHRE_LOGS_TCB = 0x4020F258
CHRE_LOGS_STACK = 0x4020D250
CHRE_LOGS_NAME = b"CHRELogs\0\0\0\0\0\0\0\0"
CHRE_LOGS_EVENT_LIST = 0x4014DBC4
FREERTOS_SUSPENDED_LIST = 0x401512BC

# Preserve the first 0x40 bytes of the stack's overflow canary.  Six coherent
# Frankel cores retain A5 through at least 0x4020eeb7.  This 64-item cave ends
# at 0x4020dc90, leaving at least 0x1228 bytes of observed unused-stack margin.
CAVE = CHRE_LOGS_STACK + 0x40
ITEM_SIZE = 0x28
ITEM_COUNT = 64
CAVE_END = CAVE + ITEM_SIZE * ITEM_COUNT
TOP_GUARD_END = CAVE_END + 0x100

AUDIO_SERVICE_PROPERTIES = (
    "init.svc.audioserver",
    "init.svc.vendor.audio-hal-powerphone",
    "init.svc.vendor.audio-hal-aidl",
)


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def chunks(start: int, size: int):
    while size:
        count = min(size, 256)
        yield start, count
        start += count
        size -= count


def dump_range(transport: AocFactoryDiag, start: int, size: int) -> bytes:
    return b"".join(transport.dump(address, count) for address, count in chunks(start, size))


def adb_text(transport: AocFactoryDiag, *arguments: str) -> str:
    return transport.run(*arguments).stdout.decode(errors="replace").strip()


def preflight(transport: AocFactoryDiag) -> None:
    if adb_text(transport, "get-state") != "device":
        raise RuntimeError("ADB target is not online")
    device = adb_text(transport, "shell", "getprop", "ro.product.device")
    build = adb_text(transport, "shell", "getprop", "ro.vendor.build.id")
    if device != EXPECTED_DEVICE:
        raise RuntimeError(f"refusing non-Frankel target {device!r}")
    if build != EXPECTED_VENDOR_BUILD_ID:
        raise RuntimeError(
            f"refusing unreviewed vendor build {build!r}; "
            f"expected {EXPECTED_VENDOR_BUILD_ID!r}"
        )
    if adb_text(transport, "shell", "su", "0", "id", "-u") != "0":
        raise RuntimeError("root shell is required")
    states = {
        # Production property policy hides vendor init state from the shell
        # domain after ctl.stop.  Query through the already-required root
        # context so a deliberately stopped HAL is not misclassified as an
        # unset/running service.
        prop: adb_text(transport, "shell", "su", "0", "getprop", prop)
        for prop in AUDIO_SERVICE_PROPERTIES
    }
    running = {prop: state for prop, state in states.items() if state != "stopped"}
    if running:
        rendered = ", ".join(f"{prop}={state!r}" for prop, state in running.items())
        raise RuntimeError(f"stop all audio services before this experiment: {rendered}")


def validate_pool(pool: bytes, *, patched: bool) -> None:
    if len(pool) != 0x60:
        raise ValueError("short pool header")
    expected = {
        0x00: POOL_VTABLE,
        0x18: STATIC_POOL_FIRST,
        0x38: STATIC_POOL_CAPACITY,
    }
    for offset, wanted in expected.items():
        actual = u32(pool, offset)
        if actual != wanted:
            raise ValueError(
                f"pool guard mismatch at 0x{POOL + offset:08x}: "
                f"got 0x{actual:08x}, expected 0x{wanted:08x}"
            )
    head = u32(pool, 0x1C)
    current = u32(pool, 0x3C)
    peak = u32(pool, 0x40)
    if head == 0:
        raise ValueError("pool freelist is empty; reboot instead of patching")
    if current > 8:
        raise ValueError(f"pool has {current} live static items; require <= 8")
    if not patched and peak > STATIC_POOL_CAPACITY:
        raise ValueError(f"stock pool peak is impossible: {peak}")


def validate_tcb(tcb: bytes) -> None:
    exact = {
        0x10: CHRE_LOGS_TCB,
        0x14: FREERTOS_SUSPENDED_LIST,
        0x18: 31,
        0x24: CHRE_LOGS_TCB,
        0x28: CHRE_LOGS_EVENT_LIST,
        0x2C: 1,
        0x30: CHRE_LOGS_STACK,
        0x44: 21,
        0x4C: 1,
    }
    for offset, wanted in exact.items():
        actual = u32(tcb, offset)
        if actual != wanted:
            raise ValueError(
                f"CHRELogs TCB guard mismatch at 0x{CHRE_LOGS_TCB + offset:08x}: "
                f"got 0x{actual:08x}, expected 0x{wanted:08x}"
            )
    if tcb[0x34:0x44] != CHRE_LOGS_NAME:
        raise ValueError(f"CHRELogs name guard mismatch: {tcb[0x34:0x44]!r}")
    top = u32(tcb, 0)
    if not 0x4020EEB8 <= top <= 0x4020F0B0:
        raise ValueError(f"unexpected CHRELogs pxTopOfStack 0x{top:08x}")


def expected_next(index: int) -> int:
    return CAVE + ITEM_SIZE * (index + 1) if index + 1 < ITEM_COUNT else 0


def validate_stock_cave(cave: bytes) -> None:
    if cave != bytes([0xA5]) * len(cave):
        for offset in range(0, len(cave), 4):
            if cave[offset:offset + 4] != b"\xA5" * 4:
                raise ValueError(
                    f"CHRELogs cave/canary is used at 0x{CHRE_LOGS_STACK + offset:08x}: "
                    f"{cave[offset:offset + 4].hex()}"
                )
        raise ValueError("CHRELogs cave/canary is not uniformly A5")


def validate_initialized_cave(cave: bytes) -> None:
    # Only +0x10 of each work item is intentionally changed.  All other bytes,
    # including the bottom canary and the top guard, must still be A5 before
    # the cave is linked into the live freelist.
    for offset in range(0, len(cave), 4):
        address = CHRE_LOGS_STACK + offset
        if CAVE <= address < CAVE_END and (address - CAVE) % ITEM_SIZE == 0x10:
            index = (address - CAVE) // ITEM_SIZE
            wanted = expected_next(index)
            actual = u32(cave, offset)
            if actual != wanted:
                raise ValueError(
                    f"synthetic item {index} next mismatch at 0x{address:08x}: "
                    f"got 0x{actual:08x}, expected 0x{wanted:08x}"
                )
        elif cave[offset:offset + 4] != b"\xA5" * 4:
            raise ValueError(
                f"unexpected non-A5 cave/guard word at 0x{address:08x}: "
                f"{cave[offset:offset + 4].hex()}"
            )


def snapshot(transport: AocFactoryDiag):
    pointer = int.from_bytes(transport.dump(POOL_POINTER, 4), "little")
    if pointer != POOL:
        raise ValueError(
            f"pool pointer guard mismatch: got 0x{pointer:08x}, expected 0x{POOL:08x}"
        )
    pool = transport.dump(POOL, 0x60)
    tcb = transport.dump(CHRE_LOGS_TCB, 0x54)
    cave = dump_range(transport, CHRE_LOGS_STACK, TOP_GUARD_END - CHRE_LOGS_STACK)
    tail_next = int.from_bytes(transport.dump(STATIC_POOL_TAIL_NEXT, 4), "little")
    return pool, tcb, cave, tail_next


def classify(pool: bytes, tcb: bytes, cave: bytes, tail_next: int) -> str:
    validate_tcb(tcb)
    if tail_next == 0:
        validate_pool(pool, patched=False)
        validate_stock_cave(cave)
        return "stock"
    if tail_next == CAVE:
        validate_pool(pool, patched=True)
        validate_initialized_cave(cave)
        return "patched-pristine"
    raise ValueError(
        f"static tail link has unknown value 0x{tail_next:08x}; reboot required"
    )


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", type=pathlib.Path, default=repository / "work/toolchains/platform-tools/adb")
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    parser.add_argument("--set-delay-ms", type=int, default=2)
    parser.add_argument(
        "operation", choices=("check-stock", "apply", "check-patched-pristine")
    )
    parser.add_argument(
        "--ack-reboot-only-rollback",
        action="store_true",
        help="required for apply; partial or complete changes are reverted only by reboot",
    )
    args = parser.parse_args()
    if not 0 <= args.set_delay_ms <= 1000:
        parser.error("--set-delay-ms must be 0..1000")
    if args.operation == "apply" and not args.ack_reboot_only_rollback:
        parser.error("apply requires --ack-reboot-only-rollback")
    return args


def main() -> int:
    args = parse_args()
    transport = AocFactoryDiag(
        argparse.Namespace(
            adb=args.adb,
            adb_server_port=args.adb_server_port,
            serial=args.serial,
            core=1,
            counter=args.counter,
        )
    )
    preflight(transport)
    pool, tcb, cave, tail_next = snapshot(transport)
    state = classify(pool, tcb, cave, tail_next)
    print(
        f"{state}: pool current={u32(pool, 0x3c)} peak={u32(pool, 0x40)} "
        f"head=0x{u32(pool, 0x1c):08x} tail-next=0x{tail_next:08x}"
    )
    if args.operation == "check-stock":
        if state != "stock":
            raise ValueError(f"expected stock state, got {state}")
        return 0
    if args.operation == "check-patched-pristine":
        if state != "patched-pristine":
            raise ValueError(f"expected pristine patched state, got {state}")
        return 0
    if state != "stock":
        raise ValueError(f"apply requires stock state, got {state}")

    delay = args.set_delay_ms / 1000
    # Initialize disconnected memory last-to-first.  The only publication is
    # the final write to the invariant static tail, so any earlier interruption
    # leaves the live freelist untouched.
    for index in reversed(range(ITEM_COUNT)):
        address = CAVE + index * ITEM_SIZE + 0x10
        transport.write_unverified(address, expected_next(index), 32)
        if delay:
            time.sleep(delay)

    # Re-prove identity, blocking state, low pool occupancy, and every cave
    # word immediately before publishing it.
    pool = transport.dump(POOL, 0x60)
    tcb = transport.dump(CHRE_LOGS_TCB, 0x54)
    cave = dump_range(transport, CHRE_LOGS_STACK, TOP_GUARD_END - CHRE_LOGS_STACK)
    tail_next = int.from_bytes(transport.dump(STATIC_POOL_TAIL_NEXT, 4), "little")
    validate_pool(pool, patched=False)
    validate_tcb(tcb)
    validate_initialized_cave(cave)
    if tail_next != 0:
        raise ValueError(
            f"tail changed before publish (0x{tail_next:08x}); reboot, do not repair live"
        )

    transport.write_unverified(STATIC_POOL_TAIL_NEXT, CAVE, 32)
    actual = int.from_bytes(transport.dump(STATIC_POOL_TAIL_NEXT, 4), "little")
    if actual != CAVE:
        raise RuntimeError(
            f"tail publish verification failed (0x{actual:08x}); reboot immediately"
        )
    print(
        f"appended {ITEM_COUNT} reboot-volatile work items: "
        f"0x{CAVE:08x}..0x{CAVE_END - 1:08x}; rollback is reboot only"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
