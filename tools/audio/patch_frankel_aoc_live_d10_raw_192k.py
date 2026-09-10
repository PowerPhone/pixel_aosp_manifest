#!/usr/bin/env python3
"""Guard and switch Frankel F1 D10 strict-mono capture to 192 kHz.

This is a reboot-volatile runtime patch for the reviewed CP2A.260805.005 AoC
F1 image.  It is deliberately narrower than the D12 experimentation tools:
only PCM 0,10 / EP3 may run while the patch is installed, and only as one
RAW S16_LE channel selected from logical microphone 0, 1, or 2.

Every mutation is preceded by an exact all-site classification.  New opens on
the affected capture PCMs are quarantined during the transaction, all relevant
routes must be off, and a failed transaction attempts to restore its complete
initial state before returning an error.  Unknown or mixed site bytes always
fail closed.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import re
import shlex
import sys
import time

from aoc_factory_diag import AocFactoryDiag


EXPECTED_DEVICE = "frankel"
EXPECTED_VENDOR_BUILD_ID = "CP2A.260805.005"
DEFAULT_NATIVE_HELPER = "/data/local/tmp/frankel_aoc_diag"
CAPTURE_DEVICES = (8, 9, 10, 12)

# D8/EP1, D9/EP2, D10/EP3, and D12/EP5 are the physical-microphone capture
# frontends affected by the shared PDM/RAW code below.  Requiring every input
# on these mixers to be off also catches a stale non-microphone route before a
# transaction.  EP5 alone exposes INTERNAL_MIC_US_TX.
COMMON_TX_SOURCES = (
    "I2S_0_TX",
    "I2S_1_TX",
    "I2S_2_TX",
    "TDM_0_TX",
    "TDM_1_TX",
    "INTERNAL_MIC_TX",
    "ERASER_TX",
    "BT_TX",
    "USB_TX",
    "INCALL_TX",
)
CAPTURE_ROUTE_CONTROLS = tuple(
    f"EP{endpoint} TX Mixer {source}"
    for endpoint in (1, 2, 3, 5)
    for source in COMMON_TX_SOURCES
) + ("EP5 TX Mixer INTERNAL_MIC_US_TX",)
POWER_ROUTE_CONTROLS = ("US Record Enable", "MIC0", "MIC1", "MIC2")


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    address: int
    before: bytes
    after: bytes
    activation: bool = False

    def __post_init__(self) -> None:
        if len(self.before) != len(self.after) or not self.before:
            raise ValueError(f"{self.name}: invalid patch geometry")


@dataclasses.dataclass(frozen=True)
class StockGuard:
    name: str
    address: int
    expected: bytes


# The qualified profile keeps the native producer at one 96-frame planar block
# every 0.5 ms.  These sites belonged to superseded native-192 experiments;
# refuse them explicitly instead of silently composing two incompatible block
# geometries.  The enum-7 gate below enters the existing enum-6 96-frame fanout
# body without changing that body.
NATIVE_96_STOCK_GUARDS = (
    StockGuard(
        "native PDM callback remains 96 frames",
        0x403B8880,
        bytes.fromhex("eef3d3431380"),
    ),
    StockGuard(
        "native PDM bookkeeping remains 96 frames",
        0x403B88FE,
        bytes.fromhex("3df0"),
    ),
    StockGuard(
        "native enum-6/7 fanout body remains 96 frames",
        0x403BAAD5,
        bytes.fromhex("9e61b4870461fe61ae010381ed04"),
    ),
)

# A normal data-pointer call through the HD-microphone gain command is a
# proven cold dispatch point.  Temporarily point it at the WUQI whole-I-cache
# invalidator, issue CMD 0x016c through tinymix, and restore it immediately.
# The invalidator intentionally returns 64, which the F1 controller logs as
# rc=64 after all 64*4 cache lines have been invalidated and ISYNC has run.
CACHE_FLUSH_DISPATCH = Patch(
    "HD Mic gain dispatch -> whole F1 I-cache invalidator",
    0x4038EA50,
    bytes.fromhex("c0c83d40"),
    bytes.fromhex("e06d4840"),
)
CACHE_FLUSH_CONTROL = "HD Mic gain (cB)"
CAVE_PATCH_ADDRESS = 0x403DB863


# Keep the enum-5 -> enum-7 Stream-2 selector last.  Stream 2 supplies one
# 0x180-byte ping-pong half every 0.5 ms.  That half already contains 96
# chronological mono S32 samples.  Force the direct/raw branch, grow its one
# S32-per-iteration loop from 48 to 96, retain the raw +0x524 staging plane,
# then grow only the downstream descriptor/converter.
# Then establish both enum-7 validator checks and downstream gates and select
# the 6.4 MHz / 192 kHz / 0.5 ms PdmV3 profile.  Revert disconnects the
# activation site first.
PATCHES = (
    Patch(
        "D10 source fill 48 -> 96 frames",
        0x403DAF5D,
        bytes.fromhex("3e44282ee992"),
        bytes.fromhex("3e44242ee992"),
    ),
    Patch(
        "D10 force the direct/raw staging branch",
        0x403DB6A2,
        bytes.fromhex("2e12b2d11dc9"),
        bytes.fromhex("2e000091edc8"),
    ),
    Patch(
        "D10 direct/raw loop 48 -> 96 S32 samples",
        0x403DB7A0,
        bytes.fromhex("2ee0108fea92"),
        bytes.fromhex("2ee01c8eea92"),
    ),
    Patch(
        "D10 common-path reload/frame-count cave",
        0x403DB863,
        bytes.fromhex("000000000000000000000000"),
        bytes.fromhex("3e41a885016152a06086d9ff"),
    ),
    Patch(
        "D10 route common path through 96-frame cave",
        0x403DB7D0,
        bytes.fromhex("3e41a8850161"),
        bytes.fromhex("c62300f02000"),
    ),
    Patch(
        "D10 raw staging publish bytes 0xc0 -> 0x180",
        0x403DB7EB,
        bytes.fromhex("fec7a94e9e93"),
        bytes.fromhex("fec7a54e9e93"),
    ),
    Patch(
        "D10 preserve 96-frame direct-path descriptor",
        0x403DB81A,
        bytes.fromhex("3c05"),
        bytes.fromhex("3df0"),
    ),
    Patch(
        "D10 strict-mono converter 48 -> 96 frames",
        0x403DBC4F,
        bytes.fromhex("fe00290fe992"),
        bytes.fromhex("fe00680fe992"),
    ),
    Patch(
        "D10 strict-mono reported bytes 0x60 -> 0xc0",
        0x403DBCE2,
        bytes.fromhex("b02f11"),
        bytes.fromhex("a02f11"),
    ),
    Patch(
        "D10 main caller frame geometry 48 -> 96",
        0x403DAC3B,
        bytes.fromhex("ae9248d196cf"),
        bytes.fromhex("9e9248d196cf"),
    ),
    Patch(
        "D10 main caller staging geometry 48 -> 96",
        0x403DAC9B,
        bytes.fromhex("ff0a291c56248317"),
        bytes.fromhex("ff0a291c5d248317"),
    ),
    Patch(
        "D10 shared caller staging geometry 48 -> 96",
        0x403DAE28,
        bytes.fromhex("2eff71afe992"),
        bytes.fromhex("2eff7daee992"),
    ),
    Patch(
        "admit enum 7 in both stream-validator comparisons",
        0x403B75C9,
        bytes.fromhex("bf78b8084c0c8014"),
        bytes.fromhex("bf88b8084c1c8014"),
    ),
    Patch(
        "classify sample-rate enums 6 and 7 as high-rate streams",
        0x403B7670,
        bytes.fromhex("bf60b5002c088413"),
        bytes.fromhex("bf68b5002c088413"),
    ),
    Patch(
        "notify downstream filters for sample-rate enums 6 and 7",
        0x403B9EAC,
        bytes.fromhex("bf60411a04448617"),
        bytes.fromhex("bf68411a04448617"),
    ),
    Patch(
        "native PDM clock 3.2 MHz -> 6.4 MHz",
        0x403B84B0,
        bytes.fromhex("00d43000"),
        bytes.fromhex("00a86100"),
    ),
    Patch(
        "select the existing disabled-HPF branch at 192 kHz",
        0x403B85F6,
        bytes.fromhex("820580"),
        bytes.fromhex("82a000"),
    ),
    Patch(
        "native PDM output rate 96000 -> 192000",
        0x403B88DD,
        bytes.fromhex("8e9444ee9d93"),
        bytes.fromhex("7e9444ee9d93"),
    ),
    Patch(
        "native timestamp interval 1 ms -> 0.5 ms",
        0x403BA544,
        bytes.fromhex("8e046c91eb92"),
        bytes.fromhex("8e046092eb92"),
    ),
    Patch(
        "native timestamp diagnostic 1 ms -> 0.5 ms",
        0x403BA585,
        bytes.fromhex("ee48acfd0f93"),
        bytes.fromhex("ee48a0fe0f93"),
    ),
    Patch(
        "route sample-rate enums 6 and 7 through the 96-frame DMA/fanout body",
        0x403BAA7B,
        bytes.fromhex("ff608414163c8413"),
        bytes.fromhex("ff688414163c8413"),
    ),
    Patch(
        "Stream 2 sample-rate enum 5 -> enum 7",
        0x4038FAF4,
        bytes.fromhex("4eb3b8150081"),
        bytes.fromhex("4eb3b81d0081"),
        activation=True,
    ),
)


@dataclasses.dataclass(frozen=True)
class WriteChunk:
    patch: Patch
    address: int
    before: bytes
    after: bytes

    @property
    def width(self) -> int:
        return len(self.before) * 8


def integer(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description=(
            "Guard and switch Frankel PCM 0,10 strict-mono RAW capture to "
            "the qualified reboot-volatile 192 kHz AoC profile"
        )
    )
    parser.add_argument(
        "action", choices=("apply", "revert", "check-stock", "check-patched")
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
        "--minimal-traffic",
        action="store_true",
        help=(
            "opt in to grouped profile/guard snapshots and exactly one "
            "unverified SET command per changed aligned chunk; complete "
            "before/after verification, activation ordering, rollback, and "
            "F1 I-cache synchronization remain mandatory"
        ),
    )
    parser.add_argument(
        "--set-delay-ms",
        type=int,
        default=0,
        help=(
            "sleep this many milliseconds after each profile SET in "
            "--minimal-traffic mode so AoC's shared diagnostic work queue "
            "can drain (default: 0)"
        ),
    )
    args = parser.parse_args()
    if args.set_delay_ms < 0 or args.set_delay_ms > 5000:
        parser.error("--set-delay-ms must be between 0 and 5000")
    if args.set_delay_ms and not args.minimal_traffic:
        parser.error("--set-delay-ms requires --minimal-traffic")
    return args


def adb_text(transport: AocFactoryDiag, *arguments: str) -> str:
    return transport.run(*arguments).stdout.decode(errors="replace").strip()


def tinymix_get_many(
    transport: AocFactoryDiag, controls: tuple[str, ...]
) -> dict[str, str]:
    # Keep the safety inventory explicit while paying for only one ADB shell
    # round trip.  Each `tinymix -v CONTROL` prints exactly one value line.
    script = "set -e\n" + "".join(
        "/system/bin/tinymix -D 0 -v -- " + shlex.quote(control) + "\n"
        for control in controls
    )
    result = transport.run(
        "shell", "su", "0", "sh", input_data=script.encode(), check=False
    )
    if result.returncode:
        stderr = result.stderr.decode(errors="replace").strip()
        raise RuntimeError(
            f"batched strict-runtime tinymix read failed ({result.returncode}): "
            f"{stderr}"
        )
    values = result.stdout.decode(errors="replace").splitlines()
    if len(values) != len(controls):
        raise RuntimeError(
            "batched strict-runtime tinymix read returned "
            f"{len(values)} lines for {len(controls)} controls"
        )
    return dict(zip(controls, values, strict=True))


def require_identity(transport: AocFactoryDiag) -> None:
    state = adb_text(transport, "get-state")
    if state != "device":
        raise RuntimeError(f"ADB target is not online: {state!r}")
    device = adb_text(transport, "shell", "getprop", "ro.product.device")
    vendor_build = adb_text(
        transport, "shell", "getprop", "ro.vendor.build.id"
    )
    boot_completed = adb_text(
        transport, "shell", "getprop", "sys.boot_completed"
    )
    uid = adb_text(transport, "shell", "su", "0", "id", "-u")
    if device != EXPECTED_DEVICE:
        raise RuntimeError(f"refusing non-Frankel target ({device!r})")
    if vendor_build != EXPECTED_VENDOR_BUILD_ID:
        raise RuntimeError(
            f"refusing unreviewed vendor build {vendor_build!r}; "
            f"expected {EXPECTED_VENDOR_BUILD_ID!r}"
        )
    if boot_completed != "1":
        raise RuntimeError("Frankel has not completed boot")
    if uid != "0":
        raise RuntimeError(f"root shell is required (su 0 uid={uid!r})")
    if adb_text(transport, "shell", "getprop", "init.svc.audioserver") != "stopped":
        raise RuntimeError(
            "audioserver must be stopped so it cannot race the strict RAW mixer state"
        )
    for path in ("/dev/acd-factory_diag", "/dev/acd-debug"):
        result = transport.run(
            "shell", "su", "0", "test", "-c", path, check=False
        )
        if result.returncode:
            raise RuntimeError(f"required AoC diagnostic node is missing: {path}")
    for device_number in CAPTURE_DEVICES:
        path = f"/dev/snd/pcmC0D{device_number}c"
        result = transport.run(
            "shell", "su", "0", "test", "-c", path, check=False
        )
        if result.returncode:
            raise RuntimeError(f"required capture PCM node is missing: {path}")


def select_native_helper(transport: AocFactoryDiag) -> None:
    if transport.native_helper:
        result = transport.run(
            "shell",
            "su",
            "0",
            "test",
            "-x",
            transport.native_helper,
            check=False,
        )
        if result.returncode:
            raise RuntimeError(
                "FRANKEL_AOC_DIAG_DEVICE is not executable on the device: "
                f"{transport.native_helper}"
            )
        print(f"AoC transport=native helper={transport.native_helper}")
        return
    result = transport.run(
        "shell", "su", "0", "test", "-x", DEFAULT_NATIVE_HELPER, check=False
    )
    if result.returncode == 0:
        transport.native_helper = DEFAULT_NATIVE_HELPER
        print(f"AoC transport=native helper={DEFAULT_NATIVE_HELPER}")
    else:
        print("AoC transport=factory_diag shell fallback")


def block_capture_opens(transport: AocFactoryDiag) -> dict[str, str]:
    modes: dict[str, str] = {}
    for device_number in CAPTURE_DEVICES:
        path = f"/dev/snd/pcmC0D{device_number}c"
        mode = adb_text(transport, "shell", "su", "0", "stat", "-c", "%a", path)
        if not re.fullmatch(r"[0-7]{1,4}", mode):
            raise RuntimeError(f"unexpected mode for {path}: {mode!r}")
        modes[path] = mode
    changed: list[str] = []
    try:
        for path in modes:
            transport.run("shell", "su", "0", "chmod", "000", path)
            changed.append(path)
        for path in modes:
            mode = adb_text(
                transport, "shell", "su", "0", "stat", "-c", "%a", path
            )
            if mode != "0":
                raise RuntimeError(f"failed to quarantine new opens on {path}")
    except Exception:
        for path in changed:
            transport.run(
                "shell", "su", "0", "chmod", modes[path], path, check=False
            )
        raise
    print("blocked new opens on PCM 0,8/9/10/12")
    return modes


def restore_capture_modes(
    transport: AocFactoryDiag, modes: dict[str, str]
) -> None:
    failures: list[str] = []
    for path, mode in modes.items():
        result = transport.run(
            "shell", "su", "0", "chmod", mode, path, check=False
        )
        if result.returncode:
            failures.append(path)
    if failures:
        raise RuntimeError(
            "failed to restore capture PCM modes: " + ", ".join(failures)
        )
    print("restored capture modes on PCM 0,8/9/10/12")


def require_capture_idle(transport: AocFactoryDiag) -> None:
    # The Frankel kernel normally omits per-substream status files while these
    # PCMs are closed.  Scan the actual character-device owners instead.  Only
    # process-exit ENOENT races are tolerated; every other ls error is an
    # incomplete scan and therefore a refusal.
    result = transport.run(
        "shell",
        "su",
        "0",
        "sh",
        input_data=b"exec ls -l /proc/[0-9]*/fd/*\n",
        check=False,
    )
    errors = [
        line.strip()
        for line in result.stderr.decode(errors="replace").splitlines()
        if line.strip()
    ]
    unexpected = [
        line
        for line in errors
        if re.fullmatch(
            r"ls: /proc/\d+/fd/\d+: No such file or directory", line
        )
        is None
    ]
    if unexpected:
        raise RuntimeError("incomplete root proc-fd scan: " + "; ".join(unexpected))
    wanted = {
        f"/dev/snd/pcmC0D{device_number}c" for device_number in CAPTURE_DEVICES
    }
    owners: list[str] = []
    pattern = re.compile(r".*\s(/proc/\d+/fd/\d+) -> (/dev/snd/pcmC0D\d+c)$")
    for line in result.stdout.decode(errors="replace").splitlines():
        match = pattern.fullmatch(line)
        if match and match.group(2) in wanted:
            owners.append(f"{match.group(1)} -> {match.group(2)}")
    if owners:
        raise RuntimeError(
            "D8/D9/D10/D12 capture is active:\n" + "\n".join(owners)
        )
    print("verified PCM 0,8/9/10/12 closed")


def require_strict_runtime(transport: AocFactoryDiag) -> int:
    strict_controls = (
        "BUILDIN MIC ID CAPTURE LIST",
        "BUILTIN MIC Process Mode",
        "Audio Capture Mic Source",
        "Mic Spatial Module Enable",
        "MIC DC Blocker",
        CACHE_FLUSH_CONTROL,
        "INTERNAL_MIC_TX Sample Rate",
        "INTERNAL_MIC_TX Format",
        "INTERNAL_MIC_TX Chan",
    )
    controls = CAPTURE_ROUTE_CONTROLS + POWER_ROUTE_CONTROLS + strict_controls
    values = tinymix_get_many(transport, controls)
    for control in CAPTURE_ROUTE_CONTROLS + POWER_ROUTE_CONTROLS:
        actual = values[control]
        if actual not in ("0", "Off"):
            raise RuntimeError(
                f"capture route/control is not off: {control}={actual!r}"
            )

    capture_list = values["BUILDIN MIC ID CAPTURE LIST"]
    fields = capture_list.split()
    if (
        len(fields) != 4
        or fields[0] not in ("0", "1", "2")
        or fields[1:] != ["-1", "-1", "-1"]
    ):
        raise RuntimeError(
            "BUILDIN MIC ID CAPTURE LIST must select exactly one logical mic "
            f"as 0|1|2 -1 -1 -1, got {capture_list!r}"
        )
    expected = {
        "BUILTIN MIC Process Mode": "Raw",
        "Audio Capture Mic Source": "Builtin_MIC",
        "Mic Spatial Module Enable": ("0", "Off"),
        "MIC DC Blocker": ("0", "Off"),
        CACHE_FLUSH_CONTROL: "0",
        "INTERNAL_MIC_TX Sample Rate": "SR_192K",
        "INTERNAL_MIC_TX Format": "S16_LE",
        "INTERNAL_MIC_TX Chan": "One",
    }
    for control, wanted in expected.items():
        actual = values[control]
        choices = (wanted,) if isinstance(wanted, str) else wanted
        if actual not in choices:
            raise RuntimeError(
                f"strict RAW runtime mismatch: {control}={actual!r}, "
                f"expected one of {choices!r}"
            )
    selected = int(fields[0])
    print(f"strict runtime=RAW/S16_LE/mono/192000 logical_mic={selected}")
    return selected


def classify(actual: bytes, patch: Patch) -> str:
    if actual == patch.before:
        return "stock"
    if actual == patch.after:
        return "patched"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
        f"{actual.hex()} (stock {patch.before.hex()}, patched {patch.after.hex()})"
    )


def read_states(transport: AocFactoryDiag) -> dict[Patch, str]:
    states: dict[Patch, str] = {}
    for patch in PATCHES:
        actual = transport.dump(patch.address, len(patch.before))
        state = classify(actual, patch)
        states[patch] = state
        print(f"{state:7s} 0x{patch.address:08x} {actual.hex()}  {patch.name}")
    return states


MemorySite = Patch | StockGuard
MAX_GROUPED_DUMP_BYTES = 256


def site_stock_bytes(site: MemorySite) -> bytes:
    return site.before if isinstance(site, Patch) else site.expected


def grouped_dump_ranges(
    sites: tuple[MemorySite, ...],
) -> tuple[tuple[int, int], ...]:
    """Cover variable-width sites with greedy, bounded diagnostic reads."""

    if not sites:
        return ()
    expected_bytes: dict[int, int] = {}
    spans: set[tuple[int, int]] = set()
    for site in sites:
        expected = site_stock_bytes(site)
        spans.add((site.address, site.address + len(expected)))
        for offset, value in enumerate(expected):
            address = site.address + offset
            previous = expected_bytes.setdefault(address, value)
            if previous != value:
                raise ValueError(
                    f"conflicting grouped stock guards at 0x{address:08x}"
                )

    ordered = sorted(spans)
    start, end = ordered[0]
    ranges: list[tuple[int, int]] = []
    for site_start, site_end in ordered[1:]:
        if max(end, site_end) - start <= MAX_GROUPED_DUMP_BYTES:
            end = max(end, site_end)
        else:
            ranges.append((start, end - start))
            start, end = site_start, site_end
    ranges.append((start, end - start))
    return tuple(ranges)


def read_sites_grouped(
    transport: AocFactoryDiag, sites: tuple[MemorySite, ...]
) -> dict[int, bytes]:
    """Read every requested site through complete <=256-byte snapshots."""

    values: dict[int, bytes] = {}
    for start, size in grouped_dump_ranges(sites):
        data = transport.dump(start, size)
        if len(data) != size:
            raise RuntimeError(
                f"short grouped AoC dump at 0x{start:08x}: "
                f"got {len(data)}, expected {size}"
            )
        for site in sites:
            site_size = len(site_stock_bytes(site))
            if start <= site.address and site.address + site_size <= start + size:
                offset = site.address - start
                actual = data[offset : offset + site_size]
                previous = values.setdefault(site.address, actual)
                if previous != actual:
                    raise RuntimeError(
                        f"inconsistent grouped AoC snapshot at 0x{site.address:08x}"
                    )
    missing = sorted({site.address for site in sites} - set(values))
    if missing:
        raise RuntimeError(
            "grouped AoC dump omitted site(s): "
            + ", ".join(f"0x{address:08x}" for address in missing)
        )
    return values


def read_states_and_stock_guards_grouped(
    transport: AocFactoryDiag,
) -> tuple[dict[Patch, str], int]:
    """Classify the full D10 profile and exact stock guards coherently."""

    sites: tuple[MemorySite, ...] = (
        PATCHES + NATIVE_96_STOCK_GUARDS + (CACHE_FLUSH_DISPATCH,)
    )
    ranges = grouped_dump_ranges(sites)
    values = read_sites_grouped(transport, sites)

    for guard in NATIVE_96_STOCK_GUARDS:
        actual = values[guard.address]
        if actual != guard.expected:
            raise ValueError(
                f"{guard.name}: unexpected bytes at 0x{guard.address:08x}: "
                f"{actual.hex()} (required stock {guard.expected.hex()})"
            )
        print(f"guard   0x{guard.address:08x} {actual.hex()}  {guard.name}")
    dispatch = values[CACHE_FLUSH_DISPATCH.address]
    if dispatch != CACHE_FLUSH_DISPATCH.before:
        raise ValueError(
            "whole-I-cache flush dispatch is not restored at "
            f"0x{CACHE_FLUSH_DISPATCH.address:08x}: {dispatch.hex()} "
            f"(required {CACHE_FLUSH_DISPATCH.before.hex()})"
        )
    print(
        f"guard   0x{CACHE_FLUSH_DISPATCH.address:08x} {dispatch.hex()}  "
        "whole-I-cache flush dispatch restored"
    )

    states: dict[Patch, str] = {}
    for patch in PATCHES:
        actual = values[patch.address]
        state = classify(actual, patch)
        states[patch] = state
        print(f"{state:7s} 0x{patch.address:08x} {actual.hex()}  {patch.name}")
    return states, len(ranges)


def require_stock_guards(transport: AocFactoryDiag) -> None:
    for guard in NATIVE_96_STOCK_GUARDS:
        actual = transport.dump(guard.address, len(guard.expected))
        if actual != guard.expected:
            raise ValueError(
                f"{guard.name}: unexpected bytes at 0x{guard.address:08x}: "
                f"{actual.hex()} (required stock {guard.expected.hex()})"
            )
        print(
            f"guard   0x{guard.address:08x} {actual.hex()}  {guard.name}"
        )
    dispatch = transport.dump(
        CACHE_FLUSH_DISPATCH.address, len(CACHE_FLUSH_DISPATCH.before)
    )
    if dispatch != CACHE_FLUSH_DISPATCH.before:
        raise ValueError(
            "whole-I-cache flush dispatch is not restored at "
            f"0x{CACHE_FLUSH_DISPATCH.address:08x}: {dispatch.hex()} "
            f"(required {CACHE_FLUSH_DISPATCH.before.hex()})"
        )
    print(
        f"guard   0x{CACHE_FLUSH_DISPATCH.address:08x} {dispatch.hex()}  "
        "whole-I-cache flush dispatch restored"
    )


def changed_chunks(patch: Patch, action: str) -> tuple[WriteChunk, ...]:
    source = patch.before if action == "apply" else patch.after
    destination = patch.after if action == "apply" else patch.before
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
        old = source[offset : offset + width_bytes]
        new = destination[offset : offset + width_bytes]
        if old != new:
            chunks.append(WriteChunk(patch, address, old, new))
        offset += width_bytes
    return tuple(chunks)


def write_chunk(transport: AocFactoryDiag, chunk: WriteChunk) -> None:
    actual = transport.dump(chunk.address, len(chunk.before))
    if actual != chunk.before:
        raise ValueError(
            f"{chunk.patch.name}: changed before write at 0x{chunk.address:08x}: "
            f"{actual.hex()}, expected {chunk.before.hex()}"
        )
    transport.write(
        chunk.address, int.from_bytes(chunk.after, "little"), chunk.width
    )
    verified = transport.dump(chunk.address, len(chunk.after))
    if verified != chunk.after:
        raise RuntimeError(
            f"write verification failed at 0x{chunk.address:08x}: "
            f"got {verified.hex()}, expected {chunk.after.hex()}"
        )
    print(
        f"write{chunk.width:<2d} 0x{chunk.address:08x} "
        f"{chunk.before.hex()}->{chunk.after.hex()}  {chunk.patch.name}"
    )


def flush_instruction_cache(transport: AocFactoryDiag) -> None:
    """Invoke the proven whole-F1-I-cache invalidator through CMD 0x016c."""

    chunks = changed_chunks(CACHE_FLUSH_DISPATCH, "apply")
    if len(chunks) != 1:
        raise AssertionError("cache-flush dispatch must be one atomic write")
    install = chunks[0]
    restore = WriteChunk(
        CACHE_FLUSH_DISPATCH,
        install.address,
        install.after,
        install.before,
    )
    initial = transport.dump(install.address, len(install.before))
    if initial != install.before:
        raise ValueError(
            "refusing cache flush with non-stock HD Mic dispatch at "
            f"0x{install.address:08x}: {initial.hex()}"
        )

    invocation_error: BaseException | None = None
    restore_error: BaseException | None = None
    try:
        write_chunk(transport, install)
        result = transport.run(
            "shell",
            "su",
            "0",
            "sh",
            input_data=(
                'exec /system/bin/tinymix -D 0 -- "HD Mic gain (cB)" 0\n'
            ).encode(),
            check=False,
        )
        # The invalidator deliberately leaves a2=64, so the controller logs
        # rc=64 and tinymix may surface either success or its generic failure
        # status.  Any shell/transport status beyond that pair is not the
        # qualified CMD 0x016c invocation.
        if result.returncode not in (0, 1):
            stderr = result.stderr.decode(errors="replace").strip()
            raise RuntimeError(
                "HD Mic CMD 0x016c cache-flush trigger failed with status "
                f"{result.returncode}: {stderr}"
            )
        print(
            "invoked HD Mic CMD 0x016c whole-I-cache invalidator "
            f"(tinymix status {result.returncode}, expected F1 rc=64)"
        )
    except BaseException as error:
        invocation_error = error
    try:
        actual = transport.dump(restore.address, len(restore.before))
        if actual == restore.before:
            write_chunk(transport, restore)
        elif actual != restore.after:
            raise RuntimeError(
                "cache-flush dispatch changed unexpectedly before restore: "
                f"{actual.hex()}"
            )
        verified = transport.dump(restore.address, len(restore.after))
        if verified != restore.after:
            raise RuntimeError(
                "cache-flush dispatch restore verification failed: "
                f"{verified.hex()}"
            )
    except BaseException as error:
        restore_error = error

    if restore_error is not None:
        if invocation_error is not None:
            raise RuntimeError(
                f"cache flush failed ({invocation_error}); additionally the "
                f"dispatch restore failed ({restore_error})"
            ) from invocation_error
        raise restore_error
    if invocation_error is not None:
        raise invocation_error
    print("restored and verified the stock HD Mic dispatch pointer")


def flush_instruction_cache_minimal(transport: AocFactoryDiag) -> None:
    """Flush F1's I-cache with raw SETs and exact dispatch restoration."""

    chunks = changed_chunks(CACHE_FLUSH_DISPATCH, "apply")
    if len(chunks) != 1 or chunks[0].width != 32:
        raise AssertionError("cache-flush dispatch must be one atomic word")
    install = chunks[0]
    initial = transport.dump(install.address, len(install.before))
    if initial != install.before:
        raise ValueError(
            "refusing minimal cache flush with non-stock HD Mic dispatch at "
            f"0x{install.address:08x}: {initial.hex()}"
        )

    invocation_error: BaseException | None = None
    restore_error: BaseException | None = None
    install_attempted = False
    try:
        # Mark the SET attempted before issuing it. A transport error can be
        # ambiguous about whether the device consumed the command.
        install_attempted = True
        transport.write_unverified(
            install.address, int.from_bytes(install.after, "little"), install.width
        )
        result = transport.run(
            "shell",
            "su",
            "0",
            "sh",
            input_data=(
                'exec /system/bin/tinymix -D 0 -- "HD Mic gain (cB)" 0\n'
            ).encode(),
            check=False,
        )
        if result.returncode not in (0, 1):
            stderr = result.stderr.decode(errors="replace").strip()
            raise RuntimeError(
                "HD Mic CMD 0x016c cache-flush trigger failed with status "
                f"{result.returncode}: {stderr}"
            )
        print(
            "invoked HD Mic CMD 0x016c whole-I-cache invalidator "
            f"(tinymix status {result.returncode}, expected F1 rc=64)"
        )
    except BaseException as error:
        invocation_error = error
    if install_attempted:
        try:
            actual = transport.dump(install.address, len(install.after))
            if actual == install.after:
                transport.write_unverified(
                    install.address,
                    int.from_bytes(install.before, "little"),
                    install.width,
                )
            elif actual != install.before:
                raise RuntimeError(
                    "minimal cache-flush dispatch changed unexpectedly before "
                    f"restore: {actual.hex()}"
                )
            verified = transport.dump(install.address, len(install.before))
            if verified != install.before:
                raise RuntimeError(
                    "minimal cache-flush dispatch restore verification failed: "
                    f"{verified.hex()}"
                )
        except BaseException as error:
            restore_error = error

    if restore_error is not None:
        if invocation_error is not None:
            raise RuntimeError(
                f"minimal cache flush failed ({invocation_error}); additionally "
                f"the dispatch restore failed ({restore_error})"
            ) from invocation_error
        raise restore_error
    if invocation_error is not None:
        raise invocation_error
    print("restored and verified the stock HD Mic dispatch pointer")


