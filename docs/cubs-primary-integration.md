# Cubs research primary integration

Status: the exact v7 closure is hardware-qualified for the
[documented research scope](cubs-powerphone-qualification-20260923.md), including
the isolated API matrix, direct/API acoustic tests and repeat boot. The user
approved replacing the proprietary primary HAL on this research phone.
The separate release is `artifacts/cubs-powerphone-192k-20260923`; the original
`artifacts/cubs` remains unchanged. This document retains intermediate failures.

## Scope and hardware limit

The new, separately built `android.hardware.audio.service-aidl.powerphone-cubs`
owns the default AIDL module, configuration service and an empty effects
factory. It exposes the built-in speaker/microphone plus two addressed speaker
and three addressed mono microphone research ports. AudioFlinger converts
ordinary client rates at its boundary to fixed192-kHz hardware streams.
Calls, Bluetooth audio, headsets, hotword and other proprietary audio features
are not implemented by this research primary.

Cubs has TAS2572 amplifiers. Their192-kHz serial input is internally processed
at96 kHz; it is not a96-kHz acoustic passband. The actual retained sweeps show
the corresponding folding above48 kHz. See the linked capability report in
`docs/cubs-powerphone-bringup.md`. All three microphone captures show the
user-requested shaped-noise rise near96 kHz:12.46–12.92dB from48–60 to84–95kHz
in fixed quiet intervals. This supports the high-rate capture path, not an
independent calibrated microphone sensitivity measurement.

## Ownership and boot

The original `vendor.audio-hal-aidl` service definition is removed, not merely
disabled: the platform audioserver RC explicitly starts that old name whenever
audioserver starts or stops. The new service name is
`vendor.audio-hal-powerphone-cubs`. Only its three actually registered default
AIDL interfaces remain declared in the primary fragment. The inherited
Bluetooth-library manifest is excluded from the assembled research image.

The platform-context RC stops audioserver before class-core startup. Vendor
post-fs-data starts aocd and the bounded, asynchronous native boot helper. The
helper waits on observable AoC/control readiness, requires idle kernel PCM
reservations, applies the guarded native192 edge0/MCPS112/two-slot speaker
closure and publishes boot-local readiness only after cache completion and
readback. It does not wait for launcher or sys.boot_completed. Firmware is
reapplied each boot, never hot-switched between mono and RAW3.

The platform mirrors its private audioserver state into
`vendor.powerphone.cubs.audioserver_stopped`; a vendor daemon must not read the
private init property directly. PCM ownership uses ALSA control-device
PCM_INFO reservation counts. This kernel does not expose the per-substream
ALSA procfs status files. No ptrace permission or broad process-FD access is
needed for the native boot helper.

## Real native-helper trials,2026-09-23

Evidence root: `work/audio-research/cubs/primary-hal-integration-20260923/`.

- First run failed after writing the closure because the native cache helper
  attempted to open AoC's single-reader debug channel twice. Audio remained
  stopped and the phone was rebooted. No failed attempt was called ready.
- The corrected run finished in3.919s, restored the temporary dispatch hook,
  observed fresh cache completion64 and read back all41 patched regions.
  AoC restart/coredump counters remained0/0.
- A real bottom-speaker/mic0 duplex test after that native application
  retained the complete3-second20,731-Hz tone. Measured frequency was
 20,731.00004Hz; zero detected phase events, dropouts or clipping. Original
  capture and analysis are in `native-apply-duplex/`.
- Read-only `--check-idle` on the actual phone found34devices/34streams and
  confirmed D5p and D10c were closed using kernel reservation ioctls.

These results validate native application and one direct path.

## Integrated boot and first API trials

The first `images-v4` boot completed with SELinux enforcing. The native helper
finished in 2.947 seconds and published readiness at uptime 6.779 seconds,
before launcher, with AoC restart/coredump counters at 0/0. Both speaker BUS
ports and all three microphone BUS ports were visible; the ordinary primary
output advertised 192000 Hz. No host-side warm-up was needed.

The first API playback trials failed with a raw PCM WRITEI EPIPE. Direct
tinyALSA duplex on that same boot retained the entire three-second 20731-Hz
tone, with no detected phase events, dropouts or clipping. This localized the
failure to the HAL transfer/start contract, not failed boot firmware setup.

