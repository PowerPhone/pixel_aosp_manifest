#!/usr/bin/env bash

# Validate the narrow cubs Wi-Fi VINTF ownership rewrite. Callers must source
# lib/common.sh first so die() is available.

validate_cubs_wifi_vintf_soong_installs() {
  local source_dir=$1
  local out_dir=$2
  local installs relative_out destination expected fragment module_path
  local -a rules=()
  local -a fragments=(
    android.hardware.wifi.hostapd.xml
    android.hardware.wifi.supplicant.xml
  )
  local -a module_paths=(
    external/wpa_supplicant_8/hostapd/android.hardware.wifi.hostapd.xml
    external/wpa_supplicant_8/wpa_supplicant/aidl/android.hardware.wifi.supplicant.xml
  )
  local index

  [[ -d "$source_dir" && ! -L "$source_dir" ]] || \
    die "AOSP source directory is missing or unsafe for cubs Wi-Fi VINTF validation"
  [[ -d "$out_dir" && ! -L "$out_dir" ]] || \
    die "cubs output directory is missing or unsafe for Wi-Fi VINTF validation"
  source_dir=$(realpath -e -- "$source_dir")
  out_dir=$(realpath -e -- "$out_dir")
  case "$out_dir" in
    "$source_dir"/*) ;;
    *) die "cubs output directory escapes the AOSP source tree" ;;
  esac
  relative_out=$(realpath --relative-to="$source_dir" -- "$out_dir")
  installs="$out_dir/soong/installs-cubs.mk"
  [[ -f "$installs" && ! -L "$installs" && -s "$installs" ]] || \
    die "cubs Soong install manifest is missing, empty, or unsafe"

  for index in "${!fragments[@]}"; do
    fragment=${fragments[$index]}
    module_path=${module_paths[$index]}
    destination="$relative_out/target/product/cubs/vendor/etc/vintf/manifest/$fragment"
    mapfile -t rules < <(
      awk -v prefix="$destination:" \
        'index($0, prefix) == 1 { print }' "$installs"
    )
    (( ${#rules[@]} == 1 )) || \
      die "expected exactly one cubs Soong install rule for $fragment; found ${#rules[@]}"
    expected="$destination: $relative_out/soong/.intermediates/$module_path/android_common/$fragment"
    [[ "${rules[0]}" == "$expected" ]] || \
      die "cubs Wi-Fi VINTF install rule is not owned by the pinned AOSP module: $fragment"
  done
}

validate_cubs_wifi_vintf_target_files() {
  local target_files=$1
  local output_name=$2
  local -n result=$output_name
  local fragment canonical entry digest key index canonical_count basename_count
  local -a entries=()
  local -a fragments=(
    android.hardware.wifi.hostapd.xml
    android.hardware.wifi.supplicant.xml
  )
  # Soong owns both inputs through the exact AOSP modules checked above, then
  # assemble_vintf records the input path and normalizes the manifest schema
  # version to the current device-manifest version. Pin those installed bytes,
  # not the pre-assembly source bytes.
  local -a expected_installed_sha256=(
    2bb8b7148536575a9022ad2bb008a02ed2f0fbcec341b0efbbc5f59e470e8881
    d8dce6d4a6f9ecd85b1d8b3bf59a545bd7ac92bd84038c81c3e3876364c9190c
  )
  local -a keys=(
    wifi_hostapd_vendor_manifest_sha256
    wifi_supplicant_vendor_manifest_sha256
  )

  [[ -f "$target_files" && ! -L "$target_files" && -s "$target_files" ]] || \
    die "cubs target-files package is missing, empty, or unsafe"
  unzip -tq "$target_files" >/dev/null || die "invalid cubs target-files ZIP"
  mapfile -t entries < <(unzip -Z1 "$target_files")
  (( ${#entries[@]} > 0 )) || die "cubs target-files ZIP has no entries"

  result=()
  for index in "${!fragments[@]}"; do
    fragment=${fragments[$index]}
    canonical="VENDOR/etc/vintf/manifest/$fragment"
    key=${keys[$index]}
    canonical_count=0
    basename_count=0
    for entry in "${entries[@]}"; do
      [[ "$entry" == "$canonical" ]] && ((canonical_count += 1))
      [[ "${entry##*/}" == "$fragment" ]] && ((basename_count += 1))
    done
    (( canonical_count == 1 )) || \
      die "expected exactly one canonical cubs target-files Wi-Fi VINTF entry for $fragment; found $canonical_count"
    (( basename_count == 1 )) || \
      die "cubs target-files contains an alternate or duplicate Wi-Fi VINTF entry: $fragment"
    digest=$(unzip -p "$target_files" "$canonical" | sha256sum)
    digest=${digest%% *}
    [[ "$digest" == "${expected_installed_sha256[$index]}" ]] || \
      die "cubs target-files Wi-Fi VINTF entry is not the pinned assembled AOSP fragment: $fragment"
    # shellcheck disable=SC2034 # returned to the caller through the nameref
    result["$key"]=$digest
  done
}
