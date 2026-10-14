# Cubs PowerPhone: boot-integrated APIs and direct ALSA

The qualified v7 replacement-primary image applies the **mono**
`mono192-edge0-mcps112-d5-two-slot-v5` profile automatically on each boot.
It provides fixed 192-kHz D10 mono capture and D5 stereo playback, with
ordinary built-in speaker/microphone routes and explicitly addressed research
routes. The isolated 10/10 API matrix, four API duplex runs, ordinary 48-kHz
playback, three 30-second direct duplex runs, and a normal reboot with post-boot
API checks passed. See the [exact qualification and retained failures](../../../docs/cubs-powerphone-qualification-20260923.md)
and [matching flash bundle](../../../artifacts/cubs-powerphone-192k-20260923/).
These bounded results do not qualify concurrent ordinary/research output or a
full 96-kHz acoustic passband. This is separate from the historical manually
applied RAW3 experiments below.

Start with the [Android API and readiness guide](../../../docs/cubs-audio-api.md)
for Java AudioTrack, AudioRecord UNPROCESSED, and AAudio. The
[API duplex reference guide](API_DUPLEX.md) records through the real Android
API without taking over ALSA or stopping audio services. One input and one
output may coexist; ordinary playback and a research speaker cannot mix
concurrently on the single D5 output. Contention recovery does not guarantee
that concurrent UI sounds are played.

The reproducible opt-in OS bundle workflow is documented in
[POWERPHONE_BUNDLE.md](POWERPHONE_BUNDLE.md). It assembles explicitly selected
captured/custom-kernel/primary images into a new directory. The qualified bundle
above preserves the original Cubs and Frankel releases; arbitrary newly assembled
images do not inherit its hardware qualification.

## Direct endpoints on the boot-integrated mono profile

Run from the `pixel_aosp_manifest` repository root in WSL, with the matching
integrated image already booted and root ADB already available. Do **not** run
the manual firmware applier first. Check the native status and the readiness
conditions in the API guide: phase `ready`, both direction flags `1`, the exact
profile above, matching current boot ID, and unchanged zero AoC restart/coredump
counters. `sys.boot_completed=1` alone is insufficient.

```bash
SERIAL=YOUR_CUBS_SERIAL
export ADB_LIBUSB=1
ADB=work/toolchains/platform-tools-37.0.1/platform-tools/adb
RUN=work/audio-research/cubs/NEW_BOOT_MONO_DIRECT_SESSION
test ! -e "$RUN"
mkdir -p "$RUN"

"$ADB" -P 5038 -s "$SERIAL" shell /vendor/bin/cubs_powerphone_boot --status

# D10, S16 mono: select logical microphone 0, 1, or 2.
bash scripts/audio/cubs/direct-mic-capture.sh \
  --serial "$SERIAL" --adb-server-port 5038 \
  --rate 192000 --mic 0 --duration 3 --output-dir "$RUN/quiet-mic0"

# Generate a stereo S32 192-kHz probe for D5.
python3 scripts/audio/cubs/generate-probe.py \
  --output "$RUN/tone20731.wav" --rate 192000 \
  --tone 20731 --duration 3 --peak .08

# Play through the top/earpiece; use --endpoint bottom for the bottom speaker.
bash scripts/audio/cubs/direct-speaker-play.sh \
  --serial "$SERIAL" --adb-server-port 5038 \
  --wav "$RUN/tone20731.wav" --pcm deep --endpoint top --asp bypass \
  --output-dir "$RUN/play-top"

# One wrapper owns both routes and retains the original microphone WAV.
bash scripts/audio/cubs/duplex-baseline.sh \
  --serial "$SERIAL" --adb-server-port 5038 \
  --wav "$RUN/tone20731.wav" --pcm deep --endpoint bottom --asp bypass \
  --capture-rate 192000 --mic 2 \
  --capture-duration 6 --max-playback-duration 3 \
  --output-dir "$RUN/bottom-mic2"
```

Use new output directories for every run. Logical microphones `0/1/2` map to
physical PDM lanes `0/2/3`; their enclosure-hole locations are not established.
On this boot profile use only mono `--mic 0|1|2`, capture rate `192000`, and
playback `--pcm deep --asp bypass` with a 192-kHz stereo S32 WAV. Do not use
`--mic all`, another rate, or the legacy primary/ultrasonic PCM routes.

