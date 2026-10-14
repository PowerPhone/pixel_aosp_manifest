# Cubs 192 kHz audio: application and endpoint guide

Status, 2026-09-23: the exact v7 replacement-primary image passed the isolated
10/10 Java/AAudio endpoint matrix, four API duplex reference runs (30/8 seconds),
ordinary 48-kHz playback, and three 30-second direct-ALSA duplex runs. A second
normal boot and its API/ordinary-playback checks also passed without host
firmware preparation. See the [qualification record and retained failures](cubs-powerphone-qualification-20260923.md)
and the [matching flash bundle](../artifacts/cubs-powerphone-192k-20260923/).
Qualification is limited to the reported intervals and routes: it does not
establish concurrent ordinary/research output mixing, a full 96-kHz acoustic
passband, or stock-feature compatibility.

This is a Cubs-specific research image. Frankel uses different services,
addresses, amplifier controls and firmware patches; do not substitute them.

## Ordinary audio versus explicit research routes

The Cubs service owns `IModule/default`, `IConfig/default` and an empty
effects factory. It replaces, rather than runs alongside, the proprietary
primary audio HAL. AudioFlinger itself is not patched for sample-rate support.

Ordinary applications can select the built-in speaker/microphone or use the
normal policy default. The default speaker is the bottom transducer; the
default microphone is logical MIC0. The physical HAL/ALSA transport stays at
192000 Hz. AudioFlinger can convert ordinary client formats/rates, such as a
48 kHz AudioTrack, at the framework boundary. A client's requested or reported
rate alone therefore does not prove the physical rate.

For research, enumerate `AudioDeviceInfo.TYPE_BUS` and select one exact address:

| Address | Endpoint | Hardware contract |
| --- | --- | --- |
| `POWERPHONE_CUBS_C0_D5_BOTTOM` | Bottom speaker | Card0 D5, stereo S32_LE, 192000 Hz |
| `POWERPHONE_CUBS_C0_D5_TOP` | Top/earpiece speaker | Same D5 transport; top amplifier profile |
| `POWERPHONE_CUBS_C0_D10_MIC0` | Logical mic0 → physical PDM lane0 | Card0 D10, mono S16_LE, 192000 Hz |
| `POWERPHONE_CUBS_C0_D10_MIC1` | Logical mic1 → physical PDM lane2 | Same D10 transport; selector1 |
| `POWERPHONE_CUBS_C0_D10_MIC2` | Logical mic2 → physical PDM lane3 | Same D10 transport; selector2 |

The microphone lane mapping is supported by the actual PDM start logs in
`work/audio-research/cubs/mono192-mcps112-qualification-20260922/`: the physical/
logical masks are respectively `1/1`, `4/2`, and `8/4`. **Bottom, top and camera
microphone-hole identities have not been measured.** Do not infer them from
the numbering. Android device IDs are discovered each run, not persisted.

Both directions use 1920-frame periods ×4, with independent 1920-frame
framework queues. The current Cubs playback start threshold is 3840 frames
(half of the 7680-frame ALSA ring), matching the successful tinyplay startup;
older full-prefill trials failed and remain in the evidence. Playback uses two
32-bit TDM slots. A stereo API buffer is still required when only one speaker
is selected; use the same test waveform in left/right channels unless studying
channel routing explicitly.

Capture requests `UNPROCESSED`, with the RAW firmware path and no advertised
capture effects. The mono API profile does not expose simultaneous three-channel
RAW3; that is a separate exclusive direct-ALSA experiment.

## Boot readiness

The native `cubs_powerphone_boot` helper starts automatically at `post-fs-data`,
after requesting the AoC loader. It waits on actual nodes, initialized objects,
idle PCMs and firmware-generation guards, not `sys.boot_completed` or a fixed
warm-up delay. It applies the exact boot-local firmware profile once and
publishes readiness only after cache completion and readbacks.

Platform init holds audioserver until the helper finishes. The HAL may register
earlier but refuses real streams until the complete contract is valid. A
failed helper can release boot with an inert HAL for recovery: reaching the
launcher or `sys.boot_completed=1` alone is not audio readiness.

On a root userdebug shell, the following are read-only diagnostics:

