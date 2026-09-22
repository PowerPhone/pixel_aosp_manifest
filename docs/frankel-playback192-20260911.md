# Frankel native-192 kHz playback investigation — 2026-09-11

September 12 follow-up: the user reported inaudible ordinary UI sounds. See
[the gain-correction investigation](frankel-ordinary-audio-fix-20260912.md).
The ordinary route's introduced amplifier attenuation was not covered by the
long-tone qualification below. In particular, the weak 66.547 kHz recording
must not be treated as proof of airborne speaker output; the existing
on-device self-loop controls do not completely exclude electrical coupling.

Status: **native 192 kHz playback on both physical speakers and sequential
research↔ordinary handoffs are verified on the final standby-zero image
within the hardware/API intervals reported here**. The flashed vendor uses
`ro.audio.flinger_standbytime_ms=0` with the unchanged RT-period-worker
kernel. Its four-segment handoff test, volume-controlled two-minute bottom
AAudio run, 30-second earpiece AAudio run and three 54.283 kHz response tests
pass. The final volume-restoration sequence also has fresh completion records
and no PCM/ownership/app-crash errors, with UI, readiness and services healthy.

**Simultaneous ordinary-primary and research-BUS playback is unsupported.**
The supported result is completed sequential playback/handoff, not concurrent
ownership of the shared physical route. Ultrasonic results establish the
intended component through the combined playback/recording path, not a
calibrated response to 96 kHz.

Earlier failures remain unchanged: the preceding vendor's route collision,
invalid-timing handoff attempts, and incorrectly attenuated BUS measurements
are not relabeled as passes. Earlier direct-ALSA and API results identify
their original vendor revision; the standby-zero image is qualified by its
own completed tests and full post-restoration error-log review.

This is not a blanket zero-jitter, calibrated-clock, flat-to-96-kHz response,
or all-microphone-API qualification. The pre-standby-zero level-0.08 two-minute API
recording **retains its fixed-gate FAIL** for one short phase event despite
clean native/HAL evidence. The level-0.16 repeat passes the same thresholds
for 119.89 analyzed seconds; transient diagnosis is a separate measurement
limitation, not a relabeling of that failure or proof of its exact origin.
Earlier EPIPEs and Java D10 reference-capture gaps remain documented.

The report is chronological: candidate sections retain their stage-specific
failures and incomplete qualifications. The final installed-image results
and scope are consolidated in the final bundled-image section below.

This report supersedes earlier claims that accepting 192 kHz PCM, reporting
192 kHz in logs, or producing a WAV of the expected length established a
correct 192 kHz playback chain. Those checks missed real pitch/cadence faults.
It does not retract the independently investigated microphone capture path.

## Five faults corrected

Addresses below are specific to Frankel's CP2A.260805.005 AoC firmware;
they are not portable offsets for other devices or firmware releases.

| Fault | Live-path correction |
| --- | --- |
| H0 speaker Configure still selected a 10 ms/480-frame block. Blindly multiplying that block by four exceeded its output ring capacity. | For source 5, sink 0 and rate enum 7 only, select a 1 ms Configure period. The conditional H0 geometry hook then selects 192 frames/`0x600` bytes. Update F1's two scheduling/accounting comparisons from the stock `0x180` expectation to `0x600` under the same scope. |
| F1's primary mixer still iterated 48 frames and laid out four words per frame. | Raise the loop to 192 frames at `0x403d3a78/7c` and pack the primary stereo pair with an eight-byte stride at `0x403d3b08`. The existing `0xc00` source allocation contains the intermediate tail. |
| The constructed speaker object retained a `0x300` TX ping-pong offset/notify extent. An earlier compensating cache patch did not repair that object geometry. | Set speaker object `0x4051b0b8 + 0x2a8` to `0x600`, matching 192 stereo S32 frames. Restore the stock cache-call instructions at `0x403d3de8/ec/f0`, so their extent comes from the corrected field exactly once. |
| The nested SRAM-read trampoline read 192 frames, but its enclosing caller retained 48 for copying and advancing the source ring. | Change the speaker caller at `0x403d3938`, using the cave at `0x403d3878`, so the same 192-frame count survives through read, copy and cursor advancement. The earlier HF-ring surplus was `0x480` bytes per call: `(192−48) × 8`. |
| The two-slot PL330 TX program loaded 16 bytes but stored only eight bytes per load/store pair. | Change the source-width instruction at `0x403aa510`: CCR becomes `0x00054007`, replacing `0x00054009`. Each memory load and pair of S32 peripheral stores now transfers eight bytes. Reopening D5 regenerates the DMA program. |

The period-one change avoids the rejected all-period H0 expansion: a
`0x3c00` write block cannot fit the observed `0x1e00` H0 ring. It also avoids
calling the H0 worker four times through an unqualified wrapper. The source
and reasoning are retained in the
[H0 handoff notes](../work/audio-research/frankel/pitch-validation/h0-handoff-20260911/README.md)
and [period-one assembly](../tools/audio/asm/frankel_aoc_speaker_period1_candidate.S).

The reproducible device helper is
[`frankel_aoc_speaker_patch`](../tools/audio/device/frankel_aoc_speaker_patch/).
The five exploratory overlays remain under `tools/audio/patch_frankel_aoc_*`
as the record of how the live candidate was assembled; they are not five
independent boot services or interchangeable release profiles.

## Processing and transfer conditions

The initial live-patch hardware measurements used:

- Playback PCM0,D5, stereo S32_LE, 192,000 frames/s; 1,920-frame periods,
  two periods, and a full-ring 3,840-frame start threshold.
- A blocking raw-WRITEI producer under `chrt -f 2` (SCHED_FIFO priority 2).
- EP6 routing and `AoC Speaker Mixer ASP Mode=ASP_BYPASS`, selected before
  activation. Stock AMixSPKR effects retain 48 kHz processing assumptions;
  bypass keeps those effects out of the research speaker path.
- The selected Cirrus amplifier enabled, normal `PCM Source=ASPRX1`,
  `High Rate PCM Source=Zero`, `Ultrasonic Mode=Disabled`, and selected
  `Digital PCM Volume=817`. The inactive endpoint is not used as a speaker.
- Capture PCM0,D10, mono S16_LE at 192,000 frames/s, 1,920 × four periods,
  RAW microphone processing, with a quiet lead before the stimulus.
- No live firmware/mixer dumps during the successful continuity run. Earlier
  diagnostic traffic during playback could induce EPIPE and was removed
  from the measurement interval.

The raw writer also needed a userspace correctness fix: a successful
`SNDRV_PCM_IOCTL_WRITEI_FRAMES` ioctl can return a **positive short frame
count**. The player now advances by that accepted count and submits only the
unaccepted suffix. It never resends an accepted prefix, treats zero or invalid
progress as failure, and preserves the suffix position across bounded EFAULT
retries. EPIPE is not silently converted into a successful continuous run.
See [the staged player](../tools/audio/device/frankel_aoc_staged_play/frankel_aoc_staged_play.cpp).

The sidecar and ordinary primary/deep speaker routes now select ASP bypass;
the sidecar snapshots the old mode and restores it after hard-off while its
ownership checks still pass. Its start threshold is also 3,840 frames. The
sidecar's existing worker policy remains FIFO/90, distinct from the FIFO/2
direct measurement above; rebuilt-HAL and cold-boot results must be recorded
separately. These output changes do not alter microphone or Bluetooth paths.
The subsequent 192 × twenty-period direct trials are described separately
below; do not confuse their one-millisecond notification granularity with
the initial ten-millisecond period setting.

## Recorded results and WAV files

All links below point into the local research workspace. WAVs and extracted
firmware are not implicitly included in the public Git repository. Each
session directory contains `stimulus.wav`, `capture.wav`, mixer snapshots,
`session.txt`, and spectral/phase analysis output.

| Playback and microphone | Requested frequency | Measured spectral peak | Component rise over quiet lead | Evidence |
| --- | ---: | ---: | ---: | --- |
| Bottom speaker → logical mic 0; 15 s stimulus | 12,000 Hz | 11,999.999466 Hz over full active interval | +68.83 dB in the two-second comparison window | [Recorded WAV](../work/audio-research/frankel/pitch-validation/f1-copy-dma-rt-prefill-20260911/capture.wav), [stimulus WAV](../work/audio-research/frankel/pitch-validation/f1-copy-dma-rt-prefill-20260911/stimulus.wav), [analysis](../work/audio-research/frankel/pitch-validation/f1-copy-dma-rt-prefill-20260911/tone-analysis.json) |
| Earpiece → logical mic 1 | 54,283 Hz | 54,283.004232 Hz | +20.63 dB | [Recorded WAV](../work/audio-research/frankel/pitch-validation/f1-54283-earpiece-a25-20260911/capture.wav), [stimulus WAV](../work/audio-research/frankel/pitch-validation/f1-54283-earpiece-a25-20260911/stimulus.wav), [analysis](../work/audio-research/frankel/pitch-validation/f1-54283-earpiece-a25-20260911/tone-analysis.json) |
| Bottom speaker → logical mic 0 | 54,283 Hz | 54,283.000169 Hz | +33.40 dB | [Recorded WAV](../work/audio-research/frankel/pitch-validation/f1-54283-bottom-a25-20260911/capture.wav), [stimulus WAV](../work/audio-research/frankel/pitch-validation/f1-54283-bottom-a25-20260911/stimulus.wav), [analysis](../work/audio-research/frankel/pitch-validation/f1-54283-bottom-a25-20260911/tone-analysis.json) |
| Bottom speaker → logical mic 0; weak result | 66,547 Hz | 66,546.982376 Hz | +7.61 dB | [Recorded WAV](../work/audio-research/frankel/pitch-validation/f1-66547-bottom-a25-20260911/capture.wav), [stimulus WAV](../work/audio-research/frankel/pitch-validation/f1-66547-bottom-a25-20260911/stimulus.wav), [analysis](../work/audio-research/frankel/pitch-validation/f1-66547-bottom-a25-20260911/tone-analysis.json) |

