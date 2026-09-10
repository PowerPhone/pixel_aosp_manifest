# Frankel 192 kHz Android API path

This note defines the framework/API surface for Pixel 10 (`frankel`). The
microphone transport described here is live-hardware qualified at tinyALSA and
is no longer the retired AP-PDM/card-1 experiment. Native-q192 speaker
transport now runs at nominal wall time on both physical amplifiers. That
transport result does not by itself establish ultrasonic acoustic bandwidth.

## Configuration ownership

Frankel's extracted service owns the normal primary module:

```text
/vendor/bin/hw/android.hardware.audio.service-aidl.aoc
android.hardware.audio.core.IModule/default
```

It does not use the example default implementation in
`hardware/interfaces/audio/aidl/default`. PowerPhone therefore adds the
independent `IModule/powerphone` instance and never replaces the primary HAL,
AudioFlinger, AudioPolicyManager, effects, Bluetooth, or telephony modules.
All research routes are explicitly addressed `TYPE_BUS` ports so ordinary
media, call, ring, and record strategies cannot select them.

Every address is at most 31 characters. AudioFlinger converts the AIDL
`AudioDevice` into the legacy fixed `AUDIO_DEVICE_MAX_ADDRESS_LEN=32` buffer,
including its terminating NUL; an overlength address makes conversion return
`BAD_VALUE` and causes AudioPolicy to discard the complete module even when
its binder service is registered and running.

## Qualified microphone path

Live qualification established one usable high-rate AoC path:

```text
card 0, PCM device 10 capture (EP3)
mono S16_LE, 192000 Hz
period_size=1920, periods=4, buffer_size=7680
```

The Android-facing framework/FMQ queue is independently 1,920 frames (10 ms).
The HAL opens D10 with the full qualified 1,920-by-four ALSA ring rather than
using the framework queue size as the ALSA buffer size.

The F1 producer remains a 96-frame planar block every 0.5 ms. The reviewed
boot-volatile mutation admits the 6.4 MHz/192 kHz profile and expands only the
D10 RAW staging/conversion geometry needed to publish those blocks. The
strict idle mixer profile is:

```text
BUILDIN MIC ID CAPTURE LIST = one of:
  0 -1 -1 -1
  1 -1 -1 -1
  2 -1 -1 -1
BUILTIN MIC Process Mode = Raw
Audio Capture Mic Source = Builtin_MIC
Mic Spatial Module Enable = 0
MIC DC Blocker = 0
MIC Record Soft Gain (dB) = 0
HD Mic gain (cB) = 0
INTERNAL_MIC_TX Sample Rate = SR_192K
INTERNAL_MIC_TX Format = S16_LE
INTERNAL_MIC_TX Chan = One
```

The sidecar exposes exactly three logical selections:

| Android input bus | ALSA profile | Selected logical mic |
| --- | --- | --- |
| `POWERPHONE_C0_D10_MIC0` | PCM0,D10 mono S16/192000 | `0 -1 -1 -1` |
| `POWERPHONE_C0_D10_MIC1` | PCM0,D10 mono S16/192000 | `1 -1 -1 -1` |
| `POWERPHONE_C0_D10_MIC2` | PCM0,D10 mono S16/192000 | `2 -1 -1 -1` |

Only one D10 stream may be active. Stream start requires boot-local readiness,
all D8/D9/D10/D12 shared routes idle, and all microphone power controls off.
The HAL then owns `EP3 TX Mixer INTERNAL_MIC_TX`, verifies its complete mixer
state before every transfer, and accepts the PCM only with 1920-by-four
geometry. PCM close precedes hard-off cleanup. D8, D9, D12, Capture Injection,
Bluetooth, and virtual endpoints are not advertised by this module.

The addresses describe internal logical microphone selectors, not enclosure
holes. Bottom/top/camera-hole mapping still requires controlled acoustic
identification.

## Speaker status

The two Frankel codecs are CS35L43 devices. The reviewed stock driver
explicitly includes 192000 in `cs35l43_fs_rates` and
`cs35l43_src_rates`, and its DAI uses that constrained rate list. The codec
driver is therefore not the present 192 kHz limitation.

The proprietary primary HAL still hard-codes built-in primary/deep/raw/MMAP
use cases to 48000 Hz. The additive research HAL instead owns PCM0,D0 stereo
S32 at 192 kHz. The qualified physical transport uses
`experimental-enum7-q192-tdm12288-192-2xs32-dma-source0`: native 192-frame
AoC jobs, two S32 slots at 12.288 MHz, and a 1,920-by-two ALSA buffer whose
15,360-byte periods match the observed D0 physical ring. Its boot helper must
install that guarded profile after stock firmware authentication.
Only one amplifier is exposed at a time; simultaneous earpiece+R amplification
watchdogs FF1 and is rejected.
PowerPhone output starts remain fail-closed behind:

```text
vendor.powerphone.aoc_speaker_192k.ready
```

The helper raises this property only after exact A32 allocator/assertion,
work-pool, OUTPUTTER timer, native-q192 geometry, guarded F1 writes,
whole-F1 I-cache synchronization, and final readback. This
certifies boot-local route and
transport configuration, not acoustic bandwidth; Nyquist-domain physical
measurement is still required.

The native-q192 transport passed the stricter wall-time gate on 2026-09-04.
The final kernel/geometry pair completed a ten-second physical-speaker stream
and concurrent D10 transport at native cadence. The exact kernel is the
one-period-lag profile SHA-256
`37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6`.
An independently calibrated Nyquist-domain acoustic measurement remains
required before claiming usable 96 kHz acoustic bandwidth.

The HAL requires its playback worker to enter `SCHED_FIFO/90`, then defers both
EP1 binding and PCM open until the first complete nonzero client burst is
already in hand. A failed RT promotion rejects start before the route is
touched. Immediately before the final EP1 activation it temporarily sets the
card-wide `PCM Stream Wait Time in MSec` control to 200; D0 copies that value
during `hw_params`, and the prior card value is restored as soon as `pcm_open`
returns. This matches stable direct-hardware behavior; omitting that value can
fail on the first ring, and an otherwise-identical `SCHED_OTHER` run recovered
an EPIPE. It uses
an isolated legacy-tinyALSA-v1 facade and submits 1,920-frame periods with an
explicit 1,920-frame start threshold. Each write is exactly one 15,360-byte D0
physical-ring quantum; capture and mixer
access remain on tinyalsa-v2. Playback does not issue
the generic `SYNC_PTR` position refinement between framework commands because
that control transaction made the following D0 `WRITEI` fail. Every observed
xrun or nonzero legacy write status fails the client stream closed.

The earpiece and bottom BUS sinks use distinct, otherwise-identical normal mix
ports. AudioPolicy performs a separate startup reachability open for each
address-distinguished attached output; routing both from one mix port reused
one AIDL port config, caused the second open to be rejected as already owned,
and left both declared devices without framework Port IDs. The two mix-port
identities affect discovery only. The sidecar's process-wide lease still
allows only one of their shared PCM0,D0 hardware routes to be active.

## Boot integration

The F1 patch is volatile. A finished image must perform it before enabling
AudioFlinger; it must not depend on a host-side post-boot script. The opt-in
generated tree contains:

```text
vendor/google_devices/frankel/frankel.mk:
  PRODUCT_PACKAGES += android.hardware.audio.service-aidl.powerphone
  DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE += hardware/interfaces/audio/aidl/default/powerphone/compatibility_matrix.powerphone.xml
  PRODUCT_PACKAGES += frankel_powerphone_d10_bootstrap

vendor/google_devices/frankel/BoardConfig.mk:
  BOARD_VENDOR_SEPOLICY_DIRS += vendor/google_devices/frankel/powerphone-d10-bootstrap/sepolicy

vendor/google_devices/frankel/powerphone-d10-patch/:
  exact copy of tools/audio/device/frankel_aoc_d10_patch/

vendor/google_devices/frankel/powerphone-speaker-patch/:
  exact copy of tools/audio/device/frankel_aoc_speaker_patch/

vendor/google_devices/frankel/powerphone-d10-bootstrap/:
  exact copy of tools/audio/device/frankel_powerphone_d10_bootstrap/
  (including the /system_ext init gate source)
```

The old `frankel_pdm_alsa.ko`, `powerphone_pdm_loader`, card-1 `FrankelPDM`,
and topology-ready property are retired from the selected image. They were a
useful AP-PDM experiment, but they are neither needed nor valid evidence for
the proven PCM0,D10 path.

