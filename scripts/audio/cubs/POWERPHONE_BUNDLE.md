# Cubs PowerPhone OS bundle (separate opt-in flavor)

This is a packaging/flash workflow, not a claim that a newly assembled bundle
has passed hardware qualification. It is separate from the historical
`artifacts/cubs` donor release and every Frankel bundle. Neither is modified.
The script copies the selected existing images; it does not rebuild Android,
calculate hashes, attest the device, or silently select the newest candidate.

The closure contains 14 current-slot OS images:

| Input | Images |
| --- | --- |
| Captured custom-kernel boot baseline | `boot`, `init_boot`, `dtbo`, `vendor_boot`, `vbmeta_system`, `vbmeta_vendor`, `vbmeta` |
| Explicit selected admission image | `vendor_kernel_boot` |
| Captured matching logical baseline | `system`, `system_dlkm`, `product`, `vendor_dlkm` |
| Explicit completed primary-image build | `vendor`, `system_ext` |

This is **not** a factory firmware restore: bootloader, radio/modem, pvmfw,
other low-level firmware, a super image, and inactive-slot physical partitions
are not flashed. Explicit `--grow-logical` may update the current slot's logical
allocation metadata, but never shrink/delete partitions or alter inactive-slot
logicals. The captured bootloader/baseband versions are prerequisites;
the runner refuses different versions. Logical partitions share super storage,
so preserving inactive-slot physical images does not promise a bootable second
Android slot. No slot switch or logical shrink/delete is performed.

## Assemble, only after selecting the exact primary candidate

Run from the repository root. `images-v7` below is an explicit candidate input,
not an automatic promotion. If another primary build is qualified, supply that
directory instead. Never combine its vendor image with another build's
system_ext image. The kernel image must retain the capture192, playback192 and
RAW3 admission changes built against the captured custom 6.12.92 kernel.

```bash
bash scripts/audio/cubs/assemble-powerphone-bundle.sh \
  --boot-dir work/audio-research/cubs/baseline-20260922/boot-backup \
  --source-slot a \
  --baseline-dir work/audio-research/cubs/primary-hal-integration-20260923/baseline \
  --baseline-properties work/audio-research/cubs/baseline-20260922/properties-services.txt \
  --vendor-kernel-boot work/audio-research/cubs/raw3-admission-kernel-20260922/vendor_kernel_boot.img \
  --primary-images work/audio-research/cubs/primary-hal-integration-20260923/images-v7 \
  --output-dir artifacts/cubs-powerphone-NEW_RELEASE
```

The default prints the local source/size plan and creates no output directory.
Add `--assemble` to the **same command** to copy into a new directory. Existing
outputs are rejected, not refreshed. Copies use reflinks where supported,
never hard links. A failed staging directory is retained for inspection. The
published bundle records source paths, sizes, source mtimes, baseline identity,
primary build reports and firmware prerequisites. These are provenance records,
not content-integrity or hardware-success claims.

The bundle contains standalone `flash-all.sh`. It also contains
`HARDWARE_QUALIFICATION_PENDING`; assembly never removes that marker or claims a
PASS. Retain actual flash, boot-readiness and API/acoustic reports separately.
No image copies are made merely by adding this source workflow to the repo.

To build new primary images rather than reuse completed ones, use the existing
[`build-primary-images.sh`](../../../tools/audio/cubs/build-primary-images.sh)
with its explicit captured-root, completed product output and policy output
arguments. Source staging remains
[`stage-primary-profile.sh`](stage-primary-profile.sh); the native helper build
is [`build-boot-helper.sh`](../../../tools/audio/cubs/build-boot-helper.sh).
This assembler deliberately does not start Soong/Ninja or replace those inputs.

## Flash the complete selected OS closure

