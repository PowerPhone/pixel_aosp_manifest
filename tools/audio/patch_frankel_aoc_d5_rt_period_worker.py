#!/usr/bin/env python3
"""Redirect Frankel's D5 period scheduling to a sleep-safe RT helper module.

Only the queue_work_on relocation at .text+0x1318c is redirected. Other
queue_work_on calls retain the original import. The helper's flush/destroy
wrappers intercept teardown and delegate non-D5 workqueues unchanged.

This is a guarded ELF64 relocatable-module transformation, not a firmware
signature bypass. Existing section indices and code bytes are retained;
expanded string/symbol/version/modinfo tables are appended and repointed.
No hashes, mock execution, or device operations are performed.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct


MODULE = "frankel_d5_period_rt"
QUEUE_SITE = 0x1318C
CALL26 = 283
EXPECTED_SIZE = 556736
ELF_SECTION = struct.Struct("<IIQQQQIIQQ")
ELF_SYMBOL = struct.Struct("<IBBHQQ")
ELF_RELA = struct.Struct("<QQq")
WRAPPERS = {"__flush_workqueue": "pp_d5_flush",
            "destroy_workqueue": "pp_d5_destroy"}
EXPORTS = ("pp_d5_qwork", *WRAPPERS.values())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def cstring(data: bytes | bytearray, offset: int) -> str:
    require(0 <= offset < len(data), "string offset outside table")
    end = data.find(b"\0", offset)
    require(end >= offset, "unterminated ELF string")
    return bytes(data[offset:end]).decode("ascii")


class ModuleElf:
    def __init__(self, data: bytes):
        require(len(data) == EXPECTED_SIZE, "expected the original 556736-byte module; already-patched/other inputs are refused")
        require(data[:6] == b"\x7fELF\x02\x01", "expected little-endian ELF64")
        require(struct.unpack_from("<HH", data, 16) == (1, 183), "expected relocatable AArch64 ELF")
        shoff = struct.unpack_from("<Q", data, 40)[0]
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 58)
        require(shentsize == 64 and shnum == 50 and shstrndx < shnum,
                "unexpected section-header layout")
        require(shoff + shnum * shentsize == len(data),
                "unexpected trailing data or module signature; unsigned input required")
        self.data = data
        self.headers = [list(ELF_SECTION.unpack_from(data, shoff + i * 64))
                        for i in range(shnum)]
        names = self.content(shstrndx)
        self.indices = {cstring(names, header[0]): i
                        for i, header in enumerate(self.headers)}
        require(len(self.indices) == shnum, "duplicate section names")
        for header in self.headers:
            if header[1] != 8:  # SHT_NOBITS occupies no file bytes.
                require(header[4] + header[5] <= len(data), "section extends past input")

    def content(self, section: str | int) -> bytes:
        index = self.indices[section] if isinstance(section, str) else section
        header = self.headers[index]
        return self.data[header[4]:header[4] + header[5]]

    def header(self, section: str) -> list[int]:
        return self.headers[self.indices[section]]


def helper_crcs(path: Path) -> dict[str, int]:
    exports = {}
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) < 4 or fields[1] not in EXPORTS:
            continue
        name = fields[1]
        owner = Path(fields[2]).name.removesuffix(".ko")
        require(owner == MODULE, f"{name} belongs to unexpected module {owner}")
        require(name not in exports, f"duplicate helper CRC for {name}")
        value = int(fields[0], 16)
        require(0 <= value <= 0xFFFFFFFF, f"invalid CRC for {name}")
        exports[name] = value
    require(set(exports) == set(EXPORTS), "Module.symvers lacks required helper exports")
    return exports


def patch(data: bytes, crcs: dict[str, int]) -> tuple[bytes, dict]:
    elf = ModuleElf(data)
    require(elf.header(".text")[4:6] == [0x7000, 0x16738], "unexpected text layout")
    text = elf.content(".text")
    require(text[QUEUE_SITE - 8:QUEUE_SITE + 4] ==
            bytes.fromhex("62c206910004805200000094"),
            "period queue call instruction/argument guard mismatch")
    require(data[0x1A5C8:0x1A5D0] == bytes.fromhex("2a0b43f9480108aa")
            and data[0x1A5E4:0x1A5E8] == bytes.fromhex("5f110071"),
            "D5 must retain the mailbox-only selector before RT dispatch")

    symbols = bytearray(elf.content(".symtab"))
    strings = bytearray(elf.content(".strtab"))
    require(elf.header(".symtab")[9] == 24 and len(symbols) % 24 == 0,
            "unexpected symbol table")
    require(elf.header(".symtab")[6] == elf.indices[".strtab"],
            "symbol table uses an unexpected string table")
    entries = [list(ELF_SYMBOL.unpack_from(symbols, i))
               for i in range(0, len(symbols), 24)]
    names = [cstring(strings, entry[0]) for entry in entries]
    require(not any(name in names for name in EXPORTS), "helper imports already present")
    originals = {}
    for name in ("queue_work_on", *WRAPPERS):
        indices = [i for i, item in enumerate(names) if item == name]
        require(len(indices) == 1, f"expected one {name} symbol")
        index = indices[0]
        require(entries[index][3] == 0 and entries[index][1] >> 4 == 1,
                f"{name} is not an undefined global import")
        originals[name] = index

    def add_string(value: str) -> int:
        offset = len(strings)
        strings.extend(value.encode("ascii") + b"\0")
        return offset

    new_queue_index = len(entries)
    queue_symbol = entries[originals["queue_work_on"]].copy()
    queue_symbol[0] = add_string("pp_d5_qwork")
    entries.append(queue_symbol)
    for old, new in WRAPPERS.items():
        entries[originals[old]][0] = add_string(new)

    relocations = bytearray(elf.content(".rela.text"))
    rela_header = elf.header(".rela.text")
    require(rela_header[9] == 24 and len(relocations) % 24 == 0
            and rela_header[6] == elf.indices[".symtab"]
            and rela_header[7] == elf.indices[".text"], "unexpected text relocations")
    queue_sites = []
    wrapper_sites = {name: [] for name in WRAPPERS}
    selected = []
    for offset in range(0, len(relocations), 24):
        target, info, addend = ELF_RELA.unpack_from(relocations, offset)
        index, kind = info >> 32, info & 0xFFFFFFFF
        require(index < len(names), "relocation symbol index outside table")
        name = names[index]
        if name == "queue_work_on":
            queue_sites.append(target)
        if name in WRAPPERS:
            require(kind == CALL26 and addend == 0, "unexpected teardown import relocation")
            wrapper_sites[name].append(target)
        if target == QUEUE_SITE:
            selected.append(offset)
            require(name == "queue_work_on" and kind == CALL26 and addend == 0,
                    "selected relocation is not the unmodified queue_work_on CALL26")
            ELF_RELA.pack_into(relocations, offset, target,
                               (new_queue_index << 32) | CALL26, addend)
    require(len(selected) == 1 and len(queue_sites) == 5,
            "unexpected period queue callsite layout")
    require(all(len(sites) == 7 for sites in wrapper_sites.values()),
            "unexpected flush/destroy callsite layout")

    versions = bytearray(elf.content("__versions"))
    require(len(versions) % 64 == 0, "expected classic64-byte module version records")
    version_names = {}
    for offset in range(0, len(versions), 64):
        name = cstring(versions[offset:offset + 64], 8)
        require(name not in version_names, f"duplicate imported version {name}")
        version_names[name] = offset
    require(not any(name in version_names for name in EXPORTS), "helper versions already present")
    require(all(name in version_names for name in originals), "missing original import versions")

    def version_record(name: str) -> bytes:
        encoded = name.encode("ascii") + b"\0"
        require(len(encoded) <= 56, "version symbol name exceeds record")
        return struct.pack("<Q", crcs[name]) + encoded.ljust(56, b"\0")

    for old, new in WRAPPERS.items():
        offset = version_names[old]
        versions[offset:offset + 64] = version_record(new)
    versions.extend(version_record("pp_d5_qwork"))

    modinfo = bytearray(elf.content(".modinfo"))
    fields, cursor = [], 0
    while cursor < len(modinfo):
        field = cstring(modinfo, cursor)
        if field.startswith("depends="):
            fields.append((cursor, field))
        cursor += len(field) + 1
    require(len(fields) == 1, "expected one dependency modinfo entry")
    old_offset, dependency = fields[0]
    require(MODULE not in dependency[8:].split(","), "helper dependency already present")
    new_dependency = dependency + ("," if dependency[8:] else "") + MODULE
    new_offset = len(modinfo)
    old_size = len(dependency) + 1
    modinfo[old_offset:old_offset + old_size] = b"\0" * old_size
    modinfo.extend(new_dependency.encode("ascii") + b"\0")
    # Leave all other modinfo offsets intact; repoint the dependency's local
    # object symbol along with its enlarged entry rather than shifting aliases.
    dependency_symbols = 0
    for entry in entries:
        if entry[3] == elf.indices[".modinfo"] and entry[4] == old_offset:
            require(entry[5] == old_size, "unexpected dependency object size")
            entry[4], entry[5] = new_offset, len(new_dependency) + 1
            dependency_symbols += 1
    require(dependency_symbols == 1, "expected one dependency object symbol")
    symbols = b"".join(ELF_SYMBOL.pack(*entry) for entry in entries)

    output = bytearray(data)
    replacements = {".rela.text": relocations, ".strtab": strings,
                    ".symtab": symbols, "__versions": versions, ".modinfo": modinfo}
    for name, content in replacements.items():
        header = elf.header(name)
        alignment = max(1, header[8])
        output.extend(b"\0" * (-len(output) % alignment))
        header[4], header[5] = len(output), len(content)
        output.extend(content)
    output.extend(b"\0" * (-len(output) % 8))
    new_shoff = len(output)
    output.extend(b"".join(ELF_SECTION.pack(*header) for header in elf.headers))
    struct.pack_into("<Q", output, 40, new_shoff)
    return bytes(output), {
        "helper_module": MODULE,
        "queue_redirect_text_offset": hex(QUEUE_SITE),
        "queue_work_on_preserved_sites": [hex(site) for site in queue_sites if site != QUEUE_SITE],
        "teardown_redirects": {WRAPPERS[name]: [hex(site) for site in sites]
                               for name, sites in wrapper_sites.items()},
        "helper_export_crcs": {name: hex(value) for name, value in crcs.items()},
        "input_bytes": len(data), "output_bytes": len(output),
        "code_bytes_changed": 0,
        "dependency": new_dependency,
        "load_requirement": "Load frankel_d5_period_rt before aoc_alsa_dev_util; helper must delegate non-D5 work and safely drain teardown.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--symvers", type=Path, required=True,
                        help="Module.symvers from the matching helper build")
    args = parser.parse_args()
    try:
        require(args.input.is_file() and not args.input.is_symlink(), "input must be a regular non-symlink module")
        require(not args.output.exists() and not args.output.is_symlink(), "output already exists; use a fresh explicit path")
        changed, report = patch(args.input.read_bytes(), helper_crcs(args.symvers))
        with args.output.open("xb") as stream:
            stream.write(changed)
        report.update({"input": str(args.input.resolve()), "output": str(args.output.resolve()),
                       "symvers": str(args.symvers.resolve())})
        print(json.dumps(report, indent=2))
    except (OSError, ValueError, KeyError, struct.error) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
