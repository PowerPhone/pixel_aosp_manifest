# Pixel 10 ordinary/UI audio investigation — 2026-09-12

Status: **the ordinary UI/media gain correction is flashed and its scoped
post-flash checks are complete**. Java and AAudio 4 kHz playback pass full
continuity checks; all eight system clicks produce source-shaped responses
at the improved level, and the final UI/error-log bookend is clean. The user
has not yet reconfirmed subjective UI-click audibility after the correction.
Both research-route
handoff recordings fail their acoustic gates despite clean transport logs;
this revision does not renew all-research continuity qualification. The
correction changes exactly three ordinary-route mixer controls, not the
firmware, kernel or research playback path.
The user reported that UI sounds remained inaudible and that the earlier
66.547 kHz result was unconvincing. Ordinary continuous playback and short
system effects are tested separately here. The previous day's qualified
playback intervals do not establish that every UI effect is audible.

## Fresh baseline on the installed image

These trials use ordinary-primary Java AudioTrack at 48 kHz, stereo PCM16,
peak level 0.08 and media volume 25/25, recorded independently through the
physical D10 microphone PCM path. Neither is a research-BUS output test.

| Requested stimulus | Measured full interval | Recorded frequency | Continuity |
| --- | --- | --- | --- |
| 12 kHz, 8 s | 7.90 s | 11,999.999669 Hz | PASS: zero phase-step events, dropouts or clipped samples |
| 4 kHz, 5 s | 4.90 s | 4,000.000620 Hz | PASS: zero phase-step events, dropouts or clipped samples |

The boundary guards account for the 0.10 s difference from requested duration;
the apps completed all requested frames in 8,033 ms and 5,027 ms respectively,
each reporting zero underruns. The user explicitly confirmed that the
4 kHz stimulus was clearly audible. This rules out complete ordinary-playback
silence during that trial, but does not resolve short UI-effect playback.

Original evidence:

- [12 kHz recording](../work/audio-research/frankel/ordinary-audio-fix-20260912/ordinary-12k-before/capture.wav)
  and [full-interval qualification](../work/audio-research/frankel/ordinary-audio-fix-20260912/ordinary-12k-before/tone-qualification.json).
- [4 kHz recording](../work/audio-research/frankel/ordinary-audio-fix-20260912/ordinary-4k-before/capture.wav)
  and [full-interval qualification](../work/audio-research/frankel/ordinary-audio-fix-20260912/ordinary-4k-before/tone-qualification.json).

## Actual UI-click diagnostic

`com.csr460.powerphone.SoundEffectsActivity` calls
`AudioManager.loadSoundEffects()` and, after a one-second preparation delay,
dispatches eight `FX_KEY_CLICK` effects one second apart. The default
`effect_volume=-1` uses Android's system-default effect attenuation; it is
not an explicitly full-volume replacement. Each call logs both wall-clock
milliseconds and monotonic nanoseconds. API completion establishes dispatch,
not sound production or audibility.

The cold trial has no helper output track. The warm trial continuously feeds
zero samples to an ordinary 48 kHz stereo AudioTrack, beginning one second
before the clicks and continuing through them. It changes no policy volume,
amplifier controls or HAL implementation. Independent D10 recordings retain
the entire capture, including preparation and quiet intervals.

- Cold: [original WAV](../work/audio-research/frankel/ordinary-audio-fix-20260912/ui-cold-before/capture.wav),
  [event log](../work/audio-research/frankel/ordinary-audio-fix-20260912/ui-cold-before/logcat.txt),
  [corrected per-click measurements](../work/audio-research/frankel/ordinary-audio-fix-20260912/ui-cold-before/ui-clicks-dominantband.json).
- Warm: [original WAV](../work/audio-research/frankel/ordinary-audio-fix-20260912/ui-warm-before/capture.wav),
  [event log](../work/audio-research/frankel/ordinary-audio-fix-20260912/ui-warm-before/logcat.txt),
  [corrected per-click measurements](../work/audio-research/frankel/ordinary-audio-fix-20260912/ui-warm-before/ui-clicks-dominantband.json).

