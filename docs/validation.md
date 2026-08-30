# Validation log

> **Scope:** This legacy guide documents the Pixel 11 (`cubs`) workflow only; see the [multi-target layout](multi-target-layout.md) for current target organization.

## Status

The raw AOSP 17 GSI probe has completed its controlled slot-A flash, first boot,
runtime audit, and second boot. It is not release-qualified: both runtime runs
reported `PASS_WITH_WARNINGS`, VINTF compatibility remained inconclusive, the
manual acceptance matrix was not completed, and the camera path failed to open
a usable device.

The first complete cubs bundle failed to boot with its packaged AVB topology;
a diagnostic verification-disabled probe identified adevtool's collapsed
`fstab.malibu` child mappings as the cause. The corrected output restores the
named `boot`, `init_boot`, `vbmeta_system`, and `vbmeta_vendor` dependencies in
both fstab copies and binds them to the root AVB chain.

That corrected bundle has now completed repeated real boots. All six logical-A
and 34 physical-A images were flashed, including the packaged
`vbmeta_system_a`, `vbmeta_vendor_a`, and root `vbmeta_a`; no
verification-disable flags or replacement vbmeta image were used. Android 17
reached `sys.boot_completed=1` on slot A in about 16 seconds with
`ro.boot.veritymode=enforcing`. The bundle-bound audit reported
`PASS_WITH_WARNINGS` with 127 passes, zero failures, and five warnings, and its
runtime attestation was published. A second normal slot-A boot completed in 38
seconds and repeated the same 127-pass, zero-failure, five-warning audit. The
exact transaction finalizer then succeeded and atomically archived the active
lineage, recovery handoff, transaction, runtime proof, and retirement record. A
final post-finalization boot completed in 20 seconds with the same fingerprint
and enforcing verity. This is positive corrected-image boot evidence, but not
full qualification: VINTF remains inconclusive and the manual matrix is
partial.

## Recorded artifacts

These hashes identify the ignored local bundles and reports used for this
bring-up. Recompute and update them after any rebuild or repackaging.

| Evidence | SHA-256 |
| --- | --- |
| GSI bundle `SHA256SUMS` | `948419ad510d417cee78151058ffe41bceb8baf9d5f364bc57b0e5e5815cfb53` |
| GSI `BUILD_ATTESTATION.txt` | `34d4b579f03363de1be6560ab7de3157009dbf6bd8cb492a8ba958cafe120d62` |
| Diagnostic pre-fix cubs bundle `SHA256SUMS` at flash time | `35b2d47efefdc54e164ec44aaf97ed11c2dc828f2274f80dec61d836a7761499` |
| Diagnostic pre-fix cubs `BUILD_ATTESTATION.txt` | `e807b535c3fa771891dfff1b0f674202d277d5279012273d1705e12d831898e7` |
| Corrected cubs build-completion attestation | `1676ed35d049dab56976eb12dd1e0858a7aa56b1aba0b343d023b68ea8fda080` |
| Corrected cubs target-files package | `a3ef8f2f5ab19cc9aab6758f859a6184842298478cfb482248dc7379fe17771c` |
| Corrected cubs bundle `SHA256SUMS` | `832f50115b07cedbee902daefc82fb75c151874395e524aad0dfee540b458e23` |
| Attested GSI runtime report | `97631553088798e67b7887119d91ffbebb989e19b23627838d3058159513d226` |
| Second-boot GSI runtime report | `96c06c33dbb51af4c73b2931e1bc6d551c64357da4f224cba4bced9c931baedc` |
| Diagnostic pre-fix cubs runtime report | `6d25900bb5e9c2415c16bff3851b80639f45987d43ff7a7a5cfbf53d7524841a` |
| Corrected cubs attested first-boot runtime report | `14a5a517a77cbfa68e148813faf84a6dafe51579117c2ddd0e071fc942da7a5c` |
| Corrected cubs runtime-boot attestation | `5bc6efc20ab29bc4316e35a037a35d84e1aa292201bad00b867d47d23aac87c1` |

The attested report is
`runtime-validation-gsi-20260829T072539Z-2048706.txt`: 128 passes, zero
failures, and four warnings. The second-boot report is
`runtime-validation-gsi-20260829T072642Z-2050253.txt`: 125 passes, zero
failures, and five warnings. Logs remain private ignored state; their filenames
and hashes are recorded here without a device identifier.

