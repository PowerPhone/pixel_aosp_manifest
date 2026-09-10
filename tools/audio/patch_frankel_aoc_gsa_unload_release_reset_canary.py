#!/usr/bin/env python3
"""Guarded Frankel AoC authenticate/unload/release-reset canary patcher."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import shutil
import struct
import sys


# This is the exact aoc_core.ko carried by the known-good Frankel image used
# for the trial.  A patched module is accepted only if reversing every guarded
# edit reproduces this digest byte-for-byte.
EXPECTED_STOCK_SIZE = 197104
EXPECTED_STOCK_SHA256 = (
    "23acc08d0539657e72a0bc506abf6cef9950b90b192c51fd0dd9bf2177e4f2ad"
)

TEXT_CAVE_OFFSET = 0x0934
TEXT_HOOK_OFFSET = 0x0A9C
TEXT_REMOVED_LOG_OFFSET = 0x0AC8
TEXT_GSA_COMMAND_OFFSET = 0x0AF0

STOCK_CAVE = bytes.fromhex(
    "e00313aa e10316aa 34040094 e00316aa a0040094 f5031f2a 52000014 "
    "01000090 21000091"
)
PATCHED_CAVE = bytes.fromhex(
    "60e241f9 00000094 68ba40f9 a9cc96d2 c919a0f2 1f692938 9f3f03d5 "
    "69ca40f9 53000014"
)
STOCK_HOOK = bytes.fromhex("69ca40f9")
PATCHED_HOOK = bytes.fromhex("a6ffff17")
STOCK_REMOVED_LOG = bytes.fromhex("00000094")
PATCHED_REMOVED_LOG = bytes.fromhex("1f2003d5")
STOCK_GSA_COMMAND = bytes.fromhex("21008052")  # mov w1, #1 (GSA_AOC_START)
PATCHED_GSA_COMMAND = bytes.fromhex("a1008052")  # mov w1, #5 (RELEASE_RESET)

R_AARCH64_NONE = 0
R_AARCH64_CALL26 = 0x11B
GSA_UNLOAD_SYMBOL = "gsa_unload_aoc_fw_image"
STOCK_LOG_SYMBOL = "_dev_info"
DISABLED_TEXT_RELOCATIONS = {0x0950: 0x113, 0x0954: 0x115}
MOVED_RELOCATION_FROM = 0x0AC8
MOVED_RELOCATION_TO = 0x0938


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "patched"))
    return parser.parse_args()


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def sections(data: bytes | bytearray) -> dict[str, tuple[int, int, int]]:
    if data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("input is not a little-endian ELF64 file")
    if len(data) != EXPECTED_STOCK_SIZE:
        raise ValueError(
            f"unexpected module size {len(data)} (expected {EXPECTED_STOCK_SIZE})"
        )
    machine = struct.unpack_from("<H", data, 0x12)[0]
    file_type = struct.unpack_from("<H", data, 0x10)[0]
    if machine != 183 or file_type != 1:
        raise ValueError("input is not the guarded AArch64 relocatable module")
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    if shentsize != 64 or not shnum or shstrndx >= shnum:
        raise ValueError("unexpected ELF section-header layout")
    headers = [
        struct.unpack_from("<IIQQQQIIQQ", data, shoff + index * shentsize)
        for index in range(shnum)
    ]
    names_header = headers[shstrndx]
    names = data[names_header[4] : names_header[4] + names_header[5]]
    result = {}
    for header in headers:
        end = names.find(b"\0", header[0])
        if end < 0:
            raise ValueError("unterminated ELF section name")
        result[names[header[0] : end].decode("ascii")] = (
            header[4], header[5], header[9]
        )
    return result


def symbols(
    data: bytes | bytearray, sec: dict[str, tuple[int, int, int]]
) -> list[str]:
    symoff, symsize, syment = sec[".symtab"]
    stroff, strsize, _ = sec[".strtab"]
    if syment != 24 or symsize % syment:
        raise ValueError("unexpected ELF symbol-table layout")
    strings = data[stroff : stroff + strsize]
    result = []
    for offset in range(symoff, symoff + symsize, syment):
        nameoff = struct.unpack_from("<I", data, offset)[0]
        end = strings.find(b"\0", nameoff)
        if end < 0:
            raise ValueError("unterminated ELF symbol name")
        result.append(strings[nameoff:end].decode("utf-8"))
    return result


def relocations(
    data: bytes | bytearray,
    sec: dict[str, tuple[int, int, int]],
    names: list[str],
) -> dict[int, tuple[int, int, int, int]]:
    offset, size, entry = sec[".rela.text"]
    if entry != 24 or size % entry:
        raise ValueError("unexpected .rela.text layout")
    result = {}
    for file_offset in range(offset, offset + size, entry):
        target, info, addend = struct.unpack_from("<QQq", data, file_offset)
        symbol, kind = info >> 32, info & 0xFFFFFFFF
        if symbol >= len(names) or target in result:
            raise ValueError("invalid or duplicate .text relocation")
        result[target] = (file_offset, kind, symbol, addend)
    return result


def code_state(data: bytes | bytearray, text: tuple[int, int, int]) -> str:
    offset, size, _ = text
    if TEXT_GSA_COMMAND_OFFSET + 4 > size:
        raise ValueError(".text is too small")
    observed = (
        data[offset + TEXT_CAVE_OFFSET : offset + TEXT_CAVE_OFFSET + len(STOCK_CAVE)],
        data[offset + TEXT_HOOK_OFFSET : offset + TEXT_HOOK_OFFSET + 4],
        data[
            offset + TEXT_REMOVED_LOG_OFFSET : offset + TEXT_REMOVED_LOG_OFFSET + 4
        ],
        data[offset + TEXT_GSA_COMMAND_OFFSET : offset + TEXT_GSA_COMMAND_OFFSET + 4],
    )
    if observed == (
        STOCK_CAVE,
        STOCK_HOOK,
        STOCK_REMOVED_LOG,
        STOCK_GSA_COMMAND,
    ):
        return "stock"
    if observed == (
        PATCHED_CAVE,
        PATCHED_HOOK,
        PATCHED_REMOVED_LOG,
        PATCHED_GSA_COMMAND,
    ):
        return "patched"
    raise ValueError("unexpected or partially patched guarded code")


def relocation_state(
    relocs: dict[int, tuple[int, int, int, int]], names: list[str]
) -> str:
    stock = True
    patched = True
    for target, expected in DISABLED_TEXT_RELOCATIONS.items():
        if target not in relocs:
            raise ValueError(f"missing guarded relocation at {target:#x}")
        stock &= relocs[target][1] == expected
        patched &= relocs[target][1] == R_AARCH64_NONE
    old = relocs.get(MOVED_RELOCATION_FROM)
    new = relocs.get(MOVED_RELOCATION_TO)
    stock &= (
        old is not None
        and old[1] == R_AARCH64_CALL26
        and names[old[2]] == STOCK_LOG_SYMBOL
        and old[3] == 0
        and new is None
    )
    patched &= (
        old is None
        and new is not None
        and new[1] == R_AARCH64_CALL26
        and names[new[2]] == GSA_UNLOAD_SYMBOL
        and new[3] == 0
    )
    if stock and not patched:
        return "stock"
    if patched and not stock:
        return "patched"
    raise ValueError("unexpected or partially patched relocation state")


def restore_stock_for_identity_check(data: bytearray) -> bytearray:
    """Reverse all permitted edits so a patched input can be fully identified."""
    restored = bytearray(data)
    sec = sections(restored)
    names = symbols(restored, sec)
    relocs = relocations(restored, sec, names)
    textoff = sec[".text"][0]
    restored[
        textoff + TEXT_CAVE_OFFSET : textoff + TEXT_CAVE_OFFSET + len(STOCK_CAVE)
    ] = STOCK_CAVE
    restored[textoff + TEXT_HOOK_OFFSET : textoff + TEXT_HOOK_OFFSET + 4] = STOCK_HOOK
    restored[
        textoff + TEXT_REMOVED_LOG_OFFSET : textoff + TEXT_REMOVED_LOG_OFFSET + 4
    ] = STOCK_REMOVED_LOG
    restored[
        textoff + TEXT_GSA_COMMAND_OFFSET : textoff + TEXT_GSA_COMMAND_OFFSET + 4
    ] = STOCK_GSA_COMMAND
    for target, kind in DISABLED_TEXT_RELOCATIONS.items():
        fileoff, _, symbol, addend = relocs[target]
        struct.pack_into(
            "<QQq", restored, fileoff, target, (symbol << 32) | kind, addend
        )
    moved = relocs[MOVED_RELOCATION_TO]
    try:
        stock_symbol = names.index(STOCK_LOG_SYMBOL)
    except ValueError as error:
        raise ValueError(f"missing symbol {STOCK_LOG_SYMBOL}") from error
    struct.pack_into(
        "<QQq",
        restored,
        moved[0],
        MOVED_RELOCATION_FROM,
        (stock_symbol << 32) | R_AARCH64_CALL26,
        0,
    )
    return restored


def verify_identity(data: bytearray, state: str) -> None:
    candidate = data if state == "stock" else restore_stock_for_identity_check(data)
    observed = digest(candidate)
    if observed != EXPECTED_STOCK_SHA256:
        raise ValueError(
            "module identity mismatch after guarded reconstruction: "
            f"{observed} (expected {EXPECTED_STOCK_SHA256})"
        )


def validate(data: bytearray) -> tuple[str, dict[str, tuple[int, int, int]], list[str]]:
    sec = sections(data)
    for name in (".text", ".rela.text", ".symtab", ".strtab"):
        if name not in sec:
            raise ValueError(f"missing required section {name}")
    names = symbols(data, sec)
    relocs = relocations(data, sec, names)
    code = code_state(data, sec[".text"])
    rela = relocation_state(relocs, names)
    if code != rela:
        raise ValueError(f"code is {code}, relocations are {rela}")
    verify_identity(data, code)
    return code, sec, names


def main() -> int:
    args = arguments()
    if args.check and args.output is not None:
        raise ValueError("--check cannot be combined with OUTPUT")
    if not args.check and args.output is None:
        raise ValueError("apply mode requires OUTPUT")
    data = bytearray(args.input.read_bytes())
    state, sec, names = validate(data)
    if args.check:
        if state != args.check:
            raise ValueError(f"expected {args.check}, found {state}")
        print(
            f"verified {state}: {args.input} "
            f"(size={len(data)}, sha256={digest(data)})"
        )
        return 0
    assert args.output is not None
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if state == "patched":
        shutil.copy2(args.input, args.output)
        print(f"already patched: {args.output} (sha256={digest(data)})")
        return 0

    relocs = relocations(data, sec, names)
    textoff = sec[".text"][0]
    data[
        textoff + TEXT_CAVE_OFFSET : textoff + TEXT_CAVE_OFFSET + len(STOCK_CAVE)
    ] = PATCHED_CAVE
    data[textoff + TEXT_HOOK_OFFSET : textoff + TEXT_HOOK_OFFSET + 4] = PATCHED_HOOK
    data[
        textoff + TEXT_REMOVED_LOG_OFFSET : textoff + TEXT_REMOVED_LOG_OFFSET + 4
    ] = PATCHED_REMOVED_LOG
    data[
        textoff + TEXT_GSA_COMMAND_OFFSET : textoff + TEXT_GSA_COMMAND_OFFSET + 4
    ] = PATCHED_GSA_COMMAND
    for target in DISABLED_TEXT_RELOCATIONS:
        fileoff, _, symbol, addend = relocs[target]
        struct.pack_into("<QQq", data, fileoff, target, symbol << 32, addend)
    fileoff, _, _, addend = relocs[MOVED_RELOCATION_FROM]
    try:
        symbol = names.index(GSA_UNLOAD_SYMBOL)
    except ValueError as error:
        raise ValueError(f"missing symbol {GSA_UNLOAD_SYMBOL}") from error
    struct.pack_into(
        "<QQq",
        data,
        fileoff,
        MOVED_RELOCATION_TO,
        (symbol << 32) | R_AARCH64_CALL26,
        addend,
    )

    new_state, _, _ = validate(data)
    if new_state != "patched":
        raise AssertionError("patched module failed validation")
    args.output.write_bytes(data)
    shutil.copymode(args.input, args.output)
    print(
        f"patched GSA-unload/release-reset canary: {args.output} "
        f"(size={len(data)}, sha256={digest(data)})"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
