#!/usr/bin/env python3
"""Inspect Google AoC crashinfo/ELF/ramdump images without a device.

The optional F1 cache overlay is based on the cache format observed in the
Frankel CP2A.260805.005 ramdumps.  Raw SRAM is stale for dirty cache lines, so
exception frames and FreeRTOS TCBs should be read from the overlaid view.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import struct
import sys


CRASHINFO_HEADER = struct.Struct("<8sIIIIQ256s")
ELF64_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
ELF64_PROGRAM_HEADER = struct.Struct("<IIQQQQQQ")
AOC_SECTION_HEADER = struct.Struct("<16s7I")
RAMDUMP_HEADER_OFFSET = 0x2000000
F1_SRAM_BASE = 0x40000000
F1_DCACHE_RECORD_SIZE = 0x88
F1_DCACHE_WAYS = (0, 0x44)

SECTION_TYPES = {
    0: "memory",
    1: "registers",
    2: "D-cache",
    3: "I-cache",
    4: "TLB",
    5: "SFR",
    6: "security SFR",
    7: "trace",
    8: "crash info",
    9: "TCM",
}


@dataclass(frozen=True)
class Section:
    name: str
    section_type: int
    core: int
    flags: int
    offset: int
    size: int
    vma: int
    lma: int


@dataclass(frozen=True)
class Image:
    data: bytes
    reason: str
    crash_header_size: int
    payload_size: int
    load_file_offset: int
    load_vaddr: int
    load_paddr: int
    load_size: int
    ramdump_file_offset: int
    section_table_offset: int
    sections: tuple[Section, ...]


def u32(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def c_string(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("utf-8", "replace")


def find_section_table(data: bytes, ramdump: int, count: int) -> int:
    """Find the extended-header section table used by recent AoC firmware."""
    search_end = min(ramdump + 0x1000, len(data))
    cursor = ramdump + 0x10
    while cursor + AOC_SECTION_HEADER.size <= search_end:
        name = data[cursor : cursor + 16].split(b"\0", 1)[0]
        if name == b"SRAM":
            try:
                sections = parse_sections(data, ramdump, cursor - ramdump, count)
            except (ValueError, struct.error):
                pass
            else:
                if sections and sections[0].offset >= 0x1000:
                    return cursor - ramdump
        cursor += 4
    raise ValueError("could not locate the AoC section table")


def parse_sections(
    data: bytes, ramdump: int, table_offset: int, count: int
) -> tuple[Section, ...]:
    sections: list[Section] = []
    for index in range(count):
        at = ramdump + table_offset + index * AOC_SECTION_HEADER.size
        values = AOC_SECTION_HEADER.unpack_from(data, at)
        name = c_string(values[0])
        section = Section(name, *values[1:])
        if not name or section.offset + section.size > len(data) - ramdump:
            raise ValueError(f"invalid AoC section {index} at file offset 0x{at:x}")
        sections.append(section)
    return tuple(sections)


def parse_image(path: Path) -> Image:
    data = path.read_bytes()
    if len(data) < CRASHINFO_HEADER.size:
        raise ValueError("file is shorter than a crashinfo header")
    magic, version, header_size, _flags, _crc, payload_size, reason_raw = (
        CRASHINFO_HEADER.unpack_from(data)
    )
    if magic != b"crashnfo":
        raise ValueError(f"bad crashinfo magic {magic!r}")
    if version != 0 or header_size < CRASHINFO_HEADER.size:
        raise ValueError(f"unsupported crashinfo header v{version}, size {header_size}")
    if data[header_size : header_size + 4] != b"\x7fELF":
        raise ValueError("crashinfo payload is not ELF")

    elf = ELF64_HEADER.unpack_from(data, header_size)
    ident = elf[0]
    if ident[4] != 2 or ident[5] != 1:
        raise ValueError("only little-endian ELF64 coredumps are supported")
    e_type, e_machine = elf[1:3]
    e_phoff, e_phentsize, e_phnum = elf[5], elf[9], elf[10]
    if e_type != 4 or e_machine != 183:
        raise ValueError(f"expected AArch64 ET_CORE, got type={e_type} machine={e_machine}")
    if e_phentsize != ELF64_PROGRAM_HEADER.size:
        raise ValueError(f"unexpected ELF program-header size {e_phentsize}")

    loads = []
    for index in range(e_phnum):
        ph = ELF64_PROGRAM_HEADER.unpack_from(
            data, header_size + e_phoff + index * e_phentsize
        )
        if ph[0] == 1:
            loads.append(ph)
    if len(loads) != 1:
        raise ValueError(f"expected one PT_LOAD, found {len(loads)}")
    _ptype, _pflags, p_offset, p_vaddr, p_paddr, p_filesz, _p_memsz, _align = loads[0]
    load_file_offset = header_size + p_offset
    ramdump = load_file_offset + RAMDUMP_HEADER_OFFSET
    if data[ramdump : ramdump + 8] != b"AOCDUMP\0":
        raise ValueError(f"no AOCDUMP header at file offset 0x{ramdump:x}")
    valid, section_count = struct.unpack_from("<II", data, ramdump + 8)
    if valid != 1 or not 1 <= section_count <= 64:
        raise ValueError(f"invalid AOCDUMP state valid={valid}, sections={section_count}")
    table_offset = find_section_table(data, ramdump, section_count)
    sections = parse_sections(data, ramdump, table_offset, section_count)
    return Image(
        data=data,
        reason=c_string(reason_raw),
        crash_header_size=header_size,
        payload_size=payload_size,
        load_file_offset=load_file_offset,
        load_vaddr=p_vaddr,
        load_paddr=p_paddr,
        load_size=p_filesz,
        ramdump_file_offset=ramdump,
        section_table_offset=table_offset,
        sections=sections,
    )


def named_section(image: Image, name: str) -> Section:
    for section in image.sections:
        if section.name == name:
            return section
    raise ValueError(f"ramdump has no {name!r} section")


def coherent_f1_sram(image: Image) -> tuple[bytes, int, int]:
    sram = named_section(image, "SRAM")
    cache = named_section(image, "F1 D-cache")
    raw_start = image.ramdump_file_offset + sram.offset
    memory = bytearray(image.data[raw_start : raw_start + sram.size])
    cache_start = image.ramdump_file_offset + cache.offset
    cache_data = image.data[cache_start : cache_start + cache.size]
    valid = 0
    applied = 0

    # Each record holds two {u32 tag, u8 data[64]} ways.  Frankel's set index
    # is encoded by pairs of dump records; tag bits 0 and 2 mean valid/dirty.
    for record in range(len(cache_data) // F1_DCACHE_RECORD_SIZE):
        for way_offset in F1_DCACHE_WAYS:
            at = record * F1_DCACHE_RECORD_SIZE + way_offset
            tag = u32(cache_data, at)
            if not tag & 1:
                continue
            valid += 1
            address = (
                F1_SRAM_BASE
                | (tag & 0xFFFFF000)
                | (((record // 2) & 0x3F) * 64)
            )
            relative = address - F1_SRAM_BASE
            if tag & 4 and 0 <= relative <= len(memory) - 64:
                memory[relative : relative + 64] = cache_data[at + 4 : at + 68]
                applied += 1
    return bytes(memory), valid, applied


EXCEPTION_FIELDS = (
    (0x04, "PC"),
    (0x08, "PS"),
    (0x0C, "A0"),
    (0x10, "A1"),
    (0x14, "A2"),
    (0x18, "A3"),
    (0x1C, "A4"),
    (0x20, "A5"),
    (0x24, "A6"),
    (0x28, "A7"),
    (0x2C, "A8"),
    (0x30, "A9"),
    (0x34, "A10"),
    (0x38, "A11"),
    (0x3C, "A12"),
    (0x40, "A13"),
    (0x44, "A14"),
    (0x48, "A15"),
    (0x4C, "SAR"),
    (0x50, "EXCCAUSE"),
    (0x54, "EXCVADDR"),
    (0x58, "LBEG"),
    (0x5C, "LEND"),
    (0x60, "LCOUNT"),
)


def find_exception_frame(memory: bytes, reason: str) -> int | None:
    match = re.search(
        r"EXCPC=0x([0-9a-fA-F]+).*EXCVADDR=0x([0-9a-fA-F]+).*EXC=(\d+)",
        reason,
    )
    if not match:
        return None
    excpc, excvaddr, cause = (int(match.group(1), 16), int(match.group(2), 16), int(match.group(3)))
    needle = struct.pack("<I", excpc)
    cursor = 0
    while True:
        found = memory.find(needle, cursor)
        if found < 0:
            return None
        frame = found - 4
        if (
            frame >= 0
            and frame + 0x64 <= len(memory)
            and u32(memory, frame + 0x50) == cause
            and u32(memory, frame + 0x54) == excvaddr
        ):
            return frame
        cursor = found + 1


def a5_runs(memory: bytes, low: int, high: int) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    start: int | None = None
    address = low
    while address + 4 <= high:
        is_canary = u32(memory, address - F1_SRAM_BASE) == 0xA5A5A5A5
        if is_canary and start is None:
            start = address
        elif not is_canary and start is not None:
            runs.append((start, address))
            start = None
        address += 4
    if start is not None:
        runs.append((start, address))
    return runs


def find_tcbs(memory: bytes, task_name: str) -> list[tuple[int, int, int]]:
    needle = task_name.encode() + b"\0"
    results = []
    cursor = 0
    while True:
        found = memory.find(needle, cursor)
        if found < 0:
            return results
        tcb = found - 0x38
        if 0 <= tcb <= len(memory) - 0x50:
            top = u32(memory, tcb)
            low = u32(memory, tcb + 0x34)
            if F1_SRAM_BASE <= low <= top < F1_SRAM_BASE + len(memory):
                results.append((F1_SRAM_BASE + tcb, top, low))
        cursor = found + 1


def print_report(path: Path, image: Image, show_sections: bool) -> None:
    print(f"file: {path}")
    print(f"file size: 0x{len(image.data):x} ({len(image.data)})")
    print(f"crashinfo header: 0x{image.crash_header_size:x}")
    print(f"crashinfo payload: 0x{image.payload_size:x} ({image.payload_size})")
    print(f"reason: {image.reason}")
    print(
        "ELF PT_LOAD: "
        f"file=0x{image.load_file_offset:x} vaddr=0x{image.load_vaddr:x} "
        f"paddr=0x{image.load_paddr:x} size=0x{image.load_size:x}"
    )
    print(
        f"AOCDUMP: file=0x{image.ramdump_file_offset:x} "
        f"section_table=+0x{image.section_table_offset:x} "
        f"sections={len(image.sections)}"
    )
    if show_sections:
        for index, section in enumerate(image.sections):
            kind = SECTION_TYPES.get(section.section_type, f"type {section.section_type}")
            print(
                f"  [{index:2d}] {section.name:16s} {kind:12s} "
                f"core={section.core} flags=0x{section.flags:x} "
                f"off=0x{section.offset:08x} size=0x{section.size:08x} "
                f"file=0x{image.ramdump_file_offset + section.offset:08x}"
            )

    memory, valid_lines, dirty_lines = coherent_f1_sram(image)
    print(f"F1 D-cache: valid lines={valid_lines}, dirty lines overlaid={dirty_lines}")

    frame = find_exception_frame(memory, image.reason)
    if frame is not None:
        print(f"F1 Xtensa exception frame: 0x{F1_SRAM_BASE + frame:08x}")
        for offset, name in EXCEPTION_FIELDS:
            print(f"  {name:8s} 0x{u32(memory, frame + offset):08x}")

    task_match = re.search(r"task=([^):]+)", image.reason)
    if task_match:
        task_name = task_match.group(1)
        for tcb, top, low in find_tcbs(memory, task_name):
            print(f"FreeRTOS TCB for {task_name}: 0x{tcb:08x}")
            print(f"  pxTopOfStack=0x{top:08x}")
            print(f"  pxStack=0x{low:08x}")
            print(f"  bottom headroom=0x{top - low:x} bytes")
            runs = [run for run in a5_runs(memory, low, top) if run[1] - run[0] >= 16]
            if runs:
                rendered = ", ".join(
                    f"0x{start:08x}..0x{end - 1:08x} ({end - start} B)"
                    for start, end in runs
                )
                print(f"  intact A5 runs: {rendered}")
                if u32(memory, low - F1_SRAM_BASE) != 0xA5A5A5A5:
                    print("  note: bottom canary is corrupt but later canary islands survive")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("coredump", type=Path, nargs="+", help="crashinfo .core file")
    parser.add_argument(
        "--no-sections", action="store_true", help="do not print the AoC section table"
    )
    args = parser.parse_args()
    status = 0
    for index, path in enumerate(args.coredump):
        if index:
            print()
        try:
            image = parse_image(path)
            print_report(path, image, not args.no_sections)
        except (OSError, ValueError, struct.error) as error:
            print(f"{path}: error: {error}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
