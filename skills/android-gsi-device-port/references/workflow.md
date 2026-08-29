# Unsupported-device AOSP/GSI workflow

Use this sequence as a decision framework. Device documentation and live
partition evidence override examples or conventions from other products.

## 1. Inventory and recovery baseline

Record the device serial, codename, stock fingerprint/build ID, security patch,
bootloader/baseband versions, slot state, unlock state, boot modes, partition
sizes, `super` metadata, boot-control state, and whether userspace fastboot can
be entered from each physical slot. Archive the exact factory package and its
license/source URLs.

Treat rollback indices and virtual A/B status as hard gates, not inventory
notes. Reject lower or internally mixed firmware generations. Do not touch
`super` or any logical partition while snapshot/merge/COW state is active or
ambiguous; confirm a terminal state again after entering fastbootd.

Before modifying shared `super`, prove a physical recovery chain. A useful
lifeboat contains the physical bootloader and fastbootd inputs needed to fetch
or rewrite partitions; it does not imply that Android remains bootable on that
slot. Journal every destructive phase so an interrupted process cannot be
mistaken for a clean starting state.

## 2. Acquire vendor material

Boot the exact stock release with authorized ADB when possible. Use `adevtool`
or an equivalent reproducible extractor against the stock device and/or
factory images to generate:

- proprietary file lists and extraction scripts;
- device/vendor makefiles and Soong namespaces;
- VINTF manifests/matrices and HAL declarations;
- sepolicy inputs and file contexts;
- init, ueventd, fstab, permissions, overlays, firmware, kernel modules, and
  linker-namespace configuration.

Keep an explicit map from each output blob to its source build and partition.
Separate redistributable generated metadata from proprietary payloads. Prefer a
download-and-extract bootstrap over committing blobs with uncertain rights.
Factory/OTA archives are normally the recovery source when fastboot cannot
read back a partition; do not represent an unverified fetch as a backup.

## 3. Reconstruct the target

Pin the AOSP tag and every external repository revision. Start with the generic
system target only when the stock vendor interface is demonstrably Treble
compatible; otherwise create a device target that repacks the stock-derived
vendor-side partitions around the new framework.

Compare and reconcile:

- VINTF requirements and declared HAL versions;
- vendor/system sepolicy compatibility and neverallow failures;
- kernel ABI, boot header version, bootconfig, DTBO, module load order and
  module signing;
- partition groups, sizes, filesystem types, sparse/raw representation, and
  snapshot/COW state;
- property ownership, init service domains, linker namespaces and APEX paths;
- AVB descriptors, rollback locations, chain partitions and signing keys.

Treat fstab as executable compatibility data. On dynamic A/B devices, a copied
entry that hardcodes `_a`/`_b` or applies slot selection twice can mount the
wrong logical device. Derive runtime mapper expectations from live names such
as `system-verity`, not fixed `dm-N` numbers; device-mapper allocation order is
not stable.

## 4. Build and inspect

Document host packages, tool versions, environment setup, manifest sync,
`lunch` target and build commands. Build `userdebug` and retain target-files so
images can be regenerated without opaque manual steps.

Before hardware writes, inspect image headers, partition fit, filesystem
contents, fstab, VINTF, sepolicy artifacts, AVB descriptors and the full vbmeta
chain. Static checks reduce avoidable risk but do not establish bootability.

## 5. Flash with a transaction boundary

The flash runner should require the expected serial, codename, firmware and
boot mode; verify its bundle allowlist; reject symlinks and unexpected files;
and require an explicit destructive confirmation. Record a transaction before
the first write.

Default to the minimum physical write set. Exclude device-unique,
security-sensitive, provisioning, and calibration state from ordinary bundles
and publish paths—for example `persist`, FRP, keystore/RPMB, EFS/NV,
`modemst`, `fsg`, and OEM calibration partitions. Names vary by device, so
classify every partition rather than relying on this example list. If an
authorized private backup is necessary, keep it encrypted and out of source
control and release artifacts.

Use bootloader fastboot for physical partitions and fastbootd for logical
partitions. Flash only the intended slot. Avoid `--disable-verity` and
`--disable-verification` in the release path. If temporarily used to isolate an
AVB failure, label that boot diagnostic and replace it with a correctly signed
chain before qualification.

Do not write bootloader or radio firmware unless the port demonstrably requires
it and exact anti-rollback compatibility is proven. Never relock around
userdebug/test/custom keys without supported key enrollment, explicit separate
authorization, and a proven unbrick path.

After erasing data/metadata when required, select the target slot and boot. Do
not retire recovery evidence yet.

## 6. Diagnose from evidence

Classify the earliest failure boundary:

- no bootloader or fastboot: physical firmware/USB/recovery problem;
- bootloader rejects image: geometry, rollback or AVB metadata problem;
- kernel reboot/panic: boot image, DTBO, kernel/module or early fstab problem;
- recovery/fastbootd only: vendor boot or logical-partition mount problem;
- animation forever: framework, VINTF, sepolicy, HAL or data-migration problem;
- Android boots with missing hardware: service/HAL/blob/configuration problem.

Collect bootloader variables, pstore/ramoops, recovery logs, kernel log, logcat,
init service state, tombstones and relevant dumpsys output before overwriting
the failing state. Change one causal layer at a time.

## 7. Qualify and publish

Require two ordinary boots of the exact packaged candidate. Verify the expected
fingerprint, slot, `userdebug` variant, boot completion, AVB state, enforcing
SELinux and verity, logical mounts through verified mapper targets, tested-slot
bootable/successful flags, clean critical-service state, and absence of new
boot-critical crashes. Run built-target `checkvintf` and, where practical, a
focused Treble VTS subset; an unavailable on-device checker is not positive
compatibility evidence.

Exercise real peripherals rather than mocks. Capture durable evidence such as
camera-produced JPEGs, active AudioFlinger frames, Wi-Fi scan results, Bluetooth
state, sensor enumeration and touch/display state. State environmental limits
for cellular, GNSS, NFC, UWB, biometrics or other hardware.

Only then finalize the flash transaction and archive its provenance. Package
the exact tested images with a `flash-all` runner, firmware requirements,
source/build identity, licensing notices, recovery instructions and a concise
validation report. Leave the tested system installed unless the user asks for
a restore.
