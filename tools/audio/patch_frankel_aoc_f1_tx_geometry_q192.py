#!/usr/bin/env python3
"""Align the live q192 two-slot speaker TX block with its DMA descriptors.

The constructor derived speaker+0x2a8 from 48 frames and four slots (0x300
bytes). The current profile changes the TDM frame count/slot count after
construction, but leaves this TX ping-pong offset and notify extent stale.
Set it to 192 * 2 * 4 = 0x600. Restore the stock cache call, whose length now
comes directly from the corrected field instead of multiplying it twice.
RX fields remain separate: its intermediate buffer has not been enlarged.
This is a reboot-volatile diagnostic, requiring closed D5.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_live_speaker_192k import (
    Patch, flush_instruction_cache_minimal, preflight, read_patch_words_grouped,
)

SPEAKER = 0x4051B0B8
PATCHES = (
    Patch("pre-commit cache span: use corrected field word 0", 0x403D3DE8,
          bytes.fromhex("552dc9f0"), bytes.fromhex("552dc981"), "hook"),
    Patch("pre-commit cache span: use corrected field word 1", 0x403D3DEC,
          bytes.fromhex("bb11e53a"), bytes.fromhex("5f9ae008"), "hook"),
    Patch("pre-commit cache span: use corrected field word 2", 0x403D3DF0,
          bytes.fromhex("b46841c0"), bytes.fromhex("006841c0"), "hook"),
    Patch("TX ping-pong and notify extent 0x300 -> 0x600", SPEAKER + 0x2A8,
          (0x300).to_bytes(4, "little"), (0x600).to_bytes(4, "little"), "hook"),
)


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
    transport.run("shell", "/vendor/bin/frankel_aoc_speaker_patch", "check-playback-closed")
    preflight(transport, True, False, "/proc/asound/card0/pcm5p/sub0/status")
    for offset, expected in ((0, 0x40275D00), (0x28C, 2), (0x298, 192),
                             (0x2B8, 0xC00), (0x2BC, 0xC00)):
        actual = int.from_bytes(transport.dump(SPEAKER + offset, 4), "little")
        if actual != expected:
            raise ValueError(f"speaker+0x{offset:x}: got0x{actual:x}, expected0x{expected:x}")
    words = read_patch_words_grouped(transport, PATCHES)
    stock = all(words[p.address] == p.before for p in PATCHES)
    patched = all(words[p.address] == p.after for p in PATCHES)
    if not stock and not patched:
        raise ValueError("mixed/unknown TX geometry: " + repr({hex(a): b.hex() for a, b in words.items()}))
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
    print("TX block " + ("0x600 bytes with direct cache extent" if applying else "0x300 bytes with doubled cache extent"))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
