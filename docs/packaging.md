# Packaging and slot-A flashing

> **Scope:** This legacy guide documents the Pixel 11 (`cubs`) workflow only; see the [multi-target layout](multi-target-layout.md) for current target organization.

The packaging scripts turn local build outputs into portable, ignored bundle
directories with standalone flash runners. A bundle can still depend on the
explicit device baseline documented below; packaging does not make proprietary
output redistributable. Review the factory-image terms and the repository's
legal boundary before sharing any bundle.

## Build bundles

After the corresponding build succeeds:

```bash
scripts/package-gsi.sh
scripts/package-device.sh
```

The outputs are `artifacts/gsi/` and `artifacts/cubs/`. Each contains an exact
image allowlist, `BUNDLE_INFO.txt`, `BUILD_ATTESTATION.txt`, the pinned stock
firmware requirements, `SHA256SUMS`, and a standalone `flash-all.sh`. The build
attestation is itself covered by `SHA256SUMS` and its digest is recorded in
`BUNDLE_INFO.txt`. The cubs packager derives images from the generated
target-files package with AOSP's
`img_from_target_files`. Set `CUBS_TARGET_FILES` only when more than one
target-files ZIP exists and the packager cannot choose unambiguously.
The complete cubs bundle contains the 25 individually slotted firmware images
named in its exact A/B manifest. Each must be byte-identical in generated
vendor source, target-files `RADIO/`, the reconstructed image ZIP, the bundle,
and the checksum-pinned stock inner ZIP.
Before reading target-files, the cubs packager also verifies the ignored
generated-vendor attestation created by `scripts/extract-vendor.sh`; rerun the
verified extraction instead of accepting an unexplained vendor-tree change.
Both packagers similarly reject outputs without a current successful-build
attestation, including outputs left behind after a later failed build. They
construct and statically validate an exact staging directory before publishing
it. The previous `SHA256SUMS` is withdrawn during refresh and the new one is
installed last, so an interruption cannot leave a mixed directory that the
runner accepts. The published copy is then revalidated; on failure its checksum
manifest is removed. A missing, non-executable, or symlinked validator is a
packaging failure. Packaging also refuses a missing, symlinked, non-executable,
or stale standalone flash runner, including any runner whose hardcoded recovery
policy digest differs from `config/recovery.env`.

For cubs, the successful-build attestation must also carry the Malibu
standalone-system-server semantic evidence derived with the checksum-pinned
host `oatdump`. Packaging does not regenerate or relax that evidence: the
35-record dex2oat invocation, target `classes.dex` CRC32, checksum-bearing
class-loader context, and normalized oatdump semantic digest must still match
the output-validation policy in `config/cubs-dexpreopt.env`. The policy file is
kept separate from `config/release.env` so it cannot retroactively change the
identity of an already completed GSI build.

Neither bundle contains the outer aggregate `bootloader.img` or `radio.img`, a
`super.img`, `super_empty.img`, userdata image, or generated fastboot task
list. The cubs bundle does contain the 25 exact individual A/B firmware
payloads, including `modem.img`; it never consumes an aggregate with
`fastboot update`.

## Mandatory device state

The flash runner refuses writes unless all of these conditions hold:

- Platform-Tools is the pinned 37.0.1 release;
- exactly one explicitly selected `cubs` device is attached;
- the bootloader is unlocked and matches the pinned stock package;
- no virtual A/B snapshot update is active and the battery is at least 50%;
- a new transaction starts in bootloader fastboot with physical B current and
  not marked unbootable; a first-use full-OTA stock anchor requires
  successful=`yes`, while a direct physical lifeboat uses its reviewed
  source-aware flag rule;
- exact resumed transactions may start in A or B bootloader fastboot, or in
  fastbootd only long enough for their journaled phase to be revalidated and
  continued; no path normal-boots Android B;
- every allowed bundle file passes its SHA-256 check; and
- both destructive confirmation variables are exact, with an additional
  stock-slot-A attestation for the GSI path;
- a private, fresh recovery handoff matches the selected transport, exact stock
  inputs, reviewed policy, and all 34 physical B partition sizes; both complete
  stock `vendor_boot_a` and `vendor_boot_b` bytes are fetched and pinned before
  A is used as the logical-flash origin; and
- the resolved fastboot executable matches both the pinned 37.0.1 version and
  extracted-binary SHA-256.

