#!/usr/bin/env bash
set -euo pipefail

export PIXEL_TARGET=${PIXEL_TARGET:-frankel}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$script_dir/../lib/common.sh"

require_pixel_target frankel "Frankel audio-kernel builder"
require_command bash cmp cp date head mktemp python3 realpath rm sed sha256sum stat

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
out_dir=${DEVICE_OUT_DIR:-"$source_dir/out_pixel/frankel"}
jobs=${BUILD_JOBS:-$(nproc)}
source_dir=$(realpath -m -- "$source_dir")
out_dir=$(realpath -m -- "$out_dir")
assert_inside_work "$source_dir"
assert_inside_work "$out_dir"
require_target_scoped_output "$source_dir" "$out_dir"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "BUILD_JOBS must be a positive integer"

module="$source_dir/vendor/google_devices/frankel/stock-kernel/aoc_alsa_dev_util.ko"
patcher="$project_root/tools/audio/patch_frankel_aoc_192k.py"
d0_progress_patcher="$project_root/tools/audio/patch_frankel_aoc_d0_progress_mode.py"
d0_progress_mode=${POWERPHONE_D0_PROGRESS_MODE:-${AUDIO_D0_PROGRESS_MODE:-mailbox}}
firmware="$source_dir/vendor/google_devices/frankel/proprietary/vendor/firmware/aoc.bin"
firmware_patcher="$project_root/tools/audio/patch_frankel_aoc_firmware_speaker_192k.py"
case ${AUDIO_PATCH_SIGNED_AOC_FIRMWARE:-false} in
  true|false) ;;
  *) die "AUDIO_PATCH_SIGNED_AOC_FIRMWARE must be true or false" ;;
esac
if [[ -n ${POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE+x} ]]; then
  firmware_profile=$POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE
elif [[ ${AUDIO_PATCH_SIGNED_AOC_FIRMWARE:-false} == true ]]; then
  # Backward-compatible spelling for retained experiment logs. New runs use
  # the explicit profile variable recorded by every full-build layer.
  firmware_profile=source0-4s32-allocator-fallback
else
  firmware_profile=stock
fi
if [[ -n ${POWERPHONE_D0_PROGRESS_MODE+x} && \
      -n ${AUDIO_D0_PROGRESS_MODE+x} && \
      "$POWERPHONE_D0_PROGRESS_MODE" != "$AUDIO_D0_PROGRESS_MODE" ]]; then
  die "POWERPHONE_D0_PROGRESS_MODE conflicts with AUDIO_D0_PROGRESS_MODE"
fi
if [[ -n ${POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE+x} && \
      -n ${AUDIO_PATCH_SIGNED_AOC_FIRMWARE+x} ]]; then
  case "$AUDIO_PATCH_SIGNED_AOC_FIRMWARE:$firmware_profile" in
    false:stock|true:source0-4s32-allocator-fallback) ;;
    *) die "POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE conflicts with AUDIO_PATCH_SIGNED_AOC_FIRMWARE" ;;
  esac
fi
case "$firmware_profile" in
  stock) patch_signed_firmware=false ;;
  source0-4s32-allocator-fallback) patch_signed_firmware=true ;;
  *) die "POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE must be stock or source0-4s32-allocator-fallback" ;;
esac
product_out="$out_dir/target/product/frankel"
case "$d0_progress_mode" in
  mailbox|pure-timer|one-period-lag) ;;
  *) die "POWERPHONE_D0_PROGRESS_MODE must be mailbox, pure-timer, or one-period-lag" ;;
esac
if [[ -n ${AUDIO_KERNEL_RESULT_DIR:-} ]]; then
  result_dir=$AUDIO_KERNEL_RESULT_DIR
elif [[ "$patch_signed_firmware" == true && "$d0_progress_mode" != mailbox ]]; then
  result_dir="$project_root/work/audio-research/frankel/build-output-signed-aoc-$d0_progress_mode"
elif [[ "$patch_signed_firmware" == true ]]; then
  result_dir="$project_root/work/audio-research/frankel/build-output-signed-aoc-experimental"
elif [[ "$d0_progress_mode" != mailbox ]]; then
  result_dir="$project_root/work/audio-research/frankel/build-output-$d0_progress_mode"
else
  result_dir="$project_root/work/audio-research/frankel/build-output"
