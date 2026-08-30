# Unsupported-device AOSP/GSI workflow

Use this sequence as a decision framework. Device documentation and live
partition evidence override examples or conventions from other products.

## 0. Organize for multiple targets

Use a target registry rather than scattering codename checks through scripts.
One target definition should pin the product name, platform family, AOSP tag,
donor build, expected firmware, partition policy, adevtool inputs, patch stacks,
build product, and validation profile. Make build, package, flash, and validation
entry points accept that target explicitly and fail if it is absent or unknown.

A useful separation is:

```text
config/targets/<codename>/   target pins, partition policy, extractor inputs
manifests/                   pinned AOSP and auxiliary repositories
patches/shared/              cross-target source patches
patches/<codename>/          device- or platform-specific patch stacks
scripts/                     target-parameterized extraction/build/flash tools
docs/targets/                target-specific bring-up and qualification records
work/<codename>/             ignored generated trees, downloads, and logs
artifacts/<codename>/device/ ignored private flash bundle
```

The exact names are local policy; the boundaries are the invariant. Never let
two targets share an output directory or infer a target from whichever device
happens to be attached. Keep common platform-family configuration reusable, but
do not promote a target exception to shared policy until another target proves
it is actually common.

## 1. Inventory and recovery baseline

Record the device serial only in private, ignored state; redact it from public
logs, documentation, and validation records. Record the codename, stock
fingerprint/build ID, security patch, bootloader/baseband versions, slot state,
unlock state, boot modes, partition sizes, `super` metadata, boot-control state,
and whether userspace fastboot can be entered from each physical slot. Archive
the exact factory package and its license/source URLs.

Treat rollback indices and virtual A/B status as hard gates, not inventory
notes. Reject lower or internally mixed firmware generations. Do not touch
`super` or any logical partition while snapshot/merge/COW state is active or
ambiguous; confirm a terminal state again after entering fastbootd.

Before modifying shared `super`, prove a physical recovery chain. A useful
lifeboat contains the physical bootloader and fastbootd inputs needed to fetch
or rewrite partitions; it does not imply that Android remains bootable on that
slot. Test the lifeboat rather than inferring it from an `is-slot-unbootable`
variable. If the spare slot is already unbootable, record the no-lifeboat
exception and the user's explicit risk acceptance; do not describe the session
or resulting bundle as recoverable on-device. Journal every destructive phase
so an interrupted process cannot be mistaken for a clean starting state.

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

Pin the adevtool commit and its device configuration. Preserve the commands and
inputs needed to regenerate an empty vendor output, then treat any corrections
to that generated tree as an ordered, locked patch stack. Regenerate from empty
state during audit: an extractor succeeding against a previously populated
directory can hide a missing source blob, stale module, or manual edit. Check
that every proprietary-file entry resolves to its intended donor partition and
that generated makefiles refer only to modules or files the build can resolve.

Keep firmware and userspace donor concepts distinct. A factory package may
supply immutable bootloader/radio partitions, vendor-side images, and extracted
files, while the framework comes from a different AOSP tag. Record each role;
never collapse them into a vague "stock version."

## 3. Reconstruct the target

Pin the AOSP tag and every external repository revision. Start with the generic
system target only when the stock vendor interface is demonstrably Treble
compatible; otherwise create a device target that repacks the stock-derived
vendor-side partitions around the new framework.

Lock every source patch to the base commit of the repository it changes and
record both order and digest. Provide an apply/check mode that rejects the wrong
base, unexpected pre-existing changes, failed reverse checks, and digest drift.
Keep patches to extractor-generated output separate from patches to AOSP source
repositories: they have different regeneration boundaries.

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

### Detect silent product omissions

Do not stop after confirming that a generated product makefile mentions a
module. For every compatibility-critical item:

1. Resolve the named Soong/Make module and its source file.
2. Confirm it appears in the product's installed-files output.
3. Confirm the expected bytes and destination inside target-files.
4. Confirm the packaged partition contains the same file.
5. Confirm the runtime framework advertises the feature or service it enables.

Permission/feature XML is a recurring trap: an extractor can add an
`android.hardware.*.xml` prebuilt name to `PRODUCT_PACKAGES` even when the AOSP
branch has no matching module definition. The rest of the build can appear
healthy while `PackageManager` omits the feature and an OEM app receives a null
manager. Add the missing prebuilt definition or correct the product input, then
bind source, installed output, target-files, and runtime state in attestation.

Namespace a target-only compatibility module with the target identifier while
preserving the installed filename expected by Android. Rewrite only that
target's generated product input to select it. Do not add an unscoped module
solely to make one product resolve: another target can then silently satisfy the
same `PRODUCT_PACKAGES` name even though its own compatibility work was never
performed. Move a module into shared policy only after its inputs and semantics
are proven common.

### Handle missing framework authorities narrowly

Some proprietary packages assume an OEM or Google content-provider authority
exists even on a GSF-free AOSP build. First decide whether the client can be
excluded without losing required hardware maintenance or recovery behavior. If
not, prefer a narrowly scoped framework redirect or compatibility provider over
installing a broad service suite merely to satisfy one query.

A provider that directly claims the missing authority has important costs:

- it conflicts with any future installation of the real authority owner, so it
  is suitable only for an explicitly GSF-free product;
- provider export, read permissions, package visibility, and caller identity
  are separate controls—platform signing or a privileged allowlist alone does
  not establish all four;
- a client may query a root URI, a key path, or a prefix selection and may
  register observers, so implement only the observed contract and return the
  expected cursor shape;
