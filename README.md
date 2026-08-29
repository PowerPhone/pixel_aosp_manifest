# AOSP 17 for Pixel 11 (`cubs`)

This repository reconstructs a reproducible Android 17 `userdebug` development
workflow for the Google Pixel 11 (`cubs`). It builds a standard ARM64 AOSP GSI
and a complete cubs product whose proprietary support is extracted locally from
Google's matching stock release.

> **The corrected complete `cubs` bundle boots on real hardware, but broader
> qualification remains incomplete.** It was flashed with its packaged
> production AVB images and no verification-disable bypass. Android 17 reached
> `sys.boot_completed=1` on slot A as `userdebug` with enforcing dm-verity on
> the first boot, a 38-second second boot, and a 20-second post-finalization
> boot. Both audited boots recorded 127 passes, zero failures, and five warnings;
> the exact flash transaction was then finalized and its active recovery proof
> was atomically archived. Camera2 opened both exposed devices and each produced
> a valid JPEG. Wi-Fi scanning and Bluetooth enablement worked; a packaged
> alarm exercised an active AudioFlinger output stream, and the vibrator HAL
> accepted a real 500 ms one-shot. Broader manual qualification remains
> partial: VINTF is still inconclusive, the SIM is not ready, and no UWB binder
> service was found. Treat every bundle
> as experimental and review
> [`docs/validation.md`](docs/validation.md) and
> [`docs/recovery.md`](docs/recovery.md) before any device write.

## Pinned baseline

