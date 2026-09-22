# Frankel primary Android playback at 192 kHz

`patch_frankel_primary_hal_192k.py` selects the hardware-qualified primary
playback candidate without changing AudioFlinger or the framework. Run it
after extracting/sanitizing the matching proprietary Frankel HAL:

```sh
python3 tools/audio/patch_frankel_primary_hal_192k.py \
  work/aosp/vendor/google_devices/frankel/proprietary/vendor/bin/hw/android.hardware.audio.service-aidl.aoc \
  --in-place
```

The generated-vendor sanitizer already invokes this canonical selector.
It recognizes stock, rate-only, former 1920x2 geometry, explicit-start,
prefill-only, FIFO-only, and the complete FIFO90/FMQ960 profile through the
reviewed instruction bytes. Unknown or mixed edits are rejected; no
whole-file hashes are needed. `--set-state stock` and `--set-state rate-only`
remove the corresponding scoped edits.

## Selected behavior

- Primary and deep output interfaces negotiate 192 kHz; AudioFlinger converts
  ordinary application rates before sending them to the hardware path.
- D1/D5 playback uses the D5/source-5 physical frontend. The secondary deep
  port is on-demand DIRECT, avoiding two persistent mixed outputs sharing D5.
- ALSA remains 192 frames × 20 periods, with a full 3840-frame autostart
  threshold. D1/D5 playback does not explicitly start an empty PCM.
- That guarded Start continuation calls the existing `sched_setscheduler`
  import for its own thread: FIFO/90 plus RESET_ON_FORK. Failure takes the
  existing Start error/PCM-close path, not a lower-priority fallback.
- The PCM minimum-frame getter advertises **960 frames** to Android for those
  playback paths, independently of the 192-frame ALSA period. This reduces
  framework FMQ transactions from 1000 to 200 per second while retaining
  one-millisecond hardware notifications.
- Capture and other PCM paths retain their previous scheduler/start/getter
  behavior; the alternate PCM-interface getter remains unchanged.

Instruction source lives in `asm/frankel_primary_hal_prefill_start.*`,
`asm/frankel_primary_hal_d5_fifo90.*`, and
`asm/frankel_primary_hal_d5_fmq960.*`. The prefill assembly represents the
historical entry/guard; the FIFO assembly replaces its selected success
continuation. Candidate overlay scripts remain for reproducing individual
trials; normal image preparation uses the single canonical selector above.

## Hardware evidence and boundary

On September 11, 2026, the combined primary FIFO90/FMQ960 candidate completed
30 seconds of ordinary Java AudioTrack playback at a 48-kHz application rate.
A separate real D10 192-kHz microphone recording measured
11,999.999912 Hz from the requested 12-kHz tone, with 0 detected phase
discontinuities, 0 dropout blocks, and 0 HAL errors. The device reported
960 HAL frames and an actual FIFO/90 D5 writer. Evidence:

`work/audio-research/frankel/pitch-validation/primary-fifo90-fmq960-soak-20260911/`

That run also used the dedicated D5 kernel period worker and held stock
PowerHAL `AUDIO_STREAMING_LOW_LATENCY` mode. It does not independently qualify
the primary changes without those conditions, or qualify a future packaged
image, every API, or every endpoint. See
[the kernel worker](kernel/frankel_d5_period_rt/README.md) for its staging path.

The pre-integration primary executables are preserved under
`work/audio-research/frankel/primary-hal-integrated-20260911/`. The tested
candidate overlay is retained under the broader `work/audio-research/frankel/`
directory. Neither location belongs in the source repository's tracked files.

## Optional research-image cluster idle policy

The normal static-display hints reduce cluster-1/2 minimum idle residency to
10,000/15,000 µs. Stock low-latency audio mode holds both at 1,500,000 µs.
For a research-only image, the configuration-only selector changes those
four display-idle actions to the same 1,500,000-µs value. Defaults and all other
actions already select that value, so it remains held across PowerHAL restart
without competing with another client's global audio-mode Boolean.

```sh
python3 tools/audio/patch_frankel_powerphone_idle_residency.py \
  work/aosp/vendor/google_devices/frankel/proprietary/vendor/etc/powerhint.json \
  --state research --in-place
```

This is an explicit **higher idle-power tradeoff**, not a CPU-frequency lock,
and is not automatically enabled by the primary HAL patcher or sanitizer.
Use `--state stock --in-place` on that file to restore the four normal values.
Alternatively pass a separate output path to stage the change without
modifying generated vendor inputs. Rebuild/install the selected powerhint
file and qualify the resulting image on hardware; the held-mode trial alone
does not establish packaged-config qualification.

The research setting was selected for the September 11 candidate build in
both of these exact files:

- Generated source:
  `work/aosp/vendor/google_devices/frankel/proprietary/vendor/etc/powerhint.json`
- Installed vendor staging:
  `work/aosp/out_pixel/frankel/target/product/frankel/vendor/etc/powerhint.json`

Original copies are preserved in
`work/audio-research/frankel/primary-hal-integrated-20260911/` as
`powerhint.generated-stock.json` and `powerhint.installed-stock.json`.
The selector changed only the four reviewed action values; no CPU-frequency
actions, other power modes, or thermal limits were changed. Selection updated
build files only, not the running device or an already-packaged vendor image.

## Research idle-route handoff configuration

Ordinary and addressed research playback share physical PCM0,D5. The
framework's default three-second standby delay can retain an already-finished
BUS stream while the primary HAL activates that same route. The September 11
bookend log shows the primary route being activated before its PCM open fails
with `EBUSY`; its rollback then disables the sidecar's amplifier and PLL.
The sidecar's resulting `EIO` is not a rate or sample-cadence failure.

The configuration-only candidate uses the existing AudioFlinger property:

```sh
python3 tools/audio/patch_frankel_powerphone_standby.py \
  work/aosp/vendor/google_devices/frankel/sysprop/vendor.prop \
  --state research --in-place
```

This adds only `ro.audio.flinger_standbytime_ms=0`. AudioFlinger retains its
existing presentation-completion and pause/flush/standby sequence, but omits
the three-second idle hold. There is no framework code patch, custom null
sink, discarded active audio, or automatic XRUN recovery. More frequent
close/reopen cycles may affect short-sound startup latency; qualify those
transitions on hardware. The change is global to ordinary mixer standby,
not scoped to one BUS address, and **does not arbitrate simultaneously active
primary/BUS clients**. Such concurrent use remains unsupported.

`frankel.mk` already includes this file via `TARGET_VENDOR_PROP`, and the
existing Ninja `vendor/build.prop` target consumes it directly. The Frankel
sanitizer now selects this property when `POWERPHONE_AUDIO_SIDECAR=true` and
removes only this reviewed line when the sidecar is disabled. The selector
accepts absent/zero states, rejects duplicate or unknown values, and supports
`--state stock` to remove the override (restoring the framework default).

For the quick nodeps candidate build, the same selector was also applied to
`work/aosp/out_pixel/frankel/target/product/frankel/vendor/build.prop`.
Original generated/installed properties are retained as `vendor.prop.before`
and `build.prop.before` under
`work/audio-research/frankel/standby0-integration-20260911/`. Rebuild the actual
installed property target for normal reproduction. A reboot/new audioserver
is required because AudioFlinger caches the property; editing these files
does not change the live phone. The earlier isolated playback passes do not
qualify this newer handoff candidate; use the dated playback report for its
post-reboot transition results.
