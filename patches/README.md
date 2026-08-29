# Compatibility patch provenance

These patches are the audited delta from exact `android-17.0.0_r1` source. They
are applied idempotently by `scripts/apply-source-patches.sh`.

`BASE_REVISIONS` is the machine-enforced project/base lock. The patch driver
rejects a stack unless its repository is at the exact locked commit, and lint
cross-checks every entry against `manifests/resolved.xml`.

Exact bases:

- `build/make`: `5ce6f787337d0223710bf7d4a16dbe6d2a35f777`
- `build/soong`: `6722dd8833db7482df1a2543ca3fcf67ddf0f7b1`
- `frameworks/base`: `94b4c163b7dfe5ce3607f7bb8456f9573f7de57d`
- `packages/apps/CarrierConfig2`: `9d56beab5824252e6fcdd09c04726d276343b247`
- `system/core`: `545d2487e38192a2ce25040897ced877cf6b4f53`
- `system/sepolicy`: `e066568e98d86db31a9346d30977f3632fa7073c`
- `tools/apksig`: `179f60df00d242f6bb22acf828b0884eac2d5f72`
- `vendor/adevtool`: `b01ccecab3468f3bcfa0d23adc361ad074989674`

## Upstream patches

The imported patches below target five Apache-2.0 AOSP repositories maintained
as GrapheneOS forks. The linked commits are the upstream provenance; all other
patches in this tree are the project-authored adapters described separately.

