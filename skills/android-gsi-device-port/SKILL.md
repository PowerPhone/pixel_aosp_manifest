---
name: android-gsi-device-port
description: Port a current Android GSI or AOSP userdebug build to a bootloader-unlocked phone whose OEM no longer publishes matching device trees or vendor blobs, including blob extraction, compatibility fixes, AVB-safe packaging, guarded flashing, and real-hardware qualification. Use for unsupported-device bring-up; do not use for ordinary emulator, officially supported AOSP target, or app-development tasks.
---

# Android GSI Device Port

Produce a reproducible source tree and a recoverable flash bundle, not merely a
`system.img` that passed static inspection.

Design the repository for more than one phone from the outset. Keep shared
pipeline code independent of the product, make one target definition the source
of truth for each codename, and isolate generated vendor trees, build outputs,
logs, and release bundles by target. A new target should normally be data plus
target-specific patches, not another copy of the build and flash scripts.

## Before mutating hardware

- Confirm the exact product/codename, stock build fingerprint, bootloader and
  baseband versions, partition layout, dynamic-partition metadata, active slot,
  unlock state, and availability of both bootloader fastboot and fastbootd.
- Require explicit authorization before unlocking, erasing, flashing, changing
  slots, or rebooting a live device. Treat each newly enumerated USB mode as a
  separate access dependency.
- Obtain the exact factory image used on the phone. Capture recovery-critical
  physical partitions before the first experimental write. Do not assume that
  a virtual A/B device has two independent copies of logical partitions:
  slot-suffixed logical A writes can invalidate Android on B through shared
  `super` metadata.
- Reject every `super` or logical-partition write while a virtual A/B merge,
  snapshot update, or COW state is active or cannot be determined. Re-query in
  bootloader fastboot and fastbootd; mode changes are not proof that a merge
  ended.
- Establish a tested recovery path. Prefer preserving one physical slot's
  bootloader/fastbootd chain, while recording which logical state it can and
  cannot recover. Stop if the only recovery path disappears or the device can
  no longer be addressed.

## Bring-up method

Read [references/workflow.md](references/workflow.md) before extracting blobs,
changing fstab/AVB metadata, building images, or flashing hardware. Adapt names
and commands to the actual device; do not copy partition lists from another
phone.

Keep these invariants throughout the work:

- Vendor files come from one identified stock build and retain provenance and
  redistribution metadata. Never publish proprietary blobs unless their terms
  allow it; provide extraction recipes when redistribution is unclear.
- Pin the manifest, every extra repository, the extractor revision, donor build,
  source-patch base revisions, ordered patch hashes, and generated-vendor
  transformation. Prove that patches replay from their recorded bases instead
  of relying on a long-lived dirty tree.
- The framework build and vendor interface must agree on VINTF, sepolicy,
  linker namespaces, HAL declarations, kernel modules, bootconfig, and dynamic
  partition geometry.
- A name in `PRODUCT_PACKAGES` is not evidence that the module reached an image.
  Resolve the Soong/Make definition and attest the exact installed file in
  target-files. This matters especially for permission and feature XML modules,
  whose omission may not stop the build but can disable framework services or
  crash proprietary clients. Give target-only compatibility modules
  target-scoped names and select them only from that target; an unscoped shim
  can silently satisfy another product's otherwise-missing package.
- AVB bypass is diagnostic evidence only. A release candidate must boot with
  the intended signed vbmeta chain and verified partitions enforcing.
- Do not relock a bootloader around `userdebug`, test-key, or custom-key images.
  Relocking requires supported key enrollment plus a separately authorized and
  proven recovery plan; enforcing verity on an unlocked/orange device is not a
  green/trusted boot claim.
- Flash physical partitions in bootloader fastboot and logical partitions in
  fastbootd. Resolve the exact target slot for every write and reject ambiguous
  serials, products, firmware versions, modes, and bundle contents.
- Never mark a flash transaction complete on the first animation. Require two
  normal Android boots, `sys.boot_completed=1`, expected fingerprint/slot,
  enforcing SELinux and verity, mounted verified mapper targets, the tested
  slot marked bootable and successful, and representative real hardware tests.

## Deliverable

Leave a repository that can rebuild and audit the result: pinned manifests,
blob-extraction configuration, patches, dependency documentation, build and
validation entry points, a self-contained image bundle, and a guarded
`flash-all` script. The runner should fail closed, declare destructive scope,
avoid hidden host assumptions, journal incomplete transactions, and retain a
documented recovery procedure. Before any device command, it must validate an
exact bundle-directory allowlist and a complete checksum manifest. It must also
verify the exact pinned fastboot executable digest before executing it. These
hashes establish integrity consistency, not signed authenticity. Keep
proprietary payloads and private device evidence out of the publishable source
tree; a hash or extraction recipe does not grant redistribution rights.

Record both successes and gaps. At minimum qualify display/touch, both cameras,
audio output, vibration, Wi-Fi, Bluetooth, sensors, storage, USB/ADB, and the
available radio/SIM path. An absent SIM, account, network, or lab instrument is
an untested condition, not a passing result.
