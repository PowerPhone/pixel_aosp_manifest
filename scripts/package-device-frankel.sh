#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ ${PIXEL_TARGET:-} != frankel ]]; then
  printf 'error: set PIXEL_TARGET=frankel for the Frankel packager\n' >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"

[[ "$DEVICE_CODENAME" == frankel && "$DEVICE_PLATFORM" == laguna ]] || \
  die "the selected target profile is not Frankel/Laguna"

require_command \
  awk bash cmp find grep install mkdir mktemp realpath rm sed sha256sum sort \
  stat tr unzip

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
out_dir=${DEVICE_OUT_DIR:-"$source_dir/out_pixel/frankel"}
out_dir=$(realpath -m -- "$out_dir")
assert_inside_work "$source_dir"
assert_inside_work "$out_dir"
case "$out_dir" in
  "$source_dir"/*) ;;
  *) die "DEVICE_OUT_DIR must remain inside the AOSP source tree" ;;
esac
require_target_scoped_output "$source_dir" "$out_dir"

product_out="$out_dir/target/product/frankel"
[[ -d "$product_out" && ! -L "$product_out" ]] || \
  die "Frankel product output is missing or unsafe: $product_out"

target_files_root="$product_out/obj/PACKAGING/target_files_intermediates"
[[ -d "$target_files_root" && ! -L "$target_files_root" ]] || \
  die "Frankel target-files directory is missing or unsafe"
target_files_root=$(realpath -e -- "$target_files_root")
case "$target_files_root" in
  "$out_dir"/*) ;;
  *) die "Frankel target-files directory escapes the selected output tree" ;;
esac

if [[ -n ${DEVICE_TARGET_FILES:-} ]]; then
  [[ -f "$DEVICE_TARGET_FILES" && ! -L "$DEVICE_TARGET_FILES" ]] || \
    die "DEVICE_TARGET_FILES is not a safe regular file"
  target_files=$(realpath -e -- "$DEVICE_TARGET_FILES")
  case "$target_files" in
    "$target_files_root"/*) ;;
    *) die "DEVICE_TARGET_FILES is not inside the Frankel target-files directory" ;;
  esac
  [[ -f "$target_files" && ! -L "$target_files" ]] || \
    die "DEVICE_TARGET_FILES is not a safe regular file"
else
  mapfile -d '' -t target_files_candidates < <(
    find "$target_files_root" -maxdepth 1 -type f \
      -name 'frankel-target_files.zip' -print0 | sort -z
  )
  (( ${#target_files_candidates[@]} == 1 )) || die \
    "expected exactly one Frankel target-files archive; found ${#target_files_candidates[@]}"
  target_files=${target_files_candidates[0]}
fi
unzip -tqq "$target_files" || die "Frankel target-files archive is invalid"

# The completion marker binds the exact target-files archive, generated vendor
# tree, source lock, patch lock, product identity, and required device images.
# Pass the already-resolved archive explicitly so verification cannot select a
# different concurrent output.
PIXEL_TARGET=frankel \
AOSP_SOURCE_DIR="$source_dir" \
DEVICE_OUT_DIR="$out_dir" \
DEVICE_TARGET_FILES="$target_files" \
  "$script_dir/attest-device-build.sh" verify

build_attestation="$out_dir/build-completion-frankel.attestation"
[[ -f "$build_attestation" && ! -L "$build_attestation" && \
   -s "$build_attestation" ]] || \
  die "verified Frankel build attestation is missing, empty, or unsafe"

# Laguna's exact CP2A.260805.005 A/B firmware inventory. Unlike Malibu, Laguna
# has ten dram_init payloads and has no dram_init_10 or dram_init_11 image.
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
  dram_phy
  gc
  gdmc
  gsa_bl1
  gsa_fw
  tzsw
  modem
)
physical_os_partitions=(
  boot
  dtbo
  init_boot
  pvmfw
  vendor_boot
  vendor_kernel_boot
  vbmeta
)
logical_partitions=(
  system
  system_dlkm
  system_ext
  product
  vendor
  vendor_dlkm
)
expected_ab_partitions=(
  "${firmware_partitions[@]}"
  "${physical_os_partitions[@]}"
  "${logical_partitions[@]}"
)
(( ${#firmware_partitions[@]} == 23 && \
   ${#physical_os_partitions[@]} == 7 && \
   ${#logical_partitions[@]} == 6 && \
   ${#expected_ab_partitions[@]} == 36 )) || \
  die "internal Frankel partition inventory is inconsistent"

firmware_image_files=()
for partition in "${firmware_partitions[@]}"; do
  firmware_image_files+=("$partition.img")
done
physical_os_image_files=()
for partition in "${physical_os_partitions[@]}"; do
  physical_os_image_files+=("$partition.img")
done
logical_image_files=()
for partition in "${logical_partitions[@]}"; do
  logical_image_files+=("$partition.img")
done
image_files=(
  "${firmware_image_files[@]}"
  "${physical_os_image_files[@]}"
  "${logical_image_files[@]}"
)
(( ${#image_files[@]} == 36 )) || \
  die "internal Frankel image inventory is inconsistent"

source_firmware_dir="$source_dir/vendor/google_devices/frankel/firmware"
[[ -d "$source_firmware_dir" && ! -L "$source_firmware_dir" ]] || \
  die "generated Frankel firmware directory is missing or unsafe"
source_firmware_images=(bootloader.img radio.img "${firmware_image_files[@]}")
mapfile -t expected_source_firmware_sorted < <(
  printf '%s\n' "${source_firmware_images[@]}" | sort
)
mapfile -t actual_source_firmware < <(
  find "$source_firmware_dir" -mindepth 1 -maxdepth 1 -name '*.img' \
    -printf '%f\n' | sort
)
[[ "${actual_source_firmware[*]}" == \
   "${expected_source_firmware_sorted[*]}" ]] || \
  die "generated Frankel firmware directory does not match the exact Laguna image allowlist"
for image_name in "${source_firmware_images[@]}"; do
  [[ -f "$source_firmware_dir/$image_name" && \
     ! -L "$source_firmware_dir/$image_name" && \
     -s "$source_firmware_dir/$image_name" ]] || \
    die "generated Frankel firmware image is missing, empty, or unsafe: $image_name"
done
[[ -f "$source_firmware_dir/android-info.txt" && \
   ! -L "$source_firmware_dir/android-info.txt" && \
   -s "$source_firmware_dir/android-info.txt" ]] || \
  die "generated Frankel firmware android-info.txt is missing, empty, or unsafe"

misc_info=$(unzip -p "$target_files" META/misc_info.txt) || \
  die "Frankel target-files has no readable META/misc_info.txt"
misc_value() {
  local key=$1
  local -a values=()
  mapfile -t values < <(
    sed -n "s/^${key}=//p" <<<"$misc_info"
  )
  (( ${#values[@]} == 1 )) || \
    die "Frankel target-files must contain exactly one $key setting"
  [[ -n "${values[0]}" ]] || \
    die "Frankel target-files contains an empty $key setting"
  printf '%s\n' "${values[0]}"
}

[[ $(misc_value ab_update) == true && \
   $(misc_value use_dynamic_partitions) == true && \
   $(misc_value avb_enable) == true ]] || \
  die "Frankel target-files is not an AVB-enabled dynamic A/B build"
[[ $(misc_value super_partition_size) == 8531214336 ]] || \
  die "Frankel target-files has unexpected Laguna super geometry"
[[ $(misc_value super_partition_groups) == google_dynamic_partitions ]] || \
  die "Frankel target-files has an unexpected dynamic partition group"
[[ $(misc_value super_google_dynamic_partitions_group_size) == 8527020032 ]] || \
  die "Frankel target-files has an unexpected Laguna dynamic group size"

normalize_word_set() {
  tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
expected_logical_words=$(normalize_word_set "${logical_partitions[*]}")
[[ $(normalize_word_set "$(misc_value dynamic_partition_list)") == \
     "$expected_logical_words" ]] || \
  die "Frankel target-files dynamic partition list is not exact"
[[ $(normalize_word_set \
       "$(misc_value super_google_dynamic_partitions_partition_list)") == \
     "$expected_logical_words" ]] || \
  die "Frankel target-files dynamic group membership is not exact"

expected_pvmfw_fingerprint="google/frankel/frankel:17/${STOCK_BUILD_ID}/${AOSP_BUILD_NUMBER}:userdebug/test-keys"
expected_pvmfw_salt=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
[[ $(misc_value pvmfw_size) == 0x100000 ]] || \
  die "Frankel target-files has an unexpected pvmfw partition size"
[[ $(misc_value has_pvmfw) == true ]] || \
  die "Frankel target-files does not declare pvmfw"
[[ $(misc_value avb_pvmfw_signing_algorithm) == SHA256_RSA4096 ]] || \
  die "Frankel target-files has an unexpected pvmfw signing algorithm"
[[ $(misc_value avb_pvmfw_signing_key_path) == \
     external/avb/test/data/testkey_rsa4096.pem ]] || \
  die "Frankel target-files has an unexpected pvmfw signing key"
[[ $(misc_value avb_pvmfw_add_hash_footer_args) == \
     "--salt $expected_pvmfw_salt --prop com.android.build.pvmfw.fingerprint:$expected_pvmfw_fingerprint" ]] || \
  die "Frankel target-files has unexpected pvmfw AVB footer arguments"

staging_parent="$project_root/work/packaging"
assert_inside_work "$staging_parent"
[[ ! -L "$staging_parent" ]] || \
  die "packaging staging parent must not be a symbolic link"
mkdir -p "$staging_parent"
staging_dir=$(mktemp -d "$staging_parent/.frankel-device-bundle.XXXXXX")
cleanup() {
  if [[ -n ${staging_dir:-} && -d "$staging_dir" && \
        ! -L "$staging_dir" && \
        "$staging_dir" == "$staging_parent"/.frankel-device-bundle.* ]]; then
    rm -rf -- "$staging_dir"
  fi
}
trap cleanup EXIT

target_entries="$staging_dir/.target-files.entries"
unzip -Z1 "$target_files" > "$target_entries"
[[ $(grep -Fxc META/ab_partitions.txt "$target_entries" || true) -eq 1 ]] || \
  die "Frankel target-files must contain exactly one META/ab_partitions.txt"
[[ $(grep -Fxc META/misc_info.txt "$target_entries" || true) -eq 1 ]] || \
  die "Frankel target-files must contain exactly one META/misc_info.txt"
[[ $(grep -Fxc IMAGES/pvmfw.img "$target_entries" || true) -eq 1 && \
   $(grep -Fxc PREBUILT_IMAGES/pvmfw.img "$target_entries" || true) -eq 1 ]] || \
  die "Frankel target-files must contain one input and one rebuilt pvmfw image"
if grep -Eq '(^|/)(vbmeta_system|vbmeta_vendor)\.img$' "$target_entries"; then
  die "Frankel root-only target-files unexpectedly contains child-vbmeta images"
fi

ab_partitions_text=$(unzip -p "$target_files" META/ab_partitions.txt) || \
  die "unable to read Frankel A/B partition manifest"
[[ -n "$ab_partitions_text" && "$ab_partitions_text" != *$'\r'* ]] || \
  die "Frankel A/B partition manifest is empty or malformed"
mapfile -t actual_ab_partitions <<<"$ab_partitions_text"
for partition in "${actual_ab_partitions[@]}"; do
  [[ "$partition" =~ ^[a-z0-9_]+$ ]] || \
    die "Frankel A/B partition manifest contains an invalid name"
done
mapfile -t actual_ab_partitions_sorted < <(
  printf '%s\n' "${actual_ab_partitions[@]}" | sort
)
mapfile -t expected_ab_partitions_sorted < <(
  printf '%s\n' "${expected_ab_partitions[@]}" | sort
)
[[ "${actual_ab_partitions_sorted[*]}" == \
   "${expected_ab_partitions_sorted[*]}" ]] || \
  die "Frankel target-files A/B manifest does not match the exact 36-image inventory"

img_from_target_files="$out_dir/host/linux-x86/bin/img_from_target_files"
avbtool="$out_dir/host/linux-x86/bin/avbtool"
[[ -f "$img_from_target_files" && ! -L "$img_from_target_files" && \
   -x "$img_from_target_files" ]] || \
  die "built otatools img_from_target_files is missing or unsafe"
[[ -f "$avbtool" && ! -L "$avbtool" && -x "$avbtool" ]] || \
  die "built otatools avbtool is missing or unsafe"
images_zip="$staging_dir/.frankel-images.zip"
note "reconstructing the exact Frankel image archive from target-files"
PATH="$out_dir/host/linux-x86/bin:$PATH" \
  "$img_from_target_files" "$target_files" "$images_zip"
unzip -tqq "$images_zip" || \
  die "reconstructed Frankel image archive is invalid"
image_entries="$staging_dir/.image-zip.entries"
unzip -Z1 "$images_zip" > "$image_entries"

for required_entry in android-info.txt fastboot-info.txt \
    "${image_files[@]}"; do
  [[ $(grep -Fxc -- "$required_entry" "$image_entries" || true) -eq 1 ]] || \
    die "reconstructed Frankel image archive must contain exactly one $required_entry"
done

# Publish firmware from the generated vendor tree, after proving that otatools
# reconstructed the exact same raw bytes from this target-files archive.
for image_name in "${firmware_image_files[@]}"; do
  if ! unzip -p "$images_zip" "$image_name" | \
      cmp -s - "$source_firmware_dir/$image_name"; then
    die "Frankel firmware differs between generated vendor and target-files: $image_name"
  fi
  install -m 0644 "$source_firmware_dir/$image_name" \
    "$staging_dir/$image_name"
done
for image_name in "${physical_os_image_files[@]}" \
    "${logical_image_files[@]}"; do
  unzip -p "$images_zip" "$image_name" > "$staging_dir/$image_name" || \
    die "failed to extract reconstructed Frankel image: $image_name"
  [[ -s "$staging_dir/$image_name" ]] || \
    die "reconstructed Frankel image is empty: $image_name"
  chmod 0644 "$staging_dir/$image_name"
  if ! unzip -p "$target_files" "IMAGES/$image_name" | \
      cmp -s - "$staging_dir/$image_name"; then
    die "reconstructed Frankel image differs from its attested target-files entry: $image_name"
  fi
  case "$image_name" in
    pvmfw.img|vbmeta.img|system.img|system_dlkm.img|system_ext.img|\
product.img|vendor.img|vendor_dlkm.img)
      # Releasetools re-footers these filesystem/AVB outputs. Their complete
      # staged set is authenticated together by the rebuilt root vbmeta below.
      continue
      ;;
  esac
  if ! cmp -s -- "$staging_dir/$image_name" "$product_out/$image_name"; then
    die "reconstructed Frankel image differs from the attested product output: $image_name"
  fi
done

# img_from_target_files deliberately rebuilds pvmfw's AVB footer at the fixed
# partition capacity and adds the build fingerprint. The attested product image
# is minimally padded, so the two containers cannot be byte-identical. Prove
# instead that the signed raw payload and hash descriptor are identical, and
# that the reconstructed footer has exactly the release-tools transformation
# pinned in META/misc_info.txt. The reconstructed image is the flash payload.
product_pvmfw="$product_out/pvmfw.img"
reconstructed_pvmfw="$staging_dir/pvmfw.img"
[[ -f "$product_pvmfw" && ! -L "$product_pvmfw" && \
   -s "$product_pvmfw" ]] || \
  die "attested Frankel product pvmfw image is missing, empty, or unsafe"
if ! unzip -p "$target_files" PREBUILT_IMAGES/pvmfw.img | \
    cmp -s - "$product_pvmfw"; then
  die "Frankel target-files pvmfw input differs from the attested product output"
fi
[[ $(stat -c %s -- "$reconstructed_pvmfw") == 1048576 ]] || \
  die "reconstructed Frankel pvmfw does not fill its 0x100000-byte partition"
"$avbtool" verify_image --image "$product_pvmfw" >/dev/null || \
  die "attested Frankel product pvmfw fails embedded AVB verification"
"$avbtool" verify_image --image "$reconstructed_pvmfw" >/dev/null || \
  die "reconstructed Frankel pvmfw fails embedded AVB verification"

product_pvmfw_info="$staging_dir/.product-pvmfw.info"
reconstructed_pvmfw_info="$staging_dir/.reconstructed-pvmfw.info"
"$avbtool" info_image --image "$product_pvmfw" > "$product_pvmfw_info" || \
  die "unable to inspect the attested Frankel product pvmfw"
"$avbtool" info_image --image "$reconstructed_pvmfw" > \
  "$reconstructed_pvmfw_info" || \
  die "unable to inspect the reconstructed Frankel pvmfw"

pvmfw_info_value() {
  local info_file=$1
  local key=$2
  local -a values=()
  mapfile -t values < <(
    awk -v prefix="$key:" \
      'index($0, prefix) == 1 {
         value = substr($0, length(prefix) + 1)
         sub(/^[[:space:]]+/, "", value)
         print value
       }' "$info_file"
  )
  (( ${#values[@]} == 1 )) || \
    die "pvmfw AVB metadata must contain exactly one $key field"
  [[ -n "${values[0]}" ]] || \
    die "pvmfw AVB metadata contains an empty $key field"
  printf '%s\n' "${values[0]}"
}

for info_file in "$product_pvmfw_info" "$reconstructed_pvmfw_info"; do
  [[ $(grep -c '^    Hash descriptor:$' "$info_file" || true) -eq 1 ]] || \
    die "pvmfw AVB metadata must contain exactly one hash descriptor"
  [[ $(grep -Ec '^    (Hashtree|Chain Partition|Kernel Cmdline) descriptor:$' \
        "$info_file" || true) -eq 0 ]] || \
    die "pvmfw AVB metadata contains an unexpected descriptor"
  [[ $(pvmfw_info_value "$info_file" Algorithm) == SHA256_RSA4096 ]] || \
    die "pvmfw AVB metadata has an unexpected signing algorithm"
  [[ $(pvmfw_info_value "$info_file" Flags) == 0 ]] || \
    die "pvmfw AVB metadata disables verification"
  [[ $(pvmfw_info_value "$info_file" 'Rollback Index') == 0 && \
     $(pvmfw_info_value "$info_file" 'Rollback Index Location') == 0 ]] || \
    die "pvmfw AVB metadata has unexpected rollback metadata"
done
[[ $(grep -Ec '^    [^[:space:]]' "$product_pvmfw_info" || true) -eq 1 ]] || \
  die "attested Frankel product pvmfw has an unexpected descriptor inventory"
[[ $(grep -Ec '^    [^[:space:]]' \
      "$reconstructed_pvmfw_info" || true) -eq 2 ]] || \
  die "reconstructed Frankel pvmfw has an unexpected descriptor inventory"

product_hash_descriptor=$(
  sed -n '/^    Hash descriptor:$/,/^      Flags:[[:space:]]/p' \
    "$product_pvmfw_info"
)
reconstructed_hash_descriptor=$(
  sed -n '/^    Hash descriptor:$/,/^      Flags:[[:space:]]/p' \
    "$reconstructed_pvmfw_info"
)
[[ -n "$product_hash_descriptor" && \
   "$product_hash_descriptor" == "$reconstructed_hash_descriptor" ]] || \
  die "reconstructed Frankel pvmfw hash descriptor differs from product output"

product_original_size_text=$(
  pvmfw_info_value "$product_pvmfw_info" 'Original image size'
)
reconstructed_original_size_text=$(
  pvmfw_info_value "$reconstructed_pvmfw_info" 'Original image size'
)
[[ "$product_original_size_text" =~ ^([1-9][0-9]*)\ bytes$ ]] || \
  die "attested Frankel product pvmfw has an invalid original image size"
pvmfw_original_size=${BASH_REMATCH[1]}
[[ "$reconstructed_original_size_text" == \
   "$product_original_size_text" ]] || \
  die "reconstructed Frankel pvmfw has a different raw payload size"
(( $(stat -c %s -- "$product_pvmfw") >= pvmfw_original_size )) || \
  die "attested Frankel product pvmfw is shorter than its raw payload"
cmp -s -n "$pvmfw_original_size" -- \
  "$product_pvmfw" "$reconstructed_pvmfw" || \
  die "reconstructed Frankel pvmfw raw payload differs from product output"

product_public_key=$(
  pvmfw_info_value "$product_pvmfw_info" 'Public key (sha1)'
)
reconstructed_public_key=$(
  pvmfw_info_value "$reconstructed_pvmfw_info" 'Public key (sha1)'
)
[[ "$product_public_key" =~ ^[0-9a-f]{40}$ && \
   "$reconstructed_public_key" == "$product_public_key" ]] || \
  die "reconstructed Frankel pvmfw uses a different embedded AVB public key"

[[ $(grep -c '^[[:space:]]*Prop:' "$product_pvmfw_info" || true) -eq 0 ]] || \
  die "attested Frankel product pvmfw unexpectedly contains an AVB property"
expected_pvmfw_prop="    Prop: com.android.build.pvmfw.fingerprint -> '$expected_pvmfw_fingerprint'"
[[ $(grep -c '^[[:space:]]*Prop:' "$reconstructed_pvmfw_info" || true) -eq 1 && \
   $(grep -Fxc -- "$expected_pvmfw_prop" \
      "$reconstructed_pvmfw_info" || true) -eq 1 ]] || \
  die "reconstructed Frankel pvmfw does not contain the exact build fingerprint"
[[ $(pvmfw_info_value "$reconstructed_pvmfw_info" 'Image size') == \
     '1048576 bytes' ]] || \
  die "reconstructed Frankel pvmfw AVB footer reports an unexpected image size"

for metadata_name in android-info.txt fastboot-info.txt; do
  unzip -p "$images_zip" "$metadata_name" > "$staging_dir/$metadata_name" || \
    die "failed to extract reconstructed Frankel metadata: $metadata_name"
  [[ -s "$staging_dir/$metadata_name" ]] || \
    die "reconstructed Frankel metadata is empty: $metadata_name"
  chmod 0644 "$staging_dir/$metadata_name"
done

# Frankel's generated AOSP target intentionally uses one root vbmeta instead
# of the three-image stock chain. Prove the positive topology: root vbmeta
# directly authenticates exactly six static OS payloads and six logical
# payloads, with no chain descriptor that could refer to an omitted child.
vbmeta_info="$staging_dir/.vbmeta.info"
(
  cd "$staging_dir"
  "$avbtool" verify_image --image vbmeta.img >/dev/null
) || die "Frankel root vbmeta does not authenticate the complete staged OS image set"
"$avbtool" info_image --image "$staging_dir/vbmeta.img" > "$vbmeta_info" || \
  die "reconstructed Frankel root vbmeta is invalid"
[[ $(grep -c '^[[:space:]]*Chain Partition descriptor:$' \
      "$vbmeta_info" || true) -eq 0 ]] || \
  die "Frankel root-only vbmeta unexpectedly contains a chain descriptor"
mapfile -t actual_vbmeta_partitions < <(
  sed -n 's/^[[:space:]]*Partition Name:[[:space:]]*//p' \
    "$vbmeta_info" | sort
)
expected_vbmeta_partitions=(
  boot dtbo init_boot product pvmfw system system_dlkm system_ext vendor
  vendor_boot vendor_dlkm vendor_kernel_boot
)
mapfile -t expected_vbmeta_partitions_sorted < <(
  printf '%s\n' "${expected_vbmeta_partitions[@]}" | sort
)
[[ "${actual_vbmeta_partitions[*]}" == \
   "${expected_vbmeta_partitions_sorted[*]}" ]] || \
  die "Frankel root vbmeta does not directly describe the exact 12-image OS set"
