#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$script_dir/lib/common.sh"

require_command awk cat cmp cp dd grep mkdir mktemp rm sed sha256sum stat xxd

# Exercise the exact helper implementations used by package-device.sh without
# running its build-attestation and publishing mainline.
# shellcheck disable=SC1090
source <(
  sed -n '/^file_sha256()/,/^source_dir=/p' \
    "$script_dir/package-device.sh" | sed '$d'
)

out_dir=${DEVICE_OUT_DIR:-"$project_root/work/aosp/out_pixel/cubs"}
avbtool="$out_dir/host/linux-x86/bin/avbtool"
[[ -x "$avbtool" ]] || die "built avbtool is required for carrier tests"

firmware_descriptor_partitions=(
  abl bl31 cap cpm dbc dbl
  dram_init_0 dram_init_1 dram_init_10 dram_init_11
  dram_init_2 dram_init_3 dram_init_4 dram_init_5 dram_init_6 dram_init_7
  dram_init_8 dram_init_9 dram_phy gc gdmc gsa_bl1 gsa_fw tzsw
)
firmware_carrier_images=()
for partition in "${firmware_descriptor_partitions[@]}"; do
  firmware_carrier_images+=("${partition}_vbfooted.img")
done

test_parent="$project_root/work/firmware-carrier-tests"
mkdir -p "$test_parent"
test_dir=$(mktemp -d "$test_parent/.mock.XXXXXX")
cleanup() {
  if [[ -n "${test_dir:-}" && -d "$test_dir" && \
        "$test_dir" == "$test_parent"/.mock.* ]]; then
    rm -rf -- "$test_dir"
  fi
}
trap cleanup EXIT

expect_failure() {
  local description=$1
  shift
  if ("$@" >"$test_dir/expected-failure.log" 2>&1); then
    die "$description unexpectedly passed"
  fi
}

carrier_misc() {
  local image
  printf 'avb_vbmeta_args='
  for image in "${firmware_carrier_images[@]}"; do
    printf '%s' "--include_descriptors_from_image out/mock/$image "
  done
  printf '%s\n' '--padding_size 4096 --rollback_index 1780617600'
}

valid_misc=$(carrier_misc)
validate_vbmeta_carrier_args "$valid_misc"
missing_misc=${valid_misc/--include_descriptors_from_image out\/mock\/abl_vbfooted.img /}
expect_failure "missing carrier argument" \
  validate_vbmeta_carrier_args "$missing_misc"
extra_misc="${valid_misc%$'\n'} --include_descriptors_from_image out/mock/extra_vbfooted.img"
expect_failure "extra carrier argument" \
  validate_vbmeta_carrier_args "$extra_misc"
renamed_misc=${valid_misc/abl_vbfooted.img/able_vbfooted.img}
expect_failure "renamed carrier argument" \
  validate_vbmeta_carrier_args "$renamed_misc"
reordered_misc=${valid_misc/abl_vbfooted.img/temporary_vbfooted.img}
reordered_misc=${reordered_misc/bl31_vbfooted.img/abl_vbfooted.img}
reordered_misc=${reordered_misc/temporary_vbfooted.img/bl31_vbfooted.img}
expect_failure "reordered carrier arguments" \
  validate_vbmeta_carrier_args "$reordered_misc"

reject_firmware_carrier_leaks $'boot.img\nsystem.img' "mock image ZIP"
expect_failure "leaked carrier" reject_firmware_carrier_leaks \
  $'boot.img\nRADIO/abl_vbfooted.img' "mock image ZIP"

expected_salt="$(literal_sha256 "$AOSP_BUILD_NUMBER")$(literal_sha256 "$AOSP_BUILD_DATETIME")"
valid_dir="$test_dir/valid"
mkdir -p "$valid_dir"
printf '%s' 'pixel-aosp-firmware-carrier-fixture' >"$valid_dir/abl.img"
cp -- "$valid_dir/abl.img" "$valid_dir/abl_vbfooted.img"
raw_size=$(stat -c '%s' "$valid_dir/abl.img")
carrier_size=$((69632 + ((raw_size + 4095) / 4096) * 4096))
"$avbtool" add_hash_footer \
  --image "$valid_dir/abl_vbfooted.img" \
  --partition_name abl \
  --partition_size "$carrier_size" \
  --salt "$expected_salt"
