#!/usr/bin/env python3
"""Guarded one-shot probe for the Frankel AoC ultrasonic Stream object.

This is a reboot-volatile diagnostic.  It redirects CMD 0x146 through a short
scalar Xtensa trampoline, records the handler's Stream pointer in an otherwise
unused AoC code-padding word, and resumes the original handler.  It does not
read or write the AP-side PDM MMIO projection.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag


LITERAL_ADDRESS = 0x4038FAE8
RESULT_ADDRESS = 0x4038FAEC
TEXT_ADDRESS = 0x4038FB34
ROUTE_ADDRESS = 0x4038FB56

LITERAL_STOCK = bytes(4)
LITERAL_PROBE = bytes.fromhex("ecfa3840")
TEXT_STOCK = bytes(12)
TEXT_PROBE = bytes.fromhex("b2224ea1ecffb90a46060000")
ROUTE_STOCK = bytes.fromhex("b2224e")
ROUTE_PROBE = bytes.fromhex("86f6ff")


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "read", "revert", "check-stock"))
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    return parser.parse_args()


def transport_for(args: argparse.Namespace) -> AocFactoryDiag:
    return AocFactoryDiag(
        argparse.Namespace(
            adb=args.adb,
            adb_server_port=args.adb_server_port,
            serial=args.serial,
            core=2,
            counter=args.counter,
        )
    )


def guarded_write(
    transport: AocFactoryDiag, address: int, before: bytes, after: bytes
) -> None:
    actual = transport.dump(address, len(before))
    if actual != before:
        raise ValueError(
            f"guard mismatch at 0x{address:08x}: got {actual.hex()}, "
            f"expected {before.hex()}"
        )
    if address & 0x3 == 0 and len(before) & 0x3 == 0:
        for offset in range(0, len(before), 4):
            old_word = before[offset : offset + 4]
            new_word = after[offset : offset + 4]
            if old_word != new_word:
                transport.write(
                    address + offset, int.from_bytes(new_word, "little"), 32
                )
    else:
        for offset, (old_byte, new_byte) in enumerate(
            zip(before, after, strict=True)
        ):
            if old_byte != new_byte:
                transport.write(address + offset, new_byte, 8)
    actual = transport.dump(address, len(after))
    if actual != after:
        raise RuntimeError(
            f"verification failed at 0x{address:08x}: got {actual.hex()}, "
            f"expected {after.hex()}"
        )


def restore_unreachable_mixed(
    transport: AocFactoryDiag, address: int, stock: bytes, probe: bytes
) -> None:
    """Restore a partially written cave after its route is proven stock."""
    actual = transport.dump(address, len(stock))
    for offset, (actual_byte, stock_byte, probe_byte) in enumerate(
        zip(actual, stock, probe, strict=True)
    ):
        if actual_byte not in (stock_byte, probe_byte):
            raise ValueError(
                f"unexpected mixed byte at 0x{address + offset:08x}: "
                f"0x{actual_byte:02x}"
            )
    if actual != stock:
        # The route has already been disconnected, so aligned word restores are
        # both faster and less exposed to an interrupted diagnostic session.
        if address & 0x3 == 0 and len(stock) & 0x3 == 0:
            for offset in range(0, len(stock), 4):
                if actual[offset : offset + 4] != stock[offset : offset + 4]:
                    transport.write(
                        address + offset,
                        int.from_bytes(stock[offset : offset + 4], "little"),
                        32,
                    )
        else:
            for offset, (actual_byte, stock_byte) in enumerate(
                zip(actual, stock, strict=True)
            ):
                if actual_byte != stock_byte:
                    transport.write(address + offset, stock_byte, 8)
    restored = transport.dump(address, len(stock))
    if restored != stock:
        raise RuntimeError(
            f"mixed-site restore failed at 0x{address:08x}: {restored.hex()}"
        )


def main() -> int:
    args = parse_args()
    transport = transport_for(args)

    literal = transport.dump(LITERAL_ADDRESS, 4)
    text = transport.dump(TEXT_ADDRESS, 12)
    route = transport.dump(ROUTE_ADDRESS, 3)
    result = transport.dump(RESULT_ADDRESS, 4)

    if args.action == "read":
        if literal != LITERAL_PROBE or text != TEXT_PROBE or route != ROUTE_PROBE:
            raise ValueError("pointer probe is not uniformly installed")
        pointer = int.from_bytes(result, "little")
        print(f"0x{RESULT_ADDRESS:08x}: 0x{pointer:08x}")
        if not 0x40000000 <= pointer < 0x41000000 or pointer & 0x3:
            raise ValueError("recorded value is not an aligned AoC-local pointer")
        return 0

    if args.action == "check-stock":
        if (
            literal != LITERAL_STOCK
            or result != bytes(4)
            or text != TEXT_STOCK
            or route != ROUTE_STOCK
        ):
            raise ValueError(
                "probe sites are not stock: "
                f"literal={literal.hex()} result={result.hex()} "
                f"text={text.hex()} route={route.hex()}"
            )
        print("all pointer-probe sites are stock")
        return 0

    if args.action == "apply":
        if result != bytes(4):
            raise ValueError(f"result word is not clear: {result.hex()}")
        # Make both data and code complete before redirecting execution.
        guarded_write(transport, LITERAL_ADDRESS, LITERAL_STOCK, LITERAL_PROBE)
        guarded_write(transport, TEXT_ADDRESS, TEXT_STOCK, TEXT_PROBE)
        guarded_write(transport, ROUTE_ADDRESS, ROUTE_STOCK, ROUTE_PROBE)
        print("pointer probe installed; start one D12 capture, then run read")
        return 0

    # Disconnect the trampoline first.  The result is runtime data, so accept
    # either the untouched zero word or one aligned AoC-local pointer.
    if route == ROUTE_PROBE:
        guarded_write(transport, ROUTE_ADDRESS, ROUTE_PROBE, ROUTE_STOCK)
    elif route != ROUTE_STOCK:
        raise ValueError(f"unexpected route bytes: {route.hex()}")
    restore_unreachable_mixed(
        transport, TEXT_ADDRESS, TEXT_STOCK, TEXT_PROBE
    )
    restore_unreachable_mixed(
        transport, LITERAL_ADDRESS, LITERAL_STOCK, LITERAL_PROBE
    )
    current_result = transport.dump(RESULT_ADDRESS, 4)
    current_value = int.from_bytes(current_result, "little")
    if current_value and not (
        0x40000000 <= current_value < 0x41000000 and current_value & 0x3 == 0
    ):
        raise ValueError(f"refusing to clear unexpected result: {current_result.hex()}")
    if current_value:
        transport.write(RESULT_ADDRESS, 0, 32)
    print("pointer probe reverted and result cleared")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
