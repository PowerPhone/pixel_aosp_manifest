# Frankel physical-audio playback and capture

For the separate build-only incremental path, see
[BUILD_PLAYBACK192.md](BUILD_PLAYBACK192.md). It rebuilds vendor audio and
stages a fresh RT-worker kernel image without accessing a phone or changing
the release bundle. The operational scripts below do access hardware.

This directory contains target-scoped host wrappers for exercising Pixel 10
(`frankel`) physical microphones and speakers. Direct tests bypass
AudioFlinger; framework tests use real AudioTrack or AAudio playback with an
independent raw D10 tinycap reference. The wrappers use the project's root ADB
connection (server port 5038 by default) and restore the routes and service
states they own.

These are hardware test tools, not evidence by themselves that the signal chain
is truly wideband. A 192 kHz WAV header or frame count can still conceal sample
rate conversion. Verify acoustic bandwidth and jitter with spectral analysis as
described below. After direct tinyALSA qualification, use
[`../../../docs/frankel-audio-api.md`](../../../docs/frankel-audio-api.md) for
the Java AudioTrack/AudioRecord and native AAudio qualification boundary. The
evidence-backed speaker, DMIC/controller/rail map and its live endpoint
identification sequence are in
[`../../../docs/frankel-physical-audio-map.md`](../../../docs/frankel-physical-audio-map.md).

## Current entrypoints: D5 playback and D10 reference

The September 11 **D5/source-5/EP6** path supersedes the D0/source-0,
D28/source-14, four-S16-slot, and rate-only experiments retained later in this
file. The [dated playback report](../../../docs/frankel-playback192-20260911.md)
is authoritative for actual raw, API, and packaged-image results. The old
[September 5 rate-only report](../../../docs/frankel-speaker-rate-only-20260905.md)
is historical, not the current playback status.

Use these entrypoints for the current image:

- `framework-sound-effects-d10-reference.sh`: eight actual Android UI clicks,
  with independent D10 capture; `--warm-primary true` compares an already-active
  ordinary output. Requires the included `SoundEffectsActivity` app build.
  Analyze the unchanged WAV with `tools/audio/analyze_frankel_ui_clicks.py`,
  including the real `Effect_Tick.ogg` source, event log, and capture markers.
  The click is principally below 2 kHz; a 2–18 kHz-only test misses it.
- `d5-d10-acoustic-measurement.sh`: simultaneous direct D5 playback and one
  D10 raw microphone. Stops all three audio services once, owns both routes,
  retains stimulus/capture/logs/analysis, and restores prior service states
  only after both streams finish. It uses already-installed firmware profiles;
  it does not apply or revert firmware patches.
- `framework-playback-d10-reference.sh`: ordinary primary AudioTrack playback
  or addressed research AudioTrack/AAudio playback, while independent tinycap
  records D10. It keeps audio services running, never writes speaker controls,
  and disables application-side recording so AudioRecord cannot be mistaken
  for the raw reference. It uses `com.csr460.powerphone/.StockPlaybackActivity`.
- `d5-speaker-192k.sh`: playback-only direct ALSA run for one physical speaker.
  It owns service stop/restore and amp/route cleanup, and normally checks the
  already-patched source-5 profile before and after playback. This does not
  itself provide an acoustic measurement; use the simultaneous wrapper above
  for that.
- `d10-raw192-capture.sh --use-boot-profile`: capture-only run of one existing
  D10 raw-microphone profile, leaving that boot profile resident.

The current defaults are deliberately separate at each boundary:

| Boundary | Selected configuration |
| --- | --- |
| Direct speaker PCM | Card 0, device 5; 192000 Hz, stereo S32_LE |
| Speaker ALSA queue | 192 frames × 20 periods; 3840-frame full-buffer start; 30,720 bytes within the 32,768-byte physical ring |
| AoC/TDM speaker path | Source 5/EP6; coherent 192-frame jobs; two S32 slots at 12.288 MHz; ASP_BYPASS and ASPRX1 |
| Kernel period delivery | Real AoC mailbox progress; dedicated `pp_d5_period` FIFO/95 worker, not the shared delayed workqueue or a synthetic timer |
| Application playback handoff | Primary/research HAL workers FIFO/90; 960-frame framework transfers while physical ALSA periods remain 192 frames |
| Independent microphone reference | Card 0, device 10; mono S16_LE/192000; 1920×4 periods |

Both codec ultrasonic modes remain disabled in this D5 route. Only the
selected amplifier is enabled; the other remains off. The selected codec's
digital volume is 817 and the raw amp gain defaults to 0. These are mixer
values, not calibrated acoustic output levels. The research image also holds
cluster idle residency at 1,500,000 µs; its higher-idle-power tradeoff and
primary scheduling patches are documented in
[the primary playback profile](../../../tools/audio/frankel_primary_playback_192k.md).
That document also covers the immediate-idle-standby configuration candidate
for completed BUS↔primary handoffs. Check the dated report for its packaged
qualification; simultaneously active primary/BUS playback is unsupported
because both routes share D5.

The research BUS strings still contain `D0` for API compatibility:
`POWERPHONE_C0_D0_BOTTOM` and `POWERPHONE_C0_D0_EARPIECE` now select physical
**PCM0,D5**, not the retired D0 path. Logical microphone selectors 0/1/2 do
not by themselves establish which enclosure opening/controller they represent.

### Direct playback with an independent microphone reference

Generate a modest 12,037-Hz pilot for the same pitch/continuity check used in
the real hardware trials. It is not the historical four-channel stimulus.

```bash
scripts/audio/frankel/generate-signal.py generate \
  work/audio-research/frankel/signals/tone12037-192k-s32-stereo-30s.wav \
  --signal tone --frequency 12037 --rate 192000 --channels 2 --bits 32 \
  --duration 30 --amplitude 0.08

scripts/audio/frankel/d5-d10-acoustic-measurement.sh \
  --stimulus work/audio-research/frankel/signals/tone12037-192k-s32-stereo-30s.wav \
  --output-dir work/audio-research/frankel/raw-bottom-mic0-30s \
  --speaker bottom --microphone 0 --tone 12037 \
  --duration 35 --lead-seconds 2 --amp-gain 0

python3 tools/audio/qualify_frankel_playback_measurement.py \
  work/audio-research/frankel/raw-bottom-mic0-30s/tone-analysis.json \
  --tone 12037 --play-seconds 30
```