Both logs contain all eight requests. The initial analysis used a 2–18 kHz
band, which excludes **99.77% of the actual installed click's energy**. The
94 ms `Effect_Tick.ogg` is concentrated below 2 kHz, with principal components
around 670–777 Hz. Therefore the original `ui-clicks-analysis.json` files are
retained as invalid-band analyses, not evidence that the clicks were absent.
See the [analysis correction record](../work/audio-research/frankel/ordinary-audio-fix-20260912/UI_CLICK_ANALYSIS_BAND_CORRECTION.md).

Corrected `ui-clicks-dominantband.json` reports use 100–2,000 Hz for the source
correlation and separately retain 100–18,000 Hz broadband metrics, without
changing the recordings, source asset or event timing. They deliberately do
not turn API completion or ambient energy into an automatic audible-playback
PASS. Absolute delays include unknown capture-start offset; unrelated ambient
transients can contaminate individual response windows.

## Bounded gain correction

The fixed-192 ordinary-speaker route introduced `Amp Gain=6` and
`R Amp Gain=6`, while the donor/default controls were 17. This is visible in
the [idle mixer snapshot](../work/audio-research/frankel/ordinary-audio-fix-20260912/mixer-before.txt)
versus the [active ordinary-route snapshot](../work/audio-research/frankel/ordinary-audio-fix-20260912/mixer-ordinary-active.txt),
and the route-local assignments in
[the primary speaker-route patcher](../tools/audio/patch_frankel_primary_speaker_route.py).

The correction restores exactly three controls: `speaker`'s `Amp Gain` and
`R Amp Gain`, and `speaker-safe`'s `R Amp Gain`, from 6 to 17. It leaves the
separate earpiece setting at 6 and research routing at 0. These are mixer
control values, not an assumed acoustic dB gain. The selector matches complete,
unique route stanzas and accepts the former gain-6 profile for migration;
unknown/mixed stanzas are rejected without calculating whole-file hashes.

### Measured live-candidate results

The candidate mixer XML was applied as a temporary live bind for these tests.
They qualify the measured live behavior, not by themselves the subsequently
rebuilt vendor image. That image's separate results follow below.

| Trial | Measured result | Scope |
| --- | --- | --- |
| Eight cold-start system clicks | All eight correlate with the actual source, correlation 0.461–0.649 versus quiet maximum 0.209; roughly 6 dB higher click peaks than baseline | Source-matched UI response; no claim of calibrated loudness |
| Ordinary 4 kHz, level 0.08, 5 s | 4.90 s at 4,000.001066 Hz; zero phase events, dropouts or clipping; clean HAL log | Full-interval continuity PASS |
| Ordinary AAudio 192 kHz, 54.283 kHz, 8 s | 54,282.999417 Hz; −76.081 dBFS, 56.486 dB above quiet | Intended-frequency combined-path response |
| Ordinary AAudio 192 kHz, 66.547 kHz, 8 s | 66,547.002426 Hz; −100.910 dBFS, 23.169 dB above quiet | Weak absolute-level combined-path response; not verified airborne output |

The 4 kHz recording increased from −49.4653 to −39.9911 dBFS, a measured
**9.47 dB increase** with the same requested stimulus. The preserved source
settings and independent capture make this stronger evidence of the route's
gain error than guessing acoustic gain from its control code.

Evidence and original WAVs:

- [Cold clicks after correction](../work/audio-research/frankel/ordinary-audio-fix-20260912/ui-cold-gain17/capture.wav)
  and [corrected source correlation](../work/audio-research/frankel/ordinary-audio-fix-20260912/ui-cold-gain17/ui-clicks-dominantband.json).
- [4 kHz after correction](../work/audio-research/frankel/ordinary-audio-fix-20260912/ordinary-4k-gain17/capture.wav)
  and [continuity qualification](../work/audio-research/frankel/ordinary-audio-fix-20260912/ordinary-4k-gain17/tone-qualification.json).
- [54.283 kHz after correction](../work/audio-research/frankel/ordinary-audio-fix-20260912/ordinary-54283-gain17/capture.wav)
  and [analysis](../work/audio-research/frankel/ordinary-audio-fix-20260912/ordinary-54283-gain17/tone-analysis.json).