These direct wrappers are deliberately disruptive: they stop audioserver and
the proprietary/replacement HAL owners, require closed PCMs, and exclusively
configure the real mixer/ALSA routes. They close the PCM before route teardown,
restore the saved controls only if the AoC generation is unchanged, and **leave
audio services stopped in quarantine**, even after success. Readiness properties
are not permission to restart a HAL over that direct session. Keep failed
captures and logs; on a generation change or failed cleanup, stop and reboot.

Return to Android API audio with a full reboot, not manual `start` commands or
marker removal:

```bash
"$ADB" -P 5038 -s "$SERIAL" reboot
```

On the integrated image, that reboot reapplies the mono profile automatically;
wait for its fresh readiness checks before launching an API test. It does not
restore the proprietary primary HAL. A 192-kHz WAV or successful command is not
acoustic-bandwidth proof: TAS2572 processes internally at 96 kHz, and the measured
high-frequency foldback prevents claiming a full 96-kHz speaker passband.

## Historical manual RAW3 / mono firmware experiments

The remainder describes the earlier exclusive, reboot-volatile firmware
workflow, not the integrated primary/API setup. **Never hot-switch mono and
RAW3, and never run this manual applier over an automatically patched boot.**
These instructions require a separately prepared baseline image/boot without
the automatic PowerPhone bootstrap; a normal reboot of the integrated image
does not provide that baseline. Do not disable guards or delete markers to
make an incompatible profile pass. Keep historical manifests and failed WAVs.

The measured RAW3 MCPS112 profile retained a full 30-second 20731-Hz tone
from each speaker on all three microphones without detected phase events,
dropouts, or clipping. Capture has a fixed 80-ms startup deficit. See the
[exact results and limits](../../../tools/audio/cubs/RAW_MCPS112_CONTROL.md).
TAS2572 accepting a 192-kHz serial input does **not** establish a full
96-kHz acoustic passband; its internal processing limitation is separate.

### Prerequisites and profile selection

Use the matching Cubs custom kernel, live firmware version15876290-polygon,
root ADB on port5038, and the guarded diagnostic helper
`/data/local/tmp/cubs_aoc_diag` with `write-raw` support. Its host build
entrypoint is [build-diag.sh](../../../tools/audio/cubs/build-diag.sh).
Do not substitute donor modules or Frankel firmware offsets.

The tested experimental kernel image, already flashed in the research session,
is:

```text
work/audio-research/cubs/raw3-admission-kernel-20260922/vendor_kernel_boot.img
```

It retains the capture192/playback admission changes and widens the RAW
channel guard to admit three channels. It does not itself install the
firmware geometry. Reproduction, image prerequisites, and the mandatory
current-boot RAW3 kernel-admission marker recipe are in
[RAW3_PACKED_CANDIDATE.md](../../../tools/audio/cubs/RAW3_PACKED_CANDIDATE.md).
Only the operator who actually flashed that known image may create its
known-flash marker; it is not live-module attestation.

Choose **one** capture manifest per fresh boot:

| Session | Explicit manifest | Capture selection |
| --- | --- | --- |
| Simultaneous RAW3, measured long-run profile | `tools/audio/manifests/cubs_d10_raw3_packed_mcps112_control.json` | `--mic all` |
| Individual mono edge0 with MCPS112, separately measured30-second continuity on each mic | `tools/audio/manifests/cubs_d10_native192_edge0_mcps112_control.json` | `--mic 0`, `1`, or `2` |

Mono and RAW3 are mutually exclusive, not dynamically switchable modes.
The applier requires `--manifest`; older edge1/no-budget profiles are
historical controls with known failures. Both current variants retain
receiver edge0 and paired RAW +112/−112 processing-budget votes.
The separate mono results are indexed locally at
`work/audio-research/cubs/mono192-mcps112-qualification-20260922/QUALIFICATION.md`.
They retain40–80ms capture startup deficits, with no loss inside the full
30-second20731Hz tones. This is not full-Nyquist microphone qualification.

### Prepare the speaker template and fresh boot

The current speaker template is the v5 two-slot192 worker with ENTRY96:

```text
work/audio-research/cubs/direct192-two-slot-template-v5-window-frame-20260923/combined-manifest.json
```

To rebuild it from the current assembly, use a **new** output directory.
The builder emits a zero-pointer template; the applier resolves and guards
the device's current-boot objects. See
[DIRECT192_CANDIDATE.md](../../../tools/audio/cubs/DIRECT192_CANDIDATE.md).

