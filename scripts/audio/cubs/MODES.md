# Cubs API mode versus exclusive direct tinyALSA mode

Status, 2026-09-23: the exact v7 image passed the isolated 10/10 API matrix,
API duplex/ordinary-playback checks, three 30-second direct duplex trials, and
a normal reboot with post-boot API checks. See the
[qualification record and limits](../../../docs/cubs-powerphone-qualification-20260923.md)
and [matching flash bundle](../../../artifacts/cubs-powerphone-192k-20260923/).
This does not qualify concurrent ordinary/research output or hot-switching
between the mono boot profile and the historical RAW3 profile.

API mode uses the boot-integrated research primary service
`vendor.audio-hal-powerphone-cubs`, with audioserver running and the proprietary
`vendor.audio-hal-aidl` absent or stopped. Use the target-aware
`../csr460-powerphone` Java/AAudio test application and its `TARGET_DEVICE=cubs`
host suite. Exact route enumeration or a readiness property is not an API or
acoustic PASS; retain actual transfers, negotiated formats and recordings.

The direct capture, speaker and duplex wrappers take exclusive ownership:

1. Stop audioserver and wait for its stopped state.
2. Allow queued platform stop actions to settle, stop the proprietary HAL if
   it exists, then stop the replacement research HAL.
3. Require five consecutive stopped/absent HAL observations with audioserver
   stopped, then scan all process file descriptors for any retained card0 PCM.
4. Only then snapshot/configure the exact mixer controls and run tinyALSA.
5. Close PCM, restore known-generation mixer snapshots, and hold **all** owners
   stopped in research quarantine. Never automatically restart the replacement
   or proprietary HAL or audioserver in this mode.

An absent proprietary service is expected in the replacement-primary image;
running or restarting is never treated as absent. The replacement may be
absent on an older stock-baseline image. Its presence alone makes a direct
session quarantined, even when it was already stopped. Existing mono192,
direct192/two-slot and RAW3 capability markers keep their independent format
guards. Firmware-generation failures prevent stale mixer replay.

Reboot to exit research direct mode and let the boot helper re-establish its
profile and API ownership. Do not start one audio service manually to bypass
that boundary. Failed cleanup or missing service/PCM ownership proof remains
a failed trial with retained evidence, not a reason to loosen the checks.

The final three 30-second direct trials exercised this service-exclusion and
quarantine path on the replacement image. The subsequent normal reboot
re-established readiness at uptime 6.775 seconds (2.830 seconds of helper
runtime), enforcing SELinux and AoC counters 0/0, without host warm-up. AAudio
TOP/MIC1 duplex and ordinary 48-kHz bottom/MIC0 playback/reference then passed.
Use actual readiness checks, not those measured timings as a fixed sleep.

The automatic profile captures one selected microphone at a time. RAW3 requires
a separate baseline boot without the automatic bootstrap; rebooting the
integrated image reapplies mono and is not permission to overlay RAW3 patches.
