#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"
# shellcheck source=lib/frankel-powerphone-build-closure.sh
source "$script_dir/lib/frankel-powerphone-build-closure.sh"

usage() {
  printf 'usage: %s invalidate|create|verify\n' "$0" >&2
  exit 2
}
[[ $# -eq 1 ]] || usage
action=$1
case "$action" in
  invalidate|create|verify) ;;
  *) usage ;;
esac

require_command awk cmp find grep realpath sha256sum sort stat unzip
source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
out_dir=${DEVICE_OUT_DIR:-"$source_dir/out_pixel/$DEVICE_CODENAME"}
out_dir=$(realpath -m -- "$out_dir")
assert_inside_work "$source_dir"
assert_inside_work "$out_dir"
case "$out_dir" in
  "$source_dir"/*) ;;
  *) die "DEVICE_OUT_DIR must remain inside the AOSP source tree" ;;
esac
require_target_scoped_output "$source_dir" "$out_dir"

marker="$out_dir/build-completion-$DEVICE_CODENAME.attestation"
if [[ "$action" == invalidate ]]; then
  if [[ -e "$marker" || -L "$marker" ]]; then
    [[ -f "$marker" && ! -L "$marker" ]] || \
      die "unsafe build-completion marker: $marker"
    rm -f -- "$marker"
  fi
  note "invalidated $DEVICE_CODENAME build-completion marker"
  exit 0
fi

product_out="$out_dir/target/product/$DEVICE_CODENAME"
[[ -d "$product_out" && ! -L "$product_out" ]] || \
  die "device product output is missing or unsafe: $product_out"
AOSP_SOURCE_DIR="$source_dir" "$script_dir/attest-generated-vendor.sh" verify

if [[ -n "${DEVICE_TARGET_FILES:-}" ]]; then
  [[ -f "$DEVICE_TARGET_FILES" && ! -L "$DEVICE_TARGET_FILES" ]] || \
    die "DEVICE_TARGET_FILES is not a safe regular file"
  target_files=$(realpath -e -- "$DEVICE_TARGET_FILES")
  case "$target_files" in
    "$out_dir"/*) ;;
    *) die "DEVICE_TARGET_FILES must be inside the selected output tree" ;;
  esac
  [[ -f "$target_files" && ! -L "$target_files" ]] || \
    die "DEVICE_TARGET_FILES is not a safe regular file"
else
  mapfile -d '' -t target_files_candidates < <(
    find "$product_out/obj/PACKAGING/target_files_intermediates" \
      -maxdepth 1 -type f \
      -name "$DEVICE_CODENAME-target_files.zip" -print0 2>/dev/null | \
      sort -z
  )
  (( ${#target_files_candidates[@]} == 1 )) || die \
    "expected exactly one target-files archive; found ${#target_files_candidates[@]}"
  target_files=${target_files_candidates[0]}
fi
unzip -tqq "$target_files"

build_prop="$product_out/system/build.prop"
[[ -f "$build_prop" && ! -L "$build_prop" ]] || \
  die "device build properties are missing or unsafe: $build_prop"
product_build_prop="$product_out/product/etc/build.prop"
vendor_build_prop="$product_out/vendor/build.prop"
for identity_prop in "$product_build_prop" "$vendor_build_prop"; do
  [[ -f "$identity_prop" && ! -L "$identity_prop" ]] || \
    die "device identity properties are missing or unsafe: $identity_prop"
done
grep -Fxq "ro.build.id=$STOCK_BUILD_ID" "$build_prop" || \
  die "device output does not use the target stock build ID"
grep -Fxq 'ro.build.type=userdebug' "$build_prop" || \
  die "device output is not userdebug"
[[ $(grep -Fxc "ro.build.version.security_patch=$AOSP_SECURITY_PATCH" \
      "$build_prop" || true) -eq 1 ]] || \
  die "device output does not use the pinned AOSP framework security patch"
grep -Fxq "ro.product.product.device=$DEVICE_CODENAME" \
  "$product_build_prop" || \
  die "product output does not identify as $DEVICE_CODENAME"
grep -Fxq "ro.product.vendor.device=$DEVICE_CODENAME" \
  "$vendor_build_prop" || \
  die "vendor output does not identify as $DEVICE_CODENAME"

if [[ "$DEVICE_CODENAME" == frankel ]]; then
  # The generated-vendor attestation binds the selected stock or research AoC
  # module input. Prove that the build installed those exact bytes and that the
  # selected target-files archive carries the same ramdisk entry; hashing only
  # the input tree and final images would otherwise leave a stale-output gap.
  powerphone_aoc_alsa_192k=${POWERPHONE_AOC_ALSA_192K:-false}
  case "$powerphone_aoc_alsa_192k" in
    true) frankel_aoc_module_state=patched ;;
    false) frankel_aoc_module_state=stock ;;
    *) die "POWERPHONE_AOC_ALSA_192K must be true or false" ;;
  esac
  powerphone_d0_progress_mode=${POWERPHONE_D0_PROGRESS_MODE:-mailbox}
  case "$powerphone_d0_progress_mode" in
    mailbox|pure-timer|one-period-lag) ;;
    *) die "POWERPHONE_D0_PROGRESS_MODE must be mailbox, pure-timer, or one-period-lag" ;;
  esac
  powerphone_d5_timer=${POWERPHONE_D5_TIMER:-false}
  case "$powerphone_d5_timer" in
    true|false) ;;
    *) die "POWERPHONE_D5_TIMER must be true or false" ;;
  esac
  if [[ -n ${POWERPHONE_PRIMARY_HAL_192K:-} ]]; then
    powerphone_primary_hal_192k=$POWERPHONE_PRIMARY_HAL_192K
  elif [[ "$powerphone_aoc_alsa_192k" == true ]]; then
    powerphone_primary_hal_192k=true
  else
    powerphone_primary_hal_192k=false
  fi
  case "$powerphone_primary_hal_192k" in
    true) frankel_primary_hal_state=patched ;;
    rate-only) frankel_primary_hal_state=rate-only ;;
    false) frankel_primary_hal_state=stock ;;
    *) die "POWERPHONE_PRIMARY_HAL_192K must be true, rate-only, or false" ;;
  esac
  powerphone_signed_aoc_firmware_profile=${POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE:-stock}
  case "$powerphone_signed_aoc_firmware_profile" in
    stock|source0-4s32-allocator-fallback) ;;
    *) die "POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE must be stock or source0-4s32-allocator-fallback" ;;
  esac
  if [[ "$powerphone_aoc_alsa_192k" == false && \
        ( "$powerphone_d0_progress_mode" != mailbox || \
          "$powerphone_signed_aoc_firmware_profile" != stock || \
          "$powerphone_d5_timer" == true || \
          "$powerphone_primary_hal_192k" != false ) ]]; then
    die "non-default AoC selections require POWERPHONE_AOC_ALSA_192K=true"
  fi
  [[ "$powerphone_d5_timer" != true || \
     "$powerphone_d0_progress_mode" == one-period-lag ]] || \
    die "POWERPHONE_D5_TIMER=true requires one-period-lag"
  powerphone_cs35l43_192k=${POWERPHONE_CS35L43_192K:-false}
  case "$powerphone_cs35l43_192k" in
    true) frankel_cs35l43_state=patched ;;
    false) frankel_cs35l43_state=stock ;;
    *) die "POWERPHONE_CS35L43_192K must be true or false" ;;
  esac
  frankel_aoc_input="$source_dir/vendor/google_devices/frankel/stock-kernel/aoc_alsa_dev_util.ko"
  frankel_aoc_installed="$product_out/vendor_kernel_ramdisk/lib/modules/aoc_alsa_dev_util.ko"
  frankel_aoc_target_entry='VENDOR_KERNEL_BOOT/RAMDISK/lib/modules/aoc_alsa_dev_util.ko'
  frankel_aoc_patcher="$project_root/tools/audio/patch_frankel_aoc_192k.py"
  frankel_d0_progress_patcher="$project_root/tools/audio/patch_frankel_aoc_d0_progress_mode.py"
  frankel_ep6_patcher="$project_root/tools/audio/patch_frankel_aoc_ep6_speaker_192k.py"
  frankel_d5_timer_patcher="$project_root/tools/audio/patch_frankel_aoc_pcm_d5_timer_mode.py"
  for frankel_aoc_path in "$frankel_aoc_input" "$frankel_aoc_installed" \
      "$frankel_aoc_patcher" "$frankel_d0_progress_patcher" \
      "$frankel_ep6_patcher" "$frankel_d5_timer_patcher"; do
    [[ -f "$frankel_aoc_path" && ! -L "$frankel_aoc_path" && \
       -s "$frankel_aoc_path" ]] || \
      die "Frankel AoC ALSA module is missing, empty, or unsafe: $frankel_aoc_path"
  done
  [[ -x "$frankel_aoc_patcher" && -x "$frankel_d0_progress_patcher" && \
     -x "$frankel_ep6_patcher" && -x "$frankel_d5_timer_patcher" ]] || \
    die "Frankel AoC patch helpers must be executable"
  verify_sha256 \
    1c96487c0cfa3505f881824adbb084126bbf30eaafc7e8346d8818f2625b5e1d \
    "$frankel_aoc_patcher"
  verify_sha256 \
    3deb57c943d0015b410aac8fdf2611b8569f0af378b0e1cb22e059f82115198a \
    "$frankel_d0_progress_patcher"
  verify_sha256 \
    c5bf1fc07decf7f9c9c94d55b7f12c80253eafb18a6e9b884efc9337b670020d \
    "$frankel_ep6_patcher"
  verify_sha256 \
    1ed1d9507155587b554ca3031a6882e5f4bcb9beaf1923dec93ea0496b32a987 \
    "$frankel_d5_timer_patcher"
  if [[ "$frankel_aoc_module_state" == stock ]]; then
    "$frankel_aoc_patcher" --check stock "$frankel_aoc_input"
  else
    "$frankel_d0_progress_patcher" \
      --check "$powerphone_d0_progress_mode" "$frankel_aoc_input"
  fi
  "$frankel_ep6_patcher" --check "$frankel_aoc_module_state" \
    "$frankel_aoc_input"
  if [[ "$powerphone_d5_timer" == true ]]; then
    "$frankel_d5_timer_patcher" --check enabled "$frankel_aoc_input"
  elif [[ "$powerphone_d0_progress_mode" == one-period-lag ]]; then
    "$frankel_d5_timer_patcher" --check disabled "$frankel_aoc_input"
  fi
  cmp -s -- "$frankel_aoc_input" "$frankel_aoc_installed" || \
    die "installed Frankel AoC ALSA module differs from the selected generated input"
  [[ $(unzip -Z1 "$target_files" | \
      grep -Fxc -- "$frankel_aoc_target_entry" || true) -eq 1 ]] || \
    die "Frankel target-files must contain exactly one selected AoC ALSA module"
  if ! unzip -p "$target_files" "$frankel_aoc_target_entry" | \
      cmp -s -- "$frankel_aoc_input" -; then
    die "Frankel target-files AoC ALSA module differs from the selected generated input"
  fi
  frankel_aoc_sha256=$(sha256sum -- "$frankel_aoc_input")
  frankel_aoc_sha256=${frankel_aoc_sha256%% *}
  frankel_aoc_patcher_sha256=$(sha256sum -- "$frankel_aoc_patcher")
  frankel_aoc_patcher_sha256=${frankel_aoc_patcher_sha256%% *}
  frankel_d0_progress_patcher_sha256=$(sha256sum -- \
    "$frankel_d0_progress_patcher")
  frankel_d0_progress_patcher_sha256=${frankel_d0_progress_patcher_sha256%% *}
  frankel_ep6_patcher_sha256=$(sha256sum -- "$frankel_ep6_patcher")
  frankel_ep6_patcher_sha256=${frankel_ep6_patcher_sha256%% *}
  frankel_d5_timer_patcher_sha256=$(sha256sum -- "$frankel_d5_timer_patcher")
  frankel_d5_timer_patcher_sha256=${frankel_d5_timer_patcher_sha256%% *}

  frankel_primary_hal_input="$source_dir/vendor/google_devices/frankel/proprietary/vendor/bin/hw/android.hardware.audio.service-aidl.aoc"
  frankel_primary_hal_installed="$product_out/vendor/bin/hw/android.hardware.audio.service-aidl.aoc"
  frankel_primary_hal_target='VENDOR/bin/hw/android.hardware.audio.service-aidl.aoc'
  frankel_primary_hal_patcher="$project_root/tools/audio/patch_frankel_primary_hal_192k.py"
  for frankel_primary_path in "$frankel_primary_hal_input" \
      "$frankel_primary_hal_installed" "$frankel_primary_hal_patcher"; do
    [[ -f "$frankel_primary_path" && ! -L "$frankel_primary_path" && \
       -s "$frankel_primary_path" ]] || \
      die "Frankel primary HAL input is missing, empty, or unsafe: $frankel_primary_path"
  done
  verify_sha256 \
    6390132493ddf7894f1e5621b5f5e6c47010f6b7005cbefd7983070258a5f04f \
    "$frankel_primary_hal_patcher"
  "$frankel_primary_hal_patcher" --check "$frankel_primary_hal_state" \
    "$frankel_primary_hal_input"
  cmp -s -- "$frankel_primary_hal_input" "$frankel_primary_hal_installed" || \
    die "installed Frankel primary HAL differs from generated input"
  if ! unzip -p "$target_files" "$frankel_primary_hal_target" | \
      cmp -s -- "$frankel_primary_hal_input" -; then
    die "Frankel target-files primary HAL differs from generated input"
  fi
  frankel_primary_hal_patcher_sha256=$(sha256sum -- "$frankel_primary_hal_patcher")
  frankel_primary_hal_patcher_sha256=${frankel_primary_hal_patcher_sha256%% *}

  frankel_aoc_core_input="$source_dir/vendor/google_devices/frankel/stock-kernel/aoc_core.ko"
  frankel_aoc_core_installed="$product_out/vendor_kernel_ramdisk/lib/modules/aoc_core.ko"
  frankel_aoc_core_target_entry='VENDOR_KERNEL_BOOT/RAMDISK/lib/modules/aoc_core.ko'
  frankel_aoc_core_patcher="$project_root/tools/audio/patch_frankel_aoc_core_zero_wp_reset.py"
  for frankel_aoc_core_path in "$frankel_aoc_core_input" \
      "$frankel_aoc_core_installed" "$frankel_aoc_core_patcher"; do
    [[ -f "$frankel_aoc_core_path" && ! -L "$frankel_aoc_core_path" && \
       -s "$frankel_aoc_core_path" ]] || \
      die "Frankel AoC core module is missing, empty, or unsafe: $frankel_aoc_core_path"
  done
  "$frankel_aoc_core_patcher" --check "$frankel_aoc_module_state" \
    "$frankel_aoc_core_input"
  cmp -s -- "$frankel_aoc_core_input" "$frankel_aoc_core_installed" || \
    die "installed Frankel AoC core differs from selected generated input"
  [[ $(unzip -Z1 "$target_files" | \
      grep -Fxc -- "$frankel_aoc_core_target_entry" || true) -eq 1 ]] || \
    die "Frankel target-files must contain exactly one selected AoC core module"
  if ! unzip -p "$target_files" "$frankel_aoc_core_target_entry" | \
      cmp -s -- "$frankel_aoc_core_input" -; then
    die "Frankel target-files AoC core differs from selected generated input"
  fi
  frankel_aoc_core_sha256=$(sha256sum -- "$frankel_aoc_core_input")
  frankel_aoc_core_sha256=${frankel_aoc_core_sha256%% *}

  frankel_aoc_firmware_input="$source_dir/vendor/google_devices/frankel/proprietary/vendor/firmware/aoc.bin"
  frankel_aoc_firmware_installed="$product_out/vendor/firmware/aoc.bin"
  frankel_aoc_firmware_target_entry='VENDOR/firmware/aoc.bin'
  frankel_aoc_firmware_patcher="$project_root/tools/audio/patch_frankel_aoc_firmware_speaker_192k.py"
  for frankel_aoc_firmware_path in \
      "$frankel_aoc_firmware_input" \
      "$frankel_aoc_firmware_installed" \
      "$frankel_aoc_firmware_patcher"; do
    [[ -f "$frankel_aoc_firmware_path" && \
       ! -L "$frankel_aoc_firmware_path" && \
       -s "$frankel_aoc_firmware_path" ]] || \
      die "Frankel signed AoC firmware input is missing, empty, or unsafe: $frankel_aoc_firmware_path"
  done
  [[ -x "$frankel_aoc_firmware_patcher" ]] || \
    die "Frankel signed AoC firmware patch helper must be executable"
  verify_sha256 \
    d5e8f5edc1ffe2901efbc807d434b308794c7588e57b47111118be85445bf0c2 \
    "$frankel_aoc_firmware_patcher"
  if [[ "$powerphone_signed_aoc_firmware_profile" == stock ]]; then
    "$frankel_aoc_firmware_patcher" \
      --profile source0-4s32-allocator-fallback --check stock \
      "$frankel_aoc_firmware_input"
  else
    "$frankel_aoc_firmware_patcher" \
      --profile "$powerphone_signed_aoc_firmware_profile" --check patched \
      "$frankel_aoc_firmware_input"
  fi
  cmp -s -- "$frankel_aoc_firmware_input" \
    "$frankel_aoc_firmware_installed" || \
    die "installed Frankel signed AoC firmware differs from selected generated input"
  [[ $(unzip -Z1 "$target_files" | \
      grep -Fxc -- "$frankel_aoc_firmware_target_entry" || true) -eq 1 ]] || \
    die "Frankel target-files must contain exactly one selected signed AoC firmware"
  if ! unzip -p "$target_files" "$frankel_aoc_firmware_target_entry" | \
      cmp -s -- "$frankel_aoc_firmware_input" -; then
    die "Frankel target-files signed AoC firmware differs from selected generated input"
  fi
  frankel_aoc_firmware_sha256=$(sha256sum -- "$frankel_aoc_firmware_input")
  frankel_aoc_firmware_sha256=${frankel_aoc_firmware_sha256%% *}
  frankel_aoc_firmware_patcher_sha256=$(sha256sum -- \
    "$frankel_aoc_firmware_patcher")
  frankel_aoc_firmware_patcher_sha256=${frankel_aoc_firmware_patcher_sha256%% *}

  frankel_cs35l43_input="$source_dir/vendor/google_devices/frankel/stock-kernel/snd-soc-cs35l43.ko"
  frankel_cs35l43_installed="$product_out/vendor_kernel_ramdisk/lib/modules/snd-soc-cs35l43.ko"
  frankel_cs35l43_target_entry='VENDOR_KERNEL_BOOT/RAMDISK/lib/modules/snd-soc-cs35l43.ko'
  frankel_cs35l43_patcher="$project_root/tools/audio/patch_frankel_cs35l43_global_fs96.py"
  for frankel_cs35l43_path in "$frankel_cs35l43_input" \
      "$frankel_cs35l43_installed" "$frankel_cs35l43_patcher"; do
    [[ -f "$frankel_cs35l43_path" && ! -L "$frankel_cs35l43_path" && \
       -s "$frankel_cs35l43_path" ]] || \
      die "Frankel CS35L43 input is missing, empty, or unsafe: $frankel_cs35l43_path"
  done
  "$frankel_cs35l43_patcher" --check "$frankel_cs35l43_state" \
    "$frankel_cs35l43_input"
  cmp -s -- "$frankel_cs35l43_input" "$frankel_cs35l43_installed" || \
    die "installed Frankel CS35L43 module differs from selected generated input"
  [[ $(unzip -Z1 "$target_files" | \
      grep -Fxc -- "$frankel_cs35l43_target_entry" || true) -eq 1 ]] || \
    die "Frankel target-files must contain exactly one selected CS35L43 module"
  if ! unzip -p "$target_files" "$frankel_cs35l43_target_entry" | \
      cmp -s -- "$frankel_cs35l43_input" -; then
    die "Frankel target-files CS35L43 module differs from selected generated input"
  fi

  powerphone_audio_sidecar=${POWERPHONE_AUDIO_SIDECAR:-false}
  frankel_powerphone_validate_build_closure \
    "$powerphone_audio_sidecar" \
    "$powerphone_cs35l43_192k" \
    "$source_dir" \
    "$source_dir/vendor/google_devices/frankel" \
    "$product_out" \
    "$target_files" || \
    die 'Frankel PowerPhone build closure verification failed'

  # The Soong producers are Frankel-prefixed, but explicit filenames preserve
  # the eight original vendor permission paths. Bind every installed file to
  # target-files so target scoping cannot change the runtime feature payload.
  frankel_feature_filenames=(
    android.hardware.audio.pro.prebuilt.xml
    android.hardware.device_unique_attestation.prebuilt.xml
    android.hardware.opengles.aep.prebuilt.xml
    android.hardware.touchscreen.multitouch.jazzhand.prebuilt.xml
    android.hardware.wifi.aware.prebuilt.xml
    android.hardware.wifi.rtt.prebuilt.xml
    android.software.ipsec_tunnel_migration.prebuilt.xml
    android.software.midi.prebuilt.xml
  )
  frankel_feature_names=(
    android.hardware.audio.pro
    android.hardware.device_unique_attestation
    android.hardware.opengles.aep
    android.hardware.touchscreen.multitouch.jazzhand
    android.hardware.wifi.aware
    android.hardware.wifi.rtt
    android.software.ipsec_tunnel_migration
    android.software.midi
  )
  for index in "${!frankel_feature_filenames[@]}"; do
    filename=${frankel_feature_filenames[$index]}
    feature=${frankel_feature_names[$index]}
    installed_feature="$product_out/vendor/etc/permissions/$filename"
    [[ -f "$installed_feature" && ! -L "$installed_feature" ]] || \
      die "Frankel feature declaration is missing or unsafe: $installed_feature"
    [[ $(grep -Fxc "    <feature name=\"$feature\" />" \
          "$installed_feature" || true) -eq 1 ]] || \
      die "Frankel feature declaration is malformed: $feature"
    if ! unzip -p "$target_files" "VENDOR/etc/permissions/$filename" | \
        cmp -s -- "$installed_feature" -; then
      die "Frankel feature declaration differs from target-files: $feature"
    fi
  done

  frankel_compatibility_paths=(
    system_ext/etc/gmscompat/gservices-flags/flags.txt
    system_ext/priv-app/EuiccSupportPixel-P23/EuiccSupportPixel-P23.apk
    system_ext/priv-app/PixelAospGservicesFlagsProvider/PixelAospGservicesFlagsProvider.apk
  )
  for relative_path in "${frankel_compatibility_paths[@]}"; do
    installed_path="$product_out/$relative_path"
    [[ -f "$installed_path" && ! -L "$installed_path" && -s "$installed_path" ]] || \
      die "Frankel compatibility payload is missing, empty, or unsafe: $installed_path"
    partition=${relative_path%%/*}
    path_inside_partition=${relative_path#*/}
    target_entry="${partition^^}/$path_inside_partition"
    if ! unzip -p "$target_files" "$target_entry" | cmp -s -- "$installed_path" -; then
      die "Frankel compatibility payload differs from target-files: $relative_path"
    fi
  done
  verify_sha256 \
    01153ea2667c6cbb838fe6adad958a9af5432970deb58cd059622c5dc1e755ab \
    "$product_out/system_ext/etc/gmscompat/gservices-flags/flags.txt"
  provider_apk="$product_out/system_ext/priv-app/PixelAospGservicesFlagsProvider/PixelAospGservicesFlagsProvider.apk"
  aapt2="$out_dir/host/linux-x86/bin/aapt2"
  [[ -f "$aapt2" && ! -L "$aapt2" && -x "$aapt2" ]] || \
    die "built aapt2 is missing or unsafe"
  provider_manifest=$(
    "$aapt2" dump xmltree --file AndroidManifest.xml "$provider_apk"
  ) || die "unable to inspect the Frankel Gservices provider manifest"
  for required_manifest_value in \
    'package="org.pixelaosp.gservicesflags"' \
    '="com.google.android.gsf.gservices"' \
    '="com.google.android.providers.gsf.permission.READ_GSERVICES"'; do
    [[ "$provider_manifest" == *"$required_manifest_value"* ]] || \
      die "Frankel Gservices provider manifest lacks $required_manifest_value"
  done