For the 12 kHz run, the analyzer retained the entire 14.89-second active
interior after excluding 50 ms at each outer boundary. It reported zero
amplitude-dropout blocks, zero phase steps above 0.35 radians, zero clipped
samples, and a maximum phase step of 0.03272 radians across 250 µs blocks.
The strongest spur was −54.84 dBc over that interval. Playback and capture
both exited successfully; the live producer reported zero xruns. The
two-second comparison interval also had zero detected phase/dropout events.

The 54.283 kHz figures are narrowband spectral detection results, not
broadband SNR or calibrated acoustic level. In both files the short-window
phase estimator was noise-dominated, and the full-interval estimator marked
the tone `measurable=false` for its stricter temporal test. Its phase-jump and
dropout counters therefore do **not** establish either ultrasonic jitter or
jitter-free ultrasonic output. Use the higher-SNR 12 kHz run for the stated
continuity result. The additional 66.547 kHz bottom-speaker result is only
+7.61 dB above its quiet-lead bin and is labeled weak, not strong bandwidth
qualification; its short-window phase/dropout metrics are likewise unsuitable
for a continuity claim.

## First post-flash results: producer-wake issue and 192-frame periods

The integrated image booted and reproduced the pitch fix. A post-flash
15-second 12 kHz bottom-speaker run retained 14.88 seconds of active audio:
measured peak 12,000.000027 Hz, zero phase steps above 0.35 radians, zero
amplitude-dropout blocks, zero clipped samples, and maximum phase step
0.03768 radians. Both streams exited successfully.
See the [post-flash WAV](../work/audio-research/frankel/pitch-validation/packaged-12k-bottom-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/packaged-12k-bottom-20260911/tone-analysis.json),
and [session](../work/audio-research/frankel/pitch-validation/packaged-12k-bottom-20260911/session.txt).

That success did not establish reliable operation for every reopen:

| Post-flash trial with 1,920 × two periods | Result | Evidence |
| --- | --- | --- |
| 12 kHz bottom, FIFO/2, 15-second stimulus | Pass; continuity figures above | [Session directory](../work/audio-research/frankel/pitch-validation/packaged-12k-bottom-20260911/) |
| 54.283 kHz earpiece, FIFO/2 | EPIPE; playback exited with status 1 | [Session](../work/audio-research/frankel/pitch-validation/packaged-54283-earpiece-20260911/session.txt), [log](../work/audio-research/frankel/pitch-validation/packaged-54283-earpiece-20260911/logcat.txt) |
| 54.283 kHz earpiece, FIFO/90 | Pass for the five-second stimulus | [Session](../work/audio-research/frankel/pitch-validation/packaged-54283-earpiece-rt90-20260911/session.txt) |
| 54.283 kHz bottom, FIFO/90 | EPIPE; playback exited with status 1 | [Session](../work/audio-research/frankel/pitch-validation/packaged-54283-bottom-rt90-20260911/session.txt), [log](../work/audio-research/frankel/pitch-validation/packaged-54283-bottom-rt90-20260911/logcat.txt) |

The failing bottom log reports `DeepBuffer, ZeroEP 192 frames, count: 1`
immediately before teardown: the AP/source-5 queue actually emptied. There
is no corresponding midstream H0 reset or HF-ring overrun. Passing and
failing runs share H0's 192-frame/ms geometry, a benign activation-time HF
underrun, and startup core-clock warnings. The 15-second pass reports exactly
5,000 H0 blocks per five seconds. These observations do not support undoing
the pitch fixes or enlarging H0's ring.

D5 remains mailbox/interrupt-driven. The 1,920-frame ALSA period requests
the firmware's threshold of 15,360 bytes out of a 30,720-byte AP ring. The
current direct experiment changes the period to 192 frames and the count
to twenty, retaining exactly the same total buffer. Firmware then reports
threshold **29,184 of 30,720** (`buffer_bytes − period_bytes`), requesting
earlier refill notifications at one-millisecond consumption increments.
This targets the producer-wake boundary, not a hidden sample-rate conversion
or a larger-than-supported allocation. The precise lost/late-wake mechanism
is still under investigation; the initial short pass alone does not prove it.

The first 192 × twenty-period, FIFO/90 bottom-speaker trial completed a
five-second 54.283 kHz stimulus with playback/capture status 0/0. The detected
peak was 54,282.994780 Hz, +32.84 dB above its quiet-lead bin. As with the
other ultrasonic results, this is point-frequency detection, not a
short-window phase/jitter claim.
See the [WAV](../work/audio-research/frankel/pitch-validation/period192-bottom-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/period192-bottom-20260911/tone-analysis.json),
and [threshold log](../work/audio-research/frankel/pitch-validation/period192-bottom-20260911/logcat.txt).

A 30-second 12.037 kHz bottom-speaker soak with this geometry subsequently
completed with playback/capture status 0/0. The producer accepted all
5,760,000 frames in 30,000 WRITEI calls, with zero positive short writes and
zero xruns. Acoustic analysis covered 29.89 active seconds and 119,559
adjacent phase pairs: measured peak 12,036.999934 Hz, zero phase steps above
0.35 radians, zero dropout blocks, zero clipping, and maximum phase step
0.04073 radians. This is a bounded continuity pass for that run.
See the [recorded WAV](../work/audio-research/frankel/pitch-validation/period192-bottom-soak-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/period192-bottom-soak-20260911/tone-analysis.json),
[producer log](../work/audio-research/frankel/pitch-validation/period192-bottom-soak-20260911/playback.log),
and [session](../work/audio-research/frankel/pitch-validation/period192-bottom-soak-20260911/session.txt).

The equivalent earpiece run also completed all 5,760,000 frames in 30,000
WRITEI calls, with zero short writes and zero xruns; device playback and
capture both returned 0. Its 29.89-second acoustic interval contained
119,559 phase pairs, measured peak 12,037.000017 Hz, zero phase steps above
0.35 radians, zero dropout blocks, zero clipping, and maximum phase step
0.08163 radians. However, the host script was edited while running and
encountered a Bash parsing error **after retrieving the device files**.
Hardware completion and the saved acoustic analysis remain valid evidence,
but the overall host collection did not finish cleanly. Cleanup restored
the audio services, and AoC restart/coredump counters remained 0/0. A clean
post-flash repeat subsequently passed, as recorded in the next section.
See the [earpiece WAV](../work/audio-research/frankel/pitch-validation/period192-earpiece-soak-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/period192-earpiece-soak-20260911/tone-analysis.json),
[producer log](../work/audio-research/frankel/pitch-validation/period192-earpiece-soak-20260911/playback.log),
and [session](../work/audio-research/frankel/pitch-validation/period192-earpiece-soak-20260911/session.txt).

These first 192 × twenty-period runs used the already-flashed firmware fixes
with an explicitly selected direct-player geometry. The following image
integration carried this geometry into the sidecar and primary HAL.

## Second image flash and Android API results

The updated image flash completed in **33.594 seconds**. Its clean boot had
SELinux Enforcing, `/vendor` mounted read-only without an overlay, bootstrap
phase `complete`, and AoC restart/coredump counters 0/0. Those observations
establish that these trials used boot-integrated changes, rather than a
post-boot writable-vendor overlay or a host-applied firmware experiment.
They do not qualify every Android audio path by themselves.

The clean post-flash earpiece raw-player repeat completed a 30-second
12.037 kHz stimulus using 192 × twenty periods and full 3,840-frame start
threshold. All 5,760,000 frames were accepted in 30,000 WRITEI calls with
zero short writes, retries, or xruns; playback and capture both exited 0.
Acoustic analysis retained 29.89 seconds and 119,559 phase pairs: peak
12,037.000097 Hz, zero phase steps above 0.35 radians, zero dropout blocks,
zero clipping, and maximum phase step 0.03927 radians. Unlike the earlier
earpiece soak, this host collection completed cleanly.
See the [earpiece WAV](../work/audio-research/frankel/pitch-validation/final-image-earpiece-soak-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/final-image-earpiece-soak-20260911/tone-analysis.json),
[producer log](../work/audio-research/frankel/pitch-validation/final-image-earpiece-soak-20260911/playback.log),
and [session](../work/audio-research/frankel/pitch-validation/final-image-earpiece-soak-20260911/session.txt).

The Android API tests distinguish the playback API from the reference
capture API; a corrupted reference cannot silently be treated as clean
speaker evidence:

| Playback/reference combination | Current result | Evidence |
| --- | --- | --- |
| Ordinary primary Java AudioTrack, 192 kHz client; raw tinycap D10 at 192 kHz | Eight-second run passed. Over 7.90 active seconds: 11,999.999553 Hz for requested 12 kHz, 31,599 phase pairs, zero phase steps/dropout blocks/clipping, maximum phase step 0.08057 rad. | [WAV](../work/audio-research/frankel/pitch-validation/final-primary192-raw-d10-20260911/capture.wav), [analysis](../work/audio-research/frankel/pitch-validation/final-primary192-raw-d10-20260911/tone-analysis.json), [session](../work/audio-research/frankel/pitch-validation/final-primary192-raw-d10-20260911/session.txt) |
| Ordinary primary Java AudioTrack, 48 kHz client; raw tinycap D10 at 192 kHz | Correct 12 kHz pitch, but **not continuity-qualified**: one 1 ms dropout across four 250 µs blocks and three detected phase steps over the 7.90-second interval. | [WAV](../work/audio-research/frankel/pitch-validation/final-primary48-raw-d10-20260911/capture.wav), [analysis](../work/audio-research/frankel/pitch-validation/final-primary48-raw-d10-20260911/tone-analysis.json) |
| Earlier AudioTrack playback with concurrent Java D10 reference capture | Many discontinuities: the linked eight-second interval has 63 distinct dropout events across 79 blocks and 204 phase steps. This combined API path is **not continuity-qualified**; raw-reference results above must not be assigned to it. | [Earlier combined-reference analysis](../work/audio-research/frankel/pitch-validation/period192-api-primary48-live-20260911/tone-analysis.json) |

