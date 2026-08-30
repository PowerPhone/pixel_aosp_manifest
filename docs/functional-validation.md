# Functional validation

> **Scope:** This legacy guide documents the Pixel 11 (`cubs`) workflow only; see the [multi-target layout](multi-target-layout.md) for current target organization.

This is the manual acceptance record for development images flashed to `cubs`.
Each exact GSI or complete-cubs candidate receives its own immutable record. It
complements, but is not replaced by, the read-only checks in
[`runtime-validation.md`](runtime-validation.md). A registered service proves
that a binder endpoint exists; it does not prove that the display, modem,
camera, speaker, or sensor works.

A row is **PENDING** for a particular candidate until a person performs it on
that exact packaged build. Do not publish device serials, Wi-Fi SSIDs or BSSIDs,
Bluetooth addresses, phone numbers, subscriber identifiers, account names,
filenames, or location data. Record bundle/report hashes and generic outcomes
instead.

## Test record

Fill this block for each candidate without adding personal identifiers:

```text
date_utc=PENDING
tester=PENDING
mode=gsi|cubs
bundle_sha256s_sha256=PENDING
bundle_build_attestation_sha256=PENDING
runtime_report_filename=PENDING
runtime_report_sha256=PENDING
runtime_result=PASS|PASS_WITH_WARNINGS|FAIL|PENDING
vintf_result=pass|fail|inconclusive
first_boot_minutes=PENDING
second_boot_minutes=PENDING
overall=PASS|FAIL|PENDING
```

Use `PASS`, `FAIL`, `PARTIAL`, `NOT RUN`, or `NOT APPLICABLE` for each result.
`PARTIAL` records useful evidence that did not exercise the complete procedure.
A required `PARTIAL`, `NOT RUN`, `NOT APPLICABLE`, or `inconclusive` result does
not qualify the image for release. Put identifying or verbose failure details
in a local, ignored log and keep this document free of identifiers.

## Recorded raw-GSI probe

```text
date_utc=2026-08-29
tester=local-bring-up-operator
mode=gsi
bundle_sha256s_sha256=948419ad510d417cee78151058ffe41bceb8baf9d5f364bc57b0e5e5815cfb53
bundle_build_attestation_sha256=34d4b579f03363de1be6560ab7de3157009dbf6bd8cb492a8ba958cafe120d62
runtime_report_filename=runtime-validation-gsi-20260829T072539Z-2048706.txt
runtime_report_sha256=97631553088798e67b7887119d91ffbebb989e19b23627838d3058159513d226
runtime_result=PASS_WITH_WARNINGS
vintf_result=inconclusive
first_boot_minutes=less-than-1 (approximately 20 seconds)
second_boot_minutes=less-than-1 (approximately 10 seconds)
overall=FAIL
```

The `overall=FAIL` result is an acceptance result, not a boot result: Android
booted twice, but VINTF remained inconclusive, most full manual procedures were
not run, and the camera stack did not provide a usable device. The second-boot
runtime report was
`runtime-validation-gsi-20260829T072642Z-2050253.txt`, SHA-256
`96c06c33dbb51af4c73b2931e1bc6d551c64357da4f224cba4bced9c931baedc`,
with 125 passes, zero failures, and five warnings.

| Area | Sanitized observation | Result |
| --- | --- | --- |
| Display and touch | Android reached an interactive UI and Camera2 reached the resumed state. Brightness, full touch coverage, rotation, and multi-touch were not exercised. | PARTIAL |
| Wi-Fi | Wi-Fi enabled and a scan returned results; it was restored to disabled. Association, DHCP, traffic, and sleep/wake were not exercised. | PARTIAL |
| Bluetooth | The adapter enabled and disabled without a framework crash. Discovery, pairing, reconnection, and a data/audio path were not exercised. | PARTIAL |
| Rear camera | Camera2 launched, but camera devices closed instead of reaching a usable preview. `hal_camera_default` repeatedly could not find `com.google.pixel.camera.services.binder.IServiceBinder/default`. | FAIL |
| Front camera | No independent front-camera procedure was possible after the camera-stack failure. | NOT RUN |
| Audio output | No speaker, Bluetooth-audio, or USB-audio playback procedure was run. | NOT RUN |
| Microphone | No recording/playback procedure was run. | NOT RUN |
| Sensors and rotation | Sensor service showed recent accelerometer, ambient-light, and proximity events. Rotation, gyroscope behavior, and the full manual procedure were not exercised. | PARTIAL |
| Cellular and radio | No SIM/eSIM registration, data, call, or SMS procedure was run. | NOT RUN |
| USB and ADB | The exact selected WSL-forwarded transport returned after boot and completed both runtime audits. A separate full disconnect/reconnect acceptance procedure was not recorded. | PARTIAL |
| Storage | A temporary shared-storage file passed create/hash/rename/delete checks and was removed. UI access and camera-media persistence were not exercised. | PARTIAL |
| Second boot | Slot A returned to Android in approximately 10 seconds with the same identities; the exact selected transport completed a fresh 125-pass, zero-failure runtime audit. | PASS |

