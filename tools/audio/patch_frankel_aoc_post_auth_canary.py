#!/usr/bin/env python3
"""Inject a guarded Frankel AoC post-authentication DRAM-write canary.

The production Pixel 10 AoC path authenticates the stock firmware through GSA,
then starts the coprocessor.  This research-only patch reuses the callback's
otherwise unreachable non-GSA block to change ``SampleRate`` to ``XampleRate``
in the write-combined AoC DRAM mapping after authentication and before START.

This does not change the signed ``aoc.bin`` and does not enable 192 kHz.  It is
only a boot/log canary proving that a later, narrowly scoped firmware-runtime
patch can be delivered at the correct point.  Every changed instruction is
expected-byte guarded for the exact Frankel module.
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import struct
import sys


TEXT_CAVE_OFFSET = 0x934
TEXT_HOOK_OFFSET = 0xA9C

# Original dormant non-GSA loader instructions at .text+0x934..0x94f.  This
# subrange has no ELF relocations, so the module loader cannot rewrite the
# replacement instructions.
STOCK_CAVE = bytes.fromhex(
    "e00313aa e10316aa 34040094 e00316aa a0040094 f5031f2a 52000014"
)

# See aoc_post_auth_canary.S.  DRAM+0xceb665 corresponds to the first byte of
# the firmware's full-band-ultrasonic SampleRate error string.  A byte store
# avoids an unaligned 32-bit MMIO access.
PATCHED_CAVE = bytes.fromhex(
    "a9cc96d2 c919a0f2 0a0b8052 0a692938 9f3f03d5 69ca40f9 55000014"
)

STOCK_HOOK = bytes.fromhex("69ca40f9")  # ldr x9, [x19, #0x190]
PATCHED_HOOK = bytes.fromhex("a6ffff17")  # b .text+0x934


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply or verify Frankel's post-authentication AoC canary."
    )
    parser.add_argument("input", type=pathlib.Path, help="exact stock aoc_core.ko")
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument(
        "--check",
        choices=("stock", "patched"),
        help="verify without writing",
    )
    return parser.parse_args()


def elf_sections(data: bytes) -> dict[str, tuple[int, int, int]]:
    """Return {name: (file offset, size, entry size)} for an ELF64 LE file."""
    if data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("input is not a little-endian ELF64 file")

    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    if shentsize != 64 or not shnum or shstrndx >= shnum:
        raise ValueError("unexpected ELF section-header layout")

    headers = []
    for index in range(shnum):
        offset = shoff + index * shentsize
        if offset + shentsize > len(data):
            raise ValueError("truncated ELF section-header table")
        headers.append(struct.unpack_from("<IIQQQQIIQQ", data, offset))

    shstr = headers[shstrndx]
    names_offset, names_size = shstr[4], shstr[5]
    names = data[names_offset : names_offset + names_size]
    if len(names) != names_size:
        raise ValueError("truncated ELF section-name table")

    result: dict[str, tuple[int, int, int]] = {}
    for header in headers:
        name_offset = header[0]
        if name_offset >= len(names):
            raise ValueError("invalid ELF section-name offset")
        name_end = names.find(b"\0", name_offset)
        if name_end < 0:
            raise ValueError("unterminated ELF section name")
        name = names[name_offset:name_end].decode("ascii")
        result[name] = (header[4], header[5], header[9])
    return result


def code_state(data: bytes, text: tuple[int, int, int]) -> str:
    text_offset, text_size, _ = text
    if TEXT_HOOK_OFFSET + len(STOCK_HOOK) > text_size:
        raise ValueError(".text is too small for the guarded offsets")
    cave = data[
        text_offset + TEXT_CAVE_OFFSET : text_offset + TEXT_CAVE_OFFSET + len(STOCK_CAVE)
    ]
    hook = data[
        text_offset + TEXT_HOOK_OFFSET : text_offset + TEXT_HOOK_OFFSET + len(STOCK_HOOK)
    ]
    if cave == STOCK_CAVE and hook == STOCK_HOOK:
        return "stock"
    if cave == PATCHED_CAVE and hook == PATCHED_HOOK:
        return "patched"
    raise ValueError(
        "unexpected or partially patched instructions at the guarded .text offsets"
    )


def main() -> int:
    args = parse_args()
    if args.check and args.output is not None:
        raise ValueError("--check cannot be combined with OUTPUT")
    if not args.check and args.output is None:
        raise ValueError("apply mode requires OUTPUT")

    data = bytearray(args.input.read_bytes())
    sections = elf_sections(data)
    try:
        text = sections[".text"]
    except KeyError as error:
        raise ValueError(f"missing required ELF section {error.args[0]}") from error

    code = code_state(data, text)
    state = code

    if args.check:
        if state != args.check:
            raise ValueError(f"expected {args.check}, found {state}")
        print(f"verified {state}: {args.input}")
        return 0

    assert args.output is not None
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if state == "patched":
        shutil.copy2(args.input, args.output)
        print(f"already patched: {args.output}")
        return 0

    text_offset = text[0]
    data[
        text_offset + TEXT_CAVE_OFFSET : text_offset + TEXT_CAVE_OFFSET + len(STOCK_CAVE)
    ] = PATCHED_CAVE
    data[
        text_offset + TEXT_HOOK_OFFSET : text_offset + TEXT_HOOK_OFFSET + len(STOCK_HOOK)
    ] = PATCHED_HOOK
    # Validate the complete result before writing it.
    new_sections = elf_sections(data)
    if code_state(data, new_sections[".text"]) != "patched":
        raise AssertionError("patched code failed self-validation")

    args.output.write_bytes(data)
    shutil.copymode(args.input, args.output)
    print(f"patched post-authentication canary: {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
