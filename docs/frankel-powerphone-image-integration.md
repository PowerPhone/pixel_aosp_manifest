# Frankel PowerPhone image integration

This document defines the image boundary for the Pixel 10 (`frankel`) D10
192 kHz microphone and D0 speaker paths. It is intentionally narrower than the
live experimentation notes: only the transport-qualified PCM formats and
individually guarded endpoints are allowed to become Android API routes.

## Qualified input contract

The only qualified capture backend is:

- ALSA card 0, device 10 (`EP3`);
- mono `S16_LE`, exactly 192000 Hz;
- 1920 frames per period and four periods (7680 frames total); and
- one logical microphone selected as `0|-1|-1|-1`, `1|-1|-1|-1`, or
  `2|-1|-1|-1` in `BUILDIN MIC ID CAPTURE LIST`.

The PowerPhone AIDL module advertises those selections as three non-default
`IN_BUS` addresses:

- `POWERPHONE_C0_D10_MIC0`;
- `POWERPHONE_C0_D10_MIC1`; and
- `POWERPHONE_C0_D10_MIC2`.

D8, D9, D12, Capture Injection, Bluetooth, and virtual devices are not part
of this module. The former card-1/S32 PDM sidecar is superseded and must not be
used as evidence for this image.

The speaker side uses only the independently proven PCM0,D0 earpiece and
R/bottom-candidate routes. The simultaneous-amplifier route is absent because
it watchdogs FF1. Acoustic ultrasonic bandwidth remains a separate gate.

## Required boot order

The F1/H0 profiles, A32 allocator fallback, and dynamically rebased speaker
banks are volatile and therefore belong to every boot. The installed signed
`aoc.bin` remains exact stock; cold mutation is rejected by GSA. The live
helper writes the guarded allocator instruction and invokes AoC's
firmware-native whole-cache invalidator through the reviewed OUTPUTTER timer,
while leaving `UsfDefaultWorker` at stock priority. The
target-specific image integration must implement this sequence:

1. Hold `audioserver` disabled before its class starts. Allow stock `aocd` and
   `vendor.audio-hal-aidl` to start, but do not let the HAL open capture PCMs.
   During vendor `post-fs-data`, set
   `persist.vendor.aoc.firmware.force_nominal_voltage=1` after Android has loaded
   persistent properties but before `aocd` starts in `late_start`; then
   initialize phase `armed` and arm a typed, boot-local attempted latch at zero.
2. Only after `init.svc.aocd=running`, the stock HAL is running, audioserver is
   stopped, watchdog expiration is still zero, and the watchdog service is
   running, atomically claim that latch as the gate's first
   command and start the confined D10 bootstrap asynchronously. Requiring the
   zero latch and `armed` phase in the compound trigger makes this action
   boot-once even if a service start fails; later service stops cannot replay
   it. `aocd` belongs to
   `class late_start` and loads AoC firmware. Do not wait for
   `sys.boot_completed`: system_server
   audio initialization can require audioserver, creating a separate circular
   boot dependency. The bootstrap sets both research readiness properties to
   zero before touching mixer or AoC state; `vendor_init` must not write either
   typed property. Start an asynchronous 60-second watchdog when arming the
   latch; the main action stops it after claiming the latch. If these compound
   prerequisites never converge, a platform-context watchdog action must claim
   the same still-zero latch, start the finalizer asynchronously, and let its
   stopped event reach the common ordinary-audio release.
   The normal action must require expiration to remain zero so an already-
   published timeout wins init's all-property trigger sweep.
   A watchdog-service `stopped` trigger with both attempted and expiration
   still zero must run the same fail-open path, covering watchdog exec, policy,
   crash, and property-publication failures.
   This deadline covers only the pre-transaction wait. After the latch is
   claimed, asynchronous helper services rely on their internal factory-I/O
   and device deadlines; do not impose an init SIGKILL timeout that can
   interrupt the temporary AoC callback before its mandatory restoration path.
   Immediately after claiming the latch, issue `stop audioserver`, wait for
   `init.svc.audioserver=stopped`, issue
   `stop vendor.audio-hal-powerphone`, and wait for that service to be
   `stopped`. A stop request alone is not a process-death barrier in Android
   init. Keeping the sidecar down during certification also excludes stale
   client stream state from the direct-PCM transaction.
   Advance an exact typed phase through `attempt1`, `attempt2`, `attempt3`, and
   `finalizing`. Every transition must set its next phase immediately before
   `start`ing the oneshot in the same action. Init cannot consume the queued
   phase edge until the start has executed, which makes both normal completion
   and immediate start failure advance exactly once. Never use `exec_start` for a
   certification attempt or finalizer: those operations can run for minutes,
   and synchronous exec prevents init from dispatching unrelated module-ready
   and HAL-start property actions required by SystemServer.
