# Runtime validation

> **Scope:** This legacy guide documents the Pixel 11 (`cubs`) workflow only; see the [multi-target layout](multi-target-layout.md) for current target organization.

`scripts/validate-runtime.sh` performs the read-only, post-boot acceptance audit
for the raw GSI trial and complete cubs build. It never reboots the phone,
changes a setting, starts an activity, writes a device file, or changes ADB
daemon privileges.

## Invocation

Enable USB debugging. The development images deliberately run unauthenticated
adbd: the GSI reports literal `ro.adb.secure=0`, while the complete cubs
userdebug build may leave the property unset (also effective false) or load the
debug-ramdisk value `0`. No RSA approval is therefore expected after either
development image boots. Do not connect this boot to an untrusted USB host. If
it is the only ADB transport in the `device` state, the script selects it and
still passes its resolved serial through `adb -s` for every subsequent command:

```bash
scripts/validate-runtime.sh gsi
```

When more than one transport may be in `device` state, select cubs explicitly:

```bash
export CUBS_ADB_SERIAL='<adb-serial>'
scripts/validate-runtime.sh cubs
```

Discovery accepts exactly one transport in the `device` state; offline or
otherwise unusable transports are not candidates. This state means ADB shell
traffic works; it does not imply RSA authentication. Every device operation
after discovery includes `-s`. The serial is validated before use, but is never printed or
placed in a report. `ANDROID_SERIAL` is also accepted, and must agree when both
variables are set. `ADB=/path/to/adb` can override the workspace platform-tools
binary.

Every ADB operation has a 20-second host-side timeout so a lost USB transport
cannot block the audit indefinitely. `CUBS_ADB_TIMEOUT_SECONDS` can set a value
from 1 through 120 seconds.

The command exits nonzero when a hard gate fails. It writes a mode-labelled UTC
report under `logs/`, with permissions `0600`. Logs are local state and are
excluded from version control. Exit zero alone is not a release decision,
because unavailable privileged evidence can remain a warning.

## Publishing post-boot flash proof

Ordinary validation does not change recovery authority. After reviewing a
successful report for the exact flashed bundle, rerun (or run initially) with
the explicit host-state gate:

```bash
CUBS_PUBLISH_RUNTIME_ATTESTATION=1 scripts/validate-runtime.sh gsi
# or: CUBS_PUBLISH_RUNTIME_ATTESTATION=1 scripts/validate-runtime.sh cubs
```

Publication remains read-only on the phone. Under the private recovery lock it
requires both the active claimed handoff and the exact v1 slot-A flash
transaction in `awaiting_runtime`. They must match the selected ADB transport,
mode, bundle `SHA256SUMS`, exact lineage/firmware, logical targets and expanded
image sizes, mode-specific product and partition identities, physical
`ro.product.vendor.device=cubs`, ADB-security mode, slot A, build/SPL/type,
`sys.boot_completed`, boot ID, uptime, and the just-written report hash. The
marker's existing schema-v2 `device` field remains the verified physical vendor
device (`cubs`), not the GSI's generic product name. It atomically writes a
mode-`0600` v2 marker at `.cache/recovery-anchor/runtime-boot-attestation`,
including the exact flash
transaction hash. A moved bundle must be selected with an absolute
`CUBS_RUNTIME_BUNDLE_DIR`.

Return that same phone explicitly to bootloader, then run the same bundle with
its separate finalize token:

```bash
platform_adb="$PWD/work/toolchains/platform-tools/adb"
"$platform_adb" -s "$CUBS_ADB_SERIAL" reboot bootloader
export CUBS_FLASH_FINALIZE_CONFIRM=FINALIZE_EXACT_CUBS_A_TRANSACTION_AFTER_SUCCESSFUL_ANDROID_BOOT
artifacts/gsi/flash-all.sh   # or the same cubs bundle that was validated
```

The finalizer does not reflash. It requires A marked successful, revalidates the
marker and physical-B lifeboat including a full `vendor_boot_b` fetch, then uses
a durable v2 journal to archive five files together: lineage, claimed handoff,
slot-A flash transaction, runtime marker, and retirement receipt. Only
hash-identical active files are removed. If that journal is interrupted, rerun
the same bundle/finalize token. After completion, its historical archive is
evidence of what was retired, not authority for a later A image, and deliberate
reuse is a hard error.

A run with no hard failures but one or more limitations reports
`result=PASS_WITH_WARNINGS`, not an unqualified pass. In particular, always
inspect the separate `vintf_compatibility` field; `inconclusive` is not a
release-qualification result even though the other read-only gates may pass.

