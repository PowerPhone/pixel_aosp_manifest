# AOSP 17 for Google Pixel devices

This repository reconstructs reproducible Android 17 `userdebug` development
workflows for bootloader-unlocked Google Pixel devices whose current AOSP build
support is no longer published by Google. It builds a standard ARM64 AOSP GSI
and complete device products whose proprietary support is extracted locally
from the matching stock releases. The target is always selected explicitly
with `PIXEL_TARGET`; it is never inferred from an attached USB device.

## Target status

| Phone | Codename | Platform | Repository status |
| --- | --- | --- | --- |
| Pixel 11 | `cubs` | Malibu | Real-hardware boot qualified; broader functional qualification remains incomplete |
| Pixel 10 | `frankel` | Laguna | Hardened complete bundle passed two real-hardware boots and two 66-pass/zero-failure runtime audits; broader end-to-end qualification remains partial |
| Pixel 9 | To be established from its own stock package | To be established | Future target; no build or qualification claim |

Read [`docs/multi-target-layout.md`](docs/multi-target-layout.md) for the target
boundary and output-isolation rules. Frankel work is documented in
[`docs/frankel-baseline.md`](docs/frankel-baseline.md) and
[`docs/frankel-build-and-flash.md`](docs/frankel-build-and-flash.md). The
serial-free qualification record and exact final evidence are in
[`docs/frankel-validation.md`](docs/frankel-validation.md).

### Pixel 10 qualification status

> **The hardened complete `frankel` bundle boots on real hardware.** Its
> guarded runner flashed all 36 packaged A-only images, wiped data/metadata,
> selected A, and rebooted without a verification bypass. Android 17 reached
> `sys.boot_completed=1` in 20 seconds, then completed a normal 29-second
> reboot. Both runtime audits recorded 66 passes and zero failures with
> enforcing SELinux and verity. The eUICC and Pixel Modem Service compatibility
> faults from the preliminary candidate were absent; delayed checks after both
> boots found no target-process crash, provider rejection, or tombstone. Rear
> and front camera captures, Wi-Fi scan, Bluetooth enablement, an active audio
> track, vibration, storage, sensors, display/touch presence, and
> NFC/fingerprint service presence passed their recorded smoke checks. SIMs
> remained `NOT_READY`, no UWB service
> was exposed, and the documented end-to-end/manual checks remain unqualified.
> Physical B was already unbootable; the operator accepted this no-lifeboat
> exception. The exact tested `userdebug` system remains booted on A. See
> [`docs/frankel-validation.md`](docs/frankel-validation.md) for hashes and the
> exact qualification boundary.

### Pixel 11 qualification status (Cubs-only)

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

## Pinned baselines