The diagnostic cubs report is
`runtime-validation-cubs-20260829T155839Z-2215721.txt`: 120 passes, zero
failures, and five warnings. It is deliberately not described as a
bundle-bound runtime attestation because the boot used a verification-disabled
root `vbmeta` that was not the image in the checksum-identified bundle.

The corrected, bundle-bound report used for runtime publication is
`runtime-validation-cubs-20260829T182257Z-3677013.txt`: 127 passes, zero
failures, and five warnings. It was collected from the packaged corrected
images with dm-verity enforcing and no AVB bypass.

The corrected second-boot report is
`runtime-validation-cubs-20260829T183044Z-3681111.txt`: 127 passes, zero
failures, and five warnings. It retained slot A and the same build and
partition identities.

## Completed build and safety gates

- The attached device was identified as `cubs` with an unlocked bootloader.
- Exact stock slot A booted Android 17 build `CD1A.260714.001.A9`; ADB
  authorization and USB re-enumeration were verified under WSL2.
- Factory and full OTA downloads passed their pinned SHA-256 checks, and the
  device bootloader/baseband matched the factory requirements.
- No virtual A/B snapshot merge was active before the development write, and
  matching factory restore inputs remained available locally.
- The `android-17.0.0_r1` source manifest resolved without sync errors.
- `gsi_arm64-aosp_current-userdebug` built and packaged successfully.
- The generated cubs vendor module passed adevtool's pinned reference spec and
  the reviewed sanitizer/attestation gates.
- The pre-fix cubs userdebug target-files package and complete factory-style
  bundle built and passed the then-current static image validation. Its later
  hardware failure exposed the missing fstab-to-chain semantic gate.
- The corrected cubs target-files and build-completion attestation now require
  both generated and packaged fstabs to be byte-identical, use the exact child
  mappings, and match the root AVB chain descriptors. Standalone AVB and
  target-files VINTF checks pass. The packaged images subsequently completed
  two audited boots with those mappings and enforcing dm-verity, followed by a
  successful post-finalization boot.
- Host simulations exercised wrong-product, firmware, bootloader-lock, battery,
  multiple-device, checksum, recovery-handoff, journal-resume, and restore
  rejection paths without contacting a real device.

## Raw GSI device result

The checksum-identified GSI bundle was flashed to literal slot-A targets while
the physical-B fastbootd lifeboat was retained. Android 17 / SDK 37 reached
`sys.boot_completed=1` on slot A with enforcing SELinux, `userdebug`, test keys,
and the expected unlocked/orange verified-boot state. The recorded partition
split was:

- AOSP `CP2A.260605.016` `system`, embedded `product`, and embedded
  `system_ext`, all on the read-only ext4 GSI root;
- stock `CD1A.260714.001.A9` `system_dlkm`, `vendor`, and `vendor_dlkm` on
  their retained read-only EROFS mappings.

The attested runtime audit reported 128 passes, no hard failures, and four
warnings: unauthenticated development ADB, no unprivileged runtime snapshot
status, no on-device `checkvintf`, and therefore inconclusive VINTF
compatibility. A second normal boot reached Android in about 10 seconds and its
fresh audit reported 125 passes, no hard failures, and five warnings; the extra
warning was the expected loss of root-only boot-control evidence in the
non-root shell. Neither result is an unqualified pass.

Limited functional smoke observations were also recorded without identifiers:

- Wi-Fi enabled and scanned, with results present, then was returned to its
  original disabled state. Association, DHCP, traffic, and sleep/wake were not
  tested.
- Bluetooth enabled and disabled without a framework crash. Pairing and a data
  or audio path were not tested.
- A temporary shared-storage file passed create/hash/rename/delete checks and
  was removed. UI and camera-media persistence were not tested.
- Sensor service showed recent accelerometer, ambient-light, and proximity
  events. The full sensor/rotation procedure was not run.
- Camera2 launched and resumed without a Java crash, but camera devices closed
  instead of providing a usable preview. Repeated SELinux diagnostics showed
  `hal_camera_default` unable to find
  `com.google.pixel.camera.services.binder.IServiceBinder/default`. This is a
  raw-GSI camera failure, not proof that the untested complete cubs build fixes
  it.

See [`functional-validation.md`](functional-validation.md) for the exact
qualification boundary.

## Diagnostic complete-cubs device result

The pre-fix complete cubs bundle was written to slot A through the reviewed
flash workflow, but its packaged AVB configuration did not reach Android. A
diagnostic retry reached `sys.boot_completed=1` only after flashing root
`vbmeta` with verification disabled. Although Android reported the ordinary
`orange` state expected on an unlocked development device, that property does
not show that verification was enforced; the diagnostic flags are conclusive
that this was not a verified bundle boot.

