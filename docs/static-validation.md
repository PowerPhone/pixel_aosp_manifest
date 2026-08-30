# Static image validation

> **Scope:** This legacy guide documents the Pixel 11 (`cubs`) workflow only; see the [multi-target layout](multi-target-layout.md) for current target organization.

`scripts/validate-images.sh` is the final, read-only gate between packaging
and any device operation. It validates completed bundles against the build
outputs that produced them; it does not invoke `adb`, `fastboot`, or any USB
tool.

Run one target, or both:

```bash
scripts/validate-images.sh gsi
scripts/validate-images.sh cubs
scripts/validate-images.sh all
```

The usual path overrides are supported: `AOSP_SOURCE_DIR`, `AOSP_OUT_DIR`,
`DEVICE_OUT_DIR`, `GSI_ARTIFACT_DIR`, `CUBS_ARTIFACT_DIR`, and
`CUBS_TARGET_FILES`. All resolved source, output, and artifact paths must stay
inside this project workspace.

## What is proven

For both bundle kinds the validator fails closed on extra, missing, symlinked,
empty, or executable image files. It verifies the exact `SHA256SUMS` coverage,
including the executable `flash-all.sh`, checks that the copied flash runner is
also byte-identical to the reviewed source,
and validates the exact `BUNDLE_INFO.txt` and successful-build attestation
schemas. The attestation pins the Repo serializer/resolver implementation and
is re-derived from the resolved source manifest, patch lock, patch-base lock,
release configuration, host tools, and current build outputs. The validator
independently re-creates this four-file source-closure hash. It also requires
`strict_build_policy=true` and the configured non-identifying build
number, username, hostname, timestamp, timezone, and locale. Together these
checks reject interrupted, stale, mixed, or host-identity-dependent builds.
The exact marker also hashes the product-specific Soong variables file and
requires both missing-dependency tolerance and SELinux neverallow suppression
to be `false`; either relaxation set to `true` is a hard validation failure.
It separately hashes Soong's product-specific consumed-environment record;
marker verification rejects unaudited nonempty environment inputs. Static
validation independently repeats the full strict Soong-variable policy and
the exact consumed-environment schema/allowlist rather than trusting the
marker's `strict_build_policy` assertion. That policy rejects ambient
sanitizers for the GSI and requires exactly `memtag_heap` for cubs, preserving
the deliberate global heap-MTE setting from the pinned Armv9 Pixel board
configuration.
For cubs it also pins the built `check_target_files_vintf` and `checkvintf`
executables; completion verification reruns the former against the attested
target-files package, whose `META/misc_info.txt` must explicitly set
`vintf_enforce=true` so the checker cannot silently skip enforcement.
The pinned Soong compatibility patch disables AOSP's generic
`dexpreopt_systemserver_check`, which cannot resolve the extracted standalone
system-server JAR across Soong namespaces. As a fail-closed replacement, the
cubs marker hashes the exact dexpreopt configuration and requires preopt to be
enabled, `system_other` placement to be disabled, and the standalone list to
contain exactly `system_ext:malibu-plugin-provider`. It also hashes these exact
target-files entries and requires each to equal its live product-output file:

- `SYSTEM_EXT/framework/malibu-plugin-provider.jar`
- `SYSTEM_EXT/framework/oat/arm64/malibu-plugin-provider.odex`
- `SYSTEM_EXT/framework/oat/arm64/malibu-plugin-provider.vdex`

Static validation recomputes all three digests instead of trusting the marker.
The source, installed, and target-files JARs must be byte-identical and each
must pass ZIP integrity checking. Both target-files and product-output ODEX
files must contain exactly one `oat\n` header magic, and both VDEX files must
begin with `vdex`. The semantic replacement then reads the generated
`javalib.invocation` with Bash `mapfile` (the real 35th record has no trailing
newline), requires exactly 35 logical records, and pins the complete file plus
its boot-class-path and class-loader-context records. It requires arm64,
`cortex-a76`, default instruction features, `-Xgc:CMC`, speed compilation,
`copy-dex-files=false`, the exact 52-entry boot class path, the exact 18-entry
standalone class path, and no verify/profile/app-image fallback.

