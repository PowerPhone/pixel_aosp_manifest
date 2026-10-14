# Cubs Android audio integration: opt-in research primary

## Current implementation: approved replacement, API qualification pending

The user explicitly approved replacing the proprietary primary HAL and losing
stock calls, Bluetooth, USB/headset and hotword support. The new separately
built `android.hardware.audio.service-aidl.powerphone-cubs` executable is
Cubs-only and registers `IModule/default`, `IConfig/default`, and an owned
`IFactory/default` that reports no effects/processings. It imports no
proprietary policy-engine configuration. Its configuration uses AOSP default
strategies plus explicit nonempty research volume groups/curves, including a
25-step media group. Those curves are not claimed to reproduce OEM loudness.

The original `android.hardware.audio.service-aidl.powerphone` binary remains
Frankel-compatible and still rejects Cubs. A compile-time
`POWERPHONE_CUBS_PRIMARY` flag selects the new role; changing properties cannot
turn the original sidecar into a primary. RC, VINTF, product, stock-owner
removal and SELinux integration belong to the target integration, not this
source patch. Registration is inert and may precede firmware readiness;
opening a real route cannot.

| Route | Hardware contract |
| --- | --- |
| Default built-in speaker | Bottom TAS profile; D5 stereo S32,192000 Hz,1920×4, two32-bit TDM slots |
| Addressed top/bottom BUS | Same D5 contract, independently selected TAS profile |
| Default built-in microphone | Logical0; D10 mono S16,192000 Hz,1920×4 |
| Addressed mic0/1/2 BUS | Same D10 contract, one selected logical ID |

Framework bursts are1920 frames in either direction; playback starts after
the full7680-frame hardware buffer has been accepted. One output mix port is
marked PRIMARY and reaches only the default speaker. Each addressed BUS has a
separate non-primary port to avoid startup port-config reuse, but all output
streams share one D5 lease. Likewise, all input ports share one D10 lease.
Ordinary/research output overlap and simultaneous different microphones are
rejected, not mixed into one physical endpoint. Immediate framework standby
is required for prompt sequential route handoff. No deep-buffer second
ordinary mixer, mmap, compressed offload, virtual endpoint or RAW3 profile is
advertised. AudioFlinger performs ordinary client-rate/container conversion;
the hardware profiles remain fixed. System mic mute zeros returned capture;
hardware master-volume/mute methods report unsupported so AudioFlinger applies
them in software instead of accepting no-op writes.

Before setup, at stream boundaries and during transfers, the Cubs backend
requires all of:

- `vendor.powerphone.cubs.capture.ready=1` and
  `vendor.powerphone.cubs.playback.ready=1`;
- `vendor.powerphone.cubs.profile=mono192-edge0-mcps112-d5-two-slot-v5`;
- `vendor.powerphone.cubs.boot_id` matching `/proc/sys/kernel/random/boot_id`;
- AoC `restart_count=0` and `coredump_count=0`;
- the proprietary `vendor.audio-hal-aidl` service absent or stopped; and
- no RAW3 marker when preparing a route.

Mixer setup/restoration additionally checks the generation and external owner
before individual writes. Raw I/O failures remain fatal; Cubs does not inherit
the Frankel-only second-WRITEI EFAULT exception. PCM closure precedes route
off and snapshot restoration. Exact firmware activation and exclusion of every
other stock audio owner must be supplied by the boot helper/target package.
These checks do not turn a successful compile into API or packaged-image
qualification. The TAS2572 internal96-kHz bandwidth limitation also remains.

The seven-file source delta is preserved in
`patches/hardware-interfaces/0031-add-opt-in-cubs-research-primary-hal.patch`,
after0029/0030 in `scripts/apply-source-patches.sh`. It was extracted against
exact owned pre-edit copies, not a broad diff of the populated AOSP tree.
The actual new primary and original sidecar both compiled and linked
successfully, exit0, using the populated Frankel graph:

```bash
cd work/aosp
export OUT_DIR=out_pixel/frankel USE_STOCK_KERNEL=true
source build/envsetup.sh
source vendor/google_devices/frankel/cmds-for-envsetup.sh
lunch frankel-aosp_current-userdebug
build/soong/soong_ui.bash --make-mode -j12 \
  android.hardware.audio.service-aidl.powerphone-cubs \
  android.hardware.audio.service-aidl.powerphone
```

Log: `work/audio-research/cubs/hal-primary-20260923/build-services.log`.
The new locally staged executable is
`work/aosp/out_pixel/frankel/target/product/frankel/vendor/bin/hw/android.hardware.audio.service-aidl.powerphone-cubs`.
It nevertheless requires runtime vendor device`cubs` and refuses Frankel.
This build regenerated the real graph and dependency closure; it did not
install on a phone or build an image. Current generated core/effect/sounddose
NDK interfaces areV4. The separate Cubs target image build must package the
matching dependency closure and owned manifest. In particular the linked
Bluetooth implementation library does not authorize advertising or starting
its unrelated factory/manifest fragment in this research profile.

The application's public UNPROCESSED-support query comes from framework
resource`config_supportAudioSourceUnprocessed`, not `IConfig`; target overlay
integration must set it consistently with the raw/no-effects path. The owned
init service name is`vendor.audio-hal-powerphone-cubs`. Hardware/API/boot
qualification of this new primary remains pending actual device trials.

## Historical preparatory stages (patch0029 and patch0030)

Status: source-only preparatory backend, compiled successfully with the populated
Frankel AOSP graph; **not installed on a phone, enabled for Cubs or hardware-qualified**.
The current Cubs experiments run with the stock audio owners stopped. Native
192 kHz microphone transport now passes30.013-kHz tone checks separately on
all three logical microphones with the native receiver edge0 experiment, but
full bandwidth, lifecycle and safe framework integration remain unqualified;
do not advertise it to Android from this disabled scaffold. A successful
two-second direct96 speaker interval is not a complete
API, boot, lifecycle or coexistence qualification.

## Bounded source change

Under `work/aosp/hardware/interfaces/audio/aidl/default/powerphone/`:

- `TargetConfiguration.h`: immutable per-target capture/playback rate, PCM,
  ALSA period/count, framework queue, readiness-property and mixer-rate fields;
  three microphone and two speaker endpoint identities.
- `Powerphone.cpp`: replaces the single shared rate with direction-specific
  contracts; profile, PCM-open, geometry and framework-buffer checks use the
  corresponding direction. Existing Frankel mixer transactions are retained;
  an explicitly disabled Cubs branch delegates to a separate backend.
- `CubsRoute.h`: snapshot/restore transactions for the experimental D10 mono
  capture and D5 stereo/two-slot playback routes, without changing the shared
  AIDL/FMQ implementation. RAW3 is explicitly unsupported.
- `main.cpp`: refuses registration when no target backend is qualified.
- `Powerphone.h`: documents the null-configuration contract.

Selection uses `ro.product.vendor.device`, not the generic GSI product. Existing
generated vendor properties identify Frankel and Cubs explicitly. Unknown
targets fail closed. Frankel retains its192000/192000 rates, D10/D5 PCMs,
1920×4 capture ring,192×20 playback ring,1920/960 framework queues, full playback
prefill, readiness properties, endpoint addresses, scheduling, mixer controls
and transfer behavior. The historical Frankel output address still contains
`D0`; it remains unchanged for existing applications, although transport isD5.

Cubs has D10 capture and D5 playback identities, but both rates and geometries
are zero and the route backend is `CUBS_PREPARATORY`. In addition,
`canAdvertiseDirection()` explicitly admits only the Frankel backend. Its
descriptor reserves:

| Direction | Proposed exact address |
| --- | --- |
| Logical mic0 |`POWERPHONE_CUBS_C0_D10_MIC0`|
| Logical mic1 |`POWERPHONE_CUBS_C0_D10_MIC1`|
| Logical mic2 |`POWERPHONE_CUBS_C0_D10_MIC2`|
| Top speaker |`POWERPHONE_CUBS_C0_D5_TOP`|
| Bottom speaker |`POWERPHONE_CUBS_C0_D5_BOTTOM`|

These are source identities, **not currently advertised devices**. Logical
microphone IDs are not a proven mapping to enclosure openings. The proposed
Cubs readiness-property strings are not new property contexts, writers or
certification claims. They are not read on a disabled target. Setting them
cannot enable this backend. Each direction can eventually carry a different
rate/geometry or remain disabled independently, but that requires a qualified
target-specific integration and an explicit source change to the admission
guard, not just changing descriptor numbers or properties.

## Preparatory tinyALSA route transactions

The new backend follows the actual exclusive hardware wrapper's controls:

- Capture: D10 mono S16, logical microphone 0, 1 or 2; `Raw` processing,
  `Builtin_MIC`, spatial processing/DC blocker/record gain disabled, exactly
  one capture-list ID with the other three entries `-1`, and
  `EP3 TX Mixer INTERNAL_MIC_TX`. It never writes HD Mic gain or reads the
  unsafe MIC Clock getter.
- Playback: D5 stereo S32, two 32-bit TDM slots, `ASP_BYPASS`, and the existing
  `music_17dB_top` or `music_17dB_bottom` TAS profile. It binds
  `TDM_0_RX Mixer EP6`, then enables `TAS25XX ASI Switch`. It does not execute
  Frankel's Cirrus controls or card-wide PCM-open override.
- Both paths snapshot named controls, validate widths/enums and read back
  writes. Existing process-wide PCM leases protect same-direction streams;
  a shared mutex serializes this backend's mixer transactions. PCM is closed
  before route cleanup. Cleanup disables ASI before unbinding playback,
  unbinds capture, and restores snapshots without duplicate route-off writes.
- A mixer write failure or observed ownership/generation change latches a
  process-wide fault and refuses new streams. Cleanup avoids replaying stale
  snapshots across uncertain state. It requires a reboot rather than claiming
  an automatic recovery from an unknown DSP generation.

These are implemented safeguards, not an activation or coexistence proof.
The additional guards require the proprietary HAL to be stopped, a nonempty
boot ID with zero AoC restart/coredump counters, and no RAW3 marker. The current
preparatory contract also requires exactly 192 kHz for either opened direction;
it makes no promise that a different rate is safe. Cross-process exclusion,
ongoing generation/readiness revocation, needed SELinux access, allowed
duplex operation, startup and error recovery still require explicit integration
and hardware qualification. No service, property or marker enables this code
in the current descriptor.

## What must not be copied from Frankel

Frankel's playback route opens Cirrus-specific amp/ultrasonic controls, forces
a card-wide PCM-open timeout, and has target-specific startup retry and
real-time scheduling contracts. Cubs uses TAS2572 and distinct controls. Those
transactions must not run on Cubs. Likewise, Frankel's ready properties and
bootstrap do not certify a Cubs firmware generation.

Current Cubs D10 patches modify shared firmware capture code. The direct
speaker replacement owns the entire `AHWSinkSPKR` worker; unpatched ordinary
entrypoints are not a compatible parallel playback path. A process-local
sidecar lease only prevents its own streams from colliding. It does not stop
the proprietary primary HAL, soundtrigger/hotword, camera capture or another
PCM client from changing shared mixer/DSP state. Mixer readback is not a
cross-process exclusion mechanism.

Do not add the sidecar's RC/VINTF declarations or product package to Cubs now.
VINTF-declaring an instance whose process intentionally refuses registration
can strand audio discovery. No init, VINTF, SELinux, policy XML, default-device,
stock-HAL or framework source change is included in this scaffold.

## Coexistence choices requiring an explicit decision