def ordered_mutation_patches(action: str) -> tuple[Patch, ...]:
    """Return cave/support/activation sites in the audited transition order."""

    if action not in ("apply", "revert"):
        raise ValueError(f"unsupported mutation action {action!r}")
    caves = tuple(patch for patch in PATCHES if patch.address == CAVE_PATCH_ADDRESS)
    support = tuple(
        patch
        for patch in PATCHES
        if not patch.activation and patch.address != CAVE_PATCH_ADDRESS
    )
    activation = tuple(patch for patch in PATCHES if patch.activation)
    if len(caves) != 1 or len(activation) != 1:
        raise AssertionError(
            "D10 profile must contain one cave and one activation site"
        )
    if action == "apply":
        return caves + support + activation
    return tuple(reversed(activation)) + tuple(reversed(support)) + tuple(
        reversed(caves)
    )


def ordered_mutation_chunks(action: str) -> tuple[WriteChunk, ...]:
    """Expand the audited patch order into naturally aligned changed chunks."""

    return tuple(
        chunk
        for patch in ordered_mutation_patches(action)
        for chunk in changed_chunks(patch, action)
    )


def rollback_chunks_minimal(
    transport: AocFactoryDiag, attempted: list[WriteChunk]
) -> list[str]:
    """Undo possibly consumed raw SETs in reverse safety order."""

    if not attempted:
        return []
    try:
        snapshot = read_sites_grouped(transport, PATCHES)
    except (OSError, RuntimeError, ValueError) as error:
        return [f"grouped rollback snapshot={error}"]

    failures: list[str] = []
    for chunk in reversed(attempted):
        patch_bytes = snapshot[chunk.patch.address]
        offset = chunk.address - chunk.patch.address
        actual = patch_bytes[offset : offset + len(chunk.after)]
        if actual == chunk.before:
            continue
        if actual != chunk.after:
            failures.append(f"0x{chunk.address:08x}=unknown:{actual.hex()}")
            continue
        try:
            transport.write_unverified(
                chunk.address,
                int.from_bytes(chunk.before, "little"),
                chunk.width,
            )
            print(
                f"rollback{chunk.width:<2d} 0x{chunk.address:08x} "
                f"{chunk.after.hex()}->{chunk.before.hex()}  {chunk.patch.name}"
            )
        except (OSError, RuntimeError, ValueError) as error:
            failures.append(f"0x{chunk.address:08x}={error}")
    return failures