The Cubs-only candidate in patch 0032 changes playback's ALSA automatic start
threshold from the full 7680-frame ring to 3840 frames, matching the successful
tinyplay implementation. It leaves the 1920-by-four ring and Frankel behavior
unchanged. In the live-bind `api-half-start-v2` trial, all four speaker/API
combinations completed eight-second runs without reported underruns. The
capture harness initially reported five passes, but subsequent log inspection
found Android silenced every input after about five seconds because the test
activity ran while the display was asleep. Those captures are not full-duration
passes; their first fixed quiet interval still contains the expected noise
ramp. AAudio capture on microphone 0 also failed its timestamp-rate check despite
transferring all samples with zero reported XRUNs. These failures are retained,
not waived; the harness must wake/unlock and verify foreground operation and
reject framework-silenced captures. API acoustic, lifecycle and final-image
qualification remain in progress. `images-v5` contains this candidate and is
explicitly marked hardware-qualification pending.

The research primary intentionally lacks Bluetooth audio interfaces. Donor
Bluetooth audio profile flags must also be disabled before Bluetooth starts;
otherwise LE Audio aborts while looking for the missing factory. The canonical
platform early-init fragment disables only those audio profiles, leaving
non-audio Bluetooth capabilities outside that quarantine. This fix still
requires a real Bluetooth-enable test on the updated image.

## Corrected live qualification and first complete flash

Patch 0033 fixes normal input FLUSH: the serialized Cubs input worker closes
D10 through standby before releasing the route. The prior inherited no-op
flush left the PCM lease live and incorrectly rejected the subsequent empty
device disconnect. The active-route-change guard remains intact, and Frankel
and output behavior are unchanged.

With the display awake and the test activity resumed, `api-flush-awake-v3`
passed all ten endpoint/API combinations. The six original eight-second input
files have no clips, sustained silencing or repeated 96-frame blocks in the
fixed 0.1–7.9-second interior. Their documented 4–5 ms startup zeros remain
in the original WAVs. Near-Nyquist quiet-noise rise is 12.45–13.01 dB.
The native input test now retains the same fixed one-second startup exclusion
and strict full-run timestamp regression as playback, rather than comparing
one priming timestamp against a single later observation.

AAudio output plus Java UNPROCESSED reference captures measured the requested
20731-Hz pilot on both speakers, with zero detected phase discontinuities,
dropouts or clipping. The top trial using patch 0033 also closed cleanly.
The bottom trial before patch 0033 retains a separate lifecycle-failure note;
its passing waveform is not represented as a complete lifecycle pass.

The complete 14-image `bundle-v6` was flashed through its standalone runner.
Its initial preflight stopped before any write because system_ext required
4096 additional bytes. The explicit `--grow-logical` rerun grew only that
current-slot logical partition and completed all writes without a data wipe,
slot change, hash check or bootloader/radio update. Physical images used
bootloader fastboot and logical images used fastbootd. Full flash log:
`work/audio-research/cubs/primary-hal-integration-20260923/flash-bundle-v6-grow-console.log`.

On the resulting boot, native readiness was published at uptime 6.747 seconds,
after 2.824 seconds of helper runtime. Android boot completed with SELinux
enforcing, both directions ready, the new HAL running and AoC counters 0/0.
The temporary HAL bind mount is gone. Final-image API/acoustic and lifecycle
checks are recorded separately as they complete; assembly alone is not a pass.

## Patch 0034 and the flashed v7 candidate

An ordinary UI/unlock output can still own the shared D5 route when a research
speaker stream starts. The earlier output worker converted that lease's
`WOULD_BLOCK` into a permanent ERROR state. Patch 0034 adds a Cubs-output-only
500 ms condition-variable wait for lease release and a narrowly opted-in
retryable START failure. On timeout, START reports `STATUS_INVALID_OPERATION`
while preserving the prior worker state; it does not consume the following
audio FMQ payload. A subsequent write can retry. This is not simultaneous
speaker-route arbitration or lossless playback through contention: an
unsuccessful framework write can still lose that submitted audio chunk.

`images-v7` and the complete 14-image `bundle-v7` contain the built 0034 HAL,
retaining the half-ring output start and input-FLUSH fixes. The full bundle was
actually flashed, not merely live-bound. Its first boot reported native
readiness at uptime 6.529 seconds after 2.802 seconds of helper runtime;
Android reached boot completion with SELinux enforcing and AoC counters 0/0.
The recorded boot ID is `d3304f1f-de4e-4049-8846-5d886ebf56ea`.
Evidence is under the same integration root in `flash-bundle-v7-console.log`
and `bundle-v7-boot1/`.

