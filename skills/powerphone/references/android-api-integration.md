# Android HAL, policy, and API integration

Start only after the exact physical route works through tinyALSA. The goal is
to preserve that route unchanged while making it intentionally selectable by
research clients.

## 1. Identify configuration ownership

Do not assume the AOSP example audio HAL owns the phone. Resolve the running
binder instances, service binaries, RC files, VINTF declarations, product
packages, policy XML includes, effects configuration, and installed bytes.
Distinguish the proprietary/default module responsible for ordinary media from
any module being added for research.

Use runtime evidence as well as source references:

- registered AIDL `IModule` instances or the corresponding HIDL/legacy modules;
- `dumpsys media.audio_policy`, `media.audio_flinger`, and active tracks;
- installed audio policy and platform configuration under vendor/system;
- service and SELinux denials; and
- actual ALSA `hw_params` while a client is active.

A module that compiles or appears in `PRODUCT_PACKAGES` is not integrated until
its applicable binary, service/manifest declarations, policy/configuration,
runtime instance, and client-visible ports are all present.

## 2. Choose the platform-appropriate HAL boundary

Modify the primary HAL/configuration when its source and route contract are
available and a high-rate profile will not change ordinary media, calls,
alarms, hotword, camera, or telephony behavior.

For a dedicated research image, another valid design is to keep a physical
speaker or microphone transport fixed at its qualified maximum rate while
allowing AudioFlinger to convert ordinary application rates at the framework
boundary. This preserves normal application compatibility without repeatedly
reconfiguring a fragile DSP/backend path. Make the conversion boundary
intentional and observable: the HAL must publish the fixed hardware profile
before AudioFlinger chooses its thread geometry, open the same rate at ALSA,
and report positions/timestamps in hardware frames. Test both exact-rate
research clients and ordinary 44.1/48 kHz clients. Do not extend this policy to
calls, hotword, or capture paths whose processing contract has not been
qualified.

First identify whether the device actually uses AIDL, HIDL, or a legacy audio
HAL. On an AIDL device whose proprietary primary module hard-codes a legacy
rate, a target-scoped additive module with explicit `TYPE_BUS` devices can
avoid patching AudioFlinger. On HIDL or legacy devices, extend the existing
generation or its policy contract instead of grafting on an unrelated AIDL
design. Keep research routes non-default and require exact client selection.

Policy separation does not lock the physical hardware. If another HAL process
can open the same PCM or change its mixer/DSP route, establish a real
cross-process exclusion mechanism or quarantine that conflicting path for the
research image. A sidecar-local mutex plus mixer readback is not sufficient.

Expose one address per independently selectable physical endpoint or unresolved
logical input. Do not advertise Bluetooth, USB, vibrator, virtual routes,
unsafe simultaneous-amplifier combinations, unsupported channel sets, or
ordinary processed microphones through the research module.

The HAL contract should fix or tightly validate:

- sample rate, PCM format, channel layout, period frames/count, and PCM node;
- the complete mixer state and physical amplifier or logical microphone;
- mutual exclusion for shared DSP engines and PCMs;
- readiness/restart generation and ownership before every stream start;
- active ALSA parameters after open; and
- close-before-route-off cleanup on success, API error, or client death.

The framework/FMQ queue and ALSA hardware ring need not have the same size.
Decouple them explicitly when Android callback cadence needs a different queue
from a hardware-qualified period/ring, and report both geometries in evidence.
When tinyALSA recovers EPIPE internally, expose and inspect its cumulative xrun
counter; a nominally successful read/write must not hide an underrun or
overrun. Any bounded startup exception must end before client audio is
consumed, establish an explicit baseline, and keep subsequent xruns fatal.

For exact research routes, refuse implicit resampling and format conversion.
If conversion between an API container and the proven ALSA container is
necessary, make it explicit and prove that it does not change the research
sample rate or spectral content. For an explicitly fixed-rate ordinary route,
instead prove that conversion occurs only on the intended client side of the
HAL boundary and that the ALSA/backend transport remains fixed at the qualified
rate.

## 3. Handle boot-volatile hardware state

If the direct path needs a volatile DSP/firmware mutation, ship a confined,
target-scoped helper and a readiness property owned by that helper. Clear the
property before applying anything and after a DSP restart or failed readback.