Repeat with `--speaker earpiece` and a fresh output directory; change
`--microphone` explicitly for each reference selector. Capture must cover the
quiet lead, complete stimulus, and at least one second of tail. The raw
wrapper's exit status primarily describes transport: it preserves acoustic
analysis even when that analysis is inconclusive. Therefore run the explicit
qualification command and inspect `playback.log`, `capture.log`, `aoc-live.log`,
`logcat.txt`, and `tone-qualification.json`; do not treat its exit zero as a
full acoustic pass.

For playback alone, using the same stereo WAV:

```bash
scripts/audio/frankel/d5-speaker-192k.sh \
  --file work/audio-research/frankel/signals/tone12037-192k-s32-stereo-30s.wav \
  --endpoint bottom --period-size 192 --period-count 20 --amp-gain 0
```

`--skip-live-patch-check` remains an explicit development escape hatch, not a
required step or permission to use a source-0/source-14 profile.

### Framework playback, independently observed at D10

The test application must already be installed. Ordinary UI/media use the
primary speaker path; no research address is passed in this example:

```bash
scripts/audio/frankel/framework-playback-d10-reference.sh \
  --output-dir work/audio-research/frankel/primary-java48-mic0-30s \
  --output-api java --output-rate 48000 --tone 12000 --microphone 0 \
  --play-seconds 30 --duration 36 --lead-seconds 2
```

For the addressed research earpiece at a 192-kHz application rate:

```bash
scripts/audio/frankel/framework-playback-d10-reference.sh \
  --output-dir work/audio-research/frankel/research-aaudio-earpiece-mic0-30s \
  --output-api aaudio --output-rate 192000 \
  --output-address POWERPHONE_C0_D0_EARPIECE \
  --tone 12037 --microphone 0 --play-seconds 30 --duration 36 --lead-seconds 2
```

Use `--output-api java` for the corresponding research AudioTrack test, and
the `...BOTTOM` address for the other speaker. Capture must cover lead plus
playback plus four seconds for launch and idle tail. Output directories must
be new. App peak defaults to 0.08; per-device Android volume also applies to
the BUS and can differ from ordinary speaker volume. A very weak received
tone may be policy attenuation, not a missing amplifier or sampling-rate fault.

This wrapper requires complete app/native results and full-duration acoustic
continuity at 12,000/12,037 Hz, and checks HAL errors through the quiet tail.
For AAudio it retains `native-report.txt` and checks its run ID against the
actual launch; an old success report cannot qualify a later failed run.

For above-48-kHz transmission evidence, use a 192000-Hz output rate with
`--tone 54283` (for example `--play-seconds 5 --duration 11`). That gate
requires the intended-frequency peak and contrast above the quiet lead; it
does **not** certify duration/jitter from a weak ultrasonic envelope. Pair it
with the lower-frequency continuity test and appropriate amplifier-off/
frequency controls. PDM noise near Nyquist is not evidence that the speaker
transmitted a requested carrier, and one carrier does not establish a flat
response through 96 kHz or expose every whole-cycle sample slip.

Avoid intrusive AoC memory dumps, `MIC Clock Rate` reads, or repeated large
AudioFlinger dumps during acceptance recordings. Such diagnostics can disturb
the stream being measured. Retain the original WAVs and logs; do not infer
physical bandwidth from WAV headers, APIs, or successful byte counts alone.

## Retained tool inventory and historical profiles

The older D0/source-0, D28/source-14, rate-only, and AP-PDM descriptions below
record the bring-up history. They are **superseded experiments, not current
playback recipes**. Use the D5/D10 and framework entrypoints above for the
current image; do not copy a historical route/profile into a running D5 test.

- `speaker-alsa-rate-trial.sh` runs normal ALSA/mixer-only experiments with
  explicit frontend/backend rate, endpoint, access and buffer geometry. It
  delegates to the legacy `d0-speaker-control-48k.sh` implementation. It does
  not modify AoC firmware and defaults to a 48 kHz reference.
- `generate-signal.py` creates deterministic low-level tone, white-noise,
  pink-noise, or linear-chirp PCM WAVs and validates WAV metadata.
- `../analyze-wideband.py` measures spectral power on both sides of the common
  24/48 kHz conversion boundaries and optional pilot-tone phase continuity.
- `../analyze-chirp-loop.py` time-aligns the known real 18--85 kHz D0/D10
  self-loop chirp, reports ridge-versus-local-noise evidence through 85 kHz,
  and withholds upper-band conclusions when lower-band alignment is weak.
- `../../../tools/audio/analyze_frankel_ultrasonic_loopback.py` is the strict
  evidence reporter for a known 16--85 kHz chirp and a standard mono
  PCM16/192000 D10 capture. It combines correlated-ridge, 24/48 kHz rolloff,
  upper-band noise, clipping, DC, dropout, and ridge-continuity results in one
  text or JSON report.
- [`../host/`](../host/README.md) contains the guarded, exact-hardware ALSA
  receiver and the external acoustic-rig qualification runbook.
- `tinyplay.sh` routes PCM card 0, device 28 (`audio_ultrasonic`) to exactly
  one of the earpiece or bottom-candidate amplifiers; simultaneous enable is
  rejected because it watchdogs FF1.
- `d5-speaker-192k.sh` is the current isolated PCM 0,5 (`EP6`/Source 5)
  wrapper: stereo S32/192 kHz, two S32 TDM slots, 192×20 ALSA periods,
  full 3840-frame startup, and FIFO/90 playback. The named source-5 live
  profile is already selected in the current native/Python profile; no
  Source 14 retargeting is an operator prerequisite. See current recipes above.