The raw GSI deliberately lacks the extracted complete-cubs product and
system-ext payloads. The complete cubs output statically contains the matching
Pixel camera service context, app, framework JARs, permissions, and VINTF
fragment, but file presence is not evidence that the service or camera works.
Only a complete-cubs flash and manual camera procedure can establish that.

## Recorded diagnostic complete-cubs probe

```text
date_utc=2026-08-29
tester=local-bring-up-operator
mode=cubs
bundle_sha256s_sha256=35b2d47efefdc54e164ec44aaf97ed11c2dc828f2274f80dec61d836a7761499
bundle_build_attestation_sha256=e807b535c3fa771891dfff1b0f674202d277d5279012273d1705e12d831898e7
runtime_report_filename=runtime-validation-cubs-20260829T155839Z-2215721.txt
runtime_report_sha256=6d25900bb5e9c2415c16bff3851b80639f45987d43ff7a7a5cfbf53d7524841a
runtime_result=PASS_WITH_WARNINGS
vintf_result=inconclusive
first_boot_minutes=NOT RECORDED
second_boot_minutes=NOT RUN
overall=FAIL
```

`overall=FAIL` is the qualification result. The pre-fix bundle reached Android
only after its packaged root `vbmeta` was replaced with a diagnostic image that
disabled verification. Consequently, the 120-pass, zero-failure, five-warning
runtime audit is useful userspace evidence but is not a bundle-bound runtime
attestation, a verified boot, or release acceptance.

| Area | Sanitized observation | Result |
| --- | --- | --- |
| Display and touch | Android completed boot. The full brightness, rotation, edge-touch, and multi-touch procedure was not recorded. | PARTIAL |
| Camera devices | Camera2 opened both exposed camera devices, but the observation did not establish lens identity, stable visual preview, switching, focus, still capture, video, or saved-media integrity. | PARTIAL |
| USB and ADB | The explicitly selected WSL-forwarded ADB transport completed the 120-pass runtime audit. A separate disconnect/reconnect procedure was not recorded. | PARTIAL |
| Second boot | No second boot of this diagnostic configuration was accepted or recorded. | NOT RUN |

Unlisted manual areas were not run. The root cause was subsequently identified
as adevtool collapsing the fstab child-AVB names to root `vbmeta`. The corrected
build restores the child mappings and has since completed a separate,
bundle-bound real-device first boot. This diagnostic record does not satisfy
any row for that corrected candidate.

## Recorded corrected complete-cubs result

```text
date_utc=2026-08-29
tester=local-bring-up-operator
mode=cubs
bundle_sha256s_sha256=832f50115b07cedbee902daefc82fb75c151874395e524aad0dfee540b458e23
bundle_build_attestation_sha256=1676ed35d049dab56976eb12dd1e0858a7aa56b1aba0b343d023b68ea8fda080
runtime_report_filename=runtime-validation-cubs-20260829T182257Z-3677013.txt
runtime_report_sha256=14a5a517a77cbfa68e148813faf84a6dafe51579117c2ddd0e071fc942da7a5c
runtime_attestation_sha256=5bc6efc20ab29bc4316e35a037a35d84e1aa292201bad00b867d47d23aac87c1
runtime_result=PASS_WITH_WARNINGS
vintf_result=inconclusive
first_boot_minutes=less-than-1 (approximately 16 seconds)
second_boot_report_filename=runtime-validation-cubs-20260829T183044Z-3681111.txt
second_boot_result=PASS_WITH_WARNINGS (127 passes, 0 failures, 5 warnings)
second_boot_minutes=less-than-1 (approximately 38 seconds)
flash_transaction_finalization=PASS
post_finalization_boot_minutes=less-than-1 (approximately 20 seconds)
overall=FAIL
```

