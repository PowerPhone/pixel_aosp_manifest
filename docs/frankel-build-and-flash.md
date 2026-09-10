# Pixel 10 (`frankel`) build and A-only flash runbook

This runbook describes the repository's current Frankel/Laguna workflow. A
source-built `frankel-aosp_current-userdebug` target and complete guarded flash
bundle have been produced. A preliminary source-built candidate reached
Android on real hardware and exposed two proprietary-package compatibility
failures. The hardened eUICC-provider and Wi-Fi-feature bundle subsequently
completed two slot-A hardware boots and two 66-pass/zero-failure runtime audits
with enforcing verity. Its broader functional qualification remains limited as
recorded in [`frankel-validation.md`](frankel-validation.md). A later build,
package publication, or fastboot transaction must not inherit that result;
repeat the checks below for every new candidate.

Run all repository commands below from the repository root. Set
`PIXEL_TARGET=frankel` on every target-aware entry point; leaving it unset
selects the legacy `cubs` default.

## Inputs and target identity

The selected profile is
[`config/targets/frankel/release.env`](../config/targets/frankel/release.env).
Its relevant inputs are:

```text
device:             frankel
platform:           laguna
lunch target:       frankel-aosp_current-userdebug
AOSP revision:      android-17.0.0_r1
AOSP build:         CP2A.260605.016
framework SPL:      2026-06-05
stock donor:        CP2A.260805.005
stock donor SPL:    2026-08-05
bootloader:         deepspace-17.2-15372054
baseband:           g5400i-260317-260429-B-15308590
```

The public AOSP framework SPL and the newer stock vendor SPL are intentionally
different. See [the reviewed donor and partition
baseline](frankel-baseline.md) for the official source links and the boundary
between public AOSP source and proprietary stock material.

## Host and source preparation

Install the documented Ubuntu packages and workspace-local pinned Node.js,
Yarn, and Platform-Tools distributions:

```bash
scripts/install-host-deps.sh
PIXEL_TARGET=frankel scripts/check-host.sh
```

`check-host.sh` requires an x86-64 host, at least 64 GiB RAM, at least 400 GiB
free space, and a native ext4 or btrfs workspace. It also proves that `adb` and
`fastboot` resolve to the pinned workspace Platform-Tools tree rather than a
distribution package.

Sync the locked AOSP and adevtool source closure:

```bash
PIXEL_TARGET=frankel SYNC_JOBS=4 scripts/sync-source.sh
```

The checkout is placed in `work/aosp`. Normal reproduction must match
`manifests/resolved.xml`; `PIXEL_AOSP_UPDATE_SOURCE_LOCK=1` is a maintainer
operation for a separately reviewed source-lock update, not a build workaround.

## Download and extract the stock donor

Review Google's Pixel binary terms, then download the pinned global factory
and full-OTA packages:

```bash
GOOGLE_PIXEL_TERMS_ACCEPTED=1 \
PIXEL_TARGET=frankel \
  scripts/download-stock.sh
```

The current scripts place the two target-unique files directly under
`downloads/`:

```text
downloads/frankel-cp2a.260805.005-factory-0e7d4fbb.zip
downloads/frankel-ota-cp2a.260805.005-25aa98f7.zip
```

Extract and validate the factory archive:

```bash
PIXEL_TARGET=frankel scripts/extract-stock.sh
```

The extracted factory directory is:

```text
work/stock/frankel-cp2a.260805.005/
```

It contains the inner `image-frankel-cp2a.260805.005.zip` and a local
completion sentinel. These ignored stock inputs and their proprietary contents
must not be committed or redistributed.

## Generate the Frankel vendor tree

Generate the device/vendor support with the pinned adevtool checkout:

```bash
PIXEL_TARGET=frankel \
ADEVTOOL_UNPACK_CONCURRENCY=10 \
ADEVTOOL_DOWNLOAD_CONCURRENCY=20 \
  scripts/extract-vendor.sh
```