- `d0-speaker-192k.sh` is the historical PCM 0,0 (`EP1`/Source 0) transport
  wrapper, not the current playback qualification path. Its frontend is
  always stereo S32_LE/192 kHz on the 15,360-byte
  `audio_playback0` ring. It defaults to the historically transport-tested
  `q192-s32-2slot`, 1920x2, start-threshold-1920 path, which maps to
  `experimental-enum7-q192-tdm12288-192-2xs32-dma-source0` and programs
  `SR_192K`, `S32_LE`, `Two` channels, `Two` slots, and
  `S32_LE` slot format: a 12.288 MHz-compatible backend. It owns the
  audio-service stop/restore boundary and verifies the selected live profile
  before and after playback. It defaults to an amps-off transport run; the
  earpiece or bottom speaker can be explicitly enabled, never both. Its
  physical-endpoint setup snapshots and temporarily sets only the selected
  codec's stock-route digital gain to 817 (`Digital PCM Volume` for earpiece,
  `R Digital PCM Volume` for bottom). The inactive codec volume is untouched;
  cleanup forces EP1 and both amps off before restoring the selected value.
  Its
  normal mode assumes the EP1/EP6 rate masks, global zero-write-pointer reset,
  and final combined D0 one-period-lag kernel SHA
  `398eaca28da2d97431b1398b5df93e34e594389fa691616416354b4705bde4e3`
  (EP6-normalized D0 profile
  `37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6`)
  are already booted. The driver retains real mailbox progress plus a 1 ms
  real-counter poll and conservatively reports one physical period behind the
  real counter; there is no prefill, availability bypass, or synthetic
  counter. The wrapper never applies the
  volatile AoC profile itself. It requires a complete payload, zero xruns,
  and permits bounded raw-WRITEI EFAULT retries only at the first 15,360-byte
  boundary. A ten-second declared-rate PCM
  stream and concurrent D10 transport passed at nominal cadence, but later
  microphone recordings did not identify the played tone. Other geometries,
  q48, and q192/S16 remain explicit diagnostics. Acoustic bandwidth still
  requires an independent Nyquist-domain measurement.
- `tinycap.sh` selects PDM ID 0, 1, or 2, all three IDs, or the stock two-mic
  ultrasound capture path.
- `d10-raw192-capture.sh` owns the guarded volatile F1-patch lifecycle for the
  qualified PCM 0,10 / EP3 strict-mono S16 192 kHz path. Its separate
  `raw192-pdm0`, `raw192-pdm1`, and `raw192-pdm2` endpoint names cannot alter
  the legacy PCM 0,8 behavior. On an integrated image,
  `--use-boot-profile` directly exercises the boot-certified D10 state without
  another diagnostic apply/revert transaction; readiness, generation,
  freshness, exclusive ownership, and route cleanup checks remain active. See
  [`../../../docs/frankel-aoc-d10-raw192-runtime.md`](../../../docs/frankel-aoc-d10-raw192-runtime.md).
- `d0-d10-self-loop-192k.sh` is the historical self-loop orchestrator for
  the former D0 transport trial and D10 RAW capture. It invokes the two
  wrappers above as independent children, waits for PCM 0,10 to enter and
  remain `RUNNING`, retains separate child logs, and analyzes the resulting
  mono capture. Its transport results did not establish correct D0 acoustic
  playback; it has been superseded by `d5-d10-acoustic-measurement.sh`.
- `observe-aoc-up-ring.sh` records one AoC service's read-only Up-ring Tx/Rx
  occupancy as TSV; it defaults to `ultrasonic_capture` every 25 ms.
- `raw-pdm-capture.sh` and `powerphone-runtime.sh` are retained historical
  AP-PDM/card-1 experiments. They are not an image-integration path and must
  not be run on the current D10 PowerPhone image.
- `self-loop-192k.sh` starts raw capture before one physical speaker and
  produces combined-path analysis for the older PCM 0,8/four-channel probe.
  It is not the current D5/D10 qualification path.
- `reset-routes.sh` is an emergency hard-off helper for only the routes and
  power controls managed here.
- `common.sh` implements the Frankel/device/root guard, quoted ADB execution,
  mixer snapshots, remote signal traps, and host-side cleanup.