def mutate_minimal(
    transport: AocFactoryDiag,
    action: str,
    states: dict[Patch, str],
    set_delay_ms: int = 0,
) -> None:
    """Run one grouped-snapshot/raw-SET D10 transaction."""

    source_state = "stock" if action == "apply" else "patched"
    destination_state = "patched" if action == "apply" else "stock"
    state_values = set(states.values())
    if state_values == {destination_state}:
        flush_instruction_cache_minimal(transport)
        final_states, _ = read_states_and_stock_guards_grouped(transport)
        if set(final_states.values()) != {destination_state}:
            raise RuntimeError(
                "profile changed while synchronizing the F1 instruction cache"
            )
        print(
            f"AoC memory was already uniformly {destination_state}; "
            "synchronized the F1 instruction cache"
        )
        return
    if state_values != {source_state}:
        raise ValueError(
            f"refusing mixed D10 profile {sorted(state_values)}; expected all "
            f"{source_state} or all {destination_state}"
        )

    attempted: list[WriteChunk] = []
    try:
        for chunk in ordered_mutation_chunks(action):
            # Append first because a failed host transport can be ambiguous
            # about whether this one device-side SET was consumed.
            attempted.append(chunk)
            transport.write_unverified(
                chunk.address,
                int.from_bytes(chunk.after, "little"),
                chunk.width,
            )
            print(
                f"write{chunk.width:<2d} 0x{chunk.address:08x} "
                f"{chunk.before.hex()}->{chunk.after.hex()}  {chunk.patch.name}"
            )
            if set_delay_ms:
                time.sleep(set_delay_ms / 1000.0)

        final_states, _ = read_states_and_stock_guards_grouped(transport)
        if set(final_states.values()) != {destination_state}:
            raise RuntimeError(
                f"final verification was not uniformly {destination_state}"
            )
        flush_instruction_cache_minimal(transport)
        final_states, _ = read_states_and_stock_guards_grouped(transport)
        if set(final_states.values()) != {destination_state}:
            raise RuntimeError(
                "profile changed while synchronizing the F1 instruction cache"
            )
    except BaseException as error:
        failures = rollback_chunks_minimal(transport, attempted)
        if not failures:
            try:
                restored_states, _ = read_states_and_stock_guards_grouped(transport)
                if set(restored_states.values()) != {source_state}:
                    raise RuntimeError(
                        f"rollback was not uniformly {source_state}"
                    )
                flush_instruction_cache_minimal(transport)
                restored_states, _ = read_states_and_stock_guards_grouped(transport)
                if set(restored_states.values()) != {source_state}:
                    raise RuntimeError(
                        "rollback changed while synchronizing the F1 instruction cache"
                    )
            except (OSError, RuntimeError, ValueError) as sync_error:
                failures.append(f"I-cache rollback sync={sync_error}")
        if failures:
            raise RuntimeError(
                f"minimal transaction failed ({error}); rollback was incomplete: "
                + "; ".join(failures)
            ) from error
        raise RuntimeError(
            f"minimal transaction failed ({error}); restored the complete "
            "initial profile"
        ) from error

    print(
        f"verified uniformly {destination_state}; live changes disappear on "
        "AoC/device reboot"
    )


