#!/usr/bin/env python3
"""Reboot-volatile, guarded F1 source5/sink0 q192 period1 experiment.

Requires the current source5 native-q192 speaker profile and its H0 enum7
period1 geometry hook. Stop audioserver and both audio HALs before applying;
the script enforces D5 closed. Reopen the route after applying. Reboot is the
clean rollback because Configure may retain runtime mixer state.

The patch makes source5/sink0 select a one-millisecond H0 Configure period,
and teaches both F1 scheduling/accounting comparisons that this native-q192
speaker's block is0x600 bytes. Other sinks, rates, and source bitmaps retain
the original0x180 comparisons. No microphone or amplifier settings change.

Assembly: asm/frankel_aoc_speaker_period1_candidate.{S,ld}.
This is an experimental overlay, not part of the canonical boot profile.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_speaker_192k import (
    flush_instruction_cache_minimal,
    preflight,
)


@dataclass(frozen=True)
class Region:
    name: str
    address: int
    before: bytes
    after: bytes


EXPECTED_CAVE = bytes.fromhex(
    "5e15b0022c8156130192d40392098a6679089224da57690282a600c6566d"
)
ACCOUNT_CAVE = bytes.fromhex(
    "8e05a4020c81b831561b01b2d303b20b8a667b08b223da576b0292a60086786d"
)
REGIONS = (
    Region(
        "scoped cadence comparison caves",
        0x40371500,
        bytes(128),
        EXPECTED_CAVE.ljust(64, b"\0") + ACCOUNT_CAVE.ljust(64, b"\0"),
    ),
    Region(
        "source5/sink0 one-millisecond mode",
        0x4039D520,
        bytes.fromhex("6b8214327223da2841ccb20c5257670462a0c00c7222448a8645b90000000000"),
        bytes.fromhex("6b8214327223da2841dc020c5257670962a0c00c122244880c7222448a4644b9"),
    ),
    Region(
        "scoped expected-block hook and adjacent bytes",
        0x4038CA74,
        bytes.fromhex("5e15b0022c81defb"),
        bytes.fromhex("06a292f02000defb"),
    ),
    Region(
        "scoped accounting-block hook and adjacent bytes",
        0x4038CB3C,
        bytes.fromhex("008e05a4020c813f"),
        bytes.fromhex("00c67f92f020003f"),
    ),
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "revert", "check-base", "check-patched"))
    parser.add_argument("--adb", type=Path, default=Path("/usr/bin/adb"))
    parser.add_argument("--adb-server-port", type=int, default=5037)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    parser.add_argument("--allow-incomplete-boot", action="store_true")
    return parser.parse_args()


def read_regions(transport: AocFactoryDiag) -> dict[int, bytes]:
    return {region.address: transport.dump(region.address, len(region.before)) for region in REGIONS}


def state(regions: dict[int, bytes]) -> str:
    if all(regions[region.address] == region.before for region in REGIONS):
        return "base"
    if all(regions[region.address] == region.after for region in REGIONS):
        return "patched"
    details = "; ".join(
        f"0x{region.address:08x}={regions[region.address].hex()}" for region in REGIONS
    )
    raise RuntimeError(f"mixed or unknown period1 overlay; reboot to restore base: {details}")


def main() -> None:
    args = arguments()
    transport = AocFactoryDiag(argparse.Namespace(
        adb=args.adb, adb_server_port=args.adb_server_port, serial=args.serial,
        counter=args.counter, core=2,
    ))
    transport.run("shell", "/vendor/bin/frankel_aoc_speaker_patch", "check-playback-closed")
    preflight(transport, True, args.allow_incomplete_boot, "/proc/asound/card0/pcm5p/sub0/status")
    if transport.dump(0x4039D540, 4) != bytes.fromhex("48470041"):
        raise RuntimeError("unexpected literal after the source5 q192 cave")
    current = state(read_regions(transport))
    print(f"source5/sink0 period1 overlay: {current}")
    if args.action.startswith("check-"):
        if current != args.action.removeprefix("check-"):
            raise RuntimeError(f"unexpected overlay state: {current}")
        return
    wanted = "patched" if args.action == "apply" else "base"
    if current == wanted:
        print("No change required.")
        return
    # Apply writes both complete zero caves before installing their hooks.
    # Revert disconnects both hooks before restoring the mode and caves.
    order = REGIONS if args.action == "apply" else tuple(reversed(REGIONS))
    for region in order:
        source = region.before if args.action == "apply" else region.after
        destination = region.after if args.action == "apply" else region.before
        for offset in range(0, len(destination), 4):
            old, new = source[offset:offset + 4], destination[offset:offset + 4]
            if old != new:
                transport.write_unverified(region.address + offset, int.from_bytes(new, "little"), 32)
        print(f"write 0x{region.address:08x}: {region.name}")
    if state(read_regions(transport)) != wanted:
        raise RuntimeError("period1 overlay write did not complete")
    flush_instruction_cache_minimal(transport)
    print(f"Installed state: {wanted}. Reopen D5; inspect H0 geometry and record the speaker acoustically.")


if __name__ == "__main__":
    main()