- `aocx-speaker-tap.sh` wraps an existing playback command with the stock
  AoCx `sspk.0` speaker-output trace. It enables only tapout20, never
  injection, and retains original WAV metadata and Binder evidence. See the
  [normal-control diagnostic README](../../../tools/audio/device/frankel_aoc_source_gain/README.md#standard-aocx-speaker-output-tap)
  for the exact service ABI, required packages, recorder parser bug, cleanup,
  and the stale-48-kHz-header limitation.
- `../../../tools/audio/probe_frankel_aoc_pdm_controls.py` is a retired
  historical probe. Offline image inspection disproved its four former
  `0x40487xxx` candidates as live PdmV3 objects.
- `../../../tools/audio/kernel/frankel_pdm_dt_probe/` builds a read-only DT
  inventory module against the exact Frankel GKI/DDK artifacts.
- `../../../tools/audio/frankel_a32_raw_pdm.py` is the guarded A32-side raw-PDM
  handoff. It must not be applied until the separately reviewed AP FIFO
  consumer is loaded and ready.
- `../../../tools/audio/device/frankel_aoc_speaker_patch/` is the native
  boot-time writer for the current reboot-volatile source-5 speaker profile.
  Its earlier Source 14 and Source 0 configurations are historical. The
  current playback wrappers consume the boot profile; they do not instruct
  users to reapply those older configurations.
- `../../../tools/audio/patch_frankel_aoc_firmware_speaker_192k.py` applies
  the same expected-bytes patch to the reviewed Frankel `aoc.bin` layout.

Every `--help` path is dry: it neither starts ADB nor contacts the phone.

## Historical D0/D10 self-loop — superseded

The following commands preserve the earlier transport investigation. They
are not a qualified current D0 speaker path and should not be run as the
current-image acceptance test. Use `d5-d10-acoustic-measurement.sh` above.

Use `d0-d10-self-loop-192k.sh` to exercise one D0 physical speaker and one
D10 RAW microphone concurrently without bypassing either path's guards. The
stimulus must be stereo S32_LE/192000; the capture is mono S16_LE/192000.
For example:

```bash
scripts/audio/frankel/d0-d10-self-loop-192k.sh \
  --stimulus work/audio-research/frankel/signals/chirp-18k-85k-192k-s32-2ch-5s-a030.wav \
  --output work/audio-research/frankel/d0-d10-earpiece-pdm0-192k.wav \
  --speaker earpiece --microphone raw192-pdm0 \
  --capture-duration 20 --lead-seconds 1 \
  --amp-gain 0 --mic-soft-gain-db 0
```

The self-loop keeps D10's qualified 1920x4 geometry unless explicitly
overridden. Under simultaneous D0/D10 scheduling pressure, opt into a deeper
240 ms capture buffer without changing the 10 ms period with
`--capture-period-size 1920 --capture-period-count 24`. This is a 92,160-byte
buffer, below the observed 98,304-byte ALSA limit; it is a diagnostic against
AP-side draining latency, not proof that F1 produced every 96-frame block.

The capture duration starts when D10 tinycap opens, so it must also cover the
D0 wrapper's guarded profile checks and route setup, not just the lead and WAV
duration. The orchestrator aborts D0 if PCM 0,10 ceases to report `RUNNING`.
It waits for D10's capture validation and volatile-patch revert, performs the
existing final route reset, then writes independent `.d0-playback.log` and
`.d10-capture.log` files plus the wideband analysis and spectrum sidecars.
Run the ridge analyzer separately on the raw capture as described in the
[`../host/` runbook](../host/README.md#time-aligned-18--85-khz-chirp-analysis);
this preserves its explicit inconclusive exit status rather than folding it
into the transport wrapper.

### ALSA wait-time isolation

`PCM Stream Wait Time in MSec` is a card-wide default, not a live property of
only the PCM whose wrapper changes it. The AoC driver copies the value into
`substream->wait_time` in `snd_aoc_pcm_hw_params()`. Consequently, a D0
`--pcm-wait-ms 200` applied before D10 opened also shortened D10's blocking
read timeout.

There is an additional vendor-kernel units bug. `snd_aoc_pcm_hw_params()`
stores `msecs_to_jiffies(chip->pcm_wait_time_in_ms)`, although ALSA core's
`wait_for_avail()` documents the field in milliseconds and converts it with
`msecs_to_jiffies()` itself. Frankel uses `CONFIG_HZ=250`, so mixer value 200
becomes 50 on the first conversion and about 13 jiffies, or 52 ms, on the
second. The nominal 10000 value similarly gives an effective wait of about
2.5 seconds rather than ten seconds.

Legacy tinycap conceals this failure mode: `capture_sample()` exits its loop
when `pcm_read()` returns nonzero, prints the accumulated frame count, writes
a valid short WAV header, and `main()` still returns status zero. The failed
duplex capture's 1,013,760 frames are exactly 33 buffers of 30,720 frames
(5.28 seconds); that is consistent with one no-progress wait expiring, not
with a proven steady half-rate PDM cadence.

The coordinated wrapper now writes 10000 before publishing D0 readiness, so
D10 copies the normal value during open. It applies an optional short D0
stress value only after D10 reports running and the quiet lead completes.
Omit `--pcm-wait-ms` for the baseline full-duplex qualification; use 200 only
as the intentionally aggressive D0 stall detector. Use
`--capture-first-diagnostic` with a stimulus at least one second longer than
the capture to prove that D10 completes while D0 and its route remain active.

The corrected real PDM0 control run used a 12-second D10 capture, 1920x16
capture geometry, a 15-second D0 stimulus, FIFO priority 90, and the isolated
D0-only 200 setting. D10 delivered exactly 2,304,000 frames and stopped while
D0 remained active; D0 then completed all 23,040,000 payload bytes with zero
xruns. That rules out D0 cleanup as the initiating event and shows that this
workload does not require an F1 core reassignment or firmware-priority patch.

This acoustic loop places the speaker, air path, and microphone in series.
Energy above 48 kHz is combined-path evidence; a cutoff cannot identify which
endpoint caused it and is not endpoint-isolated proof.

### 16--85 kHz evidence report

For the dedicated machine-readable evidence pass, generate the exact known
stimulus once (the playback wrapper requires stereo S32_LE):

```bash
scripts/audio/frankel/generate-signal.py generate \
  work/audio-research/frankel/signals/chirp-16k-85k-192k-s32-2ch-5s-a030.wav \
  --signal chirp --start-frequency 16000 --end-frequency 85000 \
  --rate 192000 --channels 2 --bits 32 --duration 5 --amplitude 0.30
```

After obtaining a real D0/D10 self-loop capture, analyze it with:

```bash
tools/audio/analyze_frankel_ultrasonic_loopback.py \
  work/audio-research/frankel/signals/chirp-16k-85k-192k-s32-2ch-5s-a030.wav \
  work/audio-research/frankel/d0-d10-earpiece-pdm0-192k.wav \
  --json-output work/audio-research/frankel/d0-d10-earpiece-pdm0-ultrasonic.json \
  --require-above-48k
```

The capture input is deliberately strict: standard mono PCM16_LE at exactly
192000 Hz. The analyzer first requires an unambiguous correlated lower-band
alignment, then reports tri-state evidence above 48 and 60 kHz and
source-normalized cutoff tests near 24 and 48 kHz. A rising 55--94 kHz noise
floor is reported only as supportive PDM/noise-shaping evidence; it never
substitutes for the correlated chirp ridge. Exact rail values, DC, constant or
zero runs, 10 ms low-RMS intervals, ridge gaps, and large ridge-timing steps
are reported as integrity indicators. Exit status 3 means alignment was
inconclusive; with `--require-above-48k`, status 4 means the capture did not
qualify. The report describes the combined speaker/air/microphone path and
does not by itself attribute bandwidth to an individual endpoint.

For a direct capture from an integrated image, use:

```bash
scripts/audio/frankel/d10-raw192-capture.sh \
  --output work/audio-research/frankel/boot-pdm0-192k.wav \
  --endpoint raw192-pdm0 --duration 12 --use-boot-profile
```

This leaves the boot-certified F1 profile resident after tinycap and forces
EP3 and all microphone power controls off. Repeat with the two other logical
selectors; do not rename them for enclosure openings without the separate
physical mapping experiment.

## Integrated PowerPhone runtime gate

The current research image uses a platform-context RC in `/system_ext` to stop
`audioserver` during `early-init`. Once the stock `aocd` firmware daemon and
AoC HAL are running and audioserver is confirmed stopped, but before
`sys.boot_completed`, it starts the confined vendor bootstrap. That process
clears both research readiness properties, establishes the strict idle D10
mixer state, establishes the cold A32 allocator fallback, selects the A32/F1 D5
speaker profile first, and certifies D10 last. Real-device boots showed that
the speaker factory-mailbox transaction
can fail after D10's resident diagnostic profile is installed. D10's final
whole-F1 cache synchronization covers both profiles; a bounded retry
re-certifies an already-selected speaker state idempotently before retrying
D10.
On a successful research bootstrap, `vendor.powerphone.pdm.ready=1` and
`vendor.powerphone.aoc_speaker_192k.ready=1` both read back before normal
AudioFlinger release. The bounded fail-open/watchdog paths can release the
framework without research readiness; a running UI alone does not qualify
the research audio profile. The AIDL module
then exposes three logical card-0/D10 input addresses and two individually
addressed card-0/D5 outputs (the stable BUS address strings retain `D0`).
The current kernel delivers D5 period callbacks on its dedicated real-time
worker. Card 1, the AP-PDM kernel module, and its loader
must remain absent. See
[`../../../docs/frankel-powerphone-image-integration.md`](../../../docs/frankel-powerphone-image-integration.md)
for the image contract and build commands. Runtime success alone is not
acoustic-bandwidth or jitter proof.

## Host/device requirements

The host needs Bash, Python 3, GNU coreutils (`realpath` and `timeout`), NumPy,
SciPy, ALSA utilities for an external receiver, and the project platform tools.
On Debian/Ubuntu/WSL install the host analysis dependencies with:

```bash
sudo apt-get install alsa-utils bash python3 coreutils kmod python3-numpy python3-scipy
```

The default ADB executable is:

```text
work/toolchains/platform-tools/adb
```

The phone must be a fully booted Frankel userdebug build with root ADB,
`/system/bin/tinymix`, `/system/bin/tinycap`, `/system/bin/chrt`, and
`/vendor/bin/frankel_aoc_staged_play`. The historical playback wrappers also
use `/system/bin/tinyplay`. The framework reference wrapper requires the
installed `com.csr460.powerphone` test application and the current integrated
HAL/bootstrap/kernel profile. If needed, run the following once before a probe:

```bash
work/toolchains/platform-tools/adb -P 5038 root
```

The scripts refuse another codename, an ambiguous ADB target, a non-root shell,
or a route already in use. Stop media, calls, voice assistants, camera apps, and
other microphone/speaker clients before testing. An alternate ADB binary,
serial, or server port can be supplied with the corresponding command option or
the `FRANKEL_AUDIO_ADB`, `FRANKEL_AUDIO_SERIAL`, and
`FRANKEL_AUDIO_ADB_SERVER_PORT` environment variables.

## Read-only AoC Up-ring observer

To retain ten seconds of `ultrasonic_capture` transport occupancy while a
separately started `tinycap` runs:

```bash
scripts/audio/frankel/observe-aoc-up-ring.sh \
  > work/audio-research/frankel/ultrasonic-up-ring.tsv
```

The defaults are 400 samples at a 25 ms start-to-start interval. Use
`--service`, `--interval-ms`, and `--count` for another service or duration.
Each row records the host epoch timestamp, raw uint32 Tx/Rx counters, their
wrap-aware delta, `slots * slot_bytes` capacity, clamped availability, and an
overflow flag. The observer only reads the kernel's
`/sys/devices/platform/9000000.aoc/services` attribute; it issues no AoC
diagnostic/control command and performs no mixer or sysfs write. It refuses
anything except the exact Frankel `CP2A.260805.005` root-userdebug build.

## Retired F1 static-table probe

The stock Frankel `kheaders.ko` is not a complete external-module build tree.
The workspace therefore bootstraps Google's official DDK workflow from Android
CI build `15739706`, including the matching `Module.symvers`, generated
configuration, common source commit, and clang `r510928`. The read-only
metadata probe and its exact import/CRC/vermagic audit are documented in
[`../../../tools/audio/kernel/frankel_pdm_dt_probe/README.md`](../../../tools/audio/kernel/frankel_pdm_dt_probe/README.md).

The former allowlisted `CMD_DBG_MEM_DUMP` probe treated these addresses as
firmware-derived PdmV3 software-state pointers:

| F1 local pointer | Pointer provenance |
| --- | --- |
| `0x40487268` | core `0x403b0d9d`, parent `+0x30c` |
| `0x40487288` | core `0x403b0da3`, parent `+0x310` |
| `0x404871f0` | core `0x403b6285`, object `+0x30` |
| `0x40487190` | core `0x403b6279`, object `+0x34` |

Exact reads of `aoc-hifi.bin` disprove that interpretation. At `0x40487190`
the words are pointers `0x4026ae72`, `0x4026ae83`, `0x4026ae95`,
`0x4026aea4`, and `0x4026aeb5`, which land in the firmware's error-message
strings (for example, "Invalid argument"). `0x404871f0` and `0x40487268` are
similar pointer tables, while `0x40487288` begins with one string pointer and
the constant `0x00034d00`. They are neither live objects nor MMIO and their
`+0x24`/`+0x28` values say nothing about PDM configuration. The retained Python
file now exits before contacting ADB. `PdmV3::ConfigRFactor` at core
`0x403a5e18` remains useful code provenance, but a trustworthy live object
address has not been recovered.

The separate controller probe reads only this hardware-register allowlist:
`+0x00`, `+0x04`, `+0x10`, `+0x14`, `+0x24`, `+0x28`, and `+0x2c`. It never
reads FIFO `+0x0c` (a read pops data), nor any clock, reset, or gate register.
Its default transport asks the A32 diagnostic service to read controller 4:

```bash
python3 tools/audio/probe_frankel_aoc_pdm_mmio.py --controller 4
```

Only after the A32 read is proven during a controlled stock PDM4/USF capture,
the same values can be compared with `aoc_core`'s stock `address` sysfs read:

```bash
python3 tools/audio/probe_frankel_aoc_pdm_mmio.py \
  --controller 4 --transport compare --allow-active-capture \
  --ack-ap-mmio-risk
```

The acknowledgement is mandatory because an AP `readl()` from a gated or
firewalled MMIO block can still trigger a synchronous external abort. This
comparison changes only the driver's address selector; it has no target-memory
write path. Controllers 0--3 must be tested only after identifying ownership
and ensuring F1 is not concurrently using the selected controller.

An active-stream diagnostic transaction can perturb real-time audio. Establish
the idle result first, use only one active snapshot, and inspect AoC/watchdog
logs afterward. The neutral array/slot labels do not assert which physical mic
is attached to a control block.

## Historical D0 speaker F1 patch transaction — superseded

This archived manual sequence describes an earlier Source 0 profile. Do not
apply or revert it on the current integrated Source 5 image; its boot helper
owns the resident D5 transaction. These addresses/counts are retained as
history rather than current instructions.

The then-selected boot profile was source 0 / PCM0,D0, native 192-frame jobs, two
S32 slots at 12.288 MHz, and 1920-frame source pulls. The native helper owns
the complete reboot-volatile transaction: the A32 allocator fallback, one
dynamic 0x3000 F1 allocation split into four 0xc00 speaker banks, conditional
H0 enum-7/one-millisecond 192/1536 geometry (with stock DeepBuffer geometry),
geometry, 44 guarded F1 words, and whole-F1 cache synchronization. Allocation
addresses are runtime values and must never be hard-coded. The two getter
vtable slots are connected last; any mixed code state, partial object commit,
second-allocation attempt, or AoC generation change requires cold reboot.

On a standalone userdebug session, stop all speaker clients and invoke:

```bash
adb shell su 0 /data/local/tmp/frankel_aoc_speaker_patch check-playback-closed
adb shell su 0 /data/local/tmp/frankel_aoc_speaker_patch check-stock
adb shell su 0 /data/local/tmp/frankel_aoc_speaker_patch apply
adb shell su 0 /data/local/tmp/frankel_aoc_speaker_patch check-patched
adb shell su 0 /data/local/tmp/frankel_aoc_speaker_patch revert
adb shell su 0 /data/local/tmp/frankel_aoc_speaker_patch check-stock
```

The tool accepts only `frankel`, vendor build `CP2A.260805.005`, real/effective
UID zero, stable AoC restart/coredump counters, exact source bytes, and closed
PCM0,D0 (`EP1 playback`, direct `116:2` node plus a complete root fd scan).
The H0 cave and its atomic hook must be installed before the first speaker
Configure because no H0 I-cache invalidator is known. Revert restores F1/H0
code but deliberately leaves the
A32 fallback and dynamic bank pointers until reboot; all state disappears when
stock signed `aoc.bin` reloads. Do not enable the retained offline signed-AoC
transform: GSA rejects modified firmware on this target.

## Historical four-channel stimulus generation

These four-channel files were for the D28/source-14 experiments. Current D5
playback requires the two-channel S32 examples at the top of this document.

The tone default is 18 kHz, deliberately not the annoying 1 kHz laboratory
default. Amplitude defaults to 0.03 full scale. Examples:

```bash
scripts/audio/frankel/generate-signal.py generate \
  work/audio/frankel/tone-18k-192k-s32-4ch.wav \
  --signal tone --frequency 18000 --rate 192000 --channels 4 --bits 32 \
  --duration 5 --amplitude 0.03

scripts/audio/frankel/generate-signal.py generate \
  work/audio/frankel/chirp-15k-80k-192k-s32-4ch.wav \
  --signal chirp --start-frequency 15000 --end-frequency 80000 \
  --rate 192000 --channels 4 --bits 32 --duration 10 --amplitude 0.02
```

All channels contain the same stimulus. The generator also supports
deterministic `white` and `pink` signals. It refuses a tone/chirp at or above
Nyquist and refuses to overwrite a file unless `--force` is given.

## Historical D28 physical-speaker recipe — superseded

This retained `tinyplay.sh` route is not the current D5 recipe. Its backend
and codec mode must not be combined with the current integrated speaker path.

All stream parameters are mandatory, so the invocation is reproducible:

```bash
scripts/audio/frankel/tinyplay.sh \
  --file work/audio/frankel/chirp-15k-80k-192k-s32-4ch.wav \
  --endpoint bottom --rate 192000 --format s32 --channels 4 \
  --period-size 512 --period-count 8 --ultrasonic-mode in-band \
  --high-rate-source direct --amp-gain 0
```

Endpoints are derived from the stock mixer routes:

- `earpiece` enables only unprefixed `Main AMP Enable Switch`, matching the
  stock `speaker-earpiece` path.
- `bottom` enables only `R Main AMP Enable Switch`. Calling it bottom is an
  inference from the complementary amp topology and must be confirmed
  acoustically.
- simultaneous amplifier enable is intentionally unsupported because it
  watchdogs FF1 `mainTask`.

`--high-rate-source direct` selects `ASPRX1` for both `High Rate PCM Source`
controls and bypasses the codec's stock `DSP FS2` choice. Use
`--high-rate-source dsp-fs2` to compare the stock DSP-fed high-rate leg.
`--ultrasonic-mode` is always explicit (`disabled`, `in-band`, or
`out-of-band`). `--amp-gain` is the codec mixer's raw integer control, whose
reported `dsrange` is 0--20; it is not a calibrated dB value. Begin at raw 0
and raise it cautiously. The stock earpiece music route uses raw value 6.

The setup sequence leaves the TDM route and amps off until all rates, formats,
slots, sources, and gains are configured. The amps are enabled last. A remote
Android-shell trap and a host trap independently force both amps off, turn off
`TDM_0_RX Mixer US`, and disable both codec ultrasonic modes. This cleanup also
runs on PCM errors and termination signals.

## Historical AP and stock AoC capture paths

For current independent 192-kHz capture, use D10 and the top-level entrypoints.
The AP-MMIO and PCM0,D8/D12 commands below retain their original limitations.

### Guarded raw AP controller capture

> **Retired:** the AP-MMIO consumer trial faulted and rebooted the phone. The
> commands in this subsection are preserved as historical procedure and must
> not be run on the current D10 PowerPhone image.

`raw-pdm-capture.sh` is the executable form of the reviewed raw-PDM handoff.
Its guarded A32 operations allow 900 seconds because factory-diagnostic reads
are serialized and a full pre/active/post snapshot takes several minutes.
Each intended A32 write is journaled atomically before the target store.
It supports exactly one physical controller per invocation and deliberately
requires an independent logical scalar-power choice. For the first staged
PDM0 permission trial:

```bash
scripts/audio/frankel/raw-pdm-capture.sh \
  --output work/audio/frankel/raw-pdm0-mic0-192k.wav \
  --controller PDM0 --power MIC0 --duration 5 \
  --ack-hardware-write --ack-ap-permission-trial
```

Do not interpret that example as `MIC0 -> PDM0`; the correspondence is not yet
known. Repeat isolated trials with an intentional scalar/controller matrix and
a known near-field stimulus. PDM2 and PDM3 are gated on the prior PDM0 AP
permission result:

```bash
scripts/audio/frankel/raw-pdm-capture.sh \
  --output work/audio/frankel/raw-pdm2-mic0-192k.wav \
  --controller PDM2 --power MIC0 --duration 5 \
  --ack-hardware-write --ack-ap-permission-trial \
  --ack-pdm0-permission-proven
```

The wrapper uses the reviewed
`work/upstream/frankel-gki-15739706/modules/frankel_pdm_alsa.ko`, requires its
vermagic release to equal the running kernel, and refuses anything except the
reviewed Frankel vendor build and a fully booted root-userdebug system. Its
PCM geometry is fixed at card 1, the selected device 0/2/3, mono S32_LE,
192000 Hz, 19200-frame periods, and four periods. Calibration switches are
explicit optional arguments; run `--help` for their defaults.

Both hardware acknowledgements are mandatory. The script checks A32 idle
state before any write and again after powering exactly one of scalar `MIC0`,
`MIC1`, or `MIC2`. It loads one controller mask with polling still zero,
validates every immutable module parameter and the selected ALSA node, applies
the guarded A32 handoff, enables polling, captures, then performs the mandatory
dependency order: reap tinycap, synchronously stop polling, collect stats and
dmesg, revert A32, power the selected scalar off, unload the module, and only
then pull and validate the WAV. It will not revert A32 if polling-off cannot be
read back, and it will not power off/unload if A32 restoration is uncertain.

Alongside the WAV it retains `.raw-pdm-stats.txt`, `.raw-pdm-dmesg.txt`,
`.raw-pdm-tinycap.txt`, `.raw-pdm-a32.txt`, and the exact A32 JSON snapshot.
The trial fails on a malformed/short WAV, zero FIFO delivery, or any reported
ALSA/module overrun. `all`, `MIC3`, `BUILDIN MIC POWER STATE`, and
`BUILDIN_MIC_POWER_INIT` are intentionally unsupported.

### Stock AoC capture paths

Single-PDM examples use mono; `all` is exactly three channels; `ultrasound` is
the stock PDM 0+1 pair and exactly two S32 channels:

```bash
scripts/audio/frankel/tinycap.sh \
  --output work/audio/frankel/pdm0-192k.wav --endpoint pdm0 \
  --rate 192000 --format s32 --channels 1 \
  --period-size 1024 --period-count 8 --duration 10

scripts/audio/frankel/tinycap.sh \
  --output work/audio/frankel/all-pdm-192k.wav --endpoint all \
  --rate 192000 --format s32 --channels 3 \
  --period-size 512 --period-count 8 --duration 10

scripts/audio/frankel/tinycap.sh \
  --output work/audio/frankel/ultrasound-pair-96k.wav \
  --endpoint ultrasound --rate 96000 --format s32 --channels 2 \
  --period-size 960 --period-count 4 --duration 10

# Use this only after the D12 frontend and AoC firmware are genuinely 192 kHz.
scripts/audio/frankel/tinycap.sh \
  --output work/audio/frankel/ultrasound-pair-192k.wav \
  --endpoint ultrasound --rate 192000 --format s32 --channels 2 \
  --period-size 1920 --period-count 4 --duration 10
```

The normal PDM endpoints use PCM 0,8, `EP1 TX Mixer INTERNAL_MIC_TX`, and
`BUILDIN MIC ID CAPTURE LIST`. The ultrasound endpoint uses PCM 0,12,
`EP5 TX Mixer INTERNAL_MIC_US_TX`, and stock capture list
`BUILDIN US MIC ID CAPTURE LIST` with value `0 1 -1 -1`. It keeps the obsolete
direct `US Record Enable` control off because the native-ultrasound firmware
rejects that command. Capture processing is set to `Raw`, spatial processing
is disabled, the source is `Builtin_MIC`, and the DC blocker defaults off. Use
`--dc-blocker on` if DC offset consumes too much headroom and
`--soft-gain-db` for an explicit -40..30 dB gain.

`pdm0`, `pdm1`, and `pdm2` select AoC logical capture IDs 0, 1, and 2. They do
not prove physical PDM-controller numbers or enclosure holes because the stock
firmware can remap logical DMICs to physical pads. Use the guarded isolation
procedure in
[`../../../docs/frankel-physical-audio-map.md`](../../../docs/frankel-physical-audio-map.md)
to establish both mappings. The stock AoC rejects ID 3.

For capture-free manual power trials, query or write only the scalar `MIC0`,
`MIC1`, and `MIC2` controls, one at a time, while all capture paths and raw PDM
controllers are idle. Verify readback and AoC logs after each write. Do not use
the four-element `BUILDIN MIC POWER STATE`, do not access `MIC3`, and do not use
`BUILDIN_MIC_POWER_INIT`; those paths touch the unsupported fourth index or a
multi-parameter power configuration rather than one scalar logical mic. The
scalar controls still use the AoC/F1 control service, but they do not open an
F1 capture PCM.

`tinycap.sh` and `reset-routes.sh` restrict power preflight and cleanup to
`MIC0`, `MIC1`, and `MIC2`. They never query or write the unsupported logical
`MIC3` control. Physical `DMIC3`/PDM3 is distinct from that invalid fourth AoC
logical-control index.

The script prints `MIC Clock Rate` only while the PCM is idle. Do **not** read
this control from another shell while capture is active: on the tested AoC
firmware that getter blocked the audio service long enough to trigger an AoC
watchdog reset. The registered mixer control has no write callback, so the
current tooling deliberately treats it as idle-only telemetry.

The capture is first pulled to a same-directory partial file. Its WAV header
and frame count are validated before it is renamed to the requested output.
The accepted frame count spans the requested duration through at most one
additional tinycap buffer. An early or implausibly long capture fails even when
stock tinycap returns status zero; a valid partial WAV is retained beside the
requested output as `.failed-capture-PID`. Capture lists and other non-power
controls are restored in reverse order, and cleanup is limited to the three
supported scalar logical-mic controls.

## Historical stock-path constraints (not the selected D5/D10 profile)

The wrappers intentionally accept 48, 96, and 192 kHz so the same commands can
be used before and after a port, but stock Frankel is not a 192 kHz end-to-end
implementation:

- `audio_ultrasonic` PCM 0,28 is hard-coded to 96 kHz, S32_LE, 2--4 channels in
  the Google AoC ALSA driver.
- PCM 0,8 capture advertises at most 96 kHz. PCM 0,12 and the AoC ultrasound
  firmware contract are 96 kHz, S32, two channels.
- The backend enums (`TDM_0_RX`, `INTERNAL_MIC_TX`, and
  `INTERNAL_MIC_US_TX`) include `SR_192K`, but selecting a backend enum does not
  widen the frontend PCM or prove the AoC firmware avoids resampling.
- `MIC Clock Rate` is registered with `mic_clock_rate_get` and a null setter in
  `aoc_alsa_ctl.c`; it is read-only. The capture script prints its idle value,
  but explicit PDM-clock control requires a kernel/AoC interface change.
- Both CS35L43 DSP sampling-rate values were observed at 48 kHz on stock. The
  direct high-rate source and ultrasonic-mode choices still require physical
  validation on the patched image.

A failed 48/192 invocation on the stock image is therefore expected and useful:
it confirms that a future successful invocation is using changed kernel/AoC
constraints rather than silently relying on the stock path.

## Physical verification

The complete isolated-speaker, isolated-microphone, host-ALSA, calibration,
jitter, and six-combination self-loop procedure is in
[`../host/README.md`](../host/README.md). The UMC202HD described in that
historical external-receiver runbook can run a true 192 kHz hardware PCM,
but its official analog input response is
specified only through 50 kHz. It can help expose 24/48 kHz brick walls; it
cannot by itself substantiate the requested smooth 60+ kHz acoustic response.

For microphone validation, present a calibrated broadband or swept ultrasonic
source and inspect each raw channel's spectrum. A genuine 192 kHz path should
not show a hard 24 or 48 kHz cutoff and typically exposes delta-sigma
noise-shaping toward the 96 kHz Nyquist edge. For speaker validation, measure
with a microphone/interface independently known to exceed 96 kHz bandwidth;
look for gradual acoustic rolloff rather than a brick wall at 24 or 48 kHz.

Check kernel/AoC logs for XRUNs and compare successive pilots/chirps for
discontinuous phase or time gaps. For the current D5 path, preserve the
192×20/full-3840 geometry and investigate notification/producer scheduling
before changing it: larger periods previously made notification starvation
worse. Its actual ring permits only 32,768 bytes, despite broader generic
ALSA limits. The older S32 D8/D12 capture geometries below are not current D10
defaults and are not universal proof of jitter-free operation.

Run the host analyzer on every pulled recording. A broadband example is:

```bash
scripts/audio/analyze-wideband.py \
  work/audio/frankel/pdm0-192k.wav \
  --expected-rate 192000 \
  --spectrum-csv work/audio/frankel/pdm0-192k-spectrum.csv
```

For a continuous 18 kHz pilot, also report phase-step outliers that can expose
dropped or repeated samples even when tinycap returned success:

```bash
scripts/audio/analyze-wideband.py \
  work/audio/frankel/pdm0-pilot-192k.wav \
  --expected-rate 192000 --pilot-tone 18000
```

The analyzer deliberately reports evidence rather than declaring success from
metadata. Energy above 48 kHz, no sharp local drop at 24/48 kHz, zero XRUNs,
correct wall-clock duration, and stable pilot phase must agree. A calibrated
wideband emitter/measurement microphone is still required to attribute a
roll-off to the phone rather than to the laboratory stimulus or receiver.

D12 is different: the AoC driver and native-ultrasound processor use a 10 ms,
four-period contract. Keep the period at exactly `rate / 100` frames: 960x4 at
96 kHz, or 1920x4 after true 192 kHz support exists. A previous 1024x8 D12 run
captured only 1.621 seconds of a requested 15 seconds before the STOP-time
broken-microphone query (`0x00eb`) timed out and requested an AP AoC reset. The
later `A3SWWDT` was a failed-recovery symptom, not proof that the original
stream completed. If scheduling pressure requires more buffering at 96 kHz,
try 960x8 without changing the 10 ms period and recheck the full duration.

If a shell or USB transport disappears during a test, Android's remote trap is
the first cleanup layer. Once ADB returns, run:

```bash
scripts/audio/frankel/reset-routes.sh
```

Then inspect the relevant controls before another high-rate experiment.
