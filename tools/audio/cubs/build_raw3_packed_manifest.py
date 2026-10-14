#!/usr/bin/env python3
"""Build a separate exclusive RAW3 candidate; no device access or hashes."""
import argparse
import json
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RETIRED = {
    'normal_bytes', 'normal_samples', 'raw_bytes',
    'raw_stage_finish_cave', 'stage_count_cave', 'stage_publish',
    'raw_stage_finish_hook', 'stage_count_hook',
    'mono_count_hook', 'mono_unshifted_source', 'mono_count_cave',
}
SIZES = {
    'raw_three_admission': 6, 'normal_stage_skip': 3,
    'producer_destination_hook': 3, 'producer_sample_hook': 6,
    'producer_missing_hook': 5, 'producer_post_hook': 4,
    'packed_stage': 93, 'producer_sample_cave': 54,
    'producer_missing_cave': 41, 'producer_destination_cave': 23,
    'producer_post_cave': 22, 'packed_publish_entry': 20,
}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--shared', type=Path, default=ROOT / 'work/audio-research/cubs/live-aoc-regions-20260922/shared.bin')
    p.add_argument('--base', type=Path, default=ROOT / 'tools/audio/manifests/cubs_d10_native192_edge0_control.json')
    p.add_argument('--output-dir', type=Path, default=ROOT / 'work/audio-research/cubs/raw3-packed-candidate-20260923')
    p.add_argument('--manifest', type=Path, default=ROOT / 'tools/audio/manifests/cubs_d10_raw3_packed_candidate.json')
    a = p.parse_args()
    stock = a.shared.read_bytes()
    if len(stock) != 0x600000 or stock[0x27a618:0x27a628].hex() != '4e062ee242872c86a154fc6e156e8e02':
        raise SystemExit('Not the inspected live Cubs shared firmware')
    base = json.loads(a.base.read_text())
    if base['profile'] != 'cubs-15876290-polygon-exclusive-d10-native192-edge0-control':
        raise SystemExit('The base must be the unchanged mono native192 edge0 profile')
    a.output_dir.mkdir(parents=True, exist_ok=True)
    obj, elf = a.output_dir / 'candidate.o', a.output_dir / 'candidate.elf'
    subprocess.run([str(ROOT / 'work/toolchains/sky1-binutils-build-gas/gas/as-new'),
                    str(ROOT / 'tools/audio/asm/cubs_d10_raw3_packed_candidate.S'),
                    '-o', str(obj)], check=True)
    subprocess.run([str(ROOT / 'work/toolchains/sky1-binutils-build/build/ld/ld-new'),
                    '-T', str(ROOT / 'tools/audio/asm/cubs_d10_raw3_packed_candidate.ld'),
                    str(obj), '-o', str(elf)], check=True)
    encoded = elf.read_bytes()
    shoff = struct.unpack_from('<I', encoded, 32)[0]
    width, count, name_index = struct.unpack_from('<HHH', encoded, 46)
    sections = [struct.unpack_from('<10I', encoded, shoff + i * width) for i in range(count)]
    ns = sections[name_index]
    names = encoded[ns[4]:ns[4] + ns[5]]
    changes = []
    found = set()
    for sec in sections:
        name = names[sec[0]:].split(b'\0', 1)[0].decode().removeprefix('.')
        if name not in SIZES:
            continue
        _, _, _, address, offset, size, *_ = sec
        if size != SIZES[name]:
            raise SystemExit(f'{name}: assembled size {size}, expected {SIZES[name]}')
        before = stock[address - 0x40000000:address - 0x40000000 + size]
        after = encoded[offset:offset + size]
        changes.append(dict(name=name, address=f'0x{address:08x}',
                            before_hex=before.hex(), after_hex=after.hex()))
        found.add(name)
    if found != set(SIZES):
        raise SystemExit(f'Missing candidate sections: {set(SIZES) - found}')
    patches = [entry for entry in base['patches'] if entry['name'] not in RETIRED] + changes
    patches.sort(key=lambda entry: int(entry['address'], 0))
    end = 0
    for entry in patches:
        address = int(entry['address'], 0)
        if address < end:
            raise SystemExit(f'Overlapping patch {entry["name"]}')
        end = address + len(bytes.fromhex(entry['after_hex']))
    base.update(
        profile='cubs-15876290-polygon-exclusive-d10-raw3-packed192-candidate',
        qualification='UNTESTED exclusive volatile RAW3 prototype; NOT FLASHABLE',
        patches=patches,
        restrictions=[
            'Cold boot; all framework/hotword/other capture clients stopped',
            'D10 S16_LE exactlythree channels, mic list0,1,2,-1 and channel selectorThree',
            'Separate kernel raw-channel admission is required; do not merely request-c3 on the old module',
            'Normal destination2 is skipped for native7/three-channel producer; no concurrent processed AP capture',
            'RAW destination3 is packed S16 and bypasses S32 microphone compensation; all other producer destinations retain stock loops',
            'The AP staging/publisher replacements are RAW3-only; mono/stereo use requires reboot into the original mono profile',
            'Runtime RAW ring must retain its0x600 capacity and0x300 half-bank, with physicalmics0/2/3 mapped fromlogical0/1/2',
            'Use the unchanged coherent-cache wrapper; all pointer values stay logical40..., factory wire accesses use verified NC aliases',
            'Restore exact stock regions or cold reboot before ordinary services resume',
        ],
        geometry={
            'pdm_clock_requested_hz': 6400000, 'native_rate_enum': 7,
            'native_receiver_control_bit1': 0, 'dma_frames': 96,
            'expected_block_seconds': 0.0005, 'channels': 3,
            'producer_raw_destination': 3, 'skipped_normal_destination': 2,
            'source_ring_capacity_bytes': 1536, 'source_padded_bank_bytes': 768,
            'packed_block_bytes': 576, 'stage_offset': '0x524',
            'stage_end_exclusive': '0x764', 'stage_plane_end': '0x824',
            's32_intermediate_staging': False, 'new_allocations': False,
        },
        kernel_admission={
            'module': 'aoc_alsa_dev_util.ko', 'function': 'aoc_raw_capture_trigger',
            'text_address': '0x1035c', 'file_offset': '0x35d90',
            'before_hex': '3f0c0071', 'after_hex': '3f100071',
            'meaning': 'cmp w1,#3 -> cmp w1,#4; retain b.ge and reject>=4',
            'raw_enable_command': '0x1272',
        },
    )
    # The firstsix bytes of the former identity anchor are now the exact
    # admission patch. Keep the remaining10bytes as an independent guard.
    base['guards'] = [g for g in base['guards'] if int(g['address'], 0) != 0x4027a618]
    base['guards'].append(dict(address='0x4027a61e', expected_hex=stock[0x27a61e:0x27a628].hex()))
    a.manifest.parent.mkdir(parents=True, exist_ok=True)
    a.manifest.write_text(json.dumps(base, indent=2) + '\n')
    print(f'{len(patches)} exclusive RAW3 regions -> {a.manifest}')


if __name__ == '__main__':
    main()