- [66.547 kHz after correction](../work/audio-research/frankel/ordinary-audio-fix-20260912/ordinary-66547-gain17/capture.wav)
  and [analysis](../work/audio-research/frankel/ordinary-audio-fix-20260912/ordinary-66547-gain17/tone-analysis.json).

The rebuilt vendor is in `artifacts/frankel/powerphone-playback192-20260912/`.
Its existing Android 17 system, RT kernel and other retained images are
unchanged. Packaging and live tests do not substitute for post-flash tests.

## Completed post-flash ordinary-path qualification

The [vendor flash](../work/audio-research/frankel/ordinary-audio-fix-20260912/vendor-gain17-flash.log)
completed in 30.353 s. Android booted, bootstrap reached `complete`, both
audio readiness properties reached 1, and SELinux remained Enforcing.
The [root/readiness/mount record](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-root-mount-readiness.txt)
shows read-only ext4 `/vendor` and no temporary mixer-XML bind masking the
packaged correction.

- [Post-flash cold UI clicks](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-ui-cold-v2/capture.wav):
  all eight actual effects have source-shaped recorded responses in the
  [timing-bounded analysis](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-ui-cold-v2/ui-clicks-timing-bounded.json).
  Median click peak is −77.51 dBFS, about 5.6 dB higher than the old cold
  trial and within 0.1 dB of the live gain-17 candidate. This is measured
  source-response evidence, not merely API dispatch or a listener's
  post-correction audibility confirmation. The capture-timing uncertainty is
  retained; the report does not infer precise physical latency.
- [Post-flash ordinary 4 kHz](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-ordinary-4k/capture.wav):
  full 4.90 s at 3,999.997297 Hz, with zero phase events, dropouts or clipped
  samples; [continuity qualification PASS](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-ordinary-4k/tone-qualification.json).
- [First post-flash handoff, peak level 0.16](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-handoff/capture.wav):
  transport/log checks passed and all four requested five-second segments
  measured their full 4.90 s, without dropout, clipping or HAL errors.
  Nevertheless the bottom and earpiece research segments had 6 and 55 phase
  events respectively; the ordinary segments passed. The combined
  [acoustic qualification remains FAIL](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-handoff/acoustic-segments/handoff-acoustic-qualification.json).

The [peak-level-0.25 repeat](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-handoff-level25/capture.wav)
also remains an [acoustic FAIL](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-handoff-level25/acoustic-segments/handoff-acoustic-qualification.json).
Its bottom segment has 441 dropout blocks, all after the nominal five-second
tone: envelope detection extends to 5.08 s into the post-tone/teardown interval.
That boundary issue is not proof of 441 in-tone underruns and is not used to
relabel the automated result. The earpiece segment has one phase event.
Both ordinary segments again pass their full intervals, and transport/log
handoff checks pass. Research gain remains 0, so the ordinary gain-17 change
did not leak into the research route. Low-level phase bias/interference is
being considered but is not a proven explanation of these events.

Additional completed ordinary-primary AAudio tests:

| Stimulus | Post-flash result | Qualification scope |
| --- | --- | --- |
| 4 kHz, 5 s | Full 4.90 s at 4,000.000228 Hz; zero phase events, dropouts or clipped samples; full native report PASS | Ordinary AAudio continuity PASS |
| 54.283 kHz, 8 s | Peak 54,283.002495 Hz, −78.2822 dBFS, 53.4727 dB above quiet; full harness PASS | Intended-frequency combined-path response |
| 66.547 kHz, 8 s | Peak 66,547.001776 Hz, −101.0771 dBFS, 27.4901 dB above quiet; full harness PASS | Intended-frequency combined-path response, not verified airborne output |

Original post-flash recordings and reports:

- [AAudio 4 kHz WAV](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-aaudio-4k/capture.wav),
  [continuity qualification](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-aaudio-4k/tone-qualification.json)
  and [complete native report](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-aaudio-4k/native-report.txt).