The proprietary primary HAL explicitly calls `pcm_start()`, which can start
the stream before the full-buffer threshold has been reached. The latest
correction gates that explicit start only for the selected D1/D5 paths,
allowing WRITEI to fill all 3,840 frames before automatic start. A live
bind-mounted HAL trial under SELinux Enforcing then passed the ordinary
48 kHz AudioTrack/raw-D10-reference repeat: 384,000 client frames in
8,004 ms, zero AudioTrack underruns, and 7.90 analyzed active seconds at
11,999.999536 Hz with zero phase steps/dropout blocks/clipping. Its maximum
phase step was 0.01647 radians.
See the [prefill-fix WAV](../work/audio-research/frankel/pitch-validation/prefill-primary48-raw-d10-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/prefill-primary48-raw-d10-20260911/tone-analysis.json),
and [API log](../work/audio-research/frankel/pitch-validation/prefill-primary48-raw-d10-20260911/logcat.txt).
This successful live trial does not yet qualify the rebuilt vendor image,
which must be flashed and retested, or explain every earlier Java reference
capture gap.

The first bottom AAudio/raw-reference run reported the correct 12.037 kHz
component and zero AAudio xruns, but the captured tone was only −89.61 dBFS.
Its full-interval analyzer marked the signal
`measurable=false`, so **no acoustic-continuity pass is claimed** for it.
See its [WAV](../work/audio-research/frankel/pitch-validation/final-aaudio-bottom-12037-20260911/capture.wav)
and [analysis](../work/audio-research/frankel/pitch-validation/final-aaudio-bottom-12037-20260911/tone-analysis.json).
The persistent approximately 33 dB reduction was explained by Android's
per-device volume: the active BUS still had media volume **8/25**. Setting
the ordinary speaker to 25 did not change that BUS's volume. Setting volume
25 while the bottom BUS was active removed the attenuation, without
changing the 0.08 stimulus amplitude or interpreting a weak recording as a
hardware bandwidth failure.

The resulting bottom AAudio/raw-D10-reference run passed its **7.89-second
active acoustic interval**: peak 12,036.999346 Hz for requested 12.037 kHz,
31,559 phase pairs, zero phase steps above 0.35 radians, zero dropout blocks,
zero clipping, and maximum phase step 0.03174 radians. AAudio reported
`AAUDIO_RUN_OK` and xrun delta/total 0/0. However, the sidecar subsequently
logged EPIPE after stop: `AAudioStream_requestStop` at 08:06:16.954,
application completion at 08:06:17.010, and the HAL's `status=-32` at
08:06:17.047. This is a clean active-tone result, **not a clean stop/reopen
lifecycle qualification**.
See the [AAudio WAV](../work/audio-research/frankel/pitch-validation/aaudio-bottom-bus25-12037-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/aaudio-bottom-bus25-12037-20260911/tone-analysis.json),
and [ordered API/HAL log](../work/audio-research/frankel/pitch-validation/aaudio-bottom-bus25-12037-20260911/logcat.txt).
Subsequent sidecar trials changed the profile to positional `LAYOUT_STEREO`
and compared framework/FMQ sizes, as recorded below. The volume finding
must not be mislabeled as proof of a channel-mask or buffer fix.
Directory names beginning `final-` identify collected candidates and are
not a declaration of final release status.

A subsequent ordinary-primary AAudio 54.283 kHz run detected
54,282.998565 Hz, +46.61 dB above its quiet-lead bin, with native xrun
delta/total 0/0. The primary HAL consistently reported 192,000 Hz, two
channels, **PCM_FLOAT** before and after start. The old app incorrectly
required PCM_I32 for every output and therefore logged only
`hardware_format_mismatch,post_start_hardware_format_mismatch`; retain this
as a point-frequency acoustic pass with an old-validator failure, not a
retroactive `AAUDIO_RUN_OK` or continuity qualification.
See the [primary AAudio WAV](../work/audio-research/frankel/pitch-validation/primary-aaudio-54283-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/primary-aaudio-54283-20260911/tone-analysis.json),
and [API report](../work/audio-research/frankel/pitch-validation/primary-aaudio-54283-20260911/logcat.txt).
The rebuilt app permits declared output PCM_FLOAT or PCM_I32 while requiring
unchanged pre/post-start format, exact 192 kHz/two channels, and all existing
route/xrun/timestamp checks. D10 input remains strictly PCM_I16. Primary HAL
float-to-integer conversion is an internal representation choice, not
physical DAC evidence; the recorded stimulus component supplies the
point-frequency self-loop evidence.

## Sidecar framework cadence: 960-frame candidate

The physical ALSA geometry remains **192 frames × twenty periods**, with
3,840 frames/30,720 bytes total and a full-ring start threshold. Framework
buffer experiments change AudioFlinger's transfer and idle-refill cadence,
not the speaker sample rate or the physical ring's capacity:

| Sidecar framework/FMQ size | Observed result | Status |
| --- | --- | --- |
| 3,840 frames / 20 ms | Failed during idle after approximately 1.6 seconds. | Rejected as a reliable stop/idle configuration; [trial](../work/audio-research/frankel/pitch-validation/fmq20-aaudio-bottom-12037-20260911/). |
| 192 frames / 1 ms | One active-playback failure and one clean repeat. | Not consistently qualified; [first trial](../work/audio-research/frankel/pitch-validation/fmq1-aaudio-bottom-12037-20260911/), [repeat](../work/audio-research/frankel/pitch-validation/fmq1-aaudio-bottom-repeat-20260911/). |
| 960 frames / 5 ms | Consecutive 30-second bottom AAudio and Java earpiece live-HAL runs passed without a HAL restart; the subsequent packaged-image bottom soak failed after approximately 23.4 seconds. | Not verified; kernel notification-starvation investigation continues below. |

The 960-frame size is below the normal 3,840-frame mixer quantum and selects
the FastMixer path in this configuration, supplying refill opportunities
inside the physical ring's 20 ms capacity. Positional `LAYOUT_STEREO` is used
consistently by both Java playback activities, AAudio, and the sidecar. The
sidecar also retains an accepted-source-frame counter across transfer calls:
the bounded second-write EFAULT allowance is attached to the actual startup
frame position, rather than being lost or restarted at each framework burst.
It does not authorize re-preparing a live stream, retrying arbitrary later
errors, or treating an xrun as success.

For the first 960-frame AAudio bottom soak, all 5,760,000 target frames were
transferred, native xrun delta/total was 0/0, and `AAUDIO_RUN_OK` was reported.
The acoustic analysis retained 29.86 seconds and 119,439 phase pairs:
12,036.999846 Hz for requested 12.037 kHz, zero phase steps above 0.35 radians,
zero dropout blocks, zero clipping, and maximum phase step 0.03750 radians.
The collected HAL playback-error file is empty, including the post-stop
quiet tail. This qualifies that entire run/tail, not every future reopen or
an image that has not yet been flashed.
See the [WAV](../work/audio-research/frankel/pitch-validation/fmq5-aaudio-bottom-soak-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/fmq5-aaudio-bottom-soak-20260911/tone-analysis.json),
[API log](../work/audio-research/frankel/pitch-validation/fmq5-aaudio-bottom-soak-20260911/logcat.txt),
and [HAL error inventory](../work/audio-research/frankel/pitch-validation/fmq5-aaudio-bottom-soak-20260911/hal-playback-errors.txt).

The following Java earpiece run also passed, **without a HAL restart between
the two routes**. The app wrote and played all 5,760,000 frames in 30,005 ms,
reported zero AudioTrack underruns, and reached `STOCK_PLAYBACK_COMPLETE`.
Its independent raw-D10 acoustic analysis retained 29.90 seconds and 119,599
phase pairs; the collected HAL playback-error inventory was again empty
through the quiet tail:

| Consecutive 960-frame run | Measured 12.037 kHz carrier | Active interval | Phase steps >0.35 rad / dropout blocks / clipped samples | Maximum phase step |
| --- | --- | --- | --- | --- |
| Bottom, AAudio | 12,036.999846 Hz | 29.86 s | 0 / 0 / 0 | 0.03750 rad |
| Earpiece, Java AudioTrack | 12,036.999998 Hz | 29.90 s | 0 / 0 / 0 | 0.05203 rad |

See the second run's [WAV](../work/audio-research/frankel/pitch-validation/fmq5-java-earpiece-soak-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/fmq5-java-earpiece-soak-20260911/tone-analysis.json),
[API log](../work/audio-research/frankel/pitch-validation/fmq5-java-earpiece-soak-20260911/logcat.txt),
and [HAL error inventory](../work/audio-research/frankel/pitch-validation/fmq5-java-earpiece-soak-20260911/hal-playback-errors.txt).
The [AudioFlinger after-dump](../work/audio-research/frankel/pitch-validation/fmq5-java-earpiece-soak-20260911/audio-flinger-after.txt)
confirms both BUS outputs at 192,000 Hz, positional stereo, HAL frame count
960, normal frame count 3,840, and FastMixer. Its cumulative FastMixer
scheduling counters are not all zero; the zero-error claims above refer to
the app/native xrun reports, collected HAL playback errors, and measured
active acoustic intervals, not every AudioFlinger diagnostic counter.

