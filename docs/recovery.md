# Explicit stock-A recovery

> **Scope:** This legacy guide documents the Pixel 11 (`cubs`) workflow only; see the [multi-target layout](multi-target-layout.md) for current target organization.

The recovery input is Google's checksum-pinned `CD1A.260714.001.A9` factory
archive. Keep the bootloader unlocked throughout development. This project does
not run Google's outer flashing script or pass the inner archive to fastboot as
an aggregate update: those paths can select A before writes finish, cancel
snapshots, rewrite shared-super metadata broadly, and touch firmware or B.

## Preconditions

- The phone is in bootloader fastboot with physical A or B current. A may be
  failed or marked unbootable after a development trial; the retained
  ready/claimed handoff and restore journal authorize a crash-safe selection
  of verified physical B before any restore write.
- B is not marked unbootable; its 25 physical firmware and nine
  boot/recovery/fastbootd partitions are the lifeboat. First-use full-OTA
  `stock_b_anchor` lineage requires successful=`yes`; a bound
  `physical_b_lifeboat` selector handoff or the exact restore journal permits
  the known post-`set_active b` `no` value. Verified direct fastbootd-only
  lineage accepts readable `yes` or `no`. B Android is never assumed bootable.
- Product is `cubs`, the bootloader is unlocked, snapshot state is `none`, and
  battery is at least 50 percent.
- Bootloader and baseband exactly match the verified inner factory package.
- Private lineage and a ready/claimed handoff exactly match the transport,
  firmware, policy, and canonical 34-partition B-size digest.
- No flash-retirement journal or unresolved direct physical-B finalized-stock
  baseline, preflight, preparation, trial, or consumption transaction exists;
  only its owning workflow may reconcile that state before restore begins.
- The regular, nonsymlink Platform-Tools 37.0.1 `fastboot` executable is
  selected by canonical path and matches the pinned extracted-binary SHA-256.
- Exactly one fastboot device is attached and its serial is provided explicitly.
- Windows/WSL forwarding is kept alive across bootloader and fastbootd modes.

The restore refuses a bootloader/baseband version mismatch. It restores the 25
individually slotted firmware A images plus the six boot-support A images from
the checksum-pinned inner factory ZIP. It never flashes the outer aggregate
`bootloader.img` or `radio.img`, and never consumes `fastboot-info.txt`,
`super_empty.img`, `system_other.img`, or the factory userdata image.

## Restore transaction

Set all three gates, then run from a controlled shell:

```bash
export CUBS_FASTBOOT_SERIAL='<fastboot-serial>'
export CUBS_ALLOW_DATA_WIPE=1
export CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID
scripts/restore-stock.sh
```

By default the restore selects
`work/toolchains/platform-tools/fastboot` when present, otherwise the resolved
`fastboot` on `PATH`. `FASTBOOT`, when set, must be an absolute path. Every path
is canonicalized and the regular-file, nonsymlink, executable, version, and
SHA-256 checks finish before device enumeration or image extraction.

The script verifies the outer archive hash and proves that each of its 40 exact
root image entries occurs once before extracting only that allowlist into
ignored `work/` storage. It records no device serial.

The device sequence is deliberately explicit:

1. In bootloader fastboot, verify current A or B, exact firmware, snapshot
   state, battery, and nonzero slotted sizes for both A/B copies of all 34
   physical firmware and boot/recovery partition classes. If necessary,
   journal and select verified physical B before entering fastbootd. No Android
   B boot is authorized.
2. Enter B-origin stock fastbootd under the transaction journal. It may expose
   only the current B logical namespace before shared-super metadata fans out.
   If so, issue `set_active a` and the first A logical resize in the same
   fastboot connection, then reconcile the connection, current slot, complete
   A-only namespace, and exact zero size. An already A-only namespace is the
   expected crash-resume state. A mixed namespace is a hard stop.
3. Resize all six literal logical `_a` partitions to zero and flash their six
   exact stock images. Every resize and flash carries `set_active a` in the same
   fastboot invocation so a reconnect cannot silently bind it to B metadata.
   The first metadata-changing command invalidates Android B because its
   logical view shares physical `super` extents; physical B remains untouched.
4. Return explicitly to bootloader fastboot, reconcile A as the selector, and
   only then flash literal `_a` names for `abl`, `bl31`, `cap`, `cpm`, `dbc`,
   `dbl`, `dram_init_0` through `dram_init_11`, `dram_phy`, `gc`, `gdmc`,
   `gsa_bl1`, `gsa_fw`, `tzsw`, and `modem`, followed by `boot`, `init_boot`,
   `dtbo`, `vendor_boot`, `vendor_kernel_boot`, and `pvmfw`. Recheck every
   physical B size and the full pinned `vendor_boot_b` bytes.
5. Flash `vbmeta_system_a`, `vbmeta_vendor_a`, and root `vbmeta_a` in that
   order. Production AVB images are used without verification-disable flags;
   root vbmeta is last.
6. Prove `userdata` and `metadata` are nonzero unslotted partitions, erase both,
   publish `activate_a_pending`, and reassert A as the final device write. After
   rechecking flags and exact evidence, publish `awaiting_stock_android`. The
   script deliberately retains the lineage and ready/claimed handoff; a stock-A
   boot failure can therefore re-enter the same restore from current A or B.

No command uses an implicit/current-slot partition name. No B partition,
whole-super image, aggregate bootloader/radio image, secondary-slot mode, or
archive task list is in the restore allowlist.

