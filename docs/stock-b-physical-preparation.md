# Direct physical-B fastbootd lifeboat

Use this fallback only when stock recovery cannot install the pinned full OTA.
It prepares the 34 physical B partitions needed for fastbootd: 25 firmware
images and nine boot/recovery images. It never writes `super`, logical
partitions, userdata, metadata, aggregate bootloader/radio images, or an
unsuffixed partition target.

This route does **not** create bootable Android B. The restored shared-super
metadata exposes only the six stock `_a` logical partitions, even while the
physical boot-control slot is B. Fresh physical-B boot/AVB images plus that
A-only logical namespace must never boot Android. While B is current, the only
authorized boot target is userspace fastbootd followed immediately by
bootloader fastboot.

## Preconditions

Start in bootloader fastboot on healthy, successful exact stock
`CD1A.260714.001.A9` A, with an unlocked bootloader, at least 50 percent
battery, and the checksum-pinned factory archive. The v7 bridge also requires
the one exact terminal stock-restore receipt named by `config/recovery.env`.
That receipt exists only after restored stock A booted successfully and the
stock finalizer completed its second Android audit and full `vendor_boot_b`
control.

Receipts are private mode-`0600` files below ignored, mode-`0700`
`.cache/recovery-anchor/`. They use salted serial bindings, not raw serials.
Active direct evidence blocks the OTA workflow until it is consumed or
recovered.

Recovery transactions have a single owner and are globally exclusive. Every
direct attestation, preparation, refresh, and trial entry rejects an active
`stock-restore-transaction`, `flash-retirement-transaction`, runtime boot
attestation, `slot-a-flash-transaction`, or incompatible lineage/handoff. Only
the slot-A flash owner may reconcile its flash transaction. Only `restore-stock.sh` may
reconcile its restore journal, only the bundle finalizer may reconcile its
flash-retirement journal, and only `resume-finalize` may reconcile a
`stock-b-consumption-transaction`. Do not delete, rename, or bypass one of
these markers to start a different workflow.

## 1. Claim the finalized stock-A baseline

Use the exact fastboot serial and both authorization gates:

```bash
export CUBS_FASTBOOT_SERIAL='<fastboot-serial>'
export CUBS_ALLOW_FINALIZED_RESTORE_BASELINE=1
export CUBS_FINALIZED_RESTORE_CONFIRM=ADOPT_FINALIZED_RESTORE_BOOTLOADER_AS_STOCK_A_BASELINE
scripts/attest-stock-a-for-physical-b.sh adopt-finalized-restore-bootloader
```

Type the same phrase at the TTY prompt. Before and after that unbounded pause,
the action verifies the pinned Platform-Tools fastboot binary, sole selected
transport, exact product/firmware, current healthy A, unlocked state,
snapshot=`none`, battery, all 34 physical A/B pairs and sizes, and full
`vendor_boot_a` and `vendor_boot_b` bytes. It extracts the six stock logical
images and derives their expanded, 4096-byte-aligned sizes directly from raw or
Android-sparse headers.

The terminal restore receipt is private and is verified by exact SHA-256,
schema, transaction ID, prior recovery-policy SHA, salted serial binding,
physical-B geometry, and an exact adopted-runtime-attestation pin. That pin is
either the reviewed 64-hex runtime marker digest or literal `none` for a
reviewed restore of an aborted flash which minted no runtime authority. The
claim is an atomic same-filesystem move from its
canonical consumed-restore pathname to `stock-a-baseline-evidence`; it is never
copied. A crash after that move but before preflight publication is reconciled
by running the same command again. Success publishes only
`cubs-stock-a-physical-b-preflight-v3` in state `bootloader_verified`, bound to
the baseline receipt and six factory-expanded logical sizes. No device command
is issued and no slot changes.

Old Android/two-slot-`lpdump` preflights and legacy preparation policies have
no v7 authority. Do not recreate, copy, rename, or hand-edit the one-shot
baseline receipt.

## 2. Flash the exact physical-B allowlist

```bash
export CUBS_FASTBOOT_SERIAL='<fastboot-serial>'
export CUBS_ALLOW_STOCK_B_WRITE=1
export CUBS_STOCK_B_CONFIRM=PREPARE_EXACT_STOCK_PHYSICAL_B_SET_ACTIVE_B_NO_REBOOT
scripts/prepare-stock-b-physical.sh prepare
```

Type the same phrase at the TTY prompt. Immediately afterward the script
repeats all live, baseline/preflight, archive, image, fit, and size checks.