These two clean live-HAL runs did not qualify the packaged image: its
subsequent post-flash failure is recorded separately below. No qualification
is inherited from the superseded 192- or 3,840-frame FMQ trials.

## Packaged 960-frame image: failed post-flash qualification

The packaged candidate booted with `sys.boot_completed=1`, speaker-helper
readiness 1, SELinux Enforcing, and AoC crash/restart counts 0/0. `/vendor`
was read-only without a runtime overlay, and the vendor-DLKM overlay was
empty. An earlier test attempt correctly aborted because the bootstrap was
not ready; it is not a playback result. The following test waited for
readiness and exercised the installed image rather than a temporary HAL
bind mount.

The 30-second, 192 kHz Java AudioTrack bottom-BUS test **failed during the
active tone**, approximately 23.4 seconds after playback started. AoC logged
`DeepBuffer, ZeroEP 192 frames, count: 1` at 08:35:02.192, followed by the
sidecar's PCM write `status=-32` (EPIPE) at 08:35:02.197. Nevertheless, Java
later reported all 5,760,000 frames written/played, elapsed time 29,734 ms,
zero AudioTrack underruns, and `STOCK_PLAYBACK_COMPLETE`. Those API counters
therefore do not establish successful physical playback. The measurement
harness retained `session_status=1` and the HAL failure inventory.

The recorded tone stops early: its outer detected interval is only 23.35
seconds, and the analyzer retains 23.25 seconds after excluding the two
50 ms boundaries. That surviving interval has the correct 12,036.999494 Hz
carrier and zero detected phase/dropout/clipping events, but **a clean prefix
is not a completed 30-second continuity pass**. The missing final portion
must not be hidden by quoting only the automatic active-interval metrics.
See the [failed-run WAV](../work/audio-research/frankel/pitch-validation/installed-fmq5-java-bottom-soak-ready-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/installed-fmq5-java-bottom-soak-ready-20260911/tone-analysis.json),
[API/kernel/AoC log](../work/audio-research/frankel/pitch-validation/installed-fmq5-java-bottom-soak-ready-20260911/logcat.txt),
[HAL failure inventory](../work/audio-research/frankel/pitch-validation/installed-fmq5-java-bottom-soak-ready-20260911/hal-playback-errors.txt),
and [measurement status](../work/audio-research/frankel/pitch-validation/installed-fmq5-java-bottom-soak-ready-20260911/measurement.txt).

The kernel log provides a specific starvation lead. In timestamp order,
`alsa: period work busy count` increases from 5 at 08:35:02.174 to 10, 15,
20 and finally 25 at 08:35:02.194, at five-millisecond intervals immediately
before EPIPE. With one-millisecond D5 periods, this is consistent with host
period notification remaining behind for approximately 25 ms—longer than
the physical ring's entire 20 ms capacity. The AoC zero-frame event and HAL
EPIPE occur in the same sequence. Raising an API buffer alone does not
remove that delayed kernel-work delivery path.

### Trace confirms pending-work dispatch delay

The subsequent ordinary-primary 48 kHz Java playback trial recorded actual
kernel workqueue queue/start/end events while capturing the acoustic
reference. The D5 work item, `alsa_pcm_period_work_5`, shows:

| D5 queued timestamp | Callback start | Pending before execution | Callback duration |
| --- | --- | --- | --- |
| 493.577075 s | 493.606813 s | 29.738 ms | 9 µs |
| 494.584166 s | 494.610798 s | 26.632 ms | 9 µs |

These intervals exceed the physical playback ring's 20 ms capacity **before
the callback even begins**. Across 31,863 captured D5 callbacks, the maximum
callback execution interval was only 1.809 ms. D10's separate period-work
item also experienced 24.838 ms pending dispatch. The trace therefore locates
these long stalls in the shared unbound-workqueue dispatch path, rather
than a callback spending 27–30 ms blocked on an ALSA lock. The queued work
items have separate ALSA workqueue names but execute through shared unbound
kernel workers. See the [kernel period trace](../work/audio-research/frankel/pitch-validation/period-worker-trace-primary48-20260911/kernel-period-trace.txt).

The corresponding acoustic trial **failed** the measurement gate: 1,246
phase steps above 0.35 radians and 456 dropout blocks (114 ms total) across
the full detected interval. Its 30.32-second analyzed duration also exceeded
the requested 30-second run's ±0.25-second acceptance window. A correct
11,999.999744 Hz carrier does not override these continuity failures.
See the [trace-run WAV](../work/audio-research/frankel/pitch-validation/period-worker-trace-primary48-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/period-worker-trace-primary48-20260911/tone-analysis.json),
and [failed qualification checks](../work/audio-research/frankel/pitch-validation/period-worker-trace-primary48-20260911/tone-qualification.json).
This is a diagnostic trace run, not an uninstrumented playback qualification.

The revised candidate uses a dedicated sleepable real-time period worker to
avoid the delayed shared-workqueue dispatch. Direct hard-IRQ period delivery
is not used: this PCM is configured with `pcm->nonatomic=1`, so its period
notification path must remain in a context where sleeping is permitted.
The RT-worker kernel was subsequently flashed and tested as recorded below.
Its hardware results do not establish a verified release or erase the failed
installed-package result.

## Flashed RT-period-worker kernel: bounded results and remaining failures

The RT-worker kernel booted under SELinux Enforcing. Primary and sidecar HALs
initially remained those in the previous vendor image, separating the kernel
change from later framework/scheduling experiments. All trials below requested
30 seconds and used an independent raw-D10 microphone reference. Frequencies
are full-active-interval estimates unless noted otherwise; zero-event rows
mean zero detected phase steps above 0.35 radians, dropout blocks and clipped
samples for that bounded interval.

| Actual trial | Measured carrier / active duration | Acoustic result | Qualification boundary and evidence |
| --- | --- | --- | --- |
| Raw D5 bottom playback | 12,036.999817 Hz / 29.89 s | PASS: 0 phase / 0 dropout / 0 clipping | Direct physical run, not an API-suite pass. [WAV](../work/audio-research/frankel/pitch-validation/rt-worker-raw-bottom-soak-20260911/capture.wav), [analysis](../work/audio-research/frankel/pitch-validation/rt-worker-raw-bottom-soak-20260911/tone-analysis.json). Its selected two-second estimate was 12,036.999773 Hz. |
| First Java bottom soak | Tone survives only 1.35 s in the analyzed interval | FAIL: active EPIPE | A clean short prefix cannot pass a 30-second request. [WAV](../work/audio-research/frankel/pitch-validation/rt-worker-java-bottom-soak-20260911/capture.wav), [HAL failures](../work/audio-research/frankel/pitch-validation/rt-worker-java-bottom-soak-20260911/hal-playback-errors.txt), [qualification](../work/audio-research/frankel/pitch-validation/rt-worker-java-bottom-soak-20260911/tone-qualification.json). |
| Java bottom, FMQ/scheduler tracing enabled | 12,036.999709 Hz / 29.90 s | PASS: 0 / 0 / 0 | Instrumented run; not a substitute for its untraced repeat. [WAV](../work/audio-research/frankel/pitch-validation/rt-worker-fmq-scheduler-trace-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/rt-worker-fmq-scheduler-trace-20260911/tone-qualification.json). |
| Java bottom, untraced repeat | 12,036.999664 Hz / 29.90 s | PASS: 0 / 0 / 0 | Clean repeat with `session_status=0`; does not erase the earlier EPIPE. [WAV](../work/audio-research/frankel/pitch-validation/rt-worker-java-bottom-repeat-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/rt-worker-java-bottom-repeat-20260911/tone-qualification.json). |
| AAudio earpiece | 12,037.000034 Hz / 29.86 s | Physical PASS: 0 / 0 / 0 | Zero native xruns and no collected HAL playback errors, but old app timestamp-rate check FAIL; not an API PASS. [WAV](../work/audio-research/frankel/pitch-validation/rt-worker-aaudio-earpiece-soak-20260911/capture.wav), [analysis](../work/audio-research/frankel/pitch-validation/rt-worker-aaudio-earpiece-soak-20260911/tone-analysis.json), [API log](../work/audio-research/frankel/pitch-validation/rt-worker-aaudio-earpiece-soak-20260911/logcat.txt). |
| Java earpiece, runtime mode-10 hint | 12,037.000010 Hz / 29.90 s | FAIL: 16 phase events / 0 dropout | Additive-transient diagnosis below does not change FAIL. [WAV](../work/audio-research/frankel/pitch-validation/rt-worker-hint-java-earpiece-soak-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/rt-worker-hint-java-earpiece-soak-20260911/tone-qualification.json). |
| Ordinary primary 48 kHz client, runtime hint | 11,999.999905 Hz / 30.13 s | FAIL: 603 phase events / 306 dropout blocks | Correct pitch, failed continuity. [WAV](../work/audio-research/frankel/pitch-validation/rt-worker-hint-primary48-soak-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/rt-worker-hint-primary48-soak-20260911/tone-qualification.json). |
| Ordinary primary 48 kHz client, FIFO/90 set before open | 11,999.999710 Hz / 29.91 s | FAIL: 18 phase events / 21 dropout blocks | Improvement is not a pass. [WAV](../work/audio-research/frankel/pitch-validation/rt-worker-primary-fifo90-before-open-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/rt-worker-primary-fifo90-before-open-20260911/tone-qualification.json). |
| Ordinary primary 48 kHz client, FIFO/90 plus FMQ960 | 11,999.999711 Hz / 29.90 s | PASS: 0 / 0 / 0 | First successful candidate run; no collected HAL playback errors, `session_status=0`. [WAV](../work/audio-research/frankel/pitch-validation/primary-fifo90-fmq960-soak-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/primary-fifo90-fmq960-soak-20260911/tone-qualification.json), [HAL error inventory](../work/audio-research/frankel/pitch-validation/primary-fifo90-fmq960-soak-20260911/hal-playback-errors.txt). |

