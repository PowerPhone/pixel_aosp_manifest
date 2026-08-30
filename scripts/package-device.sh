#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
if [[ "$DEVICE_CODENAME" == frankel ]]; then
  exec "$script_dir/package-device-frankel.sh" "$@"
fi
[[ "$DEVICE_CODENAME" == cubs ]] || \
  die "no device packager is implemented for $DEVICE_CODENAME"
# shellcheck source=../config/recovery.env disable=SC1091
source "$project_root/config/recovery.env"

require_command \
  awk cat cmp find grep install mktemp realpath rm sed sha256sum sort stat \
  unzip xxd

file_sha256() {
  local digest
  [[ -f "$1" && ! -L "$1" && -s "$1" ]] || \
    die "missing, empty, or unsafe regular file: $1"
  digest=$(sha256sum -- "$1")
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "failed to hash $1"
  printf '%s\n' "$digest"
}

zip_entry_sha256() {
  local archive=$1
  local entry=$2
  local count digest
  count=$(unzip -Z1 "$archive" | grep -Fxc -- "$entry" || true)
  (( count == 1 )) || die \
    "expected exactly one $entry entry in $archive; found $count"
  digest=$(unzip -p "$archive" "$entry" | sha256sum)
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || \
    die "failed to hash $entry from $archive"
  printf '%s\n' "$digest"
}

literal_sha256() {
  local digest
  digest=$(printf '%s' "$1" | sha256sum)
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "failed to hash release identity"
  printf '%s\n' "$digest"
}

