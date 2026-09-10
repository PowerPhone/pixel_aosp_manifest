#!/usr/bin/env python3
"""Guarded Frankel A32 raw-PDM controller handoff for AP polling.

The default operation is read-only.  ``apply`` and ``revert`` use the AoC
factory diagnostic service on core 1 and require explicit acknowledgements.
No operation writes the controller's +0x04 interrupt-enable register.

This is tied to Frankel vendor build CP2A.260805.005.  It is an experimental
research handoff, not a production audio path.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import re
import struct
import sys
import tempfile
import time
from dataclasses import dataclass
from types import SimpleNamespace
from typing import Any, Callable

from aoc_factory_diag import AocFactoryDiag


EXPECTED_DEVICE = "frankel"
EXPECTED_VENDOR_BUILD_ID = "CP2A.260805.005"
SNAPSHOT_VERSION = 5

PDM_HANDLE_LIST = 0x40130E88
CONTROLLER_BASE = 0x81C0A000
CONTROLLER_STRIDE = 0x1000
ALL_CONTROLLERS = tuple(range(5))
BUILTIN_DMIC_CONTROLLERS = (0, 2, 3)

# PdmClockV2 is constructed with index 2 for every generic PDM handle.  The
# live object's base/stride fields are authoritative: source 0x024d0de0 with
# stride 0x10, divider 0x024d1000 with stride 0x10, and gate 0x024d0760 with
# stride 0x20.  The A32 peripheral alias adds 0x80000000.  A value-preserving
# real-device trial on CP2A.260805.005 proved that stores to these resolved
# registers raise the corresponding status acknowledgements.
CLOCK_SOURCE_CONFIG = 0x824D0E00
CLOCK_SOURCE_VALUE = 0x824D0E04
CLOCK_SOURCE_STATUS = 0x824D0E08
CLOCK_DIVIDER_CONFIG = 0x824D1020
CLOCK_DIVIDER_VALUE = 0x824D1024
CLOCK_DIVIDER_STATUS = 0x824D1028
CLOCK_GATE_CONFIG = 0x824D07A0
CLOCK_GATE_ENABLE = 0x824D07A4
CLOCK_GATE_STATUS = 0x824D07BC
CLOCK_PARENT_HZ = 38_400_000
STOCK_CLOCK_DIVIDER = 12
RAW_CLOCK_DIVIDER = 8
RAW_CLOCK_HZ = CLOCK_PARENT_HZ // RAW_CLOCK_DIVIDER
PDM_VTABLE = 0x400F99F4
CLOCK_VTABLE = 0x400F9AC4
VD6282_PDM_CALLBACK = 0x400AD01D
STOCK_PDM_RATE = 16_000
STOCK_PDM_CLOCK_HZ = 3_200_000
CLOCK_OBJECT_BASES_AND_STRIDES = (
    0x024D0DE0,
    0x024D0DE4,
    0x024D0DE8,
    0x024D1000,
    0x024D1004,
    0x024D1008,
    0x024D0760,
    0x024D0764,
    0x024D077C,
    0x10,
    0x10,
    0x20,
)

RESET_CONTROL = 0x81400000
RESET_STATUS = 0x81400008
# PdmClockV2's separate vtable +0x28 method owns the low nibble of
# PDM_GLOBAL_CONFIG under a firmware lock.  Frankel's stock idle value is
# already 0x000001ff, including low nibble 0xf, and a stock PDM4 session leaves
# it unchanged.  The helper therefore treats the complete word as stock-owned
# read-only state and never emulates the method.
PDM_GLOBAL_CONFIG = 0x81401000
STOCK_PDM_GLOBAL_CONFIG = 0x000001FF

# PdmV3 stores this address at M+0x64.  Its start method sets bit 0 before
# enabling the clock; its stop method disables the clock before clearing bit
# 0.  Real stock PDM4 activity proved the exact 0 -> 1 -> 0 transition, while
# a reversible gate-only trial left it zero.  With every other PDM owner
# excluded, this helper can reproduce that exact guarded control sequence.
PDM_ACTIVITY_CONTROL = 0x8140100C
PDM_ACTIVITY_ACTIVE = 1

REG_CONTROL = 0x00
REG_IRQ_ENABLE = 0x04
REG_FIFO_POP = 0x0C  # destructive; deliberately never read by this tool
REG_FIFO_STATUS = 0x10
REG_WATERMARK = 0x14
REG_CONFIG_24 = 0x24
REG_CONFIG_28 = 0x28
REG_RAW_CONFIG = 0x2C
REG_CONFIG_30 = 0x30

CONTROL_ENABLE = 1 << 0
CONTROL_SELECTED = 1 << 2
CONTROL_NORMAL_MODE = 1 << 18
CONTROL_RAW_MODE = 1 << 22
CONTROL_START_BITS = CONTROL_ENABLE | CONTROL_NORMAL_MODE | CONTROL_RAW_MODE
RAW_CONTROL_CLEAR_MASK = 0xFFBBFFFE
RAW_CONTROL_SET = CONTROL_RAW_MODE | CONTROL_ENABLE
IRQ_ENABLE = 1 << 0
FIFO_EMPTY = 1 << 0
RAW_CONFIG_HPF_BYPASS = 1 << 1
CONFIG_30_CHANNEL_BITS = (1 << 0) | (1 << 4)
CONFIG_30_COMMIT = 1 << 9
RESET_MASK = 0x1F

PREPARED_HOLDER_EXE = "/data/local/tmp/frankel_pcm_hold"
PREPARED_HOLDER_CARD = 0
PREPARED_HOLDER_DEVICE = 8
PREPARED_HOLDER_FD = 3
PREPARED_HOLDER_CONTROLLER = 0
PREPARED_HOLDER_PCM = "/dev/snd/pcmC0D8c"
PREPARED_CONTROL = 0x003C0007
PREPARED_WATERMARK = 2
PREPARED_CONFIG_24 = 0
PREPARED_CONFIG_28 = 4
PREPARED_RAW_CONFIG = 0x00001002
PREPARED_CONFIG_30 = CONFIG_30_CHANNEL_BITS

SAFE_CONTROLLER_OFFSETS = (
    REG_CONTROL,
    REG_IRQ_ENABLE,
    REG_FIFO_STATUS,
    REG_WATERMARK,
    REG_CONFIG_24,
    REG_CONFIG_28,
    REG_RAW_CONFIG,
    REG_CONFIG_30,
)
RESTORABLE_CONTROLLER_OFFSETS = (
    REG_WATERMARK,
    REG_CONFIG_24,
    REG_CONFIG_28,
    REG_RAW_CONFIG,
    REG_CONFIG_30,
    REG_CONTROL,
)

COMMON_ADDRESSES = (
    RESET_CONTROL,
    RESET_STATUS,
    PDM_GLOBAL_CONFIG,
    PDM_ACTIVITY_CONTROL,
    CLOCK_SOURCE_CONFIG,
    CLOCK_SOURCE_VALUE,
    CLOCK_SOURCE_STATUS,
    CLOCK_DIVIDER_CONFIG,
    CLOCK_DIVIDER_VALUE,
    CLOCK_DIVIDER_STATUS,
    CLOCK_GATE_CONFIG,
    CLOCK_GATE_ENABLE,
    CLOCK_GATE_STATUS,
)

COMMON_ADDRESS_LABELS = {
    RESET_CONTROL: "reset_control",
    RESET_STATUS: "reset_status",
    PDM_GLOBAL_CONFIG: "pdm_global_config",
    PDM_ACTIVITY_CONTROL: "pdm_activity_control",
    CLOCK_SOURCE_CONFIG: "clock_source_config",
    CLOCK_SOURCE_VALUE: "clock_source_value",
    CLOCK_SOURCE_STATUS: "clock_source_status",
    CLOCK_DIVIDER_CONFIG: "clock_divider_config",
    CLOCK_DIVIDER_VALUE: "clock_divider_value",
    CLOCK_DIVIDER_STATUS: "clock_divider_status",
    CLOCK_GATE_CONFIG: "clock_gate_config",
    CLOCK_GATE_ENABLE: "clock_gate_enable",
    CLOCK_GATE_STATUS: "clock_gate_status",
}

CONTROLLER_OFFSET_LABELS = {
    REG_CONTROL: "control",
    REG_IRQ_ENABLE: "irq_enable",
    REG_FIFO_STATUS: "fifo_status",
    REG_WATERMARK: "watermark",
    REG_CONFIG_24: "config_24",
    REG_CONFIG_28: "config_28",
    REG_RAW_CONFIG: "raw_config",
    REG_CONFIG_30: "config_30",
}

POINTER_WINDOWS = (
    (0x40000000, 0x41000000),
    (0x78000000, 0x79000000),
)


def integer(value: str) -> int:
    return int(value, 0)


def parse_controllers(value: str) -> tuple[int, ...]:
    try:
        controllers = tuple(sorted({integer(item) for item in value.split(",")}))
    except ValueError as error:
        raise argparse.ArgumentTypeError("controllers must be comma-separated integers") from error
    if not controllers:
        raise argparse.ArgumentTypeError("at least one controller is required")
    unsupported = set(controllers) - set(BUILTIN_DMIC_CONTROLLERS)
    if unsupported:
        raise argparse.ArgumentTypeError(
            "only built-in DMIC controllers 0,2,3 are allowed; got "
            + ",".join(str(item) for item in sorted(unsupported))
        )
    return controllers


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Guarded Frankel A32 raw-PDM setup for AP FIFO polling"
    )
    parser.add_argument(
        "operation",
        nargs="?",
        choices=("check-idle", "apply", "check-active", "revert"),
        default="check-idle",
        help="operation (default: check-idle, which is read-only)",
    )
    parser.add_argument(
        "--controllers",
        type=parse_controllers,
        default=(0,),
        metavar="0[,2,3]",
        help="built-in DMIC controllers to hand off (default: 0)",
    )
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=integer)
    parser.add_argument(
        "--snapshot",
        type=pathlib.Path,
        help="host JSON snapshot (default: a target-specific file under /tmp)",
    )
    parser.add_argument(
        "--ack-hardware-write",
        action="store_true",
        help="required by apply and revert",
    )
    parser.add_argument(
        "--ack-ap-consumer-ready",
        action="store_true",
        help="required by apply after the AP FIFO consumer is installed and ready",
    )
    parser.add_argument(
        "--ack-polling-stopped",
        action="store_true",
        help="required by revert after the AP FIFO consumer has stopped",
    )
    parser.add_argument(
        "--skip-reset-pulse",
        action="store_true",
        help=(
            "do not pulse the selected PDM reset during apply; required for "
            "the Frankel AP-direct path because asserting RESET_CONTROL while "
            "AoC is cold drops the device before the controller can be started"
        ),
    )
    parser.add_argument(
        "--prepared-holder-pid",
        type=int,
        help="exact PID of a prepared-not-started frankel_pcm_hold owner",
    )
    parser.add_argument(
        "--prepared-holder-controller",
        type=integer,
        help="controller prepared by the bound holder (currently only 0)",
    )
    parser.add_argument(
        "--prepared-holder-ready-file",
        help="device-side ready record published by frankel_pcm_hold",
    )
    return parser.parse_args()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def u32(data: bytes, offset: int = 0) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def hex32(value: int) -> str:
    return f"0x{value:08x}"


def controller_address(controller: int, offset: int) -> int:
    return CONTROLLER_BASE + controller * CONTROLLER_STRIDE + offset


def valid_pointer(pointer: int) -> bool:
    return pointer & 3 == 0 and any(
        start <= pointer < end for start, end in POINTER_WINDOWS
    )


def default_snapshot_path(
    controllers: tuple[int, ...], prepared_holder: bool = False
) -> pathlib.Path:
    suffix = "-".join(str(item) for item in controllers)
    if prepared_holder:
        suffix += "-prepared-holder"
    return pathlib.Path(tempfile.gettempdir()) / f"frankel-a32-raw-pdm-{suffix}.json"


def atomic_json_write(path: pathlib.Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(document, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as stream:
            document = json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"cannot read snapshot {path}: {error}") from error
    require(isinstance(document, dict), "snapshot root is not an object")
    require(document.get("version") == SNAPSHOT_VERSION, "unsupported snapshot version")
    return document


def words_to_json(words: dict[int, int]) -> dict[str, str]:
    return {hex32(address): hex32(value) for address, value in sorted(words.items())}


def words_from_json(document: dict[str, str]) -> dict[int, int]:
    try:
        return {int(address, 0): int(value, 0) for address, value in document.items()}
    except (AttributeError, TypeError, ValueError) as error:
        raise RuntimeError("invalid word map in snapshot") from error


@dataclass(frozen=True)
class PreparedHolderSpec:
    pid: int
    controller: int
    ready_file: str

    @property
    def fd_path(self) -> str:
        return f"/proc/{self.pid}/fd/{PREPARED_HOLDER_FD}"


def prepared_holder_spec(args: argparse.Namespace) -> PreparedHolderSpec | None:
    pid = getattr(args, "prepared_holder_pid", None)
    controller = getattr(args, "prepared_holder_controller", None)
    ready_file = getattr(args, "prepared_holder_ready_file", None)
    supplied = (pid is not None, controller is not None, ready_file is not None)
    if not any(supplied):
        return None
    require(
        all(supplied),
        "prepared-holder mode requires --prepared-holder-pid, "
        "--prepared-holder-controller, and --prepared-holder-ready-file",
    )
    require(isinstance(pid, int) and pid > 0, "prepared-holder PID must be positive")
    require(
        controller == PREPARED_HOLDER_CONTROLLER,
        "the reviewed prepared-holder path supports only PDM0",
    )
    require(
        args.controllers == (controller,),
        "prepared-holder controller must exactly match --controllers",
    )
    require(
        isinstance(ready_file, str)
        and ready_file.startswith("/")
        and not any(character.isspace() for character in ready_file),
        "prepared-holder ready file must be an absolute device path without whitespace",
    )
    return PreparedHolderSpec(pid=pid, controller=controller, ready_file=ready_file)


def parse_prepared_ready_record(record: str) -> dict[str, int | str]:
    match = re.fullmatch(
        r"pid=(\d+) state=(prepared-not-started) card=(\d+) device=(\d+) "
        r"rate=(\d+) channels=(\d+) format=(\d+) period_size=(\d+) "
        r"period_count=(\d+)\n?",
        record,
    )
    require(match is not None, "prepared-holder ready record has unexpected syntax")
    names = (
        "pid",
        "state",
        "card",
        "device",
        "rate",
        "channels",
        "format",
        "period_size",
        "period_count",
    )
    values: dict[str, int | str] = dict(zip(names, match.groups(), strict=True))
    for name in names:
        if name != "state":
            values[name] = int(values[name])
    require(values["rate"] > 0, "prepared-holder ready rate is not positive")
    require(values["channels"] > 0, "prepared-holder channel count is not positive")
    require(values["period_size"] > 0, "prepared-holder period size is not positive")
    require(values["period_count"] > 0, "prepared-holder period count is not positive")
    return values


@dataclass(frozen=True)
class Handle:
    address: int
    active: int
    controller: int
    pcm_rate: int
    main_object: int
    callback: int
    next_address: int

    def as_json(self) -> dict[str, int | str]:
        return {
            "address": hex32(self.address),
            "active": self.active,
            "controller": self.controller,
            "pcm_rate": self.pcm_rate,
            "main_object": hex32(self.main_object),
            "callback": hex32(self.callback),
            "next": hex32(self.next_address),
        }


@dataclass
class DeviceState:
    identity: dict[str, str]
    capture_status: dict[str, str]
    handles: list[Handle]
    words: dict[int, int]


@dataclass
class WriteRecord:
    address: int
    before: int
    after: int
    label: str

    def as_json(self) -> dict[str, str]:
        return {
            "address": hex32(self.address),
            "before": hex32(self.before),
            "after": hex32(self.after),
            "label": self.label,
        }


class Hardware:
    def __init__(self, args: argparse.Namespace) -> None:
        self.transport = AocFactoryDiag(
            SimpleNamespace(
                adb=args.adb,
                adb_server_port=args.adb_server_port,
                serial=args.serial,
                core=1,
                counter=args.counter,
            )
        )

    def text(self, *arguments: str) -> str:
        result = self.transport.run(*arguments)
        return result.stdout.decode(errors="replace").strip()

    def read32(self, address: int) -> int:
        return u32(self.transport.dump(address, 4))

    def write32(self, address: int, value: int) -> None:
        self.transport.write(address, value & 0xFFFFFFFF, 32)

    def identity(self) -> dict[str, str]:
        require(self.text("get-state") == "device", "ADB target is not online")
        identity = {
            "device": self.text("shell", "getprop", "ro.product.device"),
            "vendor_build_id": self.text(
                "shell", "getprop", "ro.vendor.build.id"
            ),
            "vendor_fingerprint": self.text(
                "shell", "getprop", "ro.vendor.build.fingerprint"
            ),
            "build_type": self.text("shell", "getprop", "ro.build.type"),
            "boot_completed": self.text(
                "shell", "getprop", "sys.boot_completed"
            ),
            "serial": self.text("get-serialno"),
            "kernel": self.text("shell", "uname", "-r"),
        }
        require(identity["device"] == EXPECTED_DEVICE, "refusing a non-Frankel target")
        require(
            identity["vendor_build_id"] == EXPECTED_VENDOR_BUILD_ID,
            "refusing an unreviewed Frankel vendor build",
        )
        require(identity["boot_completed"] == "1", "Android has not completed boot")
        require(
            self.text("shell", "su", "0", "id", "-u") == "0",
            "a root shell is required",
        )
        for device in ("/dev/acd-factory_diag", "/dev/acd-debug"):
            result = self.transport.run(
                "shell", "su", "0", "test", "-c", device, check=False
            )
            require(result.returncode == 0, f"required character device is missing: {device}")
        return identity

    def capture_statuses(self) -> dict[str, str]:
        # Frankel's procfs lists card-0 PCMs in /proc/asound/pcm but does not
        # materialize pcmNNc/subN/status directories, even while the card is
        # registered. Prove idleness from the actual character-device owners
        # instead of treating a missing status path as either open or closed.
        pcm_inventory = self.text("shell", "su", "0", "cat", "/proc/asound/pcm")
        capture_devices = sorted(
            {
                int(match.group(1))
                for line in pcm_inventory.splitlines()
                if (
                    match := re.match(
                        r"^00-(\d+): .* : .*\bcapture\s+\d+\b", line
                    )
                )
            }
        )
        require(capture_devices, "card 0 exposes no capture PCM inventory")
        for device in capture_devices:
            path = f"/dev/snd/pcmC0D{device}c"
            result = self.transport.run(
                "shell", "su", "0", "test", "-c", path, check=False
            )
            require(result.returncode == 0, f"capture PCM node is missing: {path}")

        # Feed the script over stdin because adb shell does not preserve an
        # argv element as the argument to `sh -c`. A single native ls scans
        # procfs quickly. Process-exit races may produce only ENOENT rows;
        # every other diagnostic is a fail-closed incomplete scan.
        result = self.transport.run(
            "shell",
            "su",
            "0",
            "sh",
            input_data=b"exec ls -l /proc/[0-9]*/fd/*\n",
            check=False,
        )
        stderr_lines = [
            line.strip()
            for line in result.stderr.decode(errors="replace").splitlines()
            if line.strip()
        ]
        unexpected_errors = [
            line
            for line in stderr_lines
            if re.fullmatch(
                r"ls: /proc/\d+/fd/\d+: No such file or directory", line
            )
            is None
        ]
        require(
            not unexpected_errors,
            "incomplete root proc-fd scan: " + "; ".join(unexpected_errors),
        )
        open_pattern = re.compile(
            r".*\s(/proc/\d+/fd/\d+) -> (/dev/snd/pcmC0D(\d+)c)$"
        )
        owners: dict[str, list[str]] = {}
        for line in result.stdout.decode(errors="replace").splitlines():
            match = open_pattern.fullmatch(line)
            if match is None:
                continue
            device = int(match.group(3))
            if device in capture_devices:
                owners.setdefault(match.group(2), []).append(match.group(1))
        if not owners:
            return {"card0-capture-fd-scan": "closed"}
        return {
            path: "open via " + ",".join(sorted(set(paths)))
            for path, paths in sorted(owners.items())
        }

    def prepared_holder_contract(
        self, spec: PreparedHolderSpec, state: DeviceState
    ) -> dict[str, Any]:
        expected_capture = {
            PREPARED_HOLDER_PCM: f"open via {spec.fd_path}",
        }
        require(
            state.capture_status == expected_capture,
            "prepared holder is not the exact sole card-0 capture owner: "
            f"got {state.capture_status!r}, expected {expected_capture!r}",
        )
        executable = self.text(
            "shell", "su", "0", "readlink", f"/proc/{spec.pid}/exe"
        )
        require(
            executable == PREPARED_HOLDER_EXE,
            f"prepared-holder executable mismatch: {executable!r}",
        )
        fd_target = self.text("shell", "su", "0", "readlink", spec.fd_path)
        require(
            fd_target == PREPARED_HOLDER_PCM,
            f"prepared-holder FD target mismatch: {fd_target!r}",
        )
        ready_text = self.text("shell", "su", "0", "cat", spec.ready_file)
        ready = parse_prepared_ready_record(ready_text)
        require(ready["pid"] == spec.pid, "prepared-holder ready PID mismatch")
        require(
            ready["card"] == PREPARED_HOLDER_CARD,
            "prepared-holder ready card mismatch",
        )
        require(
            ready["device"] == PREPARED_HOLDER_DEVICE,
            "prepared-holder ready device mismatch",
        )
        return {
            "pid": spec.pid,
            "controller": spec.controller,
            "ready_file": spec.ready_file,
            "executable": executable,
            "fd": spec.fd_path,
            "pcm": fd_target,
            "ready_record": ready,
        }

    def handles(self) -> list[Handle]:
        address = self.read32(PDM_HANDLE_LIST)
        if address == 0:
            return []
        handles: list[Handle] = []
        seen: set[int] = set()
        for _ in range(32):
            require(valid_pointer(address), f"invalid PDM handle pointer {hex32(address)}")
            require(address not in seen, "cycle in PDM handle list")
            seen.add(address)
            data = self.transport.dump(address, 64)
            handle = Handle(
                address=address,
                active=data[4],
                controller=data[5],
                pcm_rate=u32(data, 8),
                main_object=u32(data, 12),
                callback=u32(data, 20),
                next_address=u32(data, 60),
            )
            handles.append(handle)
            if handle.next_address == 0:
                return handles
            address = handle.next_address
        raise RuntimeError("PDM handle list exceeds 32 entries")

    def words(self) -> dict[int, int]:
        groups: list[tuple[int, tuple[int, ...]]] = [
            (RESET_CONTROL, (RESET_CONTROL,)),
            (RESET_STATUS, (RESET_STATUS,)),
            # Keep both global words as singleton reads.  Their intervening
            # registers have not been admitted to this tool's safe allowlist.
            (PDM_GLOBAL_CONFIG, (PDM_GLOBAL_CONFIG,)),
            (PDM_ACTIVITY_CONTROL, (PDM_ACTIVITY_CONTROL,)),
            (
                CLOCK_SOURCE_CONFIG,
                (CLOCK_SOURCE_CONFIG, CLOCK_SOURCE_VALUE, CLOCK_SOURCE_STATUS),
            ),
            (
                CLOCK_DIVIDER_CONFIG,
                (CLOCK_DIVIDER_CONFIG, CLOCK_DIVIDER_VALUE, CLOCK_DIVIDER_STATUS),
            ),
            (CLOCK_GATE_CONFIG, (CLOCK_GATE_CONFIG, CLOCK_GATE_ENABLE)),
            (CLOCK_GATE_STATUS, (CLOCK_GATE_STATUS,)),
        ]
        for controller in ALL_CONTROLLERS:
            base = controller_address(controller, 0)
            groups.extend(
                (
                    (base + REG_CONTROL, (base + REG_CONTROL, base + REG_IRQ_ENABLE)),
                    (base + REG_FIFO_STATUS, (base + REG_FIFO_STATUS, base + REG_WATERMARK)),
                    (
                        base + REG_CONFIG_24,
                        (
                            base + REG_CONFIG_24,
                            base + REG_CONFIG_28,
                            base + REG_RAW_CONFIG,
                            base + REG_CONFIG_30,
                        ),
                    ),
                )
            )

        expected = set(COMMON_ADDRESSES)
        for controller in ALL_CONTROLLERS:
            expected.update(
                controller_address(controller, offset)
                for offset in SAFE_CONTROLLER_OFFSETS
            )
        grouped = {address for _, addresses in groups for address in addresses}
        require(grouped == expected, "safe grouped-read map differs from allowlist")
        for controller in ALL_CONTROLLERS:
            require(
                controller_address(controller, REG_FIFO_POP) not in grouped,
                f"destructive PDM{controller} FIFO pop entered grouped-read map",
            )

        words: dict[int, int] = {}
        for start, addresses in groups:
            require(addresses == tuple(range(start, addresses[-1] + 4, 4)),
                    "non-contiguous safe read group")
            data = self.transport.dump(start, len(addresses) * 4)
            for offset, address in enumerate(addresses):
                words[address] = u32(data, offset * 4)
        return words

    def state(self) -> DeviceState:
        return DeviceState(
            identity=self.identity(),
            capture_status=self.capture_statuses(),
            handles=self.handles(),
            words=self.words(),
        )

    def clock_contract(
        self, state: DeviceState, expected_divider: int
    ) -> dict[str, int | str]:
        require(len(state.handles) == 1, "expected exactly one stock PDM handle")
        handle = state.handles[0]
        require(handle.active == 0, "stock PDM4 handle is active")
        require(handle.controller == 4, "sole stock PDM handle is not PDM4")
        require(handle.pcm_rate == STOCK_PDM_RATE, "unexpected stock PDM4 PCM rate")
        require(
            handle.callback == VD6282_PDM_CALLBACK,
            "unexpected stock PDM4 callback",
        )
        require(valid_pointer(handle.main_object), "invalid stock PDM main object")

        main_data = self.transport.dump(handle.main_object, 116)
        require(u32(main_data) == PDM_VTABLE, "unexpected stock PDM main vtable")
        clock_object = u32(main_data, 20)
        require(valid_pointer(clock_object), "invalid stock PDM clock object")
        require(
            u32(main_data, 112) == STOCK_PDM_CLOCK_HZ,
            "unexpected stock PDM cached clock",
        )

        clock_data = self.transport.dump(clock_object, 68)
        require(u32(clock_data) == CLOCK_VTABLE, "unexpected PDM clock vtable")
        require(u32(clock_data, 8) == 2, "unexpected PDM clock index")
        require(
            u32(clock_data, 12) == CLOCK_PARENT_HZ,
            "unexpected PDM clock parent",
        )
        require(
            clock_data[16:19] == b"\x01\x01\x01",
            "PDM clock one-time configuration flags are not all set",
        )
        fields = tuple(u32(clock_data, offset) for offset in range(20, 68, 4))
        require(
            fields == CLOCK_OBJECT_BASES_AND_STRIDES,
            "PDM clock base/stride contract changed",
        )
        require(
            state.words[CLOCK_DIVIDER_VALUE] & 0x3F == expected_divider,
            f"PDM clock contract divider is not {expected_divider}",
        )
        return {
            "handle": hex32(handle.address),
            "main_object": hex32(handle.main_object),
            "clock_object": hex32(clock_object),
            "index": 2,
            "parent_hz": CLOCK_PARENT_HZ,
            "cached_clock_hz": STOCK_PDM_CLOCK_HZ,
            "source_config": hex32(CLOCK_SOURCE_CONFIG),
            "divider_value": hex32(CLOCK_DIVIDER_VALUE),
            "gate_enable": hex32(CLOCK_GATE_ENABLE),
        }


class Transaction:
    def __init__(
        self,
        hardware: Hardware,
        journal: Callable[[list[WriteRecord]], None] | None = None,
    ) -> None:
        self.hardware = hardware
        self.records: list[WriteRecord] = []
        self.journal = journal

    def write(self, address: int, expected: int, value: int, label: str) -> int:
        expected &= 0xFFFFFFFF
        value &= 0xFFFFFFFF
        current = self.hardware.read32(address)
        require(
            current == expected,
            f"{label}: guard mismatch at {hex32(address)}: "
            f"got {hex32(current)}, expected {hex32(expected)}",
        )
        if value == current:
            return current
        record = WriteRecord(address, current, value, label)
        # Record before issuing the packet: a transport failure can happen
        # after the firmware has completed the store.
        self.records.append(record)
        if self.journal is not None:
            # Persist the intended before/after pair before target access.  An
            # interrupted `applying`/`reverting` snapshot can therefore be
            # recovered by comparing each controlled word with exact states.
            self.journal(self.records)
        self.hardware.write32(address, value)
        actual = self.hardware.read32(address)
        require(
            actual == value,
            f"{label}: verification failed at {hex32(address)}: got {hex32(actual)}",
        )
        return actual

    def rmw(self, address: int, clear: int, set_bits: int, label: str) -> int:
        current = self.hardware.read32(address)
        value = (current & ~clear) | set_bits
        return self.write(address, current, value, label)

    def pulse_self_clearing_bit(self, address: int, bit: int, label: str) -> int:
        current = self.hardware.read32(address)
        require(
            current & bit == 0,
            f"{label}: self-clearing bit was already set at {hex32(address)}",
        )
        asserted = current | bit
        record = WriteRecord(address, current, asserted, label)
        self.records.append(record)
        if self.journal is not None:
            self.journal(self.records)
        self.hardware.write32(address, asserted)
        actual = self.hardware.read32(address)
        require(
            actual in (current, asserted),
            f"{label}: unexpected post-pulse value at {hex32(address)}: "
            f"got {hex32(actual)}, expected {hex32(current)} or {hex32(asserted)}",
        )
        if actual == asserted:
            actual = poll_mask(self.hardware, address, bit, 0, label)
        require(
            actual == current,
            f"{label}: persistent fields changed at {hex32(address)}: "
            f"got {hex32(actual)}, expected {hex32(current)}",
        )
        return actual

    def rollback(self) -> list[str]:
        errors: list[str] = []
        for record in reversed(self.records):
            try:
                current = self.hardware.read32(record.address)
                if current == record.before:
                    continue
                require(
                    current == record.after,
                    f"rollback guard mismatch at {hex32(record.address)}: "
                    f"got {hex32(current)}, expected {hex32(record.after)}",
                )
                self.hardware.write32(record.address, record.before)
                actual = self.hardware.read32(record.address)
                require(
                    actual == record.before,
                    f"rollback verification failed at {hex32(record.address)}",
                )
            except (OSError, RuntimeError, ValueError) as error:
                errors.append(f"{record.label}: {error}")
        return errors


def require_mask(value: int, mask: int, expected: int, label: str) -> None:
    require(
        value & mask == expected,
        f"{label}: got {hex32(value)}, expected mask {hex32(mask)} == {hex32(expected)}",
    )


def validate_software_owners(
    state: DeviceState, prepared_holder: PreparedHolderSpec | None = None
) -> None:
    if prepared_holder is None:
        for path, status in state.capture_status.items():
            require(
                status.strip() == "closed",
                f"active/unknown ALSA capture: {path}={status!r}",
            )
    else:
        expected = {
            PREPARED_HOLDER_PCM: f"open via {prepared_holder.fd_path}",
        }
        require(
            state.capture_status == expected,
            "prepared holder is not the exact sole card-0 capture owner",
        )
    active = [handle for handle in state.handles if handle.active != 0]
    require(
        not active,
        "A32 PDM handle(s) active: "
        + ", ".join(
            f"{hex32(handle.address)}/pdm{handle.controller}/state{handle.active}"
            for handle in active
        ),
    )


def validate_common_clock(words: dict[int, int]) -> None:
    require(
        words[PDM_GLOBAL_CONFIG] == STOCK_PDM_GLOBAL_CONFIG,
        "PDM global configuration changed from exact stock value",
    )
    require_mask(words[CLOCK_SOURCE_CONFIG], 1, 0, "clock source config")
    require_mask(words[CLOCK_SOURCE_VALUE], 1, 0, "clock source selection")
    require(
        words[CLOCK_SOURCE_STATUS] in (0, 1),
        "clock source status contains unexpected bits",
    )
    require_mask(words[CLOCK_DIVIDER_CONFIG], 1, 0, "clock divider config")
    require(
        words[CLOCK_DIVIDER_STATUS] in (0, 1),
        "clock divider status contains unexpected bits",
    )
    require_mask(words[CLOCK_GATE_CONFIG], 1, 0, "clock gate config")
    require(
        words[CLOCK_GATE_STATUS] == 1,
        "clock gate status contains unexpected persistent bits",
    )


def validate_idle(state: DeviceState, controllers: tuple[int, ...]) -> None:
    validate_software_owners(state)
    words = state.words
    validate_common_clock(words)
    require(words[PDM_ACTIVITY_CONTROL] == 0, "PDM activity control is not idle")
    require_mask(words[CLOCK_GATE_ENABLE], 1, 0, "PDM clock gate enable")
    require_mask(
        words[CLOCK_DIVIDER_VALUE],
        0x3F,
        STOCK_CLOCK_DIVIDER,
        "stock PDM clock divider",
    )
    reset_low = words[RESET_STATUS] & RESET_MASK
    require(
        words[RESET_CONTROL] & RESET_MASK == reset_low,
        "reset control/status low-five-bit mismatch",
    )
    for controller in controllers:
        require(
            reset_low & (1 << controller),
            f"PDM{controller} is held in reset",
        )
    for controller in ALL_CONTROLLERS:
        base = controller_address(controller, 0)
        require_mask(words[base + REG_CONTROL], CONTROL_ENABLE, 0, f"PDM{controller} idle")
        # Full zero is intentional: this tool never writes +0x04 and cannot
        # safely restore unknown interrupt-enable bits after a reset.
        require(
            words[base + REG_IRQ_ENABLE] == 0,
            f"PDM{controller} IRQ enable is not exactly zero",
        )
        require_mask(
            words[base + REG_FIFO_STATUS], FIFO_EMPTY, FIFO_EMPTY, f"PDM{controller} FIFO"
        )
    for controller in controllers:
        control = words[controller_address(controller, REG_CONTROL)]
        require_mask(control, CONTROL_START_BITS, 0, f"PDM{controller} start bits")


def validate_prepared_idle(
    state: DeviceState,
    controllers: tuple[int, ...],
    prepared_holder: PreparedHolderSpec,
    *,
    require_fifo_empty: bool,
) -> None:
    require(
        controllers == (PREPARED_HOLDER_CONTROLLER,),
        "prepared-holder state supports exactly PDM0",
    )
    validate_software_owners(state, prepared_holder)
    words = state.words
    validate_common_clock(words)
    require(words[PDM_ACTIVITY_CONTROL] == 0, "PDM activity control is not idle")
    require_mask(words[CLOCK_GATE_ENABLE], 1, 0, "PDM clock gate enable")
    require_mask(
        words[CLOCK_DIVIDER_VALUE],
        0x3F,
        STOCK_CLOCK_DIVIDER,
        "prepared PDM clock divider",
    )
    reset_low = words[RESET_STATUS] & RESET_MASK
    require(
        words[RESET_CONTROL] & RESET_MASK == reset_low,
        "reset control/status low-five-bit mismatch",
    )
    require(reset_low & 1, "prepared PDM0 is held in reset")
    for controller in ALL_CONTROLLERS:
        base = controller_address(controller, 0)
        require(
            words[base + REG_IRQ_ENABLE] == 0,
            f"PDM{controller} IRQ enable is not exactly zero",
        )
        if controller == PREPARED_HOLDER_CONTROLLER:
            continue
        require_mask(words[base + REG_CONTROL], CONTROL_ENABLE, 0, f"PDM{controller} idle")
        require_mask(
            words[base + REG_FIFO_STATUS],
            FIFO_EMPTY,
            FIFO_EMPTY,
            f"PDM{controller} FIFO",
        )
    base = controller_address(PREPARED_HOLDER_CONTROLLER, 0)
    expected = {
        REG_CONTROL: PREPARED_CONTROL,
        REG_WATERMARK: PREPARED_WATERMARK,
        REG_CONFIG_24: PREPARED_CONFIG_24,
        REG_CONFIG_28: PREPARED_CONFIG_28,
        REG_RAW_CONFIG: PREPARED_RAW_CONFIG,
        REG_CONFIG_30: PREPARED_CONFIG_30,
    }
    for offset, value in expected.items():
        require(
            words[base + offset] == value,
            f"prepared PDM0 {CONTROLLER_OFFSET_LABELS[offset]} mismatch: "
            f"got {hex32(words[base + offset])}, expected {hex32(value)}",
        )
    require(
        words[base + REG_FIFO_STATUS] in (0, FIFO_EMPTY),
        "prepared PDM0 FIFO status contains unexpected bits",
    )
    if require_fifo_empty:
        require_mask(
            words[base + REG_FIFO_STATUS],
            FIFO_EMPTY,
            FIFO_EMPTY,
            "prepared PDM0 FIFO",
        )


def validate_active(
    state: DeviceState,
    controllers: tuple[int, ...],
    prepared_holder: PreparedHolderSpec | None = None,
) -> None:
    validate_software_owners(state, prepared_holder)
    words = state.words
    validate_common_clock(words)
    require(
        words[PDM_ACTIVITY_CONTROL] == PDM_ACTIVITY_ACTIVE,
        "PDM activity control did not assert for raw controller start",
    )
    require_mask(words[CLOCK_GATE_ENABLE], 1, 1, "PDM clock gate enable")
    require_mask(words[CLOCK_DIVIDER_VALUE], 0x3F, RAW_CLOCK_DIVIDER, "raw clock divider")
    selected = set(controllers)
    for controller in ALL_CONTROLLERS:
        base = controller_address(controller, 0)
        control = words[base + REG_CONTROL]
        require(words[base + REG_IRQ_ENABLE] == 0, f"PDM{controller} IRQ enable changed")
        if controller not in selected:
            require_mask(control, CONTROL_ENABLE, 0, f"unselected PDM{controller}")
            continue
        required = CONTROL_ENABLE | CONTROL_SELECTED | CONTROL_RAW_MODE
        require_mask(control, required, required, f"PDM{controller} raw control")
        require_mask(control, CONTROL_NORMAL_MODE, 0, f"PDM{controller} normal mode")
        require(words[base + REG_CONFIG_24] == 4, f"PDM{controller} RFactor config")
        require(words[base + REG_WATERMARK] == 150, f"PDM{controller} watermark")
        require(
            words[base + REG_CONFIG_30] == CONFIG_30_CHANNEL_BITS,
            f"PDM{controller} config +0x30 did not settle to persistent bits",
        )
        require_mask(
            words[base + REG_RAW_CONFIG],
            RAW_CONFIG_HPF_BYPASS,
            RAW_CONFIG_HPF_BYPASS,
            f"PDM{controller} raw config",
        )


def poll_mask(
    hardware: Hardware,
    address: int,
    mask: int,
    expected: int,
    label: str,
    attempts: int = 6,
) -> int:
    last = 0
    for attempt in range(attempts):
        last = hardware.read32(address)
        if last & mask == expected:
            return last
        if attempt + 1 < attempts:
            time.sleep(0.002)
    raise RuntimeError(
        f"{label}: timeout at {hex32(address)}: got {hex32(last)}, "
        f"expected mask {hex32(mask)} == {hex32(expected)}"
    )


def set_pdm_clock(transaction: Transaction, enabled: bool) -> None:
    if enabled:
        transaction.rmw(CLOCK_GATE_CONFIG, 1, 0, "select software PDM clock gate")
        transaction.rmw(CLOCK_GATE_ENABLE, 1, 1, "enable PDM clock")
    else:
        transaction.rmw(CLOCK_GATE_ENABLE, 1, 0, "disable PDM clock")
    # Transaction.write() verifies the persistent enable register exactly.
    # 0x824d07bc bit 8 is not a persistent gate state on this build: both
    # stock idle and stock active observations read the complete word as 1.
    # PdmV3's separate activity-control word supplies the surrounding
    # start/stop ownership sequence; it is not a gate acknowledgement.


def set_pdm_activity(transaction: Transaction, enabled: bool) -> None:
    if enabled:
        transaction.write(
            PDM_ACTIVITY_CONTROL,
            0,
            PDM_ACTIVITY_ACTIVE,
            "assert PDM activity control",
        )
    else:
        transaction.write(
            PDM_ACTIVITY_CONTROL,
            PDM_ACTIVITY_ACTIVE,
            0,
            "clear PDM activity control",
        )


def pulse_reset(transaction: Transaction, controller: int) -> None:
    hardware = transaction.hardware
    mask = 1 << controller
    status = hardware.read32(RESET_STATUS) & RESET_MASK
    require(status & mask, f"PDM{controller} is not initially out of reset")
    control = hardware.read32(RESET_CONTROL)
    phase_zero = (control & ~RESET_MASK) | (status & ~mask)
    transaction.write(RESET_CONTROL, control, phase_zero, f"assert PDM{controller} reset")
    poll_mask(hardware, RESET_STATUS, RESET_MASK, status & ~mask, f"assert PDM{controller} reset")
    control = hardware.read32(RESET_CONTROL)
    phase_one = (control & ~RESET_MASK) | (status | mask)
    transaction.write(RESET_CONTROL, control, phase_one, f"release PDM{controller} reset")
    poll_mask(hardware, RESET_STATUS, RESET_MASK, status | mask, f"release PDM{controller} reset")
    poll_mask(
        hardware,
        controller_address(controller, REG_FIFO_STATUS),
        FIFO_EMPTY,
        FIFO_EMPTY,
        f"PDM{controller} FIFO empty after reset",
    )


def set_divider(transaction: Transaction, divider: int, label: str) -> None:
    require(1 <= divider < 64, "clock divider must be 1..63")
    transaction.rmw(CLOCK_DIVIDER_CONFIG, 1, 0, f"{label} divider config")
    transaction.rmw(CLOCK_DIVIDER_VALUE, 0x3F, divider, f"{label} divider")
    poll_mask(
        transaction.hardware,
        CLOCK_DIVIDER_STATUS,
        1,
        1,
        f"{label} divider status",
    )


def configure_controller(
    transaction: Transaction,
    controller: int,
    *,
    skip_gain_commit: bool = False,
) -> None:
    base = controller_address(controller, 0)
    current = transaction.hardware.read32(base + REG_CONFIG_24)
    transaction.write(base + REG_CONFIG_24, current, 4, f"PDM{controller} RFactor25")
    config_30 = base + REG_CONFIG_30
    if skip_gain_commit:
        # RESET_CONTROL cannot safely be pulsed from the AP-direct handoff on
        # this build, and without that reset edge CONFIG_30's bit-9 command
        # never self-clears.  Publish the two persistent channel fields
        # directly; raw start below supplies the first live engine edge.
        transaction.write(
            config_30,
            transaction.hardware.read32(config_30),
            CONFIG_30_CHANNEL_BITS,
            f"PDM{controller} channel fields without reset latch",
        )
    else:
        transaction.rmw(config_30, 1 << 0, 1 << 0, f"PDM{controller} channel-0 gain")
        transaction.pulse_self_clearing_bit(
            config_30,
            CONFIG_30_COMMIT,
            f"PDM{controller} channel-0 gain commit",
        )
        transaction.rmw(config_30, 1 << 4, 1 << 4, f"PDM{controller} channel-1 gain")
        transaction.pulse_self_clearing_bit(
            config_30,
            CONFIG_30_COMMIT,
            f"PDM{controller} channel-1 gain commit",
        )
    require(
        transaction.hardware.read32(config_30) == CONFIG_30_CHANNEL_BITS,
        f"PDM{controller} config +0x30 persistent fields did not settle",
    )
    current = transaction.hardware.read32(base + REG_WATERMARK)
    transaction.write(base + REG_WATERMARK, current, 150, f"PDM{controller} watermark")
    transaction.rmw(
        base + REG_CONTROL,
        0,
        CONTROL_SELECTED,
        f"PDM{controller} select",
    )


def start_raw_controller(
    transaction: Transaction, controller: int, *, prepared_takeover: bool = False
) -> None:
    base = controller_address(controller, 0)
    control = transaction.hardware.read32(base + REG_CONTROL)
    if prepared_takeover:
        require(
            controller == PREPARED_HOLDER_CONTROLLER and control == PREPARED_CONTROL,
            f"PDM{controller} prepared pre-start control changed",
        )
    else:
        require_mask(control, CONTROL_START_BITS, 0, f"PDM{controller} pre-start control")
    raw_control = (control & RAW_CONTROL_CLEAR_MASK) | RAW_CONTROL_SET
    transaction.write(base + REG_CONTROL, control, raw_control, f"PDM{controller} raw start")
    transaction.rmw(
        base + REG_RAW_CONFIG,
        0,
        RAW_CONFIG_HPF_BYPASS,
        f"PDM{controller} pdm_hpf=0",
    )
    # REG_IRQ_ENABLE (+0x04) intentionally remains exactly zero.  The A32
    # manager's +0x88 IRQ-rearm method is not called for an AP-polled FIFO.
    require(
        transaction.hardware.read32(base + REG_IRQ_ENABLE) == 0,
        f"PDM{controller} IRQ enable changed during raw start",
    )


def controlled_active_addresses(controllers: tuple[int, ...]) -> set[int]:
    addresses = {
        CLOCK_DIVIDER_CONFIG,
        CLOCK_DIVIDER_VALUE,
        CLOCK_GATE_CONFIG,
        CLOCK_GATE_ENABLE,
        PDM_ACTIVITY_CONTROL,
        RESET_CONTROL,
    }
    for controller in controllers:
        base = controller_address(controller, 0)
        addresses.update(base + offset for offset in RESTORABLE_CONTROLLER_OFFSETS)
        addresses.add(base + REG_IRQ_ENABLE)
    return addresses


def verify_exact_active_snapshot(state: DeviceState, snapshot: dict[str, Any]) -> None:
    active = words_from_json(snapshot.get("active_words", {}))
    require(active, "snapshot has no active word map")
    for address, expected in active.items():
        actual = state.words.get(address)
        require(actual is not None, f"active address missing from live snapshot: {hex32(address)}")
        require(
            actual == expected,
            f"active snapshot mismatch at {hex32(address)}: "
            f"got {hex32(actual)}, expected {hex32(expected)}",
        )


def restore_known_controller_state(
    transaction: Transaction,
    original: dict[int, int],
    controllers: tuple[int, ...],
) -> list[str]:
    errors: list[str] = []
    hardware = transaction.hardware
    for controller in controllers:
        base = controller_address(controller, 0)
        for offset in RESTORABLE_CONTROLLER_OFFSETS:
            address = base + offset
            try:
                current = hardware.read32(address)
                transaction.write(
                    address,
                    current,
                    original[address],
                    f"restore PDM{controller}+0x{offset:02x}",
                )
            except (OSError, RuntimeError, ValueError) as error:
                errors.append(str(error))
        try:
            require(
                hardware.read32(base + REG_IRQ_ENABLE) == original[base + REG_IRQ_ENABLE] == 0,
                f"PDM{controller} +0x04 changed; tool will not write it",
            )
        except (OSError, RuntimeError, ValueError) as error:
            errors.append(str(error))
    return errors


def state_document(
    state: DeviceState,
    controllers: tuple[int, ...],
    prepared_holder: dict[str, Any] | None = None,
) -> dict[str, Any]:
    document: dict[str, Any] = {
        "identity": state.identity,
        "capture_status": state.capture_status,
        "handles": [handle.as_json() for handle in state.handles],
        "controllers": list(controllers),
        "owner_mode": "prepared-holder" if prepared_holder is not None else "cold",
        "original_words": words_to_json(state.words),
    }
    if prepared_holder is not None:
        document["prepared_holder"] = prepared_holder
    return document


def check_snapshot_identity(
    snapshot: dict[str, Any],
    state: DeviceState,
    controllers: tuple[int, ...],
    prepared_holder: dict[str, Any] | None = None,
) -> None:
    require(snapshot.get("controllers") == list(controllers), "snapshot controller set mismatch")
    expected_mode = "prepared-holder" if prepared_holder is not None else "cold"
    require(snapshot.get("owner_mode") == expected_mode, "snapshot owner mode mismatch")
    require(
        snapshot.get("prepared_holder") == prepared_holder,
        "snapshot/live prepared-holder contract mismatch",
    )
    identity = snapshot.get("identity", {})
    for field in ("device", "vendor_build_id", "serial"):
        require(
            identity.get(field) == state.identity.get(field),
            f"snapshot/live {field} mismatch",
        )


def print_state(state: DeviceState, controllers: tuple[int, ...], mode: str) -> None:
    words = state.words
    print(
        f"{mode}: target={state.identity['device']} "
        f"vendor_build={state.identity['vendor_build_id']} "
        f"controllers={','.join(map(str, controllers))}"
    )
    print(
        f"clock source={words[CLOCK_SOURCE_VALUE] & 1} "
        f"divider={words[CLOCK_DIVIDER_VALUE] & 0x3f} "
        f"gate={words[CLOCK_GATE_ENABLE] & 1} "
        f"gate_status={(words[CLOCK_GATE_STATUS] >> 8) & 1}"
    )
    for controller in ALL_CONTROLLERS:
        base = controller_address(controller, 0)
        print(
            f"pdm{controller} control={hex32(words[base + REG_CONTROL])} "
            f"irq={hex32(words[base + REG_IRQ_ENABLE])} "
            f"fifo_empty={words[base + REG_FIFO_STATUS] & 1}"
        )
    print(f"A32 handles={len(state.handles)}; all software-owner guards passed")


def print_observed_state(
    state: DeviceState, controllers: tuple[int, ...], operation: str
) -> None:
    """Print the already captured, non-destructive state before validation.

    This function has no Hardware reference and performs no target access.  In
    particular, its controller rows come only from SAFE_CONTROLLER_OFFSETS,
    which deliberately excludes the destructive FIFO pop at +0x0c.
    """

    require(
        set(COMMON_ADDRESS_LABELS) == set(COMMON_ADDRESSES),
        "observed common-register labels do not match the read allowlist",
    )
    require(
        set(CONTROLLER_OFFSET_LABELS) == set(SAFE_CONTROLLER_OFFSETS),
        "observed controller-register labels do not match the read allowlist",
    )
    require(
        REG_FIFO_POP not in SAFE_CONTROLLER_OFFSETS,
        "destructive FIFO pop is present in the controller read allowlist",
    )

    words = state.words
    selected = ",".join(map(str, controllers))
    print(
        f"observed-state: operation={operation} validation=pending "
        f"target={state.identity['device']} "
        f"vendor_build={state.identity['vendor_build_id']} "
        f"controllers={selected}"
    )
    for path, status in sorted(state.capture_status.items()):
        print(f"observed-capture path={path} status={status}")
    for address in COMMON_ADDRESSES:
        print(
            f"observed-common name={COMMON_ADDRESS_LABELS[address]} "
            f"address={hex32(address)} value={hex32(words[address])}"
        )
    for controller in ALL_CONTROLLERS:
        base = controller_address(controller, 0)
        for offset in SAFE_CONTROLLER_OFFSETS:
            address = base + offset
            print(
                f"observed-pdm controller={controller} "
                f"name={CONTROLLER_OFFSET_LABELS[offset]} "
                f"offset=0x{offset:02x} address={hex32(address)} "
                f"value={hex32(words[address])}"
            )
        controller_handles = [
            handle for handle in state.handles if handle.controller == controller
        ]
        if not controller_handles:
            print(f"observed-handle controller={controller} state=none")
            continue
        for handle in controller_handles:
            print(
                f"observed-handle controller={controller} "
                f"address={hex32(handle.address)} active={handle.active} "
                f"pcm_rate={handle.pcm_rate} "
                f"main_object={hex32(handle.main_object)} "
                f"callback={hex32(handle.callback)} "
                f"next={hex32(handle.next_address)}"
            )
    for handle in state.handles:
        if handle.controller in ALL_CONTROLLERS:
            continue
        print(
            f"observed-handle controller={handle.controller} "
            f"address={hex32(handle.address)} active={handle.active} "
            f"pcm_rate={handle.pcm_rate} "
            f"main_object={hex32(handle.main_object)} "
            f"callback={hex32(handle.callback)} "
            f"next={hex32(handle.next_address)} state=outside-controller-range"
        )
    sys.stdout.flush()


def operation_check_idle(hardware: Hardware, args: argparse.Namespace) -> None:
    state = hardware.state()
    print_observed_state(state, args.controllers, "check-idle")
    validate_idle(state, args.controllers)
    print_state(state, args.controllers, "idle")
    print("read-only idle checks passed; no memory-set command was issued")


def operation_apply(
    hardware: Hardware, args: argparse.Namespace, snapshot_path: pathlib.Path
) -> None:
    require(args.ack_hardware_write, "apply requires --ack-hardware-write")
    require(
        args.ack_ap_consumer_ready,
        "apply requires --ack-ap-consumer-ready; this tool only starts FIFO production",
    )
    require(not snapshot_path.exists(), f"refusing to overwrite snapshot: {snapshot_path}")
    state = hardware.state()
    validate_idle(state, args.controllers)
    clock_contract = hardware.clock_contract(state, STOCK_CLOCK_DIVIDER)
    snapshot: dict[str, Any] = {
        "version": SNAPSHOT_VERSION,
        "status": "prepared",
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        **state_document(state, args.controllers),
        "clock_contract": clock_contract,
        "reset_pulse_skipped": args.skip_reset_pulse,
    }
    atomic_json_write(snapshot_path, snapshot)

    def persist_apply_journal(records: list[WriteRecord]) -> None:
        snapshot["status"] = "applying"
        snapshot["writes"] = [record.as_json() for record in records]
        atomic_json_write(snapshot_path, snapshot)

    transaction = Transaction(hardware, persist_apply_journal)
    try:
        snapshot["status"] = "applying"
        atomic_json_write(snapshot_path, snapshot)

        # A real Frankel trial proved that asserting RESET_CONTROL in this
        # otherwise-idle AP handoff drops the complete device.  The controller
        # is already out of reset and FIFO-empty under validate_idle(), so the
        # AP-direct profile deliberately leaves reset ownership with AoC.
        if not args.skip_reset_pulse:
            set_pdm_activity(transaction, True)
            set_pdm_clock(transaction, True)
            for controller in args.controllers:
                pulse_reset(transaction, controller)
            set_pdm_clock(transaction, False)
            set_pdm_activity(transaction, False)
        set_divider(transaction, RAW_CLOCK_DIVIDER, "4.8 MHz raw PDM")
        if args.skip_reset_pulse:
            # CONFIG_30's gain-commit bit is clocked.  With reset deliberately
            # left deasserted, start the shared clock before programming the
            # controller and retain ownership through raw start.
            set_pdm_activity(transaction, True)
            set_pdm_clock(transaction, True)
        for controller in args.controllers:
            configure_controller(
                transaction,
                controller,
                skip_gain_commit=args.skip_reset_pulse,
            )

        # Exact PdmV3 start ordering: assert M+0x64 activity first, then
        # enable the clock, then write each controller's raw start state.
        if not args.skip_reset_pulse:
            set_pdm_activity(transaction, True)
            set_pdm_clock(transaction, True)
        for controller in args.controllers:
            start_raw_controller(transaction, controller)

        active_state = hardware.state()
        validate_active(active_state, args.controllers)
        active_addresses = controlled_active_addresses(args.controllers)
        snapshot["active_words"] = words_to_json(
            {
                address: active_state.words[address]
                for address in active_addresses
                if address in active_state.words
            }
        )
        snapshot["writes"] = [record.as_json() for record in transaction.records]
        snapshot["status"] = "active"
        snapshot["activated_utc"] = datetime.datetime.now(
            datetime.timezone.utc
        ).isoformat()
        atomic_json_write(snapshot_path, snapshot)
    except BaseException as error:
        rollback_errors = transaction.rollback()
        original = words_from_json(snapshot["original_words"])
        restore_transaction = Transaction(hardware)
        rollback_errors.extend(
            restore_known_controller_state(
                restore_transaction, original, args.controllers
            )
        )
        snapshot["writes"] = [record.as_json() for record in transaction.records]
        snapshot["apply_error"] = str(error)
        snapshot["rollback_errors"] = rollback_errors
        snapshot["status"] = "rollback_failed" if rollback_errors else "rolled_back"
        atomic_json_write(snapshot_path, snapshot)
        if rollback_errors:
            raise RuntimeError(
                f"apply failed ({error}); rollback also failed: " + "; ".join(rollback_errors)
            ) from error
        raise RuntimeError(f"apply failed and was rolled back: {error}") from error

    print_state(active_state, args.controllers, "active")
    print(f"raw PDM clock={RAW_CLOCK_HZ} Hz; snapshot={snapshot_path}")
    print("AP may now poll each selected controller's physical FIFO +0x0c")


def operation_check_active(
    hardware: Hardware, args: argparse.Namespace, snapshot_path: pathlib.Path
) -> None:
    snapshot = read_json(snapshot_path)
    require(snapshot.get("status") == "active", "snapshot is not marked active")
    state = hardware.state()
    check_snapshot_identity(snapshot, state, args.controllers)
    validate_active(state, args.controllers)
    clock_contract = hardware.clock_contract(state, RAW_CLOCK_DIVIDER)
    require(
        snapshot.get("clock_contract") == clock_contract,
        "snapshot/live PDM clock object contract mismatch",
    )
    verify_exact_active_snapshot(state, snapshot)
    print_state(state, args.controllers, "active")
    print("read-only active checks passed; no memory-set command was issued")


def operation_revert(
    hardware: Hardware, args: argparse.Namespace, snapshot_path: pathlib.Path
) -> None:
    require(args.ack_hardware_write, "revert requires --ack-hardware-write")
    require(
        args.ack_polling_stopped,
        "revert requires --ack-polling-stopped after stopping the AP FIFO consumer",
    )
    snapshot = read_json(snapshot_path)
    require(snapshot.get("status") == "active", "snapshot is not marked active")
    state = hardware.state()
    check_snapshot_identity(snapshot, state, args.controllers)
    validate_active(state, args.controllers)
    clock_contract = hardware.clock_contract(state, RAW_CLOCK_DIVIDER)
    require(
        snapshot.get("clock_contract") == clock_contract,
        "snapshot/live PDM clock object contract mismatch",
    )
    verify_exact_active_snapshot(state, snapshot)
    original = words_from_json(snapshot["original_words"])

    def persist_revert_journal(records: list[WriteRecord]) -> None:
        snapshot["status"] = "reverting"
        snapshot["revert_writes"] = [record.as_json() for record in records]
        atomic_json_write(snapshot_path, snapshot)

    transaction = Transaction(hardware, persist_revert_journal)
    try:
        # Stop production while the clock is still live.  A target-only reset
        # then flushes the FIFO without a long sequence of destructive +0x0c
        # debug reads.  +0x04 remains untouched throughout.
        for controller in args.controllers:
            base = controller_address(controller, 0)
            transaction.rmw(
                base + REG_CONTROL,
                CONTROL_START_BITS,
                0,
                f"stop PDM{controller} raw stream",
            )
        for controller in args.controllers:
            pulse_reset(transaction, controller)
        set_pdm_clock(transaction, False)
        # Exact PdmV3 stop ordering is the reverse around the clock: disable
        # the clock first, then clear M+0x64 activity bit 0.
        set_pdm_activity(transaction, False)

        restore_errors = restore_known_controller_state(
            transaction, original, args.controllers
        )
        require(not restore_errors, "; ".join(restore_errors))
        divider = original[CLOCK_DIVIDER_VALUE] & 0x3F
        set_divider(transaction, divider, "restore stock PDM")

        # The idle snapshot requires the shared clock gate off. Restore the
        # full non-bit fields only when their live values still equal our state.
        transaction.rmw(
            CLOCK_GATE_CONFIG,
            1,
            original[CLOCK_GATE_CONFIG] & 1,
            "restore gate config",
        )
        transaction.rmw(
            CLOCK_GATE_ENABLE,
            1,
            original[CLOCK_GATE_ENABLE] & 1,
            "restore clock gate",
        )

        idle_state = hardware.state()
        validate_idle(idle_state, args.controllers)
        for controller in args.controllers:
            base = controller_address(controller, 0)
            for offset in RESTORABLE_CONTROLLER_OFFSETS:
                address = base + offset
                require(
                    idle_state.words[address] == original[address],
                    f"restore mismatch at {hex32(address)}",
                )
        require(
            idle_state.words[CLOCK_DIVIDER_VALUE] == original[CLOCK_DIVIDER_VALUE],
            "full divider register was not restored",
        )
    except BaseException as error:
        rollback_errors = transaction.rollback()
        snapshot["revert_error"] = str(error)
        snapshot["revert_rollback_errors"] = rollback_errors
        # A complete reverse transaction returns to the exact recorded active
        # state, so a guarded retry remains possible.  A partial rollback must
        # be audited manually and is never accepted by check-active.
        snapshot["status"] = "revert_failed" if rollback_errors else "active"
        atomic_json_write(snapshot_path, snapshot)
        detail = f"revert failed: {error}"
        if rollback_errors:
            detail += "; transaction rollback failed: " + "; ".join(rollback_errors)
        raise RuntimeError(detail) from error

    snapshot["status"] = "reverted"
    snapshot["reverted_utc"] = datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat()
    snapshot["revert_writes"] = [record.as_json() for record in transaction.records]
    atomic_json_write(snapshot_path, snapshot)
    print_state(idle_state, args.controllers, "idle")
    print(f"raw PDM handoff reverted; retained audit snapshot={snapshot_path}")


def main() -> int:
    args = parse_args()
    snapshot_path = args.snapshot or default_snapshot_path(args.controllers)
    hardware = Hardware(args)
    if args.operation == "check-idle":
        operation_check_idle(hardware, args)
    elif args.operation == "apply":
        operation_apply(hardware, args, snapshot_path)
    elif args.operation == "check-active":
        operation_check_active(hardware, args, snapshot_path)
    else:
        operation_revert(hardware, args, snapshot_path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
