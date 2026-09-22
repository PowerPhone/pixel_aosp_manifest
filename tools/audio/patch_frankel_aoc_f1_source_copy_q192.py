#!/usr/bin/env python3
"""Make the speaker source-copy caller retain 192 frames through copy/advance.

The nested ReadFromSram trampoline already reads 192 frames, but the caller
passed 48 to the enclosing wrapper at 0x403c93f0. That wrapper copies and
advances using its retained count. The 1152-byte deficit per call explains
the 0x480 surplus in the HF ring. This hook changes only the speaker caller,
replaying its conditional branch and skipping its narrow movi.n 48.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_speaker_192k import (
    Patch, flush_instruction_cache_minimal, preflight, read_patch_words_grouped,
)

PATCHES = (
    Patch("speaker source-copy cave 0", 0x403D3878,
          bytes(4), bytes.fromhex("a2210416"), "cave"),
    Patch("speaker source-copy cave 1", 0x403D387C,
          bytes(4), bytes.fromhex("a30cc2a0"), "cave"),
    Patch("speaker source-copy cave 2", 0x403D3880,
          bytes(4), bytes.fromhex("c0c62e00"), "cave"),
    Patch("speaker source-copy caller 48 -> 192", 0x403D3938,
          bytes.fromhex("de030846"), bytes.fromhex("06cfff46"), "hook"),
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
    preflight(transport, True, False, "/proc/asound/card0/pcm5p/sub0/status")
    for address, expected in ((0x4051B0B8, 0x40275D00), (0x4051B350, 192)):
        actual = int.from_bytes(transport.dump(address, 4), "little")
        if actual != expected:
            raise ValueError(f"guard 0x{address:08x}: got 0x{actual:x}, expected 0x{expected:x}")
    if transport.dump(0x403C89A0, 4) != bytes.fromhex("d20312d0"):
        raise ValueError("generic early-q48 clamp hook must be stock before reusing its cave")
    words = read_patch_words_grouped(transport, PATCHES)
    stock = all(words[p.address] == p.before for p in PATCHES)
    patched = all(words[p.address] == p.after for p in PATCHES)
    if not stock and not patched:
        raise ValueError("mixed/unknown source-copy state: " + repr({hex(a): b.hex() for a, b in words.items()}))
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
        if words[patch.address] != (patch.after if applying else patch.before):
            raise RuntimeError(f"write did not reach 0x{patch.address:08x}")
    flush_instruction_cache_minimal(transport)
    print("speaker source-copy caller " + ("192 frames" if applying else "48 frames"))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