The exact allowlist is:

- firmware: `abl`, `bl31`, `cap`, `cpm`, `dbc`, `dbl`, `dram_init_0` through
  `dram_init_11`, `dram_phy`, `gc`, `gdmc`, `gsa_bl1`, `gsa_fw`, `tzsw`,
  `modem`;
- boot/recovery: `boot`, `init_boot`, `dtbo`, `vendor_boot`,
  `vendor_kernel_boot`, `pvmfw`, `vbmeta_system`, `vbmeta_vendor`, `vbmeta`.

The outer factory SHA, inner ZIP SHA, canonical 34-line physical source
manifest SHA, and `vendor_boot.img` SHA are exact policy pins. The script also
extracts all six logical images and requires their expanded sizes and fixed
order digest to equal preflight-v3. All 40 archive entries must occur once at
the ZIP root, and all extracted bytes, hashes, and logical expanded sizes are
rechecked after the TTY gate and during continuation/refresh paths. Every
physical target must report slotted, physical, nonzero A/B sizes, and the image
must fit B. All writes use literal `*_b` names. The two vbmeta children precede
root `vbmeta_b`, which is the 34th and final image write. A/B sizes and healthy
A are rechecked around every command.

After 34 acknowledged flash exits, the script fetches the complete
`vendor_boot_b` partition and requires its size and SHA to equal the pinned
source. That is the only supported device-byte readback control; bootloader
policy prevents full readback of most other partitions. The source manifest
therefore means pinned source bytes plus acknowledged flash transactions, not
a claim that all 34 device partitions were read back.

The script publishes `activation_pending`, selects B only after every image and
fetch check, then publishes a fresh `ready` receipt with
`android_b_booted=no`. Preparation-v2 binds the baseline SHA, stock-A preflight
SHA, six-size digest, physical A/B size digests, 34-entry source manifest, and
full `vendor_boot_b` fetch. It never reboots.

If the process stops before the private manifest is published, A remains
current and replaying `prepare` safely reflashes the entire explicit allowlist;
there is no claim that an unrecorded partial count is a journal. An exact
orphan manifest is collision-safely archived before replay. If
`activation_pending` exists—whether current A still reports B unbootable or B
was already selected—continue without reflashing:

```bash
export CUBS_STOCK_B_CONFIRM=FINALIZE_EXACT_STOCK_PHYSICAL_B_ACTIVATION_NO_REBOOT
scripts/prepare-stock-b-physical.sh finalize-activation
```

The finalizer accepts a stale exact pending receipt, repeats every source/live
check, performs a fresh full `vendor_boot_b` fetch, selects B only if A is
still current, and publishes a new one-hour ready receipt. Never delete a
pending receipt.

If an exact `ready` receipt expires while recovering WSL USB forwarding, keep
B in bootloader and renew host authority without reflashing or changing slots:

```bash
export CUBS_STOCK_B_CONFIRM=REFRESH_EXACT_STOCK_PHYSICAL_B_RECEIPT_NO_REBOOT
scripts/prepare-stock-b-physical.sh refresh-ready
```

The refresh accepts historical evidence only after repeating the pinned tool,
factory/inner archive, canonical source manifest, all image, current-B,
firmware, snapshot, physical-size, fit, battery, and full `vendor_boot_b` byte
checks on both sides of its TTY gate. Only fresh receipt timestamps change.

An exact same-transport OTA resume marker, including an expired one, is
archived under the lock before the first flash. Malformed, future, foreign
device/OTA, or wrong-source markers are hard stops.

## 3. Run the one-shot fastbootd trial

Start while at least five minutes remain in the preparation receipt:

```bash
export CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL=1
export CUBS_STOCK_B_FASTBOOTD_CONFIRM=TRIAL_PREPARED_PHYSICAL_B_FASTBOOTD_ONLY_NEVER_ANDROID_B
scripts/verify-stock-b-fastbootd-lifeboat.sh start
```

After a TTY confirmation and repeated checks, the script writes `started`
before its sole `reboot fastboot`. In fastbootd it verifies the same serial,
`cubs`, userspace mode, unlocked state, two slots, current B, snapshot `none`,
and `has-slot:super=no`. It never queries `slot-successful` or any physical
partition size in fastbootd.