This entry point installs exactly the adevtool Yarn lock, builds its host
helpers, applies the reviewed source patches, runs `generate-all -d frankel`
without the `--noVerify` or `--updateSpec` bypasses, applies the Laguna-specific
sanitizer, and records the generated-vendor attestation.

The principal generated paths are:

```text
work/aosp/vendor/google_devices/frankel/
work/aosp/vendor/google_devices/frankel/firmware/
work/attestations/frankel-generated-vendor.attestation
```

The firmware directory contains the aggregate `bootloader.img` and
`radio.img`, 23 individually reconstructed donor firmware images, and the
stock metadata used by the build. `dram_train.img` and `dpm.img` do not exist
in the official donor and must not be invented.

## Frankel compatibility adapters

The generated Laguna product requests eight standard AOSP feature XML modules
whose XML inputs exist under `frameworks/native/data/etc` in
`android-17.0.0_r1`, but whose `prebuilt_etc` module definitions are missing.
Undefined `PRODUCT_PACKAGES` entries are silently omitted. The committed
`frameworks-native` patch defines all eight under `frankel_`-prefixed Soong
names rather than special-casing only the first runtime symptom. After
adevtool's FileTreeSpec verification, the Frankel sanitizer rewrites exactly
this generated product's requests to those names. Each producer sets its
original module basename as `filename`, preserving the installed path and XML
bytes while preventing unchanged Cubs requests from inheriting this adapter:

```text
android.hardware.audio.pro
android.hardware.device_unique_attestation
android.hardware.opengles.aep
android.hardware.touchscreen.multitouch.jazzhand
android.hardware.wifi.aware
android.hardware.wifi.rtt
android.software.ipsec_tunnel_migration
android.software.midi
```

Wi-Fi Aware is required for `WifiAwareManager` and the corresponding system
service to exist. Its omission made the extracted Pixel Modem Service fail at
boot; Wi-Fi RTT is installed alongside it because both are part of the reviewed
Laguna feature contract. The generated-vendor sanitizer requires the product
module references and rejects any residual generic request. Build attestation
binds all eight installed XML files to target-files. Runtime validation checks
the Aware and RTT feature declarations and services that motivated the fix.

Pristine AOSP intentionally has no Google Services Framework provider, but the
extracted `com.google.euiccpixel` application observes and queries
`com.google.android.gsf.gservices` during startup. Removing the app would also
discard the donor eSIM firmware update, recovery, and garbage-collection path.
Frankel therefore selects the project-authored
`PixelAospGservicesFlagsProvider` in `system_ext` together with the extracted
eUICC app, its permissions/overlay, and adevtool's exact six-line flags file.

The provider is platform-signed, privileged, direct-boot-aware, and read-only.
It declares the stock `READ_GSERVICES` permission, exposes only
`/system_ext/etc/gmscompat/gservices-flags/flags.txt`, supports the key and
prefix query forms used by the eUICC helper, and permits data queries only from
self, root/system, or the exact installed system/privileged
`com.google.euiccpixel` UID. Missing or malformed input yields no flags rather
than inventing defaults. The sanitizer and build attestation bind the module,
manifest contract, eUICC package, overlay, permission file, and exact flags
payload.

This is a direct-authority adapter for a deliberately GSF-free AOSP product.
It will conflict with a real GSF package that owns the same authority and must
not be included in a GSF-capable product. Such a product needs a reviewed
framework-level authority redirect or another coexistence design. Runtime
qualification must inspect all log buffers for eUICC, Pixel Modem Service, and
provider permission failures; static presence is not success evidence.

## Build the userdebug device target

Build the Frankel target-files package, boot images, otatools, and validation
helpers:

```bash
PIXEL_TARGET=frankel \
BUILD_JOBS="$(nproc)" \
  scripts/build-device.sh
```

Ordinary builds default to the exact stock AoC ALSA module. For the PowerPhone
research image, use the same explicit opt-ins during extraction (or a later
sanitizer/attestation refresh) and every build invocation:

```bash
export PIXEL_TARGET=frankel
export POWERPHONE_AOC_ALSA_192K=true
export POWERPHONE_D0_PROGRESS_MODE=one-period-lag
export POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE=stock
export POWERPHONE_AUDIO_SIDECAR=true
export POWERPHONE_CS35L43_192K=true

# Required once after changing a selector or any reviewed sidecar/bootstrap
# source: materialize the reviewed AOSP patch stack and exact generated-vendor
# selection, then bind both before the build's fail-closed verification gate.
scripts/apply-source-patches.sh
scripts/sanitize-generated-vendor-frankel.sh
scripts/attest-generated-vendor.sh create

BUILD_JOBS="$(nproc)" scripts/build-device.sh
```

If the generated-vendor attestation already describes the exact same five
selection values and reviewed helper sources, omit the two refresh commands.
Never reuse an attestation from another profile (for example, `mailbox`):
`build-device.sh` intentionally verifies rather than silently replacing it.

`POWERPHONE_AOC_ALSA_192K=true` selects the pinned PCM0,D10-capture plus
PCM0,D0 / EP1 source-0-playback binary transformation family for
`stock-kernel/aoc_alsa_dev_util.ko`: general 192 kHz allowances, the EP3 and
EP1 masks, and 500 us capture-ring polling. The baseline-compatible default
`POWERPHONE_D0_PROGRESS_MODE=mailbox` uses real D0 mailbox progress bounded
to one already-consumed period per notification and has SHA-256
`fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0`;
the publishable PowerPhone selection `one-period-lag` combines the real mailbox
counter with the 1 ms real-counter poll and reports
`max(previous, actual minus one physical period)`. It has SHA-256
`37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6`.
That exact module streamed a complete ten-second native-q192 physical-speaker
payload with a 1,920-by-two ring and 1,920-frame start threshold, and the same
geometry remained stable while D10 transport ran concurrently.
The same selection also changes `stock-kernel/aoc_core.ko` from the stock
SHA-256
`23acc08d0539657e72a0bc506abf6cef9950b90b192c51fd0dd9bf2177e4f2ad`
to
`f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c`.
That one-instruction reset fix tests an already-loaded zero write pointer
instead of advancing the producer by one complete ring before the first PCM
copy. `POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE` defaults to `stock`; the
retained `source0-4s32-allocator-fallback` cold transform is not a boot
candidate because GSA rejects the modified signed firmware. After stock
firmware loads, the boot helper retains the stock A32 allocator when its
optional early cache-sync window is unavailable, warms the Android audio
control plane, and installs the guarded F1 speaker profile live.
The two AoC modules are one transport invariant: selecting the ALSA
module without the paired core fix can manufacture initial data and watchdog
AoC during D0 startup. Selecting `false`, `mailbox`, and `stock` restores both
exact stock modules and stock firmware without regenerating the vendor tree.