[[ $(sed -n 's/^Algorithm:[[:space:]]*//p' "$vbmeta_info") == \
      SHA256_RSA4096 ]] || \
  die "Frankel root vbmeta does not use the expected RSA-4096 algorithm"
[[ $(sed -n 's/^Flags:[[:space:]]*//p' "$vbmeta_info") == 0 ]] || \
  die "Frankel root vbmeta disables AVB verification or hashtrees"
[[ $(pvmfw_info_value "$vbmeta_info" 'Public key (sha1)') == \
     "$reconstructed_public_key" ]] || \
  die "Frankel root vbmeta and pvmfw use different embedded AVB public keys"

board_requirement=$(
  sed -n 's/^require board=//p' "$staging_dir/android-info.txt"
)
[[ $(grep -c '^require board=' "$staging_dir/android-info.txt") -eq 1 && \
   "|$board_requirement|" == *'|frankel|'* ]] || \
  die "reconstructed android-info.txt does not identify Frankel"
bootloader_requirement=$(
  sed -n 's/^require version-bootloader=//p' \
    "$staging_dir/android-info.txt"
)
baseband_requirement=$(
  sed -n 's/^require version-baseband=//p' \
    "$staging_dir/android-info.txt"
)
[[ $(grep -c '^require version-bootloader=' \
      "$staging_dir/android-info.txt") -eq 1 && \
   "$bootloader_requirement" == "$EXPECTED_BOOTLOADER_VERSION" ]] || \
  die "reconstructed android-info.txt has the wrong Frankel bootloader requirement"
