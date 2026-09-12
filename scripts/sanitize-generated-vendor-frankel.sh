#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"
# shellcheck source=lib/cubs-sepolicy.sh
source "$script_dir/lib/cubs-sepolicy.sh"
# shellcheck source=lib/frankel-pdm-provenance.sh
source "$script_dir/lib/frankel-pdm-provenance.sh"

[[ "$DEVICE_CODENAME" == frankel && "$DEVICE_PLATFORM" == laguna ]] || \
  die "the frankel sanitizer may only run for the frankel/Laguna profile"

check_only=false
if [[ "${1:-}" == --check ]]; then
  check_only=true
elif [[ $# -ne 0 ]]; then
  die "usage: $0 [--check]"
fi

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
assert_inside_work "$source_dir"
generated_dir="$source_dir/vendor/google_devices/$DEVICE_CODENAME"
board_config="$generated_dir/BoardConfig.mk"
product_makefile="$generated_dir/$DEVICE_CODENAME.mk"
manifest_bp="$generated_dir/vintf/vendor/manifest/Android.bp"
product_matrix="$generated_dir/vintf/product/compatibility_matrix.xml"
policy_file="$generated_dir/sepolicy/system_ext/public/types.te"
require_file "$board_config"
require_file "$product_makefile"
require_file "$manifest_bp"
require_file "$product_matrix"
require_file "$policy_file"
[[ -d "$generated_dir" && ! -L "$generated_dir" ]] || \
  die "generated frankel tree is missing or unsafe"

# Pixel's stock eUICC firmware helper requires a tiny Gservices flag set even
# on this deliberately GSF-free product. Keep the proprietary helper, its
# generated support inputs, and the project-authored direct-authority provider
# as one fail-closed contract. The provider source itself is bound by the
# reviewed frameworks/base patch stack; these checks bind product selection
# and the exact extracted flag payload.
laguna_device_makefile="$source_dir/vendor/adevtool/config/mk/google_devices/platform/laguna/device.mk"
gservices_flags="$generated_dir/gservices-flags/flags.txt"
provider_bp="$source_dir/frameworks/base/packages/PixelAospGservicesFlagsProvider/Android.bp"
provider_manifest="$source_dir/frameworks/base/packages/PixelAospGservicesFlagsProvider/AndroidManifest.xml"
for path in \
  "$laguna_device_makefile" \
  "$gservices_flags" \
  "$provider_bp" \
  "$provider_manifest"; do
  require_file "$path"
done
verify_sha256 \
  01153ea2667c6cbb838fe6adad958a9af5432970deb58cd059622c5dc1e755ab \
  "$gservices_flags"

declare -a euicc_contract_lines=(
  'PRODUCT_PACKAGES += PixelAospGservicesFlagsProvider'
  '    name: "PixelAospGservicesFlagsProvider",'
  '    package="org.pixelaosp.gservicesflags">'
  '        <package android:name="com.google.euiccpixel" />'
  '            android:authorities="com.google.android.gsf.gservices"'
  '            android:permission="com.google.android.providers.gsf.permission.READ_GSERVICES" />'
  '    adevtool_gservices_flags'
  "    EuiccSupportPixelOverlay \\"
  "    EuiccSupportPixel-P23 \\"
  "    EuiccSupportPixelPermissions \\"
)
declare -a euicc_contract_paths=(
  "$laguna_device_makefile"
  "$provider_bp"
  "$provider_manifest"
  "$provider_manifest"
  "$provider_manifest"
  "$provider_manifest"
  "$product_makefile"
  "$product_makefile"
  "$product_makefile"
  "$product_makefile"
)
for index in "${!euicc_contract_lines[@]}"; do
  line=${euicc_contract_lines[$index]}
  path=${euicc_contract_paths[$index]}
  count=$(grep -Fxc -- "$line" "$path" || true)
  (( count == 1 )) || \
    die "Frankel eUICC compatibility contract is incomplete in $path: $line"
done
gservices_flag_lines=$(grep -cve '^[[:space:]]*$' "$gservices_flags" || true)
(( gservices_flag_lines == 6 )) || \
  die "Frankel Gservices flag payload must contain exactly six non-empty lines"
note "verified Frankel eUICC Gservices compatibility contract"

# The extracted system_ext policy repeats four types already owned by this
# pinned AOSP release. Remove only those exact declarations after generator
# verification; pin both native owners so this cannot hide a source drift.
aosp_preloads_policy="$source_dir/system/sepolicy/private/preloads_copy.te"
aosp_startup_policy="$source_dir/system/sepolicy/private/system_server_startup.te"
require_file "$aosp_preloads_policy"
require_file "$aosp_startup_policy"
verify_sha256 \
  07fcd710a27f268b2f71f51d6b5191bd09977d13b174a64ae1326569ab1c73a0 \
  "$aosp_preloads_policy"
verify_sha256 \
  b90dcd9b2256e0d830e955e8693660d3945fe6666329de7aea4d5eff26131455 \
  "$aosp_startup_policy"

declarations=(
  'type preloads_copy, domain, coredomain;'
  'type system_server_startup, domain, coredomain;'
  'type preloads_copy_exec, file_type, exec_type, system_file_type;'
  'type system_server_startup_tmpfs, file_type;'
)
present_declarations=0
for declaration in "${declarations[@]}"; do
  count=$(grep -Fxc -- "$declaration" "$policy_file" || true)
  (( count <= 1 )) || die "duplicate compatibility declaration: $declaration"
  present_declarations=$((present_declarations + count))
done

if (( present_declarations == ${#declarations[@]} )); then
  [[ "$check_only" == false ]] || \
    die "generated frankel SELinux compatibility declarations remain"
  verify_sha256 \
    a707abf99b98b8e87ed81654c8226fdf5d5e77495c37a83ea00a1f41ebc0e3ed \
    "$policy_file"
  for declaration in "${declarations[@]}"; do
    sed -i "\|^${declaration}$|d" "$policy_file"
  done
  note "removed four frankel declarations already owned by pristine AOSP sepolicy"
elif (( present_declarations == 0 )); then
  note "generated frankel SELinux compatibility declarations already omitted"
else
  die "generated frankel SELinux compatibility declaration transform is partial ($present_declarations/${#declarations[@]})"
fi
verify_sha256 \
  79a7bca363bffd2c62c0c53dd0a1bf218ab0cdb1031cf3cd0541bb5bc180d0e1 \
  "$policy_file"

# Stock redundantly carries AOSP's standard vndservicemanager transfer rule.
# Its generated complement is versioned and includes init/vendor_init after
# mapping, violating the pinned platform neverallow. Preserve the native AOSP
# rule and delete its exact three-component synthetic duplicate only.
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
sanitize_redundant_vndservicemanager_rule \
  "$generated_vendor_policy" \
  6d67a3be1f52e6f39c7ef89f280f79ba4db08d7c2489dd2abf64e24b30ff6e42 \
  55a9369a7e41dc87c98eddc94a10cf4f188c9091d6f2566aaa5ef032f4ab946b \
  _202604 "$check_only" base_adevtool_typeattr_81 frankel
sanitize_redundant_vndservicemanager_rule \
  "$generated_recovery_policy" \
  9b4b1f2a2a4c0a6aa2a1d63739f02fa80d18fe3804b756bf49b9ce347f1e1a51 \
  f8d729568193e5f6f04a77ba5a3ff286307199f0a6cd3948d8ba0d3523b252f8 \
  '' "$check_only" base_adevtool_typeattr_81 frankel
note "verified native AOSP ownership of the frankel vndservicemanager transfer rule"

# Adevtool skeletons carry broad bring-up switches. A release-capable target
# must compile with each incompatibility fixed narrowly instead.
bringup_exceptions=(
  'SELINUX_IGNORE_NEVERALLOWS := true'
  'BUILD_BROKEN_DUP_RULES := true'
)
present=0
for exception in "${bringup_exceptions[@]}"; do
  count=$(grep -Fxc -- "$exception" "$board_config" || true)
  (( count <= 1 )) || die "duplicate bring-up exception: $exception"
  present=$((present + count))
done
(( present == 0 || present == ${#bringup_exceptions[@]} )) || \
  die "generated frankel BoardConfig is only partially sanitized"
if (( present > 0 )); then
  [[ "$check_only" == false ]] || \
    die "generated frankel BoardConfig still carries bring-up exceptions"
  for exception in "${bringup_exceptions[@]}"; do
    sed -i "\|^${exception}$|d" "$board_config"
  done
  note "removed broad Laguna bring-up exceptions"
fi
for exception in "${bringup_exceptions[@]}"; do
  ! grep -Fxq -- "$exception" "$board_config" || \
    die "failed to remove bring-up exception: $exception"
done

# The target profile deliberately uses the extracted stock kernel. The
# GrapheneOS-only USB port-security init fragment is patched out before
# generation. GosOverlay remains intentionally: its locally patched content
# now carries only the stock-relevant display color-mode resource.
if grep -R -n -E --include='*.bp' --include='*.mk' --include='*.rc' \
    'init\.laguna\.grapheneos\.rc' "$generated_dir"; then
  die "generated frankel tree still requests GrapheneOS-only runtime modules"
fi

# Stock carries the same hostapd and supplicant fragments that pristine AOSP's
# service modules already own and install. Adevtool must first verify its
# immutable FileTreeSpec; this post-generation transform then replaces only
# the two generated package requests with their native AOSP module names and
# removes the corresponding generated Soong producers and XML inputs.
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

verify_sha256 \
  2dea1c14a659d7b22d3ef4d673266adfcfad1da09f27b9431f91da8de30352e3 \
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
  (( count == 1 )) || \
    die "expected one AOSP Wi-Fi ownership line in $path: $line"
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
    20de6209b444f697a1d1bed6e52b98942292bba478a23d318dec3f5ff1bb9c01 \
    "$product_makefile"
  verify_sha256 \
    18f14cc126f861d2474c7c7d5cffcdeb8afcb7b07bb09063db1eb0aafc942dce \
    "$manifest_bp"

  bp_tmp=$(mktemp --tmpdir="$(dirname -- "$manifest_bp")" '.Android.bp.wifi.XXXXXX')
  mk_tmp=$(mktemp --tmpdir="$(dirname -- "$product_makefile")" '.frankel.mk.wifi.XXXXXX')
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
    ' "$manifest_bp" >"$bp_tmp" || \
      die "failed to remove exact Wi-Fi VINTF Soong stanzas"

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
    ff385fb5e0410776811a38ee9c069ff0bd3f8a538fa43f694c377949de33ca8c \
    "$bp_tmp"
  verify_sha256 \
    8a5a7002c44f8683f7749223ddd68f66c4fd7edb49214f77b1ac84c290c4fa2d \
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

# The pinned AOSP tag carries these eight feature XML inputs but no Soong
# producers for the generic module names emitted by adevtool. Define producers
# under Frankel-prefixed names and rewrite only this generated product after
# adevtool's immutable FileTreeSpec has passed. Explicit Soong filenames retain
# the generated product's original vendor/etc/permissions paths and bytes. The
# unchanged Cubs product therefore cannot resolve its same-named requests
# through this target adapter.
aosp_feature_bp="$source_dir/frameworks/native/data/etc/Android.bp"
require_file "$aosp_feature_bp"
feature_installed_filenames=(
  android.hardware.audio.pro.prebuilt.xml
  android.hardware.device_unique_attestation.prebuilt.xml
  android.hardware.opengles.aep.prebuilt.xml
  android.hardware.touchscreen.multitouch.jazzhand.prebuilt.xml
  android.hardware.wifi.aware.prebuilt.xml
  android.hardware.wifi.rtt.prebuilt.xml
  android.software.ipsec_tunnel_migration.prebuilt.xml
  android.software.midi.prebuilt.xml
)
feature_scoped_modules=(
  frankel_android.hardware.audio.pro.prebuilt.xml
  frankel_android.hardware.device_unique_attestation.prebuilt.xml
  frankel_android.hardware.opengles.aep.prebuilt.xml
  frankel_android.hardware.touchscreen.multitouch.jazzhand.prebuilt.xml
  frankel_android.hardware.wifi.aware.prebuilt.xml
  frankel_android.hardware.wifi.rtt.prebuilt.xml
  frankel_android.software.ipsec_tunnel_migration.prebuilt.xml
  frankel_android.software.midi.prebuilt.xml
)
feature_sources=(
  android.hardware.audio.pro.xml
  android.hardware.device_unique_attestation.xml
  android.hardware.opengles.aep.xml
  android.hardware.touchscreen.multitouch.jazzhand.xml
  android.hardware.wifi.aware.xml
  android.hardware.wifi.rtt.xml
  android.software.ipsec_tunnel_migration.xml
  android.software.midi.xml
)
feature_names=(
  android.hardware.audio.pro
  android.hardware.device_unique_attestation
  android.hardware.opengles.aep
  android.hardware.touchscreen.multitouch.jazzhand
  android.hardware.wifi.aware
  android.hardware.wifi.rtt
  android.software.ipsec_tunnel_migration
  android.software.midi
)
feature_source_sha256=(
  e874740627eda9ce5bec095deb574134523a4a2d7a91040e8830f2b907bd1f3d
  b59c3c96e3fa69f87dfafc0019c5100a8241825cf82b4776f3aa699064c4e2bf
  34df4a1963e75d4ab0b2b08ad7462fe1f047d88904bac1b6ce4e71ecbf3f24ba
  9fb2b20e77f0104e5b1d01630f8af69e1d6b24baae47a1a5ca91e9c0f0aee30c
  6370914090ba4f81ef1410da719b6b2df5389180a8757ac95e77ca88d0076e85
  46871980f5214f70b0741c11f885c0330b8563abc3defbbf83b068e1cc01d786
  92a41300310336fcc7eabd9b629e3a484cdadf61312e21a829c373186c4108c6
  9c03125fbea5dbdf54b26a242dc5e330e1dc23037f6ffd87de900a285dc40e9d
)

legacy_feature_requests=0
scoped_feature_requests=0
for index in "${!feature_scoped_modules[@]}"; do
  installed_filename=${feature_installed_filenames[$index]}
  scoped_module=${feature_scoped_modules[$index]}
  legacy_feature_requests=$((legacy_feature_requests + $(
    grep -Fxc "    $installed_filename \\" "$product_makefile" || true
  )))
  scoped_feature_requests=$((scoped_feature_requests + $(
    grep -Fxc "    $scoped_module \\" "$product_makefile" || true
  )))
done

if (( legacy_feature_requests == 8 && scoped_feature_requests == 0 )); then
  [[ "$check_only" == false ]] || \
    die "generated Frankel feature requests have not been target-scoped"
  verify_sha256 \
    8a5a7002c44f8683f7749223ddd68f66c4fd7edb49214f77b1ac84c290c4fa2d \
    "$product_makefile"
  feature_tmp=$(mktemp \
    --tmpdir="$(dirname -- "$product_makefile")" '.frankel.mk.features.XXXXXX')
  cleanup_feature_temp() {
    rm -f -- "$feature_tmp"
  }
  trap cleanup_feature_temp EXIT
  LC_ALL=C awk '
    $0 == "    android.hardware.audio.pro.prebuilt.xml \\" {
      print "    frankel_android.hardware.audio.pro.prebuilt.xml \\"; replaced++; next
    }
    $0 == "    android.hardware.device_unique_attestation.prebuilt.xml \\" {
      print "    frankel_android.hardware.device_unique_attestation.prebuilt.xml \\"; replaced++; next
    }
    $0 == "    android.hardware.opengles.aep.prebuilt.xml \\" {
      print "    frankel_android.hardware.opengles.aep.prebuilt.xml \\"; replaced++; next
    }
    $0 == "    android.hardware.touchscreen.multitouch.jazzhand.prebuilt.xml \\" {
      print "    frankel_android.hardware.touchscreen.multitouch.jazzhand.prebuilt.xml \\"; replaced++; next
    }
    $0 == "    android.hardware.wifi.aware.prebuilt.xml \\" {
      print "    frankel_android.hardware.wifi.aware.prebuilt.xml \\"; replaced++; next
    }
    $0 == "    android.hardware.wifi.rtt.prebuilt.xml \\" {
      print "    frankel_android.hardware.wifi.rtt.prebuilt.xml \\"; replaced++; next
    }
    $0 == "    android.software.ipsec_tunnel_migration.prebuilt.xml \\" {
      print "    frankel_android.software.ipsec_tunnel_migration.prebuilt.xml \\"; replaced++; next
    }
    $0 == "    android.software.midi.prebuilt.xml \\" {
      print "    frankel_android.software.midi.prebuilt.xml \\"; replaced++; next
    }
    { print }
    END { if (replaced != 8) exit 45 }
  ' "$product_makefile" >"$feature_tmp" || \
    die "failed to target-scope exact Frankel feature package requests"
  verify_sha256 \
    fe764b7b159dce99b74b08912b1b9009197578c0df33285809ec98cc535d0976 \
    "$feature_tmp"
  chmod --reference="$product_makefile" "$feature_tmp"
  mv -- "$feature_tmp" "$product_makefile"
  trap - EXIT
  note "target-scoped eight Frankel feature module requests"
elif (( legacy_feature_requests == 0 && scoped_feature_requests == 8 )); then
  note "generated Frankel feature module requests already target-scoped"
else
  die "generated Frankel feature transform is partial ($legacy_feature_requests/8 legacy and $scoped_feature_requests/8 scoped requests)"
fi

powerphone_package_count=$(grep -Fxc \
  'PRODUCT_PACKAGES += android.hardware.audio.service-aidl.powerphone' \
  "$product_makefile" || true)
powerphone_matrix_count=$(grep -Fxc \
  'DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE += hardware/interfaces/audio/aidl/default/powerphone/compatibility_matrix.powerphone.xml' \
  "$product_makefile" || true)
powerphone_loader_package_count=$(grep -Fxc \
  'PRODUCT_PACKAGES += powerphone_pdm_loader' \
  "$product_makefile" || true)
powerphone_bootstrap_package_count=$(grep -Fxc \
  'PRODUCT_PACKAGES += frankel_powerphone_d10_bootstrap' \
  "$product_makefile" || true)
powerphone_staged_player_package_count=$(grep -Fxc \
  'PRODUCT_PACKAGES += frankel_aoc_staged_play' \
  "$product_makefile" || true)
case "$powerphone_package_count:$powerphone_matrix_count:$powerphone_loader_package_count:$powerphone_bootstrap_package_count:$powerphone_staged_player_package_count" in
  0:0:0:0:0)
    verify_sha256 \
      fe764b7b159dce99b74b08912b1b9009197578c0df33285809ec98cc535d0976 \
      "$product_makefile"
    ;;
  # Accept the package-only state while migrating an already materialized
  # research tree to the required device framework compatibility matrix.
  1:0:0:0:0)
    verify_sha256 \
      e889a507a4679eba60955f9d5348bc3dc41f1c2e21e65bcf14590da466c09b42 \
      "$product_makefile"
    ;;
  1:1:0:0:0)
    verify_sha256 \
      c60632fc193cbcffe25930bf3e14615e2018510985ab1e0c987893ebeb509076 \
      "$product_makefile"
    ;;
  # Migration input produced by the superseded card-1/S32 PDM experiment.
  1:1:1:0:0)
    verify_sha256 \
      1d10abe585fc3b010d6384005eabc4bc405a9f840ab4cb53e0b45547b3614118 \
      "$product_makefile"
    ;;
  # Current card-0/D10 integration. The checksum is filled from the exact
  # deterministic transform below and prevents an unreviewed package request.
  1:1:0:1:0)
    verify_sha256 \
      c284313efcdd2f9d94a1b490872ec38c8f6733c2c486788fa625f0ac8f7ed24d \
      "$product_makefile"
    ;;
  # Native-q192 PowerPhone selection adds the bounded staged D0 player to the
  # same reviewed card-0 integration, so the final image reproduces the
  # hardware-qualified raw-WRITEI path without an out-of-band adb push.
  1:1:0:1:1)
    verify_sha256 \
      0a69996f2213b6c1825346bb92512c28d077d98bb6dbfd623efb38c2c99c1943 \
      "$product_makefile"
    ;;
  *) die "invalid or duplicate PowerPhone audio product state in $product_makefile" ;;
esac
for index in "${!feature_scoped_modules[@]}"; do
  installed_filename=${feature_installed_filenames[$index]}
  scoped_module=${feature_scoped_modules[$index]}
  source_name=${feature_sources[$index]}
  feature_name=${feature_names[$index]}
  source_path="$source_dir/frameworks/native/data/etc/$source_name"
  require_file "$source_path"
  verify_sha256 "${feature_source_sha256[$index]}" "$source_path"

  scoped_module_count=$(grep -Fxc \
    "    name: \"$scoped_module\"," "$aosp_feature_bp" || true)
  legacy_module_count=$(grep -Fxc \
    "    name: \"$installed_filename\"," "$aosp_feature_bp" || true)
  source_count=$(grep -Fxc \
    "    src: \"$source_name\"," "$aosp_feature_bp" || true)
  filename_count=$(grep -Fxc \
    "    filename: \"$installed_filename\"," "$aosp_feature_bp" || true)
  package_count=$(grep -Fxc \
    "    $scoped_module \\" "$product_makefile" || true)
  legacy_package_count=$(grep -Fxc \
    "    $installed_filename \\" "$product_makefile" || true)
  declaration_count=$(grep -Fxc \
    "    <feature name=\"$feature_name\" />" "$source_path" || true)
  (( scoped_module_count == 1 && legacy_module_count == 0 && \
     source_count == 1 && filename_count == 1 && package_count == 1 && \
     legacy_package_count == 0 && declaration_count == 1 )) || \
    die "Frankel $feature_name scoped feature producer contract is incomplete"
done
note "verified eight Frankel-scoped feature producers and unchanged filenames"

verify_sha256 \
  ff385fb5e0410776811a38ee9c069ff0bd3f8a538fa43f694c377949de33ca8c \
  "$manifest_bp"
verify_sha256 \
  2dea1c14a659d7b22d3ef4d673266adfcfad1da09f27b9431f91da8de30352e3 \
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
  '    <name>android.hardware.wifi.hostapd</name>' "$product_matrix" || true)
