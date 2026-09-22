# Pixel 10 (`frankel`) case-study lessons

Read this only when working in `pixel_aosp_manifest` or using Frankel as a
design example. The repository docs and retained result directories are the
canonical live status. Exact addresses, digests, PCM numbers, mixer controls,
and scheduler identities are specific to one Frankel vendor build and must not
be copied to another phone.

## Hardware-qualified transport state

The September 11 pitch investigation supersedes earlier playback qualification
based on rates, elapsed time, and successful APIs alone. See
`docs/frankel-playback192-20260911.md` for current live and flashed-image status.
Do not treat the historical API results below as acoustic pitch validation.

The exact boot-integrated image reached `phase=complete`, PDM and speaker
readiness `1`, SELinux enforcing, and unchanged AoC restart/coredump counters.
The OEM-authenticated AoC image remains stock. The selected F1 changes are
guarded, reboot-volatile runtime mutations made only after the stock firmware
has loaded.

### Capture

PCM card 0 device 10 runs mono S16_LE at 192000 Hz with 1920 frames by four
periods. A reboot-volatile F1 profile selects one logical microphone at a time,
uses a 6.4 MHz PDM profile, and produces 96 fresh frames every 0.5 ms.

All three logical selectors completed direct 2.96-second captures of 568320
frames. Each retained file passed 5856 interior 96-frame-block checks with no
zero second halves, repeated halves, or short-lag replay. Java `AudioRecord`
with `UNPROCESSED` and native AAudio also passed on all three exact BUS routes
at an observed 192 kHz hardware rate with no xrun or AoC restart.

The captures contain energy above 48 kHz and a rising high-frequency floor.
That is combined evidence for fresh 192 kHz transport and is consistent with
PDM noise shaping; it is not proof of ultrasonic acoustic sensitivity or
absence of an internal synthesis stage. No characterized external ultrasonic
source result or logical-selector-to-enclosure-hole map is retained.

### Playback

The corrected September 11 live path is PCM0,D5/source5/EP6, stereo S32_LE
at 192000 Hz, 1920-by-two ALSA geometry, full 3840-frame initial fill, and
192 frames per one-millisecond DSP block. The two physical S32 slots use a
12.288 MHz clock. Both H0 and F1 must agree on the 1536-byte block, including
the enclosing copy/advance caller, packed mixer stride, retained TX offset,
cache extent, and balanced eight-byte DMA load/store bursts.

The bottom speaker's 15-second 12 kHz run measured 11999.999466 Hz across
14.89 seconds of active audio, with zero detected phase discontinuities,
dropouts, or clipping. Both independently selected amplifiers produced the
intended 54.283 kHz component in D10 recordings. This is combined-path
Nyquist-domain evidence above the limit of a 96 kHz transport, not a flat
response claim through 96 kHz or a calibrated transducer measurement.
Refer to the dated report for whether the newly packaged image has also
passed reboot and API qualification; live success does not establish that.

The earlier D0/source0 and incomplete D5 profiles are historical experiments.
Do not restore their getter vtable redirects, stale 48-frame caller counts,
four-word packing, or compensating doubled-cache patch.

### Ordinary playback at fixed hardware rate

Frankel's proprietary primary AIDL HAL originally exposed its primary and
deep-buffer built-in speaker use cases at 48 kHz and selected D1/D5 frontends.
The first fixed-rate patch combined three independent changes: advertise 192
kHz, replace D1/D5 geometry, and redirect both PCMs into D0/source 0. It moved
frames with zero reported underruns but was acoustically silent. A later
rate-only D1/source-1 trial asserted AMixSPKR under the native-q192 profile.
Both results are rejected experiments.

The historical fixed-rate state advertises 192 kHz on the primary, deep-buffer, and three
physical interface profiles; maps both D1 and D5 opens to D5 with 1920-by-two
geometry; selects AoC source 5; and joins the mixer route to EP6. It also marks
the deep-buffer port `DIRECT`. Without that last change, AudioPolicy kept both
primary and deep-buffer mixers open against the same non-shareable source-5
ring. UI-to-media overlap then made a nominal eight-second AudioTrack finish in
6.299 seconds and produced 97 missing 20 ms windows in simultaneous capture,
despite AudioTrack reporting zero underruns. With deep-buffer removed as a
persistent ordinary-mix candidate, UI and media share one 192 kHz primary
thread. Three forced-overlap runs completed in 8.005, 8.015, and 8.008 seconds
with zero underruns, zero interior 20 ms acoustic dropouts, and AoC
restart/coredump 0/0.

On that exact image, the five-second Java/AAudio matrix passed both D0 speaker
BUS endpoints and all three D10 microphone BUS endpoints at 192 kHz. Treat the
primary route as a compatibility layer, not an exact-rate research measurement;
the address-selected PowerPhone BUS routes remain the evidence path for exact
192 kHz clients.

