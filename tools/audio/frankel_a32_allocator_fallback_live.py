#!/usr/bin/env python3
"""Guardedly install Frankel's A32 allocator fallback and flush A32 I-cache.

This is a reboot-volatile hardware qualification tool for the exact Frankel
CP2A.260805.005 AoC image.  It changes only the allocator's conditional branch
at 0x400a114e, then temporarily directs the already-live TMD3743 OUTPUTTER
timer through the firmware's whole-cache maintenance routine.  The global
UsfTimer allocation-failure assertion remains stock.

The cache callback invocation is timing-inferred.  A complete, restart-free
speaker playback is the required behavioral proof.  Reboot is the only
rollback after the instruction write.
"""

from __future__ import annotations

import argparse
import pathlib
import sys
import time

from aoc_factory_diag import AocFactoryDiag
from frankel_a32_icache_flush_via_outputter import (
    OUTPUTTER_CALLBACK,
    WHOLE_CACHE_INVALIDATOR,
    pool_guard,
    preflight,
    timer_snapshot,
    u32,
)


ALLOCATOR_WORD_ADDRESS = 0x400A114C
ALLOCATOR_BRANCH_ADDRESS = 0x400A114E
STOCK_ALLOCATOR_WORD = bytes.fromhex("002870d0")
PATCHED_ALLOCATOR_WORD = bytes.fromhex("002825d0")
STOCK_ALLOCATOR_BRANCH = 0xD070
PATCHED_ALLOCATOR_BRANCH = 0xD025

TIMER_ASSERT_ADDRESS = 0x4009E0CE
STOCK_TIMER_ASSERT = bytes.fromhex("90bb")

RESTART_COUNT = "/sys/devices/platform/9000000.aoc/restart_count"
COREDUMP_COUNT = "/sys/devices/platform/9000000.aoc/coredump_count"


def adb_text(transport: AocFactoryDiag, *arguments: str) -> str:
    return transport.run(*arguments).stdout.decode(errors="replace").strip()


def read_counter(transport: AocFactoryDiag, path: str) -> int:
    value = adb_text(transport, "shell", "su", "0", "cat", path)
    if not value.isdecimal():
        raise RuntimeError(f"invalid AoC counter {path}: {value!r}")
    return int(value)


def generation(transport: AocFactoryDiag) -> tuple[int, int]:
    return (
        read_counter(transport, RESTART_COUNT),
        read_counter(transport, COREDUMP_COUNT),
    )


def require_generation(
    transport: AocFactoryDiag, expected: tuple[int, int]
) -> None:
    actual = generation(transport)
    if actual != expected:
        raise RuntimeError(
            "AoC generation changed: "
            f"restart {expected[0]}->{actual[0]}, "
            f"coredump {expected[1]}->{actual[1]}; reboot before continuing"
        )