| Input | Version |
| --- | --- |
| AOSP source | `android-17.0.0_r1` (`CP2A.260605.016`, SPL `2026-06-05`) |
| Pixel 11 stock | `CD1A.260714.001.A9` (SPL `2026-08-05`) |
| Device support tool | GrapheneOS `adevtool` commit `b01ccecab3468f3bcfa0d23adc361ad074989674` |
| Repo implementation | commit `b85886fa9f5b4e2189cc5b2f40bd0a80459d4c77` |
| Node.js | `24.20.0` |
| Yarn | `1.22.22` |
| Android Platform-Tools | `37.0.1` |
| Host tested | Ubuntu 26.04.1 x86_64 under WSL2 |
| Windows USB forwarding | [`usbipd-win 5.3.0`](https://github.com/dorssel/usbipd-win/releases/tag/v5.3.0) |

[`android-17.0.0_r1`](https://android.googlesource.com/platform/manifest/+/refs/tags/android-17.0.0_r1)
was the newest stable Android 17 tag in Google's official
[build-number table](https://source.android.com/docs/setup/reference/build-numbers)
and manifest remote when rechecked on 2026-08-29.

Device images, AOSP/device-support source, the Repo implementation, Node, Yarn,
and Platform-Tools have immutable revisions or filenames and recorded hashes in
[`config/release.env`](config/release.env) or the resolved Repo manifest. Ubuntu
packages are the non-hermetic layer: `scripts/install-host-deps.sh` uses the
caller's currently configured APT sources, and this repository neither selects
nor archives an APT snapshot. The exact packages observed on the tested host are
an audit record in
[`config/host-packages-ubuntu-26.04.tsv`](config/host-packages-ubuntu-26.04.tsv),
not an installable lock. Preserve equivalent Ubuntu sources externally and
record the resolved package versions when reproducing a release.

The framework is the June AOSP release while the proprietary vendor/firmware
baseline is Google's August cubs release. This is intentional, but it must not
be described as carrying August framework security coverage. Android's DSU
security-patch comparison also prevents qualifying this older-SPL GSI through
DSU on the newer stock OS, so device validation uses a carefully isolated raw
slot-A flash.

## Legal and redistribution boundary

Google's [factory image terms](https://developers.google.com/android/images#cubs)
and [full OTA terms](https://developers.google.com/android/ota#cubs) restrict
disassembly, decompilation, reverse engineering, modification, and
redistribution except where the applicable device license or law allows it.
This workflow necessarily performs local extraction and assembles modified
development images. Every builder must review and accept the applicable terms
and obtain legal advice where appropriate.

This repository publishes only original scripts/documentation, pinned source
manifests, and auditable compatibility patches. It does not publish Google
archives, extracted proprietary blobs, generated vendor modules, credentials,
or assembled image bundles. Those paths are ignored by Git. Apache-2.0 covers
project-authored material only; upstream projects and downloaded files retain
their own licenses and terms. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Host requirements

The supported and tested reproduction path is Ubuntu 26.04.1 x86_64, either
native or under WSL2, with at least 64 GiB RAM on an ext4 filesystem. The host
check requires 400 GiB to remain free whenever source sync, vendor extraction,
or either build starts. This is working headroom, not a total-disk or
clean-start capacity estimate: provision that 400 GiB in addition to the space
consumed by source, downloads, retained outputs, artifacts, and caches. WSL2
users must keep the workspace inside the Linux ext4 filesystem, not `/mnt/c`.
Other Linux distributions may be adaptable, but the installer and tested
package names are Ubuntu-specific.

Each build output uses an isolated, ignored ccache with an explicit 50 GiB
default cap, so retaining both GSI and cubs caches can consume up to 100 GiB in
addition to source and build outputs. Cache contents are acceleration state,
not source-lock or release-archive content. Override `CCACHE_MAXSIZE` or point
both builds at a reviewed shared `CCACHE_DIR` when storage policy requires a
different tradeoff; set `USE_CCACHE=0` to disable it explicitly. Never publish
a ccache directory, and clear or disable it when investigating a suspected
reproducibility failure.

The tested WSL2 USB path also requires the exact x64 `usbipd-win 5.3.0`
release on the Windows host. The official installer is
[`usbipd-win_5.3.0_x64.msi`](https://github.com/dorssel/usbipd-win/releases/download/v5.3.0/usbipd-win_5.3.0_x64.msi),
whose published SHA-256 is
`1c984914aec944de19b64eff232421439629699f8138e3ddc29301175bc6d938`.
Download and verify that MSI in a Windows temporary directory outside this
clone; `.msi` and `.exe` payloads are deliberately excluded from publication.
The release's arm64 MSI digest,
`efd7c4eb99b144c1623e616064a7b262f83d0994b0d7fde16c95d4b07528b24d`,
is recorded for audit context only and is not an accepted substitute on the
tested x64 host.

The recovery workflow accepts only the installed x64 payload with size
`8803720` bytes, SHA-256
`78fd94ca4125db7407c77bd7b985971a1ac95705a331401976f748770035325b`,
and this exact one-line `--version` output:

```text
5.3.0-54+Branch.master.Sha.aa3db8b82c4cb5071fd31bc54211606c70886912.aa3db8b82c4cb5071fd31bc54211606c70886912
```

`USBIPD_EXE` may select a nondefault absolute installed location, but it never
overrides those identity pins. Its elevated AutoBind policy must preserve
forwarding across Android, bootloader fastboot, fastbootd, and recovery USB
identities. Follow
[`docs/recovery-anchor.md`](docs/recovery-anchor.md) to validate the download,
installed payload, Authenticode signature, and policy before any device write.

From a fresh clone on the supported host, replace `YOUR_REPOSITORY_URL` with
the reviewed Git URL and run every command from the repository root:

```bash
git clone YOUR_REPOSITORY_URL pixel_aosp_manifest
cd pixel_aosp_manifest
scripts/install-host-deps.sh
scripts/check-host.sh
scripts/lint.sh
```

The installer invokes `sudo apt-get` for the Ubuntu packages, so the caller
must have sudo authority and must review the configured APT sources first. It
then installs checksum-pinned, workspace-local Node, Yarn, and Platform-Tools.

The setup includes the
[AOSP host packages](https://source.android.com/docs/setup/start/requirements),
Yarn 1.22.22, image inspection utilities, ShellCheck, and Git LFS. AOSP supplies
its own JDK and compiler toolchains. Google's Platform-Tools license applies to
the downloaded binary package.

The required Ubuntu package set installed by the script is:

```text
android-sdk-libsparse-utils bison brotli build-essential ca-certificates ccache
curl device-tree-compiler diffutils e2fsprogs erofs-utils f2fs-tools flex
fontconfig git-core git-lfs gnupg gperf lib32z1-dev libc6-dev-i386
libgl1-mesa-dev libx11-dev libxml2-utils jq lz4 openssh-client openssl pkgconf
protobuf-compiler python3-protobuf repo rsync shellcheck unzip x11proto-core-dev
util-linux xsltproc xxd zip zlib1g-dev zstd xz-utils 7zip
```

Node.js, Yarn, and Google Platform-Tools are installed separately under
`work/toolchains/` at the pinned versions above; they are not taken from APT.
Yarn is mapped directly from the recorded, checksum-pinned tarball into the
attested local Node tree without package-manager or lifecycle execution. APT
supplies only the Repo launcher; `scripts/sync-source.sh`
forces the pinned Repo implementation commit before syncing or serializing the
source lock.

Host-toolchain installation holds an exclusive lock on the real
`work/toolchains/` directory; `check-host.sh` takes the matching shared lock.
Version publication uses a recoverable two-rename transaction: after a crash,
an absent version plus `.previous` is rolled back, while a present version plus
`.previous` means publication committed and the old directory is archived.
The version name can be absent only between those two renames while the
exclusive lock is held. Convenience symlinks are replaced atomically through a
temporary sibling symlink and rename.

## Reproduce the build

The intended order keeps the portable AOSP output distinct from cubs support:

```bash
GOOGLE_PIXEL_TERMS_ACCEPTED=1 scripts/download-stock.sh
scripts/extract-stock.sh
scripts/sync-source.sh

# Standard Android 17 ARM64 userdebug GSI: system, vbmeta, and pvmfw.
scripts/build-gsi.sh
scripts/package-gsi.sh

# Verified cubs extraction and the minimal pristine-AOSP compatibility delta.
scripts/extract-vendor.sh
scripts/build-device.sh
scripts/package-device.sh
```

`scripts/sync-source.sh` rejects unexpected `.repo/local_manifests` entries and
requires the synced revisions to match the committed `manifests/resolved.xml`.
Only a maintainer intentionally reviewing a revision update should run
`CUBS_UPDATE_SOURCE_LOCK=1 scripts/sync-source.sh`; ordinary reproductions must
never refresh the lock implicitly.

The patch driver is idempotent and records the smallest known delta needed by
current `adevtool`; it does not replace AOSP with a downstream OS. Never use
`adevtool --noVerify` or `--updateSpec` in this workflow.

Extraction writes an ignored, deterministic attestation at
`work/attestations/cubs-generated-vendor.attestation`. It binds every generated
file's content and mode, every directory mode, and every in-tree symlink target
to the factory-image digest/build, resolved source manifest, pinned `adevtool`
revision, and reviewed sanitizer. Device build and packaging refuse a changed
or unattested vendor tree. The sanitizer removes `SELINUX_IGNORE_NEVERALLOWS`
and `BUILD_BROKEN_DUP_RULES`. After the unmodified upstream FileTreeSpec passes,
the sanitizer removes the stock-derived duplicate of AOSP's standard
`vndservicemanager` transfer rule from both normal and recovery extension CILs,
including only its orphaned synthetic attribute. It pins the pristine and
post-transform hashes and verifies that pristine AOSP still owns the exact
equivalent rule with explicit `init` and `vendor_init` exclusions. The sanitizer
also removes only the generated hostapd and supplicant XML files and their
Soong modules, and replaces their product requests with the corresponding
pristine-AOSP fragment modules. Those AOSP modules declare the same HALs at the
same vendor paths and remain explicitly installed even though cubs uses
proprietary Wi-Fi binaries. The attestation binds these narrow transforms and
strict enforcement, and fails if either broad bring-up exception reappears.
Because adevtool also collapses named fstab AVB dependencies to root
`vbmeta`, the sanitizer restores the exact stock-shaped child references in
both generated `fstab.malibu` copies: framework partitions use
`vbmeta_system`, `vendor` uses `vbmeta_vendor`, and `boot`/`init_boot` use their
same-named chains; `vendor_dlkm` remains root-direct. Both pristine and
normalized fstab hashes and the normalization helper are attested. Static
image validation requires the generated and target-files copies to be
byte-identical and derives their allowed child names from the root vbmeta
chain descriptors.
Build completion then requires exactly one Soong install rule per fragment,
owned by the pinned AOSP modules, and attests their exact AOSP hashes in the
canonical target-files vendor-manifest paths.

Each build also invalidates its prior completion attestation immediately before
invoking the Android build, then recreates it atomically only after every
required output is present and hashed. These ignored markers bind the resolved
source and patch locks, target identity, release/build ID/SPL/variant, build
tools, target-files, and—for cubs—the generated-vendor attestation. Packaging
rejects missing or stale markers and includes the verified marker as
`BUILD_ATTESTATION.txt` in the bundle checksum manifest. Packaging then runs
the mandatory repository static validator against a complete staging bundle
before publication and revalidates the published copy.

For cubs, the completion marker also compensates for the reviewed Soong patch
that disables the unsupported generic standalone-system-server dexpreopt
check. It binds `malibu-plugin-provider.jar` and its arm64 ODEX/VDEX files
between the live product tree and their exact `SYSTEM_EXT/` target-files
entries, verifies the generated and installed JAR are identical valid ZIPs,
checks their OAT/VDEX magic, and independently pins the effective dexpreopt
configuration. The production semantic gate additionally requires the exact
35-record dex2oat invocation, CMC with no verify/profile fallback, the pinned
arm64 Cortex-A76/default compiler settings, the 52-entry boot class path, and
the 18-entry standalone system-server class-loader context. It runs the
source-built, checksum-pinned host `oatdump` read-only against the JAR/ODEX/VDEX
set and requires the exact Android 17 OAT header and checksum-bearing stored
class path. These output-validation pins live in
[`config/cubs-dexpreopt.env`](config/cubs-dexpreopt.env), deliberately outside
the Android build-input identity in `config/release.env`.

Development flashing remains gated until the corresponding package command
completes the mandatory staging validation and published-copy revalidation.
The exact-stock slot-A recovery path is already available, but it is
destructive:

```bash
scripts/check-device.sh
export CUBS_FASTBOOT_SERIAL='<fastboot-serial>'
export CUBS_ALLOW_DATA_WIPE=1
export CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID
scripts/restore-stock.sh
```

Pixel 11's virtual A/B logical `_a` and `_b` views share physical `super`
extents. The first development logical-A write invalidates Android B as a
fallback even though B boot-control flags remain healthy. The flash and restore
workflows preserve B's 25 physical firmware partitions plus its nine
boot/recovery/fastbootd partitions, use literal `_a` partition names, and
write logical A before physical A. Before a flash, the bound stock-B
verification creates an ignored, mode-`0600`, one-hour handoff containing only
a salted serial digest. The standalone runner verifies its exact stock/OTA and
all-34-partition lineage, claims it for the exact bundle, and publishes a
salted, bundle-bound slot-A transaction before changing boot control. It then
selects untouched stock A, enters A-origin fastbootd, requires the complete
A-only logical namespace, and writes the logical payloads. Only after returning
to bootloader fastboot does it write physical A, wipe shared data, and reassert
A as the final device write. A failed first Android boot therefore keeps both
the physical-B restore authority and an exact resumable or abortable journal.
After an exact slot-A `userdebug` boot, the runtime validator can publish a
private v2 proof bound to the claimed handoff, bundle checksum manifest, and
slot-A transaction hash. Only the separately gated bootloader finalizer may
then atomically archive the lineage, claimed handoff, transaction, runtime
proof, and retirement receipt; its journal makes host interruption during
cleanup recoverable. A historical archive is never accepted as proof of the
current slot-A bytes.

The runner locates the pinned Platform-Tools fastboot binary relative to an
in-tree bundle and verifies both its version and extracted-binary digest. All
ADB-backed attestations and stock-restore checks likewise use the workspace's
pinned Platform-Tools ADB binary; a same-named distro tool is rejected. The
stock restore enters B-origin fastbootd, journals a same-connection selector
and first logical resize to pivot to A metadata, restores all logical A images,
and writes physical A only after returning to bootloader. It proves restored
stock A first in Android and then in bootloader fastboot before retiring the
lifeboat. An expired but never-claimed ready handoff has a guarded
archival-and-reissue workflow; claimed handoffs cannot use it. Read
[`docs/recovery-anchor.md`](docs/recovery-anchor.md),
[`docs/packaging.md`](docs/packaging.md), and
[`docs/recovery.md`](docs/recovery.md) before any device write.

If stock recovery cannot populate inactive B, use the separately audited
physical-B fastbootd route in
[`docs/stock-b-physical-preparation.md`](docs/stock-b-physical-preparation.md).
It begins from the one exact finalized stock-restore receipt and never boots
Android B: restored shared-super metadata exposes an A-only logical namespace
even while physical B is current. Its provenance is the claimed terminal
restore baseline, six factory-expanded logical sizes, exact pinned physical
source manifest, 34 acknowledged flashes, complete `vendor_boot_a/b` controls,
and a one-shot strict fastbootd runtime trial—not an unavailable 34-partition
device readback claim.

## Publish source safely

This working tree deliberately contains ignored Google archives, extracted
proprietary files, build outputs, image bundles, host-specific logs, caches,
and private recovery receipts. `.gitignore` is an accident-prevention layer,
not permission to upload the directory. Never archive the working tree, use
`git add -f`, or attach `artifacts/` to a GitHub release.

After the status record is final and the intended source files are staged,
review the exact Git boundary and create a source archive only from a reviewed
commit:

```bash
scripts/lint.sh
git status --short --ignored
git diff --check
git diff --cached --check
git ls-files

# Run only after committing the reviewed source set.
git archive --format=tar.gz \
  --output=pixel_aosp_manifest-source.tar.gz HEAD
```

Inspect `git ls-files` before every publication. It must not contain anything
under `work/`, `out/`, `downloads/`, `artifacts/`, `logs/`, `.cache/`, or a
generated proprietary tree, nor any image, executable blob, credential, or
private signing key. Push the reviewed commit or upload the `git archive`
result; do not substitute a filesystem ZIP or tarball. The generated source
archive is itself ignored and is not an input to later builds.

## Repository layout

- `config/`: device/release metadata plus separately scoped host-recovery pins,
  URLs, and hashes.
- `manifests/`: pinned Repo projects and the resolved source manifest.
- `patches/`: auditable compatibility patches with upstream provenance.
- `scripts/`: setup, sync, extraction, build, validation, flash, and recovery.
- `docs/`: architecture, device baseline, recovery, and validation records.
- `skills/android-gsi-device-port/`: reusable Codex guidance for bringing AOSP
  to other bootloader-unlocked phones without maintained OEM device support.
- `work/`: ignored source, toolchains, extraction state, and build outputs
  (including `work/aosp/out_pixel/`).
- `downloads/`, `artifacts/`, `logs/`: ignored proprietary inputs, local image
  bundles, and host-specific build/validation logs.
- `.cache/`: ignored private recovery journals and attestations; never publish
  or copy this state between devices.

Start with [`docs/architecture.md`](docs/architecture.md), then read
[`docs/device-baseline.md`](docs/device-baseline.md) and
[`docs/recovery.md`](docs/recovery.md) before any device write. Post-boot
qualification requires both the read-only
[`docs/runtime-validation.md`](docs/runtime-validation.md) audit and the manual
[`docs/functional-validation.md`](docs/functional-validation.md) acceptance
matrix; neither a completed boot nor registered HAL services alone establishes
working hardware.

## Primary references

- [AOSP source download and tag verification](https://source.android.com/docs/setup/download)
- [Android build numbers and tags](https://source.android.com/docs/setup/reference/build-numbers)
- [Current AOSP build/lunch syntax](https://source.android.com/docs/setup/build/building)
- [Generic System Image build and flash guide](https://source.android.com/docs/core/tests/vts/gsi)
- [Virtual A/B](https://source.android.com/docs/core/ota/virtual_ab)
- [Fastbootd](https://source.android.com/docs/core/architecture/bootloader/fastbootd)
- [USB devices in WSL](https://learn.microsoft.com/windows/wsl/connect-usb)