Establish one of the two source-valid B authorities before the first bundle.
The full-OTA route boots and verifies exact stock Android B, which is an Android
anchor only until the first shared-super logical write. The direct physical-B
route instead claims the one exact finalized stock-A restore receipt, binds six
factory-expanded logical sizes, prepares all 34 physical B partitions, and
verifies only their A-only fastbootd namespace; it never creates or boots
Android B. Under
either route, the first logical write leaves B only as a physical lifeboat: the
development flash does not touch its 25 firmware partitions or nine
boot/recovery/fastbootd partitions. Physical A remains exact stock until its own
fastbootd has completed every logical-A write. Keep Windows/WSL USB forwarding
active across bootloader-to-fastbootd transitions.

## Flash

Select the serial explicitly; do not place a real device identifier in source
control or logs:

```bash
export CUBS_FASTBOOT_SERIAL='<fastboot-serial>'
export CUBS_ALLOW_DATA_WIPE=1
export CUBS_FLASH_CONFIRM=FLASH_CUBS_A_SHARED_SUPER_INVALIDATES_B_ANDROID

# Required for the GSI path because it deliberately reuses these partitions:
export CUBS_GSI_STOCK_A_BASELINE_CONFIRMED=1
artifacts/gsi/flash-all.sh

# Or, with a separately issued fresh handoff, flash the complete device build:
artifacts/cubs/flash-all.sh
```

A claimed handoff and its slot-A transaction belong to exactly one bundle
manifest. They never authorize switching from the GSI bundle to the cubs
bundle. Finish runtime retirement or adopt an explicit abort in stock restore,
then prepare a separately verified fresh recovery authority for later work.

An in-tree artifact resolves `work/toolchains/platform-tools/fastboot` and the
private handoff from its script location, not `$PWD`. For a bundle moved away
from this project, provide canonical absolute paths:

```bash
export FASTBOOT='/absolute/path/to/platform-tools/fastboot'
export CUBS_RECOVERY_HANDOFF='/absolute/path/to/flash-handoff'
```

The handoff is fresh for one hour. It is atomically claimed for the exact
bundle checksum-manifest digest before any mutation. The runner then publishes
the private `slot-a-flash-transaction` before selecting A. That transaction is
bound to the salted USB serial, claimed handoff and lineage hashes, physical-B
digest and source, bundle kind and manifest, exact logical target/expanded-size
sets, and recovery policy. Its phases journal A selection, entry into stock-A
fastbootd, logical replay, return to the A bootloader, physical replay, final A
activation, and `awaiting_runtime`.

If a run stops, use only the same bundle within 24 hours and set the exact
`CUBS_FLASH_RESUME_CONFIRM` value reported by the runner. It revalidates the
transport and durable phase, makes A the boot-control target if necessary, and
replays the idempotent phase. It never relies on an unjournaled selector ACK.
Do not manually enter or write from B fastbootd. A stale or foreign transaction
is a stock-restore condition, not permission to invent a bypass.

If A cannot boot, hand the exact transaction to stock restore instead of
deleting state or trying Android B:

```bash
export CUBS_FLASH_ABORT_CONFIRM=ABORT_EXACT_CUBS_A_TRANSACTION_FOR_STOCK_RESTORE
artifacts/gsi/flash-all.sh   # or artifacts/cubs/flash-all.sh
```

The abort first journals `abort_return_bootloader_pending`, returns from
fastbootd only with an explicit `reboot bootloader`, and revalidates identity,
physical-B sizes/flags, source rules, and the full pinned `vendor_boot_b` bytes.
It then publishes terminal `aborted_for_restore` without deleting the
transaction, lineage, or claimed handoff. The stock-restore transaction adopts
the exact terminal file SHA and retires it only through its own journal.

After slot A boots successfully, run the validator with
`CUBS_PUBLISH_RUNTIME_ATTESTATION=1` as documented in
[`runtime-validation.md`](runtime-validation.md), explicitly return that phone
to bootloader, and invoke the same bundle with
`CUBS_FLASH_FINALIZE_CONFIRM=FINALIZE_EXACT_CUBS_A_TRANSACTION_AFTER_SUCCESSFUL_ANDROID_BOOT`.
The current-A path requires A successful/not-unbootable, runtime-attestation v2
bound to the exact `awaiting_runtime` transaction SHA, unchanged
lineage/handoff and physical-B sizes, source-aware B flags, and a full pinned
`vendor_boot_b` fetch. It then publishes flash-retirement v2 and atomically
archives five files: lineage, claimed handoff, slot-A transaction, runtime
marker, and retirement receipt. Only hash-identical active evidence is removed.
An interrupted active journal is resumable. Once its journal is gone, the
historical archive is deliberately a hard error rather than reusable authority:
it cannot attest later slot-A bytes.

