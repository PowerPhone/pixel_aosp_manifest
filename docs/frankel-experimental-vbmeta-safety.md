# Frankel experimental `vendor_kernel_boot` AVB safety

## The failure this guard prevents

Top-level `vbmeta.img` authenticates more than `vendor_kernel_boot`. It also
contains the descriptors for `boot`, `dtbo`, `init_boot`, `pvmfw`,
`vendor_boot`, and the logical system/vendor partitions. Replacing only its
`vendor_kernel_boot` digest does **not** make an old root vbmeta compatible with
a newer system/vendor set.

This happened during the 192 kHz experiments: the mailbox builders inherited a
historical 8 KiB root vbmeta while the installed complete image set used a 16
KiB root vbmeta with different system/vendor roots. Each individual file was a
valid AVB image, but the combined root set boot-cycled.

## Safe experimental workflow

The mailbox real-progress, mailbox direct-period, and mailbox batch-two
builders now produce `vendor_kernel_boot.img` only by default. Their output
contains `KERNEL_ONLY.txt` and deliberately contains no `vbmeta.img`.

To generate a root pair intentionally, name the complete current image bundle:

```bash
FRANKEL_ROOT_IMAGE_SET="$PWD/work/aosp/out_pixel/frankel/target/product/frankel" \
  tools/audio/build_frankel_ep1_source0_192k_d0_mailbox_batch2_real_progress_pair.sh \
  "$PWD/work/audio-research/frankel/my-batch2-trial"
```

`make_frankel_experimental_vbmeta.sh` first proves that the donor
`vbmeta.img` describes every image in that directory. It then changes only the
`vendor_kernel_boot` descriptor digest, preserves the donor's root signing
parameters and padded size, signs it, and verifies the resulting twelve-image
descriptor set with the candidate kernel image substituted.

Use the guarded flasher for these one-partition experiments:

```bash
export FRANKEL_EXPERIMENTAL_FLASH_CONFIRM=FLASH_EXPERIMENTAL_FRANKEL_KERNEL

# Preferred: keep the root vbmeta already installed.
tools/audio/flash_frankel_experimental_vendor_kernel_boot.sh \
  --vendor-kernel-boot /path/to/trial/vendor_kernel_boot.img --reboot

# Deliberate paired update. Both extra arguments are mandatory.
tools/audio/flash_frankel_experimental_vendor_kernel_boot.sh \
  --vendor-kernel-boot /path/to/trial/vendor_kernel_boot.img \
  --vbmeta /path/to/trial/vbmeta.img \
  --root-image-set "$PWD/work/aosp/out_pixel/frankel/target/product/frankel" \
  --reboot
```

The helper refuses fastbootd, flashes the current physical slot, and commits a
requested root vbmeta last. `--verify-only` performs all file checks without
contacting the phone.

## Builder audit (2026-09-04)

Every `tools/audio/build_frankel*.sh` that both handles
`vendor_kernel_boot` and names a `base_vbmeta` was inspected.

The following active mailbox paths are converted to kernel-only-by-default and
explicit-root-set opt-in:

- `build_frankel_ep1_source0_192k_d0_real_progress_pair.sh`
- `build_frankel_ep1_source0_192k_d0_mailbox_real_progress_pair.sh`
- `build_frankel_ep1_source0_192k_d0_hybrid_real_progress_pair.sh`
- `build_frankel_ep1_source0_192k_d0_mailbox_direct_period_elapsed_pair.sh`
- `build_frankel_ep1_source0_192k_d0_mailbox_batch2_real_progress_pair.sh`

The following historical experiment builders still derive root vbmeta from a
fixed or predecessor trial. Their emitted `vbmeta.img` is archival and must not
be combined with a current device state. Rebase their `vendor_kernel_boot.img`
with `make_frankel_experimental_vbmeta.sh`, or flash it kernel-only through the
guarded helper:

- `build_frankel_d0_mailbox_cs35l43_global_fs96_pair.sh`
- `build_frankel_d28_source2_flash_pair.sh`
- `build_frankel_d28_source2_selective_pair.sh`
- `build_frankel_ep1_source0_192k_core_zero_wp_reset_pair.sh`
- `build_frankel_ep1_source0_192k_d0_consumed_step_pair.sh`
- `build_frankel_ep1_source0_192k_d0_direct_period_elapsed_2500us_pair.sh`
- `build_frankel_ep1_source0_192k_d0_hybrid_progress_1ms_pair.sh`
- `build_frankel_ep1_source0_192k_d0_logical_clock_2500us_pair.sh`
- `build_frankel_ep1_source0_192k_d0_mailbox_aoc_4s32_outputter_nop_pair.sh`
- `build_frankel_ep1_source0_192k_d0_skip_ring_align_pair.sh`
- `build_frankel_ep1_source0_192k_d0_timer_only_1ms_pair.sh`
- `build_frankel_ep1_source0_192k_pair.sh`
- `build_frankel_ep1_source0_192k_prefill_pair.sh`
- `build_frankel_ep3_capture_192k_host_timer_500us_cold_audio_trial.sh`
- `build_frankel_ep3_capture_192k_host_timer_500us_trial.sh`
- `build_frankel_ep3_capture_192k_trial.sh`
- `build_frankel_force_speaker_ultrasonic_dtb_trial.sh`
- `build_frankel_gsa_legacy_raw_unload_canary_trial.sh`

Three cold/current-state builders use a deliberately captured matched directory
or current-bootable anchor, but the same rule applies: never move their root
vbmeta to another build state without a complete descriptor-set verification.

- `build_frankel_cold_audio_vendor_boot_trial.sh`
- `build_frankel_cold_audio_vendor_boot_v2_trial.sh`
- `build_frankel_gsa_unload_release_reset_trial.sh`

`build_frankel_aoc_host_timer_1ms_trial.sh` points at a mutable build-output
root and is likewise not a portable pair. Treat its `vbmeta.img` as bound to the
exact build-output images present when it was generated.

## Direct checks

Compare one pair:

```bash
python3 tools/audio/verify_frankel_vbmeta_image_set.py \
  --avbtool work/aosp/out_pixel/frankel/host/linux-x86/bin/avbtool \
  pair --vbmeta /path/to/vbmeta.img \
  --vendor-kernel-boot /path/to/vendor_kernel_boot.img
```

Compare every descriptor in a complete root set, replacing only the VKB leaf:

```bash
python3 tools/audio/verify_frankel_vbmeta_image_set.py \
  --avbtool work/aosp/out_pixel/frankel/host/linux-x86/bin/avbtool \
  root-set --vbmeta /path/to/new-vbmeta.img \
  --image-set /path/to/complete-bundle \
  --override vendor_kernel_boot=/path/to/new-vendor_kernel_boot.img
```
