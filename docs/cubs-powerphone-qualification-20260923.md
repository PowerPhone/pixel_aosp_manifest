# Cubs PowerPhone hardware qualification, 2026-09-23

Status: **hardware-qualified within the research scope below**. The exact v7
images passed the isolated Android API matrix, direct-ALSA and acoustic-reference
tests, complete flash, and repeat boot. This is a research-primary replacement,
not a stock-feature release or a full 96-kHz speaker-acoustic-bandwidth result.

The separate release is
[`artifacts/cubs-powerphone-192k-20260923/`](../artifacts/cubs-powerphone-192k-20260923/).
It contains `flash-all.sh`, all 14 associated images, `PowerPhoneLab-debug.apk`,
and the original qualification recordings/logs under `evidence/`.

## Qualification boundary

The tested Pixel 11 is `cubs`, serial `65270DLKY000MQ`, slot A, Android 17
userdebug, with kernel `6.12.92-android16-6-maybe-dirty-4k`. The original
`artifacts/cubs` and all Frankel images remain unchanged. No userdata was erased.

- Both speakers use 192000-Hz stereo S32 D5 transport, two 32-bit TDM slots.
- Three individually selectable microphones use native 192000-Hz mono S16 D10
  capture. Logical MIC0/1/2 map to physical PDM lanes 0/2/3; enclosure-hole names
  are not measured. Simultaneous RAW3 is a separate direct experiment, not the
  automatic boot/API profile.
