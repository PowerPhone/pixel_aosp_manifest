# Build the paired Frankel audio-boot candidate images

This is a **build-only, incremental runbook** for the already populated,
matching Frankel AOSP tree. It does not flash, reboot, open audio devices,
change a live phone, erase data or replace a release bundle. The candidate
removes obsolete bootstrap delays and gates normal boot presentation/input
on the actual audio outcome and AudioPolicy/AudioFlinger publication.
Its [dated report](../../../docs/frankel-boot-streamline-20260912.md) is the
authority for hardware qualification; a successful build is not a measured
boot-time or immediate-API pass.

The existing 192 kHz PCM configuration, mixer routes, factory amplifier
settings and custom UI-volume compensation are retained. The candidate also
changes the helpers' bootstrap cache-coherence handling; build both helpers
together with the bootstrap. Its hardware status is recorded in the dated
report. Do not change kernel inputs or regenerate a different audio profile.

## Preconditions

- Start in `pixel_aosp_manifest` on the WSL work volume.
- `work/aosp/out_pixel/frankel/combined-frankel.ninja` already exists for the
  matching populated Frankel product. This is not a clean-tree setup guide.
- The canonical bootstrap and registered source patches represent the intended
  candidate. Preserve unrelated user changes; do not reset a dirty repository
  to make a patch apply, or overwrite independently edited generated sources.
- No other Ninja/build process is active when these commands are executed.
- Existing build dependencies from the repository README are installed,
  including Python 3 and `python-is-python3`. Java, Clang, Ninja and policy
  tools come from the populated AOSP tree. SELinux compiler, context and
  neverallow checks are build requirements, not audio simulations or mock
  hardware tests; retain them.

## 1. Fresh candidate directory and recoverable inputs

Choose an unused run suffix and keep the same shell for the following blocks.
The previous `powerphone-playback192-ui6db-20260912` bundle is read only here.

```bash
set -euo pipefail
boot_project_root=$PWD
boot_aosp="$boot_project_root/work/aosp"
boot_product="$boot_aosp/out_pixel/frankel/target/product/frankel"
boot_generated="$boot_aosp/vendor/google_devices/frankel/powerphone-d10-bootstrap"
boot_canonical="$boot_project_root/tools/audio/device/frankel_powerphone_d10_bootstrap"
boot_previous="$boot_project_root/artifacts/frankel/powerphone-playback192-ui6db-20260912"
boot_run="$boot_project_root/work/audio-research/frankel/boot192-build-run-01"

test -f "$boot_aosp/out_pixel/frankel/combined-frankel.ninja"
test -d "$boot_generated"
test -d "$boot_canonical"
test ! -e "$boot_run"
mkdir -p "$boot_run/originals" "$boot_run/images" "$boot_run/logs"

cp -a -- "$boot_generated" "$boot_run/originals/powerphone-d10-bootstrap"
for boot_helper in speaker d10; do
  cp -a -- "$boot_aosp/vendor/google_devices/frankel/powerphone-$boot_helper-patch" \
    "$boot_run/originals/powerphone-$boot_helper-patch"
done
for boot_image in system system_ext vendor; do
  test -s "$boot_previous/$boot_image.img"
  cp -p --reflink=auto -- "$boot_previous/$boot_image.img" \
    "$boot_run/originals/$boot_image.img"
done

cp -a -- "$boot_canonical/." "$boot_generated/"
for boot_helper in speaker d10; do
  cp -a -- "$boot_project_root/tools/audio/device/frankel_aoc_${boot_helper}_patch/." \
    "$boot_aosp/vendor/google_devices/frankel/powerphone-$boot_helper-patch/"
done
```

The copies install the canonical native bootstrap, both patch helpers,
vendor service RC, system_ext gate RC and package policy into the generated
packages. They do not invoke the broad vendor sanitizer or alter audio tuning.

## 2. Apply only the two new source patches when needed

This runbook starts from the previously working, already-patched tree. The
current development workspace already contains these two edits; it does not
need them applied again. For another matching prior tree, the new entries are:

- `patches/frameworks-base/0007-powerphone-audio-boot-display-gate.patch`.
- `patches/system-sepolicy/0002-powerphone-audio-boot-display-gate.patch`.

They are registered in `scripts/apply-source-patches.sh` for ordered future
source integration, but this incremental run does **not** invoke that global
workflow or change its hash handling. Use direct application over the matching
existing stacks. The optional reverse applicability check below recognizes an
already-applied edit without hashing files; it is not a mock hardware test.
Unknown or partially modified hunks cause ordinary `git apply` to stop rather
than resetting or discarding user changes.

