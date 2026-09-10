#!/usr/bin/env python3
"""Retired Frankel F1 table probe; retained as reverse-engineering history.

The four former candidates below were disproved by an exact offline image
read: they are static pointer/constant tables, not live PdmV3 objects.  This
program now refuses before constructing an ADB transport so the old labels
cannot produce misleading ``config_24``/``config_28`` evidence.  The original
allowlist and decoder remain only to preserve the provenance of that rejected
hypothesis.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import pathlib
import struct
import sys

from aoc_factory_diag import AocFactoryDiag


EXPECTED_DEVICE = "frankel"
EXPECTED_VENDOR_BUILD_ID = "CP2A.260805.005"
AOC_LOCAL_BASE = 0x40000000
AOC_AP_PHYSICAL_BASE = 0x09000000
CONFIG_24 = 0x24
CONFIG_28 = 0x28
CAPTURE_STATUS_PATHS = (
    "/proc/asound/card0/pcm8c/sub0/status",
    "/proc/asound/card0/pcm12c/sub0/status",
)
RETIREMENT_REASON = (
    "retired: 0x40487190/0x404871f0/0x40487268/0x40487288 are static "
    "F1 pointer/constant tables, not live PdmV3 control blocks"
)


@dataclasses.dataclass(frozen=True)
class ControlBlock:
    name: str
    local_address: int
    provenance: str

    @property
    def projected_ap_physical_address(self) -> int:
        return AOC_AP_PHYSICAL_BASE + self.local_address - AOC_LOCAL_BASE


# These are the four rejected static-table candidates.  Their old provenance
# labels explain why they were once mistaken for pointers to live objects; do
# not use their +0x24/+0x28 contents as hardware or PdmV3 state.
CONTROL_BLOCKS = (
    ControlBlock(
        "array_a_slot0",
        0x40487268,
        "core 0x403b0d9d -> parent+0x30c",
    ),
    ControlBlock(
        "array_a_slot1",
        0x40487288,
        "core 0x403b0da3 -> parent+0x310",
    ),
    ControlBlock(
        "array_b_slot0",
        0x404871F0,
        "core 0x403b6285/0x403b62a3 -> object+0x30",
    ),
    ControlBlock(
        "array_b_slot1",
        0x40487190,
        "core 0x403b6279/0x403b629d -> object+0x34",
    ),
)


def integer(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description=(
            "Retired: former Frankel PdmV3 candidates are static F1 tables"
        )
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
        "--allow-active-capture",
        action="store_true",
        help=(
            "permit a one-shot snapshot while PCM 0,8 or 0,12 is not closed; "
            "the diagnostic transaction can perturb real-time audio"
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit machine-readable output",
    )
    return parser.parse_args()


def adb_text(transport: AocFactoryDiag, *arguments: str) -> str:
    result = transport.run(*arguments)
    return result.stdout.decode(errors="replace").strip()


def require_remote_test(
    transport: AocFactoryDiag, description: str, *test_arguments: str
) -> None:
    result = transport.run(
        "shell", "su", "0", "test", *test_arguments, check=False
    )
    if result.returncode:
        raise RuntimeError(f"device preflight failed: {description}")


def capture_statuses(transport: AocFactoryDiag) -> dict[str, str]:
    statuses: dict[str, str] = {}
    for path in CAPTURE_STATUS_PATHS:
        result = transport.run("shell", "su", "0", "cat", path, check=False)
        if result.returncode:
            statuses[path] = "unavailable"
        else:
            statuses[path] = result.stdout.decode(errors="replace").strip()
    return statuses


def preflight(
    transport: AocFactoryDiag, allow_active_capture: bool
) -> tuple[dict[str, str], dict[str, str]]:
    state = adb_text(transport, "get-state")
    if state != "device":
        raise RuntimeError(f"ADB target is not online: {state!r}")

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
            "refusing non-Frankel target "
            f"(ro.product.device={identity['device']!r})"
        )
    if identity["vendor_build_id"] != EXPECTED_VENDOR_BUILD_ID:
        raise RuntimeError(
            "refusing an unreviewed Frankel vendor build "
            f"(got {identity['vendor_build_id']!r}, expected "
            f"{EXPECTED_VENDOR_BUILD_ID!r})"
        )
    if identity["boot_completed"] != "1":
        raise RuntimeError("Frankel has not completed boot")
    uid = adb_text(transport, "shell", "su", "0", "id", "-u")
    if uid != "0":
        raise RuntimeError(f"root shell is required (su 0 uid={uid!r})")

    require_remote_test(transport, "aoc_core is not loaded", "-d", "/sys/module/aoc_core")
    require_remote_test(
        transport,
        "/dev/acd-factory_diag is not readable",
        "-r",
        "/dev/acd-factory_diag",
    )
    require_remote_test(
        transport,
        "/dev/acd-factory_diag is not writable for a dump request",
        "-w",
        "/dev/acd-factory_diag",
    )
    require_remote_test(
        transport,
        "/dev/acd-debug is not readable",
        "-r",
        "/dev/acd-debug",
    )

    statuses = capture_statuses(transport)
    non_idle = {
        path: status
        for path, status in statuses.items()
        if status != "closed"
    }
    if non_idle and not allow_active_capture:
        details = "; ".join(
            f"{path}={status!r}" for path, status in non_idle.items()
        )
        raise RuntimeError(
            "capture idleness cannot be established; stop capture or pass "
            f"--allow-active-capture for one deliberate snapshot ({details})"
        )
    return identity, statuses


def snapshot(transport: AocFactoryDiag) -> list[dict[str, int | str]]:
    result: list[dict[str, int | str]] = []
    for block in CONTROL_BLOCKS:
        # One eight-byte read covers exactly the two control words observed in
        # PdmV3::ConfigRFactor.  No FIFO/data/status offsets are touched.
        data = transport.dump(block.local_address + CONFIG_24, 8)
        config_24, config_28 = struct.unpack("<II", data)
        result.append(
            {
                "name": block.name,
                "local_base": block.local_address,
                "projected_ap_physical_base": block.projected_ap_physical_address,
                "config_24_address": block.local_address + CONFIG_24,
                "config_24": config_24,
                "config_28_address": block.local_address + CONFIG_28,
                "config_28": config_28,
                "provenance": block.provenance,
            }
        )
    return result


def print_text(
    identity: dict[str, str],
    statuses: dict[str, str],
    blocks: list[dict[str, int | str]],
) -> None:
    print(
        f"target={identity['device']} vendor_build={identity['vendor_build_id']} "
        f"kernel={identity['kernel_release']}"
    )
    for path, status in statuses.items():
        compact_status = " ".join(status.splitlines())
        print(f"capture_status {path}: {compact_status}")
    for block in blocks:
        print(
            f"{block['name']}: local=0x{block['local_base']:08x} "
            f"ap_projection=0x{block['projected_ap_physical_base']:08x} "
            f"+0x24@0x{block['config_24_address']:08x}="
            f"0x{block['config_24']:08x} "
            f"+0x28@0x{block['config_28_address']:08x}="
            f"0x{block['config_28']:08x} ({block['provenance']})"
        )


def main() -> int:
    args = parse_args()
    raise RuntimeError(RETIREMENT_REASON)
    transport_args = argparse.Namespace(
        adb=args.adb,
        adb_server_port=args.adb_server_port,
        serial=args.serial,
        core=2,
        counter=args.counter,
    )
    transport = AocFactoryDiag(transport_args)
    identity, statuses = preflight(transport, args.allow_active_capture)
    blocks = snapshot(transport)
    if args.json:
        print(
            json.dumps(
                {
                    "identity": identity,
                    "capture_status": statuses,
                    "control_blocks": blocks,
                },
                indent=2,
                sort_keys=True,
            )
        )
    else:
        print_text(identity, statuses, blocks)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