3. Require `ro.product.device=frankel` and
   `ro.vendor.build.id=CP2A.260805.005`. Before any live mutation, require
   aligned A32 word `0x400a114c=002870d0` (or exact destination `002825d0` on a
   bounded retry) and stock timer-assertion word `0x4009e0cc=8efd90bb`; an
   unknown allocator word fails apply closed.
4. Require D8, D9, D10, and D12 closed and all EP1/2/3/5 TX routes,
   `US Record Enable`, and `MIC0..MIC2` off.
5. Establish and read back the strict mixer profile:

       BUILDIN MIC ID CAPTURE LIST = 0 -1 -1 -1
       BUILTIN MIC Process Mode = Raw
       Audio Capture Mic Source = Builtin_MIC
       Mic Spatial Module Enable = 0
       MIC DC Blocker = 0
       MIC Record Soft Gain = 0
       INTERNAL_MIC_TX Sample Rate = SR_192K
       INTERNAL_MIC_TX Format = S16_LE
       INTERNAL_MIC_TX Chan = One

   `EP3 TX Mixer INTERNAL_MIC_TX` remains off until the sidecar owns a stream.
6. Run `frankel_aoc_speaker_patch apply --allow-incomplete-boot
   --skip-zero-validation`. It must
   validate the exact A32 allocator/timer-assertion source, work pool, OUTPUTTER
   timer object, and `UsfDefaultWorker` identity/current/base priority 7/7;
   install the allocator fallback; arm, wait for, and restore the guarded A32
   cache callback; make exactly one 0x3000 F1 allocation; retain allocation
   range/alignment and edge-accessibility checks while skipping only the
   watchdog-prohibitive 192-dump full zero scan; split it into four 0xc00
   CPU/DMA banks; set conditional H0 192/1536 geometry only
   for enum-7/one-millisecond Configure before
   first Configure; apply the 44-word native-q192 F1 profile; synchronize F1
   I-cache; and publish speaker readiness only after final readback. It must
   never write either worker-priority field or allocate a second region.
7. Run `frankel_aoc_d10_patch apply --allow-incomplete-boot`. The helper must
   classify every reviewed F1 site uniformly, perform guarded writes and
   readback, invoke the proven whole-F1 I-cache invalidator, and restore its
   temporary dispatch pointer. Real-device boots established this order:
   D10's resident diagnostic profile can prevent a later speaker
   factory-mailbox transaction from completing. D10 therefore runs last, and
   its final whole-F1 cache synchronization covers the already-installed
   speaker edits.
8. As part of each `apply`, require a final uniformly-patched readback after
   cache synchronization. Each helper is the sole native owner of its
   readiness transition and may raise it only after that readback succeeds.
9. Quarantine D8, D9, D12, and Capture Injection
   (`/dev/snd/pcmC0D31p`) for the rest of the boot before invoking the helper.
   Its temporary D8/D9/D10/D12 transaction quarantine must restore the
   already-zero modes for those three unadvertised capture PCMs. Only D10 is
   exposed by the research AIDL module. Ordinary microphone capture through
   the stock module is outside this research-image contract.
