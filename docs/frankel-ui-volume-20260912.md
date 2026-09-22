# Pixel 10 custom UI-volume compensation — 2026-09-12

Status: **custom UI-volume compensation is flashed and measured on the
installed image; the scoped UI checks are complete**. All eight post-flash
clicks have strong source-shaped responses, with a measured median amplitude
increase of 11.22 dB over this session's baseline and no clipped samples in
the original recording. The policy adjustment itself is nominally +6 dB;
the larger measured response is not relabeled as a 6 dB acoustic change.
The user confirmed that the preceding ordinary-audio correction works, but
its UI sounds remain too quiet. That confirmation supersedes the previous
report's then-pending subjective confirmation; it does not by itself qualify
this new volume change; the evidence for the latter is recorded below.

## What changes, and what remains factory

This is **custom +6 dB UI-volume compensation**, not restoration of a factory
volume curve. Before this adjustment, the active `AUDIO_STREAM_SYSTEM`
built-in-speaker curve and `config_soundEffectVolumeDb=-6` already matched
their factory values. The prior
correction restored ordinary amplifier gain code 17; that setting and digital
PCM volume 817 remain unchanged here.

The new selector adds exactly 600 millibels to every point of the single
`AUDIO_STREAM_SYSTEM` / `DEVICE_CATEGORY_SPEAKER` attenuation curve in
`/vendor/etc/audio/config/audio_policy_volumes.xml`. Index positions are
unchanged; for example, the final point changes from `(100,-1100)` to
`(100,-500)`. This is a policy-level requested +6 dB change, not a claim of
an exactly 6 dB acoustic increase or calibrated SPL.

Music, ring, notification, alarm, other streams, external-device curves and
research-BUS curves are untouched. Amplifier settings, sample rates, firmware,
kernel, HAL implementation and the existing system-effect asset/attenuation
are unchanged. The change affects ordinary SYSTEM-stream speaker sounds, not
only this test activity's key-click call.

The audited factory source is
`downloads/unpacked/frankel-CP2A.260805.005/vendor/etc/audio/config/audio_policy_volumes.xml`.
Compared with that source, the selected policy changes only the eight
SYSTEM/SPEAKER points by +600 millibels. There is no factory vendor resource
override restoring a different `config_soundEffectVolumeDb`; its active
value remains −6. No additional factory-default restoration is claimed.

## Reproducible and reversible selection

[The scoped selector](../tools/audio/patch_frankel_system_ui_volume.py) accepts
only the exact reviewed factory or `ui-plus6db` curve, requires one matching
stream/device stanza, and rejects an unknown curve rather than overwriting
custom tuning. It does not calculate whole-file hashes. The retained
[factory policy XML](../work/audio-research/frankel/ui-volume-tuning-20260912/audio_policy_volumes.factory.xml)
provides the pre-change copy.

From `pixel_aosp_manifest`, select the desired generated vendor state:

```bash
python3 tools/audio/patch_frankel_system_ui_volume.py \
  work/aosp/vendor/google_devices/frankel/proprietary/vendor/etc/audio/config/audio_policy_volumes.xml \
  --state ui-plus6db --in-place
```

Use `--state factory --in-place` on that same path to remove this compensation.
These host commands change build inputs, not a running phone. The generated
vendor sanitizer selects `ui-plus6db` for the patched PowerPhone primary
profile and `factory` otherwise; regenerating the patched profile therefore
reapplies its custom selection. The
[incremental build runbook](../scripts/audio/frankel/BUILD_PLAYBACK192.md)
backs up the policy XML, invokes this selector and installs its actual vendor
target before packaging `vendor.img`. No framework rebuild is involved.

## Completed actual hardware comparison

The comparison uses the actual `AudioManager` `FX_KEY_CLICK` path, with default
effect volume `-1`, eight clicks one second apart and independent D10 capture.
The source is concentrated below 2 kHz; analysis must use the corrected
100–2,000 Hz source band and timing-bounded windows. The previous 2–18 kHz
analysis error must not be repeated. API dispatch alone is not proof of
increased click level or audibility.