hostapd_interface_count=$(grep -Fxc \
  '      <name>IHostapd</name>' "$product_matrix" || true)
(( hostapd_requirement_count == 1 && hostapd_interface_count == 1 )) || \
  die "stock hostapd compatibility-matrix requirement was not preserved"

# Laguna stock fstab entries authenticate the logical partitions through root
# vbmeta. Unlike Malibu/cubs, they must not be rewritten to child vbmeta names.
for fstab in \
  "$generated_dir/proprietary/vendor_ramdisk/system/etc/fstab.laguna" \
  "$generated_dir/proprietary/vendor/etc/fstab.laguna"; do
  require_file "$fstab"
  grep -Eq '/system[[:space:]].*avb=vbmeta,logical' "$fstab" || \
    die "Laguna fstab no longer carries the root-vbmeta system mapping: $fstab"
  if grep -Eq 'avb=vbmeta_(system|vendor)' "$fstab"; then
    die "Laguna fstab unexpectedly contains a Malibu-style child AVB mapping"
  fi
done
cmp -s -- \
  "$generated_dir/proprietary/vendor_ramdisk/system/etc/fstab.laguna" \
  "$generated_dir/proprietary/vendor/etc/fstab.laguna" || \
  die "generated frankel fstab.laguna copies are not byte-identical"

