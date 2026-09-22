#!/usr/bin/env python3
"""Balance the Frankel two-S32-slot speaker PL330 TX memory/FIFO bursts.

The current two-slot profile generates TX CCR 0x00054009: each DMALD loads
16 bytes but each DMAST drains only eight bytes. Change the source-width
exponent from four to three so TX CCR becomes 0x00054007, one eight-byte
memory beat to two four-byte peripheral beats. RX already balances eight
bytes on both sides and is unchanged. Close D5 and stop audio services first.
The next D5 open regenerates descriptors using the corrected instruction.
"""
from __future__ import annotations

import argparse
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_speaker_192k import (
    Patch, classify, flush_instruction_cache_minimal, preflight,
)

SPEAKER = 0x4051B0B8
PATCH = Patch(
    "two-slot TX DMA memory burst width 16 -> 8 bytes", 0x403AA510,
    bytes.fromhex("a1130081"), bytes.fromhex("a10f0081"), "hook",
)
GUARDS = (
    (0x403AA4C8, bytes.fromhex("27073f86"), "two-slot DMA guard"),
    (0x403AA4FC, bytes.fromhex("be31bfc5"), "two-slot DMA grouping"),
    (0x403AA520, bytes.fromhex("f9213911"), "32-bit TX peripheral width"),
    (0x403AA534, bytes.fromhex("726100a5"), "TX burst length follows enabled slots"),
    (0x403D4150, bytes.fromhex("5223a688"), "DMA frame count follows speaker geometry"),
    (0x403AAAF0, bytes.fromhex("5e93a913"), "TX descriptor byte count uses S32 slots"),
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "revert", "check-stock", "check-patched"))
    parser.add_argument("--adb", type=pathlib.Path, default=pathlib.Path("/usr/bin/adb"))
    parser.add_argument("--adb-server-port", type=int, default=5037)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    args = parser.parse_args()
    args.core = 2
    transport = AocFactoryDiag(args)
    transport.run("shell", "/vendor/bin/frankel_aoc_speaker_patch", "check-playback-closed")
    # This kernel removes sub0/status when idle; the native fd scan above
    # establishes closure before this shared build/transport preflight.
    preflight(transport, True, False, "/proc/asound/card0/pcm5p/sub0/status")
    for service in ("audioserver", "vendor.audio-hal-powerphone", "vendor.audio-hal-aidl"):
        state = transport.run("shell", "getprop", f"init.svc.{service}").stdout.decode().strip()
        if state != "stopped":
            raise ValueError(f"{service} must be stopped; got {state!r}")
    for offset, expected in ((0, 0x40275D00), (0x28C, 2), (0x298, 192), (0x2A8, 0x600)):
        actual = int.from_bytes(transport.dump(SPEAKER + offset, 4), "little")
        if actual != expected:
            raise ValueError(f"speaker+0x{offset:x}: got 0x{actual:x}, expected 0x{expected:x}")
    for address, expected, label in GUARDS:
        actual = transport.dump(address, 4)
        if actual != expected:
            raise ValueError(f"{label} at 0x{address:x}: got {actual.hex()}, expected {expected.hex()}")
    actual = transport.dump(PATCH.address, 4)
    state = classify(actual, PATCH)
    print(f"TX DMA source-width instruction is {state}: 0x{PATCH.address:08x} {actual.hex()}")
    if args.action.startswith("check-"):
        if state != args.action.removeprefix("check-"):
            raise ValueError(f"unexpected {state} state")
        return 0
    destination = PATCH.after if args.action == "apply" else PATCH.before
    if actual != destination:
        transport.write_unverified(PATCH.address, int.from_bytes(destination, "little"), 32)
        readback = transport.dump(PATCH.address, 4)
        if readback != destination:
            raise RuntimeError(f"write did not reach 0x{PATCH.address:x}: {readback.hex()}")
    flush_instruction_cache_minimal(transport)
    print("TX DMA source width " + ("8 bytes; expect CCR 0x00054007" if args.action == "apply" else "16 bytes; expect CCR 0x00054009"))
    print("Reopen D5 to regenerate its DMA program. This change disappears on AoC/device reboot.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