## Recorded raw-GSI result

The controlled GSI probe used the bundle whose `SHA256SUMS` digest is
`948419ad510d417cee78151058ffe41bceb8baf9d5f364bc57b0e5e5815cfb53`
and whose build-attestation digest is
`34d4b579f03363de1be6560ab7de3157009dbf6bd8cb492a8ba958cafe120d62`.
The report used for the runtime-v2 publication was
`runtime-validation-gsi-20260829T072539Z-2048706.txt`, SHA-256
`97631553088798e67b7887119d91ffbebb989e19b23627838d3058159513d226`.
It recorded 128 passes, zero failures, four warnings, and
`vintf_compatibility=inconclusive`.

That audit began with adbd already running as root, so it could read the
boot-control success flags without changing the phone. Its warnings were the
intentional unauthenticated development ADB configuration, unavailable
unprivileged runtime snapshot status, unavailable on-device `checkvintf`, and
the consequent inconclusive VINTF result.

After a second normal boot, the fresh report
`runtime-validation-gsi-20260829T072642Z-2050253.txt`, SHA-256
`96c06c33dbb51af4c73b2931e1bc6d551c64357da4f224cba4bced9c931baedc`,
recorded 125 passes, zero failures, and five warnings. It ran under the ordinary
non-root shell, so inaccessible boot-control flags added the fifth warning. The
same build and partition identities were retained. These results prove two
completed GSI boots and the checks recorded by the validator; they do not prove
VINTF compatibility or working hardware.

## Recorded corrected complete-cubs result

The corrected cubs bundle whose `SHA256SUMS` digest is
`832f50115b07cedbee902daefc82fb75c151874395e524aad0dfee540b458e23`
and whose build-attestation digest is
`1676ed35d049dab56976eb12dd1e0858a7aa56b1aba0b343d023b68ea8fda080`
was flashed in full on the real device. It used its packaged production AVB
topology with development test keys and no verification-disable flags. Android
reached `sys.boot_completed=1` on slot A, reported the expected cubs Android 17
`userdebug` fingerprint, and kept `ro.boot.veritymode=enforcing`.

The report used for runtime-v2 publication was
`runtime-validation-cubs-20260829T182257Z-3677013.txt`, SHA-256
`14a5a517a77cbfa68e148813faf84a6dafe51579117c2ddd0e071fc942da7a5c`.
It recorded 127 passes, zero failures, five warnings, and
`vintf_compatibility=inconclusive`. The private runtime attestation used for
finalization had SHA-256
`5bc6efc20ab29bc4316e35a037a35d84e1aa292201bad00b867d47d23aac87c1`.
Its warnings were unauthenticated development ADB, inaccessible unprivileged
snapshot and boot-control evidence, unavailable on-device `checkvintf`, and
the consequent inconclusive VINTF result.

A second normal boot completed in 38 seconds on the same slot A and produced
`runtime-validation-cubs-20260829T183044Z-3681111.txt`. That fresh audit again
recorded `PASS_WITH_WARNINGS`, 127 passes, zero failures, five warnings, and the
same build and partition identities. The exact transaction finalizer then
succeeded and atomically archived the active lineage, claimed recovery handoff,
slot-A transaction, runtime proof, and retirement record. A final normal boot
after finalization completed in 20 seconds with fingerprint
`google/cubs/cubs:17/CD1A.260714.001.A9/pixel_aosp17_r1:userdebug/test-keys`
and enforcing verity.

These records establish two audited boots of the corrected packaged images and
a third post-finalization boot; no cubs flash transaction remains pending.
VINTF and incomplete manual hardware coverage still prevent an unqualified
release result. Camera and hardware evidence is recorded separately in
[`functional-validation.md`](functional-validation.md).

## Identity expectations

Both modes must report Android 17 / SDK 37, slot A, `userdebug`,
`ro.debuggable=1`, test keys, the pinned AOSP security patch, an unlocked-device
verified-boot state, enforcing SELinux, and a completed boot. The GSI must
report `ro.product.device=generic_arm64`; the complete product must report
`ro.product.device=cubs`; both must report
`ro.product.vendor.device=cubs`. The GSI's `ro.adb.secure` must be exactly `0`.
For cubs it must be unset or `0`, the only two expected userdebug/debug-ramdisk
forms; `1` is rejected in both modes.