At boot, the selected `/system_ext/etc/init` gate stops the unchanged
system-owned `audioserver` before its class starts. It starts the vendor D10
bootstrap only after stock `aocd` and the AoC HAL are running and init reports
audioserver stopped. A typed boot-local attempted property and `armed` phase
are initialized at post-fs-data; the latch is claimed as the gate's first
command, so the transaction cannot be triggered again by later
audioserver/HAL stops. Requiring `aocd` ensures card 0 exists after that
`late_start` firmware loader. The
bootstrap must still run before, rather than wait for,
`sys.boot_completed`, because system_server audio initialization can require
audioserver. A 60-second asynchronous watchdog bounds failure before the
compound prerequisite trigger; if it expires while the latch remains zero, a
platform action starts finalization asynchronously and its completion releases
ordinary audio. The normal
trigger also requires the watchdog service to be running and expiration to
remain zero, so a published timeout or stopped watchdog wins init's all-
property sweep. An unexpected watchdog-service stop
while the latch and expiration are both zero invokes the same fail-open. The
bootstrap domain clears both research readiness properties,
establishes the strict mixer state, leaves D8/D9/D12 mode 000, and invokes
`frankel_aoc_speaker_patch apply` before `frankel_aoc_d10_patch apply`.
Real-device boots showed that the speaker factory-mailbox transaction cannot
complete reliably after D10's resident diagnostic profile is installed, so
speaker runs first. D10 runs last and its final whole-F1 cache synchronization
covers both profiles. A bounded retry re-certifies an already-selected speaker
state idempotently before retrying D10. The D10 native helper accepts only
`frankel` with vendor build `CP2A.260805.005`, proves D8/D9/D10/D12 closed,
classifies every F1 site uniformly, performs guarded writes and readback,
invokes the whole-F1 I-cache invalidator, and restores its temporary dispatch.
It owns `vendor.powerphone.pdm.ready`: zero before/failure/revert and one only
after final uniformly-patched readback. The speaker helper independently owns
`vendor.powerphone.aoc_speaker_192k.ready`. Each attempt and the finalizer run
as asynchronous oneshot services; exact service-state/phase triggers advance
`armed` through three bounded attempts, `finalizing`, `releasing`, and
`complete`. Each short action publishes its next phase immediately before
starting the service; init therefore consumes the phase edge only after the
start and advances exactly once on an eventual or immediate stopped state.
Long work leaves init free to process unrelated HAL-readiness actions. Before certification, the short
launch action stops and waits for both audioserver and
`vendor.audio-hal-powerphone`. Finalizer completion starts a fresh sidecar
before starting audioserver. This
prevents the generic AIDL module's client-owned stream/port-config objects from
surviving an audioserver death and poisoning the next AudioPolicy startup.

See `frankel-powerphone-image-integration.md` for exact failure and recovery
semantics.

## Build selection

The three feature selections are strict booleans, while D0 progress and signed
AoC firmware are explicit enum profiles. All five values must remain identical
across vendor sanitization, attestation, build, and packaging:

- `POWERPHONE_AOC_ALSA_192K=true` selects the complete D10-capture plus
  D0/EP1 source-0-playback state in Google's source-unavailable AoC kernel
  module: general 192 kHz allowances, EP3 and EP1 masks, 500 us capture-ring
  polling, and a selectable D0 progress implementation.
- `POWERPHONE_D0_PROGRESS_MODE=mailbox` (the baseline default) keeps the real D0
  mailbox path with one-period bounded reporting. Its selected
  `aoc_alsa_dev_util.ko` SHA-256 is
  `fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0`.
  `POWERPHONE_D0_PROGRESS_MODE=one-period-lag` is the publishable PowerPhone
  selection. It retains the real mailbox plus 1 ms hardware-counter poll and
  reports `max(previous, actual minus one physical period)`, SHA-256
  `37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6`.
  That exact profile passed native-q192 physical-speaker and simultaneous D10
  transport at nominal cadence; selecting it is still not acoustic qualification.
  The same flag selects the required paired `aoc_core.ko`
  zero-write-pointer reset, SHA-256
  `f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c`.
  Omitting that pair can advance an already-empty D0 producer ring by a full
  ring before the first PCM copy and is not a valid PowerPhone state.
- `POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE=stock` is the default.
  It is required for the boot-integrated profile because GSA rejects the
  retained `source0-4s32-allocator-fallback` cold transform. The live helper
  applies those narrow A32/F1 changes only after stock firmware is loaded.
  The sanitizer can symmetrically restore the exact stock digest
  `ac6d7d86e6aa78379bfa3db5eaea4dadebf8113dc8f46aab52d55f3987064abd`.
- `POWERPHONE_AUDIO_SIDECAR=true` selects the PowerPhone AIDL module and the
  ordered speaker-then-D10 boot certifier.
- `POWERPHONE_CS35L43_192K=true` changes only the exact stock CS35L43
  ultrasonic GLOBAL_FS immediate from 48 to 96 kHz; its exact SHA-256 is
  `fc631fc227ab2e7e8cfa2d664e97ac7cca4c14324fb2a39479fc8e79aa358a3a`.

Example:

```bash
export PIXEL_TARGET=frankel
export POWERPHONE_AOC_ALSA_192K=true
export POWERPHONE_D0_PROGRESS_MODE=one-period-lag
export POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE=stock
export POWERPHONE_AUDIO_SIDECAR=true
export POWERPHONE_CS35L43_192K=true

scripts/sanitize-generated-vendor-frankel.sh
scripts/attest-generated-vendor.sh create
scripts/build-device.sh
scripts/package-device.sh
```