The observed restored-stock namespace is deliberately counterintuitive:
physical slot B remains current, but fastbootd exposes only six literal `_a`
logical partitions. For all six bases, `has-slot:<base>` must return one
uniform value, exactly `no`. Unsuffixed logical probes must return the exact
audited absent responses. Each `<base>_a` must report logical=`yes` and a size
equal to the factory-expanded preflight-v3 value. Every `<base>_b` logical
probe must return exactly `Partition not found`, and every B-size probe exactly
`Could not open partition`.

Every getvar is parsed as a status/output pair. A value is accepted only with
status zero, exactly one parsed value, and no `FAILED` record. Absence is
accepted only with no parsed value and exactly one expected remote-failure
record; the audited Platform-Tools exit-zero absence quirk is allowed.
Duplicate, mixed, malformed, extra-failure, or `is-logical:no` output can never
be mistaken for absence. The trial never changes the active slot in fastbootd.

Before leaving fastbootd, the receipt becomes `fastbootd_verified`. The script
then issues only `reboot bootloader`, rechecks exact firmware, current B,
B not-unbootable, healthy A, all physical A/B size digests, and a fresh full
`vendor_boot_b` fetch. B successful may be readable `yes` or `no`; selecting B
can clear it, and direct lineage never claims an Android-B boot. Full-OTA
Android-B lineage still requires `yes`.

Success publishes `verified`, creates direct provenance and a one-hour
`physical_b_lifeboat` handoff, and archives the stock-A baseline, preflight-v3,
source manifest, preparation-v2 receipt, and trial-v4 receipt together. The
trial receipt records `logical_base_has_slot_mode=no`,
`logical_namespace=a_only`, and the six verified `_a` sizes. The phone remains
in bootloader fastboot with B current.

After a USB or host interruption, never issue another `reboot fastboot`. Resume
the existing state machine instead:

```bash
export CUBS_STOCK_B_FASTBOOTD_CONFIRM=RESUME_OR_FINALIZE_ONE_SHOT_PHYSICAL_B_FASTBOOTD_NEVER_ANDROID_B
scripts/verify-stock-b-fastbootd-lifeboat.sh resume-finalize
```

This continues `started` only when the device is already in fastbootd,
continues `fastbootd_verified` from fastbootd or B bootloader, and finalizes a
`verified` receipt or orphan exact lineage without a second trial. Ambiguous
`started` plus bootloader B cannot prove fastbootd ran; the action selects
untouched stock A and archives the aborted evidence instead of minting lineage.
That fallback is itself two-phase: `aborting_to_a` is durable before
`set_active a`, and `aborted_to_a` is durable after live A verification. A
crash after the slot-selection acknowledgement resumes safely from current A
without replaying either slot selection or the fastbootd trial.

Successful and aborted evidence is first copied into a complete private
directory and published with one atomic rename. A separate mode-`0600`
v3 consumption transaction binds the baseline, logical-size digest, current
source-preparation policy, and current trial policy and remains until all five
identical active copies are removed. `resume-finalize` reconciles that
transaction before parsing any possibly partially cleaned active set;
archive-cleanup crashes therefore issue no device command and cannot split the
only copy of provenance. No legacy preparation or trial receipt has migration
authority under v7.

## 4. Flash development A

Run the reviewed bundle immediately:

```bash
artifacts/gsi/flash-all.sh
# or, after the complete bundle passes static validation, for its controlled
# on-device qualification:
artifacts/cubs/flash-all.sh
```

The runner still requires current B, B not-unbootable, healthy A, exact
firmware, exact source provenance, unchanged physical sizes, and the private
lineage/handoff. Only direct lineage accepts readable B successful=`no`. The
first shared-super logical A write invalidates Android B permanently. The
claimed recovery handoff remains after slot A is selected; it is retired only
by the separately gated finalizer after a matching exact runtime boot
attestation, so a failed first Android-A boot retains stock recovery authority.

## Host-only simulation

With the pinned factory and nested ZIP present:

```bash
scripts/tests/simulate-finalized-stock-restore-baseline.sh
scripts/tests/simulate-stock-b-physical-preparation.sh
scripts/tests/simulate-stock-b-consumption-journal.sh
```

The rejecting mock proves explicit order, full fetch controls, both TTY gates,
receipt states, `slot-successful:b=no`, no Android-B reboot, the exact A-only
logical namespace, and private five-file provenance archival without touching
a real device. It injects USB loss after entering fastbootd, malformed absence
output, and the abort-to-A crash boundary without replaying `reboot fastboot`
or slot selection. The small journal test covers crashes before archive
publication and midway through active-evidence cleanup.