The mode-10 runtime hint was observed to change the two monitored sysfs values
from **10,000 / 15,000 to 1,500,000 / 1,500,000**. It was held during the
hint-labeled investigations; these are not no-hint baseline or cold-boot
default results. The [before/after readback](../work/audio-research/frankel/pitch-validation/rt-worker-audio-idle-hint-20260911.txt)
records the actual state change, not just successful submission of a request.

The earpiece hint trial's 16 short-window phase events cluster around two
transients. Its [diagnostic analysis](../work/audio-research/frankel/pitch-validation/rt-worker-hint-java-earpiece-soak-20260911/transient-diagnosis.json)
finds increased residual energy mainly around 5–10 kHz, with before/after
carrier phase differences of only +0.00280 and −0.00073 radians and essentially
unchanged carrier amplitude. This favors additive off-carrier contamination
of the 250 µs phase estimator over a persistent sample slip. The source is
unidentified, a brief canceling phase excursion is not excluded, and the
original fixed-threshold qualification **remains FAIL**. Diagnostic changes
to demodulation windows do not replace or relax that gate.

The physically clean AAudio earpiece run exposed a separate test-app issue:
the original first-two-second timestamp probe used 7,680 frames at
433835720069 ns and 384,960 at 435856217102 ns, deriving 186,726.332 Hz while
ignoring the rest of the run. The rebuilt app now samples playback every
100 ms over the full run, uses a predetermined one-second warmup, retains
all raw observations, fits every distinct valid steady pair, and preserves
the strict 1% rate limit plus monotonicity/availability/coverage checks.
Capture timestamp behavior is unchanged. This app correction does not
retroactively turn the recorded `timestamp_rate_mismatch` into `AAUDIO_RUN_OK`.
It also does not convert the sidecar's software presentation model into
hardware-counter evidence; the independent acoustic WAV supplies the
physical result.

The ordinary-primary candidate increases its framework buffer from 192 to
960 frames and uses FIFO/90 scheduling. Its first 30-second 48 kHz-client
trial now passes, as recorded in the final table row above. The physical
192 × twenty-period ring remains unchanged. This is one successful candidate
run awaiting repeat and packaging qualification, not a final image; neither
manual scheduler improvement nor a clean neighboring trial is sufficient
to qualify the earlier failed primary or earpiece run.

## Full-run AAudio evidence and post-RT ultrasonic checks

The first bottom AAudio trial using full-run timestamp sampling still
**failed physically**, with EPIPE after approximately 3.2 seconds and only
3.13 seconds retained by the acoustic analyzer. Its reported timestamp
regression was 201,977.520 Hz, outside the unchanged 1% gate; a long fit did
not turn the HAL's subsequent error/discard behavior into a valid clock.
The large burst of raw timestamp log lines also hid the native footer through
log throttling. None of those reporting problems changes the HAL/acoustic
failure. See the [failed WAV](../work/audio-research/frankel/pitch-validation/rt-worker-aaudio-bottom-fulltimestamps-20260911/capture.wav),
[failed duration qualification](../work/audio-research/frankel/pitch-validation/rt-worker-aaudio-bottom-fulltimestamps-20260911/tone-qualification.json),
and [original log](../work/audio-research/frankel/pitch-validation/rt-worker-aaudio-bottom-fulltimestamps-20260911/logcat.txt).

The app now saves the entire native report before logging its result marker
and compact summary. It invalidates the previous file at launch, records a
unique run ID, and marks the file `RETURNED` only when native execution
returns. The framework harness pulls that report even after failures and
requires its ID to match the current app-begin log. Missing, stale, incomplete
or failed native reports fail the session; quiet-tail HAL errors and full
acoustic qualification remain separate required checks.

With sidecar timing diagnostics enabled, a subsequent **30-second bottom
AAudio run passed all three checks**:

- All 5,760,000 target frames transferred, exact 192,000 Hz/two-channel
  PCM_I32 HAL format, stable route, native xrun delta/total 0/0 and
  `AAUDIO_RUN_OK`.
- All 288 distinct valid steady timestamp observations were used, covering
  28.800 seconds after the fixed one-second warmup. No duplicate, unavailable
  or nonmonotonic steady pairs; maximum fresh-sample gap 101.630 ms and
  regression rate 192,000.460 Hz.
- Independent acoustic interval 29.86 seconds, 12,036.999865 Hz carrier,
  zero phase events/dropout blocks/clipped samples, maximum phase step
  0.05338 radians. The HAL-error inventory is empty and `session_status=0`.

The [complete native report](../work/audio-research/frankel/pitch-validation/sidecar-timing-aaudio-bottom-20260911/native-report.txt)
and [run-ID validation](../work/audio-research/frankel/pitch-validation/sidecar-timing-aaudio-bottom-20260911/native-report-status.txt)
retain the raw API evidence. The [WAV](../work/audio-research/frankel/pitch-validation/sidecar-timing-aaudio-bottom-20260911/capture.wav),
[acoustic qualification](../work/audio-research/frankel/pitch-validation/sidecar-timing-aaudio-bottom-20260911/tone-qualification.json),
and [HAL-error inventory](../work/audio-research/frankel/pitch-validation/sidecar-timing-aaudio-bottom-20260911/hal-playback-errors.txt)
support the other two checks. The diagnostic HAL reported a maximum
inter-transfer gap of 2,745 µs at cleanup; that wall-clock scheduling
measurement is not itself an acoustic-jitter or physical-DAC timestamp.
This is a complete successful candidate run, not a final-image qualification.

### Longer sidecar soak and Java earpiece repeat

The same timing-instrumented sidecar stage subsequently passed the following
additional real-device trials; both have empty collected HAL-error inventories
and `session_status=0`:

| Requested run | Full analyzed acoustic interval | Measured 12.037 kHz carrier | Phase events / dropout blocks / clipped samples | Maximum acoustic phase step |
| --- | --- | --- | --- | --- |
| Java AudioTrack earpiece, 30 s | 29.90 s; 119,599 phase pairs | 12,036.999935 Hz | 0 / 0 / 0 | 0.06399 rad |
| AAudio bottom, 120 s | 119.87 s; 479,479 phase pairs | 12,036.999970 Hz | 0 / 0 / 0 | 0.03758 rad |

The Java earpiece app reported all 5,760,000 frames written and played in
30,003 ms with zero AudioTrack underruns. See its
[WAV](../work/audio-research/frankel/pitch-validation/sidecar-timing-java-earpiece-20260911/capture.wav),
[acoustic qualification](../work/audio-research/frankel/pitch-validation/sidecar-timing-java-earpiece-20260911/tone-qualification.json),
[API/HAL log](../work/audio-research/frankel/pitch-validation/sidecar-timing-java-earpiece-20260911/logcat.txt),
and [HAL-error inventory](../work/audio-research/frankel/pitch-validation/sidecar-timing-java-earpiece-20260911/hal-playback-errors.txt).

The two-minute bottom run transferred all **23,040,000 frames**, reported
native xruns 0/0 and `AAUDIO_RUN_OK`, and passed saved-report/current-run
validation. All 1,185 distinct steady timestamp pairs contributed to the
118.825-second regression span: 191,999.673 Hz, with zero duplicate,
unavailable or nonmonotonic steady pairs and a 102.946 ms maximum fresh-query
gap. See its [complete native report](../work/audio-research/frankel/pitch-validation/sidecar-timing-aaudio-bottom-120s-20260911/native-report.txt),
[run-ID check](../work/audio-research/frankel/pitch-validation/sidecar-timing-aaudio-bottom-120s-20260911/native-report-status.txt),
[WAV](../work/audio-research/frankel/pitch-validation/sidecar-timing-aaudio-bottom-120s-20260911/capture.wav),
[acoustic qualification](../work/audio-research/frankel/pitch-validation/sidecar-timing-aaudio-bottom-120s-20260911/tone-qualification.json),
and [HAL-error inventory](../work/audio-research/frankel/pitch-validation/sidecar-timing-aaudio-bottom-120s-20260911/hal-playback-errors.txt).

At cleanup, the two-minute run's HAL timing diagnostic recorded an actual
maximum inter-transfer gap of **11.020 ms** (Java earpiece: 5.412 ms).
That is a bounded observation from these runs, distinct from 100 ms API
timestamp-query cadence and from acoustic phase measurements. It is not a
guaranteed future scheduling bound or proof that all residual failure causes
have been eliminated. These results qualify their measured intervals;
combined-image rebuild, flash and post-flash qualification remain pending.

### Post-RT point-frequency response

The following post-RT ultrasonic measurements detected the intended component
above the Nyquist limits of 48 and 96 kHz playback:

| Output path | Requested frequency | Detected peak | Intended-bin rise above quiet lead | Evidence |
| --- | --- | --- | --- | --- |
| Raw D5, bottom speaker | 54,283 Hz | 54,282.996649 Hz | +33.95 dB | [WAV](../work/audio-research/frankel/pitch-validation/rt-worker-raw-bottom-54283-20260911/capture.wav), [analysis](../work/audio-research/frankel/pitch-validation/rt-worker-raw-bottom-54283-20260911/tone-analysis.json) |
| Raw D5, earpiece | 54,283 Hz | 54,282.990392 Hz | +22.44 dB | [WAV](../work/audio-research/frankel/pitch-validation/rt-worker-raw-earpiece-54283-20260911/capture.wav), [analysis](../work/audio-research/frankel/pitch-validation/rt-worker-raw-earpiece-54283-20260911/tone-analysis.json) |
| Ordinary primary, AAudio, FIFO/90 + FMQ960 | 54,283 Hz | 54,282.999004 Hz | +47.32 dB | [WAV](../work/audio-research/frankel/pitch-validation/primary-fifo90-fmq960-aaudio-54283-20260911/capture.wav), [point-frequency qualification](../work/audio-research/frankel/pitch-validation/primary-fifo90-fmq960-aaudio-54283-20260911/tone-qualification.json) |