validate_firmware_carrier \
  abl "$valid_dir/abl.img" "$valid_dir/abl_vbfooted.img" "$expected_salt" \
  "$valid_dir/abl.info" "$valid_dir/abl.verify.log"

malformed_dir="$test_dir/malformed"
mkdir -p "$malformed_dir"
cp -- "$valid_dir/abl.img" "$malformed_dir/abl.img"
cp -- "$valid_dir/abl_vbfooted.img" "$malformed_dir/abl_vbfooted.img"
printf X | dd conv=notrunc of="$malformed_dir/abl_vbfooted.img" \
  status=none
expect_failure "malformed carrier payload" validate_firmware_carrier \
  abl "$malformed_dir/abl.img" "$malformed_dir/abl_vbfooted.img" \
  "$expected_salt" "$malformed_dir/abl.info" \
  "$malformed_dir/abl.verify.log"

wrong_salt_dir="$test_dir/wrong-salt"
mkdir -p "$wrong_salt_dir"
cp -- "$valid_dir/abl.img" "$wrong_salt_dir/abl.img"
cp -- "$valid_dir/abl.img" "$wrong_salt_dir/abl_vbfooted.img"
wrong_salt=$(printf '00%.0s' {1..64})
"$avbtool" add_hash_footer \
  --image "$wrong_salt_dir/abl_vbfooted.img" \
  --partition_name abl \
  --partition_size "$carrier_size" \
  --salt "$wrong_salt"
expect_failure "wrong carrier salt" validate_firmware_carrier \
  abl "$wrong_salt_dir/abl.img" "$wrong_salt_dir/abl_vbfooted.img" \
  "$expected_salt" "$wrong_salt_dir/abl.info" \
  "$wrong_salt_dir/abl.verify.log"

# Repeat the contract against validate-images.sh's independent implementation.
# shellcheck disable=SC1090
source <(
  sed -n '/^require_value()/,/^kv_from_text()/p' \
    "$script_dir/validate-images.sh" | sed '$d'
)
# Referenced by functions loaded dynamically above.
# shellcheck disable=SC2034
cubs_firmware_carrier_images=("${firmware_carrier_images[@]}")
# shellcheck disable=SC2034
avbtool_command=("$avbtool")
validate_vbmeta_firmware_carrier_args "$valid_misc"
expect_failure "validator missing carrier argument" \
  validate_vbmeta_firmware_carrier_args "$missing_misc"
expect_failure "validator extra carrier argument" \
  validate_vbmeta_firmware_carrier_args "$extra_misc"
expect_failure "validator renamed carrier argument" \
  validate_vbmeta_firmware_carrier_args "$renamed_misc"
expect_failure "validator reordered carrier arguments" \
  validate_vbmeta_firmware_carrier_args "$reordered_misc"
reject_firmware_carrier_leaks $'boot.img\nsystem.img' "mock image ZIP"
expect_failure "validator leaked carrier" reject_firmware_carrier_leaks \
  $'boot.img\nRADIO/abl_vbfooted.img' "mock image ZIP"
validate_firmware_carrier \
  abl "$valid_dir/abl.img" "$valid_dir/abl_vbfooted.img" "$expected_salt" \
  "$valid_dir/validator-abl.info" "$valid_dir/validator-abl.verify.log"
expect_failure "validator malformed carrier payload" validate_firmware_carrier \
  abl "$malformed_dir/abl.img" "$malformed_dir/abl_vbfooted.img" \
  "$expected_salt" "$malformed_dir/validator-abl.info" \
  "$malformed_dir/validator-abl.verify.log"
expect_failure "validator wrong carrier salt" validate_firmware_carrier \
  abl "$wrong_salt_dir/abl.img" "$wrong_salt_dir/abl_vbfooted.img" \
  "$expected_salt" "$wrong_salt_dir/validator-abl.info" \
  "$wrong_salt_dir/validator-abl.verify.log"

note "firmware descriptor-carrier allowlist and AVB mutation tests passed"
