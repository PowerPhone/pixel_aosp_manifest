# Incremental Frankel playback image build

These are ordered **build-only** commands for an already-working Frankel
AOSP userdebug tree. They select the primary playback and research idle
configuration, custom SYSTEM/speaker UI-volume compensation and immediate
idle standby, rebuild the vendor audio components, add the dedicated D5
period worker to an explicit pre-RT kernel ramdisk, and stage two candidate
images. They never flash a phone or overwrite the release bundle, and contain
no separate hash-verification, attestation, simulation, or mock-test step.

This is deliberately an incremental runbook, not a clean-room manifest sync
or a declaration that whatever happens to be in the working tree is verified.
Select the intended, hardware-qualified sidecar sources before executing it;
do not run it against an unqualified diagnostic edit or while another build
is active. Keep the same shell for the command blocks below.

## Preconditions

- Start in `pixel_aosp_manifest`, on the WSL work volume.
- `work/aosp` is initialized for `frankel`, with
  `out_pixel/frankel/combined-frankel.ninja` already generated.
- The PowerPhone AIDL source stack and generated vendor helper packages are
  already selected. The matching existing system, system_ext, product, boot,
  vendor_boot, and other images are retained by the release owner.
- The matching GKI DDK is prepared at
  `work/upstream/frankel-gki-15739706/ddk-workspace`.
- The explicit baseline below is the **pre-RT PowerPhone kernel image**, not
  an arbitrary OEM stock image. It already contains the other AoC/codec
  changes required by this profile. Never replace that input with the final
  RT-patched image; the preparation tools reject an already-patched util.
- Standard build-host dependencies from the repository README are installed.
  This sequence additionally uses `python3`, `python-is-python3`, GNU `cpio`,
  `lz4`, `find`, `sort`, and coreutils. The `vendor/build.prop` dependency
  chain includes kernel extraction with an `/usr/bin/env python` shebang;
  installing only `python3` does not satisfy that command on every WSL host.
  The compiler, Ninja, and Android boot-image tools come from
  the existing AOSP/DDK trees. Install missing `cpio`/`lz4` with the WSL package
  manager if necessary.

No framework/system image is rebuilt here. If system, system_ext, product,
SELinux, bootstrap gate, or framework sources changed since the retained
images were built, build those images separately before assembling a complete
flash bundle. In particular, rebuilding a helper's unchanged required
system_ext init file does not make an old system_ext image contain new edits.

## 1. Explicit inputs, fresh output, and recoverable originals

Choose a new run suffix each time; an existing output directory is rejected.
Paths below intentionally stay inside the project workspace.

```sh
set -euo pipefail
audio_project_root=$PWD
audio_aosp="$audio_project_root/work/aosp"
audio_generated="$audio_aosp/vendor/google_devices/frankel"
audio_product="$audio_aosp/out_pixel/frankel/target/product/frankel"
audio_hostbin="$audio_aosp/out_pixel/frankel/host/linux-x86/bin"
audio_baseline="$audio_project_root/artifacts/frankel/powerphone-audio192-dev/vendor_kernel_boot.img"
audio_run="$audio_project_root/work/audio-research/frankel/incremental-playback192-run-01"

test -f "$audio_aosp/out_pixel/frankel/combined-frankel.ninja"
test -f "$audio_baseline"
test ! -e "$audio_run"
mkdir -p "$audio_run/originals" "$audio_run/images" "$audio_run/logs"

cp -p --reflink=auto \
  "$audio_generated/proprietary/vendor/bin/hw/android.hardware.audio.service-aidl.aoc" \
  "$audio_run/originals/android.hardware.audio.service-aidl.aoc"
cp -p --reflink=auto \
  "$audio_generated/proprietary/vendor/etc/powerhint.json" \
  "$audio_run/originals/powerhint.json"
cp -p --reflink=auto \
  "$audio_generated/proprietary/vendor/etc/audio/config/mixer_paths.xml" \
  "$audio_run/originals/mixer_paths.xml"
cp -p --reflink=auto \
  "$audio_generated/proprietary/vendor/etc/audio/config/audio_policy_volumes.xml" \
  "$audio_run/originals/audio_policy_volumes.xml"
cp -p --reflink=auto "$audio_generated/sysprop/vendor.prop" \
  "$audio_run/originals/vendor.prop"
cp -p --reflink=auto "$audio_product/vendor/build.prop" \
  "$audio_run/originals/build.prop"
cp -p --reflink=auto "$audio_product/vendor.img" \
  "$audio_run/originals/vendor-before.img"
```

