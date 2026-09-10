#!/usr/bin/env python3
"""Inject a guarded Frankel raw-mailbox GSA-unload DRAM canary.

This is an aggressive hardware experiment, not a production patch.  It starts
from the proven mailbox/zero-write-pointer ``aoc_core.ko``.  After normal stock
AoC authentication, it sends legacy GSA mailbox command 92 through
``gsa_unload_aoc_fw_image`` after that exported function has been redirected
to the raw-mailbox implementation in the companion GSA module patch.  A
nonzero result skips the write and follows the
normal Trusty START path.  Success writes NUL over the ``S`` in the harmless
``SampleRate`` diagnostic string at authenticated-body offset ``0xceb665``,
reads it back, and then follows the normal Trusty START path.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import shutil
import struct
import sys


EXPECTED_SIZE = 197104
EXPECTED_BASE_SHA256 = "f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c"

TEXT_CAVE_OFFSET = 0x0934
TEXT_HOOK_OFFSET = 0x0A9C
TEXT_RELOCATION_DONOR_OFFSET = 0x0AC8

STOCK_CAVE = bytes.fromhex(
    "e00313aa e10316aa 34040094 e00316aa a0040094 f5031f2a 52000014 "
    "01000090 21000091 03000014 01000090 21000091 e0031aaa 00000094"
)
PATCHED_CAVE = bytes.fromhex(
    "60e241f9 00000094 40010035 68ba40f9 aacc96d2 ca19a0f2 1f692a38 "
    "9f3f03d5 09696a38 69000035 69ca40f9 50000014 69ca40f9 4e000014"
)
STOCK_HOOK = bytes.fromhex("69ca40f9")
PATCHED_HOOK = bytes.fromhex("a6ffff17")
STOCK_DONOR = bytes.fromhex("00000094")
PATCHED_DONOR = bytes.fromhex("1f2003d5")

R_AARCH64_NONE = 0
R_AARCH64_CALL26 = 0x11B
GSA_SIMPLE_SYMBOL = "gsa_unload_aoc_fw_image"
STOCK_DONOR_SYMBOL = "_dev_info"
DISABLED_TEXT_RELOCATIONS = {0x0950: 0x113, 0x0954: 0x115,
                             0x095C: 0x113, 0x0960: 0x115,
                             0x0968: R_AARCH64_CALL26}
MOVED_RELOCATION_TO = 0x0938


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def sections(data: bytes | bytearray) -> dict[str, tuple[int, int, int]]:
    if data[:6] != b"\x7fELF\x02\x01" or len(data) != EXPECTED_SIZE:
        raise ValueError("input is not the exact guarded ELF64 module layout")
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    if shentsize != 64 or not shnum or shstrndx >= shnum:
        raise ValueError("unexpected ELF section-header layout")
    headers = [
        struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize)
        for i in range(shnum)
    ]
    names_header = headers[shstrndx]
    names = data[names_header[4] : names_header[4] + names_header[5]]
    result: dict[str, tuple[int, int, int]] = {}
    for header in headers:
        end = names.find(b"\0", header[0])
        if end < 0:
            raise ValueError("unterminated ELF section name")
        result[names[header[0] : end].decode("ascii")] = (
            header[4], header[5], header[9]
        )
    return result


def symbols(data: bytes | bytearray,
            sec: dict[str, tuple[int, int, int]]) -> list[str]:
    symoff, symsize, syment = sec[".symtab"]
    stroff, strsize, _ = sec[".strtab"]
    if syment != 24 or symsize % syment:
        raise ValueError("unexpected ELF symbol-table layout")
    strings = data[stroff : stroff + strsize]
    result: list[str] = []
    for offset in range(symoff, symoff + symsize, syment):
        nameoff = struct.unpack_from("<I", data, offset)[0]
        end = strings.find(b"\0", nameoff)
        if end < 0:
            raise ValueError("unterminated ELF symbol name")
        result.append(strings[nameoff:end].decode("utf-8"))
    return result


def relocations(data: bytes | bytearray,
                sec: dict[str, tuple[int, int, int]],
                names: list[str]) -> dict[int, tuple[int, int, int, int]]:
    offset, size, entry = sec[".rela.text"]
    if entry != 24 or size % entry:
        raise ValueError("unexpected .rela.text layout")
    result: dict[int, tuple[int, int, int, int]] = {}
    for file_offset in range(offset, offset + size, entry):
        target, info, addend = struct.unpack_from("<QQq", data, file_offset)
        symbol, kind = info >> 32, info & 0xFFFFFFFF
        if symbol >= len(names) or target in result:
            raise ValueError("invalid or duplicate .text relocation")
        result[target] = (file_offset, kind, symbol, addend)
    return result


def code_state(data: bytes | bytearray,
               text: tuple[int, int, int]) -> str:
    offset, size, _ = text
    if TEXT_RELOCATION_DONOR_OFFSET + 4 > size:
        raise ValueError(".text is too small")
    observed = (
        bytes(data[offset + TEXT_CAVE_OFFSET:
                   offset + TEXT_CAVE_OFFSET + len(STOCK_CAVE)]),
        bytes(data[offset + TEXT_HOOK_OFFSET:offset + TEXT_HOOK_OFFSET + 4]),
        bytes(data[offset + TEXT_RELOCATION_DONOR_OFFSET:
                   offset + TEXT_RELOCATION_DONOR_OFFSET + 4]),
    )
    if observed == (STOCK_CAVE, STOCK_HOOK, STOCK_DONOR):
        return "stock"
    if observed == (PATCHED_CAVE, PATCHED_HOOK, PATCHED_DONOR):
        return "patched"
    raise ValueError("unexpected or partial guarded code state")


def relocation_state(relocs: dict[int, tuple[int, int, int, int]],
                     names: list[str]) -> str:
    stock = True
    patched = True
    for target, expected_kind in DISABLED_TEXT_RELOCATIONS.items():
        item = relocs.get(target)
        if item is None:
            raise ValueError(f"missing relocation at {target:#x}")
        stock &= item[1] == expected_kind
        patched &= item[1] == R_AARCH64_NONE
    donor = relocs.get(TEXT_RELOCATION_DONOR_OFFSET)
    moved = relocs.get(MOVED_RELOCATION_TO)
    stock &= (donor is not None and donor[1] == R_AARCH64_CALL26
              and names[donor[2]] == STOCK_DONOR_SYMBOL and donor[3] == 0
              and moved is None)
    patched &= (donor is None and moved is not None
                and moved[1] == R_AARCH64_CALL26
                and names[moved[2]] == GSA_SIMPLE_SYMBOL and moved[3] == 0)
    if stock and not patched:
        return "stock"
    if patched and not stock:
        return "patched"
    raise ValueError("unexpected or partial guarded relocation state")


def restore(data: bytearray) -> bytearray:
    restored = bytearray(data)
    sec = sections(restored)
    names = symbols(restored, sec)
    relocs = relocations(restored, sec, names)
    textoff = sec[".text"][0]
    restored[textoff + TEXT_CAVE_OFFSET:
             textoff + TEXT_CAVE_OFFSET + len(STOCK_CAVE)] = STOCK_CAVE
    restored[textoff + TEXT_HOOK_OFFSET:textoff + TEXT_HOOK_OFFSET + 4] = STOCK_HOOK
    restored[textoff + TEXT_RELOCATION_DONOR_OFFSET:
             textoff + TEXT_RELOCATION_DONOR_OFFSET + 4] = STOCK_DONOR
    for target, kind in DISABLED_TEXT_RELOCATIONS.items():
        fileoff, _, symbol, addend = relocs[target]
        struct.pack_into("<QQq", restored, fileoff, target,
                         (symbol << 32) | kind, addend)
    moved = relocs[MOVED_RELOCATION_TO]
    stock_symbol = names.index(STOCK_DONOR_SYMBOL)
    struct.pack_into("<QQq", restored, moved[0], TEXT_RELOCATION_DONOR_OFFSET,
                     (stock_symbol << 32) | R_AARCH64_CALL26, 0)
    return restored


def validate(data: bytearray) -> tuple[str, dict[str, tuple[int, int, int]], list[str]]:
    sec = sections(data)
    for name in (".text", ".rela.text", ".symtab", ".strtab"):
        if name not in sec:
            raise ValueError(f"missing required section {name}")
    names = symbols(data, sec)
    state = code_state(data, sec[".text"])
    if relocation_state(relocations(data, sec, names), names) != state:
        raise ValueError("code and relocation states disagree")
    identity = data if state == "stock" else restore(data)
    if digest(identity) != EXPECTED_BASE_SHA256:
        raise ValueError("module identity mismatch after guarded reconstruction")
    return state, sec, names


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "patched"))
    args = parser.parse_args()
    if bool(args.check) == bool(args.output):
        raise ValueError("provide exactly one of OUTPUT or --check")
    data = bytearray(args.input.read_bytes())
    state, sec, names = validate(data)
    if args.check:
        if state != args.check:
            raise ValueError(f"expected {args.check}, found {state}")
        print(f"verified {state}: {args.input} sha256={digest(data)}")
        return 0
    assert args.output is not None
    if state == "patched":
        shutil.copy2(args.input, args.output)
        return 0

    relocs = relocations(data, sec, names)
    textoff = sec[".text"][0]
    data[textoff + TEXT_CAVE_OFFSET:
         textoff + TEXT_CAVE_OFFSET + len(STOCK_CAVE)] = PATCHED_CAVE
    data[textoff + TEXT_HOOK_OFFSET:textoff + TEXT_HOOK_OFFSET + 4] = PATCHED_HOOK
    data[textoff + TEXT_RELOCATION_DONOR_OFFSET:
         textoff + TEXT_RELOCATION_DONOR_OFFSET + 4] = PATCHED_DONOR
    for target in DISABLED_TEXT_RELOCATIONS:
        fileoff, _, symbol, addend = relocs[target]
        struct.pack_into("<QQq", data, fileoff, target,
                         symbol << 32, addend)
    donor = relocs[TEXT_RELOCATION_DONOR_OFFSET]
    target_symbol = names.index(GSA_SIMPLE_SYMBOL)
    struct.pack_into("<QQq", data, donor[0], MOVED_RELOCATION_TO,
                     (target_symbol << 32) | R_AARCH64_CALL26, 0)
    if validate(data)[0] != "patched":
        raise AssertionError("post-patch validation failed")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    shutil.copymode(args.input, args.output)
    print(f"patched legacy-raw-unload canary: {args.output} sha256={digest(data)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
