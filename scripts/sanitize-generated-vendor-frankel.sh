#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"
# shellcheck source=lib/cubs-sepolicy.sh
source "$script_dir/lib/cubs-sepolicy.sh"

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

verify_sha256 \
  fe764b7b159dce99b74b08912b1b9009197578c0df33285809ec98cc535d0976 \
  "$product_makefile"
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

note "verified frankel/Laguna generated-vendor policy"