These backups preserve the immediately preceding state, which may already
include the research selection. The canonical patchers also support removing
their own reviewed changes; they do not undo unrelated user edits.

## 2. Select the qualified primary profile and research idle policy

```sh
python3 tools/audio/patch_frankel_primary_hal_192k.py \
  "$audio_generated/proprietary/vendor/bin/hw/android.hardware.audio.service-aidl.aoc" \
  --set-state patched --in-place

python3 tools/audio/patch_frankel_primary_speaker_route.py \
  "$audio_generated/proprietary/vendor/etc/audio/config/mixer_paths.xml" \
  --set-state patched --in-place

python3 tools/audio/patch_frankel_system_ui_volume.py \
  "$audio_generated/proprietary/vendor/etc/audio/config/audio_policy_volumes.xml" \
  --state ui-plus6db --in-place

python3 tools/audio/patch_frankel_powerphone_idle_residency.py \
  "$audio_generated/proprietary/vendor/etc/powerhint.json" \
  --state research --in-place

python3 tools/audio/patch_frankel_powerphone_standby.py \
  "$audio_generated/sysprop/vendor.prop" --state research --in-place
```

The first selects FIFO/90, 960-frame framework transactions, 192×20 ALSA
geometry, and full-ring autostart, scoped to the reviewed D1/D5 playback
paths. It accepts the prior prefill-only and combined candidate states.
The route selector retains fixed-192 geometry/ASP bypass and restores donor
amplifier code 17 for ordinary speaker/speaker-safe routes; earpiece code 6
and independent research BUS/raw gain controls are unchanged. It accepts the
prior gain-6 profile through complete scoped stanzas, without hashes.
The UI-volume selector adds 600 millibels (+6 dB) only to the reviewed
`AUDIO_STREAM_SYSTEM` / `DEVICE_CATEGORY_SPEAKER` curve. This is **custom
compensation**, not restoration of the factory curve: that curve and the
system-effect default attenuation already matched factory values. Amplifier
code 17, digital PCM volume 817, music/other streams, external devices and
research-BUS curves are unchanged. `--state factory --in-place` reverses this
selection; unknown/custom curves are rejected without hashes. Select that
alternative explicitly if building without the custom UI increase. See
[UI-volume evidence and qualification status](../../../docs/frankel-ui-volume-20260912.md).
The power selector changes four display-idle actions to 1,500,000-µs cluster idle
residency. This trades higher idle power for latency stability; it neither
locks CPU frequencies nor changes thermal limits. See
[primary profile details](../../../tools/audio/frankel_primary_playback_192k.md).

The standby selector sets `ro.audio.flinger_standbytime_ms=0`: normal
AudioFlinger presentation completion enters hardware standby without the
three-second idle hold. This prevents a completed research BUS stream from
retaining D5 during a subsequent ordinary speaker route. It does **not**
arbitrate overlapping active primary/BUS streams; those remain unsupported.
The property is read once per audioserver process, so qualify it after reboot,
not by assuming a changed build file updates the running system.

The generated-vendor sanitizer already invokes the primary selector, selects
`ui-plus6db` for the patched primary profile (`factory` otherwise), and
selects this standby property with `POWERPHONE_AUDIO_SIDECAR=true`, but it
does **not** automatically select the optional cluster-idle policy. Reapply
the power-selector command after regenerating vendor files for this research profile.
The direct standby-selector command also makes this incremental path independent of a
new extraction/sanitization pass.

## 3. Build and install the selected vendor prerequisites, then vendor.img

Use the already-generated Ninja graph and set `OUT_DIR` explicitly. Running
the full `vendorimage`/`systemimage` graph unnecessarily expanded approximately
155,000 dependencies during this bring-up; a missing `OUT_DIR` also caused
header-ABI tooling to fail with `Duplicate root dir`. The nodeps image target
is appropriate only after the required installed targets below have finished.

Keep `-d keepdepfile -d keeprsp` on every direct Ninja invocation, matching
the normal Soong UI. Otherwise Ninja can delete protobuf `.d` files that the
graph also declares as outputs; a subsequent invocation then rebuilds host
`aconfig` and cascades into thousands of framework Java dependencies. The
flags preserve dependency/response files without bypassing necessary builds.