The sanitizer rejects intermediate, mixed, or unknown module bytes, and the
generated-vendor attestation binds the selected outputs and pinned helpers.
The build-completion gate also compares both exact AoC modules with the
installed vendor-kernel ramdisk and target-files entries before binding the
final images. Changing any opt-in requires recreating the generated-vendor
attestation before the build. `POWERPHONE_CS35L43_192K=true`
selects the exact stock CS35L43 module with its ultrasonic GLOBAL_FS immediate
changed from 48 to 96 kHz (SHA-256
`fc631fc227ab2e7e8cfa2d664e97ac7cca4c14324fb2a39479fc8e79aa358a3a`).
Pass the same five selection values to
`scripts/package-device.sh`, whose completion-attestation verification
rechecks the selected generated tree. Neither a successful build nor the
presence of 192000 in ALSA constraints is physical bandwidth evidence.
Stock signed firmware is mandatory; readiness is a boot-local signal published
only after the guarded F1 transaction and complete speaker rebase succeed. The
VINTF-declared PowerPhone HAL process stays registered
from boot so audio discovery cannot block. Inert STANDBY construction is
allowed for policy discovery. With the D10 sidecar selected, a target-local
one-shot and its system-ext init gate coordinate a paired sidecar/audioserver
warm-up, establish the strict D10 mixer state and quarantine, retain stock A32
or certify its optional guarded fallback at stock worker priority, certify the
F1 speaker profile first, then certify the D10 capture patch
and PCM0,D10 readback. Hardware
testing showed that the speaker factory-mailbox transaction can fail after D10
is resident; D10 therefore runs last and its final whole-F1 cache
synchronization covers both profiles.
D8/D9/D12 stay quarantined and the retired card-1 AP-PDM module is absent.
Speaker start/transfer remains fail-closed on the independent boot-cleared
`vendor.powerphone.aoc_speaker_192k.ready` flag until that boot-local check
proves the volatile AoC firmware patch is active.
The addressed research profile may be visible and AudioPolicyManager may
construct an inert STANDBY stream while that flag is zero; `StreamAlsa` opens
no PCM until start, and start/transfer remain blocked.

Do not run extraction, either sanitizer, device builds, or packaging
concurrently against the same Frankel source tree. The opt-ins are materialized
in the shared generated-vendor tree, not isolated by `OUT_DIR`; the start/end
attestation gates reject persistent drift but are not a substitute for a
cross-process build lock. Finish one selected workflow before changing flags.

`BUILD_JOBS` may be reduced for the host but must remain a positive integer no
greater than 256. The default target-specific output root is:

```text
work/aosp/out_pixel/frankel/
```

Important build outputs are:

```text
work/aosp/out_pixel/frankel/target/product/frankel/
work/aosp/out_pixel/frankel/target/product/frankel/obj/PACKAGING/target_files_intermediates/
work/aosp/out_pixel/frankel/build-completion-frankel.attestation
logs/build-frankel.log
```

The completion attestation binds the generated-vendor attestation, source and
patch locks, target-files archive, and required device images. Its existence
means the scripted build gates passed; it is not boot evidence.

## Package the standalone device bundle

Publish the reviewed Frankel device bundle:

```bash
PIXEL_TARGET=frankel scripts/package-device.sh
```

For a PowerPhone research build, use the same explicit selections used to
sanitize, attest, and build it:

```bash
POWERPHONE_AOC_ALSA_192K=true \
POWERPHONE_D0_PROGRESS_MODE=one-period-lag \
POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE=stock \
POWERPHONE_AUDIO_SIDECAR=true \
POWERPHONE_CS35L43_192K=true \
PIXEL_TARGET=frankel \
  scripts/package-device.sh
```

The packager never changes selections. Omitting the flags against a research
tree (or supplying them against a stock tree) fails the attestation check.

The generic entry point dispatches to `package-device-frankel.sh`. A normal
output tree must contain exactly one Frankel target-files archive. If a
reviewed workflow intentionally retains more than one, select the desired
archive explicitly with an absolute `DEVICE_TARGET_FILES` path inside the
Frankel output tree:

```bash
repo_root=$(pwd -P)
PIXEL_TARGET=frankel \
DEVICE_TARGET_FILES="$repo_root/work/aosp/out_pixel/frankel/target/product/frankel/obj/PACKAGING/target_files_intermediates/frankel-target_files.zip" \
  scripts/package-device.sh
```

The default stock-audio build is published at:

```text
artifacts/frankel/device/
```

The all-three-flags PowerPhone build is instead published at:

```text
artifacts/frankel/powerphone/
```

A partial-selection research build uses a distinct
`artifacts/frankel/experimental-*` directory. These destinations are selected
from the same explicit flags that the attestation verifies, so a research
package cannot replace the boot-qualified baseline. `BUNDLE_INFO.txt` records
`bundle_profile`, `powerphone_aoc_alsa_192k`,
`powerphone_d0_progress_mode`, `powerphone_signed_aoc_firmware_profile`,
`powerphone_audio_sidecar`, and `powerphone_cs35l43_192k`.