# Validate the independent research selections before any can mutate the
# generated tree. In particular, a malformed sidecar value must not leave the
# AoC module changed by an otherwise failing sanitizer invocation.
powerphone_aoc_alsa_192k=${POWERPHONE_AOC_ALSA_192K:-false}
case "$powerphone_aoc_alsa_192k" in
  true) powerphone_aoc_module_state=patched ;;
  false) powerphone_aoc_module_state=stock ;;
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
powerphone_signed_aoc_firmware_profile=${POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE:-stock}
case "$powerphone_signed_aoc_firmware_profile" in
  stock|source0-4s32-allocator-fallback) ;;
  *) die "POWERPHONE_SIGNED_AOC_FIRMWARE_PROFILE must be stock or source0-4s32-allocator-fallback" ;;
esac
if [[ "$powerphone_aoc_alsa_192k" == false && \
      ( "$powerphone_d0_progress_mode" != mailbox || \
        "$powerphone_signed_aoc_firmware_profile" != stock || \
        "$powerphone_d5_timer" == true ) ]]; then
  die "non-default AoC selections require POWERPHONE_AOC_ALSA_192K=true"
fi
if [[ "$powerphone_d5_timer" == true && \
      "$powerphone_d0_progress_mode" != one-period-lag ]]; then
  die "POWERPHONE_D5_TIMER=true requires POWERPHONE_D0_PROGRESS_MODE=one-period-lag"
