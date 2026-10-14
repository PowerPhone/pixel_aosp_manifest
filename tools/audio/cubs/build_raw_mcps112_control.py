#!/usr/bin/env python3
"""Assemble a paired RAW MCPS112 experiment over mono-edge0 or RAW3.

No device operations. This is a scheduling discriminator, not a validated
fix or a change to kernel timeouts/firmware return codes.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[3]
SIZES = {'raw_mcps_enable_hook': 5, 'raw_mcps_disable_hook': 5,
         'raw_mcps_enable_cave': 11, 'raw_mcps_disable_cave': 17}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', type=Path, required=True)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--output-dir', type=Path, required=True)
    a = p.parse_args()
    base = json.loads(a.base.read_text())
    if base['profile'] not in (
            'cubs-15876290-polygon-exclusive-d10-native192-edge0-control',
            'cubs-15876290-polygon-exclusive-d10-raw3-packed192-candidate'):
        raise SystemExit('Only the reviewed mono edge0 or RAW3 base is supported')
    if 'raw_mcps_vote_control' in base:
        raise SystemExit('Input already contains an MCPS control')
    stock = (ROOT / 'work/audio-research/cubs/live-aoc-regions-20260922/shared.bin').read_bytes()
    a.output_dir.mkdir(parents=True, exist_ok=True)
    obj, elf = a.output_dir / 'candidate.o', a.output_dir / 'candidate.elf'
    subprocess.run([str(ROOT / 'work/toolchains/sky1-binutils-build-gas/gas/as-new'),
                    str(ROOT / 'tools/audio/asm/cubs_d10_raw_mcps112_control.S'),
                    '-o', str(obj)], check=True)
    subprocess.run([str(ROOT / 'work/toolchains/sky1-binutils-build/build/ld/ld-new'),
                    '-T', str(ROOT / 'tools/audio/asm/cubs_d10_raw_mcps112_control.ld'),
                    str(obj), '-o', str(elf)], check=True)
    encoded = elf.read_bytes()
    shoff = struct.unpack_from('<I', encoded, 32)[0]
    width, count, name_index = struct.unpack_from('<HHH', encoded, 46)
    sections = [struct.unpack_from('<10I', encoded, shoff + i * width) for i in range(count)]
    ns = sections[name_index]
    names = encoded[ns[4]:ns[4] + ns[5]]
    # The inherited raw_bytes region is unreachable and overlaps our disable
    # cave. Removing its obsolete write preserves both mono and RAW3 flow.
    patches = [entry for entry in base['patches'] if entry['name'] != 'raw_bytes']
    found = set()
    for sec in sections:
        name = names[sec[0]:].split(b'\0', 1)[0].decode().removeprefix('.')
        if name not in SIZES:
            continue
        _, _, _, address, offset, size, *_ = sec
        if size != SIZES[name]:
            raise SystemExit(f'Unexpected encoded width for{name}')
        patches.append(dict(name=name, address=f'0x{address:08x}',
                            before_hex=stock[address - 0x40000000:address - 0x40000000 + size].hex(),
                            after_hex=encoded[offset:offset + size].hex()))
        found.add(name)
    if found != set(SIZES):
        raise SystemExit('Missing paired MCPS sections')
    patches.sort(key=lambda entry: int(entry['address'], 0))
    end = 0
    for entry in patches:
        address = int(entry['address'], 0)
        if address < end:
            raise SystemExit(f'Overlapping region{entry["name"]}')
        end = address + len(bytes.fromhex(entry['after_hex']))
    base['patches'] = patches
    base['variant'] = 'raw-mcps112-scheduling-control'
    base['qualification'] = 'UNTESTED paired RAW MCPS112 control; real command latency/capture continuity still required'
    base['raw_mcps_vote_control'] = dict(raw_type=2, stock_mcps=28, candidate_mcps=112,
                                       paired_enable_disable=True,
                                       code_immediates_only=True,
                                       kernel_timeout_changed=False)
    base['restrictions'].append('Experimental RAW MCPS vote112; must see+112 on start and-112/zero on stop; not proof of actual DSP clock or adequate scheduling')
    a.manifest.parent.mkdir(parents=True, exist_ok=True)
    a.manifest.write_text(json.dumps(base, indent=2) + '\n')
    print(f'{len(patches)} regions -> {a.manifest}')


if __name__ == '__main__':
    main()
