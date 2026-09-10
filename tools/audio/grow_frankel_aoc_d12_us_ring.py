#!/usr/bin/env python3
"""Grow Frankel's D12 MIC_US ring from stock to eight half-periods.

The native MIC_DMA ring remains in its stock inline 0xc00-byte backing.  That
geometry is exact for one or two active 192 kHz PDM lanes; the endpoint
qualification routes deliberately select no more than two.  This one-shot
transition uses the single known-safe 0x3000-byte AoC heap allocation entirely
for MIC_US, then rebases that idle static ring under a disconnected D12 route.
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_d12_192k import require_d12_idle
from trigger_frankel_aoc_d12_ring_resize import (
    CAPACITY_CHECK_ADDRESS,
    CAPACITY_CHECK_STOCK,
    ROUTE_ADDRESS,
    ROUTE_FULL,
    ROUTE_STOCK,
    SCRATCH_ADDRESS,
    TEMPORARY_PATCHES,
    block_capture_opens,
    checked_u32,
    checked_write,
    pointer,
    require_all_capture_idle,
    require_full_profile,
    restore_capture_modes,
    ring_objects,
    validate_allocation,
)


CURRENT_RING_TOTAL = 0xC00
GROWN_US_TOTAL = 0x3000
CAPACITY_CHECK_GROWN = bytes.fromhex("3e0a31719081")
RING_VTABLE = 0x40359C38

# The repacker must be disconnected because its executable cave covers the
# allocator result word at 0x403f64a0.  The producer's original explicit-c00
# advance trampoline remains installed as part of the full foundation.
REPACKER_REVERTED = (
    (0x403E882D, bytes.fromhex("061737f02000")),
    (
        0x403F648D,
        bytes.fromhex("403490c2a600f0cc1128a2e00200c6e6c8" + "00" * 34),
    ),
    (0x403BACB8, bytes.fromhex("062bff")),
    (
        0x403BA962,
        bytes.fromhex("00" * 6 + "21e3fd862500" + "00" * 2),
    ),
)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action", choices=("arm", "commit", "check-full", "check-armed", "verify-grown")
    )
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    return parser.parse_args()


def temporary_states(transport: AocFactoryDiag) -> tuple[str, list[str], int]:
    route = transport.dump(ROUTE_ADDRESS, len(ROUTE_FULL))
    if route == ROUTE_FULL:
        route_state = "full"
    elif route == ROUTE_STOCK:
        route_state = "stock"
    else:
        raise ValueError(f"unexpected CMD 0x146 route bytes: {route.hex()}")
    states: list[str] = []
    for patch in TEMPORARY_PATCHES:
        actual = transport.dump(patch.address, len(patch.full))
        if actual == patch.full:
            state = "full"
        elif actual == patch.armed:
            state = "armed"
        else:
            raise ValueError(
                f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
                f"{actual.hex()}"
            )
        states.append(state)
        print(f"{state:5s} 0x{patch.address:08x} {patch.name}")
    scratch = struct.unpack("<I", transport.dump(SCRATCH_ADDRESS, 4))[0]
    print(f"{route_state:5s} 0x{ROUTE_ADDRESS:08x} CMD 0x146 route")
    print(f"scratch 0x{SCRATCH_ADDRESS:08x}=0x{scratch:08x}")
    return route_state, states, scratch


def require_repacker_reverted(
    transport: AocFactoryDiag, expected_scratch: int = 0
) -> None:
    for address, expected in REPACKER_REVERTED:
        if address == 0x403F648D:
            expected_mutable = bytearray(expected)
            scratch_offset = SCRATCH_ADDRESS - address
            expected_mutable[scratch_offset : scratch_offset + 4] = (
                expected_scratch.to_bytes(4, "little")
            )
            expected = bytes(expected_mutable)
        actual = transport.dump(address, len(expected))
        if actual != expected:
            raise ValueError(
                f"ring-8 repacker/advance is not in its allocation-safe state at "
                f"0x{address:08x}: {actual.hex()}"
            )
    print("verified allocation-safe reverted repacker and explicit-c00 foundation")


def ring_geometry(
    transport: AocFactoryDiag,
    expected_us_total: int,
    cursor_alignment: int = CURRENT_RING_TOTAL,
) -> list[tuple[str, int, int, int, tuple[int, ...]]]:
    result: list[tuple[str, int, int, int, tuple[int, ...]]] = []
    for name, ring in ring_objects(transport):
        vtable = struct.unpack("<I", transport.dump(ring, 4))[0]
        if vtable != RING_VTABLE:
            raise ValueError(f"{name} has unexpected vtable 0x{vtable:08x}")
        backing = pointer(transport, ring + 0x40, f"{name} backing")
        state = pointer(transport, ring + 0x44, f"{name} descriptor")
        if state != ring + 0x9C:
            raise ValueError(f"{name} descriptor 0x{state:08x} != object+0x9c")
        words = struct.unpack("<IIIIIII", transport.dump(state, 28))
        total = CURRENT_RING_TOTAL if name == "MIC_DMA_RING" else expected_us_total
        if words[1] != total or words[3] != total:
            raise ValueError(
                f"{name} end/size are not 0x{total:x}: "
                + ",".join(f"0x{word:x}" for word in words)
            )
        for cursor_name, cursor in (("write", words[0]), ("read", words[2])):
            if cursor % cursor_alignment or cursor >= total:
                raise ValueError(
                    f"{name} idle {cursor_name} cursor is not a "
                    f"0x{cursor_alignment:x}-byte boundary: 0x{cursor:x}"
                )
        if backing & 0x3F:
            raise ValueError(f"{name} backing is not 64-byte aligned")
        for reader_offset in (0x48, 0x58, 0x68, 0x78, 0x88):
            guard = struct.unpack(
                "<I", transport.dump(ring + reader_offset + 8, 4)
            )[0]
            if guard != 0xA5A5A500:
                raise ValueError(
                    f"{name} reader +0x{reader_offset:x} remains active or "
                    f"changed: 0x{guard:08x}"
                )
        result.append((name, ring, backing, state, words))
        print(
            f"{name}: backing=0x{backing:08x} total=0x{total:x} "
            f"write=0x{words[0]:x} read=0x{words[2]:x} "
            f"counter=0x{words[4]:x} generation=0x{words[6]:x}"
        )
    return result


def require_current_geometry(
    transport: AocFactoryDiag,
    cursor_alignment: int = CURRENT_RING_TOTAL,
) -> None:
    capacity = transport.dump(CAPACITY_CHECK_ADDRESS, len(CAPACITY_CHECK_STOCK))
    if capacity != CAPACITY_CHECK_STOCK:
        raise ValueError(
            "D12 setup is not coupled to the stock 0xc00 MIC_US ring: "
            + capacity.hex()
        )
    rings = ring_geometry(
        transport, CURRENT_RING_TOTAL, cursor_alignment=cursor_alignment
    )
    for name, ring, backing, _, _ in rings:
        if backing != ring + 0x178:
            raise ValueError(
                f"{name} no longer has its stock inline backing: "
                f"0x{backing:08x}"
            )
    print("verified exact stock inline MIC_DMA/MIC_US backings")


def reset_idle_current_ring_cursors(transport: AocFactoryDiag) -> None:
    """Flush retained stock half-period state under the disconnected route.

    A clean stock 96 kHz close may leave MIC_US at a 0x600-byte half-period
    boundary.  The native-192 profile consumes complete 0xc00-byte blocks, so
    arm starts both idle static rings at cursor zero after capture opens are
    blocked and CMD 0x146 is disconnected.  No payload is live at this point.
    """

    rings = ring_geometry(
        transport, CURRENT_RING_TOTAL, cursor_alignment=CURRENT_RING_TOTAL // 2
    )
    for name, _, _, state, words in rings:
        reset_cursor(transport, state, words[0], f"{name} idle write cursor")
        reset_cursor(
            transport, state + 8, words[2], f"{name} idle read cursor"
        )
    require_current_geometry(transport)


def verify_grown(transport: AocFactoryDiag) -> None:
    capacity = transport.dump(CAPACITY_CHECK_ADDRESS, len(CAPACITY_CHECK_GROWN))
    if capacity != CAPACITY_CHECK_GROWN:
        raise ValueError(
            "D12 setup is not coupled to the grown 0x3000 MIC_US ring: "
            + capacity.hex()
        )
    rings = ring_geometry(transport, GROWN_US_TOTAL)
    if rings[0][2] != rings[0][1] + 0x178:
        raise ValueError(
            "MIC_DMA no longer has its stock inline backing: "
            f"0x{rings[0][2]:08x}"
        )
    dma_start, dma_end = rings[0][2], rings[0][2] + CURRENT_RING_TOTAL
    us_start, us_end = rings[1][2], rings[1][2] + GROWN_US_TOTAL
    if max(dma_start, us_start) < min(dma_end, us_end):
        raise ValueError("MIC_DMA and grown MIC_US backings overlap")
    transport.dump(us_start, 4)
    transport.dump(us_end - 4, 4)
    print("verified inline MIC_DMA=0xc00 and independent MIC_US=0x3000 geometry")


def reset_cursor(
    transport: AocFactoryDiag, address: int, current: int, name: str
) -> None:
    if current == 0:
        return
    checked_u32(transport, address, current, 0, name)


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
    require_d12_idle(transport)
    require_all_capture_idle(transport)

    if args.action == "verify-grown":
        verify_grown(transport)
        return 0

    route_state, states, scratch = temporary_states(transport)
    wanted = "armed" if args.action == "check-armed" else "full"
    if args.action.startswith("check-"):
        if route_state != "full" or any(state != wanted for state in states):
            raise ValueError(f"US-ring allocator is not uniformly {wanted}")
        if wanted == "full" and scratch != 0:
            raise ValueError(f"full allocator retains scratch 0x{scratch:08x}")
        return 0

    if args.action == "arm":
        if route_state != "full" or any(state != "full" for state in states):
            raise ValueError("arm requires the uniformly full temporary code")
        if scratch != 0:
            raise ValueError(f"allocation scratch is not zero: 0x{scratch:08x}")
        require_full_profile(transport)
        require_repacker_reverted(transport)
        # Stock 96 kHz teardown is allowed to retain a 0x600-byte half-period;
        # it is flushed only after the route is made unreachable below.
        require_current_geometry(
            transport, cursor_alignment=CURRENT_RING_TOTAL // 2
        )
        capture_modes = block_capture_opens(transport)
        require_all_capture_idle(transport)
        checked_write(
            transport, ROUTE_ADDRESS, ROUTE_FULL, ROUTE_STOCK,
            "disconnect CMD 0x146 route",
        )
        reset_idle_current_ring_cursors(transport)
        for patch in TEMPORARY_PATCHES:
            checked_write(transport, patch.address, patch.full, patch.armed, patch.name)
        checked_write(
            transport, ROUTE_ADDRESS, ROUTE_STOCK, ROUTE_FULL,
            "activate US-ring allocator route",
        )
        restore_capture_modes(transport, capture_modes)
        print(
            "armed; run exactly one short ultrasound0/mask-1 D12 capture, "
            "stop it, then commit"
        )
        return 0

    if any(state != "armed" for state in states):
        raise ValueError("commit requires the uniformly armed allocator code")
    if scratch == 0:
        raise ValueError("allocator did not publish a result; reboot before retrying")

    capture_modes = block_capture_opens(transport)
    require_all_capture_idle(transport)
    if route_state == "full":
        checked_write(
            transport, ROUTE_ADDRESS, ROUTE_FULL, ROUTE_STOCK,
            "disconnect CMD 0x146 route",
        )
    require_repacker_reverted(transport, scratch)
    require_current_geometry(transport)
    validate_allocation(transport, scratch)

    rings = ring_geometry(transport, CURRENT_RING_TOTAL)
    _, us_ring, old_backing, us_state, us_words = rings[1]
    checked_u32(
        transport, us_ring + 0x40, old_backing, scratch,
        "MIC_US_RING independent backing",
    )
    reset_cursor(transport, us_state, us_words[0], "MIC_US_RING write cursor")
    reset_cursor(transport, us_state + 8, us_words[2], "MIC_US_RING read cursor")
    checked_u32(
        transport, us_state + 4, CURRENT_RING_TOTAL, GROWN_US_TOTAL,
        "MIC_US_RING end",
    )
    checked_u32(
        transport, us_state + 12, CURRENT_RING_TOTAL, GROWN_US_TOTAL,
        "MIC_US_RING size",
    )
    checked_write(
        transport,
        CAPACITY_CHECK_ADDRESS,
        CAPACITY_CHECK_STOCK,
        CAPACITY_CHECK_GROWN,
        "couple D12 setup to the grown MIC_US ring",
    )
    for patch in reversed(TEMPORARY_PATCHES):
        checked_write(transport, patch.address, patch.armed, patch.full, patch.name)
    checked_u32(transport, SCRATCH_ADDRESS, scratch, 0, "clear allocation scratch")
    verify_grown(transport)
    checked_write(
        transport, ROUTE_ADDRESS, ROUTE_STOCK, ROUTE_FULL,
        "restore full-profile CMD 0x146 route",
    )
    restore_capture_modes(transport, capture_modes)
    print(
        "committed independent 0x3000 MIC_US backing; MIC_DMA remains in its "
        "stock inline 0xc00 backing"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