10. From the finalizer's phase-guarded stopped event, set phase `releasing`,
    start `vendor.audio-hal-powerphone`, and only then release `audioserver`.
    Both watchdog fail-open paths must converge on this same finalizer and sole
    release action. The sidecar's
    generic AIDL Module stores open stream/port-config ownership in process
    memory, so it must never survive across an audioserver lifetime boundary.
    Set phase `complete` only after issuing both starts.

Failure is retried at most twice. A later attempt re-certifies an
already-selected speaker state idempotently before retrying D10. After the
third one-shot stops, a native
finalizer checks both readiness certificates: it preserves the quarantined
modes after success, or leaves readiness at zero and restores the PCM-node
modes after failure. A PCM absent because card 0 never registered is already
fail-open: there is no changed inode to restore, and ueventd assigns its stock
mode if it appears later. After the finalizer, including if its service start
is denied, init reaps any audioserver and PowerPhone sidecar instance, starts a fresh
sidecar, and then starts stock `audioserver`. Do not
continue from unknown or mixed F1 bytes. A reboot restores A32/F1 SRAM from
exact stock AoC firmware and provides the recovery boundary.

The target-local vendor RC must not override or inspect the system-owned
`audioserver`: Android init rejects cross-Treble service overrides, and
`init.svc.audioserver` is not an exported vendor-action property. The selected
bootstrap package therefore installs a companion RC under
`/system_ext/etc/init`. In platform init's context it issues the `early-init`
stop, requires the boot-local attempted latch to be armed, waits for stock
`aocd` and the vendor audio HAL to be running and audioserver to be stopped,
claims the latch, reaps audioserver and `vendor.audio-hal-powerphone`, then
starts the vendor bootstrap asynchronously. Exact phase/service-state actions
chain the retries and finalizer without occupying init's action queue. After
the finalizer stops, the sole release action starts a fresh sidecar before
starting audioserver. This
post-`late_start`, pre-boot-completion ordering is
intentional: the readiness transition must be able to release audioserver
before system_server finishes audio initialization. The gate starts the
unchanged system service only after the bounded finalizer stops. The vendor RC
declares the three certification one-shots plus their certificate-aware
   finalizer, forces AoC nominal voltage, initializes phase `armed`, arms the
   attempted latch at post-fs-data, and creates its private lock directory.
   Since the latch remains
claimed, a host runtime may later stop audioserver and its HAL without the
boot gate restarting them.
Do not replace or chmod `/system/bin/audioserver`.

## Runtime ownership

The AIDL module repeats the important checks at stream time. It refuses start
unless readiness is one, takes a single global D10 lease, requires all
conflicting routes idle, establishes the selected logical microphone and EP3
route, and gives Android a 1,920-frame (10 ms) framework/FMQ queue while
opening ALSA only if PCM0,D10 reports 1920 by four periods. Output uses a
7,680-frame (40 ms) framework/FMQ queue over PCM0,D0's qualified 1,920-by-two
ALSA ring. It defers EP1 and PCM open until the first complete client burst,
then submits 1,920-frame periods through the isolated legacy-v1 transport with
an explicit 1,920-frame start threshold. Real-time transfer checks the readiness certificate and
in-process lease without issuing dozens of mixer reads; full mixer ownership
is verified at route start and before cleanup. On standby, failure, or close,
the PCM is closed before EP1/EP3 and the selected physical controls are forced
off.

This is deliberately fail-stop rather than a transparent replacement for the
stock capture HAL. While the F1 patch is resident, do not use stock microphone,
hotword, or Capture Injection paths. Any AoC restart/coredump invalidates the
boot-local certification: clear readiness and reboot through the controlled
sequence instead of applying a live mutation under audioserver.

## Source and build closure

The reviewed source stack is applied with:

```bash
cd pixel_aosp_manifest
scripts/apply-source-patches.sh --check-only
```

The PowerPhone HAL patches are ordered as follows:

1. `0001-add-powerphone-192k-capture-module.patch`;
2. `0002-add-powerphone-192k-speaker-output.patch`;
3. `0003-use-qualified-frankel-d10-capture.patch`;
4. `0004-fix-powerphone-d10-build.patch`;
5. `0005-keep-readiness-writes-in-certifier-domains.patch`;
6. `0006-use-qualified-d0-single-amp-output.patch`;
7. `0007-use-direct-cs35l43-high-rate-route.patch`;
8. `0008-do-not-request-undefined-device-gain.patch`;
9. `0009-keep-mixer-io-off-realtime-playback.patch`;
10. `0010-expand-powerphone-playback-ring.patch`;
11. `0011-make-powerphone-pcm-activation-xrun-strict.patch`;
12. `0012-match-qualified-pcm-rings-and-thresholds.patch`;
13. `0013-prime-asynchronous-speaker-sink.patch`;
14. `0014-reopen-startup-eio-before-client-audio.patch`;
15. `0015-require-clocked-speaker-prime.patch`;
16. `0016-isolate-and-defer-legacy-d0-transport.patch`;
17. `0017-split-powerphone-output-probe-ports.patch`;
18. `0018-require-qualified-fifo90-playback.patch`;
19. `0019-match-tinyplay-params-preflight.patch`;
20. `0020-scope-d0-pcm-open-wait.patch`; and
21. `0021-use-qualified-native-q192-speaker-path.patch`.

Patches 0008--0011 keep absent device gain absent, remove mixer reads from
real-time paths, zero-initialize ALSA config storage, bind the final route
operation immediately before PCM open, split D0 writes into hardware periods,
and make xruns fail closed. Patches 0012--0015 record the earlier matched-ring
and silent-prime experiments. Patch 0016 supersedes their final playback
transaction, queue, and priming behavior: capture keeps its 1,920-frame
framework queue and 1920-by-four D10 ALSA geometry, while output exposes a
7,680-frame (40 ms) framework queue over the D0 ALSA ring.
The HAL defers EP1 binding and PCM open
until the first complete nonzero client burst is already available. Final
patch 0021 feeds the asynchronous sink in 1,920-frame writes, sets a 1,920-frame
start threshold, and selects two S32 TDM slots through the isolated
legacy-tinyALSA-v1 facade. Generic playback `SYNC_PTR` position refinement is
bypassed; capture remains on tinyalsa-v2 and FIFO/3.
Patch 0017 gives the two address-distinguished fixed output BUS sinks
independent normal mix-port identities, preventing their startup reachability
probes from reusing one already-open AIDL port config. Their common PCM0,D0
transport remains serialized by the HAL's process-wide playback lease.
Patch 0018 requires the playback worker to enter the hardware-stable
`SCHED_FIFO/90` policy before it can own or bind that route, raises the service
RT-priority limit to 90, and fails closed if promotion is unavailable. This
replaces the `SCHED_OTHER` policy that recovered an EPIPE on both the direct
trial and the first real AudioTrack transfer; it does not add a wall-clock
pacer. Patches 0019--0020 reproduce and scope the direct tinyplay parameter
preflight/open wait. Patch 0021 is the final native-q192 override: two S32
slots, 1,920-frame writes, and a 1,920-frame start threshold.

The legacy-v1 direct-hardware tool is reproduced by
`external-tinyalsa/0001-report-tinyplay-progress-and-xruns.patch`.
`external-tinyalsa-new/0001-expose-pcm-xrun-counter.patch` exposes the v2
cumulative xrun count, 0002 honors an explicit `avail_min`, and 0003 adds xrun
reporting to the v2 `tinyplay` completion summary. The legacy facade exports
its own cumulative counter, and every observed playback xrun or nonzero write
status fails the stream closed. These are current source integration, not by
themselves exact-image API or acoustic qualification.

A fast compile gate for the modified HAL is:

```bash
cd work/aosp
source build/envsetup.sh
source vendor/google_devices/frankel/cmds-for-envsetup.sh
export USE_STOCK_KERNEL=true
export OUT_DIR=out_pixel/frankel
lunch frankel-aosp_current-userdebug
m -j8 android.hardware.audio.service-aidl.powerphone
```

The known-good D10 integration passed this named build on 2026-09-01. It is a
compile result, not a boot or acoustic-bandwidth qualification.

