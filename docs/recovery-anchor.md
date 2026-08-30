# Stock-B pre-flash anchor and physical lifeboat

> **Scope:** This legacy guide documents the Pixel 11 (`cubs`) workflow only; see the [multi-target layout](multi-target-layout.md) for current target organization.

This procedure sends the checksum-pinned Google full OTA from exact stock A to
inactive B, boots B, and verifies it before the first development write. At
that point B is an exact stock Android anchor. It is intentionally left current
so its physical boot/recovery partitions can launch fastbootd while explicit
logical `_a` partitions are written.

When recovery cannot install that OTA, do not approximate this Android-B path
with direct physical flashes. Complete A/B logical mappings differ. Use the
fastbootd-only route in
[`stock-b-physical-preparation.md`](stock-b-physical-preparation.md), which
explicitly forbids booting Android B.

That stock-Android fallback ends at the first logical write. Pixel 11 uses
Virtual A/B metadata views whose six `_a` and `_b` logical partitions begin on
the same physical `super` extents. Writing `system_a`, `system_dlkm_a`,
`system_ext_a`, `product_a`, `vendor_a`, or `vendor_dlkm_a` therefore changes
blocks referenced by B as well. The B boot-control flags may remain
successful/bootable, but after such a write those flags do not prove that
Android B is bootable or AVB-consistent.

The post-write recovery invariant is narrower: do not write physical B at all.
Preserve its nine `boot`, `init_boot`, `dtbo`, `vendor_boot`,
`vendor_kernel_boot`, `pvmfw`, `vbmeta_system`, `vbmeta_vendor`, and `vbmeta`
partitions plus all 25 individually slotted firmware partitions enumerated in
[`recovery.md`](recovery.md). Those 34 physical partitions retain B's complete
firmware and boot/recovery/fastbootd lifeboat for finishing or retrying an
explicit A restore. Never deliberately boot Android B after shared-super was
modified.

## Stock boots disable ADB

A newly booted stock installation has Developer options and USB debugging
disabled. Every time this workflow boots stock, enable Developer options and
USB debugging and accept this host's RSA prompt. Continue only when
`adb devices` reports exactly one `device`. Never copy the ADB private key into
this repository or a log.