1. **Research-only default HAL.** A new Cubs primary implementation could own
   `IModule/default`, use fixed qualified D5/D10 rates, publish built-in speaker
   and mic ports for ordinary clients, and add exact addressed research BUS
   ports. AudioFlinger could convert48 kHz UI/media at the framework boundary.
   With the proprietary HAL permanently excluded, one implementation can
   coordinate shared PCM/mixer ownership and serialize primary/BUS streams.
   This is a substantial target integration, not an address rename. Calls,
   telephony routing, Bluetooth, hotword, USB/headsets and other vendor features
   are not automatically implemented; losing them is not authorized merely by
   proving a research route. Enumerate the desired retained functionality and
   obtain the user's choice before disabling the stock owner.
2. **Keep stock ordinary audio.** This requires a proven cross-process lease
   and target-aware routing, or a firmware profile that remains correct for
   stock-rate clients. The current exclusive direct worker does not satisfy
   that condition. Runtime patch switching is not currently a safe lease
   implementation: cold-cache activation and reboot-only rollback are part of
   the existing experiment. Do not hot-toggle copied instruction bytes while
   clients or DMA remain active.

For either choice, qualification must include independent rate/clock evidence,
API-selected route identity, PCM ownership, default UI/media behavior,
close-before-route-off cleanup, sequential and allowed concurrent usage,
restart revocation, bounded boot activation and an exact flashed-image retest.
Serial192 kHz playback must still be distinguished from TAS2572's internal
96 kHz processing and the separately measured acoustic passband.

## Durable patch and actual service build

The bounded change is preserved as
`patches/hardware-interfaces/0029-separate-qualified-target-audio-contracts.patch`,
explicitly appended after0028 in `scripts/apply-source-patches.sh`. Its four-file
delta was extracted against a separate reconstruction of preceding patches
0001–0028 under `work/audio-research/cubs/hal-target-config-20260923/`, not a
broad diff of the populated AOSP worktree. No unrelated AOSP edits were included.

The preparatory route implementation is a separate subsequent patch,
`patches/hardware-interfaces/0030-add-disabled-cubs-tinyalsa-route-backend.patch`,
also listed in `scripts/apply-source-patches.sh`. Its three-file delta was
extracted against exact copies of the two owned source files immediately
before this change, with the new header added separately, under
`work/audio-research/cubs/hal-route-backend-20260923/`. Patch0029 and unrelated
populated-tree changes were not folded into it.

The actual existing populated Frankel graph compiled and linked the service
with this command:

```bash
cd work/aosp
export OUT_DIR=out_pixel/frankel
prebuilts/build-tools/linux-x86/bin/ninja -d keepdepfile -d keeprsp \
  -f out_pixel/frankel/combined-frankel.ninja \
  android.hardware.audio.service-aidl.powerphone
```

The existing Cubs graph is `out_pixel/cubs/combined-cubs.ninja`; use
`OUT_DIR=out_pixel/cubs` and that graph for a future target build **without
installing or adding a VINTF declaration**. The header is included by existing
`Powerphone.cpp`, so no additional Android.bp source entry is required.
The initial compile caught two signed/unsigned rate comparisons introduced by
the refactor. Explicit casts fixed them; the complete retry exited zero.
Logs are `work/audio-research/cubs/hal-target-config-20260923/build-frankel-service.log`
and `build-frankel-service-retry.log`. The new local binary is
`work/aosp/out_pixel/frankel/target/product/frankel/vendor/bin/hw/android.hardware.audio.service-aidl.powerphone`.
Ninja updated ordinary local dependency/staging outputs, but no device install,
vendor image build or flash occurred. Cubs still refuses module registration.

The same actual service target was rebuilt successfully after patch0030
(compile, link, symbols, strip and local staging, exit zero). Its log is
`work/audio-research/cubs/hal-route-backend-20260923/build-frankel-service.log`.
This is a compile/link result only, not hardware validation of the disabled
Cubs backend. No simulated or mock audio qualification was performed.