fi
if [[ -n ${POWERPHONE_PRIMARY_HAL_192K:-} ]]; then
  powerphone_primary_hal_192k=$POWERPHONE_PRIMARY_HAL_192K
elif [[ "$powerphone_aoc_alsa_192k" == true ]]; then
  powerphone_primary_hal_192k=true
else
  powerphone_primary_hal_192k=false
fi
case "$powerphone_primary_hal_192k" in
  true)
    powerphone_primary_hal_state=patched
    powerphone_primary_route_state=patched
    ;;
  rate-only)
    powerphone_primary_hal_state=rate-only
    powerphone_primary_route_state=stock
    ;;
  false)
    powerphone_primary_hal_state=stock
    powerphone_primary_route_state=stock
    ;;
  *) die "POWERPHONE_PRIMARY_HAL_192K must be true, rate-only, or false" ;;
esac
if [[ "$powerphone_primary_hal_192k" != false && \
      "$powerphone_aoc_alsa_192k" != true ]]; then
  die "a high-rate primary HAL requires POWERPHONE_AOC_ALSA_192K=true"
fi
powerphone_audio_sidecar=${POWERPHONE_AUDIO_SIDECAR:-false}
case "$powerphone_audio_sidecar" in
  true|false) ;;
  *) die "POWERPHONE_AUDIO_SIDECAR must be true or false" ;;
esac

# The platform-side PowerPhone gate performs a synchronous, bounded mutation
# transaction.  It may begin only after this stock late_start daemon has been
# launched, because aocd is what loads AoC firmware and permits card 0 to
# register.  Validate the extracted prerequisite before materializing a gate
# that names its init service; otherwise an early exec_start wait can block init
# itself from ever reaching the class that creates the audio card.
if [[ "$powerphone_audio_sidecar" == true ]]; then
  powerphone_aocd_rc="$generated_dir/proprietary/vendor/etc/init/aocd.rc"
  require_file "$powerphone_aocd_rc"
  [[ $(grep -Fxc 'service aocd /vendor/bin/aocd' "$powerphone_aocd_rc" || true) -eq 1 ]] || \
    die "Frankel PowerPhone requires the stock aocd service definition"
  [[ $(grep -Fxc '  class late_start' "$powerphone_aocd_rc" || true) -eq 1 ]] || \
    die "Frankel PowerPhone requires aocd in class late_start"
  if grep -Eq '^[[:space:]]*disabled([[:space:]]|$)' "$powerphone_aocd_rc"; then
    die "Frankel PowerPhone requires automatically started stock aocd"
  fi
fi
powerphone_cs35l43_192k=${POWERPHONE_CS35L43_192K:-false}
case "$powerphone_cs35l43_192k" in
  true) powerphone_cs35l43_module_state=patched ;;
  false) powerphone_cs35l43_module_state=stock ;;
  *) die "POWERPHONE_CS35L43_192K must be true or false" ;;
esac

# Both extracted audio daemons normally restart audioserver unconditionally
# from their service onrestart hook. That overrides the platform gate's
# early-init stop if either daemon restarts during the synchronous PowerPhone
# certification transaction. Preserve normal recovery after audioserver is
# released, but make a stopped audioserver an intentional fixed point while the
# sidecar is selected. `restart --only-if-running` is an init builtin and does
# not require vendor init to read the private init.svc.audioserver property.
powerphone_audioserver_restart_stock='    onrestart restart audioserver'
powerphone_audioserver_restart_guarded='    onrestart restart --only-if-running audioserver'
powerphone_audio_restart_rcs=(
  "$generated_dir/proprietary/vendor/etc/init/android.hardware.audio.service-aidl.aoc.rc"
  "$generated_dir/proprietary/system_ext/etc/init/vendor.google.whitechapel.audio.hal.parserservice.rc"
)
powerphone_audio_restart_descriptions=(
  'Frankel stock AoC audio HAL'
  'Frankel Whitechapel audio parser'
)

select_powerphone_audioserver_restart_policy() {
  local path=$1 description=$2 desired undesired
  local desired_count undesired_count audioserver_hook_count temporary
  require_file "$path"
  [[ ! -L "$path" ]] || die "$description RC must not be a symlink: $path"

  if [[ "$powerphone_audio_sidecar" == true ]]; then
    desired=$powerphone_audioserver_restart_guarded
    undesired=$powerphone_audioserver_restart_stock
  else
    desired=$powerphone_audioserver_restart_stock
    undesired=$powerphone_audioserver_restart_guarded
  fi
  desired_count=$(grep -Fxc -- "$desired" "$path" || true)
  undesired_count=$(grep -Fxc -- "$undesired" "$path" || true)
  audioserver_hook_count=$(grep -Ec \
    '^[[:space:]]*onrestart[[:space:]].*audioserver([[:space:]]|$)' \
    "$path" || true)

  if (( desired_count == 1 && undesired_count == 0 && audioserver_hook_count == 1 )); then
    :
  elif (( desired_count == 0 && undesired_count == 1 && audioserver_hook_count == 1 )); then
    [[ "$check_only" == false ]] || \
      die "$description audioserver restart policy does not match POWERPHONE_AUDIO_SIDECAR=$powerphone_audio_sidecar"
    temporary=$(mktemp \
      --tmpdir="$(dirname -- "$path")" '.powerphone-audio-rc.XXXXXX')
    if ! LC_ALL=C awk -v source="$undesired" -v destination="$desired" '
        $0 == source { print destination; replaced++; next }
        { print }
        END { if (replaced != 1) exit 46 }
      ' "$path" >"$temporary"; then
      rm -f -- "$temporary"
      die "failed to select $description audioserver restart policy"
    fi
    chmod --reference="$path" "$temporary"
    mv -- "$temporary" "$path"
  else
    die "$description has an unrecognized or duplicate audioserver onrestart policy"
  fi

  [[ $(grep -Fxc -- "$desired" "$path" || true) -eq 1 &&
     $(grep -Fxc -- "$undesired" "$path" || true) -eq 0 ]] || \
    die "$description audioserver restart policy selection failed"
  note "verified $description audioserver restart policy: $powerphone_audio_sidecar"
}

