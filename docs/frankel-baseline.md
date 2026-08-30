# Pixel 10 (`frankel`) stock baseline

This document records the reviewed stock donor and partition contract for the
base Google Pixel 10. It is the starting point for the repository's Frankel
port; it is not evidence that Google publishes a complete AOSP device target.
The official-source observations below are current as of 2026-08-29.

## Official donor release

| Property | Reviewed value |
| --- | --- |
| Marketing name | Google Pixel 10 |
| Device codename and fastboot product | `frankel` |
| Stock release | Android 17, `CP2A.260805.005` |
| Security patch level | `2026-08-05` |
| Bootloader package | `deepspace-17.2-15372054` |
| Baseband package | `g5400i-260317-260429-B-15308590` |
| Factory archive | `frankel-cp2a.260805.005-factory-0e7d4fbb.zip` |
| Full OTA archive | `frankel-ota-cp2a.260805.005-25aa98f7.zip` |

Google lists the build in the official [Pixel 10 factory-image
section](https://developers.google.com/android/images#frankel) and [Pixel 10
full-OTA section](https://developers.google.com/android/ota#frankel). The exact
global artifacts are the [factory
archive](https://dl.google.com/dl/android/aosp/frankel-cp2a.260805.005-factory-0e7d4fbb.zip)
and [full OTA
archive](https://dl.google.com/dl/android/aosp/frankel-ota-cp2a.260805.005-25aa98f7.zip).
Google also exposes the signed build through [Android Flash
Tool](https://flash.android.com/build/15828068?target=frankel-user&signed).

The [August 2026 Pixel Update
Bulletin](https://source.android.com/docs/security/bulletin/pixel/2026/2026-08-01)
assigns supported Pixel devices the `2026-08-05` patch level. Carrier-specific
factory and OTA variants exist; this repository's reviewed donor is the global
build above, not the Rogers `CP2A.260805.005.A1` variant.

Google's download terms restrict use and redistribution of the binary
artifacts. The public repository must contain acquisition and extraction
instructions, not Google factory images, OTA packages, or extracted
proprietary blobs.

## Public AOSP source boundary

The latest stable public Android 17 source release is
`android-17.0.0_r1`, build `CP2A.260605.016`, with patch level `2026-06-05`.
Google's [codenames, tags, and build-numbers
table](https://source.android.com/docs/setup/reference/build-numbers) leaves its
supported-device field empty. The official [`android-17.0.0_r1`
manifest](https://android.googlesource.com/platform/manifest/+/refs/tags/android-17.0.0_r1/default.xml)
contains no `device/google/frankel` project, and Google's [AOSP driver-binaries
page](https://developers.google.com/android/drivers) contains no Pixel 10 or
`frankel` package.

Consequently, `CP2A.260805.005` is a stock firmware donor, not a reproducible
public AOSP source revision. The repository's
`frankel-aosp_current-userdebug` lunch target is locally reconstructed. It
combines the public Android 17 source baseline with target-specific
configuration and proprietary material acquired for the user's own device; it
must not be described as a Google-provided lunch target.

The reconstructed target includes two narrowly scoped source adapters absent
from the tag and the donor-generated skeleton. First, it defines eight
Frankel-prefixed feature XML prebuilt modules whose source XML files exist in
AOSP 17 but whose Soong module declarations do not; this includes Wi-Fi Aware
and Wi-Fi RTT. The Frankel sanitizer alone selects them, and explicit installed
filenames preserve the donor-generated paths without affecting Cubs.
Second, the GSF-free product selects a small read-only provider for the exact
Gservices authority queried by the extracted Pixel eUICC support app. These
are project-authored compatibility components, not Google-published Frankel
device support. Their design and validation boundary are recorded in the
[Frankel runbook](frankel-build-and-flash.md).

## Factory package contract

The outer factory archive contains the bootloader FBPK, radio FBPK, inner image
archive, shell and Windows flash scripts, and three EC binaries. Google's shell
scripts require Platform-Tools fastboot 33.0.1 or newer. `flash-all.sh` performs
these operations in order:

```text
fastboot flash bootloader bootloader-frankel-deepspace-17.2-15372054.img
fastboot reboot-bootloader
sleep 5
fastboot flash radio radio-frankel-g5400i-260317-260429-b-15308590.img
fastboot reboot-bootloader
sleep 5
fastboot -w update image-frankel-cp2a.260805.005.zip
```

`flash-base.sh` stops after the second bootloader reboot. The inner
`android-info.txt` requires the exact bootloader and baseband versions above,
but its board expression accepts the complete family:

```text
require board=rango|deepspace|frankel|blazer|mustang
require version-bootloader=deepspace-17.2-15372054
require version-baseband=g5400i-260317-260429-B-15308590
```

A project runner must therefore enforce literal fastboot product `frankel`
itself; the stock family-wide board requirement is not a sufficient target
gate.

The inner `fastboot-info.txt` declares this exact update sequence:

```text
flash boot
flash init_boot
flash dtbo
flash vendor_kernel_boot
flash pvmfw
flash vendor_boot
flash --apply-vbmeta vbmeta
flash vbmeta_system
flash vbmeta_vendor
reboot fastboot
update-super
flash system
flash system_dlkm
flash system_ext
flash product
flash vendor
flash vendor_dlkm
flash --slot-other system system_other.img
if-wipe erase userdata
if-wipe erase metadata
```

Current host fastboot can optimize the fastbootd/update-super/logical-partition
block into one sparse `super` flash. That optimization changes the transport
sequence, but not the package's declared partition contents. The `-w` option
requests a data/metadata wipe and the stock `update` command reboots after the
operation unless explicitly told not to.

## Exact partition inventory

The donor's `super_empty.img` uses logical-partition metadata version 10.2,
three metadata slots, and the `virtual_ab_device` flag. Physical `super` is
8,531,214,336 bytes. It defines a maximum size of 8,527,020,032 bytes for each
of `google_dynamic_partitions_a` and `google_dynamic_partitions_b` and contains
these read-only logical partitions in both groups:

```text
system
system_dlkm
system_ext
product
vendor
vendor_dlkm
```

The embedded GPT descriptors define 34 physical A/B partition types. The ten
Android boot-chain and modem partitions are:

```text
boot
init_boot
vendor_boot
vendor_kernel_boot
dtbo
vbmeta
vbmeta_system
vbmeta_vendor
pvmfw
modem
```

The other 24 A/B firmware partitions are:

```text
dbl
gsa_bl1
gc
dbc
dram_train
dram_init_0
dram_init_1
dram_init_2
dram_init_3
dram_init_4
dram_init_5
dram_init_6
dram_init_7
dram_init_8
dram_init_9
dram_phy
bl31
tzsw
abl
cpm
gdmc
dpm
cap
gsa_fw
```

The bootloader image is an FBPK v2 package for platform `lga`. It carries 22
slotted payloads: every firmware name in the second list except `dram_train`
and `dpm`. The radio FBPK carries the slotted `modem` payload. The inner image
archive contains individual copies of those 22 bootloader payloads and
`modem.img`, but the official `fastboot-info.txt` does not flash those copies;
the outer script uses the virtual `bootloader` and `radio` package targets.

There is no `dram_train.img` or `dpm.img` payload in the bootloader package,
radio package, or inner update archive. Existing `dram_train_a`,
`dram_train_b`, `dpm_a`, and `dpm_b` contents are device state that a custom
runner must preserve. They must not be erased, replaced with zero-length data,
or fabricated from another partition.

The inner update explicitly flashes these nine static A/B images to its target
slot:

```text
boot init_boot dtbo vendor_kernel_boot pvmfw vendor_boot
vbmeta vbmeta_system vbmeta_vendor
```

It flashes the six logical partitions listed above to the target slot and
places `system_other.img` into `system` on the opposite slot. `kernel_16k`,
`ramdisk_16k.img`, and `userdata_exp.ai.img` are present in the archive but are
not direct flash tasks in the official update instructions. `super_empty.img`
is metadata/layout input rather than an ordinary partition payload.

## Reconstructed Frankel AVB topology

The locally reconstructed target deliberately differs from the stock
three-vbmeta update graph. Its package contains only `vbmeta.img`; it contains
no source-built `vbmeta_system.img` or `vbmeta_vendor.img`. The root image has
no chain-partition descriptors and directly authenticates exactly these 12 OS
payloads:

```text
boot
dtbo
init_boot
pvmfw
vendor_boot
vendor_kernel_boot
system
system_dlkm
system_ext
product
vendor
vendor_dlkm
```

The first six are static physical payloads and the last six are logical
payloads. The package gate parses the built root image with `avbtool` and
requires this exact descriptor-name set, zero chain descriptors,
`SHA256_RSA4096`, and AVB flags `0`. Both generated copies of `fstab.laguna`
must map logical partitions to root `vbmeta`; a `vbmeta_system` or
`vbmeta_vendor` mapping is rejected.

The physical `vbmeta_system_[ab]` and `vbmeta_vendor_[ab]` partitions remain
part of the stock GPT, but the Frankel runner neither flashes nor erases them.
They are not reachable from the reconstructed root image and therefore do not
authenticate the packaged slot-A OS set. This root-only topology is a local
porting decision and must not be presented as the topology of Google's stock
factory package described above.

The FBPK partition descriptors also identify unslotted identity, calibration,
bootloader-state, and persistent-data partitions. A normal porting workflow
must not modify them. Depending on the supported family layout, these include:

```text
persist klog misc frp
efs efs_backup
protect_f protect_s nvram nvcfg nvdata
modem_userdata trusty_persist trusty_userdata
ufs_internal bl_data
devinfo pinfo blenv mfg_data rdbl
```

Only `metadata` and `userdata` are intentional wipe targets in the stock full
flash. UFS firmware/update records and embedded GPT descriptor entries must be
handled only by the official virtual bootloader package, never treated as
standalone partitions by a custom runner.

## Anti-rollback and the B lifeboat

Google's [factory-image
instructions](https://developers.google.com/android/images#special_instructions_for_updating_pixel_devices_to_the_may_2026_monthly_release)
state that the May 2026 Pixel 10 update increments the bootloader anti-rollback
version. After that update has booted, the device cannot flash and boot older
Android 16 bootloader builds. The factory metadata records exact required
version strings but exposes no numeric anti-rollback index, so this project
must not invent one or infer an ordering from version-string spelling.

The official outer commands do not request `--slot=all`. Google separately
recommends applying the matching full OTA after a successful May-2026-or-newer
stock boot so the inactive slot also contains a bootable, anti-rollback-
compatible firmware set. Therefore a successful factory flash of one slot is
not evidence that the other slot is a safe fallback.

Before a custom slot-A experiment, recovery policy must establish that physical
B contains a coherent May-2026-or-newer bootloader, firmware, modem, boot
stack, AVB chain, and fastbootd path. The custom A runner must then:

- refuse every product except literal `frankel`;
- refuse an older or unreviewed bootloader/baseband baseline;
- leave all physical-B firmware and boot-chain partitions untouched;
- preserve the B logical group and avoid the stock optimized `super` update,
  which reconstructs super and deliberately writes `system_other.img` to B;
- preserve `dram_train_[ab]`, `dpm_[ab]`, and all unslotted identity or
  calibration state;
- cancel or reject an active virtual-A/B snapshot operation before changing
  logical partitions;
- flash the reconstructed root-only `vbmeta_a` last, after its 12 directly
  described slot-A payloads, without verification-disable flags, while leaving
  the two stock child-vbmeta physical partitions unchanged;
- erase only `metadata` and `userdata` when the new layout requires it; and
- select A explicitly, prove repeated Android boots, and retain B recovery
  authority until the tested transaction is finalized.

Booting or modifying B merely because it is the inactive slot defeats the
lifeboat. Its role is recovery from an A-side port failure, and it should be
retired only after the exact packaged A images have booted and passed the
project's real-hardware validation gates.

The current development phone is a documented exception to that policy:
physical slot B was already unbootable when final Frankel qualification began.
The operator explicitly accepted proceeding without a B-slot lifeboat and
retains an external stock-recovery path. The standalone runner still leaves B
untouched, but that behavior does not make B usable. This exception is specific
to the current bring-up, increases the consequence of an A-side boot failure,
and must not be copied into the default procedure for another phone.