| Local patch | Upstream commit |
| --- | --- |
| `build/0001-per-product-build-id.patch` | [`ddd3c728381776d403cd0e1d68a92ffedab10373`](https://github.com/GrapheneOS/platform_build/commit/ddd3c728381776d403cd0e1d68a92ffedab10373) |
| `build-soong/0002-disable-dexpreopt-check-for-prebuilt-standalone-jars.patch` | [`1f8a2eb90fd78ddefc98d57a968ea009096406b3`](https://github.com/GrapheneOS/platform_build_soong/commit/1f8a2eb90fd78ddefc98d57a968ea009096406b3) |
| `frameworks-base/0001-aapt2-stringified-configuration.patch` | [`e32622a9af583b1cf73555fb985b49e0f73223f7`](https://github.com/GrapheneOS/platform_frameworks_base/commit/e32622a9af583b1cf73555fb985b49e0f73223f7) |
| `frameworks-base/0002-aapt2-proto-adevtool-conversion.patch` | [`f18597e43abd313efb82d349c0cd425dd6ca3389`](https://github.com/GrapheneOS/platform_frameworks_base/commit/f18597e43abd313efb82d349c0cd425dd6ca3389) |
| `frameworks-base/0003-aapt2-brief-package-info.patch` | [`7b672d6832764cf122456a9ae383445dcfe88c73`](https://github.com/GrapheneOS/platform_frameworks_base/commit/7b672d6832764cf122456a9ae383445dcfe88c73) |
| `frameworks-base/0004-aapt2-proto-java-library.patch` | [`040c88b56c6a0e454d23afcd356e21b10ad6e42e`](https://github.com/GrapheneOS/platform_frameworks_base/commit/040c88b56c6a0e454d23afcd356e21b10ad6e42e) |
| `frameworks-base/0005-aapt2-brief-package-library.patch` | [`255257eb3a8ccaef7787e462ee27da6cf9b37538`](https://github.com/GrapheneOS/platform_frameworks_base/commit/255257eb3a8ccaef7787e462ee27da6cf9b37538) |
| `system-sepolicy/0001-support-extending-sepolicy-cils.patch` | [`c31a4b7f23144ff9f27bcca999a6b3ccb1032bbc`](https://github.com/GrapheneOS/platform_system_sepolicy/commit/c31a4b7f23144ff9f27bcca999a6b3ccb1032bbc) |
| `apksig/0001-add-print-certs-command-for-adevtool.patch` | [`ba4d984e1a360d427307d669d2f789212130e9e8`](https://github.com/GrapheneOS/platform_tools_apksig/commit/ba4d984e1a360d427307d669d2f789212130e9e8) |

The numbered AAPT2 series must remain in that order.

The `apksig` patch adds `adevtool`'s batched `print-certs` command. That mode
extracts signer certificates without verifying APK content, exactly as the
upstream commit documents. Its inputs are restricted to files extracted from
the checksum-pinned stock factory archive; `adevtool generate-all` verification
itself remains enabled, and this workflow never passes `--noVerify`.

## Project-authored adapters

- `adevtool/0001-pristine-aosp-compatibility.patch` adapts the pinned MIT
  GrapheneOS adevtool configuration to public AOSP resources/policy and keeps
  the secondary-slot odex image out of the bring-up product. Its upstream
  notice is retained at `../LICENSES/adevtool-MIT.txt`.
- `carrierconfig2/0001-omit-grapheneos-test-apis.patch` excludes two debug-only
  classes from the pinned MIT CarrierConfig2 project because they import APIs
  absent from AOSP. Runtime carrier configuration remains included; the
  upstream notice is retained at `../LICENSES/carrierconfig2-MIT.txt`.
- `adevtool/0002-malibu-avb-chain-topology.patch` reconstructs the stock
  Pixel 11 AVB chain layout missing from pristine AOSP device support. It
  groups `pvmfw` and framework partitions under `vbmeta_system` at rollback
  location 1, `vendor` under `vbmeta_vendor` at location 3, and chains
  `boot`/`init_boot` at locations 2/4. Source-built userdebug images use the
  public AOSP RSA-4096 test key and the AOSP release SPL rollback index.
  Adevtool's generic extraction pass subsequently collapses named fstab AVB
  dependencies to root `vbmeta`; the post-FileTreeSpec sanitizer restores the
  exact corresponding child names in both generated `fstab.malibu` copies.
  Static validation ties those installed mappings back to this root chain.
- `adevtool/0003-strict-aosp17-sepolicy.patch` removes the GrapheneOS-only
  debug-shell write to the vendor-owned `gos-dhdutil` property. Pristine AOSP
  17 deliberately forbids this core-to-vendor property write; the patch keeps
  the confined helper and its result writer without adding a property-owner
  violator attribute or weakening neverallow enforcement.
- `adevtool/0004-malibu-firmware-avb-descriptors.patch` restores the public
  AOSP side of Pixel 11 bootloader packaging. It declares the exact 24 stock
  A/B firmware partitions, supplies a dependency-free strict FBPK v2 unpacker,
  and creates legacy-Make descriptor carriers without changing the extracted
  raw firmware. Each carrier is a raw image copy with an AVB hash footer. Its
  salt is the concatenation of the lowercase hexadecimal SHA-256 digests of
  `BUILD_NUMBER_FILE` and `BUILD_DATETIME_FILE`; its partition size is
  `64 KiB + 4 KiB + round_up(raw_size, 4 KiB)`. Both identity files, the raw
  image, and `avbtool` are normal build prerequisites. A static pattern rule
  enumerates only the reviewed 24 carrier targets, as required by Kati. The
  carriers enter the root-vbmeta descriptor arguments and target-files radio
  inputs, while the direct root vbmeta target depends on every carrier.
- `build/0008-propagate-pvmfw-signing-metadata.patch` introduces distinct
  signing-only `misc_info` fields for the inherited RSA-4096 AVB key and
  algorithm used to reconstruct pVM firmware. Releasetools consumes and can
  replace those fields without interpreting `pvmfw` as a separately chained
  partition; incomplete or mixed signing modes fail closed. The patch also
  pins the direct image's empty-payload identity salt, avoids injecting a
  second global salt, and tracks both the fingerprint and selected signing key
  as normal prerequisites. This prevents target-files from replacing the
  valid pVM footer with unsigned `Algorithm: NONE` metadata or a different
  hash identity.
- `build-soong/0005-select-adevtool-fbpack-unpacker.patch` makes fsgen prefer
  the reviewed `vendor/adevtool` FBPK unpacker when it exists, while retaining
  the original Google-prebuilt path as a backwards-compatible fallback. It
  rejects a configured bootloader when neither executable exists and tracks
  all Python files beside the selected tool as dependencies. It also promotes
  the build-number and date inputs of each Soong firmware carrier from
  order-only to normal dependencies, preventing stale descriptors after an
  incremental identity change. Focused tests pin the exact Malibu preferred
  and fallback paths, salt command, size expression, and dependency class.
- `build/0002-align-soong-gsi-avb-policy.patch` makes the Soong-built GSI
  system image honor `BoardConfigGsiCommon.mk`'s existing RSA-2048 chain key
  and security-patch rollback index. The tag-locked patch pins the UTC epoch
  for the release's `2026-06-05` SPL because Soong's filesystem
  `rollback_index` property is not configurable. Without it, AOSP 17's root `vbmeta.img`
  cannot authenticate the selected Soong `system.img`. This adapter is scoped
  to GSI filesystem defaults and leaves other generic system images unchanged.
- `build/0003-render-make-build-dates-in-utc.patch` and
  `build-soong/0001-render-build-props-in-utc.patch` make both legacy Make
  sysprops and Soong's `gen_build_prop` render the pinned epoch in UTC. Ninja
  deliberately filters ambient `TZ`, so exporting it in a wrapper alone is not
  a reproducible input.
- `build/0004-propagate-deterministic-dtbo-salt.patch` moves Make's existing
  deterministic DTBO salt expression into the footer-argument set shared with
  `misc_info.txt`. `build-soong/0003-propagate-deterministic-dtbo-salt.patch`
  generates the same salt once and binds both the fsgen direct signer and its
  target-files metadata to it. Without these paired fixes, releasetools strips
  and rebuilds the prebuilt DTBO footer with the generic fingerprint-derived
  salt, so product, target-files, and reconstructed DTBO—and consequently root
  vbmeta—differ despite identical inputs. The byte derivation intentionally
  remains AOSP's concatenated SHA-256 digests of the build-number and date
  files. These are project-authored Android 17 fixes; neither the pinned AOSP
  tag nor current upstream AOSP/GrapheneOS propagates the salt into DTBO
  metadata.
- `build/0005-track-dtbo-avb-identity-inputs.patch` declares the product
  fingerprint and conditional deterministic-salt files as normal prerequisites
  of Make's 4K and 16K AVB DTBO targets. It applies the same dependencies to
  `misc_info.txt` only when that file emits AVB metadata for a prebuilt DTBO.
  This prevents an incremental build from retaining a stale footer or
  releasetools argument after an identity input changes, without rebuilding
  non-AVB or non-DTBO products. This is a project-authored Android 17 fix.
- `system-core/0001-preserve-devnode-description-modes.patch` makes
  `mkbootfs -n` entries retain the explicit modes and device numbers from the
  node description even when releasetools also supplies a canned filesystem
  config. It zero-initializes synthetic `stat` records and adds a host test
  that proves option-order-independent CPIO bytes and the intended `0755`
  directory/`0600` character-device metadata. This prevents a rebuilt
  `init_boot` from silently changing its `/dev` permissions.
- `build/0006-merge-vendor-ramdisk-staging.patch` overlays the vendor
  ramdisk and optional recovery root into a clean intermediate tree before
  one `mkbootfs` invocation. This gives direct Make output the same global
  path ordering and clean-staging semantics as target-files reconstruction,
  avoiding byte drift in `vendor_boot` while preserving the existing overlay
  precedence. `build-soong/0006-merge-cpio-roots-before-archiving.patch`
  applies the same rule to fsgen filesystems with `include_files_of`: it uses
  the tracked host `acp`, keeps every included partition image as a normal
  input, and tests cleanup, overlay order, and a single merged-root archive
  invocation. Together the paired patches keep Make, Soong diff-test, and
  releasetools CPIO bytes aligned.
- `build/0007-propagate-make-boot-salts.patch` adds Make's deterministic
  build-number/date salt to the target-files metadata for each Make-signed
  `init_boot`, `vendor_boot`, and `vendor_kernel_boot` image. It also makes
  those direct image targets and `misc_info.txt` depend normally on the two
  identity files. Without this patch, direct and target-files ramdisk bytes
  are identical but releasetools substitutes the fingerprint digest as the
  AVB salt, changing all three images and root `vbmeta`. This is a
  project-authored Android 17 fix.
- `build-soong/0004-propagate-deterministic-boot-salts.patch` makes each
  fsgen `make_legacy` boot-image module generate its AVB salt once and bind
  both the product image signer and target-files `misc_info.txt` to that exact
  value. `boot` retains AOSP's SHA-256 digest of the kernel, while `init_boot`,
  `vendor_boot`, and `vendor_kernel_boot` retain the concatenated SHA-256
  digests of the build-number and date files. Without the metadata argument,
  releasetools chooses a different default salt when reconstructing the three
  non-kernel images, so their bytes and root vbmeta differ from the directly
  built product. This is a project-authored Android 17 fix.
- `build-soong/0002-disable-dexpreopt-check-for-prebuilt-standalone-jars.patch`
  is the exact GrapheneOS AOSP 17 fix for 10th-generation Pixel prebuilt
  standalone `system_server` JARs. The upstream checker cannot resolve such a
  JAR from its generated proprietary Soong namespace; the patch disables only
  that build-time dexpreopt artifact check and leaves the prebuilt JAR,
  `PRODUCT_STANDALONE_SYSTEM_SERVER_JARS`, and dexpreopt configuration intact.
  The cubs completion attestation compensates for the disabled generic check:
  it requires dexpreopt to remain enabled for exactly
  `system_ext:malibu-plugin-provider`, then binds the installed JAR and its
  arm64 ODEX/VDEX artifacts byte-for-byte between the product output and
  target-files. The installed JAR must also equal the generated-vendor source
  JAR and all three copies must pass ZIP/JAR integrity checking. Static
  validation independently repeats those checks and minimum OAT/VDEX magic
  validation against the attested digests before and after bundle publication.