The host `oatdump` binary is built through the same pinned Android 17 cubs
environment and its SHA-256 is fixed in `config/cubs-dexpreopt.env`. It is run
read-only with the exact `--oat-file=...`, `--dex-file=...`, `--header-only`,
and `--no-disassemble` argument grammar. Validation requires a clean exit and
no error, fatal, failure, or warning record; OAT magic/version 275; the pinned OAT header
checksum; Arm64 with `-a53,crc,lse,fp16,dotprod,-sve`; one dex file; SDK 37;
the pinned boot-image checksums; prebuilt/speed policy; and CMC's
`concurrent-copying=false`. The stored class path must contain all 18 ordered
locations with their exact dex checksums, including the pinned `services.jar`
checksum, and the target JAR must have exactly one `classes.dex` with the
pinned CRC32. The config is an output-validation policy rather than an Android
build input, so changing it does not invalidate an unrelated completed GSI.
The paths follow cubs' source-locked `TARGET_COPY_OUT_SYSTEM_EXT := system_ext`
and disabled `BOARD_USES_SYSTEM_OTHER_ODEX`; generic AOSP's
`SYSTEM/system_ext`, `SYSTEM_OTHER`, APEX-style, split, or duplicate locations
are deliberately rejected for this product.

The host-only regression suites cover both packaging structure and semantic
mutation rejection without enumerating or contacting a device:

```bash
scripts/tests/simulate-cubs-dexpreopt-validation.sh
scripts/tests/simulate-cubs-dexpreopt-semantics.sh
```

It also checks that:

- metadata distinguishes the pinned source AOSP build ID from the emitted
  build ID, and identifies SDK 37, `userdebug`, the framework security patch,
  cubs, slot-A partition-name flashing over shared `super`, and the physical
  slot-B fastbootd lifeboat;
- firmware requirements match the checksum-pinned stock factory package;
- Android sparse headers expand consistently where that container is allowed,
  while raw images remain unmodified;
- each filesystem image uses its product-specific reviewed format and passes
  read-only integrity checking (`e2fsck -n` for the raw-ext4 GSI root and
  `fsck.erofs` for the cubs logical images);
- build properties are read from the filesystem payload, rather than trusted
  only from surrounding text metadata; and
- AOSP `avbtool` verifies vbmeta signatures, chained keys, rollback locations,
  partition hashes, and dm-verity trees as a complete graph rooted exclusively
  in `vbmeta.img`; unrelated signed footers do not count as reachable coverage.
  Root and chained-child public-key identifiers must also derive from the
  source-locked AOSP RSA test keys, preventing coordinated key drift.

The GSI `system.img` is tied byte-for-byte to
`out_pixel/gsi/target/product/generic_arm64` and must be the exact raw ext4
layout selected by the build/runtime audit. Android-sparse and EROFS variants
are rejected even if their expanded files would otherwise be readable. The
root entries must be the exact aliases `/product -> /system/product` and
`/system_ext -> /system/system_ext`. The compatibility entry
`/system/etc/init/config` must itself be a symlink to
`/system/system_ext/etc/init/config`, whose `skip_mount.cfg` is byte-for-byte:

```text
# Skip "system" mountpoints.
/oem
/product
/system_ext
# Skip sub-mountpoints of system mountpoints.
/oem/*
/product/*
/system_ext/*
/system/*
```

The embedded `/system/product/etc/build.prop` and
`/system/system_ext/etc/build.prop` files must each carry their exact
partition-specific `CP2A.260605.016`, `userdebug`, `test-keys`, and full GSI
fingerprint properties. The system-ext file must contain exactly one literal
`ro.adb.secure=0`; the validator does not infer that development ADB policy
from runtime documentation or the root system build properties.

The GSI root vbmeta must use SHA256/RSA-4096 with flags clear, retain the
rollback-index-zero policy, and chain only `system` at rollback location 1.
The chained system footer must use SHA256/RSA-2048, carry the June 5 rollback
timestamp, describe exactly one sha256 system hashtree, and attest Android 17
plus the pinned SPL. Its system payload must be the pinned Android 17
`userdebug` release. The pVM firmware is accepted as a nonempty, 4 KiB-aligned
AVB image within its 1 MiB partition capacity. Its footer must contain one
`pvmfw` hash descriptor, use SHA256/RSA-4096 under the pinned AOSP test key,
and carry the deterministic SHA-256 empty-input salt. Its payload is then
unpacked as an Android 17 boot-header-v3 image.