| Input | Version |
| --- | --- |
| AOSP source | `android-17.0.0_r1` (`CP2A.260605.016`, SPL `2026-06-05`) |
| Device support tool | GrapheneOS `adevtool` commit `b01ccecab3468f3bcfa0d23adc361ad074989674` |
| Repo implementation | commit `b85886fa9f5b4e2189cc5b2f40bd0a80459d4c77` |
| Node.js | `24.20.0` |
| Yarn | `1.22.22` |
| Android Platform-Tools | `37.0.1` |
| Host tested | Ubuntu 26.04.1 x86_64 under WSL2 on a native Linux Btrfs workspace |
| Windows USB forwarding | [`usbipd-win 5.3.0`](https://github.com/dorssel/usbipd-win/releases/tag/v5.3.0) |

The target profiles pin these latest reviewed stable global stock donors as of
2026-08-29:

| Phone | Target profile | Stock donor | Vendor SPL |
| --- | --- | --- | --- |
| Pixel 11 | [`config/targets/cubs/release.env`](config/targets/cubs/release.env) | `CD1A.260714.001.A9` | `2026-08-05` |
| Pixel 10 | [`config/targets/frankel/release.env`](config/targets/frankel/release.env) | `CP2A.260805.005` | `2026-08-05` |
| Pixel 9 | Not yet defined | Not yet selected | Not yet established |

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

The framework is the June AOSP release while both current proprietary
vendor/firmware donors carry an August SPL. This is intentional, but neither
device build may be described as carrying August framework security coverage.
Android's DSU security-patch comparison also prevents qualifying this
older-SPL GSI through DSU on the newer stock OS, so device validation uses a
carefully isolated raw slot-A flash.

## Legal and redistribution boundary

Google publishes separate factory-image and full-OTA downloads for
[Pixel 11 (`cubs`) factory images](https://developers.google.com/android/images#cubs),
[Pixel 11 full OTAs](https://developers.google.com/android/ota#cubs),
[Pixel 10 (`frankel`) factory images](https://developers.google.com/android/images#frankel),
and [Pixel 10 full OTAs](https://developers.google.com/android/ota#frankel).
The associated terms restrict disassembly, decompilation, reverse engineering,
modification, and redistribution except where the applicable device license or
law allows it. This workflow necessarily performs local extraction and
assembles modified development images. Every builder must review and accept
the applicable terms and obtain legal advice where appropriate.

This repository publishes only original scripts/documentation, pinned source
manifests, and auditable compatibility patches. It does not publish Google
archives, extracted proprietary blobs, generated vendor modules, credentials,
or assembled image bundles. Those paths are ignored by Git. Apache-2.0 covers
project-authored material only; upstream projects and downloaded files retain
their own licenses and terms. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Host requirements

The supported reproduction path is Ubuntu 26.04.1 x86_64, either native or
under WSL2, with at least 64 GiB RAM on a native Linux `ext4` or `btrfs`
filesystem. The current host was tested on Btrfs; the host gate accepts both
filesystems. It requires 400 GiB to remain free whenever source sync, vendor
extraction, or a build starts. This is working headroom, not a total-disk or
clean-start capacity estimate: provision that 400 GiB in addition to the space
consumed by source, downloads, retained outputs, artifacts, and caches. WSL2
users must keep the workspace in its Linux filesystem rather than on a Windows
mount such as `/mnt/c`. Other Linux distributions may be adaptable, but the
installer and tested package names are Ubuntu-specific.

Each output root uses an isolated, ignored ccache with an explicit 50 GiB
default cap. Budget 50 GiB per retained output cache: GSI plus Cubs plus
Frankel can therefore reserve up to 150 GiB in addition to source and build
outputs, and each future device target can add another 50 GiB. Cache contents
are acceleration state, not source-lock or release-archive content. Override
`CCACHE_MAXSIZE` or point selected builds at a reviewed shared `CCACHE_DIR` when
storage policy requires a different tradeoff; set `USE_CCACHE=0` to disable it
explicitly. Never publish a ccache directory, and clear or disable it when
investigating a suspected reproducibility failure.

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
PIXEL_TARGET=frankel scripts/check-host.sh  # or PIXEL_TARGET=cubs
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
protobuf-compiler python3 python3-protobuf repo rsync shellcheck unzip
x11proto-core-dev util-linux xsltproc xxd zip zlib1g-dev zstd xz-utils 7zip
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

## Reproduce a selected target

Run target-aware commands with an explicit `PIXEL_TARGET`. Choose one of the
following workflows; do not rely on the temporary legacy default of `cubs`.

For Pixel 10 (`frankel`), the current build/integration path is:

```bash
PIXEL_TARGET=frankel scripts/check-host.sh
PIXEL_TARGET=frankel scripts/sync-source.sh
PIXEL_TARGET=frankel GOOGLE_PIXEL_TERMS_ACCEPTED=1 scripts/download-stock.sh
PIXEL_TARGET=frankel scripts/extract-stock.sh
PIXEL_TARGET=frankel scripts/extract-vendor.sh
PIXEL_TARGET=frankel scripts/build-device.sh
PIXEL_TARGET=frankel scripts/package-device.sh
# After flashing and reaching Android over ADB:
PIXEL_TARGET=frankel scripts/validate-frankel-runtime.sh
```

The standalone Frankel bundle is published under
`artifacts/frankel/device/`; its runner is
`artifacts/frankel/device/flash-all.sh`. The bundle is complete for the
reviewed Frankel port: 23 donor firmware images, seven source-built physical OS
images, six source-built logical images, metadata, attestations, and the
guarded runner. These proprietary/local outputs are ignored by Git and are not
part of the public source repository.

The Frankel source integration also installs the standard AOSP Wi-Fi Aware and
Wi-Fi RTT feature declarations requested by the generated Laguna product and a
narrow, read-only eUICC flags provider for the GSF-free product. Its eight
missing feature producers use Frankel-prefixed Soong names and retain the
original installed filenames, so unchanged Cubs requests do not inherit the
adapter. The provider
uses the authority expected by the extracted Pixel eUICC support app but is
not a general Google Services Framework implementation; see the runbook for
its caller and coexistence boundaries.

Hardware evidence is candidate-specific: a later rebuild or repack is not
qualified merely because this exact bundle passed. Follow the real slot-A and
post-boot procedure in
[`docs/frankel-build-and-flash.md`](docs/frankel-build-and-flash.md), and bind
each new result to the evidence fields in
[`docs/frankel-validation.md`](docs/frankel-validation.md).

For the already boot-qualified Pixel 11 (`cubs`) device product:

```bash
PIXEL_TARGET=cubs scripts/check-host.sh
PIXEL_TARGET=cubs scripts/sync-source.sh
PIXEL_TARGET=cubs GOOGLE_PIXEL_TERMS_ACCEPTED=1 scripts/download-stock.sh
PIXEL_TARGET=cubs scripts/extract-stock.sh
PIXEL_TARGET=cubs scripts/extract-vendor.sh
PIXEL_TARGET=cubs scripts/build-device.sh
PIXEL_TARGET=cubs scripts/package-device.sh
```

The standard Android 17 ARM64 `userdebug` GSI build produces `system.img`,
`vbmeta.img`, and `pvmfw.img`. Its current recovery-anchored package/flash path
is Cubs-only, so select Cubs explicitly:

```bash
PIXEL_TARGET=cubs scripts/build-gsi.sh
PIXEL_TARGET=cubs scripts/package-gsi.sh
```

`scripts/sync-source.sh` rejects unexpected `.repo/local_manifests` entries and
requires the synced revisions to match the committed `manifests/resolved.xml`.
Only a maintainer intentionally reviewing a revision update should run, for
the selected profile, for example:

```bash
PIXEL_TARGET=frankel PIXEL_AOSP_UPDATE_SOURCE_LOCK=1 scripts/sync-source.sh
```

Ordinary reproductions must never refresh the lock implicitly. The legacy
`CUBS_UPDATE_SOURCE_LOCK` spelling is accepted only for migration; new
instructions and automation must use `PIXEL_AOSP_UPDATE_SOURCE_LOCK`.

The patch driver is idempotent and records the smallest known target-aware
delta needed by current `adevtool`; it does not replace AOSP with a downstream
OS. Never use `adevtool --noVerify` or `--updateSpec` in this workflow.

### Pixel 11 vendor, build, and AVB gates (Cubs-only)

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

### Pixel 11 flashing and recovery (Cubs-only)

Development flashing remains gated until the corresponding package command
completes the mandatory staging validation and published-copy revalidation.
The exact-stock slot-A recovery path is already available, but it is
destructive:

```bash
PIXEL_TARGET=cubs scripts/check-device.sh
export CUBS_FASTBOOT_SERIAL='<fastboot-serial>'
export CUBS_ALLOW_DATA_WIPE=1
export CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID
PIXEL_TARGET=cubs scripts/restore-stock.sh
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

- `config/release.env`: AOSP, Repo, adevtool, Node, Yarn, and Platform-Tools
  inputs shared by all targets.
- `config/targets/<codename>/release.env`: one reviewed stock donor and device
  identity per supported target; see [`config/targets/README.md`](config/targets/README.md).
- `config/recovery.env` and the existing Cubs validation configs: legacy
  Cubs-only recovery and qualification policy, not reusable Frankel policy.
- `manifests/`: pinned Repo projects and the resolved source manifest.
- `patches/`: auditable common and platform-specific compatibility patches
  with upstream provenance.
- `scripts/lib/target-profile.sh`: validates `PIXEL_TARGET` against the fixed
  allowlist and loads exactly one profile.
- `scripts/`: shared setup/sync orchestration plus target-aware extraction,
  build, packaging, validation, flash, and recovery entry points.
- `docs/`: shared architecture plus explicitly device-scoped baselines,
  flashing runbooks, recovery policy, and validation records.
- `skills/android-gsi-device-port/`: reusable Codex guidance for bringing AOSP
  to other bootloader-unlocked phones without maintained OEM device support.
- `work/`: ignored source, toolchains, extraction state, and build outputs
  (`work/aosp/out_pixel/gsi/`, `work/aosp/out_pixel/cubs/`, and
  `work/aosp/out_pixel/frankel/`).
- `downloads/`, `artifacts/`, `logs/`: ignored proprietary inputs, local image
  bundles, and host-specific build/validation logs. Current device bundle roots
  are the legacy `artifacts/cubs/` and the target-scoped
  `artifacts/frankel/device/`.
- `.cache/`: ignored private recovery journals and attestations; never publish
  or copy this state between devices.

Start with [`docs/multi-target-layout.md`](docs/multi-target-layout.md) and
[`docs/architecture.md`](docs/architecture.md). For Frankel, continue with
[`docs/frankel-baseline.md`](docs/frankel-baseline.md) and
[`docs/frankel-build-and-flash.md`](docs/frankel-build-and-flash.md), then
record real-device evidence in
[`docs/frankel-validation.md`](docs/frankel-validation.md). The
existing [`docs/device-baseline.md`](docs/device-baseline.md),
[`docs/recovery.md`](docs/recovery.md),
[`docs/runtime-validation.md`](docs/runtime-validation.md), and
[`docs/functional-validation.md`](docs/functional-validation.md) describe the
Cubs-only baseline, recovery system, and acceptance gates. Neither a completed
build nor registered HAL services alone establishes working hardware for a new
target.

## Primary references

- [AOSP source download and tag verification](https://source.android.com/docs/setup/download)
- [Android build numbers and tags](https://source.android.com/docs/setup/reference/build-numbers)
- [Current AOSP build/lunch syntax](https://source.android.com/docs/setup/build/building)
- [Generic System Image build and flash guide](https://source.android.com/docs/core/tests/vts/gsi)
- [Virtual A/B](https://source.android.com/docs/core/ota/virtual_ab)
- [Fastbootd](https://source.android.com/docs/core/architecture/bootloader/fastbootd)
- [USB devices in WSL](https://learn.microsoft.com/windows/wsl/connect-usb)
