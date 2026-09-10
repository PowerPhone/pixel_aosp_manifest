#!/usr/bin/env python3
"""Legacy allocator for the superseded dual-0x1800 Frankel D12 layout.

``arm`` installs a one-shot allocator in an otherwise dead callback body.
Open and close exactly one sacrificial D12 capture, then run ``commit``.
Commit disconnects the D12 command route, validates that every capture PCM and
both rings are idle, directly rebases the two RingBufferStatic objects, restores
the temporary code, proves the resulting geometry, and only then reconnects
the normal 192 kHz route.  Any failed commit leaves that route disconnected;
reboot the device instead of trying to continue from a partial state.

New work must use grow_frankel_aoc_d12_us_ring.py, which retains the safe
inline DMA ring for one/two-lane endpoint routes and spends the allocation on
the deeper MIC_US queue.  Mutating legacy actions require an explicit opt-in.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import struct
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_d12_192k import (
    PATCHES,
    PROFILE_EXCLUDED_ADDRESSES,
    require_d12_idle,
)


ROUTE_ADDRESS = 0x4038FB56
ROUTE_STOCK = bytes.fromhex("b2224e")
ROUTE_FULL = bytes.fromhex("86f6ff")
SCRATCH_ADDRESS = 0x403F64A0
RING_TOTAL = 0x1800
ALLOCATION_SIZE = RING_TOTAL * 2
CAPACITY_CHECK_ADDRESS = 0x403E8400
CAPACITY_CHECK_STOCK = bytes.fromhex("3e0a314d9081")
CAPACITY_CHECK_RESIZED = bytes.fromhex("3e0a31599081")


@dataclasses.dataclass(frozen=True)
class TemporaryPatch:
    name: str
    address: int
    full: bytes
    armed: bytes


TEMPORARY_PATCHES = (
    TemporaryPatch(
        "install allocation result address and P192 marker",
        0x403E7814,
        bytes.fromhex("00" * 8),
        bytes.fromhex("a0643f4032393150"),
    ),
    TemporaryPatch(
        "install one-shot aligned allocation body in the dead callback",
        0x403E87D0,
        bytes.fromhex(
            "3641005e030848ddc81df000bd04e501"
            "001df000000000000000000000000000"
        ),
        bytes.fromhex(
            "36410032224e0c7662437c4c0a3c0b80"
            "bb1181136ee00800410bfca9041df000"
        ),
    ),
    TemporaryPatch(
        "invoke the allocator once from CMD 0x146",
        0x4038FB34,
        bytes.fromhex("b2224e0c75524b7c46060000"),
        bytes.fromhex("ad02a5c95806070000000000"),
    ),
)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=("arm", "commit", "check-full", "check-armed", "verify-resized"),
    )
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    parser.add_argument(
        "--ack-superseded-dual-ring",
        action="store_true",
        help="permit the legacy arm/commit actions (not used by the current workflow)",
    )
    return parser.parse_args()


def classify(actual: bytes, full: bytes, armed: bytes, name: str) -> str:
    if actual == full:
        return "full"
    if actual == armed:
        return "armed"
    raise ValueError(
        f"{name}: unexpected bytes {actual.hex()} "
        f"(full {full.hex()}, armed {armed.hex()})"
    )


def write_changed_chunks(
    transport: AocFactoryDiag, address: int, source: bytes, destination: bytes
) -> None:
    offset = 0
    while offset < len(source):
        current_address = address + offset
        remaining = len(source) - offset
        width = next(
            candidate
            for candidate in (4, 2, 1)
            if remaining >= candidate and current_address % candidate == 0
        )
        old = source[offset : offset + width]
        new = destination[offset : offset + width]
        if old != new:
            transport.write(
                current_address, int.from_bytes(new, "little"), width * 8
            )
            print(
                f"write{width * 8:<2d} 0x{current_address:08x} "
                f"{old.hex()}->{new.hex()}"
            )
        offset += width


def checked_write(
    transport: AocFactoryDiag,
    address: int,
    source: bytes,
    destination: bytes,
    name: str,
) -> None:
    actual = transport.dump(address, len(source))
    if actual == destination:
        return
    if actual != source:
        raise ValueError(
            f"{name}: changed before write at 0x{address:08x}: {actual.hex()}"
        )
    write_changed_chunks(transport, address, source, destination)
    actual = transport.dump(address, len(destination))
    if actual != destination:
        raise RuntimeError(
            f"{name}: verification failed at 0x{address:08x}: {actual.hex()}"
        )


def checked_u32(
    transport: AocFactoryDiag, address: int, expected: int, value: int, name: str
) -> None:
    actual = struct.unpack("<I", transport.dump(address, 4))[0]
    if actual != expected:
        raise ValueError(
            f"{name}: 0x{address:08x}=0x{actual:08x}, expected 0x{expected:08x}"
        )
    transport.write(address, value, 32)
    actual = struct.unpack("<I", transport.dump(address, 4))[0]
    if actual != value:
        raise RuntimeError(
            f"{name}: 0x{address:08x}=0x{actual:08x} after write, "
            f"expected 0x{value:08x}"
        )
    print(f"write32 0x{address:08x} 0x{expected:08x}->0x{value:08x}  {name}")


def read_states(transport: AocFactoryDiag) -> tuple[str, list[str], int, str]:
    route = transport.dump(ROUTE_ADDRESS, len(ROUTE_FULL))
    route_state = classify(route, ROUTE_FULL, ROUTE_STOCK, "CMD 0x146 route")
    print(f"{route_state:5s} 0x{ROUTE_ADDRESS:08x} {route.hex()}  CMD 0x146 route")
    states: list[str] = []
    for patch in TEMPORARY_PATCHES:
        actual = transport.dump(patch.address, len(patch.full))
        state = classify(actual, patch.full, patch.armed, patch.name)
        states.append(state)
        print(f"{state:5s} 0x{patch.address:08x} {actual.hex()}  {patch.name}")
    scratch = struct.unpack("<I", transport.dump(SCRATCH_ADDRESS, 4))[0]
    print(f"scratch 0x{SCRATCH_ADDRESS:08x} 0x{scratch:08x}")
    capacity = transport.dump(CAPACITY_CHECK_ADDRESS, len(CAPACITY_CHECK_STOCK))
    capacity_state = classify(
        capacity,
        CAPACITY_CHECK_STOCK,
        CAPACITY_CHECK_RESIZED,
        "ultrasonic ring-capacity assertion",
    )
    capacity_label = "stock" if capacity_state == "full" else "resized"
    print(
        f"{capacity_label:7s} 0x{CAPACITY_CHECK_ADDRESS:08x} "
        f"{capacity.hex()}  ultrasonic ring-capacity assertion"
    )
    return route_state, states, scratch, capacity_label


def pointer(transport: AocFactoryDiag, address: int, name: str) -> int:
    value = struct.unpack("<I", transport.dump(address, 4))[0]
    if not 0x40000000 <= value < 0x42000000 or value & 3:
        raise ValueError(f"{name} is not an aligned AoC pointer: 0x{value:08x}")
    return value


def ring_objects(transport: AocFactoryDiag) -> list[tuple[str, int]]:
    # This address is exact for the qualified CP2A.260805.005 F1 image.  A
    # persistent certifier must first discover it with the guarded pointer
    # probe instead of carrying this boot-build-specific value forward.
    controller = 0x4054AA58
    pdm = pointer(transport, controller + 0x1F0, "PDM processor")
    return [
        (name, pointer(transport, pdm + slot, name))
        for name, slot in (("MIC_DMA_RING", 0x150), ("MIC_US_RING", 0x15C))
    ]


def require_all_capture_idle(transport: AocFactoryDiag) -> None:
    command = (
        "su 0 sh -c 'find /proc/[0-9]*/fd -type l "
        "-printf \"%p:%l\\\\n\" 2>/dev/null | "
        "grep -E \":/dev/snd/pcmC0D[0-9]+c$\" || true'"
    )
    users = transport.run("shell", command).stdout.decode(errors="replace").strip()
    if users:
        raise RuntimeError("an AoC capture PCM is active:\n" + users)


def block_capture_opens(transport: AocFactoryDiag) -> list[tuple[str, str]]:
    result = transport.run(
        "shell",
        "su 0 sh -c 'stat -c \"%a %n\" /dev/snd/pcmC0D*c'",
    )
    entries: list[tuple[str, str]] = []
    for line in result.stdout.decode(errors="replace").splitlines():
        mode, path = line.split(maxsplit=1)
        if not path.startswith("/dev/snd/pcmC0D") or not path.endswith("c"):
            raise ValueError(f"unexpected capture node from stat: {line}")
        if mode not in ("0", "660"):
            raise ValueError(f"unexpected capture node mode in {line}")
        # Mode 0 is the intentional fail-closed state left by an interrupted
        # earlier commit.  All qualified Frankel card-0 capture nodes have
        # normal uevent mode 0660, which is restored only after full success.
        entries.append((path, "660"))
    if not entries or "/dev/snd/pcmC0D12c" not in {path for path, _ in entries}:
        raise ValueError("card-0 capture node inventory is incomplete")
    for path, _ in entries:
        transport.run("shell", "su", "0", "chmod", "000", path)
    for path, _ in entries:
        mode = transport.run("shell", "su", "0", "stat", "-c", "%a", path)
        if mode.stdout.decode(errors="replace").strip() != "0":
            raise RuntimeError(f"failed to block new opens on {path}")
    print(f"blocked new opens on {len(entries)} card-0 capture PCM nodes")
    return entries


def restore_capture_modes(
    transport: AocFactoryDiag, entries: list[tuple[str, str]]
) -> None:
    for path, mode in entries:
        transport.run("shell", "su", "0", "chmod", mode, path)
    print(f"restored modes on {len(entries)} card-0 capture PCM nodes")


def require_full_profile(transport: AocFactoryDiag) -> None:
    excluded = PROFILE_EXCLUDED_ADDRESSES["full"]
    for patch in PATCHES:
        if patch.address in excluded:
            continue
        actual = transport.dump(patch.address, len(patch.after))
        if actual != patch.after:
            raise ValueError(
                f"full-profile prerequisite {patch.name} is not patched at "
                f"0x{patch.address:08x}: {actual.hex()}"
            )
    print("all full-profile code and callback prerequisites verified")


def require_rebase_preconditions(transport: AocFactoryDiag) -> None:
    require_all_capture_idle(transport)
    for name, ring in ring_objects(transport):
        vtable = struct.unpack("<I", transport.dump(ring, 4))[0]
        if vtable != 0x40359C38:
            raise ValueError(f"{name} is not the expected RingBufferStatic: 0x{vtable:08x}")
        backing = pointer(transport, ring + 0x40, f"{name} backing")
        if backing != ring + 0x178:
            raise ValueError(
                f"{name} no longer has its exact stock inline backing: 0x{backing:08x}"
            )
        state = pointer(transport, ring + 0x44, f"{name} descriptor")
        if state != ring + 0x9C:
            raise ValueError(f"{name} has unexpected descriptor pointer 0x{state:08x}")
        words = struct.unpack("<IIIII", transport.dump(state, 20))
        if words[:4] != (0, 0xC00, 0, 0xC00):
            raise ValueError(
                f"{name} is not an empty stock 0xc00 ring: "
                + ",".join(f"0x{word:x}" for word in words)
            )
        sentinel = struct.unpack("<I", transport.dump(state + 0x14, 4))[0]
        generation = struct.unpack("<I", transport.dump(state + 0x18, 4))[0]
        if sentinel != 0xA5A5A5A5:
            raise ValueError(
                f"{name} descriptor sentinel changed: 0x{sentinel:08x}"
            )
        for base in (0x48, 0x58, 0x68, 0x78, 0x88):
            # Unregister only clears the low active byte; the position fields
            # may legitimately retain the just-closed reader's last snapshot
            # and are overwritten on its next acquisition.
            guard = struct.unpack("<I", transport.dump(ring + base + 8, 4))[0]
            if guard != 0xA5A5A500:
                raise ValueError(
                    f"{name} reader descriptor +0x{base:x} is active or its "
                    f"poison changed: 0x{guard:08x}"
                )
        print(
            f"{name}: exact idle RingBufferStatic rebase preconditions verified "
            f"(byte_counter=0x{words[4]:x}, generation=0x{generation:x} preserved)"
        )


def validate_allocation(transport: AocFactoryDiag, allocation: int) -> None:
    if allocation & 0x3F:
        raise ValueError(f"allocation is not 64-byte aligned: 0x{allocation:08x}")
    # On this image the general F1 heap follows the two 0xd80-byte static ring
    # objects inside the 0x405... data arena; it is not in a separate 0x410...
    # mapping.  Derive the lower bound from those guarded live objects instead
    # of imposing an unrelated address-region guess.
    minimum = max(ring + 0xD80 for _, ring in ring_objects(transport))
    if not minimum <= allocation <= 0x42000000 - ALLOCATION_SIZE:
        raise ValueError(f"allocation is outside AoC data/heap space: 0x{allocation:08x}")
    # Prove both ends are readable before installing either backing pointer.
    transport.dump(allocation, 4)
    transport.dump(allocation + ALLOCATION_SIZE - 4, 4)
    print(
        f"validated readable aligned allocation 0x{allocation:08x}.."
        f"0x{allocation + ALLOCATION_SIZE - 1:08x}"
    )


def commit_rebase(transport: AocFactoryDiag, allocation: int) -> None:
    for index, (name, ring) in enumerate(ring_objects(transport)):
        backing = allocation + index * RING_TOTAL
        state = pointer(transport, ring + 0x44, f"{name} descriptor")
        checked_u32(transport, ring + 0x40, ring + 0x178, backing, f"{name} backing")
        checked_u32(transport, state + 4, 0xC00, RING_TOTAL, f"{name} end")
        checked_u32(transport, state + 12, 0xC00, RING_TOTAL, f"{name} size")


def verify_resized(transport: AocFactoryDiag) -> None:
    capacity = transport.dump(CAPACITY_CHECK_ADDRESS, len(CAPACITY_CHECK_RESIZED))
    if capacity != CAPACITY_CHECK_RESIZED:
        raise ValueError(
            "ultrasonic capacity assertion is not coupled to the 0x1800 ring: "
            + capacity.hex()
        )
    rings: list[tuple[str, int, int, tuple[int, ...]]] = []
    for name, ring in ring_objects(transport):
        vtable = struct.unpack("<I", transport.dump(ring, 4))[0]
        if vtable != 0x40359C38:
            raise ValueError(f"{name} has unexpected vtable 0x{vtable:08x}")
        backing = pointer(transport, ring + 0x40, f"{name} backing")
        state = pointer(transport, ring + 0x44, f"{name} descriptor")
        if state != ring + 0x9C:
            raise ValueError(f"{name} descriptor 0x{state:08x} != object+0x9c")
        words = struct.unpack("<IIIII", transport.dump(state, 20))
        if words[:4] != (0, RING_TOTAL, 0, RING_TOTAL):
            raise ValueError(
                f"{name} is not an empty 0x1800 ring: "
                + ",".join(f"0x{word:x}" for word in words)
            )
        if backing & 0x3F:
            raise ValueError(f"{name} backing is not 64-byte aligned")
        rings.append((name, ring, backing, words))
    if rings[1][2] != rings[0][2] + RING_TOTAL:
        raise ValueError("resized ring backings are not contiguous 0x1800-byte halves")
    validate_allocation(transport, rings[0][2])
    for name, ring, backing, words in rings:
        print(
            f"{name}: object=0x{ring:08x} backing=0x{backing:08x} descriptor="
            + ",".join(f"0x{word:x}" for word in words)
        )
    print("verified both native D12 RingBufferStatic objects at 0x1800 bytes")


def main() -> int:
    args = parse_args()
    if args.action in ("arm", "commit") and not args.ack_superseded_dual_ring:
        raise ValueError(
            "the dual-0x1800 allocator is superseded; use "
            "grow_frankel_aoc_d12_us_ring.py"
        )
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
    if args.action == "verify-resized":
        verify_resized(transport)
        return 0

    route_state, states, scratch, capacity_state = read_states(transport)
    wanted = "armed" if args.action == "check-armed" else "full"
    if args.action.startswith("check-"):
        if route_state != "full" or any(state != wanted for state in states):
            raise ValueError(f"allocator trigger is not uniformly {wanted}")
        if wanted == "full" and scratch != 0:
            raise ValueError(f"full trigger state retains scratch 0x{scratch:08x}")
        return 0

    if args.action == "arm":
        if route_state != "full" or any(state != "full" for state in states):
            raise ValueError("arm requires the uniformly full D12 profile")
        if scratch != 0:
            raise ValueError(f"allocation scratch is not zero: 0x{scratch:08x}")
        if capacity_state != "stock":
            raise ValueError("arm requires the stock 0xc00 capacity assertion")
        require_full_profile(transport)
        require_rebase_preconditions(transport)
        checked_write(
            transport, ROUTE_ADDRESS, ROUTE_FULL, ROUTE_STOCK, "disconnect CMD 0x146 route"
        )
        for patch in TEMPORARY_PATCHES:
            checked_write(transport, patch.address, patch.full, patch.armed, patch.name)
        checked_write(
            transport, ROUTE_ADDRESS, ROUTE_STOCK, ROUTE_FULL, "activate allocator route"
        )
        print("armed; run exactly one sacrificial D12 capture, stop it, then commit")
        return 0

    # Make the temporary command body unreachable before inspecting or changing
    # its result.  Every exception below deliberately leaves the route at stock.
    if route_state not in ("full", "armed") or any(
        state != "armed" for state in states
    ):
        raise ValueError("commit requires the uniformly armed allocator trigger")
    if capacity_state != "stock":
        raise ValueError("commit requires the still-stock 0xc00 capacity assertion")
    if route_state == "full":
        checked_write(
            transport,
            ROUTE_ADDRESS,
            ROUTE_FULL,
            ROUTE_STOCK,
            "disconnect CMD 0x146 route",
        )
    else:
        print("CMD 0x146 custom route is already disconnected from a failed commit")
    capture_modes = block_capture_opens(transport)
    require_all_capture_idle(transport)
    if scratch == 0:
        raise ValueError("allocator did not publish a result; reboot before retrying")
    validate_allocation(transport, scratch)
    require_rebase_preconditions(transport)
    commit_rebase(transport, scratch)
    checked_write(
        transport,
        CAPACITY_CHECK_ADDRESS,
        CAPACITY_CHECK_STOCK,
        CAPACITY_CHECK_RESIZED,
        "couple the setup assertion to the resized ultrasonic ring",
    )
    for patch in reversed(TEMPORARY_PATCHES):
        checked_write(transport, patch.address, patch.armed, patch.full, patch.name)
    checked_u32(transport, SCRATCH_ADDRESS, scratch, 0, "clear allocation scratch")
    verify_resized(transport)
    checked_write(
        transport, ROUTE_ADDRESS, ROUTE_STOCK, ROUTE_FULL, "restore full-profile CMD 0x146 route"
    )
    restore_capture_modes(transport, capture_modes)
    print("committed and verified the normal full D12 profile with resized static rings")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
