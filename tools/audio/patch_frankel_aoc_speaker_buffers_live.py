#!/usr/bin/env python3
"""Allocate and install double-depth Frankel AoC speaker buffers.

This reboot-volatile qualification helper targets the exact
CP2A.260805.005 F1 image.  It makes the single aligned 0x3000-byte allocation
that live hardware proved the micro-heap can satisfy, then splits it into four
0xc00-byte regions for the two CPU staging objects and TX/RX DMA
RingBufferStatic objects.  Each region holds two native-q192 four-S16 blocks
of 0x600 bytes.  A second allocation is forbidden: a live second 0x3000
request exhausted HeapMicroAllocGenericInternal and restarted AoC.

There is intentionally no live revert: the second bank is an interior pointer
into the allocation.  A cold AoC/device reset is the only supported rollback.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import struct
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_speaker_192k import (
    EXPECTED_DEVICE,
    EXPECTED_VENDOR_BUILD_ID,
    flush_instruction_cache,
)


RESTART_COUNT = "/sys/devices/platform/9000000.aoc/restart_count"
COREDUMP_COUNT = "/sys/devices/platform/9000000.aoc/coredump_count"

SPEAKER = 0x4051B0B8
SPEAKER_VTABLE = 0x40275D00
STOCK_BANK_BYTES = 0x600
NATIVE_BLOCK_BYTES = 0x600
BANK_BYTES = 0xC00
CPU_SOURCE_OFFSET = BANK_BYTES
DMA_TX_OFFSET = BANK_BYTES * 2
DMA_RX_OFFSET = BANK_BYTES * 3
ALLOCATION_BYTES = BANK_BYTES * 4
# The CP2A F1 factory diagnostic path advertises 256-byte dumps, but a live
# read near the upper speaker heap returned only four 16-byte lines before
# its internal memory-fault guard fired.  Keep zero-validation reads inside
# the hardware-proven 64-byte window.
ZERO_SCAN_CHUNK_BYTES = 64
HEAP_MINIMUM = 0x4051C800
HEAP_LIMIT = 0x42000000

TX_SIZE_ADDRESS = SPEAKER + 0x2B8
SOURCE_SIZE_ADDRESS = SPEAKER + 0x2BC
TX_POINTER_ADDRESS = SPEAKER + 0x2C4
SOURCE_POINTER_ADDRESS = SPEAKER + 0x2C8
STOCK_TX_POINTER = 0x4051BBE0
STOCK_SOURCE_POINTER = 0x4051C1F0

TX_RING_POINTER_ADDRESS = SPEAKER + 0x200
RX_RING_POINTER_ADDRESS = SPEAKER + 0x204
STOCK_TX_RING = 0x4051CD08
STOCK_RX_RING = 0x4051D488
RING_VTABLE = 0x40359C38


@dataclasses.dataclass(frozen=True)
class RingLayout:
    name: str
    address: int
    metadata: int
    inline_backing: int
    descriptor: int


DMA_RINGS = (
    RingLayout("SPKR_TX_DMA", STOCK_TX_RING, 0x4051CDD8, 0x4051CE80, 0x4051CDA4),
    RingLayout("SPKR_RX_DMA", STOCK_RX_RING, 0x4051D558, 0x4051D600, 0x4051D524),
)

SCRATCH_LITERAL_ADDRESS = 0x403E7814
SCRATCH_ADDRESS = 0x403F64A0
ALLOCATOR_BODY_ADDRESS = 0x403E87D0
ALIGNED_ALLOC_LITERAL_ADDRESS = 0x403C4030
ALIGNED_ALLOC_LITERAL = 0x4040BF40
D12_CALLBACK_SLOT = 0x4027C768
STOCK_D12_CALLBACK = 0x403E87D0
WHOLE_CACHE_INVALIDATOR = 0x40486DE0
HD_MIC_DISPATCH = 0x4038EA50
STOCK_HD_MIC_DISPATCH = 0x403DC8C0


@dataclasses.dataclass(frozen=True)
class WordPatch:
    name: str
    address: int
    before: bytes
    after: bytes

    def __post_init__(self) -> None:
        if self.address & 3 or len(self.before) != 4 or len(self.after) != 4:
            raise ValueError(f"{self.name}: patch is not one aligned word")


D12_QUARANTINE = WordPatch(
    "D12 callback -> whole-cache invalidator",
    D12_CALLBACK_SLOT,
    STOCK_D12_CALLBACK.to_bytes(4, "little"),
    WHOLE_CACHE_INVALIDATOR.to_bytes(4, "little"),
)
SCRATCH_LITERAL_PATCHES = (
    WordPatch(
        "allocator result literal",
        SCRATCH_LITERAL_ADDRESS,
        bytes(4),
        SCRATCH_ADDRESS.to_bytes(4, "little"),
    ),
    WordPatch(
        "allocator P192 marker",
        SCRATCH_LITERAL_ADDRESS + 4,
        bytes(4),
        bytes.fromhex("32393150"),
    ),
)

# Linked at 0x403e87d0 with the reviewed HiFi4 toolchain.  Unlike the retired
# D12 trigger this entry does not dereference its argument: entry; a10=64;
# a11=48<<8=0x3000; call aligned_alloc through the stock literal at 0x403c4030;
# publish a10 through the literal at 0x403e7814; retw.n.
ALLOCATOR_BODY_PATCHES = (
    WordPatch("pure allocator word 0", 0x403E87D0, bytes.fromhex("3641005e"), bytes.fromhex("3641004c")),
    WordPatch("pure allocator word 1", 0x403E87D4, bytes.fromhex("030848dd"), bytes.fromhex("0a3c0b80")),
    WordPatch("pure allocator word 2", 0x403E87D8, bytes.fromhex("c81df000"), bytes.fromhex("bb118115")),
    WordPatch("pure allocator word 3", 0x403E87DC, bytes.fromhex("bd04e501"), bytes.fromhex("6ee00800")),
    WordPatch("pure allocator word 4", 0x403E87E0, bytes.fromhex("001df000"), bytes.fromhex("410dfca9")),
    WordPatch("pure allocator word 5", 0x403E87E4, bytes(4), bytes.fromhex("041df000")),
)
ALLOCATOR_DISPATCH = WordPatch(
    "HD Mic dispatch -> pure allocator",
    HD_MIC_DISPATCH,
    STOCK_HD_MIC_DISPATCH.to_bytes(4, "little"),
    ALLOCATOR_BODY_ADDRESS.to_bytes(4, "little"),
)

# Keep the cold, boot-selected q48/source-0 object exact so the helper cannot
# silently rebase a different layout or an object that has entered a new
# Start.  The configuration-dependent +0x288/+0x298 fields are 0x1800/48 in
# that live idle state; q192 crash cores instead contain 0x3000/192.
FIXED_SPEAKER_FIELDS = {
    0x280: 0x00010000,
    0x284: 0x4051C7F8,
    0x288: 0x00001800,
    0x28C: 4,
    0x290: 2,
    0x294: 3,
    0x298: 0x30,
    0x29C: 0x300,
    0x2A0: 0xC0,
    0x2A4: 0x300,
    0x2A8: 0x300,
    0x2AC: 0,
    0x2B0: 0,
    0x2B4: 0x300,
    0x2C0: 0x4051B8D0,
    0x2CC: 0x4051B800,
    0x2D0: 0x4051B880,
}


def u32(transport: AocFactoryDiag, address: int) -> int:
    return struct.unpack("<I", transport.dump(address, 4))[0]


def adb_text(transport: AocFactoryDiag, *arguments: str) -> str:
    return transport.run(*arguments).stdout.decode(errors="replace").strip()


def generation(transport: AocFactoryDiag) -> tuple[int, int]:
    values = []
    for path in (RESTART_COUNT, COREDUMP_COUNT):
        value = adb_text(transport, "shell", "su", "0", "cat", path)
        if not value.isdecimal():
            raise RuntimeError(f"invalid AoC counter {path}: {value!r}")
        values.append(int(value))
    return values[0], values[1]


def require_generation(
    transport: AocFactoryDiag, expected: tuple[int, int]
) -> None:
    actual = generation(transport)
    if actual != expected:
        raise RuntimeError(
            "AoC generation changed: "
            f"restart {expected[0]}->{actual[0]}, "
            f"coredump {expected[1]}->{actual[1]}; cold reboot before retrying"
        )


def checked_patch(
    transport: AocFactoryDiag, patch: WordPatch, apply: bool
) -> None:
    source, destination = (
        (patch.before, patch.after) if apply else (patch.after, patch.before)
    )
    actual = transport.dump(patch.address, 4)
    if actual == destination:
        return
    if actual != source:
        raise ValueError(
            f"{patch.name}: 0x{patch.address:08x} is {actual.hex()}, "
            f"expected {source.hex()}"
        )
    transport.write(patch.address, int.from_bytes(destination, "little"), 32)
    actual = transport.dump(patch.address, 4)
    if actual != destination:
        raise RuntimeError(
            f"{patch.name}: readback {actual.hex()} != {destination.hex()}"
        )
    print(
        f"write32 0x{patch.address:08x} {source.hex()}->{destination.hex()}  "
        f"{patch.name}"
    )


def checked_u32(
    transport: AocFactoryDiag, address: int, expected: int, value: int, name: str
) -> None:
    actual = u32(transport, address)
    if actual != expected:
        raise ValueError(
            f"{name}: 0x{address:08x}=0x{actual:08x}, expected 0x{expected:08x}"
        )
    transport.write(address, value, 32)
    actual = u32(transport, address)
    if actual != value:
        raise RuntimeError(
            f"{name}: 0x{address:08x}=0x{actual:08x} after write, "
            f"expected 0x{value:08x}"
        )
    print(f"write32 0x{address:08x} 0x{expected:08x}->0x{value:08x}  {name}")


def require_temporary_stock(transport: AocFactoryDiag) -> None:
    for patch in (D12_QUARANTINE,) + SCRATCH_LITERAL_PATCHES + ALLOCATOR_BODY_PATCHES + (ALLOCATOR_DISPATCH,):
        actual = transport.dump(patch.address, 4)
        if actual != patch.before:
            raise ValueError(
                f"temporary site {patch.name} is not stock: {actual.hex()}"
            )
    if u32(transport, SCRATCH_ADDRESS) != 0:
        raise ValueError("allocator scratch is not zero")
    if u32(transport, ALIGNED_ALLOC_LITERAL_ADDRESS) != ALIGNED_ALLOC_LITERAL:
        raise ValueError("aligned_alloc literal does not match reviewed F1 image")


def require_fixed_speaker(transport: AocFactoryDiag) -> None:
    if u32(transport, SPEAKER) != SPEAKER_VTABLE:
        raise ValueError("AudioHardwareSinkSpeaker vtable/object guard failed")
    raw = transport.dump(SPEAKER + 0x280, 0x54)
    words = struct.unpack("<" + "I" * (len(raw) // 4), raw)
    for offset, expected in FIXED_SPEAKER_FIELDS.items():
        actual = words[(offset - 0x280) // 4]
        if actual != expected:
            raise ValueError(
                f"speaker+0x{offset:x}=0x{actual:08x}, expected 0x{expected:08x}"
            )


def validate_allocation(transport: AocFactoryDiag, allocation: int) -> None:
    if allocation == 0 or allocation & 0x3F:
        raise ValueError(f"invalid/non-64-byte-aligned allocation 0x{allocation:08x}")
    if not HEAP_MINIMUM <= allocation <= HEAP_LIMIT - ALLOCATION_BYTES:
        raise ValueError(f"allocation is outside reviewed AoC heap range: 0x{allocation:08x}")
    transport.dump(allocation, 4)
    transport.dump(allocation + ALLOCATION_BYTES - 4, 4)


def require_zero_allocation(transport: AocFactoryDiag, allocation: int) -> None:
    """Refuse to publish uninitialized heap data into a live DMA path."""

    validate_allocation(transport, allocation)
    for offset in range(0, ALLOCATION_BYTES, ZERO_SCAN_CHUNK_BYTES):
        size = min(ZERO_SCAN_CHUNK_BYTES, ALLOCATION_BYTES - offset)
        data = transport.dump(allocation + offset, size)
        if any(data):
            first = next(index for index, byte in enumerate(data) if byte)
            raise ValueError(
                "new speaker allocation is not zero at "
                f"0x{allocation + offset + first:08x}"
            )


def validate_allocations(
    transport: AocFactoryDiag, cpu_allocation: int, dma_allocation: int
) -> None:
    validate_allocation(transport, cpu_allocation)
    if dma_allocation != cpu_allocation + DMA_TX_OFFSET:
        raise ValueError(
            f"DMA pair 0x{dma_allocation:08x} is not allocation+0x1800 "
            f"(0x{cpu_allocation + DMA_TX_OFFSET:08x})"
        )


def require_dma_ring_common(
    transport: AocFactoryDiag, ring: RingLayout
) -> tuple[int, tuple[int, ...]]:
    fixed = {
        0x00: RING_VTABLE,
        0x04: 0x28,
        0x14: 3,
        0x18: SPEAKER,
        0x3C: ring.metadata,
        0x44: ring.descriptor,
        0xE8: 0xFFFFFFFF,
        0xFC: 0xFFFFFFFF,
        0x108: 5,
        0x10C: 5,
        0x110: 4,
        0x114: 0x0000FFFF,
        0x170: 0xAC060040,
    }
    for offset, expected in fixed.items():
        actual = u32(transport, ring.address + offset)
        if actual != expected:
            raise ValueError(
                f"{ring.name}+0x{offset:x}=0x{actual:08x}, "
                f"expected 0x{expected:08x}"
            )
    expected_name = (ring.name + "\0").encode()
    actual_name = transport.dump(ring.address + 0x20, len(expected_name))
    if actual_name != expected_name:
        raise ValueError(f"{ring.name} object name/layout guard failed")
    readers = transport.dump(ring.address + 0x48, 0x54)
    if readers != bytes(len(readers)):
        raise ValueError(f"{ring.name} has an active/nonzero reader descriptor")
    descriptor = struct.unpack("<7I", transport.dump(ring.descriptor, 28))
    return u32(transport, ring.address + 0x40), descriptor


def require_dma_rings_stock(transport: AocFactoryDiag) -> None:
    expected_objects = (STOCK_TX_RING, STOCK_RX_RING)
    for address, expected in zip(
        (TX_RING_POINTER_ADDRESS, RX_RING_POINTER_ADDRESS),
        expected_objects,
        strict=True,
    ):
        if u32(transport, address) != expected:
            raise ValueError(f"speaker DMA RingBuffer pointer 0x{address:08x} changed")
    for ring in DMA_RINGS:
        backing, descriptor = require_dma_ring_common(transport, ring)
        if backing != ring.inline_backing:
            raise ValueError(
                f"{ring.name} no longer uses exact inline backing "
                f"0x{ring.inline_backing:08x}"
            )
        if (
            descriptor[:6]
            != (0, STOCK_BANK_BYTES, 0, STOCK_BANK_BYTES, 0, 0)
            or descriptor[6] == 0
        ):
            raise ValueError(
                f"{ring.name} is not an empty stock 0x600 RingBuffer: "
                + ",".join(f"0x{word:x}" for word in descriptor)
            )


def require_dma_rings_rebased(
    transport: AocFactoryDiag, dma_allocation: int
) -> None:
    for index, ring in enumerate(DMA_RINGS):
        backing, descriptor = require_dma_ring_common(transport, ring)
        expected_backing = dma_allocation + index * BANK_BYTES
        if backing != expected_backing:
            raise ValueError(
                f"{ring.name} backing 0x{backing:08x} != "
                f"0x{expected_backing:08x}"
            )
        if (
            descriptor[:6] != (0, BANK_BYTES, 0, BANK_BYTES, 0, 0)
            or descriptor[6] == 0
        ):
            raise ValueError(
                f"{ring.name} is not an empty rebased 0xc00 RingBuffer: "
                + ",".join(f"0x{word:x}" for word in descriptor)
            )


def require_stock_layout(transport: AocFactoryDiag) -> None:
    require_fixed_speaker(transport)
    expected = {
        TX_SIZE_ADDRESS: STOCK_BANK_BYTES,
        SOURCE_SIZE_ADDRESS: STOCK_BANK_BYTES,
        TX_POINTER_ADDRESS: STOCK_TX_POINTER,
        SOURCE_POINTER_ADDRESS: STOCK_SOURCE_POINTER,
    }
    for address, value in expected.items():
        actual = u32(transport, address)
        if actual != value:
            raise ValueError(
                f"stock speaker field 0x{address:08x}=0x{actual:08x}, "
                f"expected 0x{value:08x}"
            )
    require_dma_rings_stock(transport)


def require_rebased_layout(transport: AocFactoryDiag) -> tuple[int, int]:
    require_fixed_speaker(transport)
    for address in (TX_SIZE_ADDRESS, SOURCE_SIZE_ADDRESS):
        if u32(transport, address) != BANK_BYTES:
            raise ValueError(f"speaker bank size at 0x{address:08x} is not 0xc00")
    allocation = u32(transport, TX_POINTER_ADDRESS)
    source = u32(transport, SOURCE_POINTER_ADDRESS)
    validate_allocation(transport, allocation)
    if source != allocation + BANK_BYTES:
        raise ValueError(
            f"source bank 0x{source:08x} is not TX+0xc00 "
            f"(0x{allocation + BANK_BYTES:08x})"
        )
    dma_allocation = u32(transport, DMA_RINGS[0].address + 0x40)
    validate_allocations(transport, allocation, dma_allocation)
    require_dma_rings_rebased(transport, dma_allocation)
    return allocation, dma_allocation


def invoke_hd_mic_control(transport: AocFactoryDiag, purpose: str) -> None:
    result = transport.run(
        "shell",
        "su",
        "0",
        "sh",
        input_data='exec /system/bin/tinymix -D 0 -- "HD Mic gain (cB)" 0\n'.encode(),
        check=False,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError(
            f"{purpose} trigger exited {result.returncode}: "
            + result.stderr.decode(errors="replace").strip()
        )


def restore_temporary(
    transport: AocFactoryDiag, expected_generation: tuple[int, int]
) -> None:
    """Make the reused callback body unreachable, restore it, then reconnect."""

    require_generation(transport, expected_generation)
    dispatch = transport.dump(ALLOCATOR_DISPATCH.address, 4)
    if dispatch == ALLOCATOR_DISPATCH.after:
        checked_patch(transport, ALLOCATOR_DISPATCH, False)
    elif dispatch != ALLOCATOR_DISPATCH.before:
        raise RuntimeError(f"HD Mic dispatch changed unexpectedly: {dispatch.hex()}")

    callback = transport.dump(D12_QUARANTINE.address, 4)
    if callback == D12_QUARANTINE.before:
        # Restoring executable bytes while their original callback is reachable
        # would race D12; a caller must cold reboot from this inconsistent state.
        if any(
            transport.dump(patch.address, 4) == patch.after
            for patch in ALLOCATOR_BODY_PATCHES
        ):
            raise RuntimeError("allocator body is reachable through the D12 callback")
        return
    if callback != D12_QUARANTINE.after:
        raise RuntimeError(f"D12 callback quarantine changed: {callback.hex()}")

    body_changed = False
    for patch in reversed(ALLOCATOR_BODY_PATCHES):
        actual = transport.dump(patch.address, 4)
        if actual == patch.after:
            checked_patch(transport, patch, False)
            body_changed = True
        elif actual != patch.before:
            raise RuntimeError(f"allocator body word changed unexpectedly: {actual.hex()}")
    if body_changed:
        flush_instruction_cache(transport)
    for patch in reversed(SCRATCH_LITERAL_PATCHES):
        actual = transport.dump(patch.address, 4)
        if actual == patch.after:
            checked_patch(transport, patch, False)
        elif actual != patch.before:
            raise RuntimeError(f"allocator literal changed unexpectedly: {actual.hex()}")
    checked_patch(transport, D12_QUARANTINE, False)
    require_generation(transport, expected_generation)


def allocate(transport: AocFactoryDiag, expected_generation: tuple[int, int]) -> int:
    require_temporary_stock(transport)
    try:
        checked_patch(transport, D12_QUARANTINE, True)
        for patch in SCRATCH_LITERAL_PATCHES + ALLOCATOR_BODY_PATCHES:
            checked_patch(transport, patch, True)
        flush_instruction_cache(transport)
        require_generation(transport, expected_generation)
        checked_patch(transport, ALLOCATOR_DISPATCH, True)
        try:
            invoke_hd_mic_control(transport, "allocator")
        finally:
            # The allocator entry becomes unreachable before inspecting its
            # result or changing any executable byte.
            if transport.dump(ALLOCATOR_DISPATCH.address, 4) == ALLOCATOR_DISPATCH.after:
                checked_patch(transport, ALLOCATOR_DISPATCH, False)
        require_generation(transport, expected_generation)
        allocation = u32(transport, SCRATCH_ADDRESS)
        validate_allocation(transport, allocation)
    except BaseException:
        restore_temporary(transport, expected_generation)
        raise
    restore_temporary(transport, expected_generation)
    return allocation


def commit_rebase(
    transport: AocFactoryDiag, cpu_allocation: int, dma_allocation: int
) -> None:
    validate_allocations(transport, cpu_allocation, dma_allocation)
    # The route is quarantined by the caller.  Publish capacities before their
    # new pointers; any interrupted commit is reboot-only and remains blocked.
    checked_u32(transport, TX_SIZE_ADDRESS, STOCK_BANK_BYTES, BANK_BYTES, "TX bank capacity")
    checked_u32(transport, SOURCE_SIZE_ADDRESS, STOCK_BANK_BYTES, BANK_BYTES, "source bank capacity")
    for ring in DMA_RINGS:
        checked_u32(
            transport,
            ring.descriptor + 4,
            STOCK_BANK_BYTES,
            BANK_BYTES,
            f"{ring.name} descriptor end",
        )
        checked_u32(
            transport,
            ring.descriptor + 12,
            STOCK_BANK_BYTES,
            BANK_BYTES,
            f"{ring.name} descriptor size",
        )
    checked_u32(transport, TX_POINTER_ADDRESS, STOCK_TX_POINTER, cpu_allocation, "TX bank backing")
    checked_u32(
        transport,
        SOURCE_POINTER_ADDRESS,
        STOCK_SOURCE_POINTER,
        cpu_allocation + BANK_BYTES,
        "source bank backing",
    )
    for index, ring in enumerate(DMA_RINGS):
        checked_u32(
            transport,
            ring.address + 0x40,
            ring.inline_backing,
            dma_allocation + index * BANK_BYTES,
            f"{ring.name} backing",
        )


def require_all_pcm_idle(transport: AocFactoryDiag) -> None:
    users = adb_text(
        transport,
        "shell",
        "su 0 sh -c 'find /proc/[0-9]*/fd -type l -printf \"%p:%l\\n\" "
        "2>/dev/null | grep -E \":/dev/snd/pcmC0D[0-9]+[pc]$\" || true'",
    )
    if users:
        raise RuntimeError("an ALSA PCM is active:\n" + users)


def block_pcm_opens(transport: AocFactoryDiag) -> list[tuple[str, str]]:
    result = transport.run(
        "shell", "su 0 sh -c 'stat -c \"%a %n\" /dev/snd/pcmC0D*[pc]'"
    )
    entries: list[tuple[str, str]] = []
    for line in result.stdout.decode(errors="replace").splitlines():
        mode, path = line.split(maxsplit=1)
        if mode not in ("0", "660") or not path.startswith("/dev/snd/pcmC0D"):
            raise ValueError(f"unexpected PCM node inventory entry: {line}")
        entries.append((path, mode))
    if not entries:
        raise ValueError("card-0 PCM node inventory is empty")
    for path, _ in entries:
        transport.run("shell", "su", "0", "chmod", "000", path)
    for path, _ in entries:
        mode = adb_text(transport, "shell", "su", "0", "stat", "-c", "%a", path)
        if mode != "0":
            raise RuntimeError(f"failed to block new opens on {path}")
    require_all_pcm_idle(transport)
    print(f"blocked new opens on {len(entries)} card-0 PCM nodes")
    return entries


def restore_pcm_modes(
    transport: AocFactoryDiag, entries: list[tuple[str, str]]
) -> None:
    for path, mode in entries:
        transport.run("shell", "su", "0", "chmod", mode, path)
    print(f"restored modes on {len(entries)} card-0 PCM nodes")


def preflight(transport: AocFactoryDiag) -> None:
    if adb_text(transport, "get-state") != "device":
        raise RuntimeError("ADB target is not online")
    device = adb_text(transport, "shell", "getprop", "ro.product.device")
    build = adb_text(transport, "shell", "getprop", "ro.vendor.build.id")
    if (device, build) != (EXPECTED_DEVICE, EXPECTED_VENDOR_BUILD_ID):
        raise RuntimeError(f"refusing target {device!r}/{build!r}")
    if adb_text(transport, "shell", "getprop", "sys.boot_completed") != "1":
        raise RuntimeError("Frankel has not completed boot")
    if adb_text(transport, "shell", "su", "0", "id", "-u") != "0":
        raise RuntimeError("root shell is required")


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check-stock", "check-rebased", "apply"))
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    parser.add_argument(
        "--ack-reboot-only-rollback",
        action="store_true",
        help="required for the one-shot apply operation",
    )
    parser.add_argument(
        "--skip-zero-validation",
        action="store_true",
        help=(
            "skip the slow read-only scan of the fresh 0x3000-byte allocation; "
            "intended only for time-bounded hardware trials after a cold AoC boot"
        ),
    )
    args = parser.parse_args()
    if args.action == "apply" and not args.ack_reboot_only_rollback:
        parser.error("apply requires --ack-reboot-only-rollback")
    return args


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
    preflight(transport)
    initial_generation = generation(transport)
    require_all_pcm_idle(transport)
    require_temporary_stock(transport)
    if args.action == "check-stock":
        require_stock_layout(transport)
        require_generation(transport, initial_generation)
        print("exact stock speaker buffers and allocator prerequisites verified")
        return 0
    if args.action == "check-rebased":
        cpu_allocation, dma_allocation = require_rebased_layout(transport)
        require_generation(transport, initial_generation)
        print(
            f"verified CPU banks at 0x{cpu_allocation:08x}/"
            f"0x{cpu_allocation + BANK_BYTES:08x} and DMA rings at "
            f"0x{dma_allocation:08x}/0x{dma_allocation + BANK_BYTES:08x}"
        )
        return 0

    nodes = block_pcm_opens(transport)
    mutation_started = False
    try:
        require_stock_layout(transport)
        cpu_allocation = allocate(transport, initial_generation)
        if args.skip_zero_validation:
            print(
                "WARNING: trusting the freshly allocated 0x3000-byte speaker "
                "buffer without a zero-content scan"
            )
        else:
            require_zero_allocation(transport, cpu_allocation)
        dma_allocation = cpu_allocation + DMA_TX_OFFSET
        validate_allocations(transport, cpu_allocation, dma_allocation)
        require_stock_layout(transport)
        require_all_pcm_idle(transport)
        require_generation(transport, initial_generation)
        mutation_started = True
        commit_rebase(transport, cpu_allocation, dma_allocation)
        require_rebased_layout(transport)
        checked_u32(
            transport,
            SCRATCH_ADDRESS,
            cpu_allocation,
            0,
            "clear allocation scratch",
        )
        require_temporary_stock(transport)
        require_generation(transport, initial_generation)
    except BaseException:
        if not mutation_started:
            restore_pcm_modes(transport, nodes)
        else:
            print(
                "speaker object mutation began; PCM nodes remain blocked. "
                "Cold reboot before further audio use.",
                file=sys.stderr,
            )
        raise
    restore_pcm_modes(transport, nodes)
    print(
        f"committed CPU banks 0x{cpu_allocation:08x}/"
        f"0x{cpu_allocation + BANK_BYTES:08x} and DMA rings "
        f"0x{dma_allocation:08x}/0x{dma_allocation + BANK_BYTES:08x}; "
        "rollback requires a cold AoC reset"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