[[ $(grep -c '^require version-baseband=' \
      "$staging_dir/android-info.txt") -eq 1 && \
   "$baseband_requirement" == "$EXPECTED_BASEBAND_VERSION" ]] || \
  die "reconstructed android-info.txt has the wrong Frankel baseband requirement"
if grep -Eq '(^|[[:space:]])vbmeta_(system|vendor)([[:space:]]|$)' \
    "$staging_dir/fastboot-info.txt"; then
  die "Frankel root-only fastboot-info unexpectedly references child vbmeta"
fi

runner="$script_dir/flash-frankel.sh"
[[ -f "$runner" && ! -L "$runner" && -x "$runner" ]] || \
  die "reviewed Frankel flash runner is missing or unsafe: $runner"
bash -n "$runner" || die "reviewed Frankel flash runner has invalid syntax"
runner_fastboot_version=$(sed -n \
  's/^expected_fastboot_version=//p' "$runner")
runner_fastboot_sha256=$(sed -n \
  's/^expected_fastboot_sha256=//p' "$runner")
runner_bootloader_version=$(sed -n \
  's/^expected_bootloader_version=//p' "$runner")
runner_baseband_version=$(sed -n \
  's/^expected_baseband_version=//p' "$runner")
[[ $(grep -c '^expected_fastboot_version=' "$runner") -eq 1 && \
   $(grep -c '^expected_fastboot_sha256=' "$runner") -eq 1 && \
   $(grep -c '^expected_bootloader_version=' "$runner") -eq 1 && \
   $(grep -c '^expected_baseband_version=' "$runner") -eq 1 && \
   "$runner_fastboot_version" == "$PLATFORM_TOOLS_VERSION" && \
   "$runner_fastboot_sha256" == "$PLATFORM_TOOLS_FASTBOOT_SHA256" && \
   "$runner_bootloader_version" == "$EXPECTED_BOOTLOADER_VERSION" && \
   "$runner_baseband_version" == "$EXPECTED_BASEBAND_VERSION" ]] || \
  die "reviewed Frankel flash runner literals differ from the selected release pins"