The primary AAudio run also transferred all 1,536,000 target frames, reported
192,000 Hz/two-channel PCM_FLOAT consistently, native xruns 0/0 and
`AAUDIO_RUN_OK`. Its 69 steady timestamp observations span 6.820 seconds,
with no unavailable/nonmonotonic pairs and a 191,997.613 Hz regression.
The [saved native report](../work/audio-research/frankel/pitch-validation/primary-fifo90-fmq960-aaudio-54283-20260911/native-report.txt)
passed the [current-run ID check](../work/audio-research/frankel/pitch-validation/primary-fifo90-fmq960-aaudio-54283-20260911/native-report-status.txt);
the [HAL-error inventory](../work/audio-research/frankel/pitch-validation/primary-fifo90-fmq960-aaudio-54283-20260911/hal-playback-errors.txt)
is empty and the full harness reports `session_status=0`.

These 54.283 kHz rows qualify **intended-frequency response only**, not
ultrasonic duration or jitter. The raw recordings' full-interval envelopes
are marked `measurable=false`; the primary recording's short-window phase
estimator also reports many excursions. No zero-jitter claim is derived from
those weak high-frequency phase traces, and no flat or calibrated response
to 96 kHz is implied. The reported API presentation clock remains a HAL
model, distinct from the independently recorded physical component.

## Amplifier-dependent 54.283 kHz control

A bottom-speaker amplifier-off/on comparison strengthens the physical-path
interpretation of the ultrasonic self-loop observation:

| Bottom amplifier condition | 54.283 kHz result | Evidence |
| --- | --- | --- |
| Off | Intended-frequency bin −2.46 dB relative to quiet lead; no detected peak at the requested frequency. | [WAV](../work/audio-research/frankel/pitch-validation/final-image-bottom-54283-amp-off-20260911/capture.wav), [analysis](../work/audio-research/frankel/pitch-validation/final-image-bottom-54283-amp-off-20260911/tone-analysis.json) |
| On | Intended-frequency peak 54,283.005634 Hz, +35.93 dB relative to quiet lead. | [WAV](../work/audio-research/frankel/pitch-validation/final-image-bottom-54283-amp-on-20260911/capture.wav), [analysis](../work/audio-research/frankel/pitch-validation/final-image-bottom-54283-amp-on-20260911/tone-analysis.json) |

The component depends on amplifier activation, supporting a signal through
the physical output path rather than an unchanged microphone-only noise
feature. This is still an internal, uncalibrated point-frequency control;
it does not measure SPL, establish a flat response to 96 kHz, or by itself
eliminate every possible amplifier-dependent electrical coupling mechanism.
The weak high-frequency short-window phase estimates are not used to claim
ultrasonic jitter performance.

## Pre-standby-zero bundled image: measured passes and route-collision failure

The bundled vendor image flashed successfully in **30.382 seconds**; see the
[flash log](../work/audio-research/frankel/images/vendor-playback192-rt-fmq960-flash-20260911.log).
The RT kernel was already installed and is included in the bundle. This
stage tests the combined installed files, not the preceding live HAL bind
mounts. The [early root boot snapshot](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-boot-root-20260911.txt)
records SELinux Enforcing, RT-worker FIFO priority 95, and both power-setting
readbacks at 1,500,000 **without a manual power hint on this boot**. `/vendor`
is a read-only ext4 mount with no vendor overlay or temporary HAL RAM bind.
Other partition overlay mounts remain present, but their upper-file inventories
were empty; this is not a claim that no overlay mount exists anywhere.

That snapshot was taken during bootstrap `attempt1`, when speaker/PDM ready
properties were still zero. It must not be cited as completed readiness.
The controller subsequently observed speaker/PDM readiness 1/1 and phase
`complete` before starting the API batch; the harness independently requires
PDM readiness 1 and all three audio services running. The completed
[UI/readiness bookend](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-ui-bookend-20260911.txt)
confirms boot/speaker/PDM readiness 1/1/1, phase `complete`, SELinux Enforcing,
AoC crash/restart counts 0/0, RT-worker priority 95, both power readbacks
1,500,000 and all three audio services running after the tests. Settings
launched successfully and its UI hierarchy was dumped. BUS media volume was
restored to 8/25 while addressed playback was active, then ordinary-speaker
media volume to 15/25; these defaults differ from the qualification volumes.
However, the subsequent full log review found a real route collision during
that restoration sequence. This snapshot proves those UI/property readbacks,
**not a clean audio handoff or an unlatched sidecar**; see the failure below.

Only completed post-flash measurements appear in this table:

| Installed-image test | Requested / analyzed duration | Measured carrier | Acoustic phase / dropout / clipping events | Result and evidence |
| --- | --- | --- | --- | --- |
| Java AudioTrack, bottom BUS, 192 kHz | 30 s / 29.90 s | 12,036.999520 Hz | 0 / 0 / 0 | PASS; empty HAL-error inventory and `session_status=0`. [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-java-bottom-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-java-bottom-20260911/tone-qualification.json), [HAL errors](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-java-bottom-20260911/hal-playback-errors.txt). |
| AAudio, earpiece BUS, 192 kHz | 30 s / 29.86 s | 12,037.000081 Hz | 0 / 0 / 0 | PASS; native `AAUDIO_RUN_OK`, matching report run ID, empty HAL errors and `session_status=0`. [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-earpiece-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-earpiece-20260911/tone-qualification.json), [native report](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-earpiece-20260911/native-report.txt). |
| Java AudioTrack, earpiece BUS, 192 kHz | 30 s / 29.90 s | 12,036.999669 Hz | 0 / 0 / 0 | PASS; empty HAL-error inventory and `session_status=0`. [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-java-earpiece-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-java-earpiece-20260911/tone-qualification.json), [HAL errors](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-java-earpiece-20260911/hal-playback-errors.txt). |
| AAudio, bottom BUS, 192 kHz | 120 s / 119.87 s | 12,036.999923 Hz | **1 / 0 / 0** | **FAIL acoustic gate**, `session_status=1`; native report/identity and HAL-error gates pass. [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-bottom-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-bottom-20260911/tone-qualification.json), [native report](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-bottom-20260911/native-report.txt). |
| Java AudioTrack, ordinary primary, 48 kHz client | 30 s / 29.90 s | 12,000.000055 Hz | 0 / 0 / 0 | PASS; empty HAL errors, app 30,065 ms / zero underruns, `session_status=0`. [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-primary48-java-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-primary48-java-20260911/tone-qualification.json), [HAL errors](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-primary48-java-20260911/hal-playback-errors.txt). |
| AAudio, bottom BUS, 192 kHz, level-0.16 repeat | 120 s / 119.89 s | 12,036.999878 Hz | 0 / 0 / 0 | PASS with unchanged fixed thresholds; native report/identity and HAL gates pass, `session_status=0`. [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-bottom-a16-120s-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-bottom-a16-120s-20260911/tone-qualification.json), [native report](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-bottom-a16-120s-20260911/native-report.txt). |
| Direct ALSA D5, bottom, 192 kHz / level 0.08 | 30 s / 29.88 s | 12,036.999763 Hz | 0 / 0 / 0 | PASS; `session_status=0` and full-duration acoustic gate passes. [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-raw-bottom-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-raw-bottom-20260911/tone-qualification.json). |
| Direct ALSA D5, earpiece, 192 kHz / level 0.08 | 30 s / 29.88 s | 12,036.999976 Hz | 0 / 0 / 0 | PASS; `session_status=0` and full-duration acoustic gate passes. [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-raw-earpiece-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-raw-earpiece-20260911/tone-qualification.json). |
| Java AudioTrack, ordinary primary 48 kHz, after raw-route tests | 8 s / 7.90 s | 11,999.999693 Hz | 0 / 0 / 0 | PASS; `session_status=0`, confirming normal playback after direct-route cycling. [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-primary48-after-raw-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-primary48-after-raw-20260911/tone-qualification.json). |

The installed earpiece AAudio run transferred all 5,760,000 frames with native
xruns 0/0. Its 288 steady timestamp observations span 28.800 seconds and fit
191,999.902 Hz, with no duplicate, unavailable or nonmonotonic steady pairs;
the [saved-report identity check](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-earpiece-20260911/native-report-status.txt)
also passes.

The installed two-minute bottom run transferred all 23,040,000 frames,
reported native xruns 0/0 and `AAUDIO_RUN_OK`, and has an empty HAL-error
inventory. Its 1,185 steady timestamp pairs fit 191,999.987 Hz over 118.760
seconds with no duplicate, unavailable or nonmonotonic pairs. Nevertheless,
the independent WAV contains one 0.40428-radian phase event above the fixed
0.35-radian threshold among 479,479 analyzed phase pairs, at capture time
41.351625 seconds. There are no dropout blocks or clipped samples. The run
remains **FAIL**, not rounded down to a clean result.

Its separate [transient diagnosis](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-aaudio-bottom-20260911/transient-diagnosis.json)
finds only +0.0001247 radians of before/after carrier phase change and +0.0314 dB
of amplitude change, but approximately +17.8 dB residual energy in 14–20 kHz
during the event, with strong components around 14.2–15 kHz. This supports,
but does not prove, a short additive transient contaminating the phase
estimator. Its source and playback-versus-capture origin remain unidentified;
a transient timing excursion that cancels is not excluded. The diagnosis
does not alter thresholds or turn the original FAIL into PASS.

