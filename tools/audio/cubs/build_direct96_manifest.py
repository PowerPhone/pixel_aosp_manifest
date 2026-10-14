#!/usr/bin/env python3
"""Build a boot-local, exclusive D5 direct96/direct192 + existing D10 experiment.

No device calls. Inputs must come from guarded reads on the intended cold boot;
there is deliberately no reusable/default runtime object address. The emitted
manifest is volatile firmware data, NOT a signed or flashable AoC image.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[3]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--speaker-only', action='store_true',
                   help='emit zero-pointer template for a dynamic guarded device applier')
    p.add_argument('--sample-rate', type=int, choices=(96000, 192000), default=96000,
                   help='physical TDM input rate; TAS2572 internal processing remains <=96kHz')
    p.add_argument('--slots', type=int, choices=(2, 4), default=4,
                   help='two-slot192 keeps768-byte halves at96 frames/0.5ms; experimental')
    p.add_argument('--capture-manifest', type=Path)
    p.add_argument('--input-controller', type=lambda v: int(v, 0))
    p.add_argument('--output-controller', type=lambda v: int(v, 0))
    p.add_argument('--endpoint', type=lambda v: int(v, 0))
    p.add_argument('--source-ring', type=lambda v: int(v, 0))
    p.add_argument('--output-dir', type=Path, required=True)
    a = p.parse_args()
    if a.slots == 2 and a.sample_rate != 192000:
        p.error('--slots2 is only defined for the separate192kHz experiment')
    if not a.speaker_only:
        if a.capture_manifest is None:
            p.error('--capture-manifest required unless --speaker-only')
        for address in (a.input_controller, a.output_controller, a.endpoint, a.source_ring):
            if address is None or not 0x40300000 <= address < 0x403ff000 or address & 3:
                p.error('runtime objects must be aligned in the independently mapped shared MB3')
    a.output_dir.mkdir(parents=True, exist_ok=False)
    source = ROOT / 'tools/audio/asm/cubs_d5_direct96_candidate.S'
    linkscript = source.with_suffix('.ld')
    obj, elf = a.output_dir / 'candidate.o', a.output_dir / 'candidate.elf'
    rate_flags = ['--defsym', 'DIRECT_RATE192=1'] if a.sample_rate == 192000 else []
    if a.slots == 2:
        rate_flags += ['--defsym', 'DIRECT_TWO_SLOTS=1']
    subprocess.run([str(ROOT / 'work/toolchains/sky1-binutils-build-gas/gas/as-new'),
                    '--no-transform', '--no-target-align', *rate_flags,
                    str(source), '-o', str(obj)], check=True)
    subprocess.run([str(ROOT / 'work/toolchains/sky1-binutils-build/build/ld/ld-new'),
                    '-T', str(linkscript), str(obj), '-o', str(elf)], check=True)
    encoded = elf.read_bytes()
    shoff = struct.unpack_from('<I', encoded, 32)[0]
    width, count, string_index = struct.unpack_from('<HHH', encoded, 46)
    sections = [struct.unpack_from('<10I', encoded, shoff + i * width) for i in range(count)]
    names_s = sections[string_index]
    names = encoded[names_s[4]:names_s[4] + names_s[5]]
    stock = (ROOT / 'work/audio-research/cubs/live-aoc-regions-20260922/shared.bin').read_bytes()
    if len(stock) != 0x600000 or stock[0x274404:0x274407] != bytes.fromhex('36c100'):
        raise SystemExit('wrong independently recovered Cubs speaker firmware')
    result = (dict(profile='cubs-15876290-polygon-speaker-template', patches=[],
                   guards=[], restrictions=[]) if a.speaker_only
              else json.loads(a.capture_manifest.read_text()))
    selected = {'entry_hook', 'silence_call', 'callback_tolerance', 'payload', 'clock_hook'}
    if a.sample_rate == 192000 and a.slots == 4:
        selected.add('callback_shift')
    if a.slots == 2:
        selected.update(('slot_hook', 'padding_hook', 'dma_admission_hook', 'dma_ccr_call'))
    found = set()
    added = []
    for section in sections:
        name = names[section[0]:].split(b'\0', 1)[0].decode().removeprefix('.')
        if name not in selected:
            continue
        _, _, _, address, offset, length, *_ = section
        after = bytearray(encoded[offset:offset + length])
        if name == 'payload':
            if address != 0x40274404 or length > 0x464 or after[4:8] != bytes(4):
                raise SystemExit('unexpected payload or boot-local endpoint literal')
            struct.pack_into('<I', after, 4, a.endpoint or 0)
        before = stock[address - 0x40000000:address - 0x40000000 + length]
        if len(before) != length or before == after:
            raise SystemExit(f'invalid patch {name}')
        added.append(dict(name='d5_' + name, address=hex(address),
                          before_hex=before.hex(), after_hex=after.hex()))
        found.add(name)
    if found != selected:
        raise SystemExit(f'missing sections: {selected - found}')
    old = result['patches']
    for x in old:
        xa = int(x['address'], 0)
        xe = xa + len(bytes.fromhex(x['after_hex']))
        for y in added:
            ya = int(y['address'], 0)
            ye = ya + len(bytes.fromhex(y['after_hex']))
            if max(xa, ya) < min(xe, ye):
                raise SystemExit(f'capture/playback overlap: {x["name"]}/{y["name"]}')

    def guard(address, data):
        result['guards'].append(dict(address=hex(address), expected_hex=data.hex()))

    def word(address, value):
        guard(address, struct.pack('<I', value))

    if not a.speaker_only:
        word(a.input_controller, 0x401ee698)
        word(a.input_controller + 0x2c4, a.output_controller)
        word(a.output_controller, 0x401ee700)
        word(a.output_controller + 0x1f4, a.endpoint)
        word(a.endpoint, 0x401fdb24)
        guard(a.endpoint + 0x250, struct.pack('<II', a.source_ring, a.source_ring + 0xe4))
        guard(a.endpoint + 0x338, struct.pack('<II', 4, 8))
        word(a.source_ring, 0x4021d118)
        guard(a.source_ring + 32, b'audio_playback5\0')
    # Local ABI/implementation guards for the precise methods used by the
    # shim, all inside the independently validated shared NC sections.
    for address, length in [(0x4021d118, 96), (0x402981e4, 20),
                            (0x40298245, 115), (0x4029b800, 30),
                            (0x40308550, 25), (0x40308570, 25),
                            (0x40265c3c, 20), (0x40265a20, 12),
                            (0x40265ac7, 12)]:
        guard(address, stock[address - 0x40000000:address - 0x40000000 + length])
    if a.slots == 2:
        # The exact native DMA argument derivation, output counter geometry,
        # cache publication and serial slot programming underlying this shim.
        for address, length in [(0x40250898, 121), (0x40251b4c, 92),
                                (0x40251cd8, 66), (0x40251f00, 29),
                                (0x40251fae, 32), (0x40248144, 211),
                                (0x40274b64, 38)]:
            guard(address, stock[address - 0x40000000:address - 0x40000000 + length])
    result['capture_parent_profile'] = result['profile']
    rate_khz = a.sample_rate // 1000
    result['profile'] += f'-with-exclusive-d5-direct{rate_khz}'
    if a.slots == 2:
        result['profile'] += '-two-slots'
    result['qualification'] = f'UNTESTED boot-local direct{rate_khz} playback; NOT FLASHABLE; reboot-only rollback'
    result['restrictions'] += [
        f'D5 only:{rate_khz}kHz, S32_LE, stereo; no concurrent framework/other playback',
        f'Physical TDM runs{rate_khz}k with{768 // (a.slots * 4)}-frame blocks; FS log field is block geometry',
        'TAS2572 192kHz serial input is internally decimated to96kHz; no full96kHz acoustic-band claim',
        'Playback bypasses H0/SRC/protection: use low-level stimulus only',
        'Do not reuse runtime pointers after any AoC reset or reboot',
        'Cold reboot is mandatory before restarting ordinary audio services',
    ]
    result['direct_playback'] = dict(
        pcm_device=5, sample_rate=a.sample_rate, format='S32_LE', channels=2,
        bclk_hz=a.sample_rate * a.slots * 32, slots=a.slots, slot_bits=32,
        frames_per_half=768 // (a.slots * 4),
        dma_half_bytes=768, ap_read_bytes=768 * 2 // a.slots,
        expected_callback_seconds=(768 // (a.slots * 4)) / a.sample_rate,
        callback_clock_hz=38400000,
        callback_expected_ticks=38400000 * (768 // (a.slots * 4)) // a.sample_rate,
        callback_tolerance_ticks=3840,
        h0_and_src_bypassed=True, ring_sizes_changed=False,
        input_controller=hex(a.input_controller) if a.input_controller else None,
        output_controller=hex(a.output_controller) if a.output_controller else None,
        endpoint=hex(a.endpoint) if a.endpoint else None,
        source_ring=hex(a.source_ring) if a.source_ring else None,
        stats_address='0x40274440',
        stats_words=['callbacks', 'consumed_blocks', 'empty_blocks', 'geometry_refusals',
                     'last_available_bytes', 'not_running_blocks_subset_of_empty',
                     'bad_tx_geometry', 'bad_endpoint_class', 'bad_source_kind',
                     'bad_frame_bytes', 'bad_ring_class', 'bad_reader_identity',
                     'bad_capacity', 'bad_pointer_bounds_or_alignment',
                     'last_bad_value', 'geometry_refusals_while_endpoint_running'],
        host_advance_method='0x402981e4', host_irq_threshold_field='source_ring+0xd8')
    result['dynamic_pointer'] = dict(
        patch_name='d5_payload', byte_offset=4, address='0x40274408',
        input_controller_vtable='0x401ee698', output_controller_offset='0x2c4',
        output_controller_vtable='0x401ee700', endpoint_offset='0x1f4',
        endpoint_vtable='0x401fdb24', source_ring_offset='0x250',
        runtime_running_flag_offset='0x34a',
        reader_offset='0x254', source_kind_offset='0x338', source_kind=4,
        frame_bytes_offset='0x33c', frame_bytes=8,
        preflight_allowed_kind_frame_pairs=[[0, 0], [4, 8]],
        runtime_required_kind_frame_pair=[4, 8],
        preflight_unbound_ring_allowed_only_when=dict(
            source_kind=0, frame_bytes=0, source_ring=0, reader=0),
        runtime_zero_ring_or_reader='silence; no source virtual calls',
        source_ring_vtable='0x4021d118', reader_from_ring='0xe4',
        source_ring_name_offset=32, source_ring_name='audio_playback5')
    # No capture bytes are modified; the existing coherent cache wrapper
    # activates all instructions only after the combined staging completes.
    # Stage the replacement body before publishing any branch to it. The
    # existing applier preserves this order except for its RAW gate/rate sites.
    result['patches'] = old + sorted(added, key=lambda v: (
        v['name'] != 'd5_payload', int(v['address'], 0)))
    output = a.output_dir / 'combined-manifest.json'
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
