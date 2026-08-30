# Pixel 10 (`frankel`) validation record

This serial-free record identifies the source-built Android 17 Frankel bundle
qualified on 2026-08-30. The hardened bundle completed two real-device boots,
passed the dedicated runtime gate twice, and completed the hardware smoke
checks recorded below. This is positive boot and integration evidence with
explicit functional limits, not a claim that every phone feature was tested.
The exact tested `userdebug` system remains booted on slot A with enforcing
SELinux and verity.

## Candidate status

| Item | State |
| --- | --- |
| Public AOSP source | `android-17.0.0_r1` (`CP2A.260605.016`, framework SPL `2026-06-05`) |
| Stock donor | `CP2A.260805.005` (vendor/firmware donor SPL `2026-08-05`) |
| Product | `frankel-aosp_current-userdebug` |
| Source build | Completed |
| Complete guarded bundle | Qualified exact bundle remains at the ignored local path `artifacts/frankel/device/` |
| Preliminary hardware bring-up | Booted Android twice; exposed eUICC and Pixel Modem Service startup crashes |
| Hardened compatibility build | Wi-Fi Aware/RTT feature declarations and direct eUICC flags provider built, packaged, and flashed |
| Final first boot | Completed in 20 seconds; runtime gate `PASS` with 66 passes and zero failures |
| Final second boot | Normal slot-A reboot completed in 29 seconds; runtime gate `PASS` with 66 passes and zero failures |
| Final qualification statement | Repeated-boot and runtime qualified with the functional limits below |

The preliminary candidate is diagnostic history, not final success evidence.
Its two repeatable failures were:

- `com.google.euiccpixel` could not find the Gservices flags authority during
  `OtaApplication` startup on pristine AOSP; and
- `com.google.android.modem.pms` received a null `WifiAwareManager` because the
  generated product requested a feature-prebuilt module that AOSP 17 did not
  define or install.

The corrected source keeps the proprietary eUICC package and its firmware
maintenance path, supplies a narrow read-only provider for its six extracted
flags, and defines all eight missing feature producers under Frankel-scoped
module names rather than only patching the observed Aware symptom. Explicit
filenames keep their installed XML paths and bytes unchanged. See the
[build and flash runbook](frankel-build-and-flash.md) for the security and
coexistence limits of the direct provider.

## Qualified artifact identities

These hashes identify the exact local bundle flashed for qualification. The
bundled `BUILD_ATTESTATION.txt` is byte-identical to
`work/aosp/out_pixel/frankel/build-completion-frankel.attestation`. Keep the
images and full logs under ignored local paths; commit only sanitized names,
hashes, counts, and conclusions.

| Evidence | Final value |
| --- | --- |
| Target-files archive filename | `frankel-target_files.zip` |
| Target-files archive SHA-256 | `6302fa398749268a96a6608ad2dd641785637104f696ef47481fd6adcdd22f4e` |
| `frankel-generated-vendor.attestation` SHA-256 | `337d4b5fcc68cda06d25ba9da970984c6cd84f2bf508af98fed05fcdb90f762c` |
| Build-completion / bundled `BUILD_ATTESTATION.txt` SHA-256 | `c7839e350062a90b17e69ee08b39caaa45259f650f1c37ec09b939c0c80bd14f` |
| Bundle `BUNDLE_INFO.txt` SHA-256 | `6986cc618abfd1782b96d7fa56290e5053a263a8e64b26702a9e4c3d405693e6` |
| Bundle `SHA256SUMS` SHA-256 | `22369a74043465d39c23c5b78c12ac155c71206762acdeb81c114943dca0ecf6` |
| Bundle `flash-all.sh` SHA-256 | `00ba05427d11ad653fafae7ee65dc069ab8a83128143159f08d0815d7687c4f4` |
| Bundle image count | `36`: 23 donor firmware, seven physical OS, and six logical images |
| Bundle manifest/directory count | `SHA256SUMS` covers exactly 42 entries; the directory contains those entries plus the manifest, 43 files total |
| First-boot runtime report | `runtime-validation-frankel-20260830T060425Z-3089003.txt` |
| First-boot runtime report SHA-256 | `7ea92a1fa173b2897287c02d75d133adaa48eb5efbc51f766b0b762583ca00e8` |
| First-boot result | `PASS`: 66 passes, zero failures |
| Second-boot runtime report | `runtime-validation-frankel-20260830T061130Z-3094835.txt` |
| Second-boot runtime report SHA-256 | `2191ed1dc015b30f3be595c5c802b5930641911d311dcd42f72d4ffc92e906aa` |
| Second-boot result | `PASS`: 66 passes, zero failures |

The runtime report identifies the observed product, build, and partitions; the
adjacent record above supplies the bundle hashes. The Frankel path does not yet
implement the Cubs recovery anchor's cryptographic transaction binding.
Describe it as identity-bound runtime evidence, not proof of a unique flash
transaction.

## Accepted recovery exception

Physical slot B on the current development phone was already unbootable when
final qualification began. The operator explicitly accepted proceeding
without an on-device B-slot lifeboat and retains an external stock-recovery
path. The guarded runner continues to target only A and preserve every B
partition, but preservation does not repair or qualify B. Record this exception
with the final result and do not generalize it to another phone.

