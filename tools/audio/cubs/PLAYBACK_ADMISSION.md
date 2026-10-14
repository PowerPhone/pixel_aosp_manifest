# Cubs ordinary D5 playback admission experiment

This is **not a qualified 96/192 kHz speaker profile**. It fixes two kernel
admission/encoding limits so the real firmware path can be tested. It does not
change the speaker TDM clock, sample geometry, SRC/effects, DMA, amplifier
tuning or IRQ behavior. Start hardware testing at 96 kHz. TAS2572 can accept
192 kHz input, but has its own internal downsampling/bandwidth limits; see
[the capability investigation](../../../work/audio-research/cubs/tas2572-capability-20260922.md).

## Exact target and scope

Input: the live Cubs `6.12.92-android16-6-maybe-dirty-4k` module with the prior
capture192 admission applied, not the factory donor or a Frankel module:

```
work/audio-research/cubs/aoc_alsa_dev_util.capture192-admission.ko
```

PCM **D5** is labelled **EP6 PB**, but its firmware entrypoint remains **5**.
No endpoint renumbering is performed. The shared normal PCM capability template
already admits 192 kHz because of the capture experiment.

| Module location | Change |
| --- | --- |
| `.data+0xaa94`, `aoc_dai_drv` EP6 PB | Rate mask `0xfe` → `0x14fe`: add 96 and 192 kHz only |
| `.data+0xc704`, `aoc_dai_drv` TDM_0_RX | Same two rate bits; all other backend masks unchanged |
| `.text+0xd4cc`, `aoc_audio_set_params` | Branch from the default playback-rate encoder to D5-only exact-rate handling |
| Appended `.text+0x16d00`, 44 bytes | D5 96000 → enum6, 192000 → enum7; otherwise retain enum5 |

Existing 8/16/44.1 kHz branches and the 48 kHz default survive. All non-D5
playback streams keep the original encoder behavior. Capture192 patch bytes,
capture masks, every original symbol/relocation, entrypoint indices and service
channel indices survive. The TAS module already advertises mask `0x1ffe`, so
it is not modified.

The patcher appends instructions to `.text` instead of overwriting another
function. A 4096-byte insertion preserves subsequent section alignment and
updates section file offsets and `e_shoff`. Original executable addresses,
symbol values and relocation contents are unchanged. Both branches return to
`.text+0xd4d0` without changing stack state or making a new indirect/CFI call.
The exact local guards are version selectors, not whole-file hashes.

## Why D28 is not remapped to source14

In the real failed D28 trial, the mixer successfully bound **source14
Ultrasound** to **sink0 Speaker**, but EP_SETUP `0x1406` and EP_ENABLE `0x1401`
rejected channel28. Threshold command `0x1462` accepted channel28 and selected
the `audio_ultrasonic` service. Therefore changing the shared entrypoint field
would also redirect a currently correct SRAM-threshold command.

The matching firmware confirms separate namespaces. Its normal-mode setup
recognizes channel28 when choosing the ultrasound ring, but the final setup
dispatch at `0x4023f04c..0x4023f466` accepts ordinary channels below8 and channel10,
not channel14 or28. A guessed 28→14 translation would not repair this.
D28 remains unchanged in this candidate; ordinary D5 is independently supported.

Evidence: [the actual failed trial log](../../../work/audio-research/cubs/speaker96-live2-20260922/logcat-after.txt)
at 23:44:48–49. The TAS driver receives 96000, while F1 explicitly reports
48 samples, 48 kHz and TDM clock6144 kHz/4 slots. Passing a high rate to the
amplifier driver is not proof that the physical bus changed.

## Build-only reproduction

Requires Python3, GNU AArch64 binutils, cpio, lz4 and the existing Cubs AOSP
host boot-image tools. Use a new output file/directory each time; the patcher
and repacker refuse existing destinations. No device, mocks or hashes are used.

```bash
python3 tools/audio/cubs/patch_playback_admission.py \
  work/audio-research/cubs/aoc_alsa_dev_util.capture192-admission.ko \
  work/audio-research/cubs/aoc_alsa_dev_util.capture192-playback-admission.ko

cp -a work/audio-research/cubs/capture192-admission-ramdisk-20260922 \
  work/audio-research/cubs/playback-admission-ramdisk-20260922
cp -a work/audio-research/cubs/aoc_alsa_dev_util.capture192-playback-admission.ko \
  work/audio-research/cubs/playback-admission-ramdisk-20260922/lib/modules/aoc_alsa_dev_util.ko

bash tools/audio/cubs/repack-vendor-kernel-boot.sh \
  work/audio-research/cubs/baseline-20260922/boot-backup/vendor_kernel_boot_a.img \
  work/audio-research/cubs/playback-admission-ramdisk-20260922 \
  work/audio-research/cubs/playback-admission-kernel-20260922
```

The new image changes only the prepared `aoc_alsa_dev_util.ko` in the copied
ramdisk. Rollback is the original live partition backup, or the earlier
capture192-admission image if that kernel admission should be retained.
The parent/operator owns flashing after a clean firmware rollback boundary.
No flash-all release or high-rate physical qualification is implied.
