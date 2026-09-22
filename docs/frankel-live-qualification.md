# Historical Frankel AP-PDM live qualification

> **Superseded experiment.** The card-1 `frankel_pdm_alsa` module, S32_LE
> capture routes, and `powerphone_pdm_loader` image modes below are not part of
> the current PowerPhone image and must not be run as an integration recipe.
> The hardware-qualified input is now card 0, PCM 10 (D10/EP3), mono S16_LE at
> 192000 Hz with 1920-frame periods and four periods; see
> [`frankel-aoc-d10-raw192-runtime.md`](frankel-aoc-d10-raw192-runtime.md) and
> [`frankel-powerphone-image-integration.md`](frankel-powerphone-image-integration.md).
> Speaker trials recorded later in this file remain historical evidence only;
> speaker image integration stays disabled until a live profile passes.

This runbook is for the first staged Pixel 10 (`frankel`) hardware trial after
bootloader fastboot and WSL USB forwarding return. It deliberately separates
two incompatible image modes:

- **Manual first-PDM0 image:** built with
  `POWERPHONE_AUDIO_SIDECAR=false`. ALSA card 1 and
  `frankel_pdm_alsa` must be absent at boot. This is the only supported image
  for `scripts/audio/frankel/raw-pdm-capture.sh` and the first AP-permission
  trial of PDM0 alone.
- **Integrated PowerPhone image:** built with
  `POWERPHONE_AUDIO_SIDECAR=true`. Its fail-closed loader owns card 1 and loads
  all three controllers with immutable mask `0x0d` before starting the AIDL
  sidecar. Do not run the single-controller wrapper on this image, and do not
  improvise `ctl.stop`, scalar-power changes, or `rmmod` to convert it into a
  manual trial image.

Run repository commands from the `pixel_aosp_manifest` root. Execute one
stage at a time and inspect its stated stop conditions before continuing.
Device-specific USB or fastboot serials are transient operator input and must
not be copied into tracked evidence.

## Image provenance and the corrected kernel pair

The current corrected pair is:

```text
work/audio-research/frankel/build-output/vendor_kernel_boot.img
work/audio-research/frankel/build-output/vbmeta.img
```

Its root `vbmeta.img` was derived from this exact known-bootable A-side anchor:

```text
work/audio-research/frankel/non-gsa-trial/vbmeta.current-bootable.img
```

Root vbmeta authenticates the complete static and logical A-side payload set,
not only `vendor_kernel_boot`. Fastboot properties cannot prove those payload
bytes. Use this pair only when the phone still contains the exact base from
which the anchor was captured. If a complete bundle or any authenticated
partition has been flashed since then, stop and build a pair against that
exact bundle's root vbmeta instead.

The retained 2026-08-30 provenance trail gives high operational confidence,
but not byte-level proof, that the current fastbooted A side still has this
base. The two `current-bootable` files are exact copies of the earlier
successfully booted `image-192k` pair, and the anchor's descriptors for every
other authenticated partition match the packaged Frankel AOSP bundle. The
last retained partition-write transcript restores `vendor_kernel_boot_a` and
then `vbmeta_a`, followed by several hours of live Android audio experiments;
there is no retained evidence of a later partition write before the corrected
pair above was built. However, the restore transcript does not record its
source filenames, the saved pair was not produced by a partition readback,
and no runtime attestation binds the phone's current bytes to those files. An
unlogged manual flash therefore cannot be excluded.

Absent contrary operator history, perform the strict fastboot preflight below
and flash the corrected pair directly. Rebooting the current image first can
confirm Android properties but cannot close the byte-provenance gap. If the
preflight or operator history indicates that another authenticated payload was
written, install a complete matched non-sidecar bundle and derive a new pair
from that bundle instead; note that the published full-bundle runner erases
userdata and metadata.

For a newly built manual image, select the mode atomically, package it, and
derive a new kernel pair from its packaged root vbmeta:

```bash
POWERPHONE_AUDIO_SIDECAR=false \
PIXEL_TARGET=frankel \
BUILD_JOBS="$(nproc)" \
  scripts/build-device.sh

PIXEL_TARGET=frankel scripts/package-device.sh

AUDIO_VBMETA_ANCHOR="$PWD/artifacts/frankel/device/vbmeta.img" \
AUDIO_KERNEL_RESULT_DIR="$PWD/work/audio-research/frankel/build-output-manual-pdm0" \
  scripts/audio/build-frankel-kernel.sh
```