```bash
ADB=work/toolchains/platform-tools-37.0.1/platform-tools/adb
SERIAL=YOUR_CUBS_SERIAL
export ADB_LIBUSB=1
"$ADB" -P 5038 -s "$SERIAL" shell /vendor/bin/cubs_powerphone_boot --status
"$ADB" -P 5038 -s "$SERIAL" shell getprop vendor.powerphone.cubs.boot.phase
"$ADB" -P 5038 -s "$SERIAL" shell getprop init.svc.vendor.audio-hal-powerphone-cubs
"$ADB" -P 5038 -s "$SERIAL" shell getprop init.svc.audioserver
```

Required state is:

```text
vendor.powerphone.cubs.boot.phase=ready
vendor.powerphone.cubs.profile=mono192-edge0-mcps112-d5-two-slot-v5
vendor.powerphone.cubs.capture.ready=1
vendor.powerphone.cubs.playback.ready=1
vendor.powerphone.cubs.boot_id=<current /proc/sys/kernel/random/boot_id>
init.svc.vendor.audio-hal-powerphone-cubs=running
init.svc.audioserver=running
init.svc.vendor.audio-hal-aidl=<absent or stopped>
/sys/devices/platform/a800000.aoc/restart_count=0
/sys/devices/platform/a800000.aoc/coredump_count=0
```

The HAL rechecks profile/generation/ownership while operating; flags from a
previous AoC generation are not authority to stream. Never set them manually
to bypass a failure. A mutation failure, AoC restart or latched ownership fault
requires reboot and investigation, not restarting a competing stock service.
See the [native helper contract](../tools/audio/device/cubs_powerphone_boot/README.md).

On the second qualified boot, native readiness was published at uptime
6.775 seconds after 2.830 seconds of helper runtime, with SELinux enforcing and
AoC counters 0/0. Post-boot AAudio TOP/MIC1 duplex and ordinary 48-kHz
bottom/MIC0 playback/reference passed. These are measured boot timings, not a
fixed delay that apps should sleep or a deadline guaranteed for every reboot.

Normal apps need neither root nor property access. They need the public devices
to exist, successful stream opening, exact post-start routing and normal
recording permission. The host qualification tools perform the additional
root-only boot/generation checks.

## Java AudioTrack and AudioRecord

Use `AudioManager.getDevices(GET_DEVICES_OUTPUTS/INPUTS)` and require exactly
one nonzero device ID with type `TYPE_BUS` and the desired address. Do not
fall back to a default device if it is missing. These are construction
fragments; the working app includes transfer loops, error handling and cleanup.

```java
// 'speaker' is the uniquely matched output BUS AudioDeviceInfo.
AudioTrack track = new AudioTrack.Builder()
    .setAudioAttributes(new AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .setSpatializationBehavior(AudioAttributes.SPATIALIZATION_BEHAVIOR_NEVER)
        .setIsContentSpatialized(false).build())
    .setAudioFormat(new AudioFormat.Builder()
        .setSampleRate(192000).setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
    .setTransferMode(AudioTrack.MODE_STREAM)
    .setBufferSizeInBytes(Math.max(19200 * 2 * Float.BYTES,
        4 * AudioTrack.getMinBufferSize(192000, AudioFormat.CHANNEL_OUT_STEREO,
                                      AudioFormat.ENCODING_PCM_FLOAT)))
    .build();
if (!track.setPreferredDevice(speaker)) throw new IllegalStateException("route rejected");
// play(), write float stereo frames, verify routed device, then stop()/release().
```

Float client samples are explicitly converted to the S32 HAL/container; that
does not require sample-rate conversion when both rates are 192000. Use
positional `CHANNEL_OUT_STEREO`, not a channel-index mask.

For capture, declare/request `android.permission.RECORD_AUDIO` and first require
`AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED` to report `true`.
Do not silently substitute `MIC` if it does not.

```java
// 'mic' is the uniquely matched input BUS AudioDeviceInfo.
AudioRecord record = new AudioRecord.Builder()
    .setAudioSource(MediaRecorder.AudioSource.UNPROCESSED)
    .setAudioFormat(new AudioFormat.Builder()
        .setSampleRate(192000).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
        .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build())
    .setBufferSizeInBytes(Math.max(19200 * Short.BYTES,
        4 * AudioRecord.getMinBufferSize(192000, AudioFormat.CHANNEL_IN_MONO,
                                       AudioFormat.ENCODING_PCM_16BIT)))
    .build();
if (!record.setPreferredDevice(mic)) throw new IllegalStateException("route rejected");
// startRecording(), read short mono frames, then stop()/release().
```

