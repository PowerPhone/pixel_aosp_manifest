#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

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