The packaged `vendor_kernel_boot.img` and `vbmeta.img` are then that bundle's
rollback pair. Flashing the newly derived pair is valid only after the matching
complete bundle is installed.

## 1. Fastboot preflight, flash, and rollback

Windows must first see the phone. If needed, obtain its current bus ID from
`usbipd list`, then keep the mode-changing device attached from WSL:

```bash
"/mnt/c/Program Files/usbipd-win/usbipd.exe" attach \
  --wsl --auto-attach --unplugged --busid BUSID
```

Do not continue while the phone is visually in fastboot but absent from both
Windows and WSL.

Create one ignored evidence directory and select the sole fastboot transport:

```bash
FB=$PWD/work/toolchains/platform-tools/fastboot
CAND=$PWD/work/audio-research/frankel/build-output
ROLL=$PWD/work/audio-research/frankel/non-gsa-trial
RUN=$PWD/work/audio-research/frankel/live-first-pdm0-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$RUN"

# Replace this with the sole row reported by "$FB devices". Do not retain the
# value in tracked logs or documentation.
export FRANKEL_FASTBOOT_SERIAL='<sole-fastboot-serial>'

(
  set -euo pipefail
  for variable in \
      product unlocked is-userspace current-slot snapshot-update-status; do
    "$FB" -s "$FRANKEL_FASTBOOT_SERIAL" getvar "$variable" 2>&1
  done | tee "$RUN/fastboot-preflight.txt"
)
```

Require literal product `frankel`, unlocked `yes` or `true`,
`is-userspace=no`, `current-slot=a`, and `snapshot-update-status=none`. Stop on
any mismatch. Do not use these values as a substitute for the A-side image
provenance requirement above.

Flash the child image first and its root authority last. Do not reboot if
either write fails:

```bash
(
  set -euo pipefail
  "$FB" -s "$FRANKEL_FASTBOOT_SERIAL" --slot=a \
    flash vendor_kernel_boot "$CAND/vendor_kernel_boot.img" \
    2>&1 | tee "$RUN/flash-vendor-kernel-boot.txt"

  "$FB" -s "$FRANKEL_FASTBOOT_SERIAL" --slot=a \
    flash vbmeta "$CAND/vbmeta.img" \
    2>&1 | tee "$RUN/flash-vbmeta.txt"

  "$FB" -s "$FRANKEL_FASTBOOT_SERIAL" set_active a
  "$FB" -s "$FRANKEL_FASTBOOT_SERIAL" reboot
)
```

If the pair is partially written or Android fails to boot, force the phone
back to bootloader fastboot and restore both known-bootable files, again with
vbmeta last:

```bash
(
  set -euo pipefail
  "$FB" -s "$FRANKEL_FASTBOOT_SERIAL" --slot=a \
    flash vendor_kernel_boot "$ROLL/vendor_kernel_boot.current-bootable.img"
  "$FB" -s "$FRANKEL_FASTBOOT_SERIAL" --slot=a \
    flash vbmeta "$ROLL/vbmeta.current-bootable.img"
  "$FB" -s "$FRANKEL_FASTBOOT_SERIAL" set_active a
  "$FB" -s "$FRANKEL_FASTBOOT_SERIAL" reboot
)
```

Stop rather than attempting an audio probe if rollback fails, the phone no
longer returns to fastboot, or the base-image provenance is uncertain.

## 2. Root ADB and exact manual-image gate

Use the repository's private ADB server convention. Restarting adbd as root can
drop the USB transport; reattach the Android USB identity before the second
wait if necessary.

```bash
export ADB_LIBUSB=1
ADB=$PWD/work/toolchains/platform-tools/adb
ADB_PORT=5038

"$ADB" -P "$ADB_PORT" start-server &&
  timeout 180 "$ADB" -P "$ADB_PORT" wait-for-device &&
  "$ADB" -P "$ADB_PORT" root &&
  timeout 180 "$ADB" -P "$ADB_PORT" wait-for-device
```

Prove the exact environment before loading either research module:

```bash
adb_text() {
  "$ADB" -P "$ADB_PORT" shell "$@" | tr -d '\r'
}

EXPECTED_KERNEL=6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k
{
  printf 'uid=%s\n' "$(adb_text id -u)"
  printf 'boot_completed=%s\n' "$(adb_text getprop sys.boot_completed)"
  printf 'device=%s\n' "$(adb_text getprop ro.product.device)"
  printf 'vendor_build=%s\n' "$(adb_text getprop ro.vendor.build.id)"
  printf 'build_type=%s\n' "$(adb_text getprop ro.build.type)"
  printf 'kernel=%s\n' "$(adb_text uname -r)"
} | tee "$RUN/android-preflight.txt"

(
  set -e
  test "$(adb_text id -u)" = 0
  test "$(adb_text getprop sys.boot_completed)" = 1
  test "$(adb_text getprop ro.product.device)" = frankel
  test "$(adb_text getprop ro.vendor.build.id)" = CP2A.260805.005
  test "$(adb_text getprop ro.build.type)" = userdebug
  test "$(adb_text uname -r)" = "$EXPECTED_KERNEL"
)
```

The exact AoC card-0 ID `googleaocsndcar` is statically derived from the
reviewed DT card name and ALSA's ID conversion, but it has not yet been retained
as a live observation. Capture it now and stop rather than weakening the gate
if the live value differs. The current raw wrapper only rejects an empty ID or
`FrankelPDM`, so this stricter operator gate is mandatory.

```bash
card0_id=$(adb_text cat /proc/asound/card0/id)
loader_state=$(adb_text getprop init.svc.vendor.powerphone-pdm-loader)
sidecar_state=$(adb_text getprop init.svc.vendor.audio-hal-powerphone)
ready_state=$(adb_text getprop vendor.powerphone.pdm.ready)

{
  printf 'card0_id=%s\n' "$card0_id"
  printf 'loader=%s\n' "$loader_state"
  printf 'sidecar=%s\n' "$sidecar_state"
  printf 'ready=%s\n' "$ready_state"
  if "$ADB" -P "$ADB_PORT" shell 'test -e /proc/asound/card1'; then
    printf 'card1=present\n'
  else
    printf 'card1=absent\n'
  fi
  if "$ADB" -P "$ADB_PORT" shell \
      'test -d /sys/module/frankel_pdm_alsa'; then
    printf 'raw_module=present\n'
  else
    printf 'raw_module=absent\n'
  fi
  if "$ADB" -P "$ADB_PORT" shell \
      'test -x /vendor/bin/powerphone_pdm_loader'; then
    printf 'integrated_loader_binary=present\n'
  else
    printf 'integrated_loader_binary=absent\n'
  fi
  if "$ADB" -P "$ADB_PORT" shell \
      'test -x /vendor/bin/hw/android.hardware.audio.service-aidl.powerphone'; then
    printf 'integrated_sidecar_binary=present\n'
  else
    printf 'integrated_sidecar_binary=absent\n'
  fi
  if "$ADB" -P "$ADB_PORT" shell \
      'test -f /vendor_dlkm/lib/modules/frankel_pdm_alsa.ko'; then
    printf 'integrated_raw_module_file=present\n'
  else
    printf 'integrated_raw_module_file=absent\n'
  fi
  for microphone in MIC0 MIC1 MIC2; do
    printf '%s=%s\n' "$microphone" \
      "$(adb_text /system/bin/tinymix -D 0 -v -- "$microphone")"
  done
} | tee "$RUN/audio-preflight.txt"

(
  set -e
  test "$card0_id" = googleaocsndcar
  test -z "$loader_state"
  test -z "$sidecar_state"
  case "$ready_state" in ''|0) ;; *) false ;; esac
  "$ADB" -P "$ADB_PORT" shell 'test ! -e /proc/asound/card1'
  "$ADB" -P "$ADB_PORT" shell \
    'test ! -d /sys/module/frankel_pdm_alsa'
  "$ADB" -P "$ADB_PORT" shell \
    'test ! -x /vendor/bin/powerphone_pdm_loader'
  "$ADB" -P "$ADB_PORT" shell \
    'test ! -x /vendor/bin/hw/android.hardware.audio.service-aidl.powerphone'
  "$ADB" -P "$ADB_PORT" shell \
    'test ! -f /vendor_dlkm/lib/modules/frankel_pdm_alsa.ko'
  for microphone in MIC0 MIC1 MIC2; do
    case "$(adb_text /system/bin/tinymix -D 0 -v -- "$microphone")" in
      0|Off) ;;
      *) false ;;
    esac
  done
)
```