fi

images=(
  boot.img
  dtbo.img
  init_boot.img
  product.img
  pvmfw.img
  system.img
  system_dlkm.img
  system_ext.img
  vbmeta.img
  vendor.img
  vendor_boot.img
  vendor_dlkm.img
  vendor_kernel_boot.img
)

vendor_attestation="$project_root/work/attestations/$DEVICE_CODENAME-generated-vendor.attestation"
[[ -f "$vendor_attestation" && ! -L "$vendor_attestation" ]] || \
  die "generated-vendor attestation is missing or unsafe"
patch_lock="$project_root/patches/SHA256SUMS"
manifest_lock="$project_root/manifests/resolved.xml"
release_env="$project_root/config/release.env"
target_release_env="$project_root/config/targets/$DEVICE_CODENAME/release.env"
for provenance_input in \
    "$patch_lock" "$manifest_lock" "$release_env" "$target_release_env"; do
  [[ -f "$provenance_input" && ! -L "$provenance_input" ]] || \
    die "build provenance input is missing or unsafe: $provenance_input"
done
release_env_sha256=$(sha256sum -- "$release_env")
release_env_sha256=${release_env_sha256%% *}
target_release_env_sha256=$(sha256sum -- "$target_release_env")
target_release_env_sha256=${target_release_env_sha256%% *}

