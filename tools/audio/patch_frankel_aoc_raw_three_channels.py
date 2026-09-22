#!/usr/bin/env python3
"""Admit three-channel RAW capture in the matched Frankel AoC kernel module.

Only the upper-bound immediate in aoc_raw_capture_trigger changes. The
existing CH_3=3 RAW_ENABLE_2 command encoding, MMAP limit, RT worker imports,
period timing, and all other module bytes remain intact. This does not make
the unmodified firmware's mono-sized raw banks safe for three channels:
the separate guarded F1 three-channel profile is also required.

Writes a NEW output file, never overwrites its input, calculates no hashes,
and performs no device operations or simulated hardware tests.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct


SECTION = struct.Struct("<IIQQQQIIQQ")
SYMBOL = struct.Struct("<IBBHQQ")
FUNCTION = "aoc_raw_capture_trigger"
FUNCTION_VA = 0xFD6C
COMPARE_VA = 0xFD9C
STOCK = bytes.fromhex("3f0c0071")  # cmp w1, #3 ; b.ge rejects 3 and above
THREE = bytes.fromhex("3f100071")  # cmp w1, #4 ; b.ge rejects 4 and above


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def cstring(data: bytes, offset: int) -> str:
    require(0 <= offset < len(data), "string offset outside table")
    end = data.find(b"\0", offset)
    require(end >= offset, "unterminated ELF string")
    return data[offset:end].decode("ascii")


def transform(data: bytes, mode: str) -> tuple[bytes, dict]:
    require(data[:6] == b"\x7fELF\x02\x01", "expected little-endian ELF64")
    require(struct.unpack_from("<HH", data, 16) == (1, 183),
            "expected relocatable AArch64 module")
    shoff = struct.unpack_from("<Q", data, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 58)
    require(shentsize == SECTION.size and 0 < shstrndx < shnum,
            "unexpected section header layout")
    require(shoff + shnum * shentsize <= len(data), "truncated section table")
    require(not data.endswith(b"~Module signature appended~\n"),
            "signed module input requires a separate signing workflow")
    headers = [SECTION.unpack_from(data, shoff + i * shentsize)
               for i in range(shnum)]

    def content(index: int) -> bytes:
        header = headers[index]
        require(header[4] + header[5] <= len(data), "section exceeds input")
        return data[header[4]:header[4] + header[5]]

    names = content(shstrndx)
    sections = {cstring(names, h[0]): i for i, h in enumerate(headers)}
    require(".text" in sections and ".symtab" in sections,
            "missing text/symbol sections")
    text_header = headers[sections[".text"]]
    require(text_header[4] == 0x7000 and text_header[5] == 0x16738,
            "not the matched Frankel AoC util text layout")
    sym_header = headers[sections[".symtab"]]
    require(sym_header[9] == SYMBOL.size and sym_header[5] % SYMBOL.size == 0,
            "unexpected symbol format")
    strings = content(sym_header[6])
    symbols = content(sections[".symtab"])
    selected = [entry for offset in range(0, len(symbols), SYMBOL.size)
                if cstring(strings, (entry := SYMBOL.unpack_from(symbols, offset))[0])
                == FUNCTION]
    require(len(selected) == 1 and selected[0][3] == sections[".text"]
            and selected[0][4] == FUNCTION_VA,
            "RAW trigger symbol does not match the known firmware companion")
    text = content(sections[".text"])
    require(text[0xFD90:COMPARE_VA] == bytes.fromhex(
                "010441b9ff230039ff0300f9")
            and text[COMPARE_VA + 4:0xFDA8] == bytes.fromhex(
                "2a070054040040f9"),
            "channel load/compare/error-branch guard mismatch")
    offset = text_header[4] + COMPARE_VA
    current = data[offset:offset + 4]
    require(current in (STOCK, THREE), "unknown RAW capture channel bound")
    replacement = THREE if mode == "three" else STOCK
    changed = bytearray(data)
    changed[offset:offset + 4] = replacement
    return bytes(changed), {
        "function": FUNCTION,
        "text_address": hex(COMPARE_VA),
        "file_offset": hex(offset),
        "previous_maximum_channels": 2 if current == STOCK else 3,
        "selected_maximum_channels": 3 if mode == "three" else 2,
        "instruction_before": current.hex(),
        "instruction_after": replacement.hex(),
        "changed_byte_count": sum(a != b for a, b in zip(data, changed)),
        "module_size": len(data),
        "other_module_bytes_unchanged": True,
        "firmware_three_channel_profile_required": True,
        "hardware_qualified": False,
        "device_accessed": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path, help="new non-existing module path")
    parser.add_argument("--mode", choices=("three", "stock"), default="three")
    args = parser.parse_args()
    try:
        require(args.input.is_file() and not args.input.is_symlink(),
                "input must be a regular non-symlink file")
        require(not args.output.exists() and not args.output.is_symlink(),
                "output already exists; choose a new path")
        changed, report = transform(args.input.read_bytes(), args.mode)
        with args.output.open("xb") as stream:
            stream.write(changed)
        report.update({"input": str(args.input.resolve()),
                       "output": str(args.output.resolve())})
        print(json.dumps(report, indent=2))
    except (OSError, ValueError, IndexError, KeyError, struct.error) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