Require all three integrated payload rows to say `absent`. Together with empty
loader and sidecar states, this proves that the integrated selection is not
installed. Merely seeing `stopped` is insufficient: an integrated loader can
be retrying and race the manual wrapper. Never query or write `MIC3`, the
four-element `BUILDIN MIC POWER STATE`, or `BUILDIN_MIC_POWER_INIT`.

If a new manual image is required, return to the atomic
`POWERPHONE_AUDIO_SIDECAR=false` build at the beginning of this document. Do
not continue by dismantling an integrated image at runtime.

## 3. Read-only DT inventory

The DT probe translates only DT metadata; it does not map or access MMIO. The
cleanup trap unloads it if evidence collection fails.

```bash
(
  set -euo pipefail
  PROBE=$PWD/work/upstream/frankel-gki-15739706/modules/frankel_pdm_dt_probe.ko
  REMOTE_PROBE=/data/local/tmp/frankel_pdm_dt_probe.ko
  probe_may_be_loaded=false

  cleanup_probe() {
    if "$probe_may_be_loaded"; then
      "$ADB" -P "$ADB_PORT" shell rmmod frankel_pdm_dt_probe || true
    fi
    "$ADB" -P "$ADB_PORT" shell rm -f "$REMOTE_PROBE" || true
  }
  trap cleanup_probe EXIT INT TERM

  modinfo "$PROBE" | tee "$RUN/dt-probe-modinfo.txt"
  vermagic=$(modinfo -F vermagic "$PROBE")
  [[ "$vermagic" == "$EXPECTED_KERNEL "* ]]
  if "$ADB" -P "$ADB_PORT" shell \
      'test -d /sys/module/frankel_pdm_dt_probe'; then
    printf '%s\n' 'frankel_pdm_dt_probe is already loaded' >&2
    exit 1
  fi

  "$ADB" -P "$ADB_PORT" push "$PROBE" "$REMOTE_PROBE"
  probe_may_be_loaded=true
  "$ADB" -P "$ADB_PORT" shell insmod "$REMOTE_PROBE"
  "$ADB" -P "$ADB_PORT" shell dmesg > "$RUN/dt-probe-dmesg-full.txt"
  "$ADB" -P "$ADB_PORT" shell rmmod frankel_pdm_dt_probe
  probe_may_be_loaded=false
  "$ADB" -P "$ADB_PORT" shell rm -f "$REMOTE_PROBE"
  trap - EXIT INT TERM

  rg 'frankel_pdm_dt_probe' "$RUN/dt-probe-dmesg-full.txt" \
    | tee "$RUN/dt-probe.txt"
  rg -q 'read-only DT inventory start' "$RUN/dt-probe.txt"
  rg -q 'complete: matches=[0-9]+ reported=[0-9]+; no MMIO was mapped or read' \
    "$RUN/dt-probe.txt"
  ! "$ADB" -P "$ADB_PORT" shell \
    'test -d /sys/module/frankel_pdm_dt_probe'
)
```

Stop if vermagic differs, `insmod` or `rmmod` fails, the completion record is
missing, or the module remains resident. Do not substitute a direct MMIO probe
for this stage.

## 4. Volatile speaker patch and physical endpoint trial

> **Current candidate correction:** the native helper now guards 23 words and
> clamps enum 7 to 48 frames, then requests 192 kHz with divider shift 6
> (12.288 MHz). It does not include the two physical width-16 edits. The S32
> transaction below is therefore only a start-path isolation trial; it cannot
> qualify the four-slot physical bus or either speaker. A separately reviewed
> S16-slot trial and acoustic measurement remain mandatory.