Run the helper after its device/driver exists but before another owner can open
the shared PCM. Beware boot dependency cycles: waiting for full boot may be too
late, while stopping audioserver without a bounded release path can deadlock
system-server audio initialization. Make the transaction boot-local and
one-shot, and bound internal retries. On success, publish research readiness
before releasing clients. On failure, keep the research routes disabled and use
a deterministic finalizer to restore or quarantine touched state. Release
ordinary audio only from that proven-safe state; otherwise enter the declared
reboot/recovery path instead of leaving boot blocked.

The exact init trigger and latch are target-specific. Claim one-shot state
before any blocking command, prevent replay during later service cycles, and do
not synchronously wait for hardware produced by a later blocked init action.
Derive the real firmware-loader/device-ready dependency from the target's RC.

Keep host-side post-boot patch scripts for qualification only. A finished image
must establish or reject its own runtime state.

## 4. Keep the research path unprocessed

Use `UNPROCESSED` for microphone research and verify the active capture effect
chain, the platform support property, and the routed device—not just the
requested source. Disable or bypass automatic gain,
beamforming, spatial processing, noise suppression, echo cancellation,
high-pass/DC filtering, and vendor preprocessors that decimate or impose a
legacy passband. An empty AudioFlinger effect list does not prove that the HAL
or DSP is unprocessed. Leave ordinary capture behavior unchanged when possible.

Avoid global AudioFlinger patches merely to advertise a rate. First use exact
device profiles, routes, direct flags where appropriate, an additive HAL, and
effect configuration. Patch framework source only after runtime evidence shows
that a framework invariant—not the HAL, policy, or DSP—is the remaining limit.

## 5. Exercise every public API and route

Build a target-aware test app that enumerates devices and selects only exact
research addresses. Log requested, negotiated, client, HAL/device, and active
ALSA state separately.

For every output address test:

- Java `AudioTrack` routed with the intended `AudioDeviceInfo`;
- native AAudio output using the intended device ID and exact rate; and
- one physical amplifier/transducer at a time.

For every input address test:

- Java `AudioRecord` with `UNPROCESSED` and the intended device;
- native AAudio input using the intended device ID and exact rate; and
- one logical microphone selector at a time.

During each run require the exact route to be active and inspect ALSA
`hw_params` or an equally direct target-supported geometry observer;
API-reported rate alone can describe a resampled client stream. Do not fail a
working stream merely because a driver omits the procfs node, but do not treat
the omission as proof either.
Record callback sizes/timestamps, underruns/overruns, short reads/writes, and
DSP counters. Ensure tests fail when an address is missing rather than silently
falling back to the primary device. For Java, require `setPreferredDevice` to
succeed and `getRoutedDevice` to match after start; for AAudio, verify the
post-open device, hardware rate, and hardware format rather than assuming the
requested builder values were retained.

Repeat the route after standby/reopen, screen-off suspend/resume, and an allowed
audioserver/HAL restart. If the DSP can restart independently, prove that the
research readiness generation is revoked and that no stale stream resumes.
Document any deliberate loss of stock media, call, camera, assistant, or hotword
behavior.

## 6. Integrate and attest the image

Keep the feature target-scoped and default-off until qualified. Pin source
patch bases and hashes; attest the exact kernel/module state, firmware helper,
HAL binary, RC, VINTF fragment, SELinux policy, properties, and configuration
installed into target-files and final images. Exclude retired prototypes and
non-redistributable OEM artifacts from a public source release.

Map every changed file to its containing partition. A system-only GSI cannot
carry a vendor kernel module, DT/DTBO, vendor HAL, or DSP firmware change; the
flash bundle must include every touched partition and its AVB parent. Its runner
must verify target and partition topology, state wipe semantics explicitly,
avoid stale-slot mixtures, and identify known-good rollback images.

After flashing the exact package, prove boot completion, the expected build,
helper readiness, binder registration, route enumeration, and all direct/API
tests again. Tie the qualification record to the packaged image identity and
leave the tested image installed when that is the requested outcome. Treat the
package as unqualified until cold/warm boot and required lifecycle tests pass on
those exact bytes.