After starting, require `getRoutedDevice()` to match the selected device.
For AudioRecord also inspect `getActiveRecordingConfiguration()`: its device
format must be 192000 Hz/mono/PCM16, source `UNPROCESSED`, no effects, and
`isClientSilenced()` false. Verify actual reads, timestamps and duration.
For AudioTrack check negotiated format, full playback duration and underruns;
zero client underruns alone did not detect an earlier HAL failure.

Keep the diagnostic Activity awake, unlocked and resumed. A permission grant
does not prevent Android from silencing a background or sleeping recording
client. Actual early trials returned full-sized recordings after AppOp27
silencing; those trials are not valid microphone qualification. A production
background recorder needs the appropriate Android foreground-service lifecycle,
not relaxed app-op enforcement.

## Native AAudio

Pass the exact device ID discovered through the Java enumeration into JNI.
For either direction the current profile uses SHARED/NONE, not MMAP or
EXCLUSIVE/LOW_LATENCY:

```cpp
AAudioStreamBuilder* builder = nullptr;
AAudio_createStreamBuilder(&builder); // Check every result in real code.
AAudioStreamBuilder_setDirection(builder,
    input ? AAUDIO_DIRECTION_INPUT : AAUDIO_DIRECTION_OUTPUT);
AAudioStreamBuilder_setDeviceId(builder, exactDeviceId);
AAudioStreamBuilder_setSampleRate(builder, 192000);
AAudioStreamBuilder_setChannelCount(builder, input ? 1 : 2);
AAudioStreamBuilder_setFormat(builder,
    input ? AAUDIO_FORMAT_PCM_I16 : AAUDIO_FORMAT_PCM_FLOAT);
AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_NONE);
AAudioStreamBuilder_setBufferCapacityInFrames(builder, 19200);
if (input) {
    AAudioStreamBuilder_setInputPreset(builder, AAUDIO_INPUT_PRESET_UNPROCESSED);
} else {
    AAudioStreamBuilder_setUsage(builder, AAUDIO_USAGE_MEDIA);
    AAudioStreamBuilder_setContentType(builder, AAUDIO_CONTENT_TYPE_SONIFICATION);
    AAudioStreamBuilder_setSpatializationBehavior(builder, AAUDIO_SPATIALIZATION_BEHAVIOR_NEVER);
}
// Set data/error callbacks; openStream(), requestStart(), then stop/close.
```

Check the actual device, client format and hardware rate/channels/format after
opening and after starting. The Cubs output HAL is stereo PCM_I32; the AAudio
client is float. Capture must remain mono PCM_I16. Callback errors, XRUNs,
short transfer, missing route, silencing and early completion are failures.
The test app samples all steady-run timestamps after a fixed one-second warmup,
retains the raw observations and applies the original 1% rate gate plus coverage
and monotonicity checks. A two-point startup estimate is not a reliable whole-run
rate measurement. Timestamp/API agreement still does not prove acoustic bandwidth.

## Existing app and guarded host commands

The sibling project is `../csr460-powerphone`, package `com.csr460.powerphone`.
Its `MainActivity` implements all four APIs and each exact route; its
`StockPlaybackActivity` also exercises ordinary built-in output and concurrent
Java `UNPROCESSED` reference capture. From the repository root:

```bash
bash ../csr460-powerphone/scripts/build-with-aosp-prebuilts.sh
export ADB_BIN="$PWD/work/toolchains/platform-tools-37.0.1/platform-tools/adb"
export ADB_SERVER_PORT=5038 ADB_LIBUSB=1 ANDROID_SERIAL=YOUR_CUBS_SERIAL

# Requests root ADB, installs the APK, grants recording permission, and runs
# Java + AAudio on both outputs and all three inputs. Use a new result directory.
TARGET_DEVICE=cubs DURATION_SECONDS=8 TONE_HZ=20731 PEAK_LEVEL=.08 \
  bash ../csr460-powerphone/scripts/run-device-suite.sh \
  "$PWD/work/audio-research/cubs/NEW_API_MATRIX"
```

