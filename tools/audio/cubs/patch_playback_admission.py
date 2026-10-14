#!/usr/bin/env python3
"""Cubs D5 playback96/192 admission and command encoding, not physical proof.

Requires the inspected live module with the existing capture192 admission
patch. Only D5/EP6 PB and TDM_0_RX gain rate bits; existing playback/capture
endpoint IDs, SRAM channels, IRQs and other DAIs remain unchanged.

The instruction extension is appended to .text. A 4096-byte file insertion
preserves all subsequent section alignments; section offsets and e_shoff are
adjusted, while original section indices, symbol values and relocations are
unchanged. No hashes, device operations or overwrite of an existing output.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile

from patch_capture192_admission import Elf, SH, require


def transform(data: bytes, assembler: str, linker: str, objcopy: str) -> tuple[bytes, dict]:
    elf = Elf(data)
    require(len(data) == 572104, 'require inspected live capture192 module size')
    text = elf.content('.text')
    require(elf.offset('.text', 0) == 0x25a34 and len(text) == 0x16d00,
            'unexpected live text layout')
    require(elf.symbol('aoc_audio_set_params')[4:] == (0xd3b8, 0x864),
            'set_params symbol changed')
    require(text[0xd4cc:0xd4e4] == bytes.fromhex(
        'a8008052bf0c0071640240f9e8cb0039a9009f1abf100071'),
        'playback default and continuation guard mismatch')
    require(text[0xd450:0xd488] == bytes.fromhex(
        '09e883525f00096bffd30039e8cf0039e1c3003900030054'
        '08d087525f00086b60020054888895525f00086b81020054'
        '8800805213000014'), 'existing low-rate selector changed')
    require(not any(0xd4cc <= at < 0xd4d0 for at, _, _ in elf.relocations('.rela.text')),
            'unexpected relocation at the branch hook')
    # This candidate must preserve the already deployed capture admission.
    require(elf.content('.rodata')[0x16bac:0x16bb8] == bytes.fromhex(
        'fe170040401f000000ee0200'), 'capture192 normal PCM template absent')
    require(text[0xd784:0xd790] == bytes.fromhex('5f04086be800805200020054'),
            'capture192 command encoding absent')

    source = Path(__file__).with_name('playback_rate_encoding.S')
    with tempfile.TemporaryDirectory(prefix='cubs-playback-encoding-', dir=source.parent) as tmp:
        tmp = Path(tmp)
        subprocess.run([assembler, '-o', str(tmp / 'code.o'), str(source)], check=True)
        subprocess.run([linker, '-Ttext=0', '-e', 'cubs_d5_playback_rate',
                        '-o', str(tmp / 'code.elf'), str(tmp / 'code.o')], check=True)
        subprocess.run([objcopy, '-O', 'binary', '-j', '.text',
                        str(tmp / 'code.elf'), str(tmp / 'code.bin')], check=True)
        code = (tmp / 'code.bin').read_bytes()
    require(len(code) == 0x16d2c and code[:0xd4cc] == bytes(0xd4cc),
            'unexpected encoding artifact layout')
    branch = code[0xd4cc:0xd4d0]
    payload = code[0x16d00:]
    require(branch == struct.pack('<I', 0x14000000 | ((0x16d00 - 0xd4cc) // 4)),
            'hook does not branch to the appended instructions')
    require(struct.unpack_from('<I', payload, 12)[0] ==
            (0x54000001 | (((0xd4d0 - 0x16d0c) // 4 & 0x7ffff) << 5)),
            'non-D5 branch does not return to original continuation')
    require(struct.unpack_from('<I', payload, 40)[0] ==
            (0x14000000 | ((0xd4d0 - 0x16d28) // 4 & 0x3ffffff)),
            'rate branch does not return to original continuation')

    changed = bytearray(data)
    at = elf.offset('.text', 0xd4cc)
    changed[at:at + 4] = branch
    changes = [{'name': 'D5-only exact96/192 rate encoding', 'section': '.text',
                'address': '0xd4cc', 'before': text[0xd4cc:0xd4d0].hex(),
                'after': branch.hex(), 'appended_address': '0x16d00',
                'appended_bytes': payload.hex()}]
    dai = elf.symbol('aoc_dai_drv')
    require(dai[4:] == (0xa5d8, 0x2d80), 'DAI table changed')
    wanted = {'EP6 PB': (0x5, 'EP6 Playback'),
              'TDM_0_RX': (0x80000006, 'TDM_0_RX Playback')}
    found = set()
    for base in range(dai[4], dai[4] + dai[5], 0xd0):
        name = elf.relocated_string(base)
        if name not in wanted:
            continue
        ident, stream = wanted[name]
        raw = elf.content('.data')[base:base + 0xd0]
        require(struct.unpack_from('<I', raw, 8)[0] == ident, f'{name}: wrong ID')
        require(elf.relocated_string(base + 0x98) == stream, f'{name}: wrong stream')
        require(raw[0x68:0x98] == bytes(0x30), f'{name}: unexpectedly has capture')
        require(struct.unpack_from('<I', raw, 0xac)[0] == 0xfe, f'{name}: wrong old mask')
        at = elf.offset('.data', base + 0xac)
        changed[at:at + 4] = struct.pack('<I', 0x14fe)
        changes.append({'name': f'{name} admit96/192', 'section': '.data',
                        'address': hex(base + 0xac), 'before': 'fe000000',
                        'after': 'fe140000'})
        found.add(name)
    require(found == set(wanted), 'selected DAIs missing')

    # Append to executable .text without shifting any instruction or symbol
    # inside it. The extra tail is not a callable function/CFI target: only a
    # direct branch from and back into the existing set_params function.
    insertion = elf.offset('.text', 0) + len(text)
    extra = 4096
    require(len(payload) < extra, 'extension larger than insertion')
    shoff = struct.unpack_from('<Q', data, 40)[0]
    require(shoff > insertion, 'section table unexpectedly precedes text')
    changed[insertion:insertion] = payload + bytes(extra - len(payload))
    struct.pack_into('<Q', changed, 40, shoff + extra)
    for index, header in enumerate(elf.headers):
        h = list(header)
        if index == elf.sections['.text']:
            h[5] += len(payload)
        elif h[4] >= insertion:
            h[4] += extra
        SH.pack_into(changed, shoff + extra + index * SH.size, *h)
    # Structural integrity of the generated module, not a mock/hardware test.
    result = Elf(bytes(changed))
    require(result.symbols == elf.symbols, 'symbol values unexpectedly changed')
    for name in elf.names:
        if name not in ('.text', '.data'):
            require(result.content(name) == elf.content(name), f'{name} changed unexpectedly')
    require(result.content('.text') == text[:0xd4cc] + branch + text[0xd4d0:] + payload,
            'unexpected code mutation')
    return bytes(changed), {
        'feature': 'D5-only playback admission and encoding, hardware unverified',
        'pcm_device': 5, 'firmware_entrypoint': 5, 'dai_label': 'EP6 PB',
        'patches': changes, 'preserves_capture192': True,
        'entrypoint_mapping_changed': False, 'D28_unchanged': True,
        'TAS_module_changed': False, 'firmware_TDM_clock_changed': False,
        'sample_rate_hardware_verified': False, 'device_accessed': False,
        'text_extension_bytes': len(payload), 'ELF_file_insertion_bytes': extra,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--assembler', default='aarch64-linux-gnu-as')
    parser.add_argument('--linker', default='aarch64-linux-gnu-ld')
    parser.add_argument('--objcopy', default='aarch64-linux-gnu-objcopy')
    args = parser.parse_args()
    try:
        require(args.input.is_file() and not args.input.is_symlink(), 'input must be a regular file')
        require(not args.output.exists() and not args.output.is_symlink(), 'output must not exist')
        data, report = transform(args.input.read_bytes(), args.assembler, args.linker, args.objcopy)
        with args.output.open('xb') as stream:
            stream.write(data)
        report.update(input=str(args.input.resolve()), output=str(args.output.resolve()))
        print(json.dumps(report, indent=2))
    except (OSError, ValueError, KeyError, IndexError, struct.error, subprocess.CalledProcessError) as exc:
        parser.exit(1, f'error: {exc}\n')


if __name__ == '__main__':
    main()