## Required target-specific closure

The D0 frontend depends on a paired kernel state. The retained selected
`aoc_alsa_dev_util.ko` digest is
`398eaca28da2d97431b1398b5df93e34e594389fa691616416354b4705bde4e3`;
with the orthogonal EP6 admission word normalized, the D0 profile digest is
`37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6`;
the paired zero-write-pointer-reset `aoc_core.ko` digest is
`f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c`.
An image that combined the ALSA module with stock core reproduced startup and
watchdog failures. Always select, attest, package, and flash the pair together.

The final runtime uses the exact stock A32 allocator. After Android audio has
warmed AoC, the one-shot F1 allocation succeeds and the complete four-bank
speaker rebase verifies. A bounded early preparation path may live-patch the
A32 allocator fallback only if the exact short-lived OUTPUTTER timer and safe
work-pool state coexist; its absence is not a failure when stock A32 later
allocates successfully. In that proven path
`vendor.powerphone.aoc_a32_allocator.ready=0` is intentional. The A32 worker
current/base priority remains stock at 7/7.

The September 11 F1 table contains 75 words: 44 cave words followed by 31 hook
words. The retained TX block field is additionally updated in the buffer-rebase
transaction, and the conditional H0 geometry is a separate six-word profile.
Eight F1 hook words replace the two existing AudioEntrypoint getter
functions in place at `0x403f03ac` and `0x403f03bc`. Do not restore the
retired getter vtable redirects or their zero cave.

## Boot and service lifecycle

The boot orchestrator keeps audioserver and the PowerPhone sidecar lifecycle
paired while it warms the stock control plane, applies and certifies the
speaker F1/H0 transaction, applies D10 last, and publishes independent
readiness properties. D10 runs last because its resident diagnostic profile
can prevent the speaker factory-mailbox transaction; its final F1 cache flush
also covers the speaker edits.

Direct tinyALSA qualification deliberately stops Android's owners. When
returning to API testing, restart the sidecar together with audioserver:

```sh
stop audioserver
stop vendor.audio-hal-powerphone
start vendor.audio-hal-powerphone
start audioserver
```

Restarting audioserver alone leaves sidecar-owned startup port configurations
alive and can fail new streams with `port config ... already has a stream
opened on it`. This is a lifecycle failure, not a sample-rate failure.

## Repository map

- `docs/frankel-aoc-d10-raw192-runtime.md` describes capture.
- `docs/frankel-aoc-speaker-runtime.md` describes playback and boot mutation.
- `docs/frankel-playback192-20260911.md` supersedes the historical playback
  status with actual pitch, continuity, and ultrasonic self-loop evidence.
- `docs/frankel-audio-api.md` and
  `docs/frankel-powerphone-image-integration.md` describe HAL/build integration.
- `docs/frankel-physical-audio-map.md` records proven and unresolved identities.
- `scripts/audio/frankel/` contains guarded direct and API wrappers.
- `tools/audio/device/frankel_aoc_d10_patch/`,
  `tools/audio/device/frankel_aoc_speaker_patch/`, and
  `tools/audio/device/frankel_powerphone_d10_bootstrap/` contain device helpers.
- `../csr460-powerphone` contains the Java/AAudio test application.
- `work/audio-research/frankel/final-inplace-getters-stock-a32-20260905/`
  contains the exact final direct and API evidence.

## Durable lessons

1. Start from the path that owns the hardware; a plausible AP-PDM or alternate
   PCM path may lack clocks, security, DMA, or firmware ownership.
2. Preserve the hardware's real-time quantum and locate every implicit frame,
   ring, reset, getter, and timeout assumption when widening rate.
3. A binary patch that is correct in a decompiler can still enter through an
   invalid code address. Prefer in-place replacement of a proven function when
   the firmware ISA/cave execution boundary is uncertain.
4. Keep firmware-task scheduling separate from Linux process scheduling and
   change either only when direct evidence identifies it as the bottleneck.
5. Treat independently addressable amplifiers as separate endpoints. Do not
   infer that a simultaneous route is safe under a new DSP profile.
6. Treat tinyALSA header/library identity, sidecar service lifetime, coupled
   kernel modules, firmware state, init, and AVB partitions as datapath state.
7. Separate transport qualification from physical acoustic bandwidth. Correct
   rates, clocks, bytes, fresh blocks, APIs, and spectra from an uncalibrated
   self-loop still do not measure each transducer independently.
8. Patch one primary-path dimension at a time. Rate-only advertisement can be
   correct while a simultaneous PCM redirect is silent; require audible output
   and wall-clock duration in addition to frame/xrun counters.
9. Count hardware owners, not just routes. Two AudioFlinger outputs can report
   the same correct 192 kHz geometry and zero underruns while racing one DSP
   source ring; force UI/media overlap and compare wall time with a simultaneous
   physical capture before declaring ordinary audio stable.