for index in "${!powerphone_audio_restart_rcs[@]}"; do
  select_powerphone_audioserver_restart_policy \
    "${powerphone_audio_restart_rcs[$index]}" \
    "${powerphone_audio_restart_descriptions[$index]}"
done
unset -f select_powerphone_audioserver_restart_policy

# Google's exact Laguna AoC ALSA module is source-unavailable. Keep the complete
# D10-capture plus D0/EP1 source-0-playback expected-bytes transformation as a
# reversible generated-tree selection: ordinary builds restore stock, while
# research builds explicitly select the general 192 kHz constraints, EP3 and
# EP1 masks, capture polling, and one exact D0 real-progress implementation.
# The generated-vendor attestation inventories the resulting module bytes and
# hashes this sanitizer; pinning the helper here therefore transitively binds
# both the transformation logic and its output.
powerphone_aoc_patcher="$project_root/tools/audio/patch_frankel_aoc_192k.py"
powerphone_d0_progress_patcher="$project_root/tools/audio/patch_frankel_aoc_d0_progress_mode.py"
powerphone_ep6_patcher="$project_root/tools/audio/patch_frankel_aoc_ep6_speaker_192k.py"
powerphone_d5_timer_patcher="$project_root/tools/audio/patch_frankel_aoc_pcm_d5_timer_mode.py"
powerphone_aoc_module="$generated_dir/stock-kernel/aoc_alsa_dev_util.ko"
require_file "$powerphone_aoc_patcher"
require_file "$powerphone_d0_progress_patcher"
require_file "$powerphone_ep6_patcher"
require_file "$powerphone_d5_timer_patcher"
require_file "$powerphone_aoc_module"
[[ ! -L "$powerphone_aoc_patcher" && -x "$powerphone_aoc_patcher" ]] || \
  die "Frankel AoC 192 kHz patch helper is unsafe or not executable"
[[ ! -L "$powerphone_d0_progress_patcher" && \
   -x "$powerphone_d0_progress_patcher" ]] || \
  die "Frankel D0 progress patch helper is unsafe or not executable"
[[ ! -L "$powerphone_ep6_patcher" && -x "$powerphone_ep6_patcher" ]] || \
  die "Frankel EP6 192 kHz patch helper is unsafe or not executable"
[[ ! -L "$powerphone_d5_timer_patcher" && -x "$powerphone_d5_timer_patcher" ]] || \
  die "Frankel D5 timer patch helper is unsafe or not executable"
[[ ! -L "$powerphone_aoc_module" ]] || \
  die "generated Frankel AoC ALSA module must not be a symlink"
verify_sha256 \
  1c96487c0cfa3505f881824adbb084126bbf30eaafc7e8346d8818f2625b5e1d \
  "$powerphone_aoc_patcher"
verify_sha256 \
  3deb57c943d0015b410aac8fdf2611b8569f0af378b0e1cb22e059f82115198a \
  "$powerphone_d0_progress_patcher"
verify_sha256 \
  c5bf1fc07decf7f9c9c94d55b7f12c80253eafb18a6e9b884efc9337b670020d \
  "$powerphone_ep6_patcher"
verify_sha256 \
  1ed1d9507155587b554ca3031a6882e5f4bcb9beaf1923dec93ea0496b32a987 \
  "$powerphone_d5_timer_patcher"
if [[ "$check_only" == true ]]; then
  if [[ "$powerphone_aoc_module_state" == stock ]]; then
    "$powerphone_aoc_patcher" --check stock "$powerphone_aoc_module"
  else
    "$powerphone_d0_progress_patcher" \
      --check "$powerphone_d0_progress_mode" "$powerphone_aoc_module"
    if [[ "$powerphone_d5_timer" == true ]]; then
      "$powerphone_d5_timer_patcher" --check enabled "$powerphone_aoc_module"
    elif [[ "$powerphone_d0_progress_mode" == one-period-lag ]]; then
      "$powerphone_d5_timer_patcher" --check disabled "$powerphone_aoc_module"
    fi
  fi
else
  # The D5 timer selector overlaps the D0 open routine. Normalize it before
  # changing the base D0 state, then restore the requested selection below.
  if "$powerphone_d5_timer_patcher" --check enabled \
      "$powerphone_aoc_module" >/dev/null 2>&1; then
    "$powerphone_d5_timer_patcher" --set-state disabled --in-place \
      "$powerphone_aoc_module"
  fi
  # EP6 is orthogonal to the complete AoC transform, but the primary helper's
  # whole-file identities predate it. Normalize that one DAI word while the
  # base state is selected, then restore the requested EP6 state below.
  "$powerphone_ep6_patcher" --set-state stock --in-place \
    "$powerphone_aoc_module"
  # The primary helper knows stock and the complete mailbox state. Normalize
  # any selectable 192 kHz progress implementation back to mailbox before
  # asking it to restore stock, then select the requested implementation only
  # after the complete 192 kHz transform is present.
  if "$powerphone_aoc_patcher" --check stock \
      "$powerphone_aoc_module" >/dev/null 2>&1; then
    :
  else
    powerphone_aoc_progress_recognized=false
    for selectable_progress_mode in mailbox pure-timer one-period-lag; do
      if "$powerphone_d0_progress_patcher" --check "$selectable_progress_mode" \
          "$powerphone_aoc_module" >/dev/null 2>&1; then
        powerphone_aoc_progress_recognized=true
        break
      fi
    done
    [[ "$powerphone_aoc_progress_recognized" == true ]] || \
      die "generated Frankel AoC ALSA module is not an exact selectable state"
    "$powerphone_d0_progress_patcher" --set-state mailbox --in-place \
      "$powerphone_aoc_module"
  fi
  "$powerphone_aoc_patcher" --set-state "$powerphone_aoc_module_state" \
    --in-place "$powerphone_aoc_module"
  if [[ "$powerphone_aoc_module_state" == patched ]]; then
    "$powerphone_d0_progress_patcher" \
      --set-state "$powerphone_d0_progress_mode" --in-place \
      "$powerphone_aoc_module"
    "$powerphone_d0_progress_patcher" \
      --check "$powerphone_d0_progress_mode" "$powerphone_aoc_module"
  else
    "$powerphone_aoc_patcher" --check stock "$powerphone_aoc_module"
  fi
fi
"$powerphone_ep6_patcher" --set-state "$powerphone_aoc_module_state" \
  --in-place "$powerphone_aoc_module"
"$powerphone_ep6_patcher" --check "$powerphone_aoc_module_state" \
  "$powerphone_aoc_module"
