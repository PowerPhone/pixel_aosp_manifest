# Multi-target repository layout

Phone identity is an explicit workflow input. The shared profile loader accepts
only `cubs` and `frankel`, loads
`config/targets/$PIXEL_TARGET/release.env`, and verifies that the profile's
codename matches the selection. It never selects a target from an attached USB
device; live product probing is a check against the selected profile.

For compatibility with the original Pixel 11 repository, an unset
`PIXEL_TARGET` currently defaults to `cubs`. New commands and all reproduction
instructions should still set it explicitly:

```bash
PIXEL_TARGET=cubs scripts/check-device.sh
PIXEL_TARGET=frankel scripts/check-device.sh
```

An unknown target, a target name containing a slash, or a profile outside its
reviewed directory fails while loading common configuration.

## Current support matrix

| Phone | Codename | Platform | Implemented repository scope | Qualification state |
| --- | --- | --- | --- | --- |
| Pixel 11 | `cubs` | Malibu | Existing complete-device workflow plus the legacy Cubs-bound GSI, recovery, static-validation, and runtime-validation stack | Existing Cubs workflow; its evidence is separate from Frankel |
| Pixel 10 | `frankel` | Laguna | Stock acquisition/extraction, adevtool generation and sanitization, source-built `frankel-aosp_current-userdebug`, complete guarded device bundle, dedicated runtime gate, and standalone A-only runner | Hardened bundle completed two hardware boots and two 66-pass/zero-failure runtime gates; broader end-to-end qualification remains partial |
| Pixel 9 | not defined | not defined | None | Roadmap only; there is no profile, target hook, bundle, or qualification record |

The two implemented profiles share the public Android 17 source and host
toolchain pins but not their device topology:

| Property | Pixel 11 / Cubs | Pixel 10 / Frankel |
| --- | --- | --- |
| Stock baseline | `CD1A.260714.001.A9` | `CP2A.260805.005` |
| `super` size | 10,737,418,240 bytes | 8,531,214,336 bytes |
| Supplied firmware payloads | 25 | 23 |
| DRAM-init range | `dram_init_0` through `dram_init_11` | `dram_init_0` through `dram_init_9` |
| fstab | `fstab.malibu` | `fstab.laguna` |
| Platform plugin provider | `malibu-plugin-provider` | `laguna-plugin-provider` |
| Reconstructed AVB | Cubs child-vbmeta chain and firmware descriptor carriers | One root `vbmeta`, 12 direct OS descriptors, zero chain descriptors |

Frankel root `vbmeta` directly describes `boot`, `dtbo`, `init_boot`, `pvmfw`,
`vendor_boot`, `vendor_kernel_boot`, `system`, `system_dlkm`, `system_ext`,
`product`, `vendor`, and `vendor_dlkm`. Its bundle intentionally omits
`vbmeta_system.img` and `vbmeta_vendor.img`; the standalone runner leaves those
stock physical partitions unchanged. Cubs AVB assumptions must not be applied
to Frankel.

## Current checked-in layout

The repository currently uses a staged multi-target layout rather than the
fully nested target tree proposed for later cleanup:

```text
config/
  release.env                         shared AOSP/build/toolchain pins
  recovery.env                        legacy Cubs-only recovery policy
  cubs-dexpreopt.env                  Cubs-only validation policy
  targets/
    README.md
    cubs/release.env                  Pixel 11 stock and product identity
    frankel/release.env               Pixel 10 stock and product identity
manifests/
  pixel-devices.xml                   shared extraction-tool projects
  resolved.xml                        one locked source closure
scripts/
  lib/common.sh
  lib/target-profile.sh
  extract-vendor.sh                   profile-aware, target sanitizer dispatch
  build-device.sh                     profile-aware complete-device build
  package-device.sh                   Cubs implementation / Frankel dispatch
  package-device-frankel.sh           Frankel bundle policy
  sanitize-generated-vendor.sh        Cubs/Malibu hook
  sanitize-generated-vendor-frankel.sh
  flash-a.sh                          legacy standalone Cubs/GSI runner
  flash-frankel.sh                    standalone Frankel A-only runner
patches/adevtool/
  0001-pristine-aosp-compatibility.patch
  0002-malibu-avb-chain-topology.patch
  0003-strict-aosp17-sepolicy.patch
  0004-malibu-firmware-avb-descriptors.patch
  0005-laguna-pristine-aosp-compatibility.patch
patches/frameworks-base/
  0006-pixel-euicc-gservices-flags-provider.patch
patches/frameworks-native/
  0001-define-missing-feature-prebuilts.patch
docs/
  frankel-baseline.md
  frankel-build-and-flash.md
  frankel-validation.md
  multi-target-layout.md
```