It contains:

```text
flash-all.sh
bundle-kind
BUNDLE_INFO.txt
BUILD_ATTESTATION.txt
SHA256SUMS
android-info.txt
fastboot-info.txt

# 23 stock donor firmware images
abl.img bl31.img cap.img cpm.img dbc.img dbl.img
dram_init_0.img ... dram_init_9.img
dram_phy.img gc.img gdmc.img gsa_bl1.img gsa_fw.img modem.img tzsw.img

# 7 source-built physical OS images
boot.img dtbo.img init_boot.img pvmfw.img
vendor_boot.img vendor_kernel_boot.img vbmeta.img

# 6 source-built logical images
system.img system_dlkm.img system_ext.img
product.img vendor.img vendor_dlkm.img
```

The published directory contains exactly 43 regular files. `SHA256SUMS`
covers an exact 42-entry allowlist: all 36 images plus `bundle-kind`,
`BUNDLE_INFO.txt`, `BUILD_ATTESTATION.txt`, `android-info.txt`,
`fastboot-info.txt`, and `flash-all.sh`. The checksum manifest itself is the
43rd file and publication marker. Packaging withdraws that marker before
replacing payloads, installs the manifest last, then performs a strict checksum
check. It refuses to update a destination containing an unexpected entry,
symlink, or non-regular file.

The standalone runner repeats and strengthens that check before its first
fastboot invocation. It requires every allowlisted payload to be a nonempty,
non-symlink regular file, requires `flash-all.sh` to remain executable, proves
that the directory has exactly the 43 allowed names, parses exactly 42 safe and
unique manifest records, and strictly verifies every recorded digest. Only
then does it resolve `FASTBOOT` to a safe executable and require SHA-256
`a686e2c7e8dc9cf4cba0cb8a2eef05f7b2bd682c925abd032fe203215d80b618`.
The digest gate occurs before even invoking `fastboot --version`; version
`37.0.1` and live-device checks follow it.

The bundle deliberately has no `dram_train.img` or `dpm.img`. It also uses
Laguna's reconstructed root-only AVB topology and therefore has no source-built
`vbmeta_system.img` or `vbmeta_vendor.img`. Root `vbmeta.img` directly
authenticates exactly six static payloads (`boot`, `dtbo`, `init_boot`,
`pvmfw`, `vendor_boot`, and `vendor_kernel_boot`) and all six logical payloads
listed above. It has zero chain-partition descriptors, uses
`SHA256_RSA4096`, and has AVB flags `0`; the packager rejects any other
descriptor set or signing policy. The runner leaves the existing physical
child-vbmeta partitions unchanged because they are not reachable from this
root image. At flash time only, the runner asks fastboot to set both the
hashtree-disabled and verification-disabled bits in the slot-A root-vbmeta
copy. The packaged source image remains the signed flags-0 input recorded by
`SHA256SUMS`.

`pvmfw.img` has one intentional representation difference between the direct
product output and the flash bundle. Android releasetools rebuilds the
target-files `IMAGES/pvmfw.img` to the fixed 1 MiB partition capacity and adds
the exact `com.android.build.pvmfw.fingerprint` AVB property; the attested
`PREBUILT_IMAGES/pvmfw.img` input is minimally padded and has no property
descriptor. The bundle uses the rebuilt image. Packaging does not waive this
difference: it verifies both images with `avbtool`, requires identical raw
payload bytes, original size, hash descriptor, algorithm, flags, rollback
metadata, and embedded public key, then requires the rebuilt image's one exact
fingerprint property and 1 MiB size. Root `vbmeta.img` must authenticate that
rebuilt payload with the complete 12-image set.

`artifacts/`, `work/`, `downloads/`, and runtime logs are ignored local state.
Only the scripts, target profile, patches, and documentation belong in the
public source repository.