This is a boot of the corrected packaged images, not the earlier diagnostic
configuration. The production AVB topology was used with development test keys
and no verification-disable flags; Android reported enforcing dm-verity. The
127-pass, zero-failure, five-warning report is bound to the corrected bundle by
the published runtime attestation. The second boot reached the same slot-A
build in approximately 38 seconds and repeated the 127-pass, zero-failure,
five-warning audit. The exact transaction finalizer then archived the active
recovery and runtime proof, and a post-finalization boot returned in
approximately 20 seconds with the same fingerprint and enforcing verity.
`overall=FAIL` is the qualification result, not a boot failure: VINTF remains
inconclusive and required manual procedures are still incomplete.

| Area | Sanitized observation | Result |
| --- | --- | --- |
| Display and touch | The display was awake at 1080x2424 and density 420; Camera2 onboarding and capture UI rendered, and a touch input device was registered. Brightness, rotation, full edge coverage, gestures, and multi-touch were not completed. | PARTIAL |
| Wi-Fi | Wi-Fi enabled and a scan returned 29 rows without recording network identifiers. Association, DHCP, traffic, and sleep/wake were not exercised. | PARTIAL |
| Bluetooth | Bluetooth enabled and its framework/HAL services remained present. Discovery, pairing, reconnection, and a data/audio path were not exercised. | PARTIAL |
| Rear camera | Camera2 opened camera ID 0 and produced a readable, nonempty JPEG with the expected JPEG signature. Focus, video, every rear focal length, orientation review, and endurance were not completed. | PARTIAL |
| Front camera | Camera2 opened camera ID 1 and produced a readable, nonempty JPEG with the expected JPEG signature. Video, orientation review, switching endurance, and long-duration stability were not completed. | PARTIAL |
| Audio output | The packaged audio-preview activity played a known alarm at controlled media volume. AudioFlinger reported a non-standby active output with frames advancing and no write errors. Human audibility, channel quality, volume-range behavior, and Bluetooth/USB routes were not recorded. | PARTIAL |
| Vibration | Vibrator device 0 enumerated and a forced 500 ms one-shot returned success. A human tactile confirmation and patterned/endurance checks were not recorded. | PARTIAL |
| Microphone | Audio services were present, but no record/playback procedure had been completed. | NOT RUN |
| Sensors and rotation | Sensor service was present with 46 enumerated entries. Plausible changing values and four-orientation rotation were not exercised. | PARTIAL |
| Cellular and radio | Modem/baseband evidence was present, but both SIM states were `NOT_READY` and service was emergency/out-of-service. Registration, data, calls, and SMS were not qualified. | PARTIAL |
| NFC and fingerprint | Both services were present. No end-to-end NFC transaction or fingerprint enrollment/authentication was attempted. | PARTIAL |
| UWB | No UWB binder service was found; applicability and an end-to-end session were not established. | NOT RUN |
| USB and ADB | The explicitly selected WSL-forwarded ADB transport completed the bundle-bound first-boot runtime audit. A separate physical disconnect/reconnect procedure was not recorded. | PARTIAL |
| Storage | Both camera captures were saved as readable JPEG files in shared storage. General create/rename/delete and persistence-after-reboot procedures were not completed. | PARTIAL |
| Second boot | A normal restart reached the same slot-A build in approximately 38 seconds. The selected transport returned and the fresh validator report recorded 127 passes, zero failures, and five warnings. | PASS |
| Post-finalization boot | After the exact transaction finalizer archived the active recovery and runtime proof, Android returned in approximately 20 seconds with the same fingerprint and enforcing verity. | PASS |

## Complete cubs acceptance matrix

The result column below tracks the exact corrected bundle recorded above.
`PARTIAL` preserves useful real-device evidence without converting an
incomplete procedure into a pass. The verification-disabled diagnostic probe
does not contribute to these results.

