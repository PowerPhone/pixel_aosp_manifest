---
name: powerphone
description: Raise the maximum stable end-to-end transport rate of an Android phone's built-in speakers and microphones and independently qualify physical acoustic bandwidth, from codec/PDM hardware through kernel, DSP firmware, tinyALSA, the audio HAL, AudioTrack, AudioRecord, and AAudio. Use for wideband or ultrasonic research on an existing AOSP userdebug device tree; do not use for ordinary media configuration, Bluetooth, USB, or virtual audio.
---

# PowerPhone

Produce a reproducible userdebug image whose explicitly named physical acoustic
endpoints run at the highest stable rate each complete signal chain supports.
Report that transport rate separately from measured acoustic bandwidth: a
nominal `192000` or `384000` value is only a configuration claim until clocks,
continuity, and the physical passband are measured.

Assume an AOSP userdebug tree already boots. Do not infer permission to flash,
write firmware/DSP memory, change clocks, or stress transducers from that fact;
use the authorization and recovery boundary of the current task.

## Read the relevant procedure

- Before inspecting or changing kernel, DT, codec, PDM, DSP, firmware, mixer,
  clock, or tinyALSA behavior, read
  [references/hardware-bringup.md](references/hardware-bringup.md).
- Before exposing a proven tinyALSA path through Android, read
  [references/android-api-integration.md](references/android-api-integration.md).
- Before designing measurements or claiming success, read
  [references/qualification.md](references/qualification.md).
- When working in this repository or adapting its Pixel 10 work, also read
  [references/frankel-lessons.md](references/frankel-lessons.md). Exact offsets,
  digests, PCM numbers, and mixer controls are target/build-specific and must
  never be copied to another phone.
- For wrong pitch, repeated fragments, or a DSP path widened from a lower
  rate, read [references/playback-frame-accounting.md](references/playback-frame-accounting.md).

## Work in evidence gates

1. Inventory every built-in speaker and microphone and trace each complete
   path. Keep logical selectors, physical controllers, codec channels, and
   enclosure openings as separate identities until measured.
2. Find the lowest-rate layer. Check ALSA frontend constraints, backend DAI
   format and clocks, codec/amp limits, PDM clock and decimation, DSP service
   geometry, firmware policy, mixer routing, the device's actual HAL generation,
   and Android policy.
3. Select the maximum stable rate per endpoint, not a predetermined common
   number. Preserve period time where the hardware contract permits it while
   recomputing frame and byte geometry. Include initialization/reset semantics
   and every coupled module in the closure.
4. Qualify one endpoint at a time with direct tinyALSA. Start with amps off or
   one logical microphone, use low-level stimuli, inspect active hardware
   geometry (through `hw_params`, driver instrumentation, or another truthful
   target mechanism), byte cadence, fresh blocks, logs, restart counters,
   XRUNs, and cleanup.
5. Prefer a reboot-volatile, expected-bytes-guarded experiment before making a
   persistent image change. Apply only from a uniform known state, activate
   last, read back every mutation, and make reboot the fallback rollback.
6. Once direct ALSA is stable, expose it through the platform's existing AIDL,
   HIDL, or legacy HAL/configuration boundary. Use exact non-default research
   routes when clients need bit-preserving high-rate samples. A research image
   may additionally hold the ordinary physical transport at that rate and let
   AudioFlinger convert ordinary client rates, provided the HAL advertises and
   opens the fixed hardware geometry before framework negotiation. An additive
   AIDL `TYPE_BUS` module is one option on an AIDL device, but policy isolation
   is not hardware exclusion: coordinate or quarantine every shared PCM,
   mixer route, and DSP service. If multiple policy mix ports converge on one
   non-shareable DSP ring or PCM, leave only one persistent mixer eligible for
   ordinary clients; matching rates and routes do not make two HAL handles safe.
   Avoid AudioFlinger source changes unless the
   HAL/configuration contract cannot express the path.
7. Test Java `AudioTrack`, Java `AudioRecord` using `UNPROCESSED`, native
   AAudio playback, and native AAudio capture while independently observing
   the actual ALSA route and geometry.
8. Prove physical bandwidth and transport continuity; call sample-clock jitter
   only when an appropriate clock or phase-noise measurement supports it. Then
   integrate guarded boot-time activation, lifecycle handling, build
   provenance, endpoint scripts, API tests, documentation, images, and a flash
   runner. Test the exact packaged image on hardware.

## Non-negotiable interpretation rules

- A codec data sheet, mixer enum, accepted `hw_params`, WAV header, sample
  count, API-reported rate, or high-frequency electrical noise is not alone
  proof of end-to-end acoustic bandwidth.
- Backend enums do not widen a frontend PCM, and widening a kernel rate mask
  does not prove that firmware stopped decimating or resampling.
- PDM clock, oversampling ratio, decimator output rate, PCM rate, DSP block
  cadence, and Android client rate are related but distinct quantities.
- When changing ring geometry or reset code, prove empty/full semantics at zero
  and wrap, first-write behavior, and producer/consumer ownership. Track every
  coupled binary module needed for that behavior as one state. Respect the
  user's choice to skip hashes or attestation during direct hardware work;
  neither substitutes for waveform, timing, and reboot evidence.
- Do not label `MIC0`, `PDM0`, `front`, `top`, or `camera` as aliases without a
  controlled mapping experiment. Do not treat a two-amplifier combination as
  another required endpoint when each transducer is independently addressable.
- If a DSP/audio-coprocessor restart, watchdog, mixed patch state, unknown
  ownership, active conflicting PCM, or incomplete cleanup occurs, stop that
  trial and reboot or use its proven rollback. Never repair unknown live
  firmware state by guess.
- Keep rejected experiments as clearly marked provenance, not as selectable
  image inputs. Promote only the smallest hardware-qualified closure.

## Completion boundary

For every built-in physical endpoint in scope, retain an endpoint-to-route map,
direct tinyALSA result, Java and AAudio result, active hardware parameters,
XRUN/restart evidence, transport-continuity evidence, and Nyquist-domain
acoustic evidence. State combined-loop, instrument-bandwidth, enclosure-mapping,
and untested-endpoint limitations explicitly. A finished deliverable includes
reproducible source/configuration, safe endpoint scripts, lifecycle and ordinary-
audio behavior, exact tested images, and a guarded flash-all path with rollback
and partition provenance; it does not include Bluetooth, USB, vibrator, or
virtual routes unless the user separately requests them.