After the generated-vendor boot helper, init policy, and SELinux policy have
been selected, build and package the native-q192 one-period-lag/stock-firmware
profile with all three feature opt-ins and both explicit profiles:

```bash
cd pixel_aosp_manifest
export PIXEL_TARGET=frankel
export POWERPHONE_AOC_ALSA_192K=true
export POWERPHONE_D0_PROGRESS_MODE=one-period-lag
export POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE=stock
export POWERPHONE_AUDIO_SIDECAR=true
export POWERPHONE_CS35L43_192K=true
scripts/sanitize-generated-vendor-frankel.sh
scripts/attest-generated-vendor.sh create
scripts/build-device.sh
scripts/package-device.sh
```

The sanitizer/attestation pair is required once whenever a selector or the
reviewed boot-helper/sidecar source changes. The build then verifies that
materialized input instead of silently accepting or replacing a stale profile.

`POWERPHONE_AOC_ALSA_192K=true` selects the complete reversible module family in
Google's source-unavailable AoC ALSA kernel module. That state combines the
general 192 kHz constraints/rate mapping, EP3 and EP1 DAI masks, 500 us
capture-ring polling, and bounded progress. The baseline-compatible default
`POWERPHONE_D0_PROGRESS_MODE=mailbox` selects progress from D0's real mailbox
ISR and has SHA-256
`fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0`.
The publishable PowerPhone profile explicitly selects `one-period-lag`: real
mailbox progress plus the 1 ms real-counter poll, conservatively reported as
`max(previous, actual minus one physical period)`, SHA-256
`37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6`.
It passed a complete ten-second native-q192 physical-speaker stream at
`1920x2`, start threshold 1920, and remained stable with simultaneous D10
transport.
The same flag must select the paired `aoc_core.ko` zero-write-pointer reset,
SHA-256
`f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c`
(stock:
`23acc08d0539657e72a0bc506abf6cef9950b90b192c51fd0dd9bf2177e4f2ad`).
At offset `0xa190`, the guarded transform changes only the comparison used by
`aoc_ring_reset_write_pointer()`: when the loaded write pointer is already
zero, reset must be a no-op instead of advancing Tx by a complete ring before
the first PCM copy. The ALSA and core transforms are a required pair. The
generated-vendor sanitizer and device-build attester must reject a build in
which only one selected state reached `vendor_kernel_boot` or target-files.
`POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE=stock` preserves exact stock firmware.
The retained experimental `source0-4s32-allocator-fallback` transform is not a
boot candidate: GSA rejects the modified signed firmware. After stock firmware
has authenticated and loaded, the boot helper retains the exact stock A32
allocator when its optional early cache-sync window is unavailable and
installs the native-q192 source-0/two-S32-slot F1 behavior only in live,
reboot-volatile SRAM.
`POWERPHONE_CS35L43_192K=true` selects the one-instruction exact-stock
CS35L43 transform (GLOBAL_FS 48 to 96 kHz only in ultrasonic mode), SHA-256
`fc631fc227ab2e7e8cfa2d664e97ac7cca4c14324fb2a39479fc8e79aa358a3a`.
`POWERPHONE_AUDIO_SIDECAR` selects the AIDL module, the raw-WRITEI staged D0
player, and the boot-time ordered speaker-then-D10 certifier. Build attestation
must require all helper binaries and RC, the PowerPhone HAL binary/RC/VINTF
fragment, both selected AoC kernel modules, and must reject the obsolete
`frankel_pdm_alsa.ko`/card-1 loader payload.

The three-boolean selection with `one-period-lag`/`stock` profiles selects the
dedicated Frankel research-audio bundle. Other profiles are
published under a profile-specific `artifacts/frankel/experimental-*`
directory, kept separate from both that bundle and the normal device bundle.
The layout is flat: image files are next to the flashing script rather than
under an `images/` subdirectory.

```text
artifacts/frankel/powerphone/flash-all.sh
artifacts/frankel/powerphone/*.img
```

Run `flash-all.sh` from an unlocked bootloader/fastboot state. It flashes the
complete attested userdebug set; no host-side post-boot F1 patch is part of a
finished PowerPhone image.