## Stock firmware and recovery prerequisites

Before running the bundle, put the phone in bootloader fastboot and run the
read-only preflight:

```bash
PIXEL_TARGET=frankel scripts/check-device.sh
```

The current preflight requires one attached fastboot device, literal product
`frankel`, an unlocked bootloader, two slots, no virtual-A/B snapshot operation,
and at least 50 percent battery. When the stock archive has been extracted, it
also requires the exact reviewed bootloader and baseband versions.

The following recovery prerequisite is not automated by the current Frankel
runner: physical B must already contain a coherent May-2026-or-newer Pixel 10
bootloader, firmware, modem, boot stack, AVB chain, and usable fastbootd path.
The May 2026 bootloader raised anti-rollback state, so an older inactive slot is
not a lifeboat merely because fastboot calls it bootable. Prepare and verify B
from matching stock firmware before risking A.

For the current development phone only, physical B was already unbootable and
the operator explicitly accepted a no-lifeboat qualification run backed by an
external stock-recovery path. The runner still preserves B, but cannot make it
bootable or use it to recover from an A-side boot hang. Record this exception
with the final evidence; do not treat it as the normal reproduction policy.

The bundle supplies neither `dram_train` nor `dpm`; valid existing values must
already be present on both slots. Unslotted identity and calibration state must
also remain intact. In particular, do not erase or copy over `persist`, `efs`,
`efs_backup`, `nvram`, `nvcfg`, `nvdata`, `protect_f`, `protect_s`,
`modem_userdata`, `trusty_persist`, `trusty_userdata`, `mfg_data`, `devinfo`,
`pinfo`, `blenv`, `rdbl`, or UFS/GPT metadata.

## Real slot-A flash

Use the pinned workspace fastboot and an explicit serial when more than one
transport may exist. Substitute the current fastboot serial; do not record a
real serial in committed logs or documentation.

```bash
repo_root=$(pwd -P)
fastboot_bin="$repo_root/work/toolchains/platform-tools/fastboot"
fastboot_serial='<fastboot-serial>'
bundle_dir=artifacts/frankel/device
# For the explicitly selected PowerPhone build, use:
# bundle_dir=artifacts/frankel/powerphone

(
  cd "$bundle_dir"
  env -u ANDROID_SERIAL \
    FASTBOOT="$fastboot_bin" \
    FRANKEL_FASTBOOT_SERIAL="$fastboot_serial" \
    FRANKEL_FLASH_CONFIRM=FLASH_FRANKEL_A_ERASE_USERDATA \
    FRANKEL_SKIP_REBOOT=1 \
    ./flash-all.sh
)
```

The environment variables have these meanings:

| Variable | Meaning |
| --- | --- |
| `FASTBOOT` | Absolute path to the pinned fastboot executable; defaults to `fastboot` on `PATH` |
| `FRANKEL_FASTBOOT_SERIAL` | Explicit target transport; `ANDROID_SERIAL` is the fallback |
| `FRANKEL_FLASH_CONFIRM` | Must equal `FLASH_FRANKEL_A_ERASE_USERDATA` to acknowledge the wipe |
| `FRANKEL_SKIP_REBOOT` | Set to exactly `1` to leave the completed transaction in bootloader fastboot; otherwise the runner reboots Android |

If exactly one phone is attached, the serial variable may be omitted. An
explicit serial is preferable for real hardware work. Clear `ANDROID_SERIAL`
when using `FRANKEL_FASTBOOT_SERIAL` so a stale value cannot confuse separate
manual commands.

The standalone runner performs these gates and mutations:

1. Before invoking fastboot, it authenticates the exact 42-entry checksum
   manifest, exact 43-file directory, and pinned fastboot binary digest as
   described above. It then requires Platform-Tools fastboot `37.0.1` and
   enforces literal product `frankel`, unlocked state, two slots, a valid
   current slot, the exact donor bootloader/baseband, and no active snapshot.
   If invoked from fastbootd, it first returns to bootloader fastboot.
