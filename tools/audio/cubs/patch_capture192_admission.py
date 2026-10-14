#!/usr/bin/env python3
"""Cubs live-module capture192 admission/command-encoding experiment only.

Extends the shared normal-PCM ceiling, EP3 CAP (PCM D10), and INTERNAL_MIC_TX.
Other frontend/backend DAI masks and all playback code remain unchanged.
No F1/PDM clocks, firmware sample geometry, polling cadence or IRQ behavior
are changed. This does NOT establish real192 capture: the companion guarded
firmware profile and physical measurements are still required.

Uses ELF sections/symbols/relocations plus exact local-byte guards, no hashes.
Writes a new module, never overwrites an existing file, no device operations.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct

SH = struct.Struct('<IIQQQQIIQQ')
SYM = struct.Struct('<IBBHQQ')
RELA = struct.Struct('<QQq')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def cstr(data, offset):
    require(0 <= offset < len(data), 'string offset out of range')
    end = data.find(b'\0', offset)
    require(end >= offset, 'unterminated string')
    return data[offset:end].decode('ascii')


class Elf:
    def __init__(self, data):
        self.data = data
        require(data[:6] == b'\x7fELF\x02\x01', 'expected ELF64 little-endian')
        require(struct.unpack_from('<HH', data, 16) == (1, 183),
                'expected AArch64 relocatable module')
        require(not data.endswith(b'~Module signature appended~\n'),
                'signed module needs a separate signing workflow')
        shoff = struct.unpack_from('<Q', data, 40)[0]
        shsize, count, names = struct.unpack_from('<HHH', data, 58)
        require(shsize == SH.size and 0 < names < count, 'bad section table')
        require(shoff + count * shsize <= len(data), 'truncated section table')
        self.headers = [SH.unpack_from(data, shoff + i * shsize) for i in range(count)]
        self.names = [cstr(self.content(names), h[0]) for h in self.headers]
        self.sections = {name: i for i, name in enumerate(self.names)}
        sym = self.headers[self.sections['.symtab']]
        require(sym[9] == SYM.size, 'unexpected symbol size')
        self.symbols = [SYM.unpack_from(self.content('.symtab'), p)
                        for p in range(0, sym[5], SYM.size)]
        self.symbol_names = [cstr(self.content(sym[6]), s[0]) for s in self.symbols]

    def content(self, section):
        if isinstance(section, str):
            section = self.sections[section]
        h = self.headers[section]
        require(h[4] + h[5] <= len(self.data), 'section outside file')
        return self.data[h[4]:h[4] + h[5]]

    def offset(self, section, address):
        h = self.headers[self.sections[section]]
        require(0 <= address < h[5], 'address outside section')
        return h[4] + address

    def symbol(self, name):
        found = [s for s, n in zip(self.symbols, self.symbol_names) if n == name]
        require(len(found) == 1, f'nonunique/missing symbol {name}')
        return found[0]

    def relocations(self, section):
        buf = self.content(section)
        require(len(buf) % RELA.size == 0, 'bad relocation table')
        return [RELA.unpack_from(buf, p) for p in range(0, len(buf), RELA.size)]

    def relocated_string(self, address):
        found = [(info, addend) for at, info, addend in self.relocations('.rela.data')
                 if at == address]
        require(len(found) == 1, f'no unique string relocation at {address:#x}')
        info, addend = found[0]
        require(info & 0xffffffff == 257, 'string is not R_AARCH64_ABS64')
        sym = self.symbols[info >> 32]
        require(self.names[sym[3]] == '.rodata', 'string does not resolve to rodata')
        return cstr(self.content(sym[3]), sym[4] + addend)


def transform(data, mode):
    elf = Elf(data)
    require(len(data) == 572104, 'not the inspected live Cubs module size')
    require(elf.offset('.text', 0) == 0x25a34 and len(elf.content('.text')) == 0x16d00,
            'unexpected Cubs text layout')
    dai = elf.symbol('aoc_dai_drv')
    require(elf.names[dai[3]] == '.data' and dai[4:] == (0xa5d8, 0x2d80),
            'unexpected DAI table layout')
    runtime_relocations = {(at, info & 0xffffffff, addend)
                           for at, info, addend in elf.relocations('.rela.text')
                           if 0x13a18 <= at <= 0x13a1c
                           and elf.names[elf.symbols[info >> 32][3]] == '.rodata'}
    require(runtime_relocations == {(0x13a18, 275, 0x16ba8), (0x13a1c, 277, 0x16ba8)},
            'normal PCM runtime template relocation changed')
    text = elf.content('.text')
    require(text[0x13a18:0x13a30] == bytes.fromhex(
        '08000090080100910a2140a90900c3f2097f1ea90a231ba9'),
        'normal PCM template copy guard mismatch')
    require(text[0xd768:0xd784] == bytes.fromhex(
        '888895525f00086b4002005408e08e522800a0725f00086b00020054'),
        'capture44100/96000 selector guard mismatch')
    require(text[0xd790:0xd7d4] == bytes.fromhex(
        '08e883525f00086b8001005408d087525f00086b61000054'
        '2800805208000014a8008052060000148800805204000014'
        'c800805202000014e8031f2a69200051e8c30039'),
        'capture low-rate selector/store guard mismatch')
    require(not any(0xd784 <= at < 0xd790 for at, _, _ in elf.relocations('.rela.text')),
            'unexpected relocation at encoding patch')

    patches = [
        ('normal PCM rate mask add192 only', '.rodata', 0x16bac,
         bytes.fromhex('fe070040'), bytes.fromhex('fe170040')),
        ('normal PCM maximum96000 ->192000', '.rodata', 0x16bb4,
         struct.pack('<I', 96000), struct.pack('<I', 192000)),
        ('capture192 request ->AoC enum7', '.text', 0xd784,
         bytes.fromhex('087097525f00086b09000014'),
         bytes.fromhex('5f04086be800805200020054')),
    ]
    wanted = {'EP3 CAP': (0x40000002, 'EP3 Capture', 0x7fe),
              'INTERNAL_MIC_TX': (0xc000000a, 'INTERNAL_MIC_TX Capture', 0xfe)}
    found = {}
    for base in range(dai[4], dai[4] + dai[5], 0xd0):
        name = elf.relocated_string(base)
        if name not in wanted:
            continue
        ident, stream, old_rates = wanted[name]
        raw = elf.content('.data')[base:base + 0xd0]
        require(struct.unpack_from('<I', raw, 8)[0] == ident, f'{name} DAI ID changed')
        require(elf.relocated_string(base + 0x68) == stream, f'{name} capture name changed')
        require(raw[0x98:0xc8] == bytes(0x30), f'{name} unexpectedly has playback')
        require(raw[0x70:0x7c] == struct.pack('<QI', 0x444, 0),
                f'{name} format guard changed')
        require(raw[0x80:0x98] == struct.pack('<IIIIII', 0, 0, 1, 4, 0, 0),
                f'{name} rate/channel bounds changed')
        patches.append((f'{name} capture rate mask add192 only', '.data', base + 0x7c,
                        struct.pack('<I', old_rates), struct.pack('<I', old_rates | 0x1000)))
        found[name] = {'table_address': hex(base), 'id': hex(ident)}
    require(set(found) == set(wanted), 'missing selected capture DAIs')
    changed = bytearray(data)
    report = []
    for name, section, address, old, new in patches:
        at = elf.offset(section, address)
        current = data[at:at + len(old)]
        require(current in (old, new), f'{name}: expected bytes mismatch at {at:#x}')
        chosen = new if mode == 'capture192' else old
        changed[at:at + len(chosen)] = chosen
        report.append({'name': name, 'section': section, 'address': hex(address),
                       'file_offset': hex(at), 'before': current.hex(), 'after': chosen.hex()})
    return bytes(changed), {'mode': mode, 'feature': 'admission-and-capture-encoding-only',
                           'dais': found, 'patches': report,
                           'changed_bytes': sum(a != b for a, b in zip(data, changed)),
                           'other_bytes_unchanged': True, 'device_accessed': False,
                           'physical192_capture_verified': False,
                           'requires_matching_firmware_profile': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path, help='new non-existing module file')
    parser.add_argument('--mode', choices=('capture192', 'stock'), default='capture192')
    args = parser.parse_args()
    try:
        require(args.input.is_file() and not args.input.is_symlink(), 'input must be regular file')
        require(not args.output.exists() and not args.output.is_symlink(), 'output must not exist')
        changed, report = transform(args.input.read_bytes(), args.mode)
        with args.output.open('xb') as stream:
            stream.write(changed)
        report.update(input=str(args.input.resolve()), output=str(args.output.resolve()))
        print(json.dumps(report, indent=2))
    except (OSError, ValueError, KeyError, IndexError, struct.error) as exc:
        parser.exit(1, f'error: {exc}\n')


if __name__ == '__main__':
    main()