The six logical plus 34 physical partition names are the same as the complete
development `cubs` bundle. The important differences are provenance and
preparation: stock
restore uses the verified Google images and keeps production AVB enabled. Both
complete workflows zero all six logical A sizes and flash root `vbmeta_a` last.
The raw GSI
trial is narrower (`system_a`, `pvmfw_a`, and `vbmeta_a`) and disables
verification only on its generated root vbmeta.

The private v2 `stock-restore-transaction` journals `select_b_pending`,
`enter_b_fastbootd_pending`, `pivot_a_metadata_pending`,
`restoring_logicals`, `return_bootloader_pending`, `restoring_physical`,
`activate_a_pending`, `awaiting_stock_android`, `boot_control_pending`, and
`retiring_evidence`. A selector, mode-transition, metadata-fanout, or command
acknowledgement failure can therefore be reconciled without guessing the
current namespace or slot. If the transaction stops after the metadata pivot,
Android B is already invalid. Do not reboot it or manually change slots; rerun
the same explicit restore in the journaled bootloader or fastbootd mode:

```bash
scripts/restore-stock.sh
```

After the write phase, inspect bootloader state and explicitly reboot A. A
factory wipe means stock boots with Developer options and USB debugging
disabled; enable them and accept the host RSA prompt. Do not delete the retained
recovery evidence. Once exact stock A has completed boot, retire it with the
separately gated action:

```bash
export CUBS_ALLOW_STOCK_RESTORE_FINALIZE=1
export CUBS_RESTORE_CONFIRM=FINALIZE_EXACT_STOCK_A_RESTORE_AFTER_SUCCESSFUL_ANDROID_BOOT
scripts/restore-stock.sh finalize-stock-android
```

This action uses the exact workspace-pinned ADB binary and audits the stock
fingerprint/build, firmware, slot A, boot completion, inactive snapshot state,
and readable nonempty A logical partitions both before and after its interactive
prompt. It then atomically publishes `boot_control_pending`, reboots that same
salt-bound transport to bootloader, and uses the pinned fastboot binary to
require A successful/bootable, B not-unbootable, exact firmware and physical-B
sizes, the same lineage/handoff, and a full checksum-pinned `vendor_boot_b`
fetch. Only then does it publish `retiring_evidence`, remove active evidence,
and archive the restore receipt. It leaves successful stock A selected in
bootloader fastboot.

If interrupted at `boot_control_pending`, rerun the same action. From Android
it repeats the exact runtime audit and reboot; from fastboot it repeats the
success-bit and lifeboat audit. If A is not marked successful, evidence remains
active: boot A again, re-enable USB debugging, and retry. A
`retiring_evidence` interruption is host-only and idempotently completes even
if USB is gone. To establish a fresh pre-flash B anchor after retirement,
follow [`recovery-anchor.md`](recovery-anchor.md).

### ADB reports `device`, but every normal shell closes

A freshly wiped stock phone can remain in the Trade-In Mode foyer during Setup
Wizard. In that state `adb devices` may misleadingly report `device`, while an
ordinary shell exits with `error: closed`. Finish Setup Wizard on the phone
first. Then enable Developer options and normal USB debugging, accept this
host's RSA prompt, and retry the finalizer.

Google's [ADB Trade-In Mode architecture](https://android.googlesource.com/platform/packages/modules/adb/+/HEAD/docs/dev/adb_tradeinmode.md)
documents that this restricted daemon is activated only during Setup Wizard,
allows essentially only the `tradeinmode` shell command, and deliberately does
not use normal host authorization.

The stock finalizer and other Android-side stock audits fail before any receipt
transition or device mutation when they see this state. Their shared guard uses
only a noninteractive `true` shell probe and the read-only `tradeinmode
getstatus` diagnostic. It discards all diagnostic output because the response
can contain hardware identifiers. The v7 direct physical-B bridge instead
starts later, from the exact finalized restore receipt in bootloader fastboot.
Never run
`adb shell tradeinmode evaluate`: that action schedules a data wipe and is not
part of this project.

Do not relock during development. Relocking with non-stock or incompletely
restored partitions can make recovery substantially harder.

When the pinned factory archive is present, the complete restore transaction
can be replayed against rejecting host-only fastboot and ADB mocks. It asserts
the exact logical-first/physical-second order, metadata-pivot and command-ACK
reconciliation, all firmware proofs, current-A failure recovery, salted
transport mismatch rejection, both Android and fastboot
`boot_control_pending` resumes, terminal flash-abort adoption, the A-success
gate, and partial retirement cleanup. It never enumerates or contacts a real
device:

```bash
scripts/tests/simulate-restore-safety.sh
```

The normal-shell/Trade-In Mode guard has a separate archive-independent host
simulation. It runs isolated copies of both production entry points, records
the exact read-only ADB commands, and proves that no receipt or reboot is
reached:

```bash
scripts/tests/simulate-stock-adb-shell-gate.sh
```

## WSL USB notes

Windows must keep the same phone attached to WSL across both fastboot modes.
The scripts tolerate a temporary disappearance, reject a different/additional
device, and time out without changing another phone. If Android ADB is later
authorized but the user daemon cannot open the forwarded device, the tested
fallback uses a root ADB server with the existing user's key:

```bash
platform_adb="$PWD/work/toolchains/platform-tools/adb"
sudo "$platform_adb" kill-server
sudo env ADB_VENDOR_KEYS="$HOME/.android/adbkey" ADB_LIBUSB=0 \
  "$platform_adb" start-server
```

Never copy an ADB private key into this repository or a validation log.