fi
result_dir=$(realpath -m -- "$result_dir")
vbmeta_anchor=${AUDIO_VBMETA_ANCHOR:-"$project_root/work/audio-research/frankel/non-gsa-trial/vbmeta.current-bootable.img"}
avb_key=${AUDIO_AVB_KEY:-"$source_dir/external/avb/test/data/testkey_rsa4096.pem"}
avbtool="$out_dir/host/linux-x86/bin/avbtool"
assert_inside_work "$result_dir"
require_file "$module"
require_file "$patcher"
require_file "$d0_progress_patcher"
require_file "$vbmeta_anchor"
require_file "$avb_key"
[[ -x "$patcher" && ! -L "$patcher" && \
   -x "$d0_progress_patcher" && ! -L "$d0_progress_patcher" ]] || \
  die "audio module patch helpers must be safe executable files"
verify_sha256 \
  1c96487c0cfa3505f881824adbb084126bbf30eaafc7e8346d8818f2625b5e1d \
  "$patcher"
verify_sha256 \
  fad4debd25f63466511109da5dce014cc6ef9be35b15e4812ce589e578f0facd \
  "$d0_progress_patcher"
if [[ "$patch_signed_firmware" == true ]]; then
  require_file "$firmware"
  require_file "$firmware_patcher"
  [[ -x "$firmware_patcher" && ! -L "$firmware_patcher" ]] || \
    die "signed AoC firmware patch helper must be a safe executable file"
  verify_sha256 \
    d5e8f5edc1ffe2901efbc807d434b308794c7588e57b47111118be85445bf0c2 \
    "$firmware_patcher"
fi

temporary_dir=$(mktemp -d "$project_root/work/audio-research/frankel/.kernel-build.XXXXXX")
backup="$temporary_dir/aoc_alsa_dev_util.ko.input"
cp -a -- "$module" "$backup"
module_input_state=
if "$patcher" --check stock "$module" >/dev/null 2>&1; then
  module_input_state=stock
else
  for selectable_progress_mode in mailbox pure-timer one-period-lag; do
    if "$d0_progress_patcher" --check "$selectable_progress_mode" \
        "$module" >/dev/null 2>&1; then
      module_input_state=$selectable_progress_mode
      break
    fi
  done
fi
[[ -n "$module_input_state" ]] || \
  die "AoC ALSA input is not stock or an exact selectable 192 kHz state"
firmware_backup="$temporary_dir/aoc.bin.stock"
restore_inputs() {
  if [[ -f "$backup" ]]; then
    cp -f -- "$backup" "$module"
    cmp -s -- "$backup" "$module" || \
      die "failed to restore exact AoC ALSA builder input"
  fi
  if [[ -f "$firmware_backup" ]]; then
    cp -f -- "$firmware_backup" "$firmware"
    "$firmware_patcher" --profile "$firmware_profile" \
      --check stock "$firmware" >/dev/null
  fi
  rm -rf -- "$temporary_dir"
}
trap restore_inputs EXIT INT TERM

if [[ "$module_input_state" == stock ]]; then
  "$patcher" --in-place "$module"
  "$d0_progress_patcher" --check mailbox "$module"
fi
if [[ "$module_input_state" != "$d0_progress_mode" ]]; then
  "$d0_progress_patcher" --set-state "$d0_progress_mode" --in-place "$module"
fi
"$d0_progress_patcher" --check "$d0_progress_mode" "$module"
if [[ "$patch_signed_firmware" == true ]]; then
  "$firmware_patcher" --profile "$firmware_profile" --check stock "$firmware"
  cp -a -- "$firmware" "$firmware_backup"
  "$firmware_patcher" --profile "$firmware_profile" \
    "$firmware" "$temporary_dir/aoc.bin.patched"
  "$firmware_patcher" --profile "$firmware_profile" \
    --check patched "$temporary_dir/aoc.bin.patched"
  cp -f -- "$temporary_dir/aoc.bin.patched" "$firmware"
  "$firmware_patcher" --profile "$firmware_profile" \
    --check patched "$firmware"
fi

export BUILD_NUMBER="$AOSP_BUILD_NUMBER"
export BUILD_USERNAME="$AOSP_BUILD_USERNAME"
export BUILD_HOSTNAME="$AOSP_BUILD_HOSTNAME"
export BUILD_DATETIME="$AOSP_BUILD_DATETIME"
export TZ="$AOSP_BUILD_TIMEZONE"
export LC_ALL="$AOSP_BUILD_LOCALE"
export LANG="$AOSP_BUILD_LOCALE"
export USE_STOCK_KERNEL=true
export OUT_DIR
OUT_DIR=$(realpath --relative-to="$source_dir" "$out_dir")

cd "$source_dir"
# shellcheck disable=SC1091
source build/envsetup.sh
# shellcheck disable=SC1090
source vendor/google_devices/frankel/cmds-for-envsetup.sh
lunch "$DEVICE_PRODUCT_TARGET"
build_targets=(vendorkernelbootimage)
if [[ "$patch_signed_firmware" == true ]]; then
  build_targets+=(vendorimage)
