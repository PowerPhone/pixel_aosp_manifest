#!/usr/bin/env python3
"""Send guarded generic AoC commands through the factory_diag service.

This is intentionally a small transport/debug utility.  Device-specific live
patch policy belongs in a separate script with exact before/after byte guards.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import struct
import subprocess
import sys
import time


CMD_DBG_MEM_SET = 0x25
CMD_DBG_MEM_DUMP = 0x26
DATA_TYPE_CMD = 0
DEVICE = "/dev/acd-factory_diag"
DEBUG_DEVICE = "/dev/acd-debug"


def integer(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    default_adb = repository / "work/toolchains/platform-tools/adb"
    parser = argparse.ArgumentParser(
        description="Read or write AoC memory through the production factory_diag service"
    )
    parser.add_argument("--adb", type=pathlib.Path, default=default_adb)
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--core", type=integer, default=2, help="1=A32, 2=F1, 3=H0, 4=H1")
    parser.add_argument("--counter", type=integer, help="explicit u8 command counter")
    subparsers = parser.add_subparsers(dest="operation", required=True)

    dump = subparsers.add_parser("dump", help="dump readable AoC memory")
    dump.add_argument("address", type=integer)
    dump.add_argument("size", type=integer)

    write = subparsers.add_parser("write", help="write one guarded AoC memory value")
    write.add_argument("address", type=integer)
    write.add_argument("value", type=integer)
    write.add_argument("--width", type=int, choices=(8, 16, 32), required=True)
    write.add_argument(
        "--expected",
        type=integer,
        required=True,
        help="refuse the write unless a pre-read has this value",
    )
    return parser.parse_args()


class AocFactoryDiag:
    def __init__(self, args: argparse.Namespace) -> None:
        self.adb = str(args.adb)
        self.port = str(args.adb_server_port)
        self.serial = args.serial
        self.core = args.core
        self.counter = args.counter if args.counter is not None else time.monotonic_ns() & 0xFF
        # An opt-in device-side helper avoids one blocking toybox ``dd``
        # reader per transaction.  Keep the shell transport as a bootstrap
        # fallback because the helper is normally pushed only for live porting
        # sessions and is not shipped in production images.
        self.native_helper = os.environ.get("FRANKEL_AOC_DIAG_DEVICE")
        if not 1 <= self.core <= 4:
            raise ValueError("core must be 1..4")
        if not 0 <= self.counter <= 0xFF:
            raise ValueError("counter must fit in u8")
        if not pathlib.Path(self.adb).is_file():
            raise ValueError(f"adb is not a file: {self.adb}")

    def adb_command(self, *arguments: str) -> list[str]:
        command = [self.adb, "-P", self.port]
        if self.serial:
            command += ["-s", self.serial]
        return command + list(arguments)

    def run(self, *arguments: str, input_data: bytes | None = None, check: bool = True) -> subprocess.CompletedProcess[bytes]:
        environment = os.environ.copy()
        environment["ADB_LIBUSB"] = "1"
        result = subprocess.run(
            self.adb_command(*arguments),
            input=input_data,
            capture_output=True,
            env=environment,
            check=False,
        )
        if check and result.returncode:
            stderr = result.stderr.decode(errors="replace").strip()
            raise RuntimeError(f"adb command failed ({result.returncode}): {stderr}")
        return result

    def clear_debug(self) -> None:
        self.run(
            "shell", "su", "0", "timeout", "0.1", "cat", DEBUG_DEVICE, check=False
        )

    def debug_output(self) -> str:
        # The factory reply has already completed before this separate debug
        # drain.  Fractional polling keeps guarded patch passes practical; the
        # dump path still retries three reads across three idempotent commands
        # and therefore fails closed if a busy AoC delays the formatted lines.
        result = self.run(
            "shell", "su", "0", "timeout", "0.2", "cat", DEBUG_DEVICE, check=False
        )
        return result.stdout.decode(errors="replace")

    def transact(self, command_id: int, payload: bytes) -> str:
        length = 8 + len(payload)
        packet = struct.pack(
            "<BBHHh", DATA_TYPE_CMD, self.counter, length, command_id, 0
        ) + payload
        self.clear_debug()
        self.run(
            "shell",
            "su",
            "0",
            "dd",
            f"of={DEVICE}",
            f"bs={len(packet)}",
            "count=1",
            input_data=packet,
        )
        # Do not use ``timeout 2 dd ...`` here.  On Android toybox, killing the
        # timeout wrapper can leave its dd child reparented to init.  That
        # orphan keeps the factory-diag reader open and consumes the response
        # to a later transaction.  Track the reader's exact PID and always
        # reap or SIGKILL it in the same remote shell instead.
        reader = (
            "dd if=/dev/acd-factory_diag bs=4096 count=1 2>/dev/null & "
            "reader=$!; "
            "(sleep 2; kill -9 $reader 2>/dev/null) >/dev/null 2>&1 & killer=$!; "
            "wait $reader; status=$?; "
            "kill $killer 2>/dev/null; wait $killer 2>/dev/null; "
            "exit $status"
        )
        response_result = self.run(
            "shell", f"su 0 sh -c '{reader}'", check=False
        )
        # A force-killed reader normally reports 137.  Treat it like a timeout
        # below, where the short-response guard produces the useful error.
        if response_result.returncode not in (0, 137):
            stderr = response_result.stderr.decode(errors="replace").strip()
            raise RuntimeError(
                f"factory_diag read failed ({response_result.returncode}): {stderr}"
            )
        response = response_result.stdout
        if len(response) < 8:
            raise RuntimeError(f"short factory_diag response: {response.hex()}")
        response_type, response_counter, response_len, response_id, reply = struct.unpack_from(
            "<BBHHh", response
        )
        if response_type != DATA_TYPE_CMD or response_counter != self.counter:
            raise RuntimeError(f"unexpected factory_diag response header: {response[:8].hex()}")
        if response_id != command_id or response_len != len(response):
            raise RuntimeError(
                f"unexpected factory_diag response id/length: {response[:8].hex()} actual={len(response)}"
            )
        if reply != 0:
            raise RuntimeError(f"AoC command 0x{command_id:04x} failed with reply {reply}")
        return self.debug_output()

    def dump(self, address: int, size: int) -> bytes:
        if not 0 <= address <= 0xFFFFFFFF:
            raise ValueError("address must fit in u32")
        if not 1 <= size <= 256:
            raise ValueError("dump size must be 1..256 bytes")
        if self.native_helper:
            result = self.run(
                "shell",
                "su",
                "0",
                self.native_helper,
                "--core",
                str(self.core),
                "dump",
                hex(address),
                str(size),
            )
            output = result.stdout.decode(errors="replace").strip()
            try:
                data = bytes.fromhex(output)
            except ValueError as error:
                raise RuntimeError(
                    f"native AoC dump returned non-hex output: {output!r}"
                ) from error
            if len(data) != size:
                raise RuntimeError(
                    f"native AoC dump returned {len(data)} bytes, expected {size}: "
                    f"{output}"
                )
            return data
        payload = struct.pack("<iII", self.core, address, size)
        diagnostics: list[str] = []
        # Factory-diag acknowledges the command separately from /dev/acd-debug.
        # Busy USF builds can interleave enough asynchronous statistics that
        # the requested memory lines arrive in a later debug read.  Collect
        # delayed output first, then retry only this idempotent read command.
        # Writes are deliberately never retried by this transport.
        for command_attempt in range(3):
            diagnostics.append(self.transact(CMD_DBG_MEM_DUMP, payload))
            for debug_attempt in range(3):
                wanted = address
                collected = bytearray()
                debug = "\n".join(diagnostics)
                for match in re.finditer(
                    r"0x([0-9a-fA-F]+):((?:\s+[0-9a-fA-F]{2})+)", debug
                ):
                    line_address = int(match.group(1), 16)
                    line_data = bytes.fromhex(match.group(2))
                    if line_address == wanted:
                        collected.extend(line_data)
                        wanted += len(line_data)
                if len(collected) >= size:
                    return bytes(collected[:size])
                if debug_attempt + 1 < 3:
                    diagnostics.append(self.debug_output())
            if command_attempt + 1 < 3:
                time.sleep(0.002)
        raise RuntimeError(
            f"AoC dump output did not contain 0x{address:08x}+{size} after "
            f"3 read-only command attempts; debug output:\n" + "\n".join(diagnostics)
        )

    def write(self, address: int, value: int, width: int) -> None:
        modes = {32: 0, 16: 1, 8: 2}
        maximum = (1 << width) - 1
        if not 0 <= address <= 0xFFFFFFFF or not 0 <= value <= maximum:
            raise ValueError(f"address/value do not fit u32/u{width}")
        if self.native_helper:
            current = int.from_bytes(self.dump(address, width // 8), "little")
            self.run(
                "shell",
                "su",
                "0",
                self.native_helper,
                "--core",
                str(self.core),
                "write",
                str(width),
                hex(address),
                hex(current),
                hex(value),
            )
            return
        self.transact(
            CMD_DBG_MEM_SET,
            struct.pack("<iIIB", self.core, address, value, modes[width]),
        )

    def write_unverified(self, address: int, value: int, width: int) -> None:
        """Issue exactly one memory-set command without a read-back.

        This is intentionally separate from :meth:`write`: callers must have
        validated a coherent snapshot before entering a multi-word update and
        must verify the complete result afterward.  It exists for large,
        already-guarded live profiles where repeating dump/set/dump for every
        word can itself exhaust AoC's diagnostic work pool.
        """

        modes = {32: 0, 16: 1, 8: 2}
        if width not in modes:
            raise ValueError("width must be 8, 16, or 32")
        maximum = (1 << width) - 1
        width_bytes = width // 8
        if (
            not 0 <= address <= 0xFFFFFFFF
            or address % width_bytes
            or not 0 <= value <= maximum
        ):
            raise ValueError(f"address/value do not fit aligned u{width}")

        # New helpers support a single-command raw write while retaining the
        # device-side target check and transaction lock.  An older deployed
        # helper rejects the unknown operation with usage status 64; falling
        # back is safe because that rejection occurs before any AoC command.
        if self.native_helper:
            result = self.run(
                "shell",
                "su",
                "0",
                self.native_helper,
                "--core",
                str(self.core),
                "write-raw",
                str(width),
                hex(address),
                hex(value),
                check=False,
            )
            if result.returncode == 0:
                return
            if result.returncode != 64:
                stderr = result.stderr.decode(errors="replace").strip()
                raise RuntimeError(
                    f"native raw AoC write failed ({result.returncode}): {stderr}"
                )

        self.transact(
            CMD_DBG_MEM_SET,
            struct.pack("<iIIB", self.core, address, value, modes[width]),
        )
        self.counter = (self.counter + 1) & 0xFF


def main() -> int:
    args = parse_args()
    transport = AocFactoryDiag(args)
    if args.operation == "dump":
        data = transport.dump(args.address, args.size)
        print(data.hex())
        return 0

    width_bytes = args.width // 8
    current_bytes = transport.dump(args.address, width_bytes)
    current = int.from_bytes(current_bytes, "little")
    if current != args.expected:
        raise ValueError(
            f"guard mismatch at 0x{args.address:08x}: got 0x{current:0{width_bytes * 2}x}, "
            f"expected 0x{args.expected:0{width_bytes * 2}x}"
        )
    transport.write(args.address, args.value, args.width)
    actual = int.from_bytes(transport.dump(args.address, width_bytes), "little")
    if actual != args.value:
        raise RuntimeError(
            f"write verification failed at 0x{args.address:08x}: got 0x{actual:0{width_bytes * 2}x}"
        )
    print(f"0x{args.address:08x}: 0x{current:0{width_bytes * 2}x} -> 0x{actual:0{width_bytes * 2}x}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