The subsequent installed-image 54.283 kHz batch passes its explicitly bounded
point-frequency checks, with empty HAL-error inventories and `session_status=0`
for all three runs. Both AAudio saved reports also pass native/current-run
identity validation:

| Installed API/output | Detected peak | Intended-bin rise above quiet lead | Evidence |
| --- | --- | --- | --- |
| AAudio, bottom BUS | 54,283.004430 Hz | +32.73 dB | [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-54283-aaudio-bottom-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-54283-aaudio-bottom-20260911/tone-qualification.json), [native report](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-54283-aaudio-bottom-20260911/native-report.txt). |
| Java AudioTrack, earpiece BUS | 54,283.005143 Hz | +26.37 dB | [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-54283-java-earpiece-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-54283-java-earpiece-20260911/tone-qualification.json). |
| AAudio, ordinary primary | 54,282.999120 Hz | +48.54 dB | [WAV](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-54283-primary-aaudio-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-54283-primary-aaudio-20260911/tone-qualification.json), [native report](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-54283-primary-aaudio-20260911/native-report.txt). |

These eight-second requests qualify intended ultrasonic response only, not
full-duration ultrasonic jitter or a calibrated/flat response to 96 kHz.

The sequential batch stopped at that failed gate. The separately run
ordinary-primary 48 kHz Java test then passed, as recorded above, with all
1,440,000 requested client frames written/played, followed by the point-frequency
passes above. The two-minute AAudio repeat with a stronger 0.16 pilot
(originally 0.08) then passed: 119.89 analyzed seconds, 479,559 phase pairs,
zero phase/dropout/clipping events and maximum phase step 0.04444 radians.
It transferred all 23,040,000 frames with native xruns 0/0; all 1,184 distinct
steady timestamp pairs fit 191,999.514 Hz over 118.807 seconds, with no
unavailable/nonmonotonic pairs. Saved-report identity and HAL-error gates
also pass. The repeat changed signal level, not hardware/software or analysis
thresholds, and cannot erase the original failed recording. The final
direct-ALSA bottom and earpiece soaks also pass at the original 0.08 pilot
level, using the unchanged 192 × twenty-period geometry, full 3,840-frame
start threshold and FIFO/90 raw producer. Their maximum measured phase
steps are 0.12556 and 0.06987 radians respectively, with no detected events
above the fixed threshold. Each direct run accepted all 5,760,000 frames in
30,000 WRITEI calls, with zero short writes and xruns. The ordinary-primary
48 kHz Java playback check after those direct-route cycles then passed its
full 7.90-second analyzed interval with no detected phase/dropout/clipping
events, followed by the UI/readiness readbacks linked above. Those readbacks
did not exclude the later-discovered route collision.
These completed measurements support native-192 kHz playback on both speakers
within the reported hardware/API intervals and the combined-path 54.283 kHz
bandwidth result. They do not qualify the overall handoff: a subsequent
bookend-log review found the cross-route failure recorded below. They also
do not erase the
earlier failed candidates, convert the retained level-0.08 measurement FAIL
into PASS, or expand point-frequency evidence into a calibrated full-band
response or blanket zero-jitter claim.

### Bookend failure: research-to-primary route collision

Full [post-test logcat review](../work/audio-research/frankel/pitch-validation/final-rt-fmq960-logcat-bookend-20260911.txt)
found an actual failure during volume restoration: a five-second silent
research-BUS run followed by a five-second ordinary-primary run with a
seven-second launch gap. The relevant events are:

| Log timestamp | Observed event |
| --- | --- |
| 09:50:07.420–.428 | Another control path unbinds source 5 / sink 0 and powers down both speaker amplifiers while the sidecar PCM is still active. |
| 09:50:07.616–.617 | The sidecar's 960-frame transfer fails after accepting 768 frames; the final 192-frame WRITEI returns `status=-5` (EIO) after 202,684 µs inside the write. Native xrun counters remain `0->0`. |
| 09:50:07.621 | Ownership audit finds `R Main AMP Enable Switch: expected 1, got 0`. The sidecar latches a fault and refuses cleanup/restoration writes because it no longer owns the route exclusively. |
| 09:50:07.622 onward | Framework writes fail and subsequent bursts encounter the stream's ERROR state. |

This is a real route-lifetime/integrity failure, distinct from the earlier
isolated acoustic phase-estimator transient. The immediately preceding
inter-transfer gap was only 161 µs (maximum observed gap 1,945 µs); the
202.684 ms blocked WRITEI and amplifier power-down evidence must not be
misrepresented as another proven 27–30 ms unbound-worker dispatch stall.
The exact cross-process ownership/lifetime correction was under investigation
at this stage.

The device's UI and services remained alive and readiness properties still
appeared healthy, demonstrating why those snapshots alone cannot qualify
audio operation. Earlier successful WAV/API intervals remain valid evidence,
but **overall image handoff was pending a route-collision fix and repeated
real research↔ordinary transitions with full error-log review at this stage**.
No final verified handoff is claimed for this preceding vendor revision.

## Final standby-zero vendor revision: bounded qualification complete

The next vendor revision changes the persistent configuration to
`ro.audio.flinger_standbytime_ms=0`, generated into the vendor sysprop input
and `/vendor/build.prop`. The RT kernel and other previously tested audio
changes remain unchanged. This targets the framework's retained output-route
lifetime after a client stops; it does not establish safe simultaneous
ownership of the research BUS and ordinary-primary path.

The new vendor image flashed successfully in **33.598 seconds**; see the
[standby-zero flash log](../work/audio-research/frankel/images/vendor-playback192-standby0-flash-20260911.log).
The first-boot two-minute AAudio bottom test **failed** its acoustic phase
gate: 18,783 phase events, no dropout blocks or clipped samples across
119.87 analyzed seconds, with maximum phase step 0.82383 radians. Its carrier
remained 12,036.999992 Hz. Native execution transferred all 23,040,000 frames,
reported xruns 0/0, a 192,000.038 Hz full-run timestamp regression and
`AAUDIO_RUN_OK`; the HAL-error inventory is empty, but overall
`session_status=1`. See the [weak-trial WAV](../work/audio-research/frankel/pitch-validation/standby0-aaudio-bottom-120s-20260911/capture.wav),
[analysis](../work/audio-research/frankel/pitch-validation/standby0-aaudio-bottom-120s-20260911/tone-analysis.json),
[fixed-gate qualification](../work/audio-research/frankel/pitch-validation/standby0-aaudio-bottom-120s-20260911/tone-qualification.json),
and [native report](../work/audio-research/frankel/pitch-validation/standby0-aaudio-bottom-120s-20260911/native-report.txt).

The measurement level was not the intended qualification level. The active
BUS retained media volume **8/25 after reboot**. Initial attempts to select
that BUS for volume adjustment were canceled immediately while the boot
screen remained locked, so the apparent successful volume-25 commands
affected the ordinary-primary route instead. A pre-activation
`getStreamVolume()` report of 25 likewise does not establish the preferred
BUS's later active volume. The [initial command/app log](../work/audio-research/frankel/pitch-validation/standby0-first-volume-handoff-20260911.txt)
records both cancellation failures despite the successful volume readbacks.

The weak recorded tone is −83.45 dBFS, with only +40.11 dB intended-bin rise
over the quiet lead, versus approximately +77 dB in the stronger prior
measurement. That coherent-bin contrast is not short-window phase-estimator
SNR. The many noisy phase events remain a **failed measurement**, not proof
that the unchanged kernel or new standby property broke sample cadence.
Their level/noise contribution requires a correctly controlled repeat.

After explicitly waking and dismissing the lock screen, a silent five-second
BUS run completed while its active volume was set/read back to 25; see the
[active-BUS volume confirmation](../work/audio-research/frankel/pitch-validation/standby0-active-bus-volume25-20260911.txt).
The completed volume-controlled repeat below confirms the recovered acoustic
gain and passes the continuity gate. The weak run is retained and not
reclassified.

The first [handoff artifact](../work/audio-research/frankel/pitch-validation/standby0-handoff-20260911/handoff-qualification.json)
also fails its transport/log gate: missing fresh completions and launch
intervals around 1.84–1.89 seconds instead of the intended six seconds.
It cannot establish the target short-gap handoff behavior. The
[v2 attempt](../work/audio-research/frankel/pitch-validation/standby0-handoff-v2-20260911/handoff-qualification.json)
also fails its timer/launch validation and remains an invalid qualification
attempt, not a hardware pass. No result is inferred from the property change
or successful flash operation alone.

### Corrected sequential-handoff v3: PASS

The corrected test performs four actual five-second playback segments in
the order bottom BUS → ordinary primary → earpiece BUS → ordinary primary.
Measured launch-to-launch intervals are 6.27991, 6.33016 and 6.24144 seconds,
matching the six-second target plus bounded launch/force-stop overhead.
Every segment passes both fresh app-completion/transport checks and the
unchanged full-duration acoustic gate; the HAL-error inventory is empty.

| Segment | Requested carrier | Measured carrier | Analyzed duration | Phase / dropout / clipping events |
| --- | --- | --- | --- | --- |
| Bottom BUS, 192 kHz | 12,037 Hz | 12,036.997846 Hz | 4.90 s | 0 / 0 / 0 |
| Ordinary primary, 48 kHz client | 12,000 Hz | 11,999.999370 Hz | 4.90 s | 0 / 0 / 0 |
| Earpiece BUS, 192 kHz | 12,037 Hz | 12,037.000895 Hz | 4.90 s | 0 / 0 / 0 |
| Ordinary primary, 48 kHz client | 12,000 Hz | 11,999.999864 Hz | 4.90 s | 0 / 0 / 0 |