Focused raw-ext4 fixtures prove the positive layout and reject sparse/EROFS
containers, each wrong symlink target, changed mount suppression, mismatched
embedded identities, and missing, duplicated, or enabled ADB authentication:

```bash
scripts/tests/simulate-gsi-static-layout.sh
```

For cubs, validation is intentionally heavier. It re-runs the attested AOSP
`img_from_target_files` tool and requires the resulting ZIP hash to equal the
packaging provenance record. Every bundled image must equal the corresponding
reconstructed entry. `META/ab_partitions.txt` must name exactly the 40 reviewed
images. Each of the 25 individual firmware payloads must have the same digest
in generated `vendor/google_devices/cubs/firmware`, target-files `RADIO/`, the
reconstructed ZIP, the exact bundle, and the checksum-pinned stock inner ZIP.
The outer `bootloader.img` and `radio.img` aggregates are rejected from both
the reconstructed ZIP and bundle. The five directly built leaf images
(`boot`, `init_boot`, `dtbo`, `vendor_boot`, and `vendor_kernel_boot`) are
checked as a four-way identity: their attested digest, current product-output
file, `IMAGES/` entry in target-files, and reconstructed/bundled image must all
match. Root `vbmeta` is attested from target-files and must match the
reconstructed/bundled image; this is the canonical root because target-files
also reconstructs the dynamic filesystem images whose descriptors it carries.
The complete reachable AVB graph is then verified against those final images.
This prevents a completed marker or target-files archive from being combined
with images from another build. `META/misc_info.txt` must describe the audited
10,737,418,240-byte super device, its 10,733,223,936-byte dynamic group, and
exactly the six expected EROFS partitions; their expanded sizes must fit the
group. The canonical target-files pVM firmware is separately attested and must
verify under AOSP's pinned RSA-4096 userdebug key with exactly one `pvmfw`
hash descriptor and the deterministic SHA-256 empty-input salt. The product
and target-files `misc_info` copies must use the signing-only pVM key and
algorithm fields while omitting every conventional pVM chain field. Unsigned
`Algorithm: NONE` reconstruction or an accidental new AVB chain is rejected
before packaging. Boot, init-boot, vendor-boot,
vendor-kernel-boot, pVM firmware, and DTBO
headers and partition capacities are checked. The pVM firmware may be shorter
than its 1 MiB partition but must be nonempty, 4 KiB aligned, and independently
pass AVB footer verification. The boot kernel must equal the
adevtool-pinned stock `Image.lz4`, decompress to an arm64 Image declaring 4 KiB
pages, and identify its `-4k` kernel build.

The cubs `vendor_boot` check also parses the v4 header and ramdisk table rather
than relying only on `unpack_bootimg`. It requires the stock-shaped 2,048-byte
page size, a nonempty vendor ramdisk, and exactly one complete platform
fragment with the canonical empty name and all-zero board ID used by both the
pinned stock image and this product. The table, bootconfig, and AVB original
image size must tightly and safely bound one another, including zero alignment
padding. The bootconfig must retain the exact module-loading policy and UFS
boot-device declaration, while the kernel command line must contain
`bootconfig` and exactly one stock-kernel ABI-size token. Other command-line
bytes are deliberately not compared with stock, allowing the reviewed
`userdebug` and heap-MTE policy to differ. Focused fixtures reject empty,
partial, shifted, renamed, recovery-only, board-selected, overrun, and
semantically altered variants:

```bash
scripts/tests/simulate-cubs-vendor-boot-layout.sh
```

The hostapd and supplicant VINTF fragments each must have exactly one generated
install rule, from the corresponding pinned `external/wpa_supplicant_8` AOSP
module rather than the removed vendor generator module. Target-files must
contain each fragment exactly once at its canonical `VENDOR/` path, nowhere
else by the same basename, and with the exact deterministic `assemble_vintf`
output digest. The sanitizer separately pins the pristine AOSP source bytes;
the installed form records that input path and normalizes indentation and the
device-manifest schema version. Both installed digests are committed to the
build-completion attestation and independently recomputed
during bundle validation.