An expired receipt that is still exactly `ready` and unclaimed may be reissued
immediately before flashing with the guarded
`prepare-recovery-anchor.sh reissue-stale-handoff` action documented in
[`recovery-anchor.md`](recovery-anchor.md). It read-only revalidates the bound
device and physical-B lineage, archives the expired receipt, and creates a
fresh one under the same private lock. Never use that action for a claimed
receipt, and never delete or edit recovery state manually.

For both bundles, the runner journals `select_a_bootloader_pending`, selects the
still-exact stock physical A in the bootloader, verifies that selection and both
stock vendor-boot controls, then journals and enters stock-A fastbootd. A
complete A-only logical namespace is mandatory: all six `*_a` names must exist
and every corresponding `*_b` name must return the pinned Platform-Tools
Partition-not-found result. Mixed, incomplete, or B-only namespaces stop before
the first shared-super write.

The GSI path zero-resizes and writes only `system_a` in fastbootd, then later
writes physical `pvmfw_a` and `vbmeta_a`; it requires an additional operator
attestation that the reused slot-A kernel and retained logical partitions are
the exact stock baseline. It is a mixed-partition Treble trial: the validated
runtime sources `product` and `system_ext` from the AOSP GSI's read-only ext4
root through exact `/product -> /system/product` and
`/system_ext -> /system/system_ext` aliases, while `system_dlkm`, `vendor`, and
`vendor_dlkm` retain the stock build identity. Runtime validation rejects a
separate product/system_ext mount or any identity that does not match this
observed split.

The complete cubs path first zero-resizes and writes all six logical-A images.
Only after their expanded sizes are verified and the journaled return to
bootloader A succeeds does it replay the exact 25 firmware payloads followed by
`boot_a`, `init_boot_a`, `dtbo_a`, `vendor_boot_a`,
`vendor_kernel_boot_a`, `pvmfw_a`, `vbmeta_system_a`, `vbmeta_vendor_a`, and
root `vbmeta_a` last. Both paths erase `userdata` and `metadata`, journal
`activate_a_pending`, replay the final `set_active a`, publish
`awaiting_runtime`, and leave the phone in bootloader fastboot. Reboot is an
explicit, separate operator action.

The runner never flashes the outer aggregate bootloader/radio images, never
invokes `--slot=all`, never rewrites the whole super partition, and never
writes, erases, or resizes a `_b` partition (read-only B size/flag queries are
required). It proves `has-slot=yes` and nonzero A/B sizes for every one of the
25 firmware partitions and uses literal `_a` names for every write.
Nevertheless, the first logical `_a` write changes physical extents also
referenced by the other metadata slot. From that point B Android is not a
fallback even if its boot flags remain healthy; B is only the physical
fastbootd lifeboat. A crash may leave A or B selected, and may leave the phone
in bootloader fastboot or A fastbootd. The durable transaction, not an assumed
current slot, determines the recovery action. If USB forwarding disappears,
reattach only the selected phone and rerun the checksum-verified bundle with
the exact resume or abort token; let the runner normalize the transport:

```bash
CUBS_FLASH_RESUME_CONFIRM=RESUME_EXACT_CUBS_A_TRANSACTION_USING_PHYSICAL_B_LIFEBOAT \
  artifacts/gsi/flash-all.sh   # or artifacts/cubs/flash-all.sh
```

Host-only regression simulations exercise both bundle paths with a rejecting,
current-namespace fastboot mock. They cover A-origin ordering, sparse expanded
sizes, status-zero Partition-not-found parsing, crashes at every journal phase,
mixed/incomplete namespace rejection, bootloader/fastbootd abort and abort-ACK
recovery, source-aware B flags, 24-hour replay expiry, runtime-attestation v2,
five-file retirement v2, partial journal reconciliation, historical-archive
hard failure, and complete cubs logical-first/physical-second ordering. They
never enumerate or contact a real device:

```bash
scripts/tests/simulate-flash-safety.sh
```