Stop media, calls, assistants, camera clients, and every other speaker user.
The patch must begin uniformly stock with PCM 0,28 closed. First run the
hardware-read-only native ownership proof; it accepts a missing substream-status file
only after exact inventory/node validation and a complete root fd scan. The
commands below use a short low-level 18 kHz signal at raw amp gain 0; human silence at 18 kHz
is not evidence of failure, so use a near-field measurement receiver to locate
the active radiator.

Run this block as one transaction. Its exit trap reverts only after proving the
patch is still uniformly patched. A mixed or unknown state requires an AoC or
device reboot, followed by `check-stock`; do not resume a partial transaction.
The first transaction must use the native helper. The older Python transport
does not guard every write with the AoC restart/coredump generation and is
prohibited for live mutation.

```bash
(
  set -euo pipefail
  NATIVE=$PWD/work/aosp/out_pixel/frankel_speaker_helper/target/product/frankel/vendor/bin/frankel_aoc_speaker_patch
  REMOTE=/data/local/tmp/frankel_aoc_speaker_patch
  [[ -f "$NATIVE" && -x "$NATIVE" ]]
  "$ADB" -P "$ADB_PORT" push "$NATIVE" "$REMOTE"
  "$ADB" -P "$ADB_PORT" shell chmod 0755 "$REMOTE"
  PATCH=("$ADB" -P "$ADB_PORT" shell "$REMOTE")
  speaker_patched=false

  cleanup_speaker() {
    if "$speaker_patched"; then
      if "${PATCH[@]}" check-patched \
          >>"$RUN/speaker-cleanup.txt" 2>&1; then
        "${PATCH[@]}" revert >>"$RUN/speaker-cleanup.txt" 2>&1 || true
      else
        printf '%s\n' \
          'speaker patch state is not uniformly patched; reboot is required' \
          >>"$RUN/speaker-cleanup.txt"
      fi
    fi
    "$ADB" -P "$ADB_PORT" shell rm -f "$REMOTE" \
      >>"$RUN/speaker-cleanup.txt" 2>&1 || true
  }
  trap cleanup_speaker EXIT INT TERM

  "${PATCH[@]}" check-playback-closed 2>&1 \
    | tee "$RUN/speaker-check-playback-closed.txt"
  "${PATCH[@]}" check-stock 2>&1 | tee "$RUN/speaker-check-stock.txt"
  if ! "${PATCH[@]}" apply 2>&1 | tee "$RUN/speaker-apply.txt"; then
    printf '%s\n' 'apply failed; reboot and re-prove check-stock' >&2
    exit 1
  fi
  speaker_patched=true
  "${PATCH[@]}" check-patched 2>&1 \
    | tee "$RUN/speaker-check-patched.txt"

  for endpoint in earpiece bottom; do
    "$ADB" -P "$ADB_PORT" logcat -b all -c
    set +e
    scripts/audio/frankel/tinyplay.sh \
      --file work/audio-research/frankel/signals/tone-18k-192k-s32-4ch.wav \
      --endpoint "$endpoint" --rate 192000 --format s32 --channels 4 \
      --slot-format s32 \
      --period-size 512 --period-count 8 --ultrasonic-mode in-band \
      --high-rate-source direct --amp-gain 0 \
      --adb "$ADB" --adb-server-port "$ADB_PORT" \
      2>&1 | tee "$RUN/speaker-$endpoint-tinyplay.txt"
    playback_status=${PIPESTATUS[0]}
    set -e
    "$ADB" -P "$ADB_PORT" logcat -b all -d -v threadtime \
      > "$RUN/speaker-$endpoint-logcat.txt"
    (( playback_status == 0 ))
    rg -q 'AHWSinkSPKR started: 48 samples .*192 kHz' \
      "$RUN/speaker-$endpoint-logcat.txt"
    rg -q 'Speaker TDM Started with Clk: 12288 KHz, FS: 192 KHz' \
      "$RUN/speaker-$endpoint-logcat.txt"
    "${PATCH[@]}" check-patched 2>&1 \
      | tee "$RUN/speaker-$endpoint-post-check.txt"
  done

  "${PATCH[@]}" revert 2>&1 | tee "$RUN/speaker-revert.txt"
  speaker_patched=false
  "${PATCH[@]}" check-stock 2>&1 \
    | tee "$RUN/speaker-final-stock.txt"
  "$ADB" -P "$ADB_PORT" shell rm -f "$REMOTE"
  trap - EXIT INT TERM
)
```

