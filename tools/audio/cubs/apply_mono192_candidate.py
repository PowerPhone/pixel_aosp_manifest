#!/usr/bin/env python3
"""Apply an exclusive, reboot-volatile Cubs mono or explicit RAW3 experiment.

Leaves Android audio services STOPPED on success. Use only the Cubs direct
matching capture/duplex harness next, then reboot to restore ordinary firmware.
An explicit --manifest is required: historical profiles include known failures.
No hashes, image writes, or claims of physical 192-kHz qualification.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time

REPO = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--serial', required=True)
p.add_argument('--output-dir', type=Path, required=True)
p.add_argument('--manifest', type=Path, required=True,
               help='Explicit exclusive prototype manifest; there is no implicit safe/default profile')
p.add_argument('--speaker-manifest', type=Path, help='Optional exclusive D5 direct96/direct192 template; bind only to guarded objects from this boot')
p.add_argument('--adb', type=Path, default=REPO / 'work/toolchains/platform-tools-37.0.1/platform-tools/adb')
p.add_argument('--adb-server-port', type=int, default=5038)
p.add_argument('--helper', default='/data/local/tmp/cubs_aoc_diag')
a = p.parse_args()
a.output_dir.mkdir(parents=True, exist_ok=False)
adb = [str(a.adb), '-P', str(a.adb_server_port), '-s', a.serial]
events = (a.output_dir / 'transactions.jsonl').open('x')
RAW3_PROFILE = 'cubs-15876290-polygon-exclusive-d10-raw3-packed192-candidate'
RAW3_MARKER = '/dev/powerphone-cubs-raw3-192'
RAW3_KERNEL_MARKER = '/dev/powerphone-cubs-raw3-kernel-admission'
RAW3_MARKER_CONTENT = 'channels=3\nrate=192000\nformat=S16_LE\nlogical_mics=0,1,2\n'
RAW3_KERNEL_GUARD = '01ec40b9ff430039ff0700f93f100071ea060054'


def command(argv, timeout=15, check=True):
    result = subprocess.run(adb + argv, capture_output=True, text=True,
                            timeout=timeout, env={**os.environ, 'ADB_LIBUSB': '1'})
    events.write(json.dumps(dict(time=time.time(), argv=argv, returncode=result.returncode,
                                stdout=result.stdout, stderr=result.stderr)) + '\n')
    events.flush()
    if check and result.returncode:
        raise RuntimeError(f'{argv}: {result.returncode}: {result.stdout} {result.stderr}')
    return result


def shell(script, **kwargs):
    return command(['shell', script], **kwargs)


def read(core, address, size):
    text = shell(shlex.join([a.helper, '--core', str(core), 'dump', hex(address), str(size)])).stdout.strip()
    data = bytes.fromhex(text)
    if len(data) != size:
        raise RuntimeError(f'short memory read at {address:#x}')
    return data


def nc(address, size):
    # Only independently proven MB2/MB3 mappings are admitted by this profile.
    if not 0x40200000 <= address < address + size <= 0x40400000:
        raise RuntimeError(f'address outside reviewed shared sections: {address:#x}')
    return address + 0x40000000


def write_bytes(address, data):
    offset = 0
    while offset < len(data):
        at = nc(address + offset, 1)
        width = next(n for n in (4, 2, 1) if at % n == 0 and len(data) - offset >= n)
        value = int.from_bytes(data[offset:offset + width], 'little')
        shell(shlex.join([a.helper, '--core', '2', 'write-raw', str(width * 8), hex(at), hex(value)]))
        offset += width


def generation():
    return shell('cat /proc/sys/kernel/random/boot_id; cat /sys/devices/platform/a800000.aoc/restart_count; cat /sys/devices/platform/a800000.aoc/coredump_count').stdout


def capture_geometry(manifest):
    """Do not infer multichannel safety merely from a channels field."""
    profile = manifest.get('profile', '')
    geometry = manifest.get('geometry', {})
    if profile == RAW3_PROFILE:
        required = dict(channels=3, native_rate_enum=7, dma_frames=96,
                        native_receiver_control_bit1=0, packed_block_bytes=576,
                        source_ring_capacity_bytes=1536, source_padded_bank_bytes=768,
                        producer_raw_destination=3, skipped_normal_destination=2,
                        stage_offset='0x524', stage_end_exclusive='0x764',
                        new_allocations=False, s32_intermediate_staging=False)
        if any(geometry.get(key) != value for key, value in required.items()):
            raise RuntimeError('RAW3 profile has unreviewed capture geometry')
        return dict(channels=3, rate=192000, format='S16_LE', logical_mics=[0, 1, 2],
                    capability_marker=RAW3_MARKER)
    mono_profiles = {
        'cubs-15876290-polygon-exclusive-d10-mono192-direct-candidate',
        'cubs-15876290-polygon-exclusive-d10-native96-clock-control',
        'cubs-15876290-polygon-exclusive-d10-native192-edge0-control',
        *[f'cubs-15876290-polygon-exclusive-d10-native192-rfactor{factor}-control'
          for factor in (2, 3, 6, 8)],
        'cubs-15876290-polygon-exclusive-d10-native192-rfactor6-clock4266-control',
    }
    if profile not in mono_profiles or geometry.get('channels', 1) != 1:
        raise RuntimeError('unknown capture profile; neither reviewed mono nor explicit RAW3')
    return dict(channels=1, rate=192000, format='S16_LE', logical_mics='one selected mic',
                capability_marker='/dev/powerphone-cubs-mono192')


def require_raw3_kernel_admission(boot_id):
    """Prefer device module bytes; otherwise require explicit boot provenance.

    The fallback is known-flash authorization, NOT live-text verification.
    First-stage module files disappear on the inspected device after boot.
    """
    result = shell('''
set -eu
state=$(cat /sys/module/aoc_alsa_dev_util/initstate)
[ "$state" = live ] || exit 2
printf '%s\\n' "$state"
for module in /lib/modules/aoc_alsa_dev_util.ko /vendor/lib/modules/aoc_alsa_dev_util.ko /vendor_dlkm/lib/modules/aoc_alsa_dev_util.ko /system_dlkm/lib/modules/aoc_alsa_dev_util.ko; do
  [ -r "$module" ] || continue
  printf '%s\\n' "$module"
  dd if="$module" bs=1 count=20 2>/dev/null | od -An -v -tx1 | tr -d ' \\n'
  printf '\\n'
  dd if="$module" bs=1 skip=220548 count=20 2>/dev/null | od -An -v -tx1 | tr -d ' \\n'
  printf '\\n'
  exit 0
done
printf 'MODULE_FILE_UNAVAILABLE\\n'
''').stdout.splitlines()
    if not result or result[0] != 'live':
        raise RuntimeError('matching AoC ALSA module is not live')
    if len(result) == 4:
        header = bytes.fromhex(result[2])
        if (len(header) != 20 or header[:7] != b'\x7fELF\x02\x01\x01'
                or int.from_bytes(header[16:18], 'little') != 1
                or int.from_bytes(header[18:20], 'little') != 183
                or result[3] != RAW3_KERNEL_GUARD):
            raise RuntimeError('on-device module does not have exact RAW3 admission bytes')
        proof = dict(proof_method='narrow-on-device-module-read', boot_id=boot_id,
                     module_state='live', source_path=result[1],
                     guard_file_offset='0x35d84', guard_hex=result[3],
                     live_module_text_verified=False)
    elif result == ['live', 'MODULE_FILE_UNAVAILABLE']:
        marker = shell('test "$(stat -c %u:%a ' + RAW3_KERNEL_MARKER + ')" = 0:600 && cat '
                       + RAW3_KERNEL_MARKER).stdout
        fields = {}
        for line in marker.splitlines():
            key, separator, value = line.partition('=')
            if not separator or key in fields:
                raise RuntimeError('malformed RAW3 kernel admission marker')
            fields[key] = value
        expected = dict(boot_id=boot_id, module='aoc_alsa_dev_util',
                        guard_file_offset='0x35d84', guard_hex=RAW3_KERNEL_GUARD,
                        provenance='operator-flashed-raw3-image')
        if (set(fields) != set(expected) | {'source_path'}
                or any(fields.get(key) != value for key, value in expected.items())
                or not fields.get('source_path', '').startswith('/')):
            raise RuntimeError('missing/wrong-boot RAW3 known-flash authorization')
        proof = dict(proof_method='operator-known-flash-authorization', module_state='live',
                     live_module_text_verified=False, **fields)
    else:
        raise RuntimeError('unexpected RAW3 kernel admission response')
    (a.output_dir / 'raw3-kernel-admission-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
    return proof


def shared_word(address):
    return int.from_bytes(read(2, nc(address, 4), 4), 'little')


def resolve_speaker_endpoint():
    """Resolve the observed Cubs pointer chain, rejecting any changed layout."""
    root = shared_word(0x4035ca84)
    if shared_word(0x4035d00c) != root or shared_word(root) != 0x401ee698:
        raise RuntimeError('AudioInCtrl roots/vtable differ')
    output = shared_word(root + 0x2c4)
    if shared_word(output) != 0x401ee700:
        raise RuntimeError('AudioOutCtrl vtable differs')
    endpoint = shared_word(output + 0x1f4)
    if shared_word(endpoint) != 0x401fdb24:
        raise RuntimeError('D5 AudioEntrypoint vtable differs')
    geometry = (shared_word(endpoint + 0x338), shared_word(endpoint + 0x33c))
    # A fresh, unopened D5 has the observed pair (0,0). The speaker worker
    # separately requires (4,8) after ALSA configures stereo S32 at runtime.
    if geometry not in ((0, 0), (4, 8)):
        raise RuntimeError('D5 source kind/bytes per frame differs')
    ring, reader = shared_word(endpoint + 0x250), shared_word(endpoint + 0x254)
    if geometry == (0, 0) and (ring, reader) == (0, 0):
        pass  # Fresh D5 is not bound until EP_SETUP; runtime guards require it.
    else:
        if shared_word(ring) != 0x4021d118 or reader != ring + 0xe4:
            raise RuntimeError('D5 AP ring/reader identity differs')
        name = read(2, nc(ring + 0x20, 16), 16).split(b'\0', 1)[0]
        if name != b'audio_playback5':
            raise RuntimeError(f'not D5 host service: {name!r}')
    return dict(audio_input=root, audio_output=output, endpoint=endpoint,
                ring=ring, reader=reader)


mutated = False
quiesced = False
success = False
initial = ''
try:
    identity = shell('id -u; getprop ro.product.device; getprop sys.boot_completed').stdout.split()
    if identity != ['0', 'cubs', '1']:
        raise RuntimeError(f'require root, booted Cubs: {identity}')
    initial = generation()
    (a.output_dir / 'generation-before.txt').write_text(initial)
    # Require a fresh boot with no earlier PCM reads. Caller performs the reboot;
    # this explicit operational precondition keeps the initial wrapper cave cold.
    manifest = json.loads(a.manifest.read_text())
    capture = capture_geometry(manifest)
    raw3 = capture['channels'] == 3
    manifest['requested_capture'] = capture
    if raw3:
        if initial.splitlines()[1:] != ['0', '0']:
            raise RuntimeError('RAW3 requires a fresh boot with AoC restart/coredump0/0')
        manifest['kernel_admission_proof'] = require_raw3_kernel_admission(initial.splitlines()[0])
    speaker = json.loads(a.speaker_manifest.read_text()) if a.speaker_manifest else None
    speaker_patches = speaker['patches'] if speaker else []
    patches = manifest['patches']
    by_name = {entry['name']: entry for entry in patches}
    if len(by_name) != len(patches) or 'cache_wrapper' not in by_name:
        raise RuntimeError('need complete coherent-wrapper candidate')
    raw3_bodies = ('producer_sample_cave', 'producer_missing_cave',
                   'producer_destination_cave', 'producer_post_cave',
                   'packed_stage', 'packed_publish_entry')
    raw3_activations = ('normal_stage_skip', 'producer_destination_hook',
                       'producer_missing_hook', 'producer_sample_hook',
                       'producer_post_hook', 'raw_three_admission')
    if raw3 and any(name not in by_name for name in raw3_bodies + raw3_activations):
        raise RuntimeError('incomplete RAW3 body/hook/admission patch set')
    vote_bodies = ('raw_mcps_enable_cave', 'raw_mcps_disable_cave')
    vote_hooks = ('raw_mcps_enable_hook', 'raw_mcps_disable_hook')
    vote = manifest.get('raw_mcps_vote_control')
    if vote is not None:
        expected_vote = dict(raw_type=2, stock_mcps=28, candidate_mcps=112,
                             paired_enable_disable=True, code_immediates_only=True,
                             kernel_timeout_changed=False)
        if vote != expected_vote or any(name not in by_name for name in vote_bodies + vote_hooks):
            raise RuntimeError('unreviewed or incomplete paired RAW MCPS112 control')
    elif any(name in by_name for name in vote_bodies + vote_hooks):
        raise RuntimeError('RAW MCPS hooks require explicit paired-control metadata')
    wrapper = by_name['cache_wrapper']
    wrapper_after = bytes.fromhex(wrapper['after_hex'])
    if wrapper_after[12:15] != bytes.fromhex('364100'):
        raise RuntimeError('non-leaf cache wrapper must use reviewed ENTRY32')
    quiesced = True
    shell('''
set -eu
[ "$(getprop init.svc.audioserver)" = stopped ] || stop audioserver
sleep .3
i=0; stable=0
while [ "$stable" -lt 5 ]; do
  if [ "$(getprop init.svc.audioserver):$(getprop init.svc.vendor.audio-hal-aidl)" = stopped:stopped ]; then
    stable=$((stable+1))
  else
    stable=0
    [ "$(getprop init.svc.audioserver)" = stopped ] || stop audioserver
    stop vendor.audio-hal-aidl
  fi
  i=$((i+1)); [ "$i" -lt 100 ] || exit 2; sleep .1
done
''')
    owners = shell('ls -ld /proc/[0-9]*/fd/* 2>/dev/null', check=False).stdout
    (a.output_dir / 'fd-owners.txt').write_text(owners)
    if ' -> /dev/snd/pcmC0D' in owners:
        raise RuntimeError('another process still owns a card0 PCM')
    for control in ['MIC0', 'MIC1', 'MIC2', 'US Record Enable',
                    'EP1 TX Mixer INTERNAL_MIC_TX', 'EP2 TX Mixer INTERNAL_MIC_TX',
                    'EP3 TX Mixer INTERNAL_MIC_TX', 'EP4 TX Mixer INTERNAL_MIC_TX',
                    'EP5 TX Mixer INTERNAL_MIC_TX', 'EP5 TX Mixer INTERNAL_MIC_US_TX',
                    'EP6 TX Mixer INTERNAL_MIC_TX']:
        value = shell(shlex.join(['tinymix', '-D', '0', '-v', '--', control])).stdout.strip()
        if value != 'Off':
            raise RuntimeError(f'active route/control: {control}={value}')
    for table, bits in [(0x40009008, 0x1c2e), (0x4000a008, 0x1c32)]:
        expected = b''.join(((mb << 20) | bits).to_bytes(4, 'little') for mb in (2, 3))
        if read(1, table, 8) != expected:
            raise RuntimeError('Cubs A32 WB/NC mapping differs')
    if speaker:
        playback_rate = speaker.get('direct_playback', {}).get('sample_rate')
        if playback_rate not in (96000, 192000):
            raise RuntimeError('speaker template must declare direct96 or direct192')
        playback_slots = speaker['direct_playback'].get('slots')
        if playback_slots not in (2, 4) or (playback_slots == 2 and playback_rate != 192000):
            raise RuntimeError('speaker slots must be four, or two for direct192')
        resolved = resolve_speaker_endpoint()
        literal = 0x40274408
        containing = [entry for entry in speaker_patches
                      if int(entry['address'], 0) <= literal and
                      literal + 4 <= int(entry['address'], 0) + len(bytes.fromhex(entry['after_hex']))]
        if len(containing) != 1 or int(containing[0]['address'], 0) != 0x40274404:
            raise RuntimeError('speaker template lacks reviewed payload/literal')
        payload = containing[0]
        data = bytearray.fromhex(payload['after_hex'])
        if data[4:8] != b'\0' * 4:
            raise RuntimeError('speaker template already contains a boot-local pointer')
        data[4:8] = resolved['endpoint'].to_bytes(4, 'little')
        payload['after_hex'] = data.hex()
        manifest['speaker_profile'] = speaker['profile']
        manifest['direct_playback'] = speaker['direct_playback']
        manifest['resolved_speaker_objects'] = {key: hex(value) for key, value in resolved.items()}
        patches.extend(speaker_patches)
        manifest['guards'].extend(speaker.get('guards', []))
        spans = sorted((int(entry['address'], 0), len(bytes.fromhex(entry['after_hex']))) for entry in patches)
        if any(left + size > right for (left, size), (right, _) in zip(spans, spans[1:])):
            raise RuntimeError('capture and speaker patch regions overlap')
    (a.output_dir / 'applied-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for entry in manifest['guards']:
        at = int(entry['address'], 0)
        expected = bytes.fromhex(entry['expected_hex'])
        if read(2, nc(at, len(expected)), len(expected)) != expected:
            raise RuntimeError(f'stock guard differs: {at:#x}')
    for entry in patches:
        at = int(entry['address'], 0)
        expected = bytes.fromhex(entry['before_hex'])
        if read(2, nc(at, len(expected)), len(expected)) != expected:
            raise RuntimeError(f'not exact stock at {entry["name"]}; reboot before retry')
    if generation() != initial:
        raise RuntimeError('generation changed during guards')
    print(f'Applying {len(patches)} exclusive capture regions.', flush=True)
    # Mono closes its filter gate before replacing that filter's body.
    # RAW3 instead publishes all replacement bodies first; its retained old
    # stage gate is unreachable after packed_stage returns. Stream2 is last.
    order = [] if raw3 else [by_name['stage_gate']]
    # Publish the whole speaker worker/literals before either entry hook.
    order += [entry for entry in speaker_patches if int(entry['address'], 0) == 0x40274404]
    if raw3:
        order += [by_name[name] for name in raw3_bodies]
        order += [by_name['stage_gate']]
    delayed = set(raw3_bodies + raw3_activations) if raw3 else set()
    if vote is not None:
        order += [by_name[name] for name in vote_bodies]
        delayed.update(vote_bodies + vote_hooks)
    order += [entry for entry in patches if entry['name'] not in ({'stage_gate', 'stream_rate'} | delayed)
              and not (speaker and int(entry['address'], 0) == 0x40274404)]
    # The cost hooks are installed only after both caves and the RAW direct
    # return that makes their former processor-body space unreachable.
    if vote is not None:
        order += [by_name[name] for name in vote_hooks]
    if raw3:
        order += [by_name[name] for name in raw3_activations]
    order += [by_name['stream_rate']]
    # This tmpfs marker also survives an AoC-only reset: ordinary Android audio
    # must not restart against this exclusive prototype or a lost generation.
    shell('umask 077; touch /dev/powerphone-cubs-mono192')
    if speaker:
        shell(f'umask 077; touch /dev/powerphone-cubs-direct{playback_rate // 1000}')
        shell(f'umask 077; printf "%s\\n" {playback_slots} > /dev/powerphone-cubs-tdm-slots')
    mutated = True
    for entry in order:
        write_bytes(int(entry['address'], 0), bytes.fromhex(entry['after_hex']))
    dispatch = 0x402392b4
    # A native dump drains the debug service to EAGAIN before its correlated
    # request. Do this after staging, before arming HD, to discard old replies.
    if read(2, nc(dispatch, 4), 4) != bytes.fromhex('8cbf2740'):
        raise RuntimeError('HD gain dispatch changed before arming')
    wrapper_entry = int(wrapper['address'], 0) + 12
    write_bytes(dispatch, wrapper_entry.to_bytes(4, 'little'))
    print('Synchronizing F1 caches via the temporary HD handler.', flush=True)
    remote = '/data/local/tmp/cubs-cache-flush-' + str(os.getpid())
    response = shell('''
set -u
cat /dev/acd-debug > %s & reader=$!
sleep .05
tinymix 'HD Mic gain (cB)' 0
mix_status=$?
sleep .3
kill "$reader" 2>/dev/null
wait "$reader" 2>/dev/null
echo MIXER_EXIT=$mix_status
cat %s
''' % (shlex.quote(remote), shlex.quote(remote)), timeout=10, check=False)
    # Always restore the host-published hook before interpreting its reply.
    write_bytes(dispatch, bytes.fromhex('8cbf2740'))
    (a.output_dir / 'cache-flush-debug.txt').write_text(response.stdout + response.stderr)
    # Keep kernel evidence for diagnosis, but only fresh debug completion
    # qualifies this call; tinymix/kernel process success is insufficient.
    kernel = shell('dmesg').stdout
    (a.output_dir / 'dmesg-after-flush.txt').write_text(kernel)
    if not re.search(r'(?:0x)?12a4[^\n]*(?:rc[:= ]+64|err(?:or)?[:= ]+64|ret(?:urn)?[:= ]+64)', response.stdout, re.I):
        raise RuntimeError('cache wrapper completion64 not established; see saved evidence')
    for entry in patches:
        expected = bytes.fromhex(entry['after_hex'])
        at = int(entry['address'], 0)
        if read(2, nc(at, len(expected)), len(expected)) != expected:
            raise RuntimeError(f'post-flush patch bytes differ: {entry["name"]}')
    if read(2, nc(dispatch, 4), 4) != bytes.fromhex('8cbf2740'):
        raise RuntimeError('HD gain dispatch not restored')
    if generation() != initial:
        raise RuntimeError('AoC generation changed during application')
    (a.output_dir / 'generation-after.txt').write_text(generation())
    # A delayed Android stop trigger may restart the HAL. Stop it last again
    # before handing the exclusive session to the capture wrapper.
    shell('[ "$(getprop init.svc.audioserver)" = stopped ] || stop audioserver; '
          'sleep .3; stop vendor.audio-hal-aidl; sleep .5; '
          'test "$(getprop init.svc.audioserver):$(getprop init.svc.vendor.audio-hal-aidl)" = stopped:stopped')
    if raw3:
        shell('umask 077; printf %s ' + shlex.quote(RAW3_MARKER_CONTENT)
              + ' > ' + RAW3_MARKER)
    success = True
    print(f'EXPERIMENT_APPLIED profile={manifest["profile"]}: '
          f'audio services stopped; strict {capture["channels"]}-channel D10 only; reboot after testing. '
          'The nominal PCM request is not a physical-rate qualification.')
except Exception as exc:
    print(f'FAILED: {exc}', flush=True)
    raise
finally:
    if not success and mutated:
        print('Rebooting to discard uncertain volatile firmware changes.', flush=True)
        command(['reboot'], timeout=10, check=False)
    elif not success and quiesced:
        shell('start vendor.audio-hal-aidl; start audioserver', check=False)
    events.close()
