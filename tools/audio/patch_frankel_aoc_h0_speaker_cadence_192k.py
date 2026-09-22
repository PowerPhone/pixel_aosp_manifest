#!/usr/bin/env python3
"""Guarded reboot-volatile H0 cadence fix for Frankel q192 playback.

The q192 AMixSPKR object uses a 0xf00-byte internal block, while the stock
AudioMixerPlayback event callback invokes its worker only once per 48 kHz
source event. Redirect only the vtable worker entry to a 64-byte aligned code
cave. The wrapper calls the original worker four times for the q192 object and
once for every other mixer object.

This is tied to Frankel vendor build CP2A.260805.005. It writes the cave before
connecting the vtable and disconnects the vtable before erasing the cave.
All changes are volatile across an AoC/device reboot.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_speaker_192k import preflight


CAVE_ADDRESS = 0x40341000
CAVE_SIZE = 64
VTABLE_ADDRESS_POINT = 0x4027CFF4
WORKER_ENTRY_ADDRESS = VTABLE_ADDRESS_POINT + 0x50
ORIGINAL_WORKER = 0x403E8A8C
AMIX_SPKR = 0x405BE220
AMIX_BLOCK_BYTES_ADDRESS = AMIX_SPKR + 0x38C
Q192_BLOCK_BYTES = 0xF00

# Linked at 0x40341000 from asm/frankel_aoc_h0_speaker_cadence_192k.S.
CAVE_BODY = bytes.fromhex(
    "362100580252251552d5e552c57872d20372272362a780f0661167971262"
    "a004bd03ad02e005000b665636ff1df00000bd03ad02e005001df0"
)
CAVE_STOCK = bytes(CAVE_SIZE)
CAVE_PATCHED = CAVE_BODY.ljust(CAVE_SIZE, b"\0")
VTABLE_GUARDS = (
    (VTABLE_ADDRESS_POINT + 0x4C, 0x403EA388),
    (VTABLE_ADDRESS_POINT + 0x54, 0x403EA514),
    (VTABLE_ADDRESS_POINT + 0x58, 0x403E8EDC),
)


def integer(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "revert", "check-stock", "check-patched"))
    parser.add_argument("--adb", type=pathlib.Path, default=repository / "work/toolchains/platform-tools/adb")
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=integer)
    parser.add_argument("--allow-incomplete-boot", action="store_true")
    parser.add_argument("--allow-active-playback", action="store_true")
    return parser.parse_args()


def u32(data: bytes) -> int:
    if len(data) != 4:
        raise ValueError(f"u32 requires four bytes, got {len(data)}")
    return int.from_bytes(data, "little")


def snapshot(transport: AocFactoryDiag) -> tuple[bytes, int]:
    return (
        transport.dump(CAVE_ADDRESS, CAVE_SIZE),
        u32(transport.dump(WORKER_ENTRY_ADDRESS, 4)),
    )


def classify(cave: bytes, worker: int) -> str:
    if cave == CAVE_STOCK and worker == ORIGINAL_WORKER:
        return "stock"
    if cave == CAVE_PATCHED and worker == CAVE_ADDRESS:
        return "patched"
    raise ValueError(
        f"unsafe mixed/unknown H0 cadence state: cave={cave.hex()}, worker=0x{worker:08x}"
    )


def require_static_guards(transport: AocFactoryDiag) -> None:
    vptr = u32(transport.dump(AMIX_SPKR, 4))
    if vptr != VTABLE_ADDRESS_POINT:
        raise ValueError(
            f"unexpected AMixSPKR vptr 0x{vptr:08x}; expected 0x{VTABLE_ADDRESS_POINT:08x}"
        )
    for address, expected in VTABLE_GUARDS:
        actual = u32(transport.dump(address, 4))
        if actual != expected:
            raise ValueError(
                f"vtable guard mismatch at 0x{address:08x}: got 0x{actual:08x}, expected 0x{expected:08x}"
            )


def write_word(transport: AocFactoryDiag, address: int, value: int) -> None:
    transport.write_unverified(address, value, 32)


def write_cave(transport: AocFactoryDiag, source: bytes, destination: bytes) -> None:
    current = transport.dump(CAVE_ADDRESS, CAVE_SIZE)
    if current == destination:
        return
    if current != source:
        raise ValueError(f"cave changed before write: {current.hex()}")
    for offset in range(0, CAVE_SIZE, 4):
        before = source[offset : offset + 4]
        after = destination[offset : offset + 4]
        if before != after:
            write_word(
                transport,
                CAVE_ADDRESS + offset,
                int.from_bytes(after, "little"),
            )
    actual = transport.dump(CAVE_ADDRESS, CAVE_SIZE)
    if actual != destination:
        raise RuntimeError(
            f"cave verification failed: got {actual.hex()}, expected {destination.hex()}"
        )


def write_worker(transport: AocFactoryDiag, source: int, destination: int) -> None:
    current = u32(transport.dump(WORKER_ENTRY_ADDRESS, 4))
    if current == destination:
        return
    if current != source:
        raise ValueError(
            f"worker changed before write: got 0x{current:08x}, expected 0x{source:08x}"
        )
    write_word(transport, WORKER_ENTRY_ADDRESS, destination)
    actual = u32(transport.dump(WORKER_ENTRY_ADDRESS, 4))
    if actual != destination:
        raise RuntimeError(
            f"worker verification failed: got 0x{actual:08x}, expected 0x{destination:08x}"
        )


def main() -> int:
    args = parse_args()
    transport = AocFactoryDiag(
        argparse.Namespace(
            adb=args.adb,
            adb_server_port=args.adb_server_port,
            serial=args.serial,
            core=3,
            counter=args.counter,
        )
    )
    preflight(
        transport,
        args.allow_active_playback,
        args.allow_incomplete_boot,
        "/proc/asound/card0/pcm5p/sub0/status",
    )
    require_static_guards(transport)
    cave, worker = snapshot(transport)
    state = classify(cave, worker)
    print(
        f"{state}: H0 cave=0x{CAVE_ADDRESS:08x}+0x{CAVE_SIZE:x}, "
        f"worker[+0x50]=0x{worker:08x}"
    )

    if args.action.startswith("check-"):
        wanted = args.action.removeprefix("check-")
        if state != wanted:
            raise ValueError(f"H0 cadence overlay is {state}, expected {wanted}")
        return 0

    if args.action == "apply":
        block_bytes = u32(transport.dump(AMIX_BLOCK_BYTES_ADDRESS, 4))
        if block_bytes != Q192_BLOCK_BYTES:
            raise ValueError(
                f"AMixSPKR block geometry is 0x{block_bytes:x}, expected q192 0x{Q192_BLOCK_BYTES:x}"
            )
        if state == "stock":
            write_cave(transport, CAVE_STOCK, CAVE_PATCHED)
            write_worker(transport, ORIGINAL_WORKER, CAVE_ADDRESS)
    elif state == "patched":
        write_worker(transport, CAVE_ADDRESS, ORIGINAL_WORKER)
        write_cave(transport, CAVE_PATCHED, CAVE_STOCK)

    cave, worker = snapshot(transport)
    wanted = "patched" if args.action == "apply" else "stock"
    actual = classify(cave, worker)
    if actual != wanted:
        raise RuntimeError(f"postflight is {actual}, expected {wanted}")
    print(f"verified H0 cadence overlay {wanted}; changes disappear on AoC/device reboot")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