The matrix does not change mixer controls, firmware, stream volume or service
ownership. It wakes/dismisses the keyguard, requires the Activity to remain
foreground and rejects silencing. It retains six endpoint-tagged capture WAVs,
per-run API/native reports, routing, generation, error and completion evidence.
This is ten API runs, not an acoustic ten-endpoint proof.

For actual simultaneous playback plus microphone reference, after installing
and granting permission with `../csr460-powerphone/scripts/install.sh`:

```bash
bash scripts/audio/cubs/api-duplex-reference.sh \
  --adb "$ADB_BIN" --adb-server-port 5038 --serial "$ANDROID_SERIAL" \
  --output-api aaudio --speaker bottom --mic 0 \
  --duration 8 --tone 20731 --peak .08 \
  --output-dir work/audio-research/cubs/NEW_API_DUPLEX
```

Use `--output-api java|aaudio`, `--speaker bottom|top` and `--mic 0|1|2`.
The reference is Java AudioRecord, not tinycap. This wrapper requires already
rooted adbd for read-only generation checks; it does not root/install/grant,
change gain or restart services. It retains `capture.wav`, native output
reports where applicable, full logs, acoustic analysis and `qualification.json`.
API/HAL success and single-tone continuity are distinct gates. The allowed
tone option extends above the amplifier's useful band for deliberate alias
experiments; that does not make those frequencies valid speaker output.

Ordinary 48 kHz Java playback can be requested without a BUS address:

```bash
# Guarded ordinary-media test with a192-kHz MIC2 reference and physical pilot
# analysis. AudioFlinger geometry is saved only before/after the tone.
bash scripts/audio/cubs/api-duplex-reference.sh \
  --adb "$ADB_BIN" --adb-server-port 5038 --serial "$ANDROID_SERIAL" \
  --output-api java --speaker bottom --ordinary-rate 48000 --mic 2 \
  --duration 8 --tone 20731 --peak .08 \
  --output-dir work/audio-research/cubs/NEW_ORDINARY48_DUPLEX

# Bare app launch, without the wrapper's independent evidence gates:
"$ADB_BIN" -P 5038 -s "$ANDROID_SERIAL" shell am start -W \
  -n com.csr460.powerphone/.StockPlaybackActivity \
  --es output_api java --ei output_rate 48000 --ei tone_hz 20731 \
  --ei duration_seconds 8 --ef peak_level .08
```

This selects the built-in bottom speaker. For native AAudio ordinary output,
use `output_api=aaudio`, `output_rate=192000`, still omitting `output_address`.
The Activity tests transport; use a simultaneous reference for acoustic claims.

## Ownership, handoff and direct tinyALSA

There is one physical output lease (D5) and one input lease (D10). One selected
speaker plus one selected microphone may form a duplex session. Two output
routes, ordinary output overlapping a research BUS, or two independent input
routes are not supported. Multiple ordinary tracks can share the same primary
AudioFlinger mixer, but do not assume a separate BUS mixer shares its D5 lease.

Stop and release the old API stream before selecting another address; active
hot route changes are rejected. The profile uses immediate framework standby.
The v7 handoff implementation waits up to500 ms
for another output to finish closing. A longer lease conflict rejects that
START without consuming its data or putting the persistent Cubs output worker
into permanent ERROR. This is not concurrent playback: AudioFlinger can discard
the rejected chunk, and that audio attempt is unsuccessful. Real PCM, mixer
and readiness errors remain terminal. This retryable behavior is Cubs-output
only; Frankel and capture keep their existing error semantics.

Actual v7 cold-boot evidence demonstrates this distinction: TOP Java completed
1,536,000 frames in8.030s with zero underruns while a concurrent SystemUI unlock
sound repeatedly failed to acquire the ordinary primary output. The ordinary
primary resumed after research closed; a subsequent TOP AAudio run succeeded
without restarting the HAL. The original matrix aggregate failure is retained,
because the overlapping UI playback was not successful. See the
[precise thread/track attribution](../work/audio-research/cubs/primary-hal-integration-20260923/bundle-v7-api-matrix/CONTENTION_ATTRIBUTION.md).
This is recovery evidence, not a promise that UI and research audio mix or that
every rejected UI sample will play later.