def run_minimal_traffic(
    transport: AocFactoryDiag, action: str, set_delay_ms: int = 0
) -> int:
    """Guard and run one D10 action with bounded diagnostic traffic."""

    states, before_ranges = read_states_and_stock_guards_grouped(transport)
    if action.startswith("check-"):
        wanted = action.removeprefix("check-")
        if set(states.values()) != {wanted}:
            raise ValueError(f"AoC D10 profile is not uniformly {wanted}")
        print(
            f"minimal traffic: checked the complete profile and stock guards "
            f"in {before_ranges} grouped dump command(s)"
        )
        return 0

    mutate_minimal(transport, action, states, set_delay_ms)
    print(
        f"minimal traffic: guarded the complete profile and stock guards in "
        f"{before_ranges} grouped dump command(s) before mutation"
    )
    return 0


def rollback_chunks(
    transport: AocFactoryDiag, attempted: list[WriteChunk]
) -> list[str]:
    failures: list[str] = []
    for chunk in reversed(attempted):
        try:
            actual = transport.dump(chunk.address, len(chunk.after))
            if actual == chunk.before:
                continue
            if actual != chunk.after:
                failures.append(
                    f"0x{chunk.address:08x}=unknown:{actual.hex()}"
                )
                continue
            transport.write(
                chunk.address,
                int.from_bytes(chunk.before, "little"),
                chunk.width,
            )
            verified = transport.dump(chunk.address, len(chunk.before))
            if verified != chunk.before:
                failures.append(
                    f"0x{chunk.address:08x}=verify:{verified.hex()}"
                )
        except (OSError, RuntimeError, ValueError) as error:
            failures.append(f"0x{chunk.address:08x}={error}")
    return failures