2. It writes the 22 supplied bootloader-firmware images to literal slot A,
   then reboots and revalidates bootloader fastboot.
3. It writes `modem.img` to literal slot A, then reboots and revalidates
   bootloader fastboot again.
4. Before changing any slot-A OS image, it enters fastbootd through the still
   coherent current boot stack. It validates all six slot-A logical
   partitions, shrinks each to zero, and then flashes `system`, `system_dlkm`,
   `system_ext`, `product`, `vendor`, and `vendor_dlkm` to literal A.
5. It reboots directly to bootloader fastboot without trying Android, then
   writes `boot`, `dtbo`, `init_boot`, `pvmfw`, `vendor_boot`,
   `vendor_kernel_boot`, and finally root `vbmeta` to literal A. Writing
   `vbmeta` last avoids authenticating a partially replaced static set. That
   final command uses both `--disable-verity` and `--disable-verification`,
   permitting research-time `adb remount` and instrumentation without a
   second root-vbmeta transaction.
6. Only after all image writes succeed, it erases unslotted `userdata` and
   `metadata`, selects A, and either reboots Android or remains in bootloader
   fastboot when `FRANKEL_SKIP_REBOOT=1`.

It does not invoke the stock optimized `fastboot update`, does not write
`system_other.img`, and does not target B. It preserves `dram_train`, `dpm`,
unslotted identity/calibration data, and every B partition. It does not prove
that B was safe beforehand; that remains an operator recovery gate.

With `FRANKEL_SKIP_REBOOT=1`, the final transport is bootloader fastboot, not
fastbootd. Inspect the mode and active slot, then boot when ready:

```bash
"$fastboot_bin" -s "$fastboot_serial" getvar product
"$fastboot_bin" -s "$fastboot_serial" getvar is-userspace
"$fastboot_bin" -s "$fastboot_serial" getvar current-slot
"$fastboot_bin" -s "$fastboot_serial" getvar snapshot-update-status
"$fastboot_bin" -s "$fastboot_serial" reboot
```

Omit `FRANKEL_SKIP_REBOOT` for an immediate reboot after selecting A.

## Post-boot ADB checks

The first boot can take longer after the data wipe. If Android does not expose
ADB automatically, complete first-boot setup and enable USB debugging on the
phone. Use the pinned workspace ADB and a placeholder rather than committing a
real transport identifier:

```bash
adb_bin="$repo_root/work/toolchains/platform-tools/adb"
adb_serial='<adb-serial>'

"$adb_bin" -s "$adb_serial" wait-for-device
for attempt in $(seq 1 180); do
  [[ "$("$adb_bin" -s "$adb_serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
  sleep 2
done
test "$("$adb_bin" -s "$adb_serial" shell getprop sys.boot_completed | tr -d '\r')" = 1
```

Record at least the following identity and verified-boot observations:

```bash
for property in \
  ro.product.device \
  ro.build.id \
  ro.build.type \
  ro.debuggable \
  ro.build.version.release \
  ro.build.version.sdk \
  ro.build.version.security_patch \
  ro.vendor.build.security_patch \
  ro.boot.slot_suffix \
  ro.boot.verifiedbootstate \
  ro.boot.veritymode; do
  printf '%s=' "$property"
  "$adb_bin" -s "$adb_serial" shell getprop "$property" | tr -d '\r'
done
"$adb_bin" -s "$adb_serial" shell getenforce
```

The source inputs imply the following expected values; hardware must confirm
them:

| Observation | Expected value |
| --- | --- |
| `sys.boot_completed` | `1` |
| `ro.product.device` | `frankel` |
| `ro.build.id` | `CP2A.260805.005` |
| `ro.build.type` | `userdebug` |
| `ro.debuggable` | `1` |
| Android release / SDK | `17` / `37` |
| Framework SPL | `2026-06-05` |
| Generated vendor image SPL | `2026-06-05` |
| Slot suffix | `_a` |
| Verified boot state on an unlocked phone | `orange` |
| Verity mode | `disabled` after this bundle's fastboot transaction |
| SELinux | `Enforcing` |