## Retained hardware evidence and current boundary

The decisive one-period-lag kernel pairing for the current root image is retained
at
`work/audio-research/frankel/speaker-ep1-source0-192k-d0-hybrid-one-period-lag-pair/trial-1/`.
The selected `aoc_alsa_dev_util.ko`, `aoc_core.ko`, and CS35L43 states are the
closure that must be reproduced by the generated build; an AoC ALSA-only image
is not equivalent.

The direct D0 transport record at
`work/audio-research/frankel/speaker-d0-mailbox-4xs32-192k-hardware-attestation-20260902.md`
records a complete 15-second stereo S32_LE/192000 run: expected, Tx, and Rx
were all 23,040,000 bytes, with restart/coredump counters 0/0 during the test.
The prior mailbox/q48 and pure-timer records are retained as intermediate
transport evidence but are superseded for final cadence qualification. The
one-period-lag trial completed a ten-second native-q192 speaker payload and
concurrent D10 transport from the equivalent manually installed volatile
speaker state. A fresh-image boot must still verify that the integrated native
certifier reaches the same state and publishes readiness without host writes.
The transport result proves native-rate transport, not calibrated
ultrasonic speaker bandwidth.

D10 spectra for all three logical selectors are retained under
`work/audio-research/frankel/d10-force-direct-ring96-live/`. They show energy
above 48 kHz, no sharp local 24/48 kHz drop, and a rising 55--90 kHz noise
floor. Those observations support a wideband PDM path but do not replace a
calibrated external acoustic measurement; preserve each wrapper's capture and
freshness status independently.

## API application and qualification

The companion package is `com.csr460.powerphone` in the sibling
`csr460-powerphone` directory. Build it against this AOSP tree with:

```bash
cd ../csr460-powerphone
scripts/build-with-aosp-prebuilts.sh
```

The signed test APK is:

```text
app/build/manual/PowerPhoneLab-debug.apk
```

Install it only after the flashed device reports boot completion,
`vendor.powerphone.pdm.ready=1`, and
`vendor.powerphone.aoc_speaker_192k.ready=1`, then run:

```bash
scripts/run-device-suite.sh /path/to/new-results-directory
```

For a direct D10 capture from an already boot-certified image, avoid another
factory-diagnostic apply/revert transaction and retain the boot profile:

```bash
scripts/audio/frankel/d10-raw192-capture.sh \
  --output work/audio-research/frankel/boot-pdm0-192k.wav \
  --endpoint raw192-pdm0 --duration 12 --use-boot-profile
```

This mode requires `vendor.powerphone.pdm.ready=1`, snapshots the AoC restart
and coredump generation, stops audioserver for direct PCM ownership, verifies
freshness, turns EP3 and microphone power off, and rejects any readiness or
generation change. It deliberately leaves the certified F1 profile resident.

The suite exercises Java `AudioTrack` and native AAudio against both explicit
output addresses, plus Java `AudioRecord` and native AAudio against each of the
three explicit D10 addresses. Output runs require direct evidence of PCM0,D0
at `S32_LE`, two channels, 192000 Hz, period size 480, and buffer size 1920;
the Android-facing queue is independently 1920 frames. Input runs require
direct evidence of PCM0,D10 at `S16_LE`, one channel, 192000 Hz, period size
1920, and buffer size 7680; its Android-facing queue is also 1920 frames.
Frankel does not retain the
usual per-substream `/proc/asound/.../hw_params` node while these streams are
active; the harness must use a truthful HAL/driver observer rather than treat
that missing procfs file as either a pass or a stream failure.
Framework/ALSA metadata proves routing and clock configuration; it does not
prove physical ultrasonic bandwidth. Final per-transducer qualification still
requires a characterized external ultrasonic source/receiver, a calibrated
stimulus, and spectral evidence with no sharp 24 or 48 kHz cutoff, plus
continuous transfer evidence without XRUNs or timing discontinuities. A phone
self-loop cannot independently assign its combined response to speaker versus
microphone.