Build the native helper only after the complete device build has finished, by
copying its reviewed source directory beneath the AOSP tree and running the
named Soong targets in a dedicated output directory. Never use the primary
`out_pixel/frankel` here: a direct target build installs this vendor binary in
that product tree, and a later target-files repackage can accidentally include
the transient helper in a flashable vendor image.

```bash
mkdir -p work/aosp/vendor/csr460/tools/frankel_aoc_speaker_patch
rsync -a --delete tools/audio/device/frankel_aoc_speaker_patch/ \
  work/aosp/vendor/csr460/tools/frankel_aoc_speaker_patch/
(
  cd work/aosp
  export OUT_DIR=out_pixel/frankel_speaker_helper
  source build/envsetup.sh
  lunch aosp_frankel-trunk_staging-userdebug
  m frankel_aoc_speaker_patch frankel_aoc_speaker_patch_host_test
  "$OUT_DIR/host/linux-x86/bin/frankel_aoc_speaker_patch_host_test"
)
```

Before any subsequent device-image build, either leave this module confined to
the isolated output or remove its staged AOSP source. Never stage a second copy
under another `vendor/csr460` path because both copies declare the same two
Soong module names.

The unprefixed `Main AMP Enable Switch` is evidence-backed as the earpiece
route. Calling `R Main AMP Enable Switch` the bottom speaker is still a
topology inference until the two isolated trials confirm the enclosure
locations acoustically. Record the observation without recording a USB or
device identifier.

Stop before microphone work if either endpoint lacks both exact AoC facts,
tinyplay reports an underrun/error, route cleanup is uncertain, or the AoC log
reports any block/clock/rate other than 48 frames and 192 kHz/12.288 MHz.
Complete `revert` and `check-stock` first; use a reboot if uniform state cannot
be proven. Even a clean result here does not qualify a speaker: the physical
S16-slot and wide-band gates above are still open.

## 5. Guarded PDM0 with logical MIC0

This first run establishes only whether the AP can safely read PDM0 and deliver
basic PCM. `MIC0` is an independent AoC logical scalar; its correspondence to
physical controller PDM0 or an enclosure microphone is unknown. Do not label
the output as a physical bottom, top, or camera microphone.

The wrapper enforces this order:

1. require card 1/module absent and scalar MIC0/MIC1/MIC2 off;
2. perform a read-only A32 idle check;
3. load only controller mask `0x1` with polling disabled;
4. power logical scalar MIC0 and read it back;
5. repeat the A32 idle check;
6. apply the guarded PDM0 A32 handoff, then perform one synchronous AP
   `B+0x10` status-only read; require selected `status=probe_reads=1`, zero
   unselected activity, and zero FIFO/data counters while polling remains off;
7. consume that one-shot proof by enabling AP polling, then capture fixed mono
   S32_LE/192000 with 19,200-frame periods and four periods;
8. reap tinycap, stop polling synchronously, collect stats/dmesg, revert A32,
   power MIC0 off, unload the module, then pull and validate the WAV.

Save logcat separately because the wrapper's `.raw-pdm-a32.txt` is an A32
transaction transcript, not an AoC runtime log. The scalar mixer setter does
not propagate the lower-level power-command result, so inspect the captured
AoC rows even when scalar readback succeeds.