- [54.283 kHz WAV](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-ordinary-54283/capture.wav)
  and [analysis](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-ordinary-54283/tone-analysis.json).
- [66.547 kHz WAV](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-ordinary-66547/capture.wav)
  and [analysis](../work/audio-research/frankel/ordinary-audio-fix-20260912/postflash-ordinary-66547/tone-analysis.json).

### Final UI, volume and full-error-log bookend

The authoritative [checked logcat](../work/audio-research/frankel/ordinary-audio-fix-20260912/final-ui-checked-logcat.txt)
starts at `09-12 06:24:17.040` and includes genuine fresh five-second playback
completions for research BUS at `06:25:50.813` and ordinary primary at
`06:25:58.356`. All 960,000 and 240,000 requested frames respectively
completed, in 5,011 and 5,024 ms, with zero app-reported underruns. The
[checked error inventory](../work/audio-research/frankel/ordinary-audio-fix-20260912/final-ui-checked-errors.txt)
is empty across that interval. The earlier `final-ui-bookend-logcat.txt` was
empty because of a quoted-date `-T` collection error and **is not evidence**;
the corrected collection contains both actual completion records.

The [final UI/readiness record](../work/audio-research/frankel/ordinary-audio-fix-20260912/final-ui-bookend.txt)
shows Settings launching in 181 ms and a successful hierarchy dump, boot
complete, bootstrap `complete`, both audio readiness flags 1, standby 0,
SELinux Enforcing and all three audio services running. The phone remains in
Settings. [Actual final volumes](../work/audio-research/frankel/ordinary-audio-fix-20260912/final-volumes.txt)
are SPEAKER 25, research BUS 8, with system/ring 5 retained. Ordinary speaker
volume is intentionally not described as restored to the previous value 15.

The completed scope is **ordinary UI/media gain correction flashed and
measured**, not all-research continuity qualified. Neither failed research
handoff is replaced or silently relabeled. The user confirmed pre-correction
4 kHz playback was clear; post-correction click-level confidence comes from
the measured source-shaped response, not a new subjective confirmation.
No further kernel/DSP change is part of this correction.

## Ultrasonic interpretation limits

The [HF evidence plot](../work/audio-research/frankel/ordinary-audio-fix-20260912/hf-evidence-plots/hf-evidence.png)
([PDF](../work/audio-research/frankel/ordinary-audio-fix-20260912/hf-evidence-plots/hf-evidence.pdf))
shows unchanged original recordings with narrow-frequency spectrograms and
active/quiet spectra. Its [source, CSVs and measurement metadata](../work/audio-research/frankel/ordinary-audio-fix-20260912/hf-evidence-plots/)
make the window choices reproducible. At 192 kHz, all plotted active windows
are samples `[480000, 1248000)` (2.5–6.5 s), and quiet windows are
`[19200, 211200)` (0.1–1.1 s). Integrated line power uses ±4 Hz around the
requested tone, with 1 Hz PSD bins.

These **fixed-window plot values differ from the dynamic analyzer's values**
quoted above: old 66.547 kHz is −115.939 dBFS / 13.945 dB over quiet; new
ordinary 66.547 kHz is −100.969 dBFS / 24.665 dB; new ordinary 54.283 kHz is
−76.177 dBFS / 58.514 dB. They are explicitly different window/analysis
definitions, not inconsistent versions of one measurement. Old raw-bottom
versus new ordinary-primary recordings also differ in routing and active
amplifiers, so that comparison is not a controlled gain-only experiment.

The previous 66.547 kHz result is a **weak correlated recorded line, not
verified airborne speaker output**. It does not establish a usable acoustic
bandwidth to that frequency or validate a smooth response to 96 kHz.

Likewise, disappearance of the 54.283 kHz line with the amplifier disabled
supports dependence on the amplifier's operating state, but amplifier-off
also changes electrical conditions. It is not absolute acoustic isolation and
cannot independently exclude electrical coupling. The existing recordings
remain useful combined-path evidence; they must not be relabeled as a
calibrated airborne speaker transfer function. These limits do not depend on
whether this UI-audio correction succeeds.