```sh
(
  cd "$audio_aosp"
  export OUT_DIR=out_pixel/frankel
  prebuilts/build-tools/linux-x86/bin/ninja \
    -d keepdepfile -d keeprsp \
    -f out_pixel/frankel/combined-frankel.ninja \
    android.hardware.audio.service-aidl.powerphone \
    libpowerphone_tinyalsa_v1 \
    frankel_aoc_speaker_patch \
    frankel_aoc_d10_patch \
    frankel_powerphone_d10_bootstrap \
    frankel_aoc_staged_play \
    out_pixel/frankel/target/product/frankel/vendor/bin/hw/android.hardware.audio.service-aidl.aoc \
    out_pixel/frankel/target/product/frankel/vendor/etc/audio/config/mixer_paths.xml \
    out_pixel/frankel/target/product/frankel/vendor/etc/audio/config/audio_policy_volumes.xml \
    out_pixel/frankel/target/product/frankel/vendor/etc/powerhint.json \
    out_pixel/frankel/target/product/frankel/vendor/build.prop

  prebuilts/build-tools/linux-x86/bin/ninja \
    -d keepdepfile -d keeprsp \
    -f out_pixel/frankel/combined-frankel.ninja vendorimage-nodeps
) 2>&1 | tee "$audio_run/logs/vendor-build.log"

cp -p --reflink=auto "$audio_product/vendor.img" "$audio_run/images/vendor.img"
```

These are production targets, not host test targets. They rebuild the current
selected sources and actual installed dependencies. The command does not
synchronize or discard source changes; use the already-selected matching
canonical/generated helper source copies. A successful build alone is not
playback qualification.

## 4. Build the matching RT helper and extract the explicit pre-RT ramdisk

```sh
bash tools/audio/kernel/frankel_d5_period_rt/build-frankel-gki.sh \
  2>&1 | tee "$audio_run/logs/rt-module-build.log"

mkdir -p "$audio_run/baseline/unpacked" "$audio_run/baseline/ramdisk-root"
"$audio_hostbin/unpack_bootimg" --boot_img "$audio_baseline" \
  --out "$audio_run/baseline/unpacked" \
  > "$audio_run/logs/baseline-unpack.log"
test -f "$audio_run/baseline/unpacked/vendor_ramdisk00"
test ! -e "$audio_run/baseline/unpacked/vendor_ramdisk01"

lz4 -d -c "$audio_run/baseline/unpacked/vendor_ramdisk00" | (
  cd "$audio_run/baseline/ramdisk-root"
  cpio --quiet -idm --no-absolute-filenames
)
```

This image has one LZ4 vendor-kernel ramdisk fragment. Do not reuse these
commands with a different multi-fragment layout or an untrusted archive.
The following step validates the relevant module and dependency layout before
staging changes. The baseline image and extracted baseline remain unchanged.

## 5. Stage the RT imports/load order and repack a new kernel image

```sh
python3 tools/audio/prepare_frankel_d5_rt_ramdisk.py \
  "$audio_run/baseline/ramdisk-root" "$audio_run/rt-prepared" \
  --helper work/upstream/frankel-gki-15739706/modules/frankel_d5_period_rt.ko \
  --symvers work/upstream/frankel-gki-15739706/modules/frankel_d5_period_rt.Module.symvers \
  2>&1 | tee "$audio_run/logs/rt-preparation.log"

bash tools/audio/repack_frankel_vendor_kernel_boot.sh \
  "$audio_baseline" "$audio_run/rt-prepared/ramdisk-root" "$audio_run/rt-image" \
  2>&1 | tee "$audio_run/logs/kernel-image-build.log"

cp -p --reflink=auto "$audio_run/rt-image/vendor_kernel_boot.img" \
  "$audio_run/images/vendor_kernel_boot.img"
```

The prep helper preserves originals outside its ramdisk payload, redirects
only the reviewed D5 period queue import, extends teardown barriers, adds the
matching helper's exported ABI versions, and updates module load/dependency
metadata. Already-RT modules or mixed edits are rejected, not patched again.
The repacker preserves the baseline image arguments/DTB and generates normal
AVB footer metadata required by the image format; that is not a separate
hash-verification or attestation pass.

## Output and handoff boundary

The only new staged image outputs are:

- `$audio_run/images/vendor.img`
- `$audio_run/images/vendor_kernel_boot.img`

Logs, original inputs, unpacked baseline, and prepared ramdisk remain under
the same fresh run directory. No `artifacts/` image, flash-all script, or
connected device is changed. The release owner must combine these outputs
with the matching unchanged images, flash through the existing workflow,
and qualify boot, SELinux, actual worker scheduling, sustained raw/API
playback, correct acoustic frequency, jitter, endpoint routing, and lifecycle
behavior before naming the resulting bundle verified.

Lifecycle qualification must include completed BUS→primary and primary→BUS
transitions with short gaps, not only isolated streams separated by the old
three-second standby interval. Simultaneously active clients on the shared
physical D5 route are not an accepted use case.