- throwing `SecurityException` at another privileged client that probes the
  same authority can create a secondary boot crash. Do not widen access to fix
  that: return a semantically safe empty result where the API permits, or route
  only the intended caller.

Keep any compatibility flags immutable, allowlisted, and installed from a
measured source file. Test every packaged app that requests the provider's
permission or references its authority, not just the first crashing client.
Document the authority collision and the migration needed if the real provider
is later installed.

## 4. Build and inspect

Document host packages, tool versions, environment setup, manifest sync,
`lunch` target and build commands. Build `userdebug` and retain target-files so
images can be regenerated without opaque manual steps.

Before hardware writes, inspect image headers, partition fit, filesystem
contents, fstab, VINTF, sepolicy artifacts, AVB descriptors and the full vbmeta
chain. Static checks reduce avoidable risk but do not establish bootability.

Generate a build attestation from resolved inputs rather than mutable working
state: manifest revisions, extractor revision/configuration, donor identities,
ordered patch digests, generated-vendor evidence, build product, target-files,
and the exact installed compatibility files. If packaging transforms an image
(for example, adding a firmware-specific footer or fixed-size padding), make
that transformation deterministic, attest its semantics, and sign/describe the
transformed bytes rather than an earlier intermediate.

Check identity and firmware coherence as a tuple: bootloader, radio/baseband,
vendor build identity and security patch, framework build identity and security
patch, VINTF level, rollback indices, and AVB descriptor set. Do not solve a
proprietary compatibility check by falsely advancing the framework security
patch. If a donor-compatible property override is required, document exactly
which property changed and retain the real source tag/build in provenance.

For AVB, enumerate every partition protected directly or through a chained
vbmeta image, its key, algorithm, rollback location, flags, and expected size.
Verify descriptors against the exact release images and confirm that the flash
bundle contains one coherent chain. Root-only and chained layouts can both be
valid; an accidental mix is not.

Construct a release bundle in a private sibling staging directory and validate
it there before publication. Treat `SHA256SUMS` (or its explicitly named
equivalent) as the completion marker: preferably publish a new versioned
directory with one same-filesystem atomic rename; when refreshing a fixed
directory in place, withdraw the old marker before the first payload replacement
and install the new marker last. Revalidate the published copy and withdraw the
marker on failure. A runner must treat an absent marker as an incomplete
package, never as an invitation to use whatever files remain.

## 5. Flash with a transaction boundary

The standalone flash runner should carry an expected flat-directory allowlist.
Before resolving or invoking any device tool, require the directory to contain
exactly that allowlist plus the checksum manifest, with only regular,
non-symlink files. Parse the manifest defensively: require safe relative names,
one entry for every allowlisted file other than the manifest itself, no
duplicates, omissions or additions, and a strict checksum pass. Checking only
the entries that happen to be present is insufficient because a damaged or
modified manifest can omit a required image.

Resolve fastboot to one regular executable and compare its bytes with the
digest pinned by the project's Platform-Tools configuration before executing
it, including for `--version` or `devices`. Keep the pin in bundle metadata so
it is auditable and reject disagreement between configuration, metadata and
runner. A checksum file stored beside its payloads detects accidental mixing
and corruption, but it does not authenticate a bundle when an attacker can
replace both; signed metadata or a separately trusted digest is needed for
authenticity.

After these host-only gates, require the expected serial, codename, firmware
and boot mode, then an explicit destructive confirmation. Record a transaction
before the first write.

Supply the expected serial at invocation time or through private ignored state;
never bake it into a public script, bundle manifest, log, screenshot, or
validation report. Redact both ADB and fastboot identifiers from published
evidence. USB authorization in stock Android, ADB, bootloader fastboot, and
fastbootd are separate access states—re-enumeration can legitimately require
human action without changing the target identity.

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

Require two ordinary boots of the exact packaged candidate on real hardware,
with the second reached through a normal reboot rather than a mocked boot-state
transition. Verify the expected fingerprint, slot, `userdebug` variant, boot
completion, AVB state, enforcing
SELinux and verity, logical mounts through verified mapper targets, tested-slot
bootable/successful flags, clean critical-service state, and absence of new
boot-critical crashes. Run built-target `checkvintf` and, where practical, a
focused Treble VTS subset; an unavailable on-device checker is not positive
compatibility evidence.

Exercise real peripherals rather than mocks. Capture durable evidence such as
camera-produced JPEGs, active AudioFlinger frames, Wi-Fi scan results, Bluetooth
state, sensor enumeration and touch/display state. Clear or delimit crash logs
before each boot and explicitly monitor proprietary packages implicated during
bring-up, plus adjacent clients of any compatibility shim. State environmental
limits for cellular, GNSS, NFC, UWB, biometrics or other hardware. No SIM,
account, radio network, test card, or human touch confirmation means untested,
not passed.

Tie the validation record to the packaged bundle identity and build
attestation. If the runtime validator checks properties and file identities but
cannot cryptographically prove the immediately preceding flash transaction,
say that it is identity-bound rather than transaction-bound; do not overstate
the evidence.

Only then finalize the flash transaction and archive its provenance. Package
the exact tested images with a `flash-all` runner, firmware requirements,
source/build identity, licensing notices, recovery instructions and a concise
validation report. Leave the tested system installed unless the user asks for
a restore.

Before publishing the repository, audit tracked files separately from the local
deliverable. Keep extracted blobs, factory/OTA downloads, target-files, images,
device-unique backups, raw logs, serial-bearing reports, and private flash
bundles ignored. Publish target definitions, extraction recipes, source patches,
patch locks, scripts, documentation, and licensing/provenance metadata. A file
being technically necessary—or having a recorded hash—does not make it legal to
redistribute.
