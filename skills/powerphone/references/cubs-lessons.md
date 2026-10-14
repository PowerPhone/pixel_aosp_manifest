# Cubs: hardware limits and replacing a proprietary primary

Use the repository's dated Cubs qualification reports for current release
status. These are observed failure modes, not a universal target recipe.

## Separate serial input rate from amplifier processing rate

Cubs uses TI TAS2572, unlike the amplifier assumed from the Frankel case.
Its documented 192-kHz serial input is internally downsampled to 96 kHz.
Actual sweeps showed folding above 48 kHz even with correct 192-kHz TDM
clocks and source cadence. A wider kernel mask or DSP bypass cannot remove
this internal silicon stage. Keep serial transport and acoustic passband
as separate results; do not guess rate bits from a similarly named codec.

The three logical microphone selectors map to physical controller IDs 0, 2
and 3, not proven enclosure openings. The working native capture selected
the 6.4-MHz PDM profile, changed the sampling edge and produced 96 frames per
0.5 ms. Increasing the paired RAW-processing budget eliminated long-run
control starvation. These are firmware profile fields, not measured CPU
frequency or a microphone manufacturer's guaranteed maximum clock.

Respect the user's measurement scope. If they accept a near-Nyquist
noise-shaping ramp as the microphone milestone, retain fixed quiet-window
PSD, fresh samples and continuity evidence. Do not require an unavailable
external source to complete that narrower milestone, but do not rename it
calibrated ultrasonic acoustic sensitivity.

## Make primary replacement a complete service transition

A separate executable can own the default AIDL module/config/effects
interfaces, publish fixed high-rate built-in profiles and expose exact BUS
research endpoints. Explicitly disclose unsupported telephony, Bluetooth
audio, headset and hotword behavior. Retaining the old primary RC as
`disabled` was insufficient: platform audioserver actions explicitly started
that service name. Remove its service definition and obsolete VINTF owners.

If Bluetooth remains installed without Bluetooth audio interfaces, disable
its corresponding audio-profile flags before that stack initializes. Removing
only the factory manifest left LE Audio enabled and caused repeated aborts.
Do not disable unrelated BLE/HID/network features merely to silence that
audio failure. Verify property load order: donor product values can override
a vendor property file.

## Prefer observed readiness before launcher

The native helper waits for actual AoC/control readiness while audioserver
is gated, applies exact guarded firmware mutations, flushes caches and
publishes profile plus boot-generation readiness. It need not wait for
launcher. Give failures a bounded release path with research routes inert.
Use vendor-owned mirrors rather than granting access to private init
properties. Where per-stream procfs is unavailable, ALSA control PCM_INFO
reservation counts can establish idle ownership without broad proc-FD scans.

The AoC diagnostic node allows only one reader. A cache-flush transaction
that opened another reader during the first reader's lifetime failed with
EBUSY after mutation. Close the reader before restoring the dispatch hook
or performing another readback; reboot after an incomplete transaction.

## Copy the whole working PCM contract, not a favored buffer rule

Cubs tinyplay worked with 1920-by-four S32 stereo periods and a half-ring
3840-frame automatic start threshold. The HAL's full-ring 7680 start failed
with raw WRITEI EPIPE; matching tinyplay fixed the tested API runs. Both
paths otherwise used the same blocking library and SW parameters. This
does not prove the precise kernel failure mechanism, and it is not a rule
that half-ring is universally better than full prefill. Keep Frankel's
independently qualified geometry separate.

In AIDL capture, a PAUSED→FLUSH transition moves the worker to STANDBY.
An inherited no-op flush left D10 and its lease live, so the subsequent
empty-device disconnect was rejected as an active route change. Closing
through the existing standby path on the serialized input worker fixed
normal teardown without relaxing the live-route-change guard.

A separate cold-boot handoff exposed another state-machine boundary: the AIDL
output worker treated a temporary D5 lease WOULD_BLOCK as permanent ERROR.
The Cubs correction waits briefly for the prior owner to close and
keeps only START contention retryable. START precedes the framework FMQ data
write, so a rejected start does not consume or replay that queued payload.
However, AudioFlinger can discard its current mixed chunk after a failed HAL
write. Retryable is therefore not synonymous with lossless: require the short
handoff wait to succeed for a passing stream, retain timeout errors, and do not
claim simultaneous playback on a non-shareable PCM. Qualify this boundary on
the actual packaged cold boot, not just after a manual audio-service restart.
On the actual v7 cold boot, the research stream completed correctly while a
queued unlock sound timed out repeatedly. The primary stream recovered when
the research owner closed. That demonstrates recovery, not lossless mixing;
the aggregate overlapping trial remains failed.

An idle snapshot immediately after dismissing keyguard can precede a queued
unlock sound. Before an exclusive experiment, observe the keyguard transition
finished and a bounded span of consecutive PCM-closed observations. Preserve
busy observations and retain every later HAL error. This is a test ownership
precondition, not extra DSP warm-up, and cannot prevent future user/UI overlap.

## Verify the test app is actually recording

KEEP_SCREEN_ON does not wake an already sleeping display. An Activity can
launch while the display sleeps, produce valid-looking samples initially,
then lose foreground microphone AppOp permission and receive zeros after
about five seconds. Wake/unlock, check resumed activity and awake state,
and reject framework-silenced recordings; do not bypass permission policy.

Exclude a fixed startup interval and retain full-run timestamp observations.
A first priming timestamp versus one sample two seconds later biased one
otherwise complete capture; the same strict full-run regression used for
playback gives a better clock observation without weakening rate tolerance.

Android BUS volume can differ from ordinary speaker volume. In the actual
Cubs test, index 8/25 attenuated a pilot by roughly 41 dB relative to direct
ALSA, making short-window phase noise look like thousands of slips. Read
the active device's volume, set it before the qualified run, keep the stimulus
bounded and retain the original weak result. Do not alter volume mid-run or
raise amplifier gain to compensate blindly.