The 4.90-second intervals exclude only the analyzer's fixed 50 ms boundary
guards from each detected five-second tone; they do not shorten the requested
duration to hide failures. See the [original continuous WAV](../work/audio-research/frankel/pitch-validation/standby0-handoff-v3-20260911/capture.wav),
[transport/launch evidence](../work/audio-research/frankel/pitch-validation/standby0-handoff-v3-20260911/handoff-qualification.json),
[combined four-segment acoustic qualification](../work/audio-research/frankel/pitch-validation/standby0-handoff-v3-20260911/acoustic-segments/handoff-acoustic-qualification.json),
and [HAL-error inventory](../work/audio-research/frankel/pitch-validation/standby0-handoff-v3-20260911/hal-playback-errors.txt).
The combined report records the completed acoustic pass separately from the
earlier transport report's pre-analysis `acoustic_qualification=PENDING` field.

The [current AudioService volume readback](../work/audio-research/frankel/pitch-validation/standby0-volume-readback-20260911.txt)
now confirms **both speaker and BUS media volume 25/25** after proper wakeup
and active-BUS adjustment, unlike the invalid pre-activation check. The
volume-controlled batch requests bottom AAudio for 120 seconds and earpiece
AAudio for 30 seconds at level 0.16, then 54.283 kHz bottom AAudio, earpiece
Java and ordinary-primary AAudio checks at level 0.25. The completed bottom
result, remaining tests and completed volume-restoration/UI/full-error-log
bookend are recorded below.

### Volume-controlled bottom AAudio, 120 seconds: PASS

With actual BUS volume 25/25, the same standby-zero image transferred all
23,040,000 target frames with native xruns 0/0 and `AAUDIO_RUN_OK`. All 1,184
distinct steady timestamp pairs contribute to a 118.760-second fit of
191,999.948 Hz, with no duplicate, unavailable or nonmonotonic observations.
The saved report matches the current run ID, the HAL-error inventory is
empty, and the complete harness reports `session_status=0`.

The independent acoustic interval is **119.87 seconds**, with a
12,036.999915 Hz carrier, zero phase/dropout/clipping events and maximum
phase step 0.02215 radians. Recorded pilot level is now −50.23 dBFS versus
−83.45 dBFS in the incorrect-volume run, approximately **33.22 dB recovered**;
the intended-bin rise over quiet is +83.24 dB. The fixed analysis thresholds
are unchanged, and the earlier weak-recording FAIL remains retained.

See the [WAV](../work/audio-research/frankel/pitch-validation/standby0-volume25-aaudio-bottom-20260911/capture.wav),
[full acoustic qualification](../work/audio-research/frankel/pitch-validation/standby0-volume25-aaudio-bottom-20260911/tone-qualification.json),
[complete native report](../work/audio-research/frankel/pitch-validation/standby0-volume25-aaudio-bottom-20260911/native-report.txt),
[current-run validation](../work/audio-research/frankel/pitch-validation/standby0-volume25-aaudio-bottom-20260911/native-report-status.txt),
and [HAL-error inventory](../work/audio-research/frankel/pitch-validation/standby0-volume25-aaudio-bottom-20260911/hal-playback-errors.txt).

Concurrent primary/BUS playback remains unsupported. The supported scope is
clean **sequential short-gap handoff**, demonstrated by the corrected v3 test
without EIO, amplifier-ownership loss, latched faults or invalidated earlier
streams.
### Additional volume-controlled standby-zero results

The 30-second earpiece AAudio run passes with a 29.86-second acoustic
interval, 12,036.999960 Hz carrier, zero phase/dropout/clipping events and
maximum phase step 0.03650 radians. All 5,760,000 target frames transfer,
native xruns are 0/0, full-run timestamp regression is 191,999.945 Hz, and
`AAUDIO_RUN_OK` is retained in the complete saved report. Its current-run
identity, HAL-error and acoustic gates pass; `session_status=0`.
See the [earpiece WAV](../work/audio-research/frankel/pitch-validation/standby0-volume25-aaudio-earpiece-20260911/capture.wav),
[qualification](../work/audio-research/frankel/pitch-validation/standby0-volume25-aaudio-earpiece-20260911/tone-qualification.json),
and [native report](../work/audio-research/frankel/pitch-validation/standby0-volume25-aaudio-earpiece-20260911/native-report.txt).

Completed 54.283 kHz tests on the same vendor revision are:

| API/output | Detected peak | Intended-bin rise above quiet lead | Result and evidence |
| --- | --- | --- | --- |
| AAudio, bottom BUS | 54,283.002154 Hz | +38.99 dB | Point-frequency PASS, `session_status=0`, empty HAL errors. [WAV](../work/audio-research/frankel/pitch-validation/standby0-54283-aaudio-bottom-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/standby0-54283-aaudio-bottom-20260911/tone-qualification.json). |
| Java AudioTrack, earpiece BUS | 54,282.990119 Hz | +26.64 dB | Point-frequency PASS, `session_status=0`, empty HAL errors. [WAV](../work/audio-research/frankel/pitch-validation/standby0-54283-java-earpiece-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/standby0-54283-java-earpiece-20260911/tone-qualification.json). |
| AAudio, ordinary primary | 54,282.999652 Hz | +40.38 dB | Point-frequency PASS, native/current-report PASS, `session_status=0`, empty HAL errors. [WAV](../work/audio-research/frankel/pitch-validation/standby0-54283-primary-aaudio-20260911/capture.wav), [qualification](../work/audio-research/frankel/pitch-validation/standby0-54283-primary-aaudio-20260911/tone-qualification.json), [native report](../work/audio-research/frankel/pitch-validation/standby0-54283-primary-aaudio-20260911/native-report.txt). |

These ultrasonic measurements are intended-frequency response checks, not
ultrasonic jitter, full-band calibration or flat response to 96 kHz.

### Final restoration, readiness and full-error-log bookend: PASS

The [fresh final log interval](../work/audio-research/frankel/pitch-validation/standby0-final-logcat-bookend-20260911.txt)
contains two completed five-second silent playback requests: research BUS,
then ordinary primary, with a seven-second configured launch gap. BUS
transferred/played 960,000 frames in 5,014 ms and primary 240,000 in 5,032 ms,
both with zero AudioTrack underruns and fresh `STOCK_PLAYBACK_COMPLETE`
records. The full interval has no PCM EIO/EBUSY/write failures, amplifier
ownership drift or latched-fault reports, app failures, fatal exceptions or
ANRs. This explicitly checks the transition that failed on the prior vendor;
it does not substitute silence for the v3 test's four acoustic segments.

The [UI/readiness transcript](../work/audio-research/frankel/pitch-validation/standby0-final-ui-bookend-20260911.txt)
also confirms successful Settings launch in 172 ms and a completed UI
hierarchy dump; boot/speaker/PDM readiness 1/1/1 with phase `complete`;
standby property 0; SELinux Enforcing; AoC crash/restart counts 0/0;
kernel-worker FIFO priority 95; both power-setting readbacks 1,500,000;
and all three audio services running. Unlike the prior failed bookend,
these readbacks are accompanied by the clean full error-log interval.

The [final per-device volume inventory](../work/audio-research/frankel/pitch-validation/standby0-final-volumes-20260911.txt)
confirms ordinary-speaker media volume **15/25** and BUS media volume **8/25**
after restoration, rather than relying only on the current route's scalar
volume API. Qualification measurements used the separately documented
active-route volumes and signal levels; the restored defaults are lower.

The final standby-zero revision therefore passes its reported native-192
playback, combined-path 54.283 kHz response and completed sequential-handoff
tests. Simultaneous primary/BUS use remains unsupported, and the retained
failed measurements and prior-vendor collision remain part of the evidence.

The v3 result qualifies its measured sequential handoffs only. Prior WAV/API
passes remain evidence for the preceding vendor revision and are not
automatically inherited as qualifications of this new image.

## Interpretation and qualification limits

The corrected 12 kHz reproduction resolves the demonstrated pitch/cadence
fault. Together, the native 192-frame/ms geometry, matching transport/DMA
accounting, and intended 54.283 kHz self-loop component support the live
native-192 kHz chain qualification. This is an internal point-frequency
self-loop result, not a calibrated frequency-response measurement or a claim
of a flat/useful acoustic response up to 96 kHz. Several-frequency sweeps,
alias/harmonic comparisons, and acoustic-versus-electrical coupling controls
can characterize the complete transducer path further; external calibrated
gear is not a prerequisite for the internal test reported here. PDM noise
near Nyquist is microphone evidence, not proof of speaker output.

Frequency estimates use the recording's nominal 192 kHz timebase. Their
displayed fit precision is not independently calibrated clock accuracy.
A single carrier can also miss a sample slip equal to a whole number of its
cycles; zero detected events is a bounded measurement result, not a claim
of mathematically zero jitter.

The direct harness is
[`d5-d10-acoustic-measurement.sh`](../scripts/audio/frankel/d5-d10-acoustic-measurement.sh).
Do not label a rebuilt bundle verified solely because it incorporates these
sources: boot the flashed image, confirm the helpers complete before first
speaker activation, repeat physical playback/recording, and exercise ordinary
UI/media audio and Android API routes. The measured post-flash playback runs
above completed; the preceding vendor's cross-route handoff failed, while
the standby-zero revision now passes its corrected v3 sequential test,
volume-controlled playback/bandwidth batch and final full-error-log bookend.
This completes the bounded playback/handoff qualification reported here;
it does not establish safe concurrent primary/BUS playback. This session
does not requalify every original microphone/API combination; its independent
reference is raw D10, principally MIC0. The earlier Java D10 reference-capture
gaps and the isolated low-level phase-event recording remain available for
further investigation. Qualification is bounded by the recorded endpoints,
signal levels, durations and physical-reference evidence—not inferred from
the image contents, software sample-rate labels, or a discarded failed run.
