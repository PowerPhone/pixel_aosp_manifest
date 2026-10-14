# Cubs PowerPhone bring-up

Status (2026-09-23): **a separately qualified research image is available**.
See the [final scope and hardware evidence](cubs-powerphone-qualification-20260923.md)
and [API/boot guide](cubs-audio-api.md). The entries below preserve the bring-up
history, including failures and superseded candidates; they are not instructions
to apply historical firmware profiles over the automatic boot profile.
Frankel's working profile is unchanged. No Frankel firmware addresses, kernel
module offsets, amplifier controls, or flash topology are portable by assumption.

### Current result at a glance

| Area | Actual state |
| --- | --- |
| Speaker serial transport | Both TAS endpoints accept measured192-kHz FSYNC with two32-bit slots; stable30-second tests under simultaneous RAW3 capture |
| Three simultaneous microphones | Native192-kHz transport, correct20731-Hz pitch and complete30-second tones on all six speaker/mic combinations; no detected interior phase jumps/dropouts/clipping with RAW MCPS112 |
| Acoustic bandwidth | Intended18–48-kHz sweep response followed by strong96-kHz-domain folding; no intended48–90-kHz speaker self-loop response established. All3 microphones meet the agreed near96-kHz noise-ramp milestone; calibrated acoustic sensitivity is not claimed |
| Amplifier limit | TAS2572 internally downsamples192 to96kHz and documents aliasing. Correct family setting is already active; no missing manual192-kHz selector was found |
| Android APIs / boot | Replacement primary:10/10 isolated AudioTrack/AudioRecord/AAudio endpoint tests; direct/API tone continuity passed. Automatic readiness6.529/6.775s on two boots; separate14-image flash-all release. APIs select one mono mic at a time |

Original WAVs and complete six-path results are indexed in the local
[RAW3 qualification report](../work/audio-research/cubs/raw3-packed-v2-mcps112-20260922/QUALIFICATION.md).
The entries below retain the failed experiments and their corrections rather
than rewriting that history as success.

## Live baseline

The attached, unlocked Pixel 11 identifies as `cubs`, hardware revision MP1.0.
It booted slot A successfully. Its fingerprint is
`google/cubs/cubs:17/CD1A.260714.001.A9/eng.charle:userdebug/test-keys`, but its
kernel is **6.12.92-android16-6-maybe-dirty-4k**, not the saved donor's 6.12.69.
Use the live module/boot backup as the mutation baseline; do not mix their ABIs.

Local evidence and recovery material (ignored, not GitHub release inputs):

```text
work/audio-research/cubs/baseline-20260922/
  identity-pcm-modules.txt
  properties-services.txt
  framework-audio.txt
  tinymix.txt
  pcm-capabilities.txt
  control-enums.txt
  aoc.bin
  boot-backup/{boot,vendor_boot,vendor_kernel_boot,init_boot,dtbo}_a.img
  boot-backup/vbmeta{,_system,_vendor}_a.img
  vendor-kernel-ramdisk/lib/modules/
```

The older complete boot-qualified bundle remains untouched at `artifacts/cubs/`.
The new live backup is only the named physical partitions, not a complete
snapshot of userdata or the logical OS partitions.

Use Platform-Tools 37.0.1 and ADB server port 5038. A competing server on 5037
claimed the USB device when root ADB re-enumerated; stopping that server and
restarting 5038 with `ADB_LIBUSB=1` restored access. Do not confuse this host
ownership issue with a phone crash.

## Hardware and interfaces

- Audio card 0: `google,aoc-snd-card`; proprietary AoC AIDL primary service
  `vendor.audio-hal-aidl`.
- Live codec controls identify the TAS25xx pair, with `music_17dB_top`,
  `music_17dB_bottom`, `music_17dB_stereo`, and `voice` profiles. Donor platform
  XML identifies TAS2572. The Awinic codec is the auxiliary HAC path, not the
  two normal speaker endpoints.
- AoC uses Malibu firmware (`mbu_a32`, `mbu_hf5`) and a PdmV4 frontend.
  Live sysfs root: `/sys/devices/platform/a800000.aoc`.
