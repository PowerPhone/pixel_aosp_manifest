#!/usr/bin/env python3
"""Apply a guarded Frankel AoC authenticate/unload/direct-start canary.

This research-only patch targets one exact stock ``aoc_core.ko`` layout.  It
does not patch signed ``aoc.bin``.  Instead it tests whether GSA's supported
unload operation releases the AoC DRAM firewall after successful stock-image
authentication.  If so, the callback performs a one-byte DRAM canary, installs
the driver's existing non-GSA IOMMU/reset setup, and starts AoC directly.

The patch deliberately reuses signed-image error-handling instructions that
are unreachable for the known-valid stock firmware.  Every code byte,
relocation, symbol, and section offset is checked before mutation.
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import struct
import sys


TEXT_CAVE_OFFSET = 0x0934
TEXT_HOOK_OFFSET = 0x0A9C
TEXT_CLEAR_FLAG_OFFSET = 0x0AC8

STOCK_CAVE = bytes.fromhex(
    "e00313aa e10316aa 34040094 e00316aa a0040094 f5031f2a 52000014 "
    "01000090 21000091 03000014 01000090 21000091 e0031aaa 00000094 "
    "e00316aa"
)

# Encodings audited against aoc_gsa_unload_canary.S.  The BL at +0x04 is
# intentionally zero-immediate: the module loader resolves its relocated GSA
# symbol.  DRAM+0xceb665 is the first byte of the Fullband Ultrasonic
# "SampleRate" diagnostic string; writing NUL is an observable canary only.
PATCHED_CAVE = bytes.fromhex(
    "60e241f9 00000094 e00313aa e10316aa 32040094 e00316aa 9e040094 "
    "68ba40f9 a9cc96d2 c919a0f2 1f692938 9f3f03d5 f5031f2a 69ca40f9 "
    "4d000014"
)

STOCK_HOOK = bytes.fromhex("69ca40f9")
PATCHED_HOOK = bytes.fromhex("a6ffff17")

STOCK_CLEAR_FLAG = bytes.fromhex("00000094")
PATCHED_CLEAR_FLAG = bytes.fromhex("7f220f39")

R_AARCH64_NONE = 0
R_AARCH64_CALL26 = 0x11B
GSA_UNLOAD_SYMBOL = "gsa_unload_aoc_fw_image"

# Relocations inside overwritten signed-image error paths must be disabled.
DISABLED_TEXT_RELOCATIONS = {
    0x0950: 0x113,
    0x0954: 0x115,
    0x095C: 0x113,
    0x0960: 0x115,
    0x0968: R_AARCH64_CALL26,
}
MOVED_RELOCATION_FROM = 0x0AC8
MOVED_RELOCATION_TO = 0x0938


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply or verify Frankel's AoC GSA-unload canary."
    )
    parser.add_argument("input", type=pathlib.Path, help="exact stock aoc_core.ko")
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "patched"))
    return parser.parse_args()


def elf_layout(data: bytes) -> tuple[dict[str, tuple[int, int, int, int]], list[tuple]]:
    if data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("input is not a little-endian ELF64 file")
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    if shentsize != 64 or not shnum or shstrndx >= shnum:
        raise ValueError("unexpected ELF section-header layout")
    headers = [
        struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize)
        for i in range(shnum)
    ]
    shstr = headers[shstrndx]
    names = data[shstr[4] : shstr[4] + shstr[5]]
    sections: dict[str, tuple[int, int, int, int]] = {}
    for index, header in enumerate(headers):
        end = names.find(b"\0", header[0])
        if end < 0:
            raise ValueError("unterminated ELF section name")
        name = names[header[0] : end].decode("ascii")
        sections[name] = (header[4], header[5], header[9], index)
    return sections, headers


def symbol_names(data: bytes, sections: dict[str, tuple[int, int, int, int]]) -> list[str]:
    sym_off, sym_size, sym_ent, _ = sections[".symtab"]
    str_off, str_size, _, _ = sections[".strtab"]
    if sym_ent != 24 or sym_size % sym_ent:
        raise ValueError("unexpected ELF symbol-table layout")
    strings = data[str_off : str_off + str_size]
    result = []
    for off in range(sym_off, sym_off + sym_size, sym_ent):
        name_off = struct.unpack_from("<I", data, off)[0]
        end = strings.find(b"\0", name_off)
        if end < 0:
            raise ValueError("unterminated ELF symbol name")
        result.append(strings[name_off:end].decode("utf-8"))
    return result


def relocation_map(
    data: bytes, sections: dict[str, tuple[int, int, int, int]], names: list[str]
) -> dict[int, tuple[int, int, int, int]]:
    rela_off, rela_size, rela_ent, _ = sections[".rela.text"]
    if rela_ent != 24 or rela_size % rela_ent:
        raise ValueError("unexpected .rela.text layout")
    result = {}
    for file_off in range(rela_off, rela_off + rela_size, rela_ent):
        target, info, addend = struct.unpack_from("<QQq", data, file_off)
        symbol = info >> 32
        kind = info & 0xFFFFFFFF
        if symbol >= len(names):
            raise ValueError("invalid relocation symbol index")
        if target in result:
            raise ValueError(f"duplicate .text relocation at {target:#x}")
        result[target] = (file_off, kind, symbol, addend)
    return result


def code_state(data: bytes, text: tuple[int, int, int, int]) -> str:
    off, size, _, _ = text
    if TEXT_CLEAR_FLAG_OFFSET + 4 > size:
        raise ValueError(".text is too small for guarded offsets")
    cave = data[off + TEXT_CAVE_OFFSET : off + TEXT_CAVE_OFFSET + len(STOCK_CAVE)]
    hook = data[off + TEXT_HOOK_OFFSET : off + TEXT_HOOK_OFFSET + 4]
    clear = data[off + TEXT_CLEAR_FLAG_OFFSET : off + TEXT_CLEAR_FLAG_OFFSET + 4]
    if (cave, hook, clear) == (STOCK_CAVE, STOCK_HOOK, STOCK_CLEAR_FLAG):
        return "stock"
    if (cave, hook, clear) == (PATCHED_CAVE, PATCHED_HOOK, PATCHED_CLEAR_FLAG):
        return "patched"
    raise ValueError("unexpected or partially patched guarded instructions")


def relocation_state(
    relocs: dict[int, tuple[int, int, int, int]], names: list[str]
) -> str:
    stock_ok = True
    patched_ok = True
    for target, stock_kind in DISABLED_TEXT_RELOCATIONS.items():
        try:
            _, kind, _, _ = relocs[target]
        except KeyError as error:
            raise ValueError(f"missing guarded relocation at {target:#x}") from error
        stock_ok &= kind == stock_kind
        patched_ok &= kind == R_AARCH64_NONE

    old = relocs.get(MOVED_RELOCATION_FROM)
    new = relocs.get(MOVED_RELOCATION_TO)
    stock_ok &= (
        old is not None
        and old[1] == R_AARCH64_CALL26
        and names[old[2]] == "_dev_info"
        and old[3] == 0
        and new is None
    )
    patched_ok &= (
        old is None
        and new is not None
        and new[1] == R_AARCH64_CALL26
        and names[new[2]] == GSA_UNLOAD_SYMBOL
        and new[3] == 0
    )
    if stock_ok and not patched_ok:
        return "stock"
    if patched_ok and not stock_ok:
        return "patched"
    raise ValueError("unexpected or partially patched .rela.text state")


def main() -> int:
    args = parse_args()
    if args.check and args.output is not None:
        raise ValueError("--check cannot be combined with OUTPUT")
    if not args.check and args.output is None:
        raise ValueError("apply mode requires OUTPUT")

    data = bytearray(args.input.read_bytes())
    sections, _ = elf_layout(data)
    for required in (".text", ".rela.text", ".symtab", ".strtab"):
        if required not in sections:
            raise ValueError(f"missing required section {required}")
    names = symbol_names(data, sections)
    code = code_state(data, sections[".text"])
    relocs = relocation_map(data, sections, names)
    rela = relocation_state(relocs, names)
    if code != rela:
        raise ValueError(f"code is {code}, relocations are {rela}")
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

    text_off = sections[".text"][0]
    data[text_off + TEXT_CAVE_OFFSET : text_off + TEXT_CAVE_OFFSET + len(STOCK_CAVE)] = PATCHED_CAVE
    data[text_off + TEXT_HOOK_OFFSET : text_off + TEXT_HOOK_OFFSET + 4] = PATCHED_HOOK
    data[text_off + TEXT_CLEAR_FLAG_OFFSET : text_off + TEXT_CLEAR_FLAG_OFFSET + 4] = PATCHED_CLEAR_FLAG

    for target in DISABLED_TEXT_RELOCATIONS:
        file_off, _, symbol, addend = relocs[target]
        struct.pack_into("<QQq", data, file_off, target, (symbol << 32) | R_AARCH64_NONE, addend)

    old_file_off, _, _, old_addend = relocs[MOVED_RELOCATION_FROM]
    try:
        unload_symbol = names.index(GSA_UNLOAD_SYMBOL)
    except ValueError as error:
        raise ValueError(f"missing symbol {GSA_UNLOAD_SYMBOL}") from error
    struct.pack_into(
        "<QQq",
        data,
        old_file_off,
        MOVED_RELOCATION_TO,
        (unload_symbol << 32) | R_AARCH64_CALL26,
        old_addend,
    )

    new_sections, _ = elf_layout(data)
    new_names = symbol_names(data, new_sections)
    new_relocs = relocation_map(data, new_sections, new_names)
    if code_state(data, new_sections[".text"]) != "patched":
        raise AssertionError("patched code failed self-validation")
    if relocation_state(new_relocs, new_names) != "patched":
        raise AssertionError("patched relocations failed self-validation")

    args.output.write_bytes(data)
    shutil.copymode(args.input, args.output)
    print(f"patched GSA-unload canary: {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
