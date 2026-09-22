#!/usr/bin/env python3
"""Live diagnostic for the active q192, two-S32-slot F1 speaker mixer.

The primary worker still constructs 48 four-word frames after the existing
profile raises source reads and DMA to 192 stereo frames.  This overlay
raises its loop to 192 and packs the primary stereo pair with an eight-byte
stride.  The trailing optional pair is overwritten by the following frame;
the final pair stays inside the existing 0xc00-byte source allocation and
outside the 0x600-byte DMA copy.  Only the reviewed primary branch is allowed.

This is reboot-volatile.  It is a hardware experiment, not yet a release
profile.  Stop Android audio services and close D5 before applying/reverting.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_speaker_192k import (
    Patch,
    flush_instruction_cache_minimal,
    preflight,
    read_patch_words_grouped,
)


SPEAKER = 0x4051B0B8
PATCHES = (
    Patch("primary mixer frames 48 -> 192 low word", 0x403D3A78,
          bytes.fromhex("fe91b583"), bytes.fromhex("fe91b503"), "hook"),
    Patch("primary mixer frames 48 -> 192 high word", 0x403D3A7C,
          bytes.fromhex("0181bf0a"), bytes.fromhex("0681bf0a"), "hook"),
    Patch("primary mixer stereo stride 16 -> 8", 0x403D3B08,
          bytes.fromhex("ae0a2639"), bytes.fromhex("ae0a3439"), "hook"),
)


def guards(transport: AocFactoryDiag) -> None:
    for offset, expected in ((0, 0x40275D00), (0x28C, 2), (0x298, 192),
                             (0x2B8, 0xC00), (0x2BC, 0xC00)):
        actual = int.from_bytes(transport.dump(SPEAKER + offset, 4), "little")
        if actual != expected:
            raise ValueError(f"speaker+0x{offset:x}: got 0x{actual:x}, expected 0x{expected:x}")
    branch = transport.dump(SPEAKER + 0x280, 4)
    if branch[1] != 0 or branch[2] != 1:
        raise ValueError(f"unsupported speaker branch bytes +0x280: {branch.hex()}")
    for address, expected in ((0x403D3C84, "1b22f066"),
                              (0x403D3D70, "1b33f066")):
        actual = transport.dump(address, 4)
        if actual != bytes.fromhex(expected):
            raise ValueError(f"requires existing two-slot CPU copy at 0x{address:x}: {actual.hex()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "revert", "check-stock", "check-patched"))
    parser.add_argument("--adb", type=pathlib.Path, default=pathlib.Path("/usr/bin/adb"))
    parser.add_argument("--adb-server-port", type=int, default=5037)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda text: int(text, 0))
    args = parser.parse_args()
    args.core = 2
    transport = AocFactoryDiag(args)
    # This kernel removes sub0/status when the PCM closes. The native check
    # establishes idleness from the PCM inventory and a complete root fd scan.
    transport.run("shell", "/vendor/bin/frankel_aoc_speaker_patch", "check-playback-closed")
    preflight(transport, True, False, "/proc/asound/card0/pcm5p/sub0/status")
    guards(transport)
    words = read_patch_words_grouped(transport, PATCHES)
    stock = all(words[patch.address] == patch.before for patch in PATCHES)
    patched = all(words[patch.address] == patch.after for patch in PATCHES)
    if not stock and not patched:
        raise ValueError("mixed/unknown mixer instructions: " + repr({hex(a): b.hex() for a, b in words.items()}))
    if args.action.startswith("check-"):
        if (args.action == "check-stock" and not stock) or (args.action == "check-patched" and not patched):
            raise ValueError(f"state is {'stock' if stock else 'patched'}")
        print(args.action + " passed")
        return 0
    applying = args.action == "apply"
    if (applying and patched) or (not applying and stock):
        print("already " + ("patched" if patched else "stock"))
        return 0
    for patch in PATCHES if applying else reversed(PATCHES):
        destination = patch.after if applying else patch.before
        transport.write_unverified(patch.address, int.from_bytes(destination, "little"), 32)
        print(f"0x{patch.address:08x}: {destination.hex()} {patch.name}", flush=True)
    words = read_patch_words_grouped(transport, PATCHES)
    for patch in PATCHES:
        expected = patch.after if applying else patch.before
        if words[patch.address] != expected:
            raise RuntimeError(f"write did not reach 0x{patch.address:08x}")
    flush_instruction_cache_minimal(transport)
    print("F1 primary mixer " + ("q192 packed stereo" if applying else "original 48-frame four-word layout"))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