- Audio configuration belongs to
  `/apex/com.google.pixel.audio.resource/etc/audio/config/`, not loose Frankel
  vendor XML.
- Three logical mic controls (`MIC0`..`MIC2`) and the default capture list
  `0 1 2 -1` exist. Physical enclosure-hole mapping is not yet measured.

Live kernel admission, before changes:

| PCM | Route | Advertised limit |
| --- | --- | --- |
| D0 / D1 / D5 playback | EP1 / EP2 / EP6 | 48 kHz, 1–2 channels |
| D8 / D10 / D12 capture | EP1 / EP3 / EP5 | 96 kHz, 1–4 channels |
| D28 playback | ultrasonic | 96 kHz, S32, 2–4 channels |

Backend mixer enums already include `SR_192K`; this does **not** establish
frontend admission, DSP transport, amplifier rate, or acoustic bandwidth.

## Speaker bandwidth caveat

TI advertises 192-kHz **input** for the TAS2572. Its detailed SLASF66 datasheet,
section 7.4.8 (page 41), says this input is internally downsampled to 96 kHz;
the electrical table gives an approximately 45-kHz passband edge. This is a
silicon-path constraint, distinct from the driver's rate switch. Investigation
must establish whether any documented bypass exists before claiming native
192-kHz/full-band playback. A 192-kHz WAV, accepted API rate, or aliased
ultrasonic tone is not a passing Nyquist result.

