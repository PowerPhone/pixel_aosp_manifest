#!/usr/bin/env python3
"""Read-only guard probe for Frankel's A32 VD6282/PDM object graph.

This utility never issues CMD_DBG_MEM_SET.  It follows a dynamic pointer only
after checking alignment and that it falls in one of the two A32 address
windows observed in the stock CP2A.260805.005 firmware.
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys
from types import SimpleNamespace

from aoc_factory_diag import AocFactoryDiag


PDM_HANDLE_LIST = 0x40130E88
CLOCK_DIVIDER_REGISTERS = 0x824D1020
CLOCK_SOURCE_REGISTERS = 0x824D0E00
CLOCK_GATE_CONTROL = 0x824D07A0
CLOCK_GATE_STATUS = 0x824D07BC
PDM_VTABLE = 0x400F99F4
CLOCK_VTABLE = 0x400F9AC4
VD6282_PDM_CALLBACK = 0x400AD01D
STOCK_PCM_RATE = 16000
STOCK_PDM_CLOCK = 3200000
STOCK_CLOCK_PARENT = 38400000
STOCK_CLOCK_DIVIDER = 12


def integer(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Read and validate the Frankel A32 VD6282/PDM object graph"
    )
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument(
        "--pdm-id",
        type=integer,
        choices=range(5),
        default=4,
        help="expected controller ID (stock VD6282 is 4)",
    )
    return parser.parse_args()


def u32(data: bytes, offset: int = 0) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def valid_a32_pointer(pointer: int) -> bool:
    if pointer & 3:
        return False
    return (0x40000000 <= pointer < 0x41000000) or (
        0x78000000 <= pointer < 0x79000000
    )


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def checked_pointer(pointer: int, name: str) -> int:
    require(valid_a32_pointer(pointer), f"invalid {name} pointer 0x{pointer:08x}")
    return pointer


def main() -> int:
    args = parse_args()
    transport = AocFactoryDiag(
        SimpleNamespace(
            adb=args.adb,
            adb_server_port=args.adb_server_port,
            serial=args.serial,
            core=1,
            counter=None,
        )
    )

    handle = u32(transport.dump(PDM_HANDLE_LIST, 4))
    checked_pointer(handle, "PDM-list head")
    selected: tuple[int, bytes] | None = None

    for index in range(5):
        header = transport.dump(handle, 64)
        pdm_id = header[5]
        pcm_rate = u32(header, 8)
        print(
            f"handle[{index}]=0x{handle:08x} id={pdm_id} "
            f"pcm_rate={pcm_rate} next=0x{u32(header, 60):08x}"
        )
        if pdm_id == args.pdm_id:
            selected = (handle, header)
            break
        next_handle = u32(header, 60)
        require(next_handle != 0, f"PDM ID {args.pdm_id} is not in the handle list")
        handle = checked_pointer(next_handle, "next PDM handle")

    require(selected is not None, f"PDM ID {args.pdm_id} was not found")
    handle, header = selected
    require(u32(header, 8) == STOCK_PCM_RATE, "unexpected normal PCM rate")
    require(u32(header, 20) == VD6282_PDM_CALLBACK, "unexpected PDM callback")

    main_object = checked_pointer(u32(header, 12), "main PDM object")
    client = checked_pointer(u32(header, 24), "VD6282 client")
    client_handle = u32(transport.dump(client + 0x6C, 4))
    require(client_handle == handle, "client/handle cross-reference mismatch")
    client_config = transport.dump(client + 0x14C, 20)
    client_clock = u32(client_config, 0)
    client_mode = client_config[8]
    client_chunk = u32(client_config, 12)

    main_data = transport.dump(main_object, 116)
    require(u32(main_data, 0) == PDM_VTABLE, "unexpected main PDM vtable")
    clock_object = checked_pointer(u32(main_data, 20), "PDM clock object")
    cached_clock = u32(main_data, 112)

    clock_data = transport.dump(clock_object, 20)
    require(u32(clock_data, 0) == CLOCK_VTABLE, "unexpected PDM clock vtable")
    require(u32(clock_data, 8) == 2, "unexpected PDM clock index")
    require(
        u32(clock_data, 12) == STOCK_CLOCK_PARENT,
        "unexpected PDM clock parent rate",
    )

    divider_registers = struct.unpack(
        "<III", transport.dump(CLOCK_DIVIDER_REGISTERS, 12)
    )
    source_registers = struct.unpack(
        "<III", transport.dump(CLOCK_SOURCE_REGISTERS, 12)
    )
    gate_control = struct.unpack(
        "<II", transport.dump(CLOCK_GATE_CONTROL, 8)
    )
    gate_status = u32(transport.dump(CLOCK_GATE_STATUS, 4))
    divider_register = divider_registers[1]
    divider = divider_register & 0x3F
    require(divider == STOCK_CLOCK_DIVIDER, "unexpected live PDM clock divider")
    require(cached_clock == STOCK_PDM_CLOCK, "unexpected cached PDM clock")

    print(
        f"client=0x{client:08x} mode={client_mode} "
        f"clock={client_clock} chunk={client_chunk}"
    )
    print(
        f"main=0x{main_object:08x} clock_object=0x{clock_object:08x} "
        f"cached_clock={cached_clock}"
    )
    print(
        "clock_divider_regs="
        f"0x{divider_registers[0]:08x},0x{divider_registers[1]:08x},"
        f"0x{divider_registers[2]:08x} divider={divider}"
    )
    print(
        "clock_source_regs="
        f"0x{source_registers[0]:08x},0x{source_registers[1]:08x},"
        f"0x{source_registers[2]:08x}"
    )
    print(
        "clock_gate_regs="
        f"0x{gate_control[0]:08x},0x{gate_control[1]:08x} "
        f"status=0x{gate_status:08x} status_bit8={(gate_status >> 8) & 1}"
    )
    print("all read-only Frankel A32 Direct1 guards passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
