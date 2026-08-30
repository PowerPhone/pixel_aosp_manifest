# Build architecture

> **Scope:** This legacy guide documents the Pixel 11 (`cubs`) workflow only; see the [multi-target layout](multi-target-layout.md) for current target organization.

This project intentionally produces two related outputs instead of conflating
them.

## Pure AOSP GSI

`scripts/sync-source.sh` resolves the immutable `android-17.0.0_r1` tag, and
`scripts/build-gsi.sh` verifies that pinned source before building the standard
`gsi_arm64-aosp_current-userdebug` target. Its `system.img` contains no Pixel
factory image content. This is the portable AOSP 17 development system
requested by the project.

The source tree carries a small pinned host-tool compatibility stack because
the synced `arsclib` module participates in Soong graph validation. Those
additive AAPT2 commands, per-product build-ID fallback, and optional SELinux-CIL
hooks do not alter the generic GSI's runtime product contents.

The raw GSI is a deliberately mixed-partition trial, not a pure-AOSP runtime.
Its only replaced logical framework payload is `system_a`; the trial also
writes `pvmfw_a` and its generated root `vbmeta_a`. The cubs fstab can continue
using stock `system_dlkm`, `vendor`, and `vendor_dlkm` content while the stock
slot-A kernel and boot ramdisks remain in use. The successful GSI boot showed
that `product` and `system_ext` instead come from the root system image:
`/product` resolves to `/system/product`, `/system_ext` resolves to
`/system/system_ext`, and neither path has a separate mount. Both therefore
report the AOSP `CP2A.260605.016` `userdebug` identity and inherit the
read-only ext4 root mount. Retained `system_dlkm`, `vendor`, and `vendor_dlkm`
report Google's `CD1A.260714.001.A9` `user` identity.

That boot proves the recorded framework/vendor split can reach Android; it does
not prove full hardware support. In the raw-GSI probe, Camera2 reached the
resumed state but no camera device stayed open for a usable preview. Repeated
SELinux diagnostics showed `hal_camera_default` unable to find
`com.google.pixel.camera.services.binder.IServiceBinder/default`. The raw GSI
does not contain the extracted Pixel camera service app, matching product
service context, or related system-ext framework JARs. The complete cubs output
statically contains those pieces, but that observation is only a reason to test
the complete product, not evidence that its camera works.

This path minimizes the first experimental write and is useful as a Treble
probe, but validation must record `/proc/mounts`, exact embedded-tree aliases,
dynamic-partition sources, and build properties for every framework/vendor
tree. The complete cubs product is the meaningful final AOSP platform image
because it replaces
the slot-A `system`, `system_ext`, `product`, `system_dlkm`, and vendor-side
logical partitions as one audited set.

The `_a` suffix is a logical metadata namespace, not physical isolation on this
device. Settled `lpdump -a` metadata shows the A and B views beginning on the
same shared-super extents. Even the minimal GSI's `system_a` write invalidates
Android B as a fallback. Flashing preserves B only as a physical
firmware/boot/recovery/fastbootd lifeboat: all 25 firmware and nine boot-chain
partition copies on B remain untouched. Its boot-control success flags do not
attest to the shared logical contents afterward.

## Complete cubs product

The pinned GrapheneOS fork of `adevtool` consumes Google's exact cubs factory
image locally. It reconstructs product makefiles, VINTF declarations, SELinux
policy, firmware metadata, proprietary modules, and a stock-kernel input. The
tool must reproduce its immutable upstream file-tree specification exactly;
verification bypasses and spec updates are prohibited in the normal workflow.

The resulting `cubs` product inherits the generic AOSP system product while
supplying hardware-specific partitions from the extracted support module. Its
self-contained flash set includes exactly 25 individually slotted firmware
images, while the outer aggregate bootloader/radio containers remain excluded.
This track produces target-files and factory-style images packaged for a
controlled complete-device qualification flash. The corrected complete Cubs
bundle passed static validation and repeated real-hardware boot audits with
enforcing dm-verity; broader functional qualification remains incomplete. See
the recorded evidence and limits in [`validation.md`](validation.md).

After the reviewed compatibility sanitizer runs, extraction atomically creates
a local vendor-tree attestation. Its sorted manifest covers regular-file
contents and modes, directory modes, and non-escaping symlink targets. Metadata
binds that tree to the pinned stock archive/build, resolved Repo manifest,
`adevtool` commit, and sanitizer digest. Unsafe pathnames, special files,
external symlinks, either `SELINUX_IGNORE_NEVERALLOWS` assignment, and either
`BUILD_BROKEN_DUP_RULES` assignment are hard failures. Build and packaging
recompute the attestation and compare it byte-for-byte before consuming the
generated module.

After the unmodified upstream FileTreeSpec passes, the sanitizer removes only
the stock-derived duplicate of AOSP's existing `vndservicemanager` transfer
rule and the duplicate's orphaned synthetic type attribute from the normal and
recovery extension CILs. The extracted rule expresses its exclusions through
versioned types inside an opaque generated complement, which can include
`init` and `vendor_init` after final mapping; the native AOSP source rule owns
the same vendor-domain access with exclusions that compile correctly. Both
pristine and sanitized CIL hashes and the native AOSP policy hash are pinned.

The sanitizer also removes only
the generated hostapd and supplicant XML files and their exact Soong module
stanzas, then replaces their product requests with the corresponding AOSP
fragment module names. Those two stock fragments are normalized copies of
declarations owned by pristine AOSP's matching Wi-Fi services; retaining both
producers would create the only two duplicate cubs install targets. Explicitly
requesting the AOSP fragments also covers cubs' proprietary replacement Wi-Fi
binaries, whose generated modules do not carry the source services' required
edges. All other duplicate-rule detection remains strict.

Adevtool's generic fstab pass rewrites every named AVB dependency to root
`vbmeta`, but cubs reconstructs the stock four-child AVB chain. After the
immutable FileTreeSpec succeeds, the sanitizer therefore accepts only the
exact generated fstab digest and atomically restores `vbmeta_system` for the
framework group, `vbmeta_vendor` for `vendor`, and the same-named `boot` and
`init_boot` chains in both generated copies. `vendor_dlkm` remains a direct
root descriptor. The normalized digest and transform helper are attested;
target-files validation requires both installed copies to match those bytes
and the actual root-vbmeta chain target set.

Build completion is a separate attested state. Immediately before `m`, each
build removes its old completion marker. A successful invocation does not
restore that marker until its required images, host packaging tools, and cubs
target-files have all been hashed. The marker also commits to the resolved Repo
manifest and reviewed patch lock; the cubs marker commits to the vendor-tree
attestation. Packagers regenerate and byte-compare this record against live
outputs, preventing a failed build from being followed by packaging of files
left behind by an older run.

## Boundary between public and local state

Version controlled:

- source revisions and local Repo manifests;
- download URLs and cryptographic digests;
- host, extraction, build, packaging, flash, restore, and validation scripts;
- generated-output verification logic and redacted validation records.

Ignored local state:

- Google factory and OTA archives;
- unpacked partition images and extracted proprietary binaries;
- generated `vendor/google_devices/cubs` content;
- generated-vendor content/mode/symlink attestations;
- source and compiler output trees;
- distributable image bundles pending an explicit licensing review;
- device identifiers, ADB keys, and other host credentials.

This boundary lets the repository describe and reproduce the work without
redistributing Google's proprietary artifacts.