Sources: [TI product page](https://www.ti.com/product/TAS2572),
[TI-hosted detailed datasheet](https://e2e.ti.com/cfs-file/__key/communityserver-discussions-components-files/6/074.02572.0001_5F00_TAS2572YCGR_5F00_SPEC.pdf).

## Original qualification checklist (retained history)

The target-rate, API, integration and scoped-release items are now recorded in
the linked final report. Full96-kHz speaker acoustic bandwidth is precluded by
the observed/documented amplifier stage; microphone calibrated ultrasonic
sensitivity is outside the user's agreed noise-ramp criterion. The original
checklist below shows the questions investigated, not outstanding release claims.

1. Direct ALSA baseline and target-rate transport on each endpoint.
2. Cubs-specific PDM clock/decimation and all DSP frame/byte boundaries.
3. Independent speaker routing, rate/pitch correctness, full-interval spectra,
   and XRUN/restart monitoring; distinguish hardware filtering from mechanics.
4. AudioTrack, AudioRecord UNPROCESSED, and AAudio tests with actual HAL/ALSA
   transport evidence, followed by boot and normal-UI lifecycle tests.
5. Target-scoped reproducible build/boot integration and a separately named,
   hardware-qualified flash bundle.

## First live experiments

All results below are on the untouched live kernel/firmware baseline, with
AoC restart/coredump counters remaining `0/0` and audio services restored.

| Experiment | Observed result |
| --- | --- |
| D10, logical mic 0, S16 mono, 48 kHz, 3 seconds | 142,080 frames / 2.96 seconds; transport works |
| Same at nominal 96 kHz | Same 142,080 frames over roughly 3 wall seconds; only 1.48 seconds at the WAV rate, **not true 96-kHz transport** |
| Same at 192 kHz | Kernel `hw_params` rejects it; zero frames |
| Bottom D5, ASP bypass, 48-kHz stereo S32 / 20-kHz tone | Playback command completes; acoustic proof pending duplex capture |
| Bottom D28, ASP bypass, 96-kHz stereo S32 / 30-kHz tone | Tinyplay reports a playback error after about 0.4 seconds; not a pass |

The speaker amplifier driver was reached with 96-kHz backend parameters in
the D28 trial. That does not identify the reason for the subsequent write
failure or prove the actual bus/output rate.

Scripts (run via `bash`, existing root ADB):

```bash
bash scripts/audio/cubs/direct-mic-capture.sh \
  --output-dir work/audio-research/cubs/NEW-RUN \
  --rate 48000 --mic 0 --duration 3
```

`direct-speaker-play.sh` independently owns playback. Do not run these two
single-stream wrappers concurrently; each stops the framework and owns the
card. The newer duplex harness, when present, must own both streams.

The baseline init policy starts the vendor HAL after `audioserver` stops.
Quiescence therefore waits for the audioserver stop action and stops the HAL
last, requiring both services to settle. A bulk FD-owner check avoids the
very slow fork-per-file-descriptor scan tried initially. Cleanup restores
named mixer settings only if boot/AoC generations are unchanged. Failed
attempts and WAVs remain available for diagnosis.

`tools/audio/cubs/patch_capture192_admission.py` creates a separate experimental
kernel module with normal-runtime admission, only D10/backend DAI extension,
and correct capture command encoding. It does **not** fix the AoC producer.

`tools/audio/cubs/build-diag.sh` builds a Cubs-product-guarded factory transport
using the existing AOSP Clang/sysroot/runtime objects. Its code shares the
transport with Frankel but no firmware patch addresses. A live core-2 read of
the independently derived Cubs shared-code anchor `0x4027a618` returned
`4e062ee242872c86a154fc6e156e8e02`, matching the pulled firmware. This proves a
bounded diagnostic read, not code-write or cache synchronization support.

## Real 48-kHz duplex reference after admission-kernel v2

These four experiments used the separately flashed capture-admission kernel v2,
but retained the original AoC firmware and requested **48 kHz** on both streams.
One `duplex-baseline.sh` transaction owned the capture and speaker routes:
five-second D10 mono S16 capture, one-second quiet lead after capture readiness,
then a two-second, 20-kHz stereo S32 probe at peak 0.02 with 5-ms fades. The
speaker profile selected either TAS25XX bottom or top; AoC speaker ASP was
bypassed. All four WAVs contain 238,080 frames / 4.96 seconds and no saturated
samples. Both commands completed, cleanup restored the original controls and
services, and AoC restart/coredump counters remained `0/0`.

| Speaker / logical microphone | Measured carrier (Hz) | Tone RMS (dBFS) | Detected interval (s) | Whole interior analyzed (s) | Phase steps >0.35 rad / dropout blocks |
| --- | ---: | ---: | --- | ---: | ---: |
| Bottom / mic 0 | 19,999.99930 | -59.28 | 1.55–3.52 | 1.87 | 0 / 0 |
| Top / mic 0 | 20,000.00097 | -73.89 | 1.47–3.45 | 1.88 | 0 / 0 |
| Bottom / mic 1 | 19,999.99969 | -70.27 | 1.55–3.53 | 1.88 | 0 / 0 |
| Bottom / mic 2 | 20,000.00334 | -87.71 | 1.48–3.46 | 1.88 | **145 / 0 — not phase-qualified** |

The analyzer retains every sample between the outer detected tone boundaries,
excluding a fixed 50 ms at each end; it does not choose a favorable short
window or omit internal gaps. Phase differences use 250-us blocks. The mic-2
tone corresponds to only about **1.91 S16 quantization steps peak**, so
quantization and additive noise can confound its phase measurement. Its
maximum measured phase step was 0.553 rad. The 145 events remain reported;
they are neither a continuity pass nor conclusive evidence of a transport
fault. A louder bounded physical repeat can resolve this without relaxing the
analysis threshold.

This establishes received 20-kHz lines and short-run pitch/continuity references
for the listed routes, not 96/192-kHz acoustic bandwidth. A single carrier
cannot reveal a sample slip by an exact whole number of cycles, and these
trials alone do not isolate acoustic output from electrical coupling. Logical
mic IDs are not yet mapped to enclosure holes.

Original WAVs, transport evidence, and per-trial `analysis/metrics.json`,
`analysis/full-capture-analysis.png`, and `analysis/whole-active-phase.csv`:

```text
work/audio-research/cubs/capture192-admission-kernel-v2-20260922/hardware/
  duplex48-bottom/
  duplex48-top/
  duplex48-bottom-mic1/
  duplex48-bottom-mic2/
```

Reproduce a duplex reference and analyze its complete recording:

```bash
bash scripts/audio/cubs/duplex-baseline.sh \
  --output-dir work/audio-research/cubs/NEW-DUPLEX-RUN \
  --wav work/audio-research/cubs/baseline-20260922/stimuli/tone20000-48000-s32-stereo.wav \
  --endpoint bottom --mic 0 --capture-rate 48000

work/toolchains/hf-plot-venv/bin/python tools/audio/analyze_cubs_baseline_tone.py \
  work/audio-research/cubs/NEW-DUPLEX-RUN/capture.wav --tone 20000 \
  --expected-duration 2 \
  --output-dir work/audio-research/cubs/NEW-DUPLEX-RUN/analysis
```

The host analyzer requires NumPy, SciPy, and Matplotlib. Analysis does not
modify or resample the original WAV. On this kernel the verbose PCM proc status
node is absent, so the harness records capture readiness from a living child
and actual WAV byte growth before starting its quiet lead.

## Native-192 capture prototype: first hardware failure

The live-kernel admission image is
`work/audio-research/cubs/capture192-admission-kernel-v2-20260922/vendor_kernel_boot.img`.
Only `vendor_kernel_boot_a` and the backed-up `vbmeta_a` (with fastboot verification
disabled) were flashed. The original physical-partition backups and the older
`artifacts/cubs/` bundle remain unchanged. Admission alone still records about
48,000 actual frames/second even when a 192-kHz WAV is requested.

The first coherent, volatile firmware trial is saved under
`work/audio-research/cubs/mono192-v2-20260922/`. Its 23 patch regions were visible
after a fresh cache-handler completion, but the first capture produced **zero
frames**, not a valid 192-kHz recording. AoC logs show native Stream 2 at 192000
and 19200 timestamp ticks per 96-frame block (0.5 ms), versus the old expected
38400 ticks. The AP configuration rejected the new rate; RAW enable command
`0x1272` subsequently timed out and caused an AoC reset. These observations
support the clock/cadence change, not microphone acoustic bandwidth.

The exclusive prototype is marked by `/dev/powerphone-cubs-mono192`. Capture
wrappers leave ordinary audio services stopped while marked, including after
an AoC reset. Full reboot is the clean prototype rollback; never restore stale
firmware bytes or mixer snapshots after the firmware generation changes.

A separate repeated speaker trial (`speaker96-live2-20260922/`) localized the
original D28 failure: firmware rejects entrypoint **28** in configure `0x1406`
and enable `0x1401`, while source 14 is bound to the speaker and its sink still
reports 48 kHz. TAS backend admission at 96 kHz was therefore not sufficient.
Playback entrypoint mapping and actual output timing require correction.

### Subsequent real capture and clock-control experiments

`mono192-v4-20260922/` bypasses the remaining legacy RAW-stage processor after
releasing its source ring. It captures separately from all three logical mics
without an AoC reset. However, mic0 has about -24 dBFS broadband noise; this
is **not** qualified 192-kHz audio. Five/15-second runs produce 4.56/14.56
seconds of samples, respectively: the roughly 404-ms RAW-enable response
accounts for most of this fixed startup deficit. Full duration checks remain
failed rather than silently accepting short recordings.

`mono192-v5-20260922/` restores the stock hardware-HPF instruction. The same
conversion path then exposes a +0.7014 FS mic0 DC offset without improving
AC noise. A known 20-kHz tone remains at the correct frequency, but this
does not overcome the unacceptable noise or establish Nyquist bandwidth.

`mono96-control-v1-20260922/` retains the v5 RAW staging/converter but restores
the original 3.2-MHz clock, 96-kHz native timebase and timestamp interval.
The nominal 192-kHz WAV header is deliberately retained as a diagnostic:
476,160 samples over five wall seconds are **96-kHz acquisition**, not 192.
The 20-kHz physical probe appears near 40 kHz in the file's declared coordinates.
With that coordinate distinction explicit, its full tone interval is clean:
20,000.00013 Hz, 2.00 seconds, no detected phase events/dropouts over the
retained 1.8-second physical interior. Quiet physical 0.2..0.8 seconds measures
-78.08 dBFS AC, about 53.8 dB better than v5, and DC is +0.0000379 FS.
This isolates the failure to the higher-clock/receiver configuration rather
than establishing that conversion code is inherently broken. Receiver timing,
decimation and the microphones' actual clock limits remain under investigation.

The currently flashed kernel-only image is
`work/audio-research/cubs/playback-admission-kernel-20260922/vendor_kernel_boot.img`.
It preserves capture admission and adds D5-only 96/192-kHz admission/encoding.
It boots, and D5/96 playback now completes, but firmware logs still show a
48-kHz speaker sink/TDM clock. The image is **not** a high-bandwidth playback
release; original `artifacts/cubs/` remains untouched.

## Android API integration inventory — design only

### Subsequent direct-path experiments (September 22–23)

The exclusive D5 direct96 prototype now bypasses H0/SRC and copies real host
stereo S32 frames into the existing four-slot speaker DMA buffers. At a
12.288-MHz BCLK, both physical speakers transmit a 30.013-kHz acoustic probe:
bottom measured 30,013.000161 Hz and top 30,013.000452 Hz. Neither recording
has detected phase discontinuities or dropouts in the retained 1.82-second
physical tone interior. The microphone uses the **clean physical96 control**;
its deliberately retained 192-kHz file header must not be read as a physical
192-kHz qualification. Evidence is in
`work/audio-research/cubs/direct96-v2-20260922/`.

This is above-24-kHz acoustic evidence, not a completed playback release.
The top route has an approximately 11-ms onset transient, and logs retain
startup/teardown interval warnings and bypassed H0 messages. Ordinary audio
services remain stopped for this volatile prototype. The TI amplifier's
documented internal96-kHz ceiling is not removed by changing its input rate.

The stock3.2-MHz microphone RFactor6 trial produces 57,600 timestamp ticks
per96-frame block: **64-kHz acquisition**, not the hypothesized144/192 kHz.
It records322,560 samples over the five-second test without an AoC reset.
Together with RFactor2→48k, stock4→96k, and8→no frames, this rules out a
simple linear multiplier interpretation of the field. Evidence is in
`work/audio-research/cubs/native192-rfactor6-v1-20260922/`. No API or boot
readiness claim follows from these diagnostic configurations.

The adjacent RFactor3 experiment produces115,200 ticks per96-frame block
and161,280 samples in the five-second test: physical32k, not128/192k. No
reset occurred. A19.937-kHz probe is above this path's Nyquist limit, and its
expected alias is not convincingly detected; do not claim a pitch pass.

The first direct192 speaker-bus experiment
(`work/audio-research/cubs/direct192-v1-20260922/`) reaches24.576-MHz TDM but
fails playback after about0.49 seconds. Only160×48 stereo frames are consumed,
exactly one40-ms AP buffer, and there is no sustained acoustic tone. Startup
consumption before EP_ENABLE and the TAS clock-ratio errors are being
investigated separately. This is a failed experiment, not a192-kHz playback
qualification. Updated route cleanup avoids the duplicate unbind and closes
the speaker before the capture tail; its real bind/unbind replies both succeed.

### Native192 receiver-edge breakthrough

`tools/audio/manifests/cubs_d10_native192_edge0_control.json` preserves the
nominal6.4-MHz clock, RFactor4 and canonical direct RAW conversion, changing
only the native receiver edge selection at4025d1fc to0. The physical pad clock
has not been independently measured; the nominal value comes from software.
All three separately selected microphones now capture a30.013-kHz tone at
the correct frequency and full two-second tone duration. No detected phase
events, dropouts or clipping occur in their retained tone interiors:

| Logical mic / speaker | Measured Hz | Tone dBFS | Max phase step (rad) |
| --- | ---: | ---: | ---: |
| 0 / bottom | 30013.000090 | -64.58 | 0.104 |
| 1 / top | 30013.000918 | -65.99 | 0.0575 |
| 2 / top | 30012.998042 | -57.60 | 0.0404 |

Mic0's quiet AC level improves from approximately-24.30 to-80.01dBFS; the
large+0.7017FS DC offset disappears. Mic1/2 quiet levels are-75.67/-80.52dBFS.
Their quiet spectra rise toward96kHz without a downward step at24/48kHz,
consistent with extended noise shaping but **not independent proof of
acoustic sensitivity above48kHz**. An external ultrasonic reference has been
requested. Mic0 also captures43,116.998870Hz from the96-kHz bottom-speaker
path, with no detected tone-interior phase events/dropouts/clipping.

Evidence: `work/audio-research/cubs/native192-edge0-v1-20260922/`, including
original WAVs, full-interval reports and fixed quiet-spectrum comparisons.
The amplifier's protected, uncached TDM_DET reads0x35 during the96-kHz speaker
test (128 clocks/frame), independently confirming that bus configuration.
The approximately0.4-second RAW startup delay still shortens a5-second tinycap
request to4.56 seconds; wrappers deliberately retain the duration failure.
Mic1 has one repeated96-sample block before its tone and mic2 has three during
startup; none occur in the analyzed tones. Simultaneous three-channel capture,
API integration, automatic boot readiness and a flashable release remain open.

The direct192 playback running-gate retry stalls F1 after EP_ENABLE returns
success, triggering an input-command timeout and an AoC reset. The phone
recovers by reboot. Therefore pre-enable waiting is not its demonstrated
cause. A lower-callback-rate two-slot transport is being prepared separately;
neither failed192 speaker candidate should be installed persistently.

The first two-slot192 transport now completes playback without an AoC reset.
Its protected silicon TDM_DET register reads0x26 during the tone:192-kHz frame
sync with64 bit clocks/frame. Nevertheless the acoustic recording is a
**continuity failure**:2.00 seconds becomes approximately2.16 seconds, with
1293 phase jumps and a strong25.012-kHz spur. The direct worker consumes4000
96-frame blocks but also reports310 geometry refusals, currently under
investigation. Evidence is
`work/audio-research/cubs/direct192-two-slot-v1-20260922/`. Successful commands,
complete input-byte consumption and a valid192-kHz bus do not qualify playback.

The instrumented two-slot candidate isolates this failure. With physical96-kHz
microphone capture it plays30012.999589Hz for2.02seconds with no interior phase
events, dropouts or clipping, and zero geometry refusals. The identical speaker
candidate with native192-kHz capture instead rejects668 source-pointer blocks,
all while playback is running, stretching the tone to2.32seconds. The assembly
worker's ENTRY64 frame put locals at+32/+36/+40 in Xtensa's register-spill area;
the higher-load run exposed their corruption. A separate ENTRY96 candidate is
being tested, without changing clocks or weakening the ring bounds checks.
Evidence: `work/audio-research/cubs/direct192-two-slot-v2-reasons-20260922/`
and `work/audio-research/cubs/direct192-two-slot-v3-reasons-native192-20260922/`.

The ENTRY96 same-load repeat **passes the short measured waveform**:
30013.085669Hz,1.99-second outer interval,1.89-second retained interior,
zero phase-step events/dropouts/clipped samples, maximum phase step0.09621rad.
All geometry counters are zero and all4000 source blocks were consumed.
Evidence: `work/audio-research/cubs/direct192-two-slot-v4-frame-native192-20260922/`.
This qualifies that two-second bottom-speaker/mic0 experiment, not a complete
endpoint matrix, long-run stability, amplifier full-bandwidth or Android APIs.

The separate RAW3-admission `vendor_kernel_boot_a` image has been flashed
through bootloader fastboot and boots normally. It adds only the exact
RAW-trigger channel comparison3→4 to the existing capture/playback admission
module. Firmware RAW3 packing still requires its separate exclusive volatile
profile; widening kernel admission alone does not make three-channel recording
safe. The original complete Cubs release remains unchanged.

The first packed RAW3 trial starts zero frames: command0x1272 times out and
AoC restarts once. A full83,887,192-byte SSCD capture and original logs are
preserved at `work/audio-research/cubs/raw3-packed-v1-direct192-20260922/`.
The phone remains reachable through ADB. RAW3 is not qualified; this failure
does not invalidate the separately measured mono edge0 transport.

### Long-run qualification is not yet a pass

The fixed two-slot speaker worker consumes60000 blocks for each30-second
source with no geometry refusals or AoC reset. However, bottom/mic0 capture
contains only29.87seconds of tone, and top/mic1 only29.78seconds. The respective
35-second requests return34.44/34.36-second recordings. These runs are retained
as **duration-unqualified**, not passed merely because commands completed.

At30013Hz, losing96 samples shifts carrier phase by only0.04084rad: each block
contains almost exactly15 cycles. Thus zero events above the0.35rad threshold
cannot exclude such losses. A20731Hz follow-up makes a96-sample slip produce
about2.30rad, improving detection without using an annoying low-frequency tone.
Evidence: `work/audio-research/cubs/direct192-two-slot-longrun-20260922/`.

The20731Hz follow-up confirms a real continuity failure: its outer tone lasts
29.68seconds, with867 thresholded phase events and maximum2.311rad, close to
the96-sample-slip signature. The large whole-record fitted frequency is biased
by these discontinuities and must not be called a physical pitch estimate.
No speaker source-buffer geometry rejection occurs. RAW still votes the stock
28MCPS budget; a paired112MCPS enable/disable control is the next scheduling
experiment, not an established fix. The RAW3 core independently shows2294
576-byte blocks already published into the host-service ring despite the
RAW_ENABLE command timing out. This points toward scheduling/control-response
starvation rather than an absent three-channel publisher.

The paired RAW112MCPS control **fixes the observed RAW3 startup failure** in
the first real retry:560640 three-channel frames in a3-second request
(2.92 seconds of data), no AoC reset, explicit+112 at start and−112 back to
zero at stop. The subsequent bottom-speaker20731Hz/30-second run returns
6704640 three-channel frames for35 seconds (34.92 seconds of data): the same
80ms fixed deficit, with no growing loss apparent from duration. Speaker
geometry counters remain zero. Whole-waveform continuity analysis is separate
and still required; sample totals alone are not a pass.

The three quiet channels are distinct, nonzero, unclipped streams, with
quiet AC levels−80.17/−76.68/−80.77dBFS. No exact repeated blocks were found
after startup at the tested48–1920-frame block sizes. Evidence:
`work/audio-research/cubs/raw3-packed-v2-mcps112-20260922/`.

The corrected bottom-speaker30-second20731Hz run now passes the measured
continuity check on **all three simultaneous microphone channels**. Each
outer tone interval is30.00seconds, with29.90seconds analyzed after fixed
50ms boundary exclusions. Measured frequencies are20730.999901,
20730.999984 and20730.999728Hz; phase-event/dropout/clipped-sample counts are
zero for all three, with maximum phase steps0.00561/0.03471/0.15148rad.
This is actual waveform evidence of corrected pitch and block continuity;
it does not establish microphone sensitivity above48kHz or bypass the
amplifier's internal96-kHz domain. Top-speaker analysis and sweeps follow.

The matching top-speaker run also passes all three channels: outer durations
30.00/30.01/30.01seconds, frequencies20730.999513/20730.999960/20730.999899Hz,
zero phase events/dropout blocks/clipped samples, and maximum phase steps
0.09054/0.00987/0.00916rad. Thus both physical speaker routes have a measured
30-second continuity pass with simultaneous RAW3 capture under this prototype.
The18–90kHz sweeps are retained separately: folded aliases must not be counted
as intended high-frequency response, and a self-loop cannot independently
separate the microphone and amplifier transfer functions.

Individual-microphone mode with the same RAW MCPS112 correction is now also
measured separately. Mic0/bottom, mic1/top and mic2/top each retain a30.00s
20731Hz tone and29.90s analyzed interior, with zero phase events/dropouts/
clipped samples. Frequencies are20730.999975/20730.999962/20730.999938Hz;
maximum phase steps0.03034/0.01462/0.00926rad. Capture startup deficits are
80/80/40ms, retained explicitly. This same-mono comparison isolates the budget
change from the earlier867-event mono failure. Original evidence:
`work/audio-research/cubs/mono192-mcps112-qualification-20260922/QUALIFICATION.md`.

The research session ended with a full reboot restoring ordinary unmodified
AoC firmware; volatile research profiles are not default-on. The widened
admission kernel remains installed. No research HAL has been installed or
enabled, and no final PowerPhone flash bundle has been published.

### Integration inventory

No Cubs research API module is installed or qualified yet. Direct native-rate
capture and safe framework coexistence remain prerequisites; the volatile
`/dev/powerphone-cubs-mono192` marker is a **quarantine marker, not readiness**.

The stock Cubs manifest already declares audio-core/effect **AIDL v4**, matching
the existing source-built PowerPhone module. The stock AoC process owns
`IModule/default`, `IModule/bluetooth`, `IModule/r_submix`, `IConfig/default`, and
`IFactory/default`. An additional research `IModule` must not duplicate those
default config/effect instances. The currently observed ordinary output ports
advertise stereo 48 kHz; normal/fast inputs advertise S16 48 kHz. Editing a WAV
header, backend mixer enum, or AudioFlinger client rate cannot add a genuine
high-rate HAL profile.

Configuration/build ownership:

| Area | Current source or installed owner | Minimal later integration |
| --- | --- | --- |
| Ordinary platform, mixer, volume configuration | `com.google.pixel.audio.resource.apex`, mounted at `/apex/com.google.pixel.audio.resource/etc/audio/config/` | Preserve ordinary resource configuration initially; do not create an unused loose policy XML |
| Research AIDL module | `hardware/interfaces/audio/aidl/default/powerphone/` in `work/aosp` | Reuse the AIDL/FMQ, exact-device selection, lease and fail-stop mechanisms through a Cubs-specific configuration; leave Frankel behavior unchanged |
| Product selection | `vendor/google_devices/cubs/cubs.mk`, generated by adevtool | Add an explicit, default-off Cubs research package selection through the reproducible target generator/sanitizer |
| Service discovery | Binary, init RC, VINTF `IModule` fragment, framework compatibility matrix | Install a uniquely named research instance and its matching declarations together; register an inert module before audio-policy discovery rather than block discovery until hardware is ready |
| SELinux and readiness | Cubs vendor policy currently labels only the stock AoC executable explicitly | Add exact executable/service labels and a typed Cubs readiness property owned by the target helper; the HAL reads it, but does not self-certify |
| Public API probe | `../csr460-powerphone`, package `com.csr460.powerphone` | Add a target profile containing exact addresses and independent input/output rate contracts; retain negotiated-route, timing, and native-error checks |

The smallest first research exposure, **after real transport qualification**,
is capture-only: three addressed `IN_BUS` logical microphone choices, one
exclusive card-0/D10 lease, mono S16, the exact proven rate and period/ring,
and `UNPROCESSED` source metadata. Each address gets its own attached input
device and mix route. No default microphone replacement or unqualified speaker
profile is needed for this first step. A new Cubs address namespace would make
target selection explicit instead of silently treating Frankel's port names as
a portable hardware contract.

The existing module is not otherwise drop-in: it couples input and output to
one 192000-Hz constant, and its output controls, two-slot geometry, PCM choice,
gain behavior and buffering are Frankel-specific. Cubs input and output rates
must be separate contracts; do not advertise native192 speaker bandwidth when
the amplifier or DSP path cannot deliver it. Read the current source constants
rather than older Frankel integration notes that describe superseded D0 and
buffer experiments.

`HD Mic gain (cB)` **does exist on Cubs**: live baseline control218, value0.
It is also the factory callback path used for cache synchronization. Its
presence was missed in an earlier case-sensitive inventory search; there is
no missing-control workaround to apply. Ordinary gain setters must not be
confused with cache-certification steps or issued gratuitously in realtime.

The essential unresolved integration boundary is ownership. Starting the stock
HAL and audioserver while this experimental shared mono profile is resident is
not currently safe. A sidecar-local mutex does not prevent the proprietary
HAL from opening its D10 fast-capture path or rewriting shared microphone
controls. Establish a target-proven quarantine/arbitration contract for every
conflicting capture path, including stock access to D10 itself, before
releasing Android clients. Preserve ordinary output and startup discovery only
once their coexistence has been demonstrated. A generation change must revoke
research readiness, and a failed volatile mutation must not release normal
audio into unknown firmware state.

The existing test app's ordinary Java48k playback/reference and UI-effect
activities are reusable. Its research endpoint allowlists, native AAudio
192000-Hz checks, three fixed D10 addresses, two Frankel output addresses, and
automated target/readiness/sysfs checks need explicit Cubs profiles. Validate
Java `AudioRecord(UNPROCESSED)` and AAudio input separately for every logical
mic. Playback/API-rate generalization should wait for a physically qualified
speaker route. No global framework or AudioFlinger source change is indicated
by the present evidence.
