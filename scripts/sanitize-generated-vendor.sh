#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
# shellcheck source=lib/cubs-sepolicy.sh disable=SC1091
source "$script_dir/lib/cubs-sepolicy.sh"
# shellcheck source=lib/cubs-fstab.sh disable=SC1091
source "$script_dir/lib/cubs-fstab.sh"

require_pixel_target cubs "the cubs/Malibu generated-vendor sanitizer"

check_only=false
if [[ "${1:-}" == --check ]]; then
  check_only=true
elif [[ $# -ne 0 ]]; then
  die "usage: $0 [--check]"
fi

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
assert_inside_work "$source_dir"
policy_file="$source_dir/vendor/google_devices/$DEVICE_CODENAME/sepolicy/system_ext/public/types.te"
require_file "$policy_file"
board_config="$source_dir/vendor/google_devices/$DEVICE_CODENAME/BoardConfig.mk"
require_file "$board_config"
generated_dir="$source_dir/vendor/google_devices/$DEVICE_CODENAME"
product_makefile="$generated_dir/$DEVICE_CODENAME.mk"
manifest_bp="$generated_dir/vintf/vendor/manifest/Android.bp"
product_matrix="$generated_dir/vintf/product/compatibility_matrix.xml"
require_file "$product_makefile"
require_file "$manifest_bp"
require_file "$product_matrix"

# Adevtool deliberately collapses every named fstab AVB dependency to the root
# vbmeta partition. That is incompatible with the stock-shaped cubs chain
# reconstructed by the reviewed board patch: first-stage mount must request
# the same boot/init_boot/vbmeta_system/vbmeta_vendor child devices that root
# vbmeta chains. Keep generator verification immutable, then restore only the
# exact hash-pinned mappings in both installed copies.
fstab_vendor_ramdisk="$generated_dir/proprietary/vendor_ramdisk/system/etc/fstab.malibu"
fstab_vendor="$generated_dir/proprietary/vendor/etc/fstab.malibu"
sanitize_cubs_fstab_avb_mapping \
  "$fstab_vendor_ramdisk" \
  "$CUBS_ADEVTOOL_FSTAB_SHA256" \
  "$CUBS_CHAINED_AVB_FSTAB_SHA256" \
  "$check_only" \
  "generated vendor-ramdisk fstab.malibu"
sanitize_cubs_fstab_avb_mapping \
  "$fstab_vendor" \
  "$CUBS_ADEVTOOL_FSTAB_SHA256" \
  "$CUBS_CHAINED_AVB_FSTAB_SHA256" \
  "$check_only" \
  "generated vendor fstab.malibu"
cmp -s -- "$fstab_vendor_ramdisk" "$fstab_vendor" || \
  die "generated cubs fstab.malibu copies are not byte-identical"
note "restored exact cubs child AVB mappings in both generated fstab copies"

# The extracted stock extension redundantly carries AOSP's standard
# vndservicemanager transfer rule. Adevtool renames the stock rule's generated
# base_typeattr, so its versioned complement is opaque to the final platform
# mapping and incorrectly includes init/vendor_init. Keep the native AOSP rule,
# whose source-level exclusions compile correctly, and remove only the exact
# duplicate allow plus its now-orphaned synthetic attribute. This runs after
# adevtool has verified the pristine files against its immutable FileTreeSpec.
aosp_vndservicemanager_policy="$source_dir/system/sepolicy/vendor/vndservicemanager.te"
require_file "$aosp_vndservicemanager_policy"
verify_sha256 \
  a05e6b283358012ed5b9648087bacd52a1882d4cd34b66fcd3661c5904840954 \
  "$aosp_vndservicemanager_policy"
aosp_transfer_rule='allow vndservicemanager { domain -coredomain -init -vendor_init }:binder transfer;'
aosp_transfer_rule_count=$(grep -Fxc \
  "$aosp_transfer_rule" "$aosp_vndservicemanager_policy" || true)
(( aosp_transfer_rule_count == 1 )) || \
  die "pinned AOSP vndservicemanager transfer owner is missing or duplicated"

generated_vendor_policy="$generated_dir/sepolicy/vendor/sepolicy_ext.cil"
generated_recovery_policy="$generated_dir/sepolicy/vendor/sepolicy_ext_recovery.cil"
sanitize_cubs_redundant_vndservicemanager_rule \
  "$generated_vendor_policy" \
  264d0a0163faa9d25db27deb122ebeb1531e7abb557803c058ae35b6cb28b3a3 \
  489a051bda685a8df7e22faad50e69b95a75a242b181f4d6842c356e5b83a1ce \
  _202604 \
  "$check_only"
sanitize_cubs_redundant_vndservicemanager_rule \
  "$generated_recovery_policy" \
  26f2481cf9f34f3da6f0414277b1acf52f751f727710ea74f9fffd50d3bb554d \
  d408d44571460cec23fefa1d396f229833905889cdd204a4253b0d4ba3185026 \
  '' \
  "$check_only"
note "verified native AOSP ownership of the sanitized vndservicemanager transfer rule"

declarations=(
  'type preloads_copy, domain, coredomain;'
  'type system_server_startup, domain, coredomain;'
  'type preloads_copy_exec, file_type, exec_type, system_file_type;'
  'type system_server_startup_tmpfs, file_type;'
)

present=0
for declaration in "${declarations[@]}"; do
  count=$(grep -Fxc "$declaration" "$policy_file" || true)
  (( count <= 1 )) || die "duplicate compatibility declaration: $declaration"
  present=$((present + count))
done

if (( present == 0 )); then
  note "generated SELinux compatibility filter already applied"
else
  (( present == ${#declarations[@]} )) || \
    die "generated SELinux policy is only partially sanitized"
  [[ "$check_only" == false ]] || \
    die "generated SELinux compatibility filter has not been applied"

  for declaration in "${declarations[@]}"; do
    sed -i "\\|^${declaration}$|d" "$policy_file"
  done

  for declaration in "${declarations[@]}"; do
    ! grep -Fxq "$declaration" "$policy_file" || \
      die "failed to remove compatibility declaration: $declaration"
  done
  note "removed four declarations already provided by pristine AOSP sepolicy"
fi

# Adevtool emits these broad bring-up escapes for every generated device. Do
# not silently weaken AOSP's SELinux neverallow enforcement or permit duplicate
# build rules in a release candidate; strict compilation must expose each real
# incompatibility so it can be fixed narrowly.
bringup_exceptions=(
  'SELINUX_IGNORE_NEVERALLOWS := true'
  'BUILD_BROKEN_DUP_RULES := true'
)
present_exceptions=0
for exception in "${bringup_exceptions[@]}"; do
  count=$(grep -Fxc "$exception" "$board_config" || true)
  (( count <= 1 )) || die "duplicate bring-up exception: $exception"
  present_exceptions=$((present_exceptions + count))
done
(( present_exceptions == 0 || \
   present_exceptions == ${#bringup_exceptions[@]} )) || \
  die "generated BoardConfig bring-up exceptions are only partially sanitized"
if (( present_exceptions > 0 )); then
  [[ "$check_only" == false ]] || \
    die "generated BoardConfig bring-up exceptions have not been removed"
  for exception in "${bringup_exceptions[@]}"; do
    sed -i "\|^${exception}$|d" "$board_config"
  done
fi
for exception in "${bringup_exceptions[@]}"; do
  ! grep -Fxq "$exception" "$board_config" || \
    die "failed to remove bring-up exception: $exception"
done
if (( present_exceptions > 0 )); then
  note "removed broad neverallow and duplicate-rule build exceptions"
else
  note "strict generated BoardConfig already verified"
fi

# The stock-exact hostapd and supplicant fragments duplicate declarations
# already owned, required, and installed by pristine AOSP's matching service
# modules. The generator's immutable FileTreeSpec is verified before this
# script runs. Remove the two complete generated producers afterward as one
# fail-closed, attested transform; removing only PRODUCT_PACKAGES is
# insufficient because Soong still emits install rules for declared modules.
wifi_modules=(
  adevtool_vintf_fragment_vendor_android.hardware.wifi.hostapd.xml
  adevtool_vintf_fragment_vendor_android.hardware.wifi.supplicant.xml
)
wifi_fragments=(
  android.hardware.wifi.hostapd.xml
  android.hardware.wifi.supplicant.xml
)
wifi_generated_sha256=(
  2bb8b7148536575a9022ad2bb008a02ed2f0fbcec341b0efbbc5f59e470e8881
  d8dce6d4a6f9ecd85b1d8b3bf59a545bd7ac92bd84038c81c3e3876364c9190c
)
wifi_aosp_paths=(
  "$source_dir/external/wpa_supplicant_8/hostapd/android.hardware.wifi.hostapd.xml"
  "$source_dir/external/wpa_supplicant_8/wpa_supplicant/aidl/android.hardware.wifi.supplicant.xml"
)
wifi_aosp_sha256=(
  ce92fa3e0509f9619a386ce33b73f2ce71cdf164aa861b5fee98460120ba2e52
  aff4e096edaf9fece9cd98eff7c5a8642f0a18f9d74e2134086adfb1fea2b375
)

# This product requirement must survive. A config-wide vintf_exclusions rule
# would also remove it, so the compatibility-matrix hash is pinned on both
# sides of the transform.
verify_sha256 \
  60b187729cd54dd59c8fdafb4924dbe4f3a89df672fc25992b3e39eebf51c555 \
  "$product_matrix"

hostapd_bp="$source_dir/external/wpa_supplicant_8/hostapd/Android.bp"
supplicant_bp="$source_dir/external/wpa_supplicant_8/wpa_supplicant/Android.bp"
supplicant_aidl_bp="$source_dir/external/wpa_supplicant_8/wpa_supplicant/aidl/Android.bp"
require_file "$hostapd_bp"
require_file "$supplicant_bp"
require_file "$supplicant_aidl_bp"
for index in "${!wifi_aosp_paths[@]}"; do
  verify_sha256 "${wifi_aosp_sha256[$index]}" "${wifi_aosp_paths[$index]}"
done

require_exact_line_once() {
  local line=$1
  local path=$2
  local count
  count=$(grep -Fxc "$line" "$path" || true)
  (( count == 1 )) || die "expected one AOSP Wi-Fi ownership line in $path: $line"
}

require_exact_line_once \
  '    name: "android.hardware.wifi.hostapd.xml",' "$hostapd_bp"
require_exact_line_once \
  '        "android.hardware.wifi.hostapd.xml",' "$hostapd_bp"
require_exact_line_once \
  '    vintf_fragment_modules: ["android.hardware.wifi.hostapd.xml"],' "$hostapd_bp"
require_exact_line_once \
  '    name: "android.hardware.wifi.supplicant.xml",' "$supplicant_aidl_bp"
require_exact_line_once \
  '        "android.hardware.wifi.supplicant.xml",' "$supplicant_bp"
require_exact_line_once \
  '    vintf_fragment_modules: ["android.hardware.wifi.supplicant.xml"],' "$supplicant_bp"

present_wifi_components=0
aosp_wifi_package_requests=0
for index in "${!wifi_modules[@]}"; do
  module=${wifi_modules[$index]}
  fragment=${wifi_fragments[$index]}
  generated_xml="$generated_dir/vintf/vendor/manifest/$fragment"

  if [[ -e "$generated_xml" || -L "$generated_xml" ]]; then
    [[ -f "$generated_xml" && ! -L "$generated_xml" ]] || \
      die "generated Wi-Fi VINTF path is not a regular file: $generated_xml"
    verify_sha256 "${wifi_generated_sha256[$index]}" "$generated_xml"
    present_wifi_components=$((present_wifi_components + 1))
  fi

  module_count=$(grep -Fxc "    name: \"$module\"," "$manifest_bp" || true)
  src_count=$(grep -Fxc "    src: \"$fragment\"," "$manifest_bp" || true)
  package_count=$(grep -Fxc "    $module \\" "$product_makefile" || true)
  aosp_package_count=$(grep -Fxc "    $fragment \\" "$product_makefile" || true)
  (( module_count <= 1 && src_count <= 1 && package_count <= 1 && \
     aosp_package_count <= 1 )) || \
    die "duplicate generated Wi-Fi VINTF component: $module"
  present_wifi_components=$((
    present_wifi_components + module_count + src_count + package_count
  ))
  aosp_wifi_package_requests=$((aosp_wifi_package_requests + aosp_package_count))
done

if (( present_wifi_components == 8 && aosp_wifi_package_requests == 0 )); then
  [[ "$check_only" == false ]] || \
    die "generated Wi-Fi VINTF duplicate producers have not been removed"
  verify_sha256 \
    06072527d95e41051936f53c3adeacce1c0c3f71ad7fd2179f8fe6f75d21afeb \
    "$product_makefile"
  verify_sha256 \
    3d7e496bf86da8c0a37d5e6d9905ae7906a6ad98a4d19a71b5167e84b22f1764 \
    "$manifest_bp"

  bp_tmp=$(mktemp --tmpdir="$(dirname -- "$manifest_bp")" '.Android.bp.wifi.XXXXXX')
  mk_tmp=$(mktemp --tmpdir="$(dirname -- "$product_makefile")" '.cubs.mk.wifi.XXXXXX')
  cleanup_wifi_temps() {
    rm -f -- "$bp_tmp" "$mk_tmp"
  }
  trap cleanup_wifi_temps EXIT

  LC_ALL=C awk \
    -v m1="${wifi_modules[0]}" -v s1="${wifi_fragments[0]}" \
    -v m2="${wifi_modules[1]}" -v s2="${wifi_fragments[1]}" '
      { lines[NR] = $0 }
      END {
        removed = 0
        separator = ""
        for (i = 1; i <= NR; i++) {
          module = ""
          source = ""
          if (lines[i + 1] == "    name: \"" m1 "\",") {
            module = m1
            source = s1
          } else if (lines[i + 1] == "    name: \"" m2 "\",") {
            module = m2
            source = s2
          }
          if (module != "") {
            if (lines[i] != "vintf_fragment {" ||
                lines[i + 2] != "    src: \"" source "\"," ||
                lines[i + 3] != "    soc_specific: true," ||
                lines[i + 4] != "}") {
              exit 42
            }
            i += 4
            if (i < NR && lines[i + 1] == "") {
              i++
            }
            removed++
            continue
          }
          printf "%s%s", separator, lines[i]
          separator = "\n"
        }
        if (removed != 2) {
          exit 43
        }
      }
    ' "$manifest_bp" >"$bp_tmp" || die "failed to remove exact Wi-Fi VINTF Soong stanzas"

  LC_ALL=C awk \
    -v m1="${wifi_modules[0]}" -v s1="${wifi_fragments[0]}" \
    -v m2="${wifi_modules[1]}" -v s2="${wifi_fragments[1]}" '
      $0 == "    " m1 " \\" { print "    " s1 " \\"; replaced++; next }
      $0 == "    " m2 " \\" { print "    " s2 " \\"; replaced++; next }
      { print }
      END { if (replaced != 2) exit 44 }
    ' "$product_makefile" >"$mk_tmp" || \
      die "failed to replace generated Wi-Fi VINTF package requests"

  verify_sha256 \
    deb2ba3b28677886e5f6ba3f9bf41346802aa1d97ef2adf7381249bffc59df0f \
    "$bp_tmp"
  verify_sha256 \
    f3e9a24837c707bd7add2bf65aba760059c23f7f191af08edfdb975ffedc45f4 \
    "$mk_tmp"
  chmod --reference="$manifest_bp" "$bp_tmp"
  chmod --reference="$product_makefile" "$mk_tmp"
  mv -- "$bp_tmp" "$manifest_bp"
  mv -- "$mk_tmp" "$product_makefile"
  for fragment in "${wifi_fragments[@]}"; do
    rm -f -- "$generated_dir/vintf/vendor/manifest/$fragment"
  done
  trap - EXIT
  note "removed two complete generated Wi-Fi VINTF duplicate producers"
elif (( present_wifi_components == 0 && aosp_wifi_package_requests == 2 )); then
  note "generated Wi-Fi VINTF duplicate producers already omitted"
else
  die "generated Wi-Fi VINTF producer transform is partial ($present_wifi_components/8 generated components and $aosp_wifi_package_requests/2 AOSP requests present)"
fi

verify_sha256 \
  deb2ba3b28677886e5f6ba3f9bf41346802aa1d97ef2adf7381249bffc59df0f \
  "$manifest_bp"
verify_sha256 \
  f3e9a24837c707bd7add2bf65aba760059c23f7f191af08edfdb975ffedc45f4 \
  "$product_makefile"
verify_sha256 \
  60b187729cd54dd59c8fdafb4924dbe4f3a89df672fc25992b3e39eebf51c555 \
  "$product_matrix"
for index in "${!wifi_modules[@]}"; do
  module=${wifi_modules[$index]}
  fragment=${wifi_fragments[$index]}
  [[ ! -e "$generated_dir/vintf/vendor/manifest/$fragment" && \
     ! -L "$generated_dir/vintf/vendor/manifest/$fragment" ]] || \
    die "sanitized Wi-Fi VINTF XML still exists: $fragment"
  if grep -R -Fq --include='*.bp' --include='*.mk' \
      -e "$module" "$generated_dir"; then
    die "sanitized generated tree still references Wi-Fi VINTF producer: $module"
  fi
  src_count=$(grep -Fxc "    src: \"$fragment\"," "$manifest_bp" || true)
  package_count=$(grep -Fxc "    $fragment \\" "$product_makefile" || true)
  (( src_count == 0 && package_count == 1 )) || \
    die "AOSP Wi-Fi VINTF package ownership is not exact: $fragment"
done

hostapd_requirement_count=$(grep -Fxc \
  '        <name>android.hardware.wifi.hostapd</name>' "$product_matrix" || true)
hostapd_interface_count=$(grep -Fxc \
  '            <name>IHostapd</name>' "$product_matrix" || true)
(( hostapd_requirement_count == 1 && hostapd_interface_count == 1 )) || \
  die "stock hostapd compatibility-matrix requirement was not preserved"