If the A-side candidate boot-hangs or loses both fastboot and ADB access, stop
qualification and use the operator's external recovery procedure. Do not claim
that the repository's currently Cubs-only recovery-anchor/restore workflow
protects Frankel.

## Completed real-hardware gate

The hardened bundle's guarded `flash-all.sh` wrote all 36 reviewed images,
completed the userdata/metadata wipe, selected A, and rebooted successfully.
It used the required bootloader/baseband, exact A-only partition inventory, and
packaged root `vbmeta`. No verification-disable option was used. Both runtime
reports confirmed:

- first and second boots reached `sys.boot_completed=1` on slot A as Android 17
  SDK 37 `userdebug`, with the expected build ID and June framework/vendor
  property SPL;
- SELinux and dm-verity were enforcing, and all six logical partitions were
  read-only verified mappings;
- Wi-Fi Aware and Wi-Fi RTT features were declared and their framework services
  existed;
- `PixelAospGservicesFlagsProvider` was installed at the expected `system_ext`
  path with the exact authority and permission, and the eUICC package had its
  privileged read permission;
- the inspected crash and main/system buffers contained no startup crash or
  provider-permission failure from `com.google.euiccpixel`, `com.google.android.modem.pms`,
  `com.google.android.euicc`, or `com.google.android.apps.camera.services`;
- no verification bypass was active.

Delayed checks after both boots found an empty crash buffer, zero counts for
each of the four named crash processes, zero provider rejections, and zero
tombstones. The eUICC and Pixel Modem Service processes were running. After
second-boot cleanup, the media-provider row count was also zero.

## Functional smoke observations

All observations below were made on the exact checksum-identified hardened
bundle. Identifiers and media filenames were not retained.

| Area | Recorded result | Qualification limit |
| --- | --- | --- |
| Rear camera | Camera ID 0 produced a 3000x4000 JPEG, 966,010 bytes, with valid JPEG magic | Focus, video, every lens, image quality, and endurance were not tested |
| Front camera | Camera ID 1 produced a 2448x3440 JPEG, 515,678 bytes, with valid JPEG magic | Focus, video, image quality, and endurance were not tested |
| Camera stability | No camera-process crash was present after either capture | Long-duration and repeated-switch testing were not performed |
| Wi-Fi | Enabled and returned 36 sanitized scan rows | Association, DHCP, traffic, roaming, and sleep/wake were not tested |
| Bluetooth | Adapter reached `STATE_ON` | Discovery, pairing, reconnection, and audio/data transport were not tested |
| Audio | `com.android.music` AudioPreview produced an active AudioFlinger track that advanced through 220,500 frames with no fatal rows | No human audibility, channel-quality, microphone, or alternate-route confirmation |
| Vibration | Vibrator ID 0 accepted a forced 500 ms operation | No human tactile confirmation |
| Storage | Create, rename, and delete sequence passed | Removable media and sustained I/O were not tested |
| Sensors | Sensor service exposed 40 hardware sensors | Individual sensor response, calibration, and rotation were not fully tested |
| Display and touch | Display reported 1080x2424 at density 420; `focal_ts` exposed multi-touch input | No human touch-edge, gesture, or multi-touch confirmation |
| NFC and fingerprint | NFC was found and fingerprint services were present | No end-to-end NFC transaction or biometric enrollment/authentication |
| Modem and telephony | Phone service and baseband were present | Both SIM states were `NOT_READY`; registration, calls, SMS, and data remain unqualified |
| UWB | No UWB service was exposed | UWB is unavailable or unqualified on this build |

The temporary camera media was removed; the sanitized record retains no media
filename or content.

## Final sanitized result

```text
qualification_date_utc=2026-08-30
final_result=PASS_HARDENED_BUNDLE_BOOT_AND_RUNTIME_WITH_FUNCTIONAL_LIMITS
first_boot_seconds=20
second_boot_seconds=29
verified_boot_and_verity=SELINUX_ENFORCING_VERITY_ENFORCING_NO_BYPASS
runtime_gate_first=PASS_PASSES_66_FAILURES_0
runtime_gate_second=PASS_PASSES_66_FAILURES_0
known_package_crashes=0
gservices_provider_rejections=0
tombstones=0
delayed_checks_after_both_boots=PASS
media_rows_after_cleanup=0
flash_result=ALL_36_WRITES_WIPE_SLOT_A_REBOOT_SUCCEEDED
hardware_smoke_summary=CAMERAS_WIFI_SCAN_BLUETOOTH_AUDIO_VIBRATION_STORAGE_SENSORS_DISPLAY_TOUCH_NFC_FINGERPRINT_SERVICES_MODEM_PRESENT
unqualified_or_unavailable_functions=SIM_REGISTRATION_CALLS_SMS_DATA_UWB_AND_LISTED_END_TO_END_TESTS
slot_b_exception=ACCEPTED_NO_LIFEBOAT
tested_system_left_installed=YES_SLOT_A
tested_system_left_booted=YES_SLOT_A_USERDEBUG_ENFORCING
```

Never add a USB serial, ADB transport ID, Wi-Fi SSID/BSSID, Bluetooth address,
SIM or subscriber identifier, camera media, account data, or other device-
unique value to this file. The proprietary bundle, extracted blobs, build
outputs, and raw runtime logs remain local/ignored and are not redistributable
source artifacts.