The modes deliberately have different partition identities:

| Partition | `gsi` expectation | `cubs` expectation |
| --- | --- | --- |
| `system` | AOSP `CP2A.260605.016`, `userdebug` | cubs `CD1A.260714.001.A9`, `userdebug` |
| `system_dlkm` | stock `CD1A.260714.001.A9`, `user` | cubs `CD1A.260714.001.A9`, `userdebug` |
| `system_ext` | AOSP `CP2A.260605.016`, `userdebug`, embedded in GSI root | cubs `CD1A.260714.001.A9`, `userdebug` |
| `product` | AOSP `CP2A.260605.016`, `userdebug`, embedded in GSI root | cubs `CD1A.260714.001.A9`, `userdebug` |
| `vendor` | stock `CD1A.260714.001.A9`, `user` | cubs `CD1A.260714.001.A9`, `userdebug` |
| `vendor_dlkm` | stock `CD1A.260714.001.A9`, `user` | cubs `CD1A.260714.001.A9`, `userdebug` |

The GSI table is intentionally mixed. On the validated boot, `/product` points
exactly to `/system/product` and `/system_ext` points exactly to
`/system/system_ext`; neither is a separate mount. Both inherit the read-only
ext4 root mount and report the AOSP GSI identity. A separate mount, wrong alias,
stock identity for either embedded tree, or AOSP identity on retained
`system_dlkm`, `vendor`, or `vendor_dlkm` is a validation failure. The report
records the separate partitions' mapper sources and COW presence, and records
any unmounted logical mapper that still exists for an embedded tree without
mistaking it for the source of the live files.

The complete cubs build uses dm-verity targets layered over the six logical
partition mappings. Device-mapper minor numbers are runtime allocation details,
not stable partition identities, so the validator resolves both the logical
mapper and the corresponding `*-verity` mapper instead of assuming fixed
`dm-N` values. On the recorded corrected boot, the logical mappings happened to
be `dm-0` through `dm-5`, while the live read-only mounts used the enforcing
verity mappings `dm-12` through `dm-17`. In `cubs` mode, a mount must resolve to
its named verity mapper; merely finding the underlying logical mapper is not
sufficient. This check is what distinguishes the successful production-AVB
boot from the earlier verification-disabled diagnostic probe.

## Root and boot-control limits

The validator does not run `adb root`: that command restarts `adbd` and would
violate the read-only contract. With an ordinary shell session, it validates
the configuration that makes a userdebug adbd root-capable (`userdebug` plus
`ro.debuggable=1`) without exercising the transition. If adbd was already root
before invocation, as in the recorded GSI audit, the script additionally
queries slot-A bootable and successful flags through `bootctl`; it does not
modify them. Because authentication is disabled and root can be enabled without
an RSA trust decision, this development boot must be treated as exposed to any
connected USB host.

Unprivileged Android does not expose a reliable virtual A/B merge-state API on
this stock baseline. Runtime virtual-A/B properties and COW mappings are
recorded, and the report warns when the authoritative status is inaccessible.
The fastboot preflight remains responsible for confirming
`snapshot-update-status=none`.

## VINTF and hardware checks

When an on-device `checkvintf` binary is executable, the script runs
`checkvintf --check-compat`; only a successful execution is reported as a
VINTF compatibility pass. The cubs stock baseline does not ship that command,
so the script verifies the required manifest/matrix inputs and looks for the
exact failures emitted by `Build.isBuildConsistent()` in Android's system log.
A matching error is a failure. No matching error is only
`vintf_compatibility=inconclusive` and a warning: log retention is finite, and
absence of a message cannot prove compatibility.

Resolve an inconclusive result with an authoritative VINTF check from the
built target or VTS before calling the image release-qualified. The runtime
script's clean boot and HAL registration checks remain useful evidence, but
are not substitutes for that result.

The remaining smoke audit is intentionally non-invasive. It checks registered
binder and AIDL services for display, audio, camera, sensors, Wi-Fi, Bluetooth,
GNSS, NFC, radio, biometrics, graphics, and health; matching package-manager
features; core daemon liveness; physical display information; battery status;
kernel architecture and 4 KiB page size; `/data` capacity; and the read-only
dynamic-partition mounts. It does not turn radios on, open the camera, place a
call, play audio, or collect subscriber/device identifiers.

Running either mode against an untouched stock `user` build is a safe negative
control: the command performs no device writes and fails clearly on the
userdebug, debuggable, AOSP identity, and security-patch gates.
