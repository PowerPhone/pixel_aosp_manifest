#!/usr/bin/env python3
"""Assemble the Cubs-specific volatile mono D10 candidate; no device access.

Requires the already extracted live shared.bin, recovered Xtensa tools, and
exact instruction guards. Produces a byte manifest, not a signed firmware.
"""
import argparse
import json
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SIZES = {
    'stream_rate': 2, 'restart_native_rate': 2, 'classify_native': 3,
    'configure_native_rate': 2, 'native_timebase': 6, 'native_clock': 4,
    'notify_native': 3, 'fanout_native': 3,
    'normal_bytes': 6, 'normal_samples': 6, 'raw_direct_return': 18, 'raw_bytes': 6,
    'ap_rate_admission_hook': 3, 'ap_rate_admission_cave': 14,
    'raw_stage_finish_hook': 3, 'raw_stage_finish_cave': 12,
    'mono_unshifted_source': 6,
    'stage_gate': 6, 'stage_count_cave': 10, 'stage_publish': 3,
    'stage_count_hook': 6, 'mono_count_hook': 6, 'mono_count_cave': 6,
    'raw_output_bytes': 3, 'allowed_rate_mask': 6, 'allowed_rate_bound': 3,
    'cache_wrapper': 46,
    'timestamp_expected_half_ms': 6,
}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--shared', type=Path, default=ROOT / 'work/audio-research/cubs/live-aoc-regions-20260922/shared.bin')
    p.add_argument('--output-dir', type=Path)
    p.add_argument('--manifest', type=Path)
    p.add_argument('--native96-control', action='store_true',
                   help='Separate diagnostic stock-clock control; does not replace the192 manifest')
    p.add_argument('--native192-edge0-control', action='store_true',
                   help='Separate6.4MHz native receiver-edge0 control; clock/RFactor/HPF preserved')
    p.add_argument('--native192-rfactor2-control', action='store_true',
                   help='Experimental3.2MHz native-RFactor register2 control; encoding unqualified')
    p.add_argument('--native192-rfactor8-control', action='store_true',
                   help='Experimental3.2MHz native-RFactor register8 control; cadence requires hardware proof')
    p.add_argument('--native192-rfactor6-control', action='store_true',
                   help='Experimental3.2MHz native-RFactor register6 control; hardware produced64k')
    p.add_argument('--native192-rfactor3-control', action='store_true',
                   help='Experimental3.2MHz native-RFactor register3 control; discriminate encoding')
    p.add_argument('--native192-rfactor6-clock4266-control', action='store_true',
                   help='Experimental4.266666MHz/register6 target192k; physical cadence unqualified')
    a = p.parse_args()
    if sum((a.native96_control, a.native192_rfactor2_control, a.native192_rfactor8_control,
            a.native192_rfactor6_control, a.native192_rfactor6_clock4266_control,
            a.native192_rfactor3_control, a.native192_edge0_control)) > 1:
        p.error('Select only one diagnostic control')
    requested_output, requested_manifest = a.output_dir, a.manifest
    a.output_dir = a.output_dir or ROOT / ('work/audio-research/cubs/mono96-clock-control-20260922'
                                         if a.native96_control else 'work/audio-research/cubs/mono192-candidate-20260922')
    a.manifest = a.manifest or ROOT / ('tools/audio/manifests/cubs_d10_mono96_clock_control.json'
                                     if a.native96_control else 'tools/audio/manifests/cubs_d10_mono192_candidate.json')
    assembly = 'cubs_d10_mono96_clock_control.S' if a.native96_control else 'cubs_d10_mono192_candidate.S'
    stock_sites = {'native_clock', 'native_timebase', 'timestamp_expected_half_ms'} if a.native96_control else set()
    linker = 'cubs_d10_mono192_candidate.ld'
    sizes = dict(SIZES)
    if a.native192_edge0_control:
        a.output_dir = requested_output or ROOT / 'work/audio-research/cubs/native192-edge0-control-20260922'
        a.manifest = requested_manifest or ROOT / 'tools/audio/manifests/cubs_d10_native192_edge0_control.json'
        assembly = 'cubs_d10_native192_edge0_control.S'
        linker = 'cubs_d10_native192_edge0_control.ld'
        sizes['native_receiver_edge_zero'] = 3
    rfactor_control = (8 if a.native192_rfactor8_control else 6 if (a.native192_rfactor6_control
                       or a.native192_rfactor6_clock4266_control)
                       else 3 if a.native192_rfactor3_control
                       else 2 if a.native192_rfactor2_control else None)
    if rfactor_control:
        a.output_dir = requested_output or ROOT / f'work/audio-research/cubs/native192-rfactor{rfactor_control}-control-20260922'
        a.manifest = requested_manifest or ROOT / f'tools/audio/manifests/cubs_d10_native192_rfactor{rfactor_control}_control.json'
        assembly = f'cubs_d10_native192_rfactor{rfactor_control}_control.S'
        linker = f'cubs_d10_native192_rfactor{rfactor_control}_control.ld'
        stock_sites = {'native_clock'}
        sizes.update({f'rfactor{rfactor_control}_native_hook': 5, f'rfactor{rfactor_control}_native_cave': 15})
        if a.native192_rfactor6_clock4266_control:
            a.output_dir = requested_output or ROOT / 'work/audio-research/cubs/native192-rfactor6-clock4266-control-20260922'
            a.manifest = requested_manifest or ROOT / 'tools/audio/manifests/cubs_d10_native192_rfactor6_clock4266_control.json'
            assembly = 'cubs_d10_native192_rfactor6_clock4266_control.S'
            stock_sites = set()
    a.output_dir.mkdir(parents=True, exist_ok=True)
    obj, elf = a.output_dir / 'candidate.o', a.output_dir / 'candidate.elf'
    subprocess.run([str(ROOT / 'work/toolchains/sky1-binutils-build-gas/gas/as-new'),
                    '-I', str(ROOT / 'tools/audio/asm'),
                    str(ROOT / 'tools/audio/asm' / assembly), '-o', str(obj)], check=True)
    subprocess.run([str(ROOT / 'work/toolchains/sky1-binutils-build/build/ld/ld-new'),
                    '-L', str(ROOT / 'tools/audio/asm'),
                    '-T', str(ROOT / 'tools/audio/asm' / linker),
                    str(obj), '-o', str(elf)], check=True)
    original = a.shared.read_bytes()
    if len(original) != 0x600000 or original[0x27a618:0x27a628].hex() != '4e062ee242872c86a154fc6e156e8e02':
        raise SystemExit('Not the independently identified live Cubs shared firmware')
    encoded = elf.read_bytes()
    if encoded[:6] != b'\x7fELF\x01\x01':
        raise SystemExit('Expected little-endian ELF32 candidate')
    shoff = struct.unpack_from('<I', encoded, 32)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', encoded, 46)
    sections = [struct.unpack_from('<10I', encoded, shoff + i * shentsize) for i in range(shnum)]
    names_sec = sections[shstrndx]
    names = encoded[names_sec[4]:names_sec[4] + names_sec[5]]
    patches = []
    stock_guards = []
    found = set()
    for s in sections:
        name = names[s[0]:].split(b'\0', 1)[0].decode().removeprefix('.')
        if name not in sizes:
            continue
        _, _, _, address, offset, length, *_ = s
        if length != sizes[name] or not 0x40000000 <= address < 0x40600000:
            raise SystemExit(f'Unexpected size/address for {name}: {length}/{address:x}')
        before = original[address - 0x40000000:address - 0x40000000 + length]
        after = encoded[offset:offset + length]
        if name in stock_sites:
            if before != after:
                raise SystemExit(f'Clock-control stock region changed: {name}')
            stock_guards.append(dict(address=f'0x{address:08x}', expected_hex=before.hex()))
            found.add(name)
            continue
        if before == after:
            raise SystemExit(f'Unchanged patch {name}')
        patches.append(dict(name=name, address=f'0x{address:08x}', before_hex=before.hex(), after_hex=after.hex()))
        found.add(name)
    if found != set(sizes):
        raise SystemExit(f'Missing sections: {set(sizes) - found}')
    result = {
        'profile': 'cubs-15876290-polygon-exclusive-d10-mono192-direct-candidate',
        'qualification': 'UNTESTED; volatile real-hardware prototype; NOT FLASHABLE',
        'restrictions': ['All framework/hotword/other capture clients stopped',
                         'D10 only, one selected physical microphone, S16_LE mono',
                         'Do not use stereo, Three, raw multi-mic, or concurrent AP capture',
                         'Requires independently established Cubs cache coherence and explicit I-cache flush',
                         'Restore all original bytes before restarting ordinary services; cold reboot if restoration is uncertain'],
        'geometry': {'pdm_clock_requested_hz': 6400000, 'native_rate_enum': 7,
                     'dma_frames': 96, 'expected_block_seconds': 0.0005,
                     'mono_stage_s32_bytes': 384, 'mono_output_s16_bytes': 192,
                     'fixed_stage_plane_capacity_bytes': 768},
        'cache_flush': {'dispatch_address': '0x402392b4',
                        'stock_dispatch_hex': '8cbf2740',
                        'wrapper_entry': '0x4027b24c',
                        'wrapper_dispatch_hex': '4cb22740',
                        'command': 'HD Mic gain (cB)=0', 'expected_status': 64,
                        'requirement': 'First apply from cold boot before any RAW capture; all ordinary HD senders stopped; NC host restores original dispatch immediately after status64; unexpected status means stop and cold reboot, not retry'},
        'patches': sorted(patches, key=lambda item: int(item['address'], 0)),
        'guards': [dict(address='0x4027a618', expected_hex='4e062ee242872c86a154fc6e156e8e02'),
                   dict(address='0x4025d1e0', expected_hex='30c662'),
                   dict(address='0x402392b4', expected_hex='8cbf2740'),
                   dict(address='0x403085d0', expected_hex='36210022a04032a00076820ef27300f27310f27320f2733032d3010020001df0')],
    }
    if a.native96_control:
        result['profile'] = 'cubs-15876290-polygon-exclusive-d10-native96-clock-control'
        result['qualification'] = 'DIAGNOSTIC96k CONTROL ONLY;192k WAV header intentionally does not reflect physical rate'
        result['restrictions'].append('Only a controlled-rate discriminator; a physical20k tone is expected at40k in a192k-header WAV')
        result['geometry'].update(pdm_clock_requested_hz=3200000, native_physical_rate_hz=96000,
                                  expected_block_seconds=0.001, intended_wav_header_hz=192000)
        result['guards'].extend(stock_guards)
    if a.native192_edge0_control:
        result['profile'] = 'cubs-15876290-polygon-exclusive-d10-native192-edge0-control'
        result['qualification'] = 'UNTESTED receiver-edge discriminator;192k cadence alone does not establish valid microphone samples'
        result['geometry'].update(native_receiver_control_bit1=0,
                                  native_rfactor_register_value=4,
                                  hpf_bypass_polarity='stock')
        result['restrictions'].append('Forces the native receiver edge only; physical pad clock and microphone compatibility remain unmeasured')
    if rfactor_control:
        result['profile'] = f'cubs-15876290-polygon-exclusive-d10-native192-rfactor{rfactor_control}-control'
        result['qualification'] = 'UNTESTED experimentalRFactor-registerencoding;192k cadence and bandwidth NOT established'
        result['restrictions'].append('Enum5 producer branch is repurposed as an exclusive-native7 code cave; no ordinary capture consumers')
        result['geometry'].update(pdm_clock_requested_hz=3200000, native_rfactor_argument=4,
                                  native_rfactor_register_offset='0x28', native_rfactor_register_value=rfactor_control,
                                  register_encoding_experimental=True)
        result['guards'].extend(stock_guards)
        if a.native192_rfactor6_clock4266_control:
            result['profile'] = 'cubs-15876290-polygon-exclusive-d10-native192-rfactor6-clock4266-control'
            result['geometry'].update(pdm_clock_requested_hz=4266666,
                                      pdm_base_clock_observed_hz=38400000,
                                      intended_pdm_clock_divider=9)
    a.manifest.parent.mkdir(parents=True, exist_ok=True)
    a.manifest.write_text(json.dumps(result, indent=2) + '\n')
    print(f'{len(patches)} Cubs-only regions -> {a.manifest}')


if __name__ == '__main__':
    main()
