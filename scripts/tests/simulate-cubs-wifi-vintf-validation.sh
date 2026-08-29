#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
# shellcheck source=../lib/common.sh disable=SC1091
source "$project_root/scripts/lib/common.sh"
# shellcheck source=../lib/cubs-wifi-vintf.sh disable=SC1091
source "$project_root/scripts/lib/cubs-wifi-vintf.sh"

require_command cp expand grep mkdir mktemp rm sed sha256sum unzip zip

scratch_parent="$project_root/work/wifi-vintf-validation-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

fixture_source="$scratch_dir/source"
fixture_out="$fixture_source/out_pixel/cubs"
fixture_tree="$scratch_dir/target-files"
fixture_zip="$scratch_dir/cubs-target_files.zip"
installs="$fixture_out/soong/installs-cubs.mk"
hostapd_source="$project_root/work/aosp/external/wpa_supplicant_8/hostapd/android.hardware.wifi.hostapd.xml"
supplicant_source="$project_root/work/aosp/external/wpa_supplicant_8/wpa_supplicant/aidl/android.hardware.wifi.supplicant.xml"

write_assembled_fragment() {
  local input_path=$1
  local source_file=$2
  local output_file=$3
  {
    printf '%s\n' '<!--' '    Input:' "        $input_path" '-->'
    sed 's/<manifest version="1\.0"/<manifest version="9.0"/' \
      "$source_file" | expand -t 4
  } >"$output_file"
}

pack_fixture() {
  rm -f -- "$fixture_zip"
  (
    cd "$fixture_tree"
    zip -q -r "$fixture_zip" VENDOR
  )
}

make_fixture() {
  rm -rf -- "$fixture_source" "$fixture_tree"
  mkdir -p "$fixture_out/soong" \
    "$fixture_tree/VENDOR/etc/vintf/manifest"
  printf '%s\n' \
    'out_pixel/cubs/target/product/cubs/vendor/etc/vintf/manifest/android.hardware.wifi.hostapd.xml: out_pixel/cubs/soong/.intermediates/external/wpa_supplicant_8/hostapd/android.hardware.wifi.hostapd.xml/android_common/android.hardware.wifi.hostapd.xml' \
    'out_pixel/cubs/target/product/cubs/vendor/etc/vintf/manifest/android.hardware.wifi.supplicant.xml: out_pixel/cubs/soong/.intermediates/external/wpa_supplicant_8/wpa_supplicant/aidl/android.hardware.wifi.supplicant.xml/android_common/android.hardware.wifi.supplicant.xml' \
    >"$installs"
  write_assembled_fragment \
    external/wpa_supplicant_8/hostapd/android.hardware.wifi.hostapd.xml \
    "$hostapd_source" \
    "$fixture_tree/VENDOR/etc/vintf/manifest/android.hardware.wifi.hostapd.xml"
  write_assembled_fragment \
    external/wpa_supplicant_8/wpa_supplicant/aidl/android.hardware.wifi.supplicant.xml \
    "$supplicant_source" \
    "$fixture_tree/VENDOR/etc/vintf/manifest/android.hardware.wifi.supplicant.xml"
  pack_fixture
}

expect_soong_failure() {
  local description=$1
  local expected_message=$2
  local log="$scratch_dir/${description//[^a-zA-Z0-9]/-}.log"
  if (validate_cubs_wifi_vintf_soong_installs \
      "$fixture_source" "$fixture_out") >"$log" 2>&1; then
    die "$description unexpectedly passed"
  fi
  grep -Fq -- "$expected_message" "$log" || {
    sed -n '1,120p' "$log" >&2
    die "$description failed for an unexpected reason"
  }
}

expect_target_failure() {
  local description=$1
  local expected_message=$2
  local log="$scratch_dir/${description//[^a-zA-Z0-9]/-}.log"
  if (
    # shellcheck disable=SC2034 # populated through the helper's nameref
    declare -A hashes=()
    validate_cubs_wifi_vintf_target_files "$fixture_zip" hashes
  ) >"$log" 2>&1; then
    die "$description unexpectedly passed"
  fi
  grep -Fq -- "$expected_message" "$log" || {
    sed -n '1,120p' "$log" >&2
    die "$description failed for an unexpected reason"
  }
}