def mutate(
    transport: AocFactoryDiag, action: str, states: dict[Patch, str]
) -> None:
    source_state = "stock" if action == "apply" else "patched"
    destination_state = "patched" if action == "apply" else "stock"
    state_values = set(states.values())
    if state_values == {destination_state}:
        require_stock_guards(transport)
        flush_instruction_cache(transport)
        print(
            f"AoC memory was already uniformly {destination_state}; "
            "synchronized the F1 instruction cache"
        )
        return
    if state_values != {source_state}:
        raise ValueError(
            f"refusing mixed D10 profile {sorted(state_values)}; expected all "
            f"{source_state} or all {destination_state}"
        )

    attempted: list[WriteChunk] = []
    try:
        for patch in ordered_mutation_patches(action):
            for chunk in changed_chunks(patch, action):
                attempted.append(chunk)
                write_chunk(transport, chunk)
        final_states = read_states(transport)
        if set(final_states.values()) != {destination_state}:
            raise RuntimeError(
                f"final verification was not uniformly {destination_state}"
            )
        require_stock_guards(transport)
        flush_instruction_cache(transport)
        final_states = read_states(transport)
        if set(final_states.values()) != {destination_state}:
            raise RuntimeError(
                "profile changed while synchronizing the F1 instruction cache"
            )
        require_stock_guards(transport)
    except BaseException as error:
        failures = rollback_chunks(transport, attempted)
        if not failures:
            try:
                restored_states = read_states(transport)
                if set(restored_states.values()) != {source_state}:
                    raise RuntimeError(
                        f"rollback was not uniformly {source_state}"
                    )
                require_stock_guards(transport)
                flush_instruction_cache(transport)
                require_stock_guards(transport)
            except (OSError, RuntimeError, ValueError) as sync_error:
                failures.append(f"I-cache rollback sync={sync_error}")
        if failures:
            raise RuntimeError(
                f"transaction failed ({error}); rollback was incomplete: "
                + "; ".join(failures)
            ) from error
        raise RuntimeError(
            f"transaction failed ({error}); restored the complete initial profile"
        ) from error
    print(
        f"verified uniformly {destination_state}; live changes disappear on "
        "AoC/device reboot"
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
    modes = block_capture_opens(transport)
    operation_error: BaseException | None = None
    try:
        require_capture_idle(transport)
        require_strict_runtime(transport)
        require_stock_guards(transport)
        states = None if args.minimal_traffic else read_states(transport)
        # Recheck after the diagnostic reads and immediately before a possible
        # mutation.  Capture opens remain quarantined throughout this window.
        require_capture_idle(transport)
        require_strict_runtime(transport)
        if args.minimal_traffic:
            # The grouped snapshot is the second exact stock-guard check and
            # the complete profile classification immediately before any raw
            # SET.  The earlier guard read makes the intervening runtime
            # recheck meaningful without duplicating all 22 profile sites.
            run_minimal_traffic(transport, args.action, args.set_delay_ms)
        else:
            require_stock_guards(transport)
            if states is None:
                raise AssertionError("normal traffic path omitted patch states")
            if args.action.startswith("check-"):
                wanted = args.action.removeprefix("check-")
                if set(states.values()) != {wanted}:
                    raise ValueError(f"AoC D10 profile is not uniformly {wanted}")
            else:
                mutate(transport, args.action, states)
    except BaseException as error:
        operation_error = error
    try:
        restore_capture_modes(transport, modes)
    except (OSError, RuntimeError, ValueError) as restore_error:
        if operation_error is None:
            raise
        raise RuntimeError(
            f"operation failed ({operation_error}); additionally {restore_error}"
        ) from operation_error
    if operation_error is not None:
        raise operation_error
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