For isolated qualification, wake/unlock in the non-playing preparation phase,
confirm foreground/unlocked state, and require the native read-only
`cubs_powerphone_boot --check-idle` kernel-reservation check before starting.
Keep a bounded deadline and retain busy observations. A single idle snapshot
cannot prevent a subsequent queued/user-triggered UI sound, so deliberately
overlapping UI tests remain separate from isolated endpoint results.

The Cubs input FLUSH fix releases the paused D10 FD and route on the serialized
FMQ worker before the framework disconnects its port. PCM close always precedes
route-off/restoration. Lifecycle errors remain failures even when the recorded
tone itself appears correct. The final isolated matrix and sequential API/direct
sessions passed their lifecycle checks; the separately retained concurrent UI
failure above is not reclassified as a pass.

Direct wrappers are a separate exclusive mode. They stop audioserver, exclude
both HAL owners, check PCM ownership, then configure named endpoints. Examples:

```bash
bash scripts/audio/cubs/direct-mic-capture.sh \
  --serial "$ANDROID_SERIAL" --adb-server-port 5038 \
  --rate 192000 --mic 2 --duration 3 \
  --output-dir work/audio-research/cubs/NEW_DIRECT_MIC2

python3 scripts/audio/cubs/generate-probe.py \
  --output work/audio-research/cubs/NEW_TONE.wav \
  --rate 192000 --tone 20731 --duration 3 --peak .08
bash scripts/audio/cubs/direct-speaker-play.sh \
  --serial "$ANDROID_SERIAL" --adb-server-port 5038 \
  --wav work/audio-research/cubs/NEW_TONE.wav \
  --pcm deep --endpoint top --asp bypass \
  --output-dir work/audio-research/cubs/NEW_DIRECT_TOP
```

The direct speaker wrapper requires a stereo S32 WAV and limits a single trial
to 10 seconds. Longer simultaneous trials use `duplex-baseline.sh` as documented
in the [direct-mode runbook](../scripts/audio/cubs/README.md). In this mono boot
profile do not use `--mic all`, legacy primary/ultrasonic PCMs or another rate.
Wrappers leave all audio owners stopped after cleanup; **reboot to return to
automatic API mode**. Do not manually restart audioserver over an exclusive
direct session. See [API/direct mode boundaries](../scripts/audio/cubs/MODES.md).

## Research-image limits

- Stock calls/telephony audio, Bluetooth audio, USB/headsets and hotword are
  not implemented by this replacement. Audio Bluetooth profiles are disabled
  to avoid missing-factory crash loops. The non-audio Bluetooth stack stayed ON
  with zero crashes during the 25-second observation and after the normal reboot;
  this is not a functional qualification of every BLE/GATT/HID accessory.
- Speaker DSP protection/effects are bypassed for research. Begin with short,
  low-level signals; inaudibility is not assurance of low transducer stress.
- TAS2572 accepts the 192 kHz serial stream but internally downsamples to
  96 kHz. TI warns against content above 40 kHz because of aliasing. The actual
  Cubs sweeps also show folding beyond the 48 kHz boundary, not successful
  48–90 kHz acoustic reproduction. There is no documented missing manual
  192 kHz selector that removes this limitation. See
  [TI section7.4.8, page41](https://e2e.ti.com/cfs-file/__key/communityserver-discussions-components-files/6/074.02572.0001_5F00_TAS2572YCGR_5F00_SPEC.pdf)
  and the [target-specific audit](../tools/audio/cubs/DIRECT192_CANDIDATE.md).
- Microphone high-band noise and fresh 192 kHz samples support the transport
  finding but do not establish calibrated acoustic sensitivity through 96 kHz.
  A speaker-to-microphone self-loop measures the combined path; it cannot
  independently assign each transducer's rolloff or exclude all electrical
  coupling. Full bandwidth and sample-clock phase-noise claims remain separate
  from API rates and the bounded continuity tests.

For packaging and flash topology use the [Cubs integration record](cubs-primary-integration.md),
the [qualified release bundle](../artifacts/cubs-powerphone-192k-20260923/), and
its installation prerequisites, not a mixture of Frankel images or historical
Cubs candidates. Earlier failed tests remain failures in the qualification record.