def require_exact_guards(
    transport: AocFactoryDiag, allocator_word: bytes
) -> None:
    actual_allocator = transport.dump(ALLOCATOR_WORD_ADDRESS, 4)
    if actual_allocator != allocator_word:
        raise ValueError(
            f"allocator guard mismatch at 0x{ALLOCATOR_WORD_ADDRESS:08x}: "
            f"got {actual_allocator.hex()}, expected {allocator_word.hex()}"
        )
    timer_assert = transport.dump(TIMER_ASSERT_ADDRESS, 2)
    if timer_assert != STOCK_TIMER_ASSERT:
        raise ValueError(
            f"global timer assertion is not stock at 0x{TIMER_ASSERT_ADDRESS:08x}: "
            f"got {timer_assert.hex()}, expected {STOCK_TIMER_ASSERT.hex()}"
        )


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    parser.add_argument(
        "--wait-seconds",
        type=float,
        default=7.0,
        help="callback hijack duration; must exceed one five-second interval",
    )
    parser.add_argument("operation", choices=("check", "apply"))
    parser.add_argument(
        "--ack-reboot-only-rollback",
        action="store_true",
        help="required for apply",
    )
    args = parser.parse_args()
    if not 5.5 <= args.wait_seconds <= 20:
        parser.error("--wait-seconds must be 5.5..20")
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
    initial_generation = generation(transport)
    pool_guard(transport)
    timer, body = timer_snapshot(transport)
    callback = u32(body, 0x28)
    allocator = transport.dump(ALLOCATOR_WORD_ADDRESS, 4)
    timer_assert = transport.dump(TIMER_ASSERT_ADDRESS, 2)
    print(
        f"generation={initial_generation[0]}/{initial_generation[1]} "
        f"timer=0x{timer:08x} callback=0x{callback:08x} "
        f"allocator={allocator.hex()} timer_assert={timer_assert.hex()}"
    )
    if allocator not in (STOCK_ALLOCATOR_WORD, PATCHED_ALLOCATOR_WORD):
        raise ValueError(f"unknown allocator word {allocator.hex()}")
    if timer_assert != STOCK_TIMER_ASSERT:
        raise ValueError(f"global timer assertion is not stock: {timer_assert.hex()}")
    require_generation(transport, initial_generation)
    if args.operation == "check":
        return 0
    if callback != OUTPUTTER_CALLBACK:
        raise ValueError(
            f"apply requires stock OUTPUTTER callback 0x{OUTPUTTER_CALLBACK:08x}"
        )
    if allocator != STOCK_ALLOCATOR_WORD:
        raise ValueError("apply requires the exact stock allocator word")

    transport.write_unverified(
        ALLOCATOR_BRANCH_ADDRESS, PATCHED_ALLOCATOR_BRANCH, 16
    )
    require_exact_guards(transport, PATCHED_ALLOCATOR_WORD)
    require_generation(transport, initial_generation)

    # Re-attest the work pool and complete timer object immediately before
    # arming the firmware-native cache operation.  Always attempt to restore
    # the callback after it has been written.
    pool_guard(transport)
    current_timer, current_body = timer_snapshot(transport)
    if current_timer != timer or u32(current_body, 0x28) != OUTPUTTER_CALLBACK:
        raise RuntimeError("OUTPUTTER timer changed after allocator write; reboot")
    callback_address = timer + 0x28
    transport.write_unverified(callback_address, WHOLE_CACHE_INVALIDATOR, 32)
    armed = int.from_bytes(transport.dump(callback_address, 4), "little")
    if armed != WHOLE_CACHE_INVALIDATOR:
        raise RuntimeError(
            f"callback arm readback is 0x{armed:08x}; reboot immediately"
        )
    print(
        f"cache callback armed at 0x{callback_address:08x}; "
        f"waiting {args.wait_seconds:.1f} seconds"
    )

    restore_error: Exception | None = None
    try:
        time.sleep(args.wait_seconds)
    finally:
        try:
            current_timer, current_body = timer_snapshot(transport)
            if current_timer != timer:
                raise RuntimeError(
                    f"timer object moved 0x{timer:08x}->0x{current_timer:08x}"
                )
            current_callback = u32(current_body, 0x28)
            if current_callback != WHOLE_CACHE_INVALIDATOR:
                raise RuntimeError(
                    f"callback changed unexpectedly to 0x{current_callback:08x}"
                )
            transport.write_unverified(
                callback_address, OUTPUTTER_CALLBACK, 32
            )
            restored = int.from_bytes(
                transport.dump(callback_address, 4), "little"
            )
            if restored != OUTPUTTER_CALLBACK:
                raise RuntimeError(
                    f"callback restore readback is 0x{restored:08x}"
                )
        except Exception as error:
            restore_error = error
    if restore_error is not None:
        raise RuntimeError(
            f"callback restoration failed: {restore_error}; reboot immediately"
        )

    require_exact_guards(transport, PATCHED_ALLOCATOR_WORD)
    require_generation(transport, initial_generation)
    print(
        "allocator D-side readback and callback restoration verified; "
        "cache invocation is timing-inferred. Run restart-free speaker "
        "playback now for behavioral proof; reboot is the only rollback."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