`config/release.env` contains only inputs shared by the current profiles: the
AOSP revision and framework SPL, deterministic build identity, Repo, adevtool,
Node.js, Yarn, and Platform-Tools pins. Each target `release.env` contains its
codename, marketing name, platform, exact lunch target, stock build and SPL,
required bootloader/baseband, and pinned factory/OTA artifacts.

Partition arrays and mutation policy are not data in those `.env` files. They
remain reviewed target-specific code in the current packagers, sanitizers,
attesters, and standalone flash runners. This is intentional until a common
abstraction is supported by evidence from more than one platform.

## Current output and private-state paths

The implemented scripts currently use these paths:

```text
work/aosp/                                      shared source checkout
work/aosp/vendor/google_devices/cubs/           generated Cubs vendor tree
work/aosp/vendor/google_devices/frankel/        generated Frankel vendor tree
work/aosp/out_pixel/gsi/                        legacy Cubs-bound GSI build
work/aosp/out_pixel/cubs/                       Cubs complete-device build
work/aosp/out_pixel/frankel/                    Frankel complete-device build
work/attestations/cubs-generated-vendor.attestation
work/attestations/frankel-generated-vendor.attestation

downloads/<target-specific factory or OTA filename>.zip
work/stock/cubs-<lowercase-build>/
work/stock/frankel-<lowercase-build>/

logs/build-gsi.log                              legacy Cubs-bound GSI log
logs/build-cubs.log
logs/build-frankel.log

artifacts/gsi/                                  legacy Cubs-bound GSI bundle
artifacts/cubs/                                 Cubs complete-device bundle
artifacts/frankel/device/                       Frankel complete-device bundle

.cache/recovery-anchor/                        legacy Cubs-only private state
```

Downloads, stock directories, generated source, build output, attestations,
artifacts, logs, and recovery state are ignored local data. The source checkout
is shared because both profiles use the same resolved manifest and combined
patch closure. Build outputs and complete-device bundles are separated by
codename. The download and attestation roots are flat today, but their
filenames include the target identity.

There is no implemented `artifacts/frankel/gsi/`, Frankel recovery-anchor
directory, or Frankel runtime attestation path. Documentation must not imply
that those future paths already exist.

## Shared orchestration and target hooks

These current entry points load the selected profile and share their outer
mechanics:

- host checks and pinned toolchain activation;
- source sync and source-lock verification;
- stock download and extraction using the selected archive names;
- adevtool invocation for the selected codename;
- complete-device build orchestration using
  `$DEVICE_CODENAME-aosp_current-userdebug` and
  `out_pixel/$DEVICE_CODENAME`;
- complete-device packaging dispatch; and
- read-only comparison of live fastboot product and firmware to the profile.

The generated-vendor sanitizer, build attestation, image inventory, AVB graph,
firmware policy, package schema, and flash ordering remain target hooks. In
particular, Frankel uses `scripts/sanitize-generated-vendor-frankel.sh`,
`scripts/attest-device-build.sh`, `scripts/package-device-frankel.sh`, and the
packaged copy of `scripts/flash-frankel.sh`. Cubs-specific libraries under
`scripts/lib/cubs-*` remain narrow and must not be selected for Frankel by
textual substitution.

The pinned adevtool tree already includes Frankel's device config, vendor spec,
vendor-state record, and generated skeleton. Patch
`0005-laguna-pristine-aosp-compatibility.patch` plus the Frankel sanitizer
provide the generated-tree transforms. Two source patches complete the
Frankel-specific runtime contract: the `frameworks-native` patch declares
eight Frankel-prefixed feature prebuilts, including Wi-Fi Aware and RTT, while
the sanitizer rewrites only Frankel's verified generated requests to those
names. Their explicit filenames retain the original installed paths and bytes;
unchanged Cubs requests cannot inherit the adapter. The `frameworks-base`
patch supplies the product-selected, eUICC-only flags provider for this
GSF-free product. Neither compatibility component is selected by the generic
GSI. The Frankel packager enforces Laguna geometry, the exact
36-image inventory, and the root-only 12-descriptor/no-chain AVB policy. These
build-time gates and the existence of a bundle do not replace candidate-bound
hardware evidence. The exact hardened bundle subsequently passed two
real-device boots and its runtime gate twice; see
[`frankel-validation.md`](frankel-validation.md) for the artifact identities,
functional observations, and explicit limits.