The `device` label alone is insufficient after a wipe: the Trade-In Mode foyer
can expose that label while closing every normal shell. Finish Setup Wizard
before enabling normal USB debugging. The guarded failure and the prohibited
wipe-scheduling command are documented in
[`recovery.md`](recovery.md#adb-reports-device-but-every-normal-shell-closes).

## WSL recovery USB forwarding

Authorized Android ADB and recovery sideload use different USB identities.
Recovery sideload is Google USB ID `18d1:d001`. The supported Windows-side
forwarder is the exact x64 `usbipd-win 5.3.0` release. Download its official
[`usbipd-win_5.3.0_x64.msi`](https://github.com/dorssel/usbipd-win/releases/download/v5.3.0/usbipd-win_5.3.0_x64.msi)
asset to a Windows temporary directory, never into this repository or its
mounted workspace. In an elevated Windows PowerShell, download and inspect it:

```powershell
$UsbipdMsiName = 'usbipd-win_5.3.0_x64.msi'
$UsbipdMsiUrl = 'https://github.com/dorssel/usbipd-win/releases/download/v5.3.0/usbipd-win_5.3.0_x64.msi'
$UsbipdMsi = Join-Path ([IO.Path]::GetTempPath()) $UsbipdMsiName
Invoke-WebRequest -Uri $UsbipdMsiUrl -OutFile $UsbipdMsi
(Get-FileHash -Algorithm SHA256 -LiteralPath $UsbipdMsi).Hash.ToLowerInvariant()
$MsiSignature = Get-AuthenticodeSignature -LiteralPath $UsbipdMsi
$MsiSignature.Status
$MsiSignature.SignerCertificate | Format-List Subject,Thumbprint
$MsiSignature.TimeStamperCertificate | Format-List Subject,Thumbprint
```

The x64 MSI must hash to
`1c984914aec944de19b64eff232421439629699f8138e3ddc29301175bc6d938`.
The official release also reports SHA-256
`efd7c4eb99b144c1623e616064a7b262f83d0994b0d7fde16c95d4b07528b24d`
for `usbipd-win_5.3.0_arm64.msi`; that value is informational only. This
workflow was tested on x64 Windows and does not accept the arm64 payload.

After installing the verified x64 MSI with Windows Installer, validate the
installed payload independently:

```powershell
$UsbipdExe = Join-Path $env:ProgramFiles 'usbipd-win\usbipd.exe'
(Get-Item -LiteralPath $UsbipdExe).Length
(Get-FileHash -Algorithm SHA256 -LiteralPath $UsbipdExe).Hash.ToLowerInvariant()
& $UsbipdExe --version
$ExeSignature = Get-AuthenticodeSignature -LiteralPath $UsbipdExe
$ExeSignature.Status
$ExeSignature.SignerCertificate | Format-List Subject,Thumbprint
$ExeSignature.TimeStamperCertificate | Format-List Subject,Thumbprint
```

The only accepted executable identity is:

```text
size=8803720
sha256=78fd94ca4125db7407c77bd7b985971a1ac95705a331401976f748770035325b
version=5.3.0-54+Branch.master.Sha.aa3db8b82c4cb5071fd31bc54211606c70886912.aa3db8b82c4cb5071fd31bc54211606c70886912
```

For provenance review, the observed executable metadata was product name
`usbipd-win`, product version equal to the exact version line above, file
version `5.3.0.1158`, and a valid Authenticode signature from
`CN="Open Source Developer, Frans van Dorsselaer", O=Open Source Developer,
L=Sassenheim, S=Zuid-Holland, C=NL`. The signer certificate thumbprint was
`30EC478E9FEC6174D949FFF5C00EC028A7D2E8F9`, the timestamp certificate
thumbprint was `C325B89B17FCC5026061CE2B717B4507DD9C6A6A`, and the reviewed x64
MSI ProductCode was `{EA1D5623-E6A7-4E4A-9259-E39722050300}`. These
certificate and product fields are documentation-only corroboration; the
workflow's runtime authority is the exact executable size, SHA-256, and
version output.

`USBIPD_EXE` is only an absolute location override. It cannot change the
configured identity. Before either recovery action executes usbipd-win, the
script canonicalizes that location privately, rejects symlinks and nonregular
files, checks the exact size and SHA-256, executes only the exact `--version`
probe, and re-hashes it. The guarded policy query checks the payload again
before and after execution and suppresses the path and policy rows on every
failure.

With the installed payload validated, use that same explicit path to verify
that an AutoBind policy exists, or add it once if required:

```powershell
& $UsbipdExe policy list
& $UsbipdExe policy add --effect Allow --operation AutoBind --hardware-id 18d1:d001
```

Do not set `CUBS_RECOVERY_USB_READY=1` when the policy list is empty. Both
`install` and `resume-sideload` first prove the configured executable identity,
then read its policy list and stop unless an Allow/AutoBind row contains
`18d1:d001`. Keep an auto-attach process running for the phone's current bus ID
while modes change;
obtain the bus ID from `usbipd list` rather than assuming it remains constant:

```bash
"/mnt/c/Program Files/usbipd-win/usbipd.exe" attach \
  --wsl --auto-attach --unplugged --busid BUSID
```

If recovery fails to attach, no OTA bytes are sent. Repair forwarding and use
the guarded `resume-sideload` action within one hour. Its ignored private marker
binds the pinned OTA, source slot A, age, and a hash of the preflighted USB
serial. The marker is deleted after a successful host-side sideload.

## Verify exact stock A

Preconditions are exact stock `CD1A.260714.001.A9` on A, an unlocked
bootloader, at least 50 percent battery, one authorized ADB device, and both
checksum-pinned Google archives in `downloads/`.

Run:

```bash
scripts/prepare-recovery-anchor.sh check-ota
scripts/prepare-recovery-anchor.sh preflight-android
```

The Android preflight verifies the fingerprint, incremental, SDK, SPL, build
timestamp, stock `user` type, slot, unlocked/orange boot state, boot completion,
bootloader, every reported modem version, and the audited A/B OTA partition
property. It also runs `lpdump -a`, requires `Update state: none`, requires both
metadata headers to identify Virtual A/B, and proves that all six A/B logical
views begin on the same `super` sectors.

## What the same-build full OTA writes

The pinned full OTA has the same post-build fingerprint and timestamp as the
stock system. A full OTA is still allowed in this same-version case; it is not
an incremental downgrade. Its A/B payload writes the inactive B view, including
logical partitions and inactive-slot firmware/bootchain partitions. The
audited partition list is printed by `check-ota` and includes `abl`, `bl31`,
`boot`, `dtbo`, `init_boot`, `modem`, `pvmfw`, all six dynamic partitions,
`vendor_boot`, `vendor_kernel_boot`, the three vbmeta partitions, and the
device's remaining bootchain firmware entries.

This is an intentional B firmware write. It does not write active A or erase
userdata, but it can create a Virtual A/B snapshot that must merge completely.

Install with both environment gates and the exact interactive phrase:

```bash
CUBS_RECOVERY_USB_READY=1 \
CUBS_ALLOW_SLOT_B_OTA=1 \
  scripts/prepare-recovery-anchor.sh install
```

If the recovery USB transition was interrupted:

```bash
CUBS_RECOVERY_USB_READY=1 \
CUBS_ALLOW_SLOT_B_OTA=1 \
  scripts/prepare-recovery-anchor.sh resume-sideload
```

A successful `adb sideload` exit is not proof of a usable B. Recovery should
boot B automatically.

## Verify B and hand directly to flashing

On the fresh stock-B boot, re-enable USB debugging, accept RSA, leave Android
running for at least two minutes, then run:

```bash
scripts/prepare-recovery-anchor.sh verify-android

CUBS_ALLOW_BOOTLOADER_REBOOT=1 \
  scripts/prepare-recovery-anchor.sh reboot-and-verify
```

The second action binds the Android and fastboot transports by a serial hash.
It requires bootloader fastboot, current B, no pending snapshot, healthy A/B
flags, exact firmware, and nonzero slotted A/B sizes for all 25 firmware and
nine boot/recovery lifeboat partitions. It writes no raw serial: a random
anchor ID and salted serial digest bind the transports. Only this bound action,
not the diagnostic `verify-fastboot` action, creates the private
`.cache/recovery-anchor/lifeboat-lineage` and one-hour `flash-handoff` files.
Both are mode `0600` below a mode-`0700` ignored directory. The handoff binds
the exact stock/OTA inputs, shared-super audit, all 34 B sizes, and the reviewed
recovery-policy version.

If the only failed condition is snapshot state `merging` or `snapshotted`, keep
B current and let its merge settle:

```bash
CUBS_ALLOW_STOCK_B_REBOOT=1 \
  scripts/prepare-recovery-anchor.sh continue-b-merge
```

That stock boot disables USB debugging again. Re-enable it and repeat
`reboot-and-verify`. Unknown snapshot states, fastbootd, an unbootable B, and a
current slot other than B are hard stops. Merge continuation is source-gated to
the initial full-OTA path and is rejected once any recovery lineage, handoff,
direct-preparation evidence, or restore transaction exists.

After verification, leave B current. Do not select A manually. Run the reviewed
bundle directly from bootloader fastboot. Before changing the selector, the
runner claims the exact handoff and publishes its slot-A transaction. It then
selects untouched stock A, enters A-origin fastbootd, writes only the complete
A logical namespace, returns to bootloader fastboot, writes physical A, wipes
shared data, and reasserts A as the final device write:

```bash
artifacts/gsi/flash-all.sh
# Later, when the complete image is ready:
artifacts/cubs/flash-all.sh
```

The recovery scripts use the checksum-pinned workspace Platform-Tools 37.0.1
ADB and fastboot binaries rather than an older host `PATH` copy. The
in-repository bundle similarly finds fastboot relative to its own location,
independent of the caller's current directory. A moved bundle must receive an
absolute `FASTBOOT` path and an absolute `CUBS_RECOVERY_HANDOFF` path. Tool
versions and extracted-binary digests are checked.

The recovery-state lock also enforces global transaction ownership. OTA and
anchor actions reject an unresolved direct physical-B finalized-restore
baseline, preflight, preparation, trial, or consumption evidence, plus an
active stock-restore or
flash-retirement transaction or slot-A flash transaction. Direct actions
likewise reject the restore journal. Only the action that created a journal may
reconcile it; never remove a marker manually to cross from one recovery
workflow into another.

Immediately before its first device mutation, the runner atomically claims the
fresh handoff for the exact digest of that bundle's `SHA256SUMS` and publishes a
salted `slot-a-flash-transaction`. A failed transaction leaves both records
active. Only the same bundle may resume a nonterminal transaction within 24
hours, and only with the separately explicit token printed by the runner. It
may instead be moved to the exact terminal `aborted_for_restore` state with the
separate abort token; `restore-stock.sh` adopts and retires that record rather
than asking the operator to delete it. A successful flash also leaves the
transaction and handoff active: physical-B recovery authority is retained
until exact slot-A Android passes runtime validation. Publish the bundle-bound
runtime-v2 marker and use the separate bootloader finalizer described in
[`runtime-validation.md`](runtime-validation.md). That finalizer journals and
atomically archives five files: lineage, claimed handoff, slot-A transaction,
runtime marker, and retirement receipt. Never delete or edit a claimed receipt
or transaction to switch bundles; use the stock restore if the exact
transaction cannot be resumed.

If flashing did not start and the receipt expires in `ready` state, do not
delete or edit it by hand. Keep physical B current in bootloader fastboot and,
immediately before the reviewed flash, run the guarded host-only reissue:

```bash
CUBS_ALLOW_STALE_HANDOFF_REISSUE=1 \
  scripts/prepare-recovery-anchor.sh reissue-stale-handoff
artifacts/cubs/flash-all.sh   # or the reviewed GSI bundle
```

The action accepts only an expired, unclaimed, exact-schema receipt whose
bundle fields are still `none`. It checks exact firmware, snapshot and slot
state, all 34 physical-B sizes, the bound transport, and immutable lineage
both before and after its interactive confirmation. It sends no mutating
fastboot command. Under the private state lock it copies the expired receipt to
a mode-`0700` retirement archive, then atomically replaces the active path with
a fresh one-hour receipt, so interruption never leaves authority absent. A
fresh receipt must be used as-is. A claimed,
malformed, foreign-policy, or lineage-mismatched receipt is never eligible for
reissue and remains a resume-or-stock-restore condition.

## Selecting B for a later flash

A successful flash leaves A current in bootloader fastboot. For a later
reviewed flash, the guarded selector may make physical B current without
rebooting it:

```bash
CUBS_ALLOW_SELECT_B_LIFEBOAT=1 \
  scripts/prepare-recovery-anchor.sh select-b-lifeboat
```

This action is not a substitute for the initial stock-B verification route. It
accepts current A or a crash-resume on already selected B, and requires exact
firmware, no snapshot, B not-unbootable, healthy A, source-aware B-success
semantics, immutable lineage, all 34 explicit physical pairs/sizes, and a full
checksum-pinned live `vendor_boot_b` fetch. It publishes the exact one-hour
`physical_b_lifeboat` handoff before `set_active b`, then repeats the entire
audit after selection. A host loss after the acknowledgement is therefore
resumable without an unjournaled B state. Run `flash-all.sh` immediately; never
reboot invalid Android B.

## Stop conditions

Stop instead of improvising if more than one transport appears, identity or
firmware differs, snapshot state is unknown, recovery reports an install
failure, B physical flags/sizes fail, or WSL forwarding cannot be restored.
Do not erase partitions, select a slot blindly, relock, or run Google's outer
factory flashing script. If shared-super has already been modified, preserve
the physical B lifeboat and use the explicit restore in
[`recovery.md`](recovery.md).