if [[ "$powerphone_aoc_module_state" == patched && \
      "$powerphone_d0_progress_mode" == one-period-lag ]]; then
  if [[ "$powerphone_d5_timer" == true ]]; then
    "$powerphone_d5_timer_patcher" --set-state enabled --in-place \
      "$powerphone_aoc_module"
    "$powerphone_d5_timer_patcher" --check enabled "$powerphone_aoc_module"
  else
    "$powerphone_d5_timer_patcher" --check disabled "$powerphone_aoc_module"
  fi
fi
note "verified Frankel AoC ALSA module selection: $powerphone_aoc_module_state/$powerphone_d0_progress_mode/d5-timer-$powerphone_d5_timer"

# The selected D0 mailbox transport also requires the paired core ring reset:
# stock advances Tx by a complete ring when the write pointer is already zero,
# manufacturing data before the first PCM copy. Keep that one-instruction
# aoc_core transform reversible under the same AoC ALSA selection.
powerphone_aoc_core_patcher="$project_root/tools/audio/patch_frankel_aoc_core_zero_wp_reset.py"
powerphone_aoc_core_module="$generated_dir/stock-kernel/aoc_core.ko"
require_file "$powerphone_aoc_core_patcher"
require_file "$powerphone_aoc_core_module"
[[ ! -L "$powerphone_aoc_core_patcher" && -x "$powerphone_aoc_core_patcher" ]] || \
  die "Frankel AoC core ring-reset patch helper is unsafe or not executable"
[[ ! -L "$powerphone_aoc_core_module" ]] || \
  die "generated Frankel AoC core module must not be a symlink"
verify_sha256 \
  8cd75fae398bf94f96cf5d299c59539086a3930ebd40b3adf57692cd09bce4aa \
  "$powerphone_aoc_core_patcher"
if [[ "$check_only" == true ]]; then
  "$powerphone_aoc_core_patcher" --check "$powerphone_aoc_module_state" \
    "$powerphone_aoc_core_module"
else
  "$powerphone_aoc_core_patcher" --set-state "$powerphone_aoc_module_state" \
    "$powerphone_aoc_core_module" "$powerphone_aoc_core_module"
  "$powerphone_aoc_core_patcher" --check "$powerphone_aoc_module_state" \
    "$powerphone_aoc_core_module"
fi
note "verified Frankel AoC core zero-write-pointer selection: $powerphone_aoc_module_state"

# The signed AoC firmware is an independent generated-tree selection.  The
# research profile installs the exact live-qualified source-0/four-S32 F1
# speaker program plus the narrow A32 allocator fallback. The helper performs
# guarded symmetric selection and verifies an exact whole-file digest before
# and after every atomic replacement.
powerphone_aoc_firmware_patcher="$project_root/tools/audio/patch_frankel_aoc_firmware_speaker_192k.py"
powerphone_aoc_firmware="$generated_dir/proprietary/vendor/firmware/aoc.bin"
require_file "$powerphone_aoc_firmware_patcher"
require_file "$powerphone_aoc_firmware"
[[ ! -L "$powerphone_aoc_firmware_patcher" && \
   -x "$powerphone_aoc_firmware_patcher" ]] || \
  die "Frankel signed AoC firmware patch helper is unsafe or not executable"
[[ ! -L "$powerphone_aoc_firmware" ]] || \
  die "generated Frankel signed AoC firmware must not be a symlink"
verify_sha256 \
  d5e8f5edc1ffe2901efbc807d434b308794c7588e57b47111118be85445bf0c2 \
  "$powerphone_aoc_firmware_patcher"
if [[ "$check_only" == true ]]; then
  if [[ "$powerphone_signed_aoc_firmware_profile" == stock ]]; then
    "$powerphone_aoc_firmware_patcher" \
      --profile source0-4s32-allocator-fallback --check stock \
      "$powerphone_aoc_firmware"
  else
    "$powerphone_aoc_firmware_patcher" \
      --profile "$powerphone_signed_aoc_firmware_profile" --check patched \
      "$powerphone_aoc_firmware"
  fi
elif [[ "$powerphone_signed_aoc_firmware_profile" == stock ]]; then
  "$powerphone_aoc_firmware_patcher" \
    --profile source0-4s32-allocator-fallback --set-state stock --in-place \
    "$powerphone_aoc_firmware"
  "$powerphone_aoc_firmware_patcher" \
    --profile source0-4s32-allocator-fallback --check stock \
    "$powerphone_aoc_firmware"
else
  "$powerphone_aoc_firmware_patcher" \
    --profile "$powerphone_signed_aoc_firmware_profile" \
    --set-state patched --in-place \
    "$powerphone_aoc_firmware"
  "$powerphone_aoc_firmware_patcher" \
    --profile "$powerphone_signed_aoc_firmware_profile" --check patched \
    "$powerphone_aoc_firmware"
fi
note "verified Frankel signed AoC firmware selection: $powerphone_signed_aoc_firmware_profile"

# Keep the speaker-amplifier rate change just as narrow and reversible as the
# source-unavailable AoC transform above.  The exact stock CS35L43 core is
# changed at one guarded AArch64 immediate: the non-disabled ultrasonic path
# selects GLOBAL_FS code 4 (96 kHz) instead of code 3 (48 kHz).  FSX2 then
# consumes the 192 kHz ASP stream without replacing Google's DDK-built driver
# or changing any ordinary-mode rate selection.
powerphone_cs35l43_patcher="$project_root/tools/audio/patch_frankel_cs35l43_global_fs96.py"
powerphone_cs35l43_module="$generated_dir/stock-kernel/snd-soc-cs35l43.ko"
require_file "$powerphone_cs35l43_patcher"
require_file "$powerphone_cs35l43_module"
[[ ! -L "$powerphone_cs35l43_patcher" && -x "$powerphone_cs35l43_patcher" ]] || \
  die "Frankel CS35L43 192 kHz patch helper is unsafe or not executable"
[[ ! -L "$powerphone_cs35l43_module" ]] || \
  die "generated Frankel CS35L43 module must not be a symlink"
verify_sha256 \
  6a1420030d7e2f481f9e3ab008d5f7cff33490dcd6c3af4dda31d9a138b4fbb5 \
  "$powerphone_cs35l43_patcher"
if [[ "$check_only" == true ]]; then
  "$powerphone_cs35l43_patcher" --check "$powerphone_cs35l43_module_state" \
    "$powerphone_cs35l43_module"
else
  "$powerphone_cs35l43_patcher" --set-state "$powerphone_cs35l43_module_state" \
    --in-place "$powerphone_cs35l43_module"
  "$powerphone_cs35l43_patcher" --check "$powerphone_cs35l43_module_state" \
    "$powerphone_cs35l43_module"
fi
note "verified Frankel CS35L43 192 kHz selection: $powerphone_cs35l43_module_state"

# Keep every physical output below AudioFlinger at a fixed 192 kHz. The
# proprietary HAL's guarded transform changes the primary/deep mix profiles,
# all built-in output interfaces, and makes the secondary deep port on-demand
# DIRECT. Ordinary UI and media consequently share one primary AudioFlinger
# thread before the guarded D1-to-D5 redirect reaches EP6/source 5.
powerphone_primary_hal_patcher="$project_root/tools/audio/patch_frankel_primary_hal_192k.py"
powerphone_primary_hal="$generated_dir/proprietary/vendor/bin/hw/android.hardware.audio.service-aidl.aoc"
require_file "$powerphone_primary_hal_patcher"
require_file "$powerphone_primary_hal"
[[ ! -L "$powerphone_primary_hal_patcher" && -x "$powerphone_primary_hal_patcher" ]] || \
  die "Frankel primary HAL patch helper is unsafe or not executable"