install -m 0755 "$runner" "$staging_dir/flash-all.sh"
install -m 0644 "$build_attestation" \
  "$staging_dir/BUILD_ATTESTATION.txt"
printf 'device\n' > "$staging_dir/bundle-kind"

target_files_sha256=$(sha256sum "$target_files" | awk '{print $1}')
build_attestation_sha256=$(
  sha256sum "$build_attestation" | awk '{print $1}'
)
android_info_sha256=$(
  sha256sum "$staging_dir/android-info.txt" | awk '{print $1}'
)
fastboot_info_sha256=$(
  sha256sum "$staging_dir/fastboot-info.txt" | awk '{print $1}'
)
{
  printf 'bundle_schema=pixel-aosp-flash-bundle-v2\n'
  printf 'bundle_kind=device\n'
  printf 'device=frankel\n'
  printf 'platform=laguna\n'
  printf 'marketing_name=Pixel 10\n'
  printf 'product_target=%s\n' "$DEVICE_PRODUCT_TARGET"
  printf 'aosp_revision=%s\n' "$AOSP_REVISION"
  printf 'source_aosp_build_id=%s\n' "$AOSP_BUILD_ID"
  printf 'output_build_id=%s\n' "$STOCK_BUILD_ID"
  printf 'framework_security_patch=%s\n' "$AOSP_SECURITY_PATCH"
  printf 'build_variant=userdebug\n'
  printf 'required_platform_tools_fastboot=%s\n' "$PLATFORM_TOOLS_VERSION"
  printf 'required_platform_tools_fastboot_sha256=%s\n' \
    "$PLATFORM_TOOLS_FASTBOOT_SHA256"
  printf 'required_bootloader=%s\n' "$bootloader_requirement"
  printf 'required_baseband=%s\n' "$baseband_requirement"
  printf 'target_files_name=%s\n' "${target_files##*/}"
  printf 'target_files_sha256=%s\n' "$target_files_sha256"
  printf 'build_attestation_sha256=%s\n' "$build_attestation_sha256"
  printf 'android_info_sha256=%s\n' "$android_info_sha256"
  printf 'fastboot_info_sha256=%s\n' "$fastboot_info_sha256"
  printf 'super_partition_size=8531214336\n'
  printf 'dynamic_partition_group_size=8527020032\n'
  printf 'firmware_image_count=23\n'
  printf 'physical_os_image_count=7\n'
  printf 'logical_image_count=6\n'
  printf 'total_image_count=36\n'
  printf 'avb_topology=laguna-root-vbmeta-no-child-vbmeta-images\n'
} > "$staging_dir/BUNDLE_INFO.txt"
chmod 0644 "$staging_dir/BUNDLE_INFO.txt" "$staging_dir/bundle-kind"