- [Before: original recording](../work/audio-research/frankel/ui-volume-tuning-20260912/before/capture.wav)
  and [event/state log](../work/audio-research/frankel/ui-volume-tuning-20260912/before/logcat.txt).
- [Live candidate: original recording](../work/audio-research/frankel/ui-volume-tuning-20260912/after-live/capture.wav)
  and [event/state log](../work/audio-research/frankel/ui-volume-tuning-20260912/after-live/logcat.txt).
- [Post-flash original recording](../work/audio-research/frankel/ui-volume-tuning-20260912/postflash/capture.wav)
  and [timing-bounded source analysis](../work/audio-research/frankel/ui-volume-tuning-20260912/postflash/ui-clicks-analysis.json).
- [Live-install record](../work/audio-research/frankel/ui-volume-tuning-20260912/live-install.txt)
  and [vendor build log](../work/audio-research/frankel/ui-volume-tuning-20260912/vendor-build.log).

All three recordings use eight actual clicks, system volume 5/7 and default
effect volume −1. Source-matched measurements retain every event window:

| Measurement | Before | After live selection | After flash/reboot |
| --- | --- | --- | --- |
| Median absolute source projection | 0.00193810 | 0.00729084 | 0.00705252 |
| Relative source amplitude | Reference | 3.762× / +11.51 dB | 3.639× / +11.22 dB |
| Median peak 20 ms, 100–2,000 Hz | −81.27 dBFS | −70.76 dBFS | −70.96 dBFS |
| Clipped samples, entire original WAV | 0 | 0 | 0 |

All eight post-flash source correlations have absolute values 0.744–0.803,
with no noise-dominated event windows. Post-flash median projection is only
0.289 dB below the live candidate. Some baseline/live windows contain ambient
interference; they remain in the reports. Cleaner paired events independently
show the larger-than-nominal live increase. See the full
[acoustic comparison](../work/audio-research/frankel/ui-volume-tuning-20260912/ACOUSTIC_COMPARISON.md).

Active HAL volume metadata changed from 0.0599071 to 0.11953, approximately
6 dB, whereas the recorded source-matched change is approximately 11 dB.
A second volume-dependent application is only a hypothesis; its cause was
not established in this work. These are relative microphone measurements,
not calibrated SPL or proof that no internal analog stage clips. Absence of
full-file sample clipping is not a distortion measurement.

## Installed image and final state

The complete bundle is
`artifacts/frankel/powerphone-playback192-ui6db-20260912/`; only its vendor
image differs from the preceding ordinary-gain bundle. The
[incremental vendor flash](../work/audio-research/frankel/ui-volume-tuning-20260912/vendor-flash.log)
completed in 30.763 s without erasing userdata. The
[post-flash policy XML](../work/audio-research/frankel/ui-volume-tuning-20260912/postflash-audio_policy_volumes.xml)
and [final readiness/mount record](../work/audio-research/frankel/ui-volume-tuning-20260912/final-ui-readiness.txt)
confirm the packaged policy, read-only ext4 `/vendor` with no policy-file
bind, boot and bootstrap complete, both audio readiness flags 1, SELinux
Enforcing and all three audio services running. Settings launched in 238 ms
and its hierarchy dump succeeded; the phone is left in Settings.

The [fresh click log](../work/audio-research/frankel/ui-volume-tuning-20260912/postflash/logcat.txt)
contains all eight dispatches and completion, and its
[error inventory](../work/audio-research/frankel/ui-volume-tuning-20260912/postflash/errors.txt)
is empty. [Final actual volume indices](../work/audio-research/frankel/ui-volume-tuning-20260912/final-volumes.txt)
remain SYSTEM/RING 5/7, ordinary-speaker media 25 and research BUS 8; the
louder UI result did not require changing those indices.

Qualification is limited to the installed custom UI-volume change and these
real click/boot/UI checks. Ordinary-media curves are unchanged by source
inspection, not newly requalified through a full media/API regression here.
The preceding report's research-continuity failures, unsupported concurrent
primary/BUS playback and ultrasonic airborne-proof limitations remain. No
new subjective confirmation of this latest UI level is inferred.