## Legacy Cubs-only GSI, recovery, and runtime tools

The generic name “GSI” does not make the current GSI bundle device-neutral.
The following profile-loading entry points are explicitly tied to the legacy
Cubs policy stack and must be invoked with `PIXEL_TARGET=cubs`:

```text
scripts/build-gsi.sh
scripts/package-gsi.sh
scripts/validate-images.sh
scripts/validate-runtime.sh
scripts/prepare-recovery-anchor.sh
scripts/prepare-stock-b-physical.sh
scripts/verify-stock-b-fastbootd-lifeboat.sh
scripts/restore-stock.sh
```

`scripts/attest-build-output.sh` and
`scripts/attest-stock-a-for-physical-b.sh` are likewise Cubs-only helpers.
`scripts/flash-a.sh` is the standalone runner copied into legacy GSI and Cubs
bundles; it does not load `PIXEL_TARGET`, but its embedded image inventory,
recovery protocol, and confirmations are specifically Cubs policy and must not
be used for Frankel.

`build-gsi.sh` builds the generic ARM64 system but invokes the legacy
GSI/Cubs build attester. `package-gsi.sh` binds that system to Cubs firmware,
recovery, and flash policy and publishes it at `artifacts/gsi/`.
`validate-images.sh` accepts only `gsi|cubs|all`, and
`validate-runtime.sh` accepts only `gsi|cubs`; neither accepts `frankel` or
`device`. Frankel instead has the explicitly target-gated
`validate-frankel-runtime.sh` plus the direct hardware procedure in
[the Frankel runbook](frankel-build-and-flash.md). The Frankel validator writes
a redacted report but does not produce a Cubs recovery-bound runtime
attestation.

There is no supported Frankel invocation of `package-gsi.sh`, and `device` is
not a valid `validate-runtime.sh` mode.

## Current command contract

The implemented Frankel complete-device path is:

```bash
PIXEL_TARGET=frankel GOOGLE_PIXEL_TERMS_ACCEPTED=1 scripts/download-stock.sh
PIXEL_TARGET=frankel scripts/extract-stock.sh
PIXEL_TARGET=frankel scripts/extract-vendor.sh
PIXEL_TARGET=frankel scripts/build-device.sh
PIXEL_TARGET=frankel scripts/package-device.sh
```

The equivalent Cubs complete-device entry points remain available with
`PIXEL_TARGET=cubs`. The legacy GSI path is likewise selected as Cubs:

```bash
PIXEL_TARGET=cubs scripts/build-gsi.sh
PIXEL_TARGET=cubs scripts/package-gsi.sh
PIXEL_TARGET=cubs scripts/validate-images.sh all
PIXEL_TARGET=cubs scripts/validate-runtime.sh gsi   # after a matching real flash
```

Environment overrides such as `DEVICE_OUT_DIR`, `DEVICE_TARGET_FILES`,
`AOSP_OUT_DIR`, and the Frankel runner's `FRANKEL_FASTBOOT_SERIAL` are accepted
only where their implementing script documents them. Legacy `CUBS_*` variables
remain part of the Cubs-only workflows; they are not target-neutral aliases.
Every complete-device build or package `DEVICE_OUT_DIR` must resolve to the
selected target's `out_pixel/$DEVICE_CODENAME` root or one of its descendants;
an override can never reuse another target's output namespace.

## Roadmap, not current behavior

Further reorganization may move target hooks beneath
`scripts/targets/<codename>/`, move device documentation beneath
`docs/devices/<codename>/`, and isolate downloads, attestations, logs, and
private recovery state in target subdirectories. Such moves require atomic
migration of existing Cubs recovery state and updates to every attestation and
publication path; this document does not claim they have happened.

Frankel's exact hardened device bundle is hardware boot-qualified, with the
functional limits in its validation record. It still lacks a
recovery-anchor/stock-restore workflow, cryptographic transaction-bound runtime
attestation, and a target-specific GSI packaging path. The current development
phone's physical B slot is known unbootable; the operator accepted that
no-lifeboat exception for this bring-up, but it is not the policy for a future
target or another phone. Pixel 9 onboarding begins only after its codename,
platform, stable donor, partition inventory, AVB graph, fstab, generated-vendor
transforms, and real-hardware recovery plan have been established from its own
factory package and phone. A future profile is not flashable merely because it
resembles Malibu or Laguna.