avb_info_value() {
  local info=$1
  local expression=$2
  local description=$3
  local -a values=()
  mapfile -t values < <(sed -n "$expression" "$info")
  (( ${#values[@]} == 1 )) || \
    die "$description must occur exactly once in AVB metadata"
  printf '%s\n' "${values[0]}"
}

hash_descriptor_value() {
  local info=$1
  local field=$2
  local description=$3
  local -a values=()
  mapfile -t values < <(
    awk -v field="$field" '
      / descriptor:$/ {
        in_hash = ($0 ~ /^[[:space:]]+Hash descriptor:$/)
        next
      }
      in_hash {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        if (index(line, field ":") == 1) {
          sub(/^[^:]*:[[:space:]]*/, "", line)
          print line
        }
      }
    ' "$info"
  )
  (( ${#values[@]} == 1 )) || \
    die "$description must occur exactly once in the carrier hash descriptor"
  printf '%s\n' "${values[0]}"
}

validate_vbmeta_carrier_args() {
  local misc=$1
  local args token basename
  local index
  local -a values=()
  local -a tokens=()
  local -a actual=()

  mapfile -t values < <(sed -n 's/^avb_vbmeta_args=//p' <<<"$misc")
  (( ${#values[@]} == 1 )) || \
    die "target-files must contain exactly one avb_vbmeta_args setting"
  args=${values[0]}
  read -r -a tokens <<<"$args"
  for ((index = 0; index < ${#tokens[@]}; index += 1)); do
    token=${tokens[$index]}
    [[ "$token" == --include_descriptors_from_image ]] || continue
    (( index + 1 < ${#tokens[@]} )) || \
      die "avb_vbmeta_args has an unterminated descriptor-carrier argument"
    ((index += 1))
    basename=${tokens[$index]##*/}
    [[ "$basename" =~ ^[a-z0-9_]+_vbfooted\.img$ ]] || \
      die "avb_vbmeta_args references an unsafe firmware descriptor carrier"
    actual+=("$basename")
  done
  (( ${#actual[@]} == ${#firmware_carrier_images[@]} )) && \
    [[ "${actual[*]}" == "${firmware_carrier_images[*]}" ]] || \
    die "avb_vbmeta_args does not include the exact ordered firmware descriptor-carrier set"
}

reject_firmware_carrier_leaks() {
  local listing=$1
  local destination=$2
  local entry basename
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -n "$entry" ]] || continue
    basename=${entry##*/}
    [[ ! "$basename" =~ ^[a-z0-9_]+_vbfooted\.img$ ]] || \
      die "$destination leaks firmware descriptor carrier $basename"
  done <<<"$listing"
}

validate_firmware_carrier() {
  local partition=$1
  local raw=$2
  local carrier=$3
  local expected_salt=$4
  local info=$5
  local verify_log=$6
  local raw_size carrier_size expected_carrier_size expected_digest digest
  local descriptor_count hash_descriptor_count

  raw_size=$(stat -c '%s' "$raw")
  carrier_size=$(stat -c '%s' "$carrier")
  (( raw_size > 0 )) || die "empty raw firmware image for $partition"
  expected_carrier_size=$((
    69632 + ((raw_size + 4095) / 4096) * 4096
  ))
  (( carrier_size == expected_carrier_size )) || die \
    "$partition descriptor carrier size mismatch: expected $expected_carrier_size, found $carrier_size"
  cmp -n "$raw_size" -s -- "$raw" "$carrier" || die \
    "$partition descriptor carrier does not preserve the raw firmware prefix"

  "$avbtool" info_image --image "$carrier" >"$info" || \
    die "$partition descriptor carrier has invalid AVB metadata"
  descriptor_count=$(grep -Ec \
    '^[[:space:]]+[^[:space:]].* descriptor:$' "$info" || true)
  hash_descriptor_count=$(grep -Ec \
    '^[[:space:]]+Hash descriptor:$' "$info" || true)
  (( descriptor_count == 1 && hash_descriptor_count == 1 )) || die \
    "$partition descriptor carrier must contain exactly one hash descriptor"
  [[ $(avb_info_value "$info" \
      's/^Algorithm:[[:space:]]*//p' "$partition carrier algorithm") == NONE ]] || \
    die "$partition descriptor carrier must use unsigned inner vbmeta"
  [[ $(avb_info_value "$info" \
      's/^Rollback Index:[[:space:]]*//p' "$partition carrier rollback index") == 0 ]] || \
    die "$partition descriptor carrier has a nonzero rollback index"
  [[ $(avb_info_value "$info" \
      's/^Flags:[[:space:]]*//p' "$partition carrier flags") == 0 ]] || \
    die "$partition descriptor carrier has nonzero AVB flags"
  [[ $(avb_info_value "$info" \
      's/^Image size:[[:space:]]*\([0-9][0-9]*\) bytes$/\1/p' \
      "$partition carrier image size") == "$carrier_size" ]] || \
    die "$partition descriptor carrier footer size is inconsistent"
  [[ $(avb_info_value "$info" \
      's/^Original image size:[[:space:]]*\([0-9][0-9]*\) bytes$/\1/p' \
      "$partition carrier original size") == "$raw_size" ]] || \
    die "$partition descriptor carrier original size is inconsistent"
  [[ $(hash_descriptor_value "$info" "Image Size" \
      "$partition descriptor image size") == "$raw_size bytes" ]] || \
    die "$partition descriptor does not cover the exact raw image size"
  [[ $(hash_descriptor_value "$info" "Hash Algorithm" \
      "$partition descriptor hash algorithm") == sha256 ]] || \
    die "$partition descriptor does not use SHA-256"
  [[ $(hash_descriptor_value "$info" "Partition Name" \
      "$partition descriptor partition name") == "$partition" ]] || \
    die "$partition descriptor names the wrong raw partition"
  [[ $(hash_descriptor_value "$info" Salt \
      "$partition descriptor salt") == "$expected_salt" ]] || \
    die "$partition descriptor salt does not match the pinned release identity"
  [[ $(hash_descriptor_value "$info" Flags \
      "$partition descriptor flags") == 0 ]] || \
    die "$partition hash descriptor has nonzero flags"

  expected_digest=$(
    { printf '%s' "$expected_salt" | xxd -r -p; cat -- "$raw"; } | \
      sha256sum
  )
  expected_digest=${expected_digest%% *}
  digest=$(hash_descriptor_value "$info" Digest \
    "$partition descriptor digest")
  [[ "$digest" == "$expected_digest" ]] || \
    die "$partition descriptor digest does not match its salted raw image"
  if ! "$avbtool" verify_image --image "$carrier" >"$verify_log" 2>&1; then
    sed -n '1,120p' "$verify_log" >&2
    die "$partition descriptor carrier failed AVB hash verification"
  fi
}

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
out_dir=${DEVICE_OUT_DIR:-"$source_dir/out_pixel/cubs"}
out_dir=$(realpath -m -- "$out_dir")
product_out="$out_dir/target/product/$DEVICE_CODENAME"
artifacts_root=$(realpath -m -- "$project_root/artifacts")
bundle_dir=${CUBS_ARTIFACT_DIR:-"$artifacts_root/cubs"}
bundle_dir=$(realpath -m -- "$bundle_dir")
case "$bundle_dir" in
  "$artifacts_root"/*) ;;
  *) die "cubs artifact directory must remain below $artifacts_root" ;;
esac
if [[ -n "${CUBS_TARGET_FILES:-}" ]]; then
  [[ -f "$CUBS_TARGET_FILES" && ! -L "$CUBS_TARGET_FILES" ]] || \
    die "CUBS_TARGET_FILES is not a safe regular file"
  CUBS_TARGET_FILES=$(realpath -e -- "$CUBS_TARGET_FILES")
  export CUBS_TARGET_FILES
fi
assert_inside_work "$source_dir"
assert_inside_work "$out_dir"
require_target_scoped_output "$source_dir" "$out_dir"
assert_inside_project "$bundle_dir"
AOSP_SOURCE_DIR="$source_dir" \
  "$script_dir/attest-generated-vendor.sh" verify
AOSP_SOURCE_DIR="$source_dir" DEVICE_OUT_DIR="$out_dir" \
  "$script_dir/attest-build-output.sh" verify cubs
build_attestation="$out_dir/build-completion-cubs.attestation"
require_file "$build_attestation"
[[ ! -L "$build_attestation" ]] || die "unsafe cubs build attestation"
build_attestation_sha256=$(sha256sum "$build_attestation" | awk '{print $1}')
[[ -f "$script_dir/flash-a.sh" && ! -L "$script_dir/flash-a.sh" && \
   -x "$script_dir/flash-a.sh" ]] || \
  die "reviewed standalone flash runner is missing or unsafe"
runner_policy_sha256=$(
  sed -n 's/^expected_recovery_policy_sha256=//p' \
    "$script_dir/flash-a.sh"
)
[[ $(grep -c '^expected_recovery_policy_sha256=' \
      "$script_dir/flash-a.sh") -eq 1 && \
   "$runner_policy_sha256" == "$CUBS_RECOVERY_POLICY_SHA256" ]] || \
  die "standalone flash runner does not match the current recovery policy"
[[ -d "$product_out" ]] || die "device product output not found: $product_out"

if [[ -n "${CUBS_TARGET_FILES:-}" ]]; then
  target_files=$(realpath -e -- "$CUBS_TARGET_FILES")
  assert_inside_project "$target_files"
  require_file "$target_files"
else
  target_files_root="$product_out/obj/PACKAGING/target_files_intermediates"
  [[ -d "$target_files_root" ]] || \
    die "target-files output not found: $target_files_root"
  mapfile -t target_files_candidates < <(
    find "$target_files_root" -type f -name '*target_files*.zip' -print | sort
  )
  (( ${#target_files_candidates[@]} == 1 )) || die \
    "expected exactly one target-files package; found ${#target_files_candidates[@]}; set CUBS_TARGET_FILES explicitly"
  target_files=${target_files_candidates[0]}
fi
unzip -tq "$target_files" >/dev/null || die "invalid target-files ZIP"

misc_info=$(unzip -p "$target_files" META/misc_info.txt) || \
  die "target-files package has no META/misc_info.txt"
grep -qx 'ab_update=true' <<<"$misc_info" || \
  die "target-files package is not configured for A/B updates"
grep -qx 'use_dynamic_partitions=true' <<<"$misc_info" || \
  die "target-files package does not use dynamic partitions"
grep -qx 'avb_enable=true' <<<"$misc_info" || \
  die "target-files package does not enable AVB"
grep -qx 'super_partition_size=10737418240' <<<"$misc_info" || \
  die "target-files super size does not match the audited cubs layout"

staging_parent="$project_root/work/packaging"
mkdir -p "$staging_parent"
staging_dir=$(mktemp -d "$staging_parent/.cubs-bundle.XXXXXX")
cleanup() {
  if [[ -n "${staging_dir:-}" && -d "$staging_dir" && \
        "$staging_dir" == "$staging_parent"/.cubs-bundle.* ]]; then
    rm -rf -- "$staging_dir"
  fi
}
trap cleanup EXIT
install -m 0644 "$build_attestation" "$staging_dir/BUILD_ATTESTATION.txt"

# Validate the build identity from target-files properties before constructing
# a flashable bundle. Product-specific properties may live in any partition.
mapfile -t build_prop_entries < <(
  unzip -Z1 "$target_files" | awk '/(^|\/)build\.prop$/ {print}'
)
(( ${#build_prop_entries[@]} > 0 )) || \
  die "target-files package contains no build properties"
for entry in "${build_prop_entries[@]}"; do
  unzip -p "$target_files" "$entry" >> "$staging_dir/all-build-props.txt"
  printf '\n' >> "$staging_dir/all-build-props.txt"
done
grep -Eq '^ro\.(build|system\.build)\.type=userdebug$' \
  "$staging_dir/all-build-props.txt" || \
  die "target-files package is not a userdebug build"
grep -Eq '^ro\.(build|system\.build)\.version\.sdk=37$' \
  "$staging_dir/all-build-props.txt" || \
  die "target-files package is not Android SDK 37"
grep -Eq '^ro\.product(\.[^.]+)?\.device=cubs$' \
  "$staging_dir/all-build-props.txt" || \
  die "target-files package has no cubs device identity"
grep -Fqx "ro.build.id=$STOCK_BUILD_ID" \
  "$staging_dir/all-build-props.txt" || \
  die "target-files package does not use the pinned cubs product build ID"
grep -Fqx "ro.system.build.id=$STOCK_BUILD_ID" \
  "$staging_dir/all-build-props.txt" || \
  die "target-files package has a mismatched system build ID"
grep -Fqx "ro.build.version.security_patch=$AOSP_SECURITY_PATCH" \
  "$staging_dir/all-build-props.txt" || \
  die "target-files framework SPL does not match the pinned AOSP release"

img_from_target_files="$out_dir/host/linux-x86/bin/img_from_target_files"
avbtool="$out_dir/host/linux-x86/bin/avbtool"
[[ -x "$img_from_target_files" ]] || \
  die "built img_from_target_files not found: $img_from_target_files"
[[ -x "$avbtool" ]] || die "built avbtool not found: $avbtool"

images_zip="$staging_dir/cubs-images.zip"
note "generating partition images from target-files"
"$img_from_target_files" "$target_files" "$images_zip"
unzip -tq "$images_zip" >/dev/null || die "generated image ZIP is invalid"

firmware_partitions=(
  abl
  bl31
  cap
  cpm
  dbc
  dbl
  dram_init_0
  dram_init_1
  dram_init_2
  dram_init_3
  dram_init_4
  dram_init_5
  dram_init_6
  dram_init_7
  dram_init_8
  dram_init_9
  dram_init_10
  dram_init_11
  dram_phy
  gc
  gdmc
  gsa_bl1
  gsa_fw
  tzsw
  modem
)
firmware_descriptor_partitions=(
  abl
  bl31
  cap
  cpm
  dbc
  dbl
  dram_init_0
  dram_init_1
  dram_init_10
  dram_init_11
  dram_init_2
  dram_init_3
  dram_init_4
  dram_init_5
  dram_init_6
  dram_init_7
  dram_init_8
  dram_init_9
  dram_phy
  gc
  gdmc
  gsa_bl1
  gsa_fw
  tzsw
)
firmware_image_files=()
for partition in "${firmware_partitions[@]}"; do
  firmware_image_files+=("$partition.img")
done
firmware_carrier_images=()
for partition in "${firmware_descriptor_partitions[@]}"; do
  firmware_carrier_images+=("${partition}_vbfooted.img")
done
image_files=(
  "${firmware_image_files[@]}"
  boot.img
  init_boot.img
  dtbo.img
  vendor_boot.img
  vendor_kernel_boot.img
  pvmfw.img
  vbmeta.img
  vbmeta_system.img
  vbmeta_vendor.img
  system.img
  system_dlkm.img
  system_ext.img
  product.img
  vendor.img
  vendor_dlkm.img
)
mapfile -t generated_entries < <(unzip -Z1 "$images_zip")
for image_name in "${image_files[@]}"; do
  matches=0
  for entry in "${generated_entries[@]}"; do
    [[ "$entry" == "$image_name" ]] && ((matches += 1))
  done
  (( matches == 1 )) || die \
    "generated image ZIP must contain exactly one root entry named $image_name"
  unzip -p "$images_zip" "$image_name" > "$staging_dir/$image_name"
  [[ -s "$staging_dir/$image_name" ]] || die "empty image: $image_name"
done

# The 25 slotted firmware payloads must remain byte-identical from adevtool's
# generated source through target-files and img_from_target_files. Aggregate
# bootloader/radio containers are extraction inputs only and are deliberately
# excluded from both the reconstructed image ZIP and the flash bundle.
source_firmware_dir="$source_dir/vendor/google_devices/$DEVICE_CODENAME/firmware"
[[ -d "$source_firmware_dir" && ! -L "$source_firmware_dir" ]] || \
  die "generated cubs firmware directory is missing or unsafe"
expected_source_firmware=(bootloader.img radio.img "${firmware_image_files[@]}")
mapfile -t expected_source_firmware_sorted < <(
  printf '%s\n' "${expected_source_firmware[@]}" | LC_ALL=C sort
)
mapfile -t actual_source_firmware < <(
  find "$source_firmware_dir" -mindepth 1 -maxdepth 1 -type f \
    -name '*.img' -printf '%f\n' | LC_ALL=C sort
)
[[ "${actual_source_firmware[*]}" == \
   "${expected_source_firmware_sorted[*]}" ]] || \
  die "generated cubs firmware source does not match its exact image allowlist"
mapfile -t expected_target_radio < <(
  printf 'RADIO/%s\n' \
    "${expected_source_firmware[@]}" "${firmware_carrier_images[@]}" | \
    LC_ALL=C sort
)
mapfile -t actual_target_radio < <(
  unzip -Z1 "$target_files" | \
    awk '/^RADIO\/[^/]+\.img$/ {print}' | LC_ALL=C sort
)
[[ "${actual_target_radio[*]}" == "${expected_target_radio[*]}" ]] || \
  die "target-files RADIO entries do not match the exact raw and descriptor-carrier allowlist"
validate_vbmeta_carrier_args "$misc_info"
for forbidden_image in bootloader.img radio.img "${firmware_carrier_images[@]}"; do
  aggregate_count=$(
    printf '%s\n' "${generated_entries[@]}" | \
      grep -Fxc -- "$forbidden_image" || true
  )
  (( aggregate_count == 0 )) || \
    die "reconstructed image ZIP must not contain target-files-only $forbidden_image"
done
reject_firmware_carrier_leaks \
  "$(printf '%s\n' "${generated_entries[@]}")" "reconstructed image ZIP"

build_number_file="$out_dir/soong/build_number.txt"
build_date_file="$out_dir/build_date.txt"
[[ $(file_sha256 "$build_number_file") == \
   $(literal_sha256 "$AOSP_BUILD_NUMBER") ]] || \
  die "cubs build-number file bytes do not match the pinned release identity"
[[ $(file_sha256 "$build_date_file") == \
   $(literal_sha256 "$AOSP_BUILD_DATETIME") ]] || \
  die "cubs build-date file bytes do not match the pinned release identity"
firmware_carrier_salt="$(file_sha256 "$build_number_file")$(file_sha256 "$build_date_file")"
[[ "$firmware_carrier_salt" =~ ^[0-9a-f]{128}$ ]] || \
  die "failed to derive the cubs firmware descriptor-carrier salt"
carrier_dir="$staging_dir/.firmware-descriptor-carriers"
mkdir -p "$carrier_dir"
for partition in "${firmware_descriptor_partitions[@]}"; do
  raw_image="$carrier_dir/$partition.img"
  carrier_image="$carrier_dir/${partition}_vbfooted.img"
  unzip -p "$target_files" "RADIO/$partition.img" >"$raw_image"
  unzip -p "$target_files" "RADIO/${partition}_vbfooted.img" \
    >"$carrier_image"
  [[ -s "$raw_image" && -s "$carrier_image" ]] || \
    die "empty raw image or descriptor carrier for $partition"
  validate_firmware_carrier \
    "$partition" "$raw_image" "$carrier_image" "$firmware_carrier_salt" \
    "$carrier_dir/$partition.info" "$carrier_dir/$partition.verify.log"
done
rm -rf -- "$carrier_dir"
for partition in "${firmware_partitions[@]}"; do
  image_name="$partition.img"
  source_hash=$(file_sha256 "$source_firmware_dir/$image_name")
  target_hash=$(zip_entry_sha256 "$target_files" "RADIO/$image_name")
  reconstructed_hash=$(zip_entry_sha256 "$images_zip" "$image_name")
  staged_hash=$(file_sha256 "$staging_dir/$image_name")
  [[ "$source_hash" == "$target_hash" && \
     "$source_hash" == "$reconstructed_hash" && \
     "$source_hash" == "$staged_hash" ]] || \
    die "$image_name differs across generated source, target-files, reconstructed ZIP, or staged bundle"
done
"$avbtool" info_image --image "$staging_dir/vbmeta.img" >/dev/null || \
  die "vbmeta image failed AVB validation"
"$avbtool" info_image --image "$staging_dir/vbmeta_system.img" >/dev/null || \
  die "vbmeta_system image failed AVB validation"
"$avbtool" info_image --image "$staging_dir/vbmeta_vendor.img" >/dev/null || \
  die "vbmeta_vendor image failed AVB validation"

# The firmware requirements and every individually slotted firmware payload
# are bound to the checksum-pinned stock package, not to fastboot-info.txt.
# The outer bootloader/radio aggregate images are never packaged.
factory_image="$project_root/downloads/$FACTORY_IMAGE_FILENAME"
verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"
"$script_dir/extract-stock.sh"
stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
stock_images="$stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
require_file "$stock_images"
for partition in "${firmware_partitions[@]}"; do
  image_name="$partition.img"
  stock_hash=$(zip_entry_sha256 "$stock_images" "$image_name")
  [[ "$stock_hash" == "$(file_sha256 "$staging_dir/$image_name")" ]] || \
    die "$image_name differs from the checksum-pinned stock inner image ZIP"
done
stock_android_info=$(unzip -p "$stock_images" android-info.txt) || \
  die "stock image package has no android-info.txt"
stock_board_requirement=$(sed -n 's/^require board=//p' <<<"$stock_android_info")
[[ "|$stock_board_requirement|" == *"|$DEVICE_CODENAME|"* ]] || \
  die "stock package board requirement does not include $DEVICE_CODENAME"
stock_bootloader_requirement=$(
  sed -n 's/^require version-bootloader=//p' <<<"$stock_android_info"
)
stock_baseband_requirement=$(
  sed -n 's/^require version-baseband=//p' <<<"$stock_android_info"
)
[[ $(grep -c '^require version-bootloader=' <<<"$stock_android_info") -eq 1 ]] || \
  die "stock package must have exactly one bootloader requirement"
[[ $(grep -c '^require version-baseband=' <<<"$stock_android_info") -eq 1 ]] || \
  die "stock package must have exactly one baseband requirement"
{
  printf 'require product=%s\n' "$DEVICE_CODENAME"
  printf 'require version-bootloader=%s\n' "$stock_bootloader_requirement"
  printf 'require version-baseband=%s\n' "$stock_baseband_requirement"
} > "$staging_dir/firmware-requirements.txt"

printf 'cubs\n' > "$staging_dir/bundle-kind"
target_files_sha256=$(sha256sum "$target_files" | awk '{print $1}')
images_zip_sha256=$(sha256sum "$images_zip" | awk '{print $1}')
{
  printf 'bundle_kind=cubs\n'
  printf 'device=%s\n' "$DEVICE_CODENAME"
  printf 'aosp_revision=%s\n' "$AOSP_REVISION"
  printf 'source_aosp_build_id=%s\n' "$AOSP_BUILD_ID"
  printf 'output_build_id=%s\n' "$STOCK_BUILD_ID"
  printf 'framework_security_patch=%s\n' "$AOSP_SECURITY_PATCH"
  printf 'build_variant=userdebug\n'
  printf 'stock_vendor_build=%s\n' "$STOCK_BUILD_ID"
  printf 'platform_tools=%s\n' "$PLATFORM_TOOLS_VERSION"
  printf 'target_files_sha256=%s\n' "$target_files_sha256"
  printf 'generated_images_zip_sha256=%s\n' "$images_zip_sha256"
  printf 'build_attestation_sha256=%s\n' "$build_attestation_sha256"
  printf 'flash_scope=slot_a_partition_names_shared_super\n'
  printf 'recovery_anchor=slot_b_physical_fastbootd_lifeboat\n'
} > "$staging_dir/BUNDLE_INFO.txt"
install -m 0755 "$script_dir/flash-a.sh" "$staging_dir/flash-all.sh"

manifest_files=(
  bundle-kind
  BUNDLE_INFO.txt
  BUILD_ATTESTATION.txt
  firmware-requirements.txt
  flash-all.sh
  "${image_files[@]}"
)
(
  cd "$staging_dir"
  sha256sum "${manifest_files[@]}" > SHA256SUMS
  sha256sum --check --strict SHA256SUMS
)

rm -f -- "$staging_dir/all-build-props.txt" "$staging_dir/cubs-images.zip"
[[ -f "$script_dir/validate-images.sh" && \
   ! -L "$script_dir/validate-images.sh" && \
   -x "$script_dir/validate-images.sh" ]] || \
  die "required static image validator is missing or not a safe executable"
AOSP_SOURCE_DIR="$source_dir" DEVICE_OUT_DIR="$out_dir" \
CUBS_ARTIFACT_DIR="$staging_dir" CUBS_TARGET_FILES="$target_files" \
  "$script_dir/validate-images.sh" cubs

# Publish only after static validation. Remove the old checksum first so an
# interrupted refresh is never accepted as a complete, reviewed bundle.
mkdir -p "$bundle_dir"
allowed_existing=(SHA256SUMS "${manifest_files[@]}")
mapfile -d '' -t existing_entries < <(
  find "$bundle_dir" -mindepth 1 -maxdepth 1 -printf '%f\0' | LC_ALL=C sort -z
)
for name in "${existing_entries[@]}"; do
  allowed=
  for allowed_name in "${allowed_existing[@]}"; do
    if [[ "$name" == "$allowed_name" ]]; then
      allowed=1
      break
    fi
  done
  [[ -n "$allowed" ]] || die \
    "refusing to replace cubs artifact directory containing unexpected entry: $name"
  [[ -f "$bundle_dir/$name" && ! -L "$bundle_dir/$name" ]] || die \
    "refusing to replace unsafe cubs artifact entry: $name"
done
rm -f -- "$bundle_dir/SHA256SUMS"
for name in bundle-kind BUNDLE_INFO.txt BUILD_ATTESTATION.txt \
  firmware-requirements.txt "${image_files[@]}"; do
  install -m 0644 "$staging_dir/$name" "$bundle_dir/$name"
done
install -m 0755 "$staging_dir/flash-all.sh" "$bundle_dir/flash-all.sh"
install -m 0644 "$staging_dir/SHA256SUMS" "$bundle_dir/SHA256SUMS"

if ! AOSP_SOURCE_DIR="$source_dir" DEVICE_OUT_DIR="$out_dir" \
    CUBS_ARTIFACT_DIR="$bundle_dir" CUBS_TARGET_FILES="$target_files" \
    "$script_dir/validate-images.sh" cubs; then
  rm -f -- "$bundle_dir/SHA256SUMS"
  die "published cubs bundle failed revalidation; its checksum manifest was withdrawn"
fi

note "cubs userdebug slot-A flash bundle: $bundle_dir"
note "the bundle contains 25 individually slotted firmware images, never aggregate bootloader/radio images"
note "the flash runner targets only literal slot-A names and never writes slot B"
note "the runner journals stock-A fastbootd logical writes before every physical-A payload"
note "shared-super writes invalidate B Android while preserving the physical-B fastbootd lifeboat"