- The TAS2572 amplifier accepts 192-kHz serial data but internally downsamples
  it to 96 kHz. Real sweeps show folding above 48 kHz. This release does **not**
  claim a 96-kHz speaker acoustic passband. See the
  [hardware report and TI sources](cubs-powerphone-bringup.md#speaker-bandwidth-caveat).
- All six Java/native microphone captures show a 12.52–12.94 dB noise-density
  rise from 48–60 kHz to 84–95 kHz. This meets the user's agreed noise-shaping
  milestone; it is not calibrated microphone acoustic sensitivity to 96 kHz.
- One input and one output may run together. The single D5 hardware output
  cannot mix ordinary UI audio with another research output. Bounded contention
  recovery avoids a permanently poisoned stream, but cannot guarantee lossless
  concurrent playback. Isolated tests require observed keyguard/PCM quiescence.
- Calls, Bluetooth **audio**, headset audio and hotword features are not
  implemented. The original proprietary primary HAL is removed. AudioFlinger
  itself is not patched for sample-rate support.

## Exact flashed image and boot

The complete 14-image `bundle-v7` was flashed using its own standalone
`flash-all.sh`. Physical images used bootloader fastboot; logical images used
fastbootd. Top-level vbmeta used `--disable-verity --disable-verification`.
The runner preserves userdata and the active slot, and requires the captured
bootloader/baseband versions. It does not contain a factory-firmware restore.

Initial v7 boot reached native readiness at uptime **6.529 seconds**, after
2.802 seconds of helper runtime. SELinux remained enforcing, both readiness
flags were 1, and AoC restart/coredump counters were 0/0. No temporary HAL bind
mount or host firmware warm-up was used. The boot helper applies the exact
profile before releasing audioserver, without waiting for launcher.

After the direct-ALSA trials, a full reboot automatically restored API mode.
Fresh boot ID `7f763e6b-2b67-4c7d-bbf4-733fe42cd75c` reached readiness at
**6.775 seconds**, with helper runtime 2.830 seconds. Android boot completion
was observed by uptime 16.70 seconds. SELinux stayed enforcing, both services
were running, and AoC counters stayed 0/0. Bluetooth also remained ON with
zero recorded crashes across that reboot. Fresh post-boot API/acoustic trials
then passed without manual firmware application or an audio-service restart.

Evidence root (local, ignored):
`work/audio-research/cubs/primary-hal-integration-20260923/`.

| Test | Actual result | Evidence under that root |
| --- | --- | --- |
| Complete flash | All 14 images written; no wipe | `flash-bundle-v7-console.log`, `bundle-v7/flash-powerphone-*.log` |
| Enforcing boot / early readiness | Ready at 6.529 s, AoC 0/0 | `bundle-v7-boot1/` |
| Java AudioTrack and native AAudio | Both speakers, four 8-second runs, PASS | `bundle-v7-exclusive-api-matrix/run-status.tsv` |
| Java AudioRecord UNPROCESSED and native AAudio | All three mics, six 8-second runs, PASS | Same matrix, `captures/`, `recording-evidence/QUALIFICATION.md` |
| AAudio top / mic2 reference | Complete 30-second 20731-Hz tone, continuity PASS | `bundle-v7-duplex-aaudio-top-30s/` |
| Java bottom / mic0 reference | Complete 30-second 20731-Hz tone, continuity PASS | `bundle-v7-duplex-java-bottom-30s/` |
| Java top / mic1 and AAudio bottom / mic2 | Both 8-second tones, continuity PASS | `bundle-v7-duplex-java-top-8s/`, `bundle-v7-duplex-aaudio-bottom-8s/` |
| Ordinary Java AudioTrack at 48 kHz | Correct acoustic pitch and continuity; primary remains 192 kHz | `bundle-v7-ordinary48/` |
| Non-audio Bluetooth stack enabled | ON after 25 s, zero crashes; audio profiles disabled | `bundle-v7-bluetooth-enable/` |
| Direct tinyplay/tinycap: bottom/mic0, top/mic1, top/mic2 | Three complete 30-second tones, correct pitch, zero detected phase events/dropouts/clips | `bundle-v7-direct-*-30s-uncompressed/`, `bundle-v7-direct-report.md` |
| Repeat boot | Fresh automatic readiness at 6.775 s, enforcing, AoC 0/0 | `bundle-v7-boot2/` |
| Post-boot AAudio top/mic1 and ordinary 48-kHz bottom/mic0 | Both 8-second API/acoustic tests PASS | `bundle-v7-postboot-aaudio-top/`, `bundle-v7-postboot-ordinary48/` |

Duplex reference recording uses Java AudioRecord UNPROCESSED; native AAudio
input is separately tested by the six-capture matrix. Original WAV samples are
retained. The fixed 0.1–7.9-second input interiors have no sustained zeros,
repeated 96-frame blocks or clipping. Startup zeros of 5–5.5 ms and repetitions
ending by 10.896 ms are reported, not trimmed from the original recordings.
The three native input full-run timestamp regressions were 191990.192,
191974.651 and 191966.119 Hz, with no reported XRUNs or nonmonotonic timestamps.
Timestamp models and sample counts are not independent physical-clock proof.

Tone analysis retains the complete detected tone, excluding only fixed 50-ms
boundary fades. Its accepted results require correct pitch, expected duration,
no detected phase events over 0.35 rad, no dropouts/clipping and sufficient
line contrast. This is measured continuity, not a claim of literally zero jitter.

The three direct recordings contain 6,520,320 frames each, or 33.96 seconds for
a requested 34-second capture. Their 40-ms startup deficit remains reported;
the entire 30-second tone is present. Direct-mode logs retain auxiliary Awinic
startup warnings, boundary speaker-interval messages and H0's inactive-source
messages on the bypassed path. They are not described as universally clean
logs. No AoC restart or measured interior tone discontinuity occurred.

API acoustic trials used bounded peak 0.08, with MUSIC/BUS volume 25/25 set
before playback. A low existing volume can make a coherent ultrasonic pilot
too weak for phase analysis. Volume is not changed during measured playback.
See the per-run reports for exact levels, timestamps and quiet spectra.
After testing, ordinary MUSIC volume was restored to its prior 8/25 and
Bluetooth to OFF; the research BUS volume remains separate. The tested image
was left booted in API mode, with both PCMs closed, both ready flags set and
AoC counters 0/0 (`bundle-v7-boot2/final-idle-state.txt`).

## Retained failures

Earlier trials are not reclassified as passes: the nested AoC debug-reader
failure, full-ring HAL start EPIPE, background framework-silenced capture,
capture-FLUSH ownership failure, weak-volume phase failures and v6 cold-boot
permanent stream error remain recorded in
[integration history](cubs-primary-integration.md).

The first v7 matrix remains **9/10 aggregate FAIL**. Its Java TOP research
stream completed correctly, but a simultaneous queued unlock sound failed the
global HAL-error gate. The primary recovered when D5 became free. See
`bundle-v7-api-matrix/CONTENTION_ATTRIBUTION.md`; this is recovery evidence,
not supported concurrent mixing. The later isolated 10/10 matrix does not erase
that failure or filter out HAL errors.

The first final-image direct trial, `bundle-v7-direct-bottom-mic0-30s`, stopped
before touching audio because the default ADB upload timed out after 60 seconds.
The device remained responsive. Uploading the same 46,080,044-byte probe with
`adb push -Z` completed in 1.283 seconds; Cubs direct wrappers now disable
transfer compression in both directions. This changes transport only, not WAV
samples, firmware or audio gates. The original failed upload record is retained.

## Use and reproduce

- [API addresses, Java/AAudio examples and boot readiness](cubs-audio-api.md).
- [Direct tinyALSA capture/playback scripts and quarantine](../scripts/audio/cubs/README.md).
- [API acoustic reference harness](../scripts/audio/cubs/API_DUPLEX.md).
- [Source, boot integration and matching image assembly](cubs-primary-integration.md).
- [14-image packaging and guarded flashing](../scripts/audio/cubs/POWERPHONE_BUNDLE.md).
- [PowerPhone's reusable Cubs lessons](../skills/powerphone/references/cubs-lessons.md).

The app source is the sibling workspace `csr460-powerphone`, package
`com.csr460.powerphone`. Generated images and proprietary baseline material are
local artifacts, not a claim that those blobs can be redistributed on GitHub.