rm -f -- "$target_entries" "$image_entries" "$images_zip" "$vbmeta_info" \
  "$product_pvmfw_info" "$reconstructed_pvmfw_info"

manifest_files=(
  bundle-kind
  BUNDLE_INFO.txt
  BUILD_ATTESTATION.txt
  android-info.txt
  fastboot-info.txt
  flash-all.sh
  "${image_files[@]}"
)
(
  cd "$staging_dir"
  sha256sum "${manifest_files[@]}" > SHA256SUMS
  sha256sum --check --strict SHA256SUMS
)
chmod 0644 "$staging_dir/SHA256SUMS"

artifacts_root="$project_root/artifacts"
frankel_artifacts_root="$artifacts_root/frankel"
bundle_dir="$frankel_artifacts_root/device"
assert_inside_project "$artifacts_root"
assert_inside_project "$frankel_artifacts_root"
assert_inside_project "$bundle_dir"
for directory in "$artifacts_root" "$frankel_artifacts_root"; do
  [[ ! -L "$directory" ]] || \
    die "artifact directory must not be a symbolic link: $directory"
  mkdir -p "$directory"
  [[ -d "$directory" && ! -L "$directory" ]] || \
    die "artifact path is not a real directory: $directory"
done
if [[ -e "$bundle_dir" || -L "$bundle_dir" ]]; then
  [[ -d "$bundle_dir" && ! -L "$bundle_dir" ]] || \
    die "Frankel bundle destination is not a real directory"