| Area | Manual procedure | Pass criteria | Result |
| --- | --- | --- | --- |
| Display and touch | Complete setup or reach the launcher. Exercise minimum and maximum brightness, portrait and landscape, edge/corner touches, scrolling, long-press, and multi-touch in a test surface. | No blanking, flicker, corruption, stuck orientation, dead zones, ghost touches, or input latency that prevents normal use. | PARTIAL |
| Wi-Fi | With permission to use a test access point, enable Wi-Fi, connect, obtain an address, load an HTTPS page, let the screen sleep, wake it, and confirm traffic resumes. Forget the network afterward if policy requires it. | Association, DHCP, DNS/TLS traffic, sleep/wake reconnection, and disconnect all work without a framework crash. Do not record network names or addresses. | PARTIAL |
| Bluetooth | Enable Bluetooth and pair with a consented test headset or peripheral. Disconnect, reconnect, and verify media control or another device-appropriate data path. Remove the pairing afterward if required. | Discovery, pairing, encrypted reconnection, and the selected data/audio path work; Settings and Bluetooth services remain responsive. | PARTIAL |
| Rear camera | In a camera application, test preview, focus, still capture, and a short video on each exposed rear focal length. Review the outputs, then delete test media if required. | Preview is stable; controls respond; captured image/video is readable, correctly oriented, and free of severe corruption. | PARTIAL |
| Front camera | Switch to the front camera and repeat preview, still capture, and short video checks. | Camera switching, preview, capture, orientation, and saved output work without a camera-service restart. | PARTIAL |
| Audio output | Play a known local test sound through the built-in speaker at low and moderate volume. Exercise volume controls and, if available, a consented Bluetooth or USB audio route. | Output is audible on the chosen routes, volume changes work, and there is no severe clipping, channel loss, or service crash. | PARTIAL |
| Vibration | Trigger a short one-shot and representative notification/call patterns while holding the device. | Haptics are perceptible, stop on time, and do not wedge or crash the vibrator service. | PARTIAL |
| Microphone | Record a short spoken test clip with the built-in microphone and play it back. Delete the recording after review. | Recording completes and intelligible audio is present without persistent silence, gross distortion, or an audio-service crash. | NOT RUN |
| Sensors and rotation | Enable automatic rotation and rotate through all four orientations. Exercise a sensor-display application for accelerometer, gyroscope, proximity, and ambient-light changes without recording location. | Orientation follows the device; listed sensors produce plausible changing values; proximity and ambient-light behavior are responsive. | PARTIAL |
| Cellular and radio | Using an authorized test SIM/eSIM and carrier plan, confirm registration and signal state. Test mobile data; make a short consented test call and SMS only when cost and recipient authorization are understood. | Registration persists, data transfers, and every attempted authorized call/SMS succeeds with usable audio. Record no number, carrier account, cell ID, or location. | PARTIAL |
| USB and ADB | With USB debugging intentionally enabled, disconnect and reconnect the forwarded USB device. Confirm the host sees exactly the intended transport in `device` state and rerun the runtime validator with explicit or sole-device selection. The development GSI/cubs images intentionally disable ADB authentication; an RSA prompt is expected only after a stock restore or another mode change that reenables it. | USB re-enumerates, the exact selected transport provides shell access within the configured timeout, no unrelated device is selected, and the runtime report records the expected unauthenticated ADB mode. | PARTIAL |
| Storage | From the UI, create a small temporary file in user storage, open it, rename it, delete it, and confirm free-space reporting remains sane. Also confirm camera media survives reopening before cleanup. | Create/read/rename/delete and media persistence work without I/O errors, corruption, or a storage-service crash. | PARTIAL |
| Second boot | After all preceding checks and confirmation that the physical slot-B fastbootd lifeboat is still available (not Android B), explicitly approve a normal restart from the power menu. Time from restart to an interactive UI, restore USB forwarding and the selected ADB transport, and rerun the runtime validator. An RSA prompt is not expected for these unauthenticated development images. | The second boot reaches the UI within 5 minutes, remains on slot A with the same build identities, regains shell access on the exact selected transport, and repeats the automated checks with no new failure. | PASS |

## Stop conditions

Stop testing and return to the documented recovery path if the display never
becomes interactive, the second boot exceeds five minutes, repeated framework
or hardware-service crashes prevent a row from completing, userdata becomes
unreadable, slot identity changes unexpectedly, or ADB access cannot be
restored. Do not continue with additional flashes merely to turn a failed row
into a pass.

The second-boot step is deliberately manual. This repository does not automate
a reboot from the read-only validator, so reaching that state always requires
an operator decision after confirming the physical B fastbootd lifeboat.
