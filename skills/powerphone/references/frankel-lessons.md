# Pixel 10 (`frankel`) case-study lessons

Read this only when working in `pixel_aosp_manifest` or using Frankel as a
design example. The repository docs and retained result directories are the
canonical live status. Exact addresses, digests, PCM numbers, mixer controls,
and scheduler identities are specific to one Frankel vendor build and must not
be copied to another phone.

## Hardware-qualified transport state

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

PCM card 0 device 0 runs stereo S32_LE at 192000 Hz with 1920 frames by two
periods. The selected F1 profile uses source 0, a 192-frame firmware quantum,
two physical S32 slots, and a 12.288 MHz TDM clock. It patches the two existing
`AudioEntrypoint` getters in place to implement `a3 ? 192 : 1920`; a prior
vtable redirect into a zero-filled cave caused an illegal instruction during
D0 PREPARE and is deliberately absent.

On the exact final integrated boot, the individual bottom and earpiece routes
each consumed a 4608000-byte three-second WAV with zero xruns. Measured elapsed
times were 3.4649 and 3.5642 seconds respectively, including bounded first-ring
startup handling. Java `AudioTrack` and native AAudio then passed on both exact
BUS routes at an observed S32/stereo/192 kHz hardware rate, with complete
1536000-frame transfers, zero framework underruns/HAL xruns, and stable AoC
counters.

This qualifies the 192 kHz transport and Android API routes. It does not
independently qualify either transducer's ultrasonic response. Phone
speaker-to-phone-microphone spectra are only combined-path evidence; calibrated
external wideband source and receiver measurements remain necessary for
per-endpoint acoustic-bandwidth claims.

## Required target-specific closure

The D0 frontend depends on a paired kernel state. The retained selected
`aoc_alsa_dev_util.ko` digest is
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

The selected F1 table contains 46 words: 24 cave words followed by 22 hook
words. Eight hook words replace the two existing AudioEntrypoint getter
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
