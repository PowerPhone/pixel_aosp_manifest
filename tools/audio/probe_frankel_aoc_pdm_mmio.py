#!/usr/bin/env python3
"""Read an allowlisted Frankel AoC PDM-controller register snapshot.

The normal transport asks the A32 factory-diagnostic service to read its own
local controller window.  An explicitly acknowledged comparison transport can
also use aoc_core's stock read-only ``address`` sysfs attribute.  Neither path
offers an arbitrary address, and the FIFO-pop register at +0x0c is deliberately
absent from the allowlist.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import struct
import sys

from aoc_factory_diag import AocFactoryDiag


EXPECTED_DEVICE = "frankel"
EXPECTED_VENDOR_BUILD_ID = "CP2A.260805.005"
A32_CONTROLLER_BASE = 0x81C0A000
AOC_SRAM_CONTROLLER_OFFSET = 0x01C0A000
CONTROLLER_STRIDE = 0x1000
CONTROLLER_IDS = tuple(range(5))

# +0x0c is the destructive FIFO pop and must never be added here.  Clock,
# reset, and gate registers are in different blocks and are likewise excluded.
REGISTERS = (
    (0x00, "control"),
    (0x04, "enable"),
    (0x10, "fifo_status"),
    (0x14, "fifo_watermark"),
    (0x24, "config_24"),
    (0x28, "config_28"),
    (0x2C, "raw_enable"),
)
CAPTURE_STATUS_PATHS = (
    "/proc/asound/card0/pcm8c/sub0/status",
    "/proc/asound/card0/pcm12c/sub0/status",
)
SYSFS_ADDRESS_PATHS = (
    "/sys/bus/platform/devices/9000000.aoc/address",
    "/sys/devices/platform/9000000.aoc/address",
)


def integer(value: str) -> int:
    return int(value, 0)


def parse_controller(value: str) -> tuple[int, ...]:
    if value == "all":
        return CONTROLLER_IDS
    controller = integer(value)
    if controller not in CONTROLLER_IDS:
        raise argparse.ArgumentTypeError("controller must be 0..4 or all")
    return (controller,)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description=(
            "Read only the allowlisted Frankel AoC PDM-controller registers"
        )
    )
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument(
        "--controller", type=parse_controller, default=(4,), metavar="0..4|all"
    )
    parser.add_argument(
        "--transport",
        choices=("a32", "ap-sysfs", "compare"),
        default="a32",
        help="A32 diagnostic read (default), AP projection, or both",
    )
    parser.add_argument(
        "--ack-ap-mmio-risk",
        action="store_true",
        help=(
            "required for ap-sysfs/compare: acknowledge that even a read from "
            "a gated or firewalled MMIO block can cause a synchronous error"
        ),
    )
    parser.add_argument(
        "--allow-active-capture",
        action="store_true",
        help="permit one coordinated snapshot while a capture PCM is active",
    )
    parser.add_argument("--counter", type=integer)
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def adb_text(transport: AocFactoryDiag, *arguments: str) -> str:
    result = transport.run(*arguments)
    return result.stdout.decode(errors="replace").strip()


def preflight(
    transport: AocFactoryDiag, allow_active_capture: bool
) -> tuple[dict[str, str], dict[str, str]]:
    if adb_text(transport, "get-state") != "device":
        raise RuntimeError("ADB target is not online")
    identity = {
        "device": adb_text(transport, "shell", "getprop", "ro.product.device"),
        "vendor_build_id": adb_text(
            transport, "shell", "getprop", "ro.vendor.build.id"
        ),
        "boot_completed": adb_text(
            transport, "shell", "getprop", "sys.boot_completed"
        ),
        "kernel_release": adb_text(transport, "shell", "uname", "-r"),
    }
    if identity["device"] != EXPECTED_DEVICE:
        raise RuntimeError(
            f"refusing non-Frankel target: {identity['device']!r}"
        )
    if identity["vendor_build_id"] != EXPECTED_VENDOR_BUILD_ID:
        raise RuntimeError(
            "refusing an unreviewed Frankel vendor build: "
            f"{identity['vendor_build_id']!r}"
        )
    if identity["boot_completed"] != "1":
        raise RuntimeError("Frankel has not completed boot")
    if adb_text(transport, "shell", "su", "0", "id", "-u") != "0":
        raise RuntimeError("a root shell is required")

    statuses: dict[str, str] = {}
    for path in CAPTURE_STATUS_PATHS:
        result = transport.run("shell", "su", "0", "cat", path, check=False)
        statuses[path] = (
            result.stdout.decode(errors="replace").strip()
            if result.returncode == 0
            else "unavailable"
        )
    non_idle = {
        path: status for path, status in statuses.items() if status != "closed"
    }
    if non_idle and not allow_active_capture:
        detail = "; ".join(f"{path}={value!r}" for path, value in non_idle.items())
        raise RuntimeError(
            "capture idleness cannot be established; stop capture or pass "
            f"--allow-active-capture for one coordinated snapshot ({detail})"
        )
    return identity, statuses


def find_sysfs_address(transport: AocFactoryDiag) -> str:
    for path in SYSFS_ADDRESS_PATHS:
        result = transport.run("shell", "su", "0", "test", "-r", path, check=False)
        if result.returncode == 0:
            writable = transport.run(
                "shell", "su", "0", "test", "-w", path, check=False
            )
            if writable.returncode:
                raise RuntimeError(f"stock AoC address selector is not writable: {path}")
            return path
    raise RuntimeError("stock aoc_core address sysfs attribute was not found")


def read_a32(transport: AocFactoryDiag, address: int) -> int:
    return struct.unpack("<I", transport.dump(address, 4))[0]


def read_ap_sysfs(transport: AocFactoryDiag, path: str, offset: int) -> int:
    # address_store only changes aoc_core's selector.  address_show performs the
    # actual readl.  Keep selection and read in one root shell to reduce races.
    command = f"printf '%s\\n' {offset} > {path} && cat {path}"
    result = transport.run("shell", "su", "0", "sh", "-c", command)
    text = result.stdout.decode(errors="replace").strip()
    try:
        return int(text, 0) & 0xFFFFFFFF
    except ValueError as error:
        raise RuntimeError(f"unexpected {path} value: {text!r}") from error


def snapshot(
    transport: AocFactoryDiag,
    controllers: tuple[int, ...],
    mode: str,
) -> list[dict[str, int | str | bool]]:
    sysfs_path = find_sysfs_address(transport) if mode != "a32" else None
    rows: list[dict[str, int | str | bool]] = []
    for controller in controllers:
        for register_offset, name in REGISTERS:
            a32_address = (
                A32_CONTROLLER_BASE
                + controller * CONTROLLER_STRIDE
                + register_offset
            )
            sram_offset = (
                AOC_SRAM_CONTROLLER_OFFSET
                + controller * CONTROLLER_STRIDE
                + register_offset
            )
            row: dict[str, int | str | bool] = {
                "controller": controller,
                "register": name,
                "register_offset": register_offset,
                "a32_address": a32_address,
                "aoc_sram_offset": sram_offset,
            }
            if mode in ("a32", "compare"):
                row["a32_value"] = read_a32(transport, a32_address)
            if mode in ("ap-sysfs", "compare"):
                assert sysfs_path is not None
                row["ap_value"] = read_ap_sysfs(
                    transport, sysfs_path, sram_offset
                )
            if mode == "compare":
                row["values_match"] = row["a32_value"] == row["ap_value"]
            rows.append(row)
    return rows


def print_text(
    identity: dict[str, str],
    statuses: dict[str, str],
    rows: list[dict[str, int | str | bool]],
) -> None:
    print(
        f"target={identity['device']} vendor_build={identity['vendor_build_id']} "
        f"kernel={identity['kernel_release']}"
    )
    for path, status in statuses.items():
        print(f"capture_status {path}: {' '.join(status.splitlines())}")
    for row in rows:
        fields = [
            f"pdm{row['controller']}",
            f"{row['register']}+0x{row['register_offset']:02x}",
            f"a32@0x{row['a32_address']:08x}",
            f"sram+0x{row['aoc_sram_offset']:08x}",
        ]
        if "a32_value" in row:
            fields.append(f"a32=0x{row['a32_value']:08x}")
        if "ap_value" in row:
            fields.append(f"ap=0x{row['ap_value']:08x}")
        if "values_match" in row:
            fields.append(f"match={str(row['values_match']).lower()}")
        print(" ".join(fields))


def main() -> int:
    args = parse_args()
    if args.transport != "a32" and not args.ack_ap_mmio_risk:
        raise ValueError(
            "--transport ap-sysfs/compare requires --ack-ap-mmio-risk"
        )
    transport_args = argparse.Namespace(
        adb=args.adb,
        adb_server_port=args.adb_server_port,
        serial=args.serial,
        core=1,
        counter=args.counter,
    )
    transport = AocFactoryDiag(transport_args)
    identity, statuses = preflight(transport, args.allow_active_capture)
    rows = snapshot(transport, args.controller, args.transport)
    if args.json:
        print(
            json.dumps(
                {
                    "identity": identity,
                    "capture_status": statuses,
                    "registers": rows,
                },
                indent=2,
                sort_keys=True,
            )
        )
    else:
        print_text(identity, statuses, rows)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