The read-only runtime report recorded `PASS_WITH_WARNINGS`, 120 passes, zero
hard failures, and five warnings: unauthenticated development ADB, unavailable
unprivileged snapshot and boot-control evidence, no on-device `checkvintf`, and
therefore inconclusive VINTF compatibility. These automated results show that
the diagnostic system reached a stable, auditable Android userspace. They do
not override the AVB bypass or qualify the image for release.

Camera2 opened both exposed camera devices during the diagnostic boot. No
recorded observation establishes a stable visual preview, focus, still image,
video capture, saved-media integrity, or camera switching, so neither camera
receives functional acceptance from this probe. Most of the remaining manual
hardware matrix and a second boot were also not completed.

The root cause was the pre-fix generated fstab topology. Adevtool mapped every
named `avb=` dependency to root `vbmeta`, while the reconstructed stock-shaped
root image chained `boot`, `init_boot`, `vbmeta_system`, and `vbmeta_vendor` as
children. The corrected sanitizer restores those child names after immutable
FileTreeSpec verification, and static validation now compares both fstab copies
with the root chain records. The later corrected first boot is independent
evidence that this correction works on hardware; the diagnostic probe remains
historical evidence only.

## Corrected complete-cubs device result

The corrected checksum-identified bundle booted on the real device with its
packaged production AVB topology, development test keys, and no
verification-disable bypass. It reported the expected `cubs` Android 17 / SDK
37 `userdebug` identity, slot `_a`, unlocked/orange verified-boot state,
enforcing SELinux, and `ro.boot.veritymode=enforcing`. All six audited dynamic
partitions were mounted read-only through their `*-verity` device-mapper
targets. The runtime validator recorded 127 passes, no hard failures, and five
warnings: unauthenticated development ADB, unavailable unprivileged snapshot
and boot-control evidence, no on-device `checkvintf`, and consequently
inconclusive VINTF compatibility.

The following sanitized hardware observations were made on that same first
boot:

- Camera2 opened rear camera ID 0 and front camera ID 1. Each captured a real,
  nonempty JPEG with the expected JPEG signature; the files were readable from
  shared storage. Focus, video, every rear focal length, and long-duration
  stability remain unqualified.
- Wi-Fi enabled and returned 29 scan rows without publishing network
  identifiers. Association, DHCP, traffic, and sleep/wake were not exercised.
- Bluetooth enabled. Discovery, pairing, reconnection, and an audio/data path
  were not exercised.
- The packaged audio-preview activity played a known alarm at a controlled
  media volume. AudioFlinger reported a non-standby active output with frames
  advancing and no write errors. No human audibility, channel-quality,
  Bluetooth/USB route, or microphone result was recorded.
- The vibrator HAL exposed device 0 and accepted a forced 500 ms one-shot with
  a successful command result. A human tactile confirmation was not recorded.
- Sensor service was present with 46 enumerated entries. Display output was
  awake at 1080x2424 with density 420, and touch input was registered. Full
  rotation, gesture, edge-touch, multi-touch, and sensor-response procedures
  remain incomplete.
- NFC and fingerprint services were present. No end-to-end NFC or biometric
  operation was attempted. No UWB binder service was found.
- Modem and baseband evidence was present, but both SIM states were `NOT_READY`
  and cellular service was emergency/out-of-service. Calls, SMS, and mobile
  data therefore remain unqualified.

The second normal boot completed in 38 seconds on slot A. Its fresh report,
`runtime-validation-cubs-20260829T183044Z-3681111.txt`, again recorded
`PASS_WITH_WARNINGS` with 127 passes, zero failures, and five warnings. The
exact transaction finalizer then completed successfully and atomically archived
the active recovery lineage, claimed handoff, transaction, runtime proof, and
retirement record. A final normal boot after finalization reached Android in 20
seconds with fingerprint
`google/cubs/cubs:17/CD1A.260714.001.A9/pixel_aosp17_r1:userdebug/test-keys`
and enforcing verity. No active transaction or recovery proof remains to be
finalized.

## Required before complete cubs qualification

- Resolve any runtime VINTF warning with the already attested target-files check
  or another authoritative built-target/VTS result; absence of a boot-log error
  is not compatibility evidence.
- Complete every applicable complete-cubs row in
  [`functional-validation.md`](functional-validation.md), including audio,
  radio, storage, and the remaining camera coverage.
