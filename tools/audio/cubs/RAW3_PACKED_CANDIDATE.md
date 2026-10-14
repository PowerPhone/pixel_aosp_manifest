# Cubs simultaneous three-microphone candidate

This is an **exclusive RAW3 prototype**, not a qualified image or framework
profile. The original MCPS28 manifest failed its real start-response test;
it is retained for history, not recommended as the current recipe. The
separate [MCPS112 variant](RAW_MCPS112_CONTROL.md) passed simultaneous
three-channel 30-second tone continuity with both speakers on this device.
That result does not establish 96-kHz acoustic bandwidth or Android API support.
The separate mono receiver-edge0 manifest is preserved. Only the parent
hardware session should apply a selected profile, after a cold boot with
ordinary audio clients and services quarantined.

Build the real Xtensa patch payload and exact stock-byte manifest:

```sh
python3 tools/audio/cubs/build_raw3_packed_manifest.py
```

Output is `tools/audio/manifests/cubs_d10_raw3_packed_candidate.json`.
This builds the historical geometry-only baseline. For the measured
MCPS112 profile, subsequently run the separate variant builder documented
in [RAW_MCPS112_CONTROL.md](RAW_MCPS112_CONTROL.md).
The builder assembles `tools/audio/asm/cubs_d10_raw3_packed_candidate.S` and
its linker map, then combines the non-overlapping prerequisites from the
unchanged mono native192 edge0 profile. There are no new allocations, no
firmware signing, no device operations, and no hashes.

## Why combining the AP planes was insufficient

The real v3 SSCD snapshot independently identified APInputProcessor
`0x403d4948`, with normal ring at `+0x144` and RAW ring at `+0x148`.
Both source rings have capacity `0x600`, hence a padded producer bank of
`0x300` bytes. PDM object's destination table at `+0x140` maps destination2
to that normal ring and destination3 to that RAW ring. These heap addresses
are evidence from that boot, not constants to reuse on another boot.

At `0x4025ef19`, the ordinary producer copies96 frames times channel count
as S32. Three channels require1152 bytes, exceeding the768-byte bank before
the AP stager ever runs. The subsequent producer publication at
`0x4025ee1e..0x4025ee35` still commits half the ring capacity. Enlarging only
the AP stage would therefore corrupt the upstream ring.

## Candidate path

- PDM destination3, native enum7, exactlythree channels: copy each sample's
  upper16 bits directly into interleaved S16. The valid-source and
  missing-source/zero-fill loops both use six-byte frame stride. Other
  destination/rate/channel combinations retain their original S32 loops.
- Destination2 is skipped for native enum7/three-channel descriptors. Its
  unconsumed normal ring would otherwise overflow as well. The AP normal
  staging branch is bypassed in this exclusive profile.
- Packed destination3 skips the per-destination S32 microphone-compensation
  block. It retains the original padded768-byte producer commit.
- AP RAW staging uses its original reader, rewinds to the latest half-bank,
  copies exactly576 packed bytes to `this+0x524`, then releases the original
 768-byte source bank. The stage ends at `this+0x764`, below metadata at
 `this+0x824`. No S32 duplicate planes or legacy SRC/effect processors run.
- The converter entry requires producer channels3 and requested RAW
  channels3, then enters the existing AP-ring publisher at `0x4027b715`.
  Its inherited byte-count patch yields `3*3*64 = 576` bytes each callback.

The producer helpers reuse only the old AP-stager body made unreachable by
the new stager entry/return. The coherent cache wrapper remains at
`0x4027b240` with entry `0x4027b24c`; its bytes and protocol are unchanged.
There is no overlap with the direct speaker worker at `0x40274404`.

## Both channel-admission guards are required

Firmware `0x4027a618` changes unsigned rejection of `(channels-1)>=2` to
`>=3`, admitting3 but rejecting0 and4+. This is the firstsix bytes of the
old firmware identity anchor, so the new manifest separately guards the
remaining10 bytes and carries exact original bytes in the admission patch.

The matching live Cubs kernel module still rejects3 in
`aoc_raw_capture_trigger`, not its general channel metadata:

| Location | Original | Candidate |
| --- | --- | --- |
| `.text+0x1035c`, file `0x35d90` | `3f0c0071`, `cmp w1,#3` | `3f100071`, `cmp w1,#4` |

The following signed `b.ge` stays unchanged. Command `0x1272` is nine bytes,
with the requested channel count in byte8; stop remains command `0x126a`.
Apply this admission change to the matching capture/playback-admitted
module, retaining those already required changes and using a new output.
The firmware manifest does not change or flash a kernel module.

For a new guarded module output, leaving the already admitted input intact:

```sh
python3 tools/audio/cubs/patch_raw3_admission.py \
  --input /path/to/current-admitted/aoc_alsa_dev_util.ko \
  --output /path/to/new-raw3/aoc_alsa_dev_util.ko
```

Package that result with the existing Cubs vendor-kernel-boot preparation
workflow. The script refuses an existing output and changes only the
four-byte comparison instruction; it does not install or flash anything.

The actual build prepared on2026-09-22 uses the currently flashed playback
admission image and its ramdisk as its explicit baseline:

```sh
python3 tools/audio/cubs/patch_raw3_admission.py \
  --input work/audio-research/cubs/playback-admission-ramdisk-20260922/lib/modules/aoc_alsa_dev_util.ko \
  --output work/audio-research/cubs/aoc_alsa_dev_util.capture192-playback-raw3-admission.ko
cp -a work/audio-research/cubs/playback-admission-ramdisk-20260922 \
  work/audio-research/cubs/raw3-admission-ramdisk-20260922
cp -a work/audio-research/cubs/aoc_alsa_dev_util.capture192-playback-raw3-admission.ko \
  work/audio-research/cubs/raw3-admission-ramdisk-20260922/lib/modules/aoc_alsa_dev_util.ko
bash tools/audio/cubs/repack-vendor-kernel-boot.sh \
  work/audio-research/cubs/playback-admission-kernel-20260922/vendor_kernel_boot.img \
  work/audio-research/cubs/raw3-admission-ramdisk-20260922 \
  work/audio-research/cubs/raw3-admission-kernel-20260922
```

Use fresh destinations on repetition. Both earlier admission images and
ramdisks are preserved. The new image widens only the RAW guard; mono
capture remains admitted. Required host tools are Python3, GNU coreutils,
`cpio`, `lz4`, and existing Cubs AOSP host `unpack_bootimg`, `mkbootimg`,
`avbtool`; firmware assembly additionally uses the recovered Sky1 Xtensa
assembler/linker. The repacker adds image-format AVB footer metadata, not a
hash-verification/attestation pass. No hardware qualification is implied.

## Apply preflight and markers

`apply_mono192_candidate.py` now recognizes the exact RAW3 profile and
geometry, while retaining the existing mono profiles. RAW3 requires fresh
AoC counters0/0, a live `aoc_alsa_dev_util` module, and admission evidence
before any audio-service or firmware mutation. If the module file remains
visible, it reads only the ELF header and20-byte instruction neighborhood.

On the inspected phone, first-stage `/lib/modules` files disappear after
boot and no readable module-text interface is available. For this case,
the operator who actually flashed the prepared RAW3 image may publish the
following **known-flash authorization** after confirming the new boot.
This is explicitly not live-text verification or cryptographic attestation.
Do not create it after flashing an older image merely to bypass the check.

```sh
ADB=work/toolchains/platform-tools-37.0.1/platform-tools/adb
SERIAL=YOUR_CUBS_SERIAL
"$ADB" -P 5038 -s "$SERIAL" shell '
set -eu
test "$(id -u)" = 0
test "$(cat /sys/module/aoc_alsa_dev_util/initstate)" = live
umask 077
printf "%s\n" \
  "boot_id=$(cat /proc/sys/kernel/random/boot_id)" \
  module=aoc_alsa_dev_util \
  guard_file_offset=0x35d84 \
  guard_hex=01ec40b9ff430039ff0700f93f100071ea060054 \
  provenance=operator-flashed-raw3-image \
  source_path=/mnt/wsl/aosp_workspace/pixel_aosp_manifest/work/audio-research/cubs/raw3-admission-kernel-20260922/vendor_kernel_boot.img \
  > /dev/powerphone-cubs-raw3-kernel-admission
chmod 600 /dev/powerphone-cubs-raw3-kernel-admission
'

python3 tools/audio/cubs/apply_mono192_candidate.py \
  --serial "$SERIAL" \
  --manifest tools/audio/manifests/cubs_d10_raw3_packed_mcps112_control.json \
  --output-dir work/audio-research/cubs/YOUR_NEW_RAW3_APPLY_DIRECTORY
```

The admission marker must be owned byroot, mode0600, and contain exactly
those six unique fields. Its boot UUID must match the current device.
`source_path` records the image actually flashed. The applier saves this
provenance as `raw3-kernel-admission-proof.json`, explicitly setting
`live_module_text_verified=false`. A readable on-device module that has
the old comparison rejects immediately; it cannot use marker fallback.

RAW3 cave bodies and replacement stage/publisher are installed before any
new producer hooks. Channel admission and producer activation follow;
Stream2 rate activation is last. Existing cache completion, post-write
guards, AoC generation checks, and failure reboot remain in force.
`--manifest` is mandatory; the applier no longer defaults to the historical
receiver-edge1 profile that produced corrupted microphone samples.

The existing `/dev/powerphone-cubs-mono192` marker remains a quarantine flag
for compatibility; it does **not** imply that mono is safe in a RAW3 session.
Only after successful cache completion, firmware postguards, and confirmed
stopped services does the applier publish
`/dev/powerphone-cubs-raw3-192`, with exactly:

```text
channels=3
rate=192000
format=S16_LE
logical_mics=0,1,2
```

The capture/duplex scripts require both flags for `--mic all`, reject mono
requests in a RAW3 session, and reject any AoC restart/coredump. Capability
markers are not permission to continue after an AoC-only reset.

## Actual results and remaining tests

The hardware launcher must select mic list `0 1 2 -1`, channel selector
`Three`, and D10 S16_LE three-channel192000 capture. The previous strict
mono launcher marker must not be reused without its explicit RAW3 support.
For each new variant, begin with a short capture, inspect all three
waveforms, and verify real tone frequency/cadence and continuity on each
channel. Do not infer success
from channel count, WAV headers, or sample counts alone. Preserve failures.

The measured MCPS112 variant captured 560640 frames in the three-second
quiet trial and 6704640 frames in each 35-second duplex capture: a fixed
80-ms startup deficit, rather than the earlier growing sample loss.
All three channels retained the full approximately 30-second 20731-Hz
tone from each speaker, with zero detected phase events, amplitude
dropouts, or clipping. Exact metrics and evidence paths are in the MCPS
document. These are specific real measurements, not a guarantee for
untested rates, bandwidth, boot cycles, or concurrent clients.

This prototype is RAW3-only: cold reboot back to the mono profile before
using mono/stereo or ordinary framework capture. Wider ultrasonic
bandwidth, other loads, repeated-boot behavior, and framework/API
integration require their own hardware qualification.