The initial `bundle-v7-api-matrix/` retains an aggregate failure during the
top-Java trial: the research stream succeeded, but concurrent UI starts failed
the global HAL-error gate. Its other nine results do not make that matrix pass.
The revised exclusive preflight observes keyguard transition completion and
at least 500 ms of consecutive native kernel PCM-idle observations, with a
bounded deadline and no service stops. On the exact
flashed v7 image, `bundle-v7-exclusive-api-matrix/run-status.tsv` records all
ten speaker/microphone Java/AAudio combinations passing. Subsequent four API
duplex combinations, three direct 30-second trials, ordinary 48-kHz client
audio, Bluetooth enablement and repeat boot also passed their scoped checks.
Boot2 restored the profile at uptime 6.775 seconds; fresh AAudio top/mic1 and
ordinary bottom/mic0 acoustic trials passed without host warm-up. The final
report indexes original recordings, retained warnings and unsupported features.

## Reproducible source and image assembly

Canonical integration is `config/targets/cubs/powerphone/`; the native helper
is `tools/audio/device/cubs_powerphone_boot/`. Run
`bash scripts/audio/cubs/stage-primary-profile.sh` after editing either source.
It updates only the generated Cubs product and keeps prior copies outside
the AOSP source tree. HAL changes are patches0029–0034.

Build the actual Cubs components in `work/aosp`, with `OUT_DIR=out_pixel/cubs`,
`USE_STOCK_KERNEL=true`, `cubs-aosp_current-userdebug` and these targets:

```text
android.hardware.audio.service-aidl.powerphone-cubs cubs_powerphone_boot
cubs_powerphone_services_rc cubs_powerphone_platform_gate_rc
cubs_powerphone_manifest vendor_sepolicy.cil vendor_file_contexts
vendor_property_contexts
```

The populated graph can subsequently be invoked with Ninja and
`-d keepdepfile -d keeprsp`; use the Cubs graph and explicit OUT_DIR. The first
build regenerates real interface/runtime dependencies, not mock targets.

The captured live vendor/system_ext partitions are the image base. Do not
substitute the older donor kernel/module pairing. Policy assembly combines
the new Cubs vendor policy with the platform/system_ext/product policies
actually kept on the phone. Existing init policy-cache metadata is preserved;
there is no copying/flashing hash verification step. Only the baseline
userdebug `su` permissive domain may remain; the HAL and boot helper are
intended to run under enforcing policy.

`scripts/audio/cubs/flash-primary-trial.sh` is a deliberately narrow trial
runner, not the final flash-all bundle. Physical images use bootloader
fastboot; vendor/system_ext logical images require fastbootd. It never wipes
userdata or writes bootloader/radio. Use the full release runner for the tested
14-image closure rather than treating this narrow trial script as flash-all.

The separate opt-in full-bundle workflow is documented in
[`scripts/audio/cubs/POWERPHONE_BUNDLE.md`](../scripts/audio/cubs/POWERPHONE_BUNDLE.md).
It uses `assemble-powerphone-bundle.sh` and standalone `flash-powerphone.sh`
(copied into a bundle as `flash-all.sh`). The v7 candidate is
`work/audio-research/cubs/primary-hal-integration-20260923/bundle-v7/`.
Its `BUNDLE_INFO.json`, image sizes, firmware prerequisites and complete-copy
marker record assembly provenance; its original `HARDWARE_QUALIFICATION_PENDING`
remains as assembly history. The separately promoted copy archives that marker
and adds measured, scoped qualification; neither replaces `artifacts/cubs`.

The matching optional lab app is separately built at
`../csr460-powerphone/app/build/manual/PowerPhoneLab-debug.apk`
(`com.csr460.powerphone`, version 0.3.0 / code 3, arm64-v8a). It is not
preinstalled by these images. The release includes the exact tested APK
alongside the images, its app source/build provenance, and the completed
qualification/evidence index with explicit hardware limitations.
Install through authorized USB-debugging ADB on port 5038 using
`install --no-incremental -r`, grant the runtime `RECORD_AUDIO` permission,
then launch `com.csr460.powerphone/.MainActivity`. Normal Java/AAudio use does
not require app root; the host qualification scripts use root for independent
kernel and firmware observations. A portable release also needs an explicit
Linux platform-tools path; the captured host-path hint is machine-local.