temporary=$(mktemp "$out_dir/.build-completion-$DEVICE_CODENAME.XXXXXX")
cleanup() {
  [[ -z "${temporary:-}" ]] || rm -f -- "$temporary"
}
trap cleanup EXIT
{
  printf 'format=pixel-aosp-device-build-attestation-v1\n'
  printf 'device=%s\n' "$DEVICE_CODENAME"
  printf 'platform=%s\n' "$DEVICE_PLATFORM"
  printf 'product_target=%s\n' "$DEVICE_PRODUCT_TARGET"
  printf 'variant=userdebug\n'
  printf 'aosp_revision=%s\n' "$AOSP_REVISION"
  printf 'aosp_build_id=%s\n' "$AOSP_BUILD_ID"
  printf 'framework_security_patch=%s\n' "$AOSP_SECURITY_PATCH"
  printf 'device_build_id=%s\n' "$STOCK_BUILD_ID"
  printf 'release_env_sha256=%s\n' "$release_env_sha256"
  printf 'target_release_env_sha256=%s\n' "$target_release_env_sha256"
  printf 'resolved_manifest_sha256=%s\n' "$(sha256sum "$manifest_lock" | awk '{print $1}')"
  printf 'patch_lock_sha256=%s\n' "$(sha256sum "$patch_lock" | awk '{print $1}')"
  printf 'generated_vendor_attestation_sha256=%s\n' \
    "$(sha256sum "$vendor_attestation" | awk '{print $1}')"
  if [[ "$DEVICE_CODENAME" == frankel ]]; then
    printf 'powerphone_aoc_alsa_192k=%s\n' "$powerphone_aoc_alsa_192k"
    printf 'powerphone_aoc_alsa_sha256=%s\n' "$frankel_aoc_sha256"
    printf 'powerphone_aoc_patcher_sha256=%s\n' \
      "$frankel_aoc_patcher_sha256"
    printf 'powerphone_d0_progress_mode=%s\n' \
      "$powerphone_d0_progress_mode"
    printf 'powerphone_d5_timer=%s\n' "$powerphone_d5_timer"
    printf 'powerphone_primary_hal_192k=%s\n' "$powerphone_primary_hal_192k"
    printf 'powerphone_d0_progress_patcher_sha256=%s\n' \
      "$frankel_d0_progress_patcher_sha256"
    printf 'powerphone_ep6_patcher_sha256=%s\n' \
      "$frankel_ep6_patcher_sha256"
    printf 'powerphone_d5_timer_patcher_sha256=%s\n' \
      "$frankel_d5_timer_patcher_sha256"
    printf 'powerphone_primary_hal_patcher_sha256=%s\n' \
      "$frankel_primary_hal_patcher_sha256"
    printf 'powerphone_aoc_core_sha256=%s\n' "$frankel_aoc_core_sha256"
    printf 'powerphone_signed_aoc_firmware_profile=%s\n' \
      "$powerphone_signed_aoc_firmware_profile"
    printf 'powerphone_signed_aoc_firmware_sha256=%s\n' \
      "$frankel_aoc_firmware_sha256"
    printf 'powerphone_signed_aoc_firmware_patcher_sha256=%s\n' \
      "$frankel_aoc_firmware_patcher_sha256"
    printf 'powerphone_cs35l43_192k=%s\n' "$powerphone_cs35l43_192k"
    printf 'powerphone_cs35l43_sha256=%s\n' \
      "$FRANKEL_POWERPHONE_CS35L43_SHA256"
    printf 'powerphone_audio_sidecar=%s\n' "$FRANKEL_POWERPHONE_SELECTION"
    printf 'powerphone_d10_patch_sha256=%s\n' \
      "$FRANKEL_POWERPHONE_D10_PATCH_SHA256"
    printf 'powerphone_speaker_patch_sha256=%s\n' \
      "$FRANKEL_POWERPHONE_SPEAKER_PATCH_SHA256"
    printf 'powerphone_d10_bootstrap_sha256=%s\n' \
      "$FRANKEL_POWERPHONE_D10_BOOTSTRAP_SHA256"
    printf 'powerphone_staged_player_sha256=%s\n' \
      "$FRANKEL_POWERPHONE_STAGED_PLAYER_SHA256"
    printf 'powerphone_audio_hal_sha256=%s\n' \
      "$FRANKEL_POWERPHONE_AUDIO_HAL_SHA256"
  fi
  printf 'target_files_name=%s\n' "${target_files##*/}"
  printf 'target_files_size=%s\n' "$(stat -c '%s' "$target_files")"
  printf 'target_files_sha256=%s\n' "$(sha256sum "$target_files" | awk '{print $1}')"
  for image in "${images[@]}"; do
    path="$product_out/$image"
    [[ -f "$path" && ! -L "$path" && -s "$path" ]] || \
      die "required device image is missing, empty, or unsafe: $path"
    printf 'image_%s_size=%s\n' "${image%.img}" "$(stat -c '%s' "$path")"
    printf 'image_%s_sha256=%s\n' "${image%.img}" \
      "$(sha256sum "$path" | awk '{print $1}')"
  done
} > "$temporary"

case "$action" in
  create)
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$marker"
    temporary=
    note "created $DEVICE_CODENAME build-completion attestation: $marker"
    ;;
  verify)
    [[ -f "$marker" && ! -L "$marker" ]] || \
      die "build-completion attestation is missing or unsafe"
    cmp -s -- "$marker" "$temporary" || \
      die "$DEVICE_CODENAME output no longer matches its build attestation"
    note "verified $DEVICE_CODENAME build output"
    ;;
esac