```bash
boot_apply_new_patch() {
  local boot_repository=$1 boot_patch=$2
  if git -C "$boot_repository" apply --reverse --check "$boot_patch" \
      >/dev/null 2>&1; then
    printf 'Already applied: %s\n' "$boot_patch"
  else
    git -C "$boot_repository" apply "$boot_patch"
  fi
}

boot_apply_new_patch "$boot_aosp/frameworks/base" \
  "$boot_project_root/patches/frameworks-base/0007-powerphone-audio-boot-display-gate.patch"
boot_apply_new_patch "$boot_aosp/system/sepolicy" \
  "$boot_project_root/patches/system-sepolicy/0002-powerphone-audio-boot-display-gate.patch"
```

Clean-tree reconstruction of every earlier patch is outside this bounded
incremental run. None of the commands in this document were executed merely
by writing it.

The WindowManager gate reads the system-owned, enum-typed
`sys.powerphone.audio_boot` property. Its declaration, property context and
system_server read permission must be installed together with the framework
change; a vendor-internal property is not a substitute across the platform
policy boundary.

## 3. Build installed prerequisites, then all three images

`OUT_DIR` must be exported explicitly. The native target also requires the
system_ext gate package; the installed RC targets below make their packaging
prerequisites explicit. `services` is the installable merged framework JAR,
not just a compile-only intermediate. `selinux_policy` builds the matching
platform and non-system policy artifacts and their normal install metadata.

Every direct Ninja invocation must include `-d keepdepfile -d keeprsp`, as
the normal Soong UI does. Without `keepdepfile`, Ninja can delete protobuf
`.d` files that this graph also declares as outputs, causing the next
invocation to rebuild host `aconfig` and cascade into thousands of framework
Java dependencies. These flags preserve dependency and response files; they
do not skip required compilation or policy checks.

```bash
(
  cd "$boot_aosp"
  export OUT_DIR=out_pixel/frankel
  prebuilts/build-tools/linux-x86/bin/ninja \
    -d keepdepfile -d keeprsp \
    -f out_pixel/frankel/combined-frankel.ninja \
    frankel_powerphone_d10_bootstrap \
    frankel_aoc_speaker_patch frankel_aoc_d10_patch \
    services \
    selinux_policy \
    out_pixel/frankel/target/product/frankel/vendor/etc/init/frankel_powerphone_d10_bootstrap.rc \
    out_pixel/frankel/target/product/frankel/system_ext/etc/init/frankel_powerphone_audioserver_gate.rc

  prebuilts/build-tools/linux-x86/bin/ninja \
    -d keepdepfile -d keeprsp \
    -f out_pixel/frankel/combined-frankel.ninja \
    systemimage-nodeps systemextimage-nodeps vendorimage-nodeps
) 2>&1 | tee "$boot_run/logs/build.log"

for boot_image in system system_ext vendor; do
  test -s "$boot_product/$boot_image.img"
  cp -p --reflink=auto -- "$boot_product/$boot_image.img" \
    "$boot_run/images/$boot_image.img"
done
```

The exact target is **`systemextimage-nodeps`**, producing `system_ext.img`;
`system_extimage-nodeps` is not the target. Nodeps packaging is appropriate
only after all selected installed prerequisites finish successfully. No
separate file-hashing, attestation, simulation or mock-test step is added.

## 4. Handoff boundary: a matched three-image set

The staged set must be qualified together:

| Image | Required new content |
| --- | --- |
| `system.img` | WindowManager in `services.jar`, platform property contexts and policy |
| `system_ext.img` | Platform-init bootstrap/display bridge and its matching installed policy |
| `vendor.img` | Native bootstrap, vendor service RC/package policy and matching precompiled policy |

Do **not** deploy only vendor, only the RC, or only the framework JAR. An old
platform property context can reject the new enum, an old WMS cannot enforce
the gate, and an old RC/native package does not implement the intended
startup sequence. Do not reuse a stale precompiled policy with the new
platform type. Retain all other images from the preceding complete bundle,
especially its already-qualified RT `vendor_kernel_boot.img`.

These commands deliberately stop before device writes or release promotion.
Hardware qualification must observe a real boot, current readiness and
Binder publication, then exercise immediate API playback/capture and UI
behavior. Missing opt-in property leaves other targets unchanged; explicit
failure, safe/recovery/boot-message paths and the 180-second presentation
deadline fail open without certifying audio. A normal successful gate does
not wait for `sys.boot_completed`, which follows boot-animation completion.