[[ ! -L "$powerphone_primary_hal" ]] || \
  die "generated Frankel primary audio HAL must not be a symlink"
# The primary HAL selector validates its reviewed instruction sites directly,
# including migration from the former ten-ms PCM geometry; no file hash is
# needed for that scoped transformation.
if [[ "$check_only" == true ]]; then
  "$powerphone_primary_hal_patcher" --check "$powerphone_primary_hal_state" \
    "$powerphone_primary_hal"
else
  "$powerphone_primary_hal_patcher" --set-state "$powerphone_primary_hal_state" \
    --in-place "$powerphone_primary_hal"
  "$powerphone_primary_hal_patcher" --check "$powerphone_primary_hal_state" \
    "$powerphone_primary_hal"
fi
note "verified Frankel fixed-192 kHz primary HAL selection: $powerphone_primary_hal_state"

# Match the proprietary HAL's guarded D1-to-D5 PCM redirect at the mixer
# layer. Both ordinary speaker mix paths connect TDM RX to EP6/source 5;
# Bluetooth, USB, raw, haptic, and capture routes remain stock.
powerphone_primary_route_patcher="$project_root/tools/audio/patch_frankel_primary_speaker_route.py"
powerphone_mixer_paths="$generated_dir/proprietary/vendor/etc/audio/config/mixer_paths.xml"
require_file "$powerphone_primary_route_patcher"
require_file "$powerphone_mixer_paths"
[[ ! -L "$powerphone_primary_route_patcher" && -x "$powerphone_primary_route_patcher" ]] || \
  die "Frankel primary speaker route patch helper is unsafe or not executable"
[[ ! -L "$powerphone_mixer_paths" ]] || \
  die "generated Frankel mixer paths must not be a symlink"
# The selector recognizes complete scoped stanzas, including prior gain-6
# and current donor-gain-17 profiles, without whole-file hash verification.
if [[ "$check_only" == true ]]; then
  "$powerphone_primary_route_patcher" --check "$powerphone_primary_route_state" \
    "$powerphone_mixer_paths"
else
  "$powerphone_primary_route_patcher" --set-state "$powerphone_primary_route_state" \
    --in-place "$powerphone_mixer_paths"
  "$powerphone_primary_route_patcher" --check "$powerphone_primary_route_state" \
    "$powerphone_mixer_paths"
fi
note "verified Frankel primary speaker route selection: $powerphone_primary_route_state"

# PowerPhone's framework experiment is deliberately opt-in and additive. The
# service registers only IModule/powerphone; Google's extracted default module
# remains the owner of IModule/default, IConfig/default, effects, Bluetooth,
# telephony, and normal policy-selected acoustic routes. The sidecar's exact
# IN_BUS/OUT_BUS research paths require explicit selection and independently
# gate hardware start/transfer on their boot-local readiness properties.
# Materialize the selected state into the generated vendor tree instead of
# leaking an untracked environment variable into Kati/Soong.
powerphone_file_contexts="$generated_dir/sepolicy/vendor/file_contexts"
powerphone_service_contexts="$generated_dir/sepolicy/vendor/service_contexts"
require_file "$powerphone_file_contexts"
require_file "$powerphone_service_contexts"
powerphone_loader_source="$project_root/tools/audio/device/frankel_pdm_loader"
powerphone_loader_generated="$generated_dir/powerphone-pdm-loader"
powerphone_module_source="$project_root/work/upstream/frankel-gki-15739706/modules/frankel_pdm_alsa.ko"
powerphone_module_generated="$generated_dir/stock-kernel/frankel_pdm_alsa.ko"
powerphone_d10_patch_source="$project_root/tools/audio/device/frankel_aoc_d10_patch"
powerphone_d10_patch_generated="$generated_dir/powerphone-d10-patch"
powerphone_speaker_patch_source="$project_root/tools/audio/device/frankel_aoc_speaker_patch"
powerphone_speaker_patch_generated="$generated_dir/powerphone-speaker-patch"
powerphone_d10_bootstrap_source="$project_root/tools/audio/device/frankel_powerphone_d10_bootstrap"
powerphone_d10_bootstrap_generated="$generated_dir/powerphone-d10-bootstrap"
powerphone_staged_player_source="$project_root/tools/audio/device/frankel_aoc_staged_play"
powerphone_staged_player_generated="$generated_dir/powerphone-staged-play"
for path in \
  "$powerphone_d10_patch_source/Android.bp" \
  "$powerphone_d10_patch_source/frankel_aoc_d10_patch.cpp" \
  "$powerphone_speaker_patch_source/Android.bp" \
  "$powerphone_speaker_patch_source/frankel_aoc_speaker_patch.cpp" \
  "$powerphone_speaker_patch_source/patch_model.cpp" \
  "$powerphone_speaker_patch_source/patch_model.h" \
  "$powerphone_d10_bootstrap_source/Android.bp" \
  "$powerphone_d10_bootstrap_source/frankel_powerphone_d10_bootstrap.cpp" \
  "$powerphone_d10_bootstrap_source/frankel_powerphone_d10_bootstrap.rc" \
  "$powerphone_d10_bootstrap_source/frankel_powerphone_audioserver_gate.rc" \
  "$powerphone_d10_bootstrap_source/sepolicy/file_contexts" \
  "$powerphone_d10_bootstrap_source/sepolicy/frankel_powerphone_d10_bootstrap.te" \
  "$powerphone_d10_bootstrap_source/sepolicy/property_contexts" \
  "$powerphone_staged_player_source/Android.bp" \
  "$powerphone_staged_player_source/frankel_aoc_staged_play.cpp"; do
  require_file "$path"
done
powerphone_package_line='PRODUCT_PACKAGES += android.hardware.audio.service-aidl.powerphone'
powerphone_matrix_line='DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE += hardware/interfaces/audio/aidl/default/powerphone/compatibility_matrix.powerphone.xml'
powerphone_loader_package_line='PRODUCT_PACKAGES += powerphone_pdm_loader'
powerphone_bootstrap_package_line='PRODUCT_PACKAGES += frankel_powerphone_d10_bootstrap'
powerphone_staged_player_package_line='PRODUCT_PACKAGES += frankel_aoc_staged_play'
# shellcheck disable=SC2016 # Preserve this Make variable for BoardConfig.
powerphone_module_line='BOARD_VENDOR_KERNEL_MODULES += $(KERNEL_MODULE_DIR)/frankel_pdm_alsa.ko'
powerphone_legacy_policy_line='BOARD_VENDOR_SEPOLICY_DIRS += vendor/google_devices/frankel/powerphone-pdm-loader/sepolicy'
powerphone_d10_policy_line='BOARD_VENDOR_SEPOLICY_DIRS += vendor/google_devices/frankel/powerphone-d10-bootstrap/sepolicy'
powerphone_file_context_line='/vendor/bin/hw/android\.hardware\.audio\.service-aidl\.powerphone u:object_r:hal_audio_default_exec:s0'
powerphone_service_context_line='android.hardware.audio.core.IModule/powerphone u:object_r:hal_audio_service:s0'

