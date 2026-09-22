#!/usr/bin/env python3
"""Guarded Frankel A32 I-cache flush via one OUTPUTTER timer callback.

The production memory-set command changes A32 SRAM but does not provide an
explicit instruction-cache operation.  This trial temporarily replaces the
already-live OUTPUTTER UsfTimer callback with the firmware's own whole-cache
maintenance routine.  The timer still defers through UsfDefaultWorker, so the
cache routine executes from the safe worker context.  The callback is restored
after more than one stock five-second timer interval.

This is an experimental, reboot-volatile path.  It cannot directly prove that
the callback ran; the behavioral proof is that the newly written instruction
executes afterward.  Reboot is the only rollback for the instruction change.
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
# CP2A.260805.005 Frankel/Polygon has been observed with either of two runtime
# construction layouts under the same signed image. Resolve the live TMD3743
# OUTPUTTER instance by its complete object guard instead of assuming one
# address.
TIMER_LAYOUTS = (
    (0x4016DF48, 0x4016DF08),
    (0x4016E048, 0x4016E008),
)
TIMER_VTABLE = 0x4010A330
USF_DEFAULT_WORKER = 0x40165730
OUTPUTTER_CALLBACK = 0x400A7A2D
TIMER_PERIOD_NS = 5_000_000_000

INVOKE_FAILURE_BRANCH = 0x4009E0CE
STOCK_BRANCH = 0xBB90
DROP_CALLBACK_NOP = 0xBF00
WHOLE_CACHE_INVALIDATOR = 0x40091BE9  # Thumb entry at even address 0x40091be8.

AUDIO_SERVICE_PROPERTIES = (
    "init.svc.audioserver",
    "init.svc.vendor.audio-hal-powerphone",
    "init.svc.vendor.audio-hal-aidl",
)


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


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
        # The production property policy does not expose vendor init-service
        # state to the shell domain after ctl.stop.  Query it in the same root
        # domain that owns the guarded factory-diag transaction.
        prop: adb_text(transport, "shell", "su", "0", "getprop", prop)
        for prop in AUDIO_SERVICE_PROPERTIES
    }
    running = {prop: state for prop, state in states.items() if state != "stopped"}
    if running:
        rendered = ", ".join(f"{prop}={state!r}" for prop, state in running.items())
        raise RuntimeError(f"stop all audio services before this experiment: {rendered}")


def timer_snapshot(transport: AocFactoryDiag) -> tuple[int, bytes]:
    matches: list[tuple[int, bytes]] = []
    failures: list[str] = []
    for pointer_address, expected_context in TIMER_LAYOUTS:
        timer = int.from_bytes(transport.dump(pointer_address, 4), "little")
        if timer == 0:
            continue
        if not 0x40178000 <= timer <= 0x40190000 or timer % 8:
            failures.append(
                f"0x{pointer_address:08x}=0x{timer:08x} is not a timer pointer"
            )
            continue
        body = transport.dump(timer, 0x38)
        exact = {
            0x00: TIMER_VTABLE,
            0x24: USF_DEFAULT_WORKER,
            0x2C: expected_context,
        }
        mismatch = next(
            (
                f"+0x{offset:02x}=0x{u32(body, offset):08x}, "
                f"expected 0x{wanted:08x}"
                for offset, wanted in exact.items()
                if u32(body, offset) != wanted
            ),
            None,
        )
        period = int.from_bytes(body[0x10:0x18], "little")
        callback = u32(body, 0x28)
        if mismatch is not None:
            failures.append(f"0x{pointer_address:08x}: {mismatch}")
        elif period != TIMER_PERIOD_NS:
            failures.append(
                f"0x{pointer_address:08x}: period {period}, expected {TIMER_PERIOD_NS}"
            )
        elif callback not in (OUTPUTTER_CALLBACK, WHOLE_CACHE_INVALIDATOR):
            failures.append(
                f"0x{pointer_address:08x}: unknown callback 0x{callback:08x}"
            )
        else:
            matches.append((timer, body))
    if len(matches) != 1:
        detail = "; ".join(failures) or "both reviewed timer slots are null"
        raise ValueError(
            f"expected exactly one guarded OUTPUTTER timer, found {len(matches)}: {detail}"
        )
    return matches[0]


def pool_guard(transport: AocFactoryDiag) -> None:
    pointer = int.from_bytes(transport.dump(POOL_POINTER, 4), "little")
    if pointer != POOL:
        raise ValueError(
            f"pool pointer guard mismatch: got 0x{pointer:08x}, expected 0x{POOL:08x}"
        )
    body = transport.dump(POOL, 0x60)
    head = u32(body, 0x1C)
    current = u32(body, 0x3C)
    if not head or current > 8:
        raise ValueError(
            f"unsafe pool state before timer enqueue: head=0x{head:08x}, current={current}"
        )


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", type=pathlib.Path, default=repository / "work/toolchains/platform-tools/adb")
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    parser.add_argument(
        "--wait-seconds",
        type=float,
        default=7.0,
        help="callback hijack duration; must exceed one five-second interval",
    )
    parser.add_argument(
        "operation", choices=("check", "apply-nop-and-flush")
    )
    parser.add_argument(
        "--ack-experimental-timer-hijack",
        action="store_true",
        help="required for apply-nop-and-flush",
    )
    args = parser.parse_args()
    if not 5.5 <= args.wait_seconds <= 20:
        parser.error("--wait-seconds must be 5.5..20")
    if args.operation != "check" and not args.ack_experimental_timer_hijack:
        parser.error("apply requires --ack-experimental-timer-hijack")
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
    pool_guard(transport)
    timer, body = timer_snapshot(transport)
    callback = u32(body, 0x28)
    branch = int.from_bytes(transport.dump(INVOKE_FAILURE_BRANCH, 2), "little")
    if branch not in (STOCK_BRANCH, DROP_CALLBACK_NOP):
        raise ValueError(
            f"unknown instruction at 0x{INVOKE_FAILURE_BRANCH:08x}: 0x{branch:04x}"
        )
    print(
        f"timer=0x{timer:08x} callback=0x{callback:08x}; "
        f"branch=0x{branch:04x}"
    )
    if args.operation == "check":
        return 0
    if callback != OUTPUTTER_CALLBACK or branch != STOCK_BRANCH:
        raise ValueError("apply requires exact stock callback and stock branch")

    # Write the dormant instruction first, then arrange for firmware-native
    # cache maintenance.  Always try to restore the callback; if that cannot
    # be proved, the operator must reboot rather than attempt further writes.
    transport.write_unverified(INVOKE_FAILURE_BRANCH, DROP_CALLBACK_NOP, 16)
    changed = int.from_bytes(transport.dump(INVOKE_FAILURE_BRANCH, 2), "little")
    if changed != DROP_CALLBACK_NOP:
        raise RuntimeError(f"instruction D-side readback is 0x{changed:04x}, expected 0xbf00")

    callback_address = timer + 0x28
    transport.write_unverified(callback_address, WHOLE_CACHE_INVALIDATOR, 32)
    armed = int.from_bytes(transport.dump(callback_address, 4), "little")
    if armed != WHOLE_CACHE_INVALIDATOR:
        raise RuntimeError(
            f"callback hijack readback is 0x{armed:08x}; reboot immediately"
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
                    f"timer object moved 0x{timer:08x}->0x{current_timer:08x}; reboot"
                )
            current_callback = u32(current_body, 0x28)
            if current_callback != WHOLE_CACHE_INVALIDATOR:
                raise RuntimeError(
                    f"callback changed unexpectedly to 0x{current_callback:08x}; reboot"
                )
            transport.write_unverified(callback_address, OUTPUTTER_CALLBACK, 32)
            restored = int.from_bytes(transport.dump(callback_address, 4), "little")
            if restored != OUTPUTTER_CALLBACK:
                raise RuntimeError(
                    f"callback restore readback 0x{restored:08x}; reboot immediately"
                )
        except Exception as error:  # Report the original exact recovery failure.
            restore_error = error
    if restore_error is not None:
        raise RuntimeError(f"callback restoration failed: {restore_error}")

    print(
        "callback restored; whole-cache invocation is timing-inferred only. "
        "Behaviorally test the NOP before treating the I-cache flush as proven; "
        "reboot is the only rollback."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