make_fixture
validate_cubs_wifi_vintf_soong_installs "$fixture_source" "$fixture_out"
declare -A positive_hashes=()
validate_cubs_wifi_vintf_target_files "$fixture_zip" positive_hashes
[[ "${positive_hashes[wifi_hostapd_vendor_manifest_sha256]}" == \
   2bb8b7148536575a9022ad2bb008a02ed2f0fbcec341b0efbbc5f59e470e8881 ]] || \
  die "positive hostapd target-files hash is incorrect"
[[ "${positive_hashes[wifi_supplicant_vendor_manifest_sha256]}" == \
   d8dce6d4a6f9ecd85b1d8b3bf59a545bd7ac92bd84038c81c3e3876364c9190c ]] || \
  die "positive supplicant target-files hash is incorrect"

make_fixture
printf '%s\n' \
  'out_pixel/cubs/target/product/cubs/vendor/etc/vintf/manifest/android.hardware.wifi.hostapd.xml: out_pixel/cubs/soong/.intermediates/vendor/google_devices/cubs/vintf/vendor/manifest/adevtool_vintf_fragment_vendor_android.hardware.wifi.hostapd.xml/android_common/android.hardware.wifi.hostapd.xml' \
  >>"$installs"
expect_soong_failure duplicate-rule \
  'expected exactly one cubs Soong install rule for android.hardware.wifi.hostapd.xml; found 2'

make_fixture
sed -i \
  's|external/wpa_supplicant_8/hostapd/android.hardware.wifi.hostapd.xml|vendor/google_devices/cubs/generated-hostapd|' \
  "$installs"
expect_soong_failure wrong-owner \
  'cubs Wi-Fi VINTF install rule is not owned by the pinned AOSP module: android.hardware.wifi.hostapd.xml'

make_fixture
sed -i '/vendor\/etc\/vintf\/manifest\/android.hardware.wifi.hostapd.xml:/d' \
  "$installs"
expect_soong_failure missing-rule \
  'expected exactly one cubs Soong install rule for android.hardware.wifi.hostapd.xml; found 0'

make_fixture
sed -i \
  '/vendor\/etc\/vintf\/manifest\/android.hardware.wifi.hostapd.xml:/s/$/ unexpected-extra-prerequisite/' \
  "$installs"
expect_soong_failure extra-prerequisite \
  'cubs Wi-Fi VINTF install rule is not owned by the pinned AOSP module: android.hardware.wifi.hostapd.xml'

make_fixture
rm -f -- \
  "$fixture_tree/VENDOR/etc/vintf/manifest/android.hardware.wifi.hostapd.xml"
pack_fixture
expect_target_failure missing-canonical \
  'expected exactly one canonical cubs target-files Wi-Fi VINTF entry for android.hardware.wifi.hostapd.xml; found 0'

make_fixture
printf '%s\n' 'not the pinned AOSP hostapd fragment' > \
  "$fixture_tree/VENDOR/etc/vintf/manifest/android.hardware.wifi.hostapd.xml"
pack_fixture
expect_target_failure wrong-hash \
  'cubs target-files Wi-Fi VINTF entry is not the pinned assembled AOSP fragment: android.hardware.wifi.hostapd.xml'

make_fixture
mkdir -p "$fixture_tree/PRODUCT/etc/vintf/manifest"
cp "$hostapd_source" \
  "$fixture_tree/PRODUCT/etc/vintf/manifest/android.hardware.wifi.hostapd.xml"
(
  cd "$fixture_tree"
  zip -q -r "$fixture_zip" VENDOR PRODUCT
)
expect_target_failure alternate-basename \
  'cubs target-files contains an alternate or duplicate Wi-Fi VINTF entry: android.hardware.wifi.hostapd.xml'

printf '%s\n' \
  'mocked cubs Wi-Fi VINTF ownership/install/target-files validation passed'