set_optional_exact_line() {
  local enabled=$1 line=$2 path=$3 description=$4 count last_byte temporary
  count=$(grep -Fxc -- "$line" "$path" || true)
  (( count <= 1 )) || die "duplicate $description in $path"
  if [[ "$enabled" == true && "$count" == 0 ]]; then
    [[ "$check_only" == false ]] || die "$description is not enabled"
    last_byte=$(tail -c 1 -- "$path" | od -An -tuC | tr -d '[:space:]')
    if [[ -s "$path" && "$last_byte" != 10 ]]; then
      printf '\n' >>"$path"
    fi
    printf '%s\n' "$line" >>"$path"
  elif [[ "$enabled" == false && "$count" == 1 ]]; then
    [[ "$check_only" == false ]] || die "$description remains enabled"
    temporary=$(mktemp --tmpdir="$(dirname -- "$path")" '.powerphone-line.XXXXXX')
    grep -Fvx -- "$line" "$path" >"$temporary"
    chmod --reference="$path" "$temporary"
    mv -- "$temporary" "$path"
  fi
  count=$(grep -Fxc -- "$line" "$path" || true)
  if [[ "$enabled" == true ]]; then
    (( count == 1 )) || die "failed to enable $description"
  else
    (( count == 0 )) || die "failed to disable $description"
  fi
}

set_optional_exact_line "$powerphone_audio_sidecar" \
  "$powerphone_package_line" "$product_makefile" \
  'PowerPhone audio package request'
set_optional_exact_line "$powerphone_audio_sidecar" \
  "$powerphone_matrix_line" "$product_makefile" \
  'PowerPhone audio framework compatibility matrix request'
set_optional_exact_line false \
  "$powerphone_loader_package_line" "$product_makefile" \
  'superseded PowerPhone PDM loader package request'
set_optional_exact_line "$powerphone_audio_sidecar" \
  "$powerphone_bootstrap_package_line" "$product_makefile" \
  'PowerPhone D10 bootstrap package request'
set_optional_exact_line "$powerphone_audio_sidecar" \
  "$powerphone_staged_player_package_line" "$product_makefile" \
  'PowerPhone staged D0 player package request'
set_optional_exact_line false \
  "$powerphone_module_line" "$board_config" \
  'superseded PowerPhone stage-only vendor-DLKM module request'
set_optional_exact_line false \
  "$powerphone_legacy_policy_line" "$board_config" \
  'superseded PowerPhone PDM loader policy directory'
set_optional_exact_line "$powerphone_audio_sidecar" \
  "$powerphone_d10_policy_line" "$board_config" \
  'PowerPhone D10 bootstrap policy directory'
set_optional_exact_line "$powerphone_audio_sidecar" \
  "$powerphone_file_context_line" "$powerphone_file_contexts" \
  'PowerPhone audio executable label'
set_optional_exact_line "$powerphone_audio_sidecar" \
  "$powerphone_service_context_line" "$powerphone_service_contexts" \
  'PowerPhone audio Binder-service label'
unset -f set_optional_exact_line

# Both primary and addressed research playback use physical D5. Let normal
# AudioFlinger presentation completion enter standby without its three-second
# idle hold, so a completed BUS stream does not retain D5 during a later
# primary-route activation. This is not concurrent-client arbitration.
powerphone_standby_patcher="$project_root/tools/audio/patch_frankel_powerphone_standby.py"
powerphone_vendor_props="$generated_dir/sysprop/vendor.prop"
require_file "$powerphone_standby_patcher"
require_file "$powerphone_vendor_props"
powerphone_standby_state=stock
[[ "$powerphone_audio_sidecar" != true ]] || powerphone_standby_state=research
if [[ "$check_only" == true ]]; then
  python3 "$powerphone_standby_patcher" "$powerphone_vendor_props" \
    --state "$powerphone_standby_state" --check
else
  python3 "$powerphone_standby_patcher" "$powerphone_vendor_props" \
    --state "$powerphone_standby_state" --in-place
fi

sync_optional_powerphone_directory() {
  local enabled=$1 source=$2 destination=$3 description=$4 temporary
  [[ -d "$source" && ! -L "$source" ]] || \
    die "$description source directory is missing or unsafe: $source"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -d "$destination" && ! -L "$destination" ]] || \
      die "$description destination is not a plain directory: $destination"
  fi
  if [[ "$enabled" == true ]]; then
    if [[ ! -d "$destination" ]] || \
        ! diff -qr -- "$source" "$destination" >/dev/null; then
      [[ "$check_only" == false ]] || die "$description is not materialized exactly"
      temporary=$(mktemp -d \
        --tmpdir="$(dirname -- "$destination")" '.powerphone-loader.XXXXXX')
      cp -a -- "$source/." "$temporary/"
      if [[ -d "$destination" ]]; then
        rm -rf -- "$destination"
      fi
      mv -- "$temporary" "$destination"
    fi
    diff -qr -- "$source" "$destination" >/dev/null || \
      die "$description differs from its reviewed source"
  elif [[ -e "$destination" || -L "$destination" ]]; then
    [[ "$check_only" == false ]] || die "$description remains enabled"
    rm -rf -- "$destination"
  fi
}

sync_optional_powerphone_module() {
  local enabled=$1 source=$2 destination=$3 name vermagic
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || \
      die "PowerPhone PDM module destination is unsafe: $destination"
  fi
  if [[ "$enabled" == true ]]; then
    require_file "$source"
    command -v modinfo >/dev/null 2>&1 || die 'required command not found: modinfo'
    name=$(modinfo -F name "$source")
    [[ "$name" == frankel_pdm_alsa ]] || \
      die "PowerPhone PDM module has unexpected internal name: $name"
    vermagic=$(modinfo -F vermagic "$source")
    [[ "$vermagic" == \
      '6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k SMP preempt mod_unload modversions aarch64' ]] || \
      die "PowerPhone PDM module has unexpected vermagic: $vermagic"
    if [[ ! -f "$destination" ]] || ! cmp -s -- "$source" "$destination"; then
      [[ "$check_only" == false ]] || die 'PowerPhone PDM module is not staged exactly'
      cp -f -- "$source" "$destination"
    fi
    cmp -s -- "$source" "$destination" || \
      die 'staged PowerPhone PDM module differs from its reviewed build output'
  elif [[ -e "$destination" || -L "$destination" ]]; then
    [[ "$check_only" == false ]] || die 'PowerPhone PDM module remains staged'
    rm -f -- "$destination"
  fi
}

sync_optional_powerphone_directory false \
  "$powerphone_loader_source" "$powerphone_loader_generated" \
  'superseded PowerPhone PDM loader source'
sync_optional_powerphone_module false \
  "$powerphone_module_source" "$powerphone_module_generated"
sync_optional_powerphone_directory "$powerphone_audio_sidecar" \
  "$powerphone_d10_patch_source" "$powerphone_d10_patch_generated" \
  'PowerPhone D10 native patch source'
sync_optional_powerphone_directory "$powerphone_audio_sidecar" \
  "$powerphone_speaker_patch_source" "$powerphone_speaker_patch_generated" \
  'PowerPhone speaker native patch source'
sync_optional_powerphone_directory "$powerphone_audio_sidecar" \
  "$powerphone_d10_bootstrap_source" "$powerphone_d10_bootstrap_generated" \
  'PowerPhone D10 boot orchestrator source'
sync_optional_powerphone_directory "$powerphone_audio_sidecar" \
  "$powerphone_staged_player_source" "$powerphone_staged_player_generated" \
  'PowerPhone staged D0 player source'
unset -f sync_optional_powerphone_directory sync_optional_powerphone_module

if find "$generated_dir/stock-kernel" -maxdepth 1 -type f \
    -name '*modules.load' -exec grep -Flx -- 'frankel_pdm_alsa.ko' {} + | \
    grep -q .; then
  die 'PowerPhone PDM module must never appear in a modules.load file'
fi
note "verified exact PowerPhone audio research selection: $powerphone_audio_sidecar"

note "verified frankel/Laguna generated-vendor policy"
