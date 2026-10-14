# Cubs capture192 admission experiment

This is **not a qualified192 capture image**. It removes host admission
barriers and encodes192kHz as AoC enum7, but leaves PDM clocks, native sample
geometry, timing, buffering and firmware unchanged. Use the matched firmware
profile and real capture measurements before claiming physical192kHz.

Input is the live2026-09-22 Cubs custom-kernel backup, not stock donor modules.
The guarded patcher changes15 bytes in `aoc_alsa_dev_util.ko`: normal-PCM
runtime rate ceiling, only EP3 CAP/D10 and INTERNAL_MIC_TX DAI masks, and
capture request encoding. It adds192kHz only, not176.4kHz. Other DAI masks
and playback code are preserved. No hashes, mock tests or device calls.

From the repository root, using **new, non-existing destinations**:

```bash
python3 tools/audio/cubs/patch_capture192_admission.py \
  work/audio-research/cubs/baseline-20260922/vendor-kernel-ramdisk/lib/modules/aoc_alsa_dev_util.ko \
  work/audio-research/cubs/aoc_alsa_dev_util.capture192-admission.ko
cp -a work/audio-research/cubs/baseline-20260922/vendor-kernel-ramdisk \
  work/audio-research/cubs/capture192-admission-ramdisk-20260922
cp -a work/audio-research/cubs/aoc_alsa_dev_util.capture192-admission.ko \
  work/audio-research/cubs/capture192-admission-ramdisk-20260922/lib/modules/aoc_alsa_dev_util.ko
bash tools/audio/cubs/repack-vendor-kernel-boot.sh \
  work/audio-research/cubs/baseline-20260922/boot-backup/vendor_kernel_boot_a.img \
  work/audio-research/cubs/capture192-admission-ramdisk-20260922 \
  work/audio-research/cubs/capture192-admission-kernel-v2-20260922
```

The repacker uses existing Cubs AOSP host tools, `python3`, `cpio`, and `lz4`.
It retains base header arguments, bootconfig and all concatenated Malibu
DTBs; only the prepared single ramdisk replaces the base fragment. AVB footer
creation is image packaging, not hash verification or signature attestation.
The original ramdisk and full partition backup remain untouched.

Hardware owner only, after confirming the same device remains on slotA:

```bash
fastboot flash vendor_kernel_boot_a \
  work/audio-research/cubs/capture192-admission-kernel-v2-20260922/vendor_kernel_boot.img
fastboot --disable-verity --disable-verification flash vbmeta_a \
  work/audio-research/cubs/baseline-20260922/boot-backup/vbmeta_a.img
fastboot reboot
```

Rollback changes only these same partitions and does not wipe data:

```bash
fastboot flash vendor_kernel_boot_a \
  work/audio-research/cubs/baseline-20260922/boot-backup/vendor_kernel_boot_a.img
fastboot --disable-verity --disable-verification flash vbmeta_a \
  work/audio-research/cubs/baseline-20260922/boot-backup/vbmeta_a.img
fastboot reboot
```

Do not flash `boot.img`, donor modules, `vendor_boot`, or a full flash-all for
this experiment. These command examples have not been executed by the
offline builder and are not proof of boot or capture success.