The build attestation requires both selected AoC kernel modules, both patch
helpers, the staged D0 player, the boot orchestrator, vendor service RC,
system-ext gate RC,
PowerPhone HAL binary/RC/VINTF fragment, and rejects every retired card-1
payload. Selection and successful compilation are not live or acoustic
qualification.

## Test application

The sibling workspace directory `../csr460-powerphone` contains
`com.csr460.powerphone`. It builds offline against this AOSP tree:

```bash
cd ../csr460-powerphone
scripts/build-with-aosp-prebuilts.sh
```

The signed arm64 test APK is:

```text
app/build/manual/PowerPhoneLab-debug.apk
```

The app tests Java `AudioTrack`, Java `AudioRecord` with `UNPROCESSED`, native
AAudio playback, and native AAudio capture. Its qualification UI and intent
path accept only exact `POWERPHONE_*` bus addresses. For each D10 input,
`AudioRecord` and AAudio must negotiate 192000 Hz and report mono `S16` on the
device side. PowerPhone's stream-start path rejects the open unless tinyALSA
reports 192000 Hz, mono `S16_LE`, period size 1920, and period count four. That
fail-closed check distinguishes the 1,920-frame framework queue from D10's
7,680-frame ALSA ring. Output instead uses a 7,680-frame framework queue while
the active D0 ring is 1,920-by-two; each ALSA write contains one 1,920-frame
period and ALSA starts at 1,920 frames.
Frankel removes or omits the usual per-substream procfs `hw_params` path while
these streams are active; a test must use truthful driver/HAL instrumentation
rather than turn that absent file into a false stream failure.

Run the automated route suite after the flashed image reports boot completion,
D10 readiness, and speaker readiness:

```bash
cd ../csr460-powerphone
ADB_BIN=../pixel_aosp_manifest/work/toolchains/platform-tools/adb \
ADB_SERVER_PORT=5038 ADB_LIBUSB=1 ANDROID_SERIAL=<frankel-serial> \
scripts/run-device-suite.sh /path/to/new-results-directory
```

The required properties are `sys.boot_completed=1`,
`vendor.powerphone.pdm.ready=1`, and
`vendor.powerphone.aoc_speaker_192k.ready=1`. The suite covers Java and AAudio
on both explicit output BUS addresses and all three input BUS addresses. Its
preflight also requires the exact Android 17 userdebug/vendor build, enforcing
SELinux, root adbd, the expected AoC card, and all three audio services running.
It snapshots AoC `restart_count` and `coredump_count` before the suite and after
each of the ten route/API runs, rejecting any generation change. During a run,
one passive continuous `logcat` reader is the only observer; `getprop`, procfs,
AoC counters, and every `dumpsys` are deferred until the terminal
`LAB_RUN_COMPLETE` or `LAB_RUN_FAILED` marker. This avoids reproducing the
observed roughly 1.9-second D0 worker starvation caused by an active diagnostic
dump. Java playback must also finish within a broad 0.75x--1.50x wall-clock
window around the requested duration. That gate rejects both discarded fast
streams and the stable but 4x-slow q48/source-0 compatibility path; it is not an
acoustic-bandwidth test. A complete API pass has exactly ten PASS rows and six
endpoint-tagged capture WAVs.

## Pass boundary

For each separately exposed logical microphone:

1. Java AudioRecord and AAudio complete with no failure marker.
2. Requested, client, device-side, and ALSA rates agree at 192000 Hz.
3. The exact requested `POWERPHONE_C0_D10_MICn` route is active.
4. Successful HAL start proves that its fail-closed tinyALSA checks accepted
   mono S16 at exact 1920-by-four geometry; API metadata alone is insufficient.
   Post-run AudioFlinger/policy dumps are diagnostic inventory, not evidence of
   a stream which has already closed.
5. `UNPROCESSED` has no active capture effects, or every unavoidable stage is
   shown not to decimate or low-pass the stream.
6. No XRUN, HAL error, short transfer, or invalid timestamp occurs. Callback
   gaps and blocking stalls remain timestamped diagnostics; because host and
   Android scheduling can lengthen either observation without losing frames,
   they are not alone classified as a transfer discontinuity.
7. An independently calibrated wideband measurement finally demonstrates
   response above 48 kHz without a sharp 24/48 kHz cutoff and shows the
   expected PDM noise-shaped floor toward 96 kHz.

API success, sample counts, and nominal timestamps are transport evidence;
only the final spectral/pilot measurement establishes physical bandwidth and
clock continuity. Until a characterized external ultrasonic source/receiver
is used, the retained microphone spectra and phone self-loop runs cannot
independently qualify each enclosure microphone or assign combined-path
rolloff to either speaker.