```bash
(
  set -u -o pipefail
  OUT=$RUN/raw-pdm0-mic0-192k.wav
  "$ADB" -P "$ADB_PORT" logcat -b all -c

  set +e
  scripts/audio/frankel/raw-pdm-capture.sh \
    --output "$OUT" \
    --controller PDM0 \
    --power MIC0 \
    --duration 5 \
    --ack-hardware-write \
    --ack-ap-permission-trial \
    --adb "$ADB" \
    --adb-server-port "$ADB_PORT" \
    2>&1 | tee "$RUN/raw-pdm0-mic0-run.txt"
  raw_status=${PIPESTATUS[0]}
  set -e

  if timeout 20 "$ADB" -P "$ADB_PORT" get-state >/dev/null 2>&1; then
    "$ADB" -P "$ADB_PORT" logcat -b all -d -v threadtime \
      > "$RUN/raw-pdm0-mic0-logcat.txt" || true
  fi
  (( raw_status == 0 )) || {
    printf '%s\n' \
      'STOP: inspect the wrapper cleanup result; do not improvise cleanup' >&2
    exit "$raw_status"
  }

  {
    printf 'card0_id=%s\n' "$(adb_text cat /proc/asound/card0/id)"
    if "$ADB" -P "$ADB_PORT" shell 'test -e /proc/asound/card1'; then
      printf 'card1=present\n'
    else
      printf 'card1=absent\n'
    fi
    if "$ADB" -P "$ADB_PORT" shell \
        'test -d /sys/module/frankel_pdm_alsa'; then
      printf 'raw_module=present\n'
    else
      printf 'raw_module=absent\n'
    fi
    for microphone in MIC0 MIC1 MIC2; do
      printf '%s=%s\n' "$microphone" \
        "$(adb_text /system/bin/tinymix -D 0 -v -- "$microphone")"
    done
  } > "$RUN/raw-pdm0-mic0-post-state.txt"

  rg -q '^card0_id=googleaocsndcar$' \
    "$RUN/raw-pdm0-mic0-post-state.txt"
  rg -q '^card1=absent$' "$RUN/raw-pdm0-mic0-post-state.txt"
  rg -q '^raw_module=absent$' "$RUN/raw-pdm0-mic0-post-state.txt"
  for microphone in MIC0 MIC1 MIC2; do
    rg -q "^$microphone=(0|Off)$" \
      "$RUN/raw-pdm0-mic0-post-state.txt"
  done
)
```

Do not add `--ack-pdm0-permission-proven` to the first PDM0 run; that option is
only a gate for later PDM2/PDM3 trials. Do not use `reset-routes.sh` or issue
manual power/module commands after a failed wrapper. Its fail-closed cleanup
intentionally leaves dependent state unchanged when it cannot prove an
earlier prerequisite:

- unproven tinycap stop: do not revert A32;
- unproven polling-off: do not revert A32;
- unproven A32 restoration: do not power the scalar off;
- unproven scalar-off: do not unload the module.

Stop and preserve evidence on any AP abort/hang or device loss, cleanup error,
malformed or short WAV, zero FIFO words/delivery, or module/ALSA overrun. Do
not advance to PDM2 or PDM3.

## Evidence and interpretation boundary

A clean run produces these ignored local artifacts under `$RUN`:

```text
fastboot-preflight.txt
flash-vendor-kernel-boot.txt
flash-vbmeta.txt
android-preflight.txt
audio-preflight.txt
dt-probe-modinfo.txt
dt-probe-dmesg-full.txt
dt-probe.txt
speaker-check-stock.txt
speaker-apply.txt
speaker-check-patched.txt
speaker-earpiece-tinyplay.txt
speaker-earpiece-logcat.txt
speaker-bottom-tinyplay.txt
speaker-bottom-logcat.txt
speaker-revert.txt
speaker-final-stock.txt
raw-pdm0-mic0-run.txt
raw-pdm0-mic0-logcat.txt
raw-pdm0-mic0-post-state.txt
raw-pdm0-mic0-192k.wav
raw-pdm0-mic0-192k.raw-pdm-stats.txt
raw-pdm0-mic0-192k.raw-pdm-status-probe.txt
raw-pdm0-mic0-192k.raw-pdm-dmesg.txt
raw-pdm0-mic0-192k.raw-pdm-tinycap.txt
raw-pdm0-mic0-192k.raw-pdm-a32.txt
raw-pdm0-mic0-192k.raw-pdm-a32.json
```

A failed completed capture may additionally be retained with a
`.failed-capture-PID.wav` suffix. Never retain a USB serial, bus ID, network
identifier, account/SIM identifier, or other device-unique value in tracked
documentation.

Successful PCM delivery proves neither the MIC0-to-PDM0 mapping nor genuine
192 kHz acoustic bandwidth. Only after a clean permission trial, use an
independently calibrated stimulus/receiver chain and the Nyquist checks in
[`scripts/audio/host/README.md`](../scripts/audio/host/README.md). A WAV header,
sample count, rising high-frequency noise floor, or phone self-loop alone is
not endpoint-isolated proof.