The proprietary donor release itself has stock SPL `2026-08-05`, but this
source build deterministically regenerates the vendor partition build
properties with the public AOSP framework SPL. The runtime expectation for
`ro.vendor.build.security_patch` is therefore `2026-06-05`; this does not
rewrite the individual proprietary payload bytes extracted from the newer
donor.

Inspect partition mounts and the principal hardware services without changing
the other slot:

```bash
"$adb_bin" -s "$adb_serial" shell 'mount | grep -E " /(system|product|system_ext|vendor)(/| )"'
"$adb_bin" -s "$adb_serial" shell 'ls -l /dev/block/mapper | grep -E "(system|product|vendor)"'
"$adb_bin" -s "$adb_serial" shell service list | grep -E 'camera|audio|sensor|wifi|bluetooth|nfc|fingerprint'
"$adb_bin" -s "$adb_serial" shell dumpsys media.camera | sed -n '1,120p'
"$adb_bin" -s "$adb_serial" shell dumpsys sensorservice | sed -n '1,80p'
```

Run the target-bound automated gate as well. It uses the pinned workspace ADB,
redacts the transport identifier, requires root-capable `userdebug`, checks the
exact device build ID and framework SPL, and proves that all six logical A
partitions use read-only direct linear device-mapper mappings without a verity
target when the explicit disabled-AVB expectation is selected. It also checks
the Wi-Fi Aware/RTT declarations and services, the eUICC flags provider and
permission path, and the absence of the known eUICC, Pixel Modem Service,
EuiccGoogle, and Pixel Camera Services crash signatures:

```bash
FRANKEL_ADB_SERIAL="$adb_serial" \
FRANKEL_EXPECT_DISABLED_AVB=true \
PIXEL_TARGET=frankel \
  scripts/validate-frankel-runtime.sh
```

The validator deliberately defaults to the historical enforcing-AVB
contract. Leave `FRANKEL_EXPECT_DISABLED_AVB` unset only when qualifying a
candidate flashed without the two disable flags; a candidate installed by the
bundled runner requires the explicit `true` value above.

The report is written under ignored `logs/` state. It establishes boot,
identity, AVB/verity, SELinux, mount, and core-service evidence; it deliberately
does not turn camera, Wi-Fi, audio, modem, display/touch, or other subjective
functional checks into synthetic pass claims.

Then perform a normal second A-side reboot and repeat the boot-complete,
identity, slot, verity, SELinux, mount, and service checks:

```bash
"$adb_bin" -s "$adb_serial" reboot
"$adb_bin" -s "$adb_serial" wait-for-device
```

The legacy `scripts/validate-runtime.sh` modes remain Cubs/GSI-specific and
must not be used to label a Frankel boot as qualified; use the dedicated
Frankel validator above. It does not publish a Cubs recovery-bound runtime
attestation. Retain its report plus direct hardware observations and state the
result narrowly. The checksum-identified hardened bundle completed the listed
camera, Wi-Fi scan, Bluetooth, audio, vibration, storage, sensor,
display/touch-presence, NFC/fingerprint-service, modem-presence, and repeated-
reboot smoke checks. SIM registration and telephony/data remained unqualified,
UWB was unavailable, and the other end-to-end/manual limits are listed in the
validation record. These observations remain real-hardware evidence for that
exact candidate rather than build-time claims.

Record only sanitized evidence in
[`frankel-validation.md`](frankel-validation.md). Do not publish USB transport
identifiers, network names/addresses, SIM identifiers, camera media, or raw
logs. The report is identity-bound to the observed build; the validation record
separately binds the candidate hashes. It is not a cryptographic transaction
attestation equivalent to the Cubs recovery-anchor workflow.