Back up user data and retain the captured baseline externally. Use WSL Linux
platform-tools37.0.1; ADB stays on port5038 with `ADB_LIBUSB=1`. A moved bundle
may need the explicit `--platform-tools` path. The source equivalent is
`bash scripts/audio/cubs/flash-powerphone.sh --bundle-dir BUNDLE ...`.

```bash
SERIAL=YOUR_CUBS_SERIAL
BUNDLE=artifacts/cubs-powerphone-NEW_RELEASE
TOOLS="$PWD/work/toolchains/platform-tools-37.0.1/platform-tools"

# Local plan only; no device queries or reboots.
bash "$BUNDLE/flash-all.sh" --serial "$SERIAL" --platform-tools "$TOOLS"

# Actual current-slot OS writes, preserving user data by default.
bash "$BUNDLE/flash-all.sh" --serial "$SERIAL" --platform-tools "$TOOLS" \
  --flash --reboot
```

If a selected logical image is larger than its current partition, the default
stops in preflight before any image/metadata write. Add `--grow-logical` to
authorize growth of only that current-slot logical partition to the exact
recorded image byte size. For example, v6 `system_ext.img` is232960000 bytes,
one4096-byte block larger than the actual earlier232955904-byte partition.
All planned sizes are logged before the first write; growth occurs in guarded
fastbootd immediately before that partition's flash. A failed allocation
(including insufficient super/group space) stops without shrink/delete fallback.

Platform-tools `flash` itself automatically resizes logical partitions to the
image size. Therefore this runner also rejects an image **smaller** than the
current partition in preflight; otherwise an apparently ordinary flash could
silently shrink it. No padding, inactive-slot deletion, or space reclamation is
inferred. The source files and assembled image bytes remain unchanged.

The runner matches the exact serial, requires product `cubs`, unlocked `yes`
and a stable valid current slot, checks existing firmware versions and image
capacity, and preflights the current-slot fastbootd namespace before the first
image write. An active/unknown virtual-A/B snapshot update is rejected.
Physical images are flashed in bootloader fastboot; the six logical images
are flashed in fastbootd. The top-level vbmeta flash explicitly disables AVB
verification/verity for this unlocked research image.

Each USB transition has a bounded60-second wait. A reboot-request command can
time out after a successful USB disconnect; it is accepted **only** if the
exact device reaches the requested mode and passes the guards. Both
`fastboot` and platform-tools37's `fastbootd` device labels are recognized;
`is-userspace` remains authoritative. An image-flash error is never ignored or
automatically retried. All commands and outputs are recorded in a unique
`flash-powerphone-*.log` in the bundle directory.
Failures before any flash/resize/erase attempt are explicitly labeled
`PREFLIGHT_FAILED_BEFORE_WRITES`; subsequent failures preserve the possibility
of partial writes. Earlier failed logs are never replaced.

`--reboot` establishes only exact-device Cubs ADB arrival, not
`sys.boot_completed`, helper readiness, absence of SELinux denials, or audio
success. Without it, the device remains in fastbootd. If a transition or write
fails, preserve the log and inspect the actual device/partitions before any
retry; the runner does not wipe or attempt automatic recovery.

### Optional destructive wipe

Only append `--wipe-userdata` if explicitly intending to erase **all user data
and its encryption metadata across both slots**. It issues exactly `erase
userdata` and `erase metadata` after the image writes. This is not recoverable
without an external backup. The default never erases either partition; no
implicit `fastboot -w` or failure-triggered wipe is used.

## Qualification boundary

The boot helper selects the mono edge0/MCPS112 plus D5 two-slot192 profile.
RAW3 remains a separate mutually exclusive direct-capture experiment; the
wider kernel admission alone does not make RAW3 the boot/API profile. Java,
AAudio, ordinary UI sounds, endpoint routing, handoffs and repeated boots must
be qualified against the **exact flashed bundle**, not only a live-bound HAL.
TAS2572 accepting192-kHz serial input does not imply a full96-kHz acoustic
passband. Keep those limits and actual physical evidence with any release.