Every build-type declaration in target-files must be `userdebug`. Canonical
build properties for each of `system`, `product`, `system_ext`, `system_dlkm`,
`vendor`, and `vendor_dlkm` must independently and uniquely identify SDK 37,
Android 17, the stock-shaped output build ID, and test-key `userdebug` output;
one correct partition cannot mask a conflicting property in another.

The cubs AVB root must have exactly four SHA256/RSA-4096 chains: `boot` at
rollback location 2, `init_boot` at 4, `vbmeta_system` at 1, and
`vbmeta_vendor` at 3. Every child uses the June framework-SPL rollback epoch
with flags clear. The system child covers exactly `pvmfw`, `product`, `system`,
`system_dlkm`, and `system_ext`; the vendor child covers exactly `vendor`.
`dtbo`, `vendor_boot`, `vendor_kernel_boot`, and `vendor_dlkm` remain direct
root descriptors. Duplicating child-group descriptors into the root is
rejected. Additional proprietary firmware descriptors are required to match
the complete partition-name topology of the checksum-pinned stock root vbmeta;
arbitrary extra root descriptors are not accepted. Root AVB directly describes
24 of the 25 firmware payloads. `modem.img` is absent from the stock AVB
descriptor topology and is therefore authenticated by exact pinned-stock
digest equality instead.

The validator also extracts both installed `fstab.malibu` copies from
target-files and requires them to be byte-identical to one another and to both
attested generated-vendor copies. Their exact active mapping is enforced:
`system`, `system_dlkm`, `system_ext`, and `product` use `vbmeta_system`;
`vendor` uses `vbmeta_vendor`; `boot` and `init_boot` use their same-named
chains; and `vendor_dlkm` remains root-direct. Key-bypass flags, extra AVB
records, and partial mappings are rejected. The set of non-root fstab targets
is derived independently and must equal the chain-partition set parsed from
the packaged root `vbmeta.img` metadata. Focused fixtures exercise the exact
post-FileTreeSpec transform and reject mapping, chain, and bypass mutations:

```bash
scripts/tests/simulate-cubs-fstab-avb-mapping.sh
```

Root and child vbmeta files must be nonempty, 4 KiB aligned, and fit their
65,536-byte physical partitions.

Target-files must contain exactly one canonical `META/vbmeta_digest.txt` (a
lowercase SHA-256 followed by one line feed). The independent validator
recalculates that digest from the reconstructed root and chained images that
are actually packaged, rather than from the different direct product-output
vbmeta variants, and requires an exact match.

The cubs output deliberately uses the stock-shaped build ID
`CD1A.260714.001.A9` for vendor compatibility while its framework payload and
SPL come from the pinned AOSP 17 source release (`CP2A.260605.016`,
`2026-06-05`). These are separately attested and must not be conflated.

The cubs image-ZIP reconstruction and AVB hashtree verification read several
gigabytes and use temporary sparse files under `work/static-validation/`.
Allow adequate local disk space and do not interrupt the mandatory packaging
gate.

## Scope boundary

Static validation proves internal format, identity, provenance, sizing, and
cryptographic consistency. It cannot prove that proprietary HALs satisfy VINTF
at runtime, that SELinux policy permits the real boot path, that display/radio/
camera hardware works, or that the bootloader accepts every image. Those are
separate controlled slot-A flash and on-device validation stages. AOSP
`userdebug` images use development signing keys, and the raw GSI trial
deliberately flashes vbmeta with verification disabled; neither should be
described as a production security configuration.

The slot-B lifeboat describes a physical boot/init/vendor-boot path into
fastbootd. Dynamic logical partitions live in shared `super`; validation does
not claim that a complete stock Android system remains independently preserved
on slot B. The final runner adds a separate live gate that static image
validation cannot supply: a fresh private handoff from exact stock-B Android to
the same fastboot transport for the full-OTA route, or a fresh handoff from the
separately verified direct physical-B fastbootd lifeboat. Both sources are
bound to their source-specific provenance, the reviewed policy, selected
transport, and canonical sizes of all 34 physical B partitions. Host-only mock
tests prove rejection, claim, exact-bundle resume, consumption, and restore
invalidation without enumerating a USB device.