else
  mkdir "$bundle_dir"
fi

declare -A allowed_bundle_entries=([SHA256SUMS]=1)
for name in "${manifest_files[@]}"; do
  allowed_bundle_entries["$name"]=1
done
mapfile -d '' -t existing_entries < <(
  find "$bundle_dir" -mindepth 1 -maxdepth 1 -printf '%f\0' | sort -z
)
for name in "${existing_entries[@]}"; do
  [[ -n ${allowed_bundle_entries[$name]+present} ]] || \
    die "refusing to replace Frankel bundle containing unexpected entry: $name"
  [[ -f "$bundle_dir/$name" && ! -L "$bundle_dir/$name" ]] || \
    die "refusing to replace unsafe Frankel bundle entry: $name"
done

# SHA256SUMS is the publication marker. Withdraw it before replacing any
# payload so an interrupted publication cannot look complete.
rm -f -- "$bundle_dir/SHA256SUMS"
for name in "${manifest_files[@]}"; do
  if [[ "$name" == flash-all.sh ]]; then
    install -m 0755 "$staging_dir/$name" "$bundle_dir/$name"
  else
    install -m 0644 "$staging_dir/$name" "$bundle_dir/$name"
  fi
done
install -m 0644 "$staging_dir/SHA256SUMS" "$bundle_dir/SHA256SUMS"
(
  cd "$bundle_dir"
  sha256sum --check --strict SHA256SUMS
)

note "Frankel userdebug device flash bundle: $bundle_dir"
note "bundle contains 23 Laguna firmware, 7 physical OS, and 6 logical images"