```bash
SERIAL=YOUR_CUBS_SERIAL
export ADB_LIBUSB=1
ADB=work/toolchains/platform-tools-37.0.1/platform-tools/adb
RUN=work/audio-research/cubs/NEW_SESSION_DIRECTORY
test ! -e "$RUN"
mkdir -p "$RUN"

python3 tools/audio/cubs/build_direct96_manifest.py --speaker-only \
  --sample-rate 192000 --slots 2 --output-dir "$RUN/speaker-template"

"$ADB" -P 5038 -s "$SERIAL" reboot
"$ADB" -P 5038 -s "$SERIAL" wait-for-device
"$ADB" -P 5038 -s "$SERIAL" root
"$ADB" -P 5038 -s "$SERIAL" wait-for-device
"$ADB" -P 5038 -s "$SERIAL" shell 'id -u; getprop ro.product.device; getprop sys.boot_completed'
```

Proceed only when these report `0`, `cubs`, and `1`; no audio trial should
precede this boot's application. For RAW3, now follow the linked
current-boot kernel-admission marker recipe. Recreate it after every reboot.
Build the capture variants only if needed using the commands in the
[MCPS112 document](../../../tools/audio/cubs/RAW_MCPS112_CONTROL.md).

### Apply and record

This example selects RAW3. For mono, replace the manifest and every
`--mic all` below with the selected mono microphone.

```bash
python3 tools/audio/cubs/apply_mono192_candidate.py \
  --serial "$SERIAL" --adb-server-port 5038 \
  --manifest tools/audio/manifests/cubs_d10_raw3_packed_mcps112_control.json \
  --speaker-manifest "$RUN/speaker-template/combined-manifest.json" \
  --output-dir "$RUN/apply"

bash scripts/audio/cubs/direct-mic-capture.sh \
  --serial "$SERIAL" --adb-server-port 5038 \
  --rate 192000 --mic all --duration 3 --output-dir "$RUN/quiet3"

python3 scripts/audio/cubs/generate-probe.py \
  --output "$RUN/tone20731.wav" --rate 192000 \
  --tone 20731 --duration 30 --peak .08

bash scripts/audio/cubs/duplex-baseline.sh \
  --serial "$SERIAL" --adb-server-port 5038 \
  --wav "$RUN/tone20731.wav" --pcm deep --endpoint bottom --asp bypass \
  --capture-rate 192000 --mic all \
  --capture-duration 35 --max-playback-duration 30 \
  --output-dir "$RUN/bottom-all-20731-30s"
```

Repeat the duplex command with `--endpoint top` and a different, new output
directory for the earpiece. The wrappers own routing, use D5 stereo S32
playback and D10 S16 capture, save original WAVs/logs, and retain failures.
See [RAW3.md](RAW3.md) for channel selection, duration gates, and evidence
limits. Shell success, headers, and sample counts are not Nyquist or
continuity qualification; inspect every original channel and full tone
interval, including missing tails and phase discontinuities.

### Quarantine and restoration

The applier and wrappers intentionally leave Android audio services stopped.
`/dev/powerphone-cubs-mono192` is a quarantine flag, not proof that mono is
safe. RAW3 also requires the exact successful-profile marker
`/dev/powerphone-cubs-raw3-192`. Do not manually restart ordinary audio,
delete markers to evade guards, or continue after an AoC reset.

```bash
"$ADB" -P 5038 -s "$SERIAL" reboot
```

A full reboot of this non-bootstrap baseline discards volatile AoC patches and
tmpfs markers and restores the ordinary firmware path. The experimental kernel admission image remains
flashed; restoring the original kernel image is a separate explicit rollback,
not an effect of reboot. Reapply only on another fresh, guarded boot.

## Historical incremental primary-HAL boot-trial runner

For explicitly assembled experimental `vendor.img` / `system_ext.img` trial
images, see [PRIMARY_TRIAL_FLASH.md](PRIMARY_TRIAL_FLASH.md) and
[flash-primary-trial.sh](flash-primary-trial.sh). That opt-in runner uses
bootloader fastboot for optional physical images and fastbootd only for the
two logical images. This development runner is not the qualified release's
standalone `flash-all.sh`; use the matching bundle above for the complete image
set and its prerequisites.