fi
m -j"$jobs" "${build_targets[@]}"

installed_module="$product_out/vendor_kernel_ramdisk/lib/modules/aoc_alsa_dev_util.ko"
require_file "$installed_module"
"$d0_progress_patcher" --check "$d0_progress_mode" "$installed_module"
require_file "$product_out/vendor_kernel_boot.img"
require_file "$avbtool"

mkdir -p "$result_dir"
cp -f -- "$product_out/vendor_kernel_boot.img" "$result_dir/vendor_kernel_boot.img"
if [[ "$patch_signed_firmware" == true ]]; then
  installed_firmware="$product_out/vendor/firmware/aoc.bin"
  require_file "$installed_firmware"
  "$firmware_patcher" --profile "$firmware_profile" \
    --check patched "$installed_firmware"
  require_file "$product_out/vendor.img"
  cp -f -- "$product_out/vendor.img" "$result_dir/vendor.img"
fi

# The full-tree vbmeta image may describe partitions regenerated after a
# partial/interrupted build and therefore must not be paired with the system
# currently installed on the phone.  Preserve every descriptor from the known
# bootable root vbmeta, then let avbtool replace only the duplicated
# vendor_kernel_boot descriptor with the freshly built image's digest.
vbmeta_info=$("$avbtool" info_image --image "$vbmeta_anchor")
vbmeta_algorithm=$(sed -n 's/^Algorithm:[[:space:]]*//p' <<<"$vbmeta_info")
vbmeta_rollback_index=$(sed -n 's/^Rollback Index:[[:space:]]*//p' <<<"$vbmeta_info")
vbmeta_flags=$(sed -n 's/^Flags:[[:space:]]*//p' <<<"$vbmeta_info" | head -n 1)
vbmeta_rollback_location=$(sed -n 's/^Rollback Index Location:[[:space:]]*//p' <<<"$vbmeta_info")
vbmeta_padding_size=$(stat -c '%s' -- "$vbmeta_anchor")
[[ -n "$vbmeta_algorithm" && -n "$vbmeta_rollback_index" && \
   -n "$vbmeta_flags" && -n "$vbmeta_rollback_location" ]] || \
  die "could not parse AVB parameters from $vbmeta_anchor"

vbmeta_descriptor_args=(
  --include_descriptors_from_image "$vbmeta_anchor"
  --include_descriptors_from_image "$result_dir/vendor_kernel_boot.img"
)
if [[ "$patch_signed_firmware" == true ]]; then
  vbmeta_descriptor_args+=(
    --include_descriptors_from_image "$result_dir/vendor.img"
  )
fi
"$avbtool" make_vbmeta_image \
  --output "$result_dir/vbmeta.img" \
  --key "$avb_key" \
  --algorithm "$vbmeta_algorithm" \
  --rollback_index "$vbmeta_rollback_index" \
  --rollback_index_location "$vbmeta_rollback_location" \
  --flags "$vbmeta_flags" \
  "${vbmeta_descriptor_args[@]}" \
  --padding_size "$vbmeta_padding_size"
{
  printf 'variant=frankel-powerphone-aoc-192k\n'
  printf 'built_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'source_module=%s\n' "$module"
  printf 'patcher=%s\n' "$patcher"
  printf 'patcher_sha256=%s\n' "$(sha256sum "$patcher" | awk '{print $1}')"
  printf 'd0_progress_mode=%s\n' "$d0_progress_mode"
  printf 'd0_progress_patcher=%s\n' "$d0_progress_patcher"
  printf 'd0_progress_patcher_sha256=%s\n' \
    "$(sha256sum "$d0_progress_patcher" | awk '{print $1}')"
  printf 'signed_aoc_firmware_patch=%s\n' "$patch_signed_firmware"
  printf 'signed_aoc_firmware_profile=%s\n' "$firmware_profile"
  if [[ "$patch_signed_firmware" == true ]]; then
    printf 'source_firmware=%s\n' "$firmware"
    printf 'firmware_patcher=%s\n' "$firmware_patcher"
    printf 'firmware_patcher_sha256=%s\n' \
      "$(sha256sum "$firmware_patcher" | awk '{print $1}')"
  fi
  printf 'product=%s\n' "$DEVICE_PRODUCT_TARGET"
  printf 'vbmeta_anchor=%s\n' "$vbmeta_anchor"
} >"$result_dir/BUILD_INFO.txt"

note "audio-kernel images: $result_dir"
