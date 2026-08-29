#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
# shellcheck source=lib/cubs-dexpreopt.sh disable=SC1091
source "$script_dir/lib/cubs-dexpreopt.sh"
# shellcheck source=lib/cubs-wifi-vintf.sh disable=SC1091
source "$script_dir/lib/cubs-wifi-vintf.sh"

usage() {
  printf 'usage: %s invalidate|create|verify gsi|cubs\n' "$0" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
action=$1
kind=$2
case "$action" in
  invalidate|create|verify) ;;
  *) usage ;;
esac
case "$kind" in
  gsi|cubs) ;;
  *) usage ;;
esac

require_command awk chmod cmp date find jq mkdir mktemp mv od realpath rm sha256sum sort tr unlink unzip

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
case "$kind" in
  gsi)
    out_dir=${AOSP_OUT_DIR:-"$source_dir/out_pixel/gsi"}
    soong_product=gsi_arm64
    ;;
  cubs)
    out_dir=${DEVICE_OUT_DIR:-"$source_dir/out_pixel/cubs"}
    soong_product=$DEVICE_CODENAME
    ;;
esac
out_dir=$(realpath -m -- "$out_dir")
assert_inside_work "$source_dir"
assert_inside_work "$out_dir"
case "$out_dir" in
  "$source_dir"/*) ;;
  *) die "build output directory must be inside the AOSP source tree" ;;
esac

marker="$out_dir/build-completion-$kind.attestation"
if [[ "$action" == verify ]]; then
  [[ -d "$out_dir" && ! -L "$out_dir" ]] || \
    die "$kind build output directory is missing or unsafe"
else
  mkdir -p "$out_dir"
fi

if [[ "$action" == invalidate ]]; then
  if [[ -f "$marker" || -L "$marker" ]]; then
    unlink -- "$marker"
    note "invalidated prior $kind build-completion attestation"
  elif [[ -e "$marker" ]]; then
    die "unsafe build-completion attestation path: $marker"
  else
    note "no prior $kind build-completion attestation"
  fi
  exit 0
fi

case "$action" in
  create)
    [[ ! -e "$marker" && ! -L "$marker" ]] || \
      die "build-completion attestation was not invalidated before the build"
    ;;
  verify)
    [[ -f "$marker" && ! -L "$marker" ]] || \
      die "$kind build has no safe completion attestation; rerun the build"
    ;;
esac

resolved_manifest="$project_root/manifests/resolved.xml"
patch_lock="$project_root/patches/SHA256SUMS"
base_revisions="$project_root/patches/BASE_REVISIONS"
release_env="$project_root/config/release.env"
require_file "$resolved_manifest"
require_file "$patch_lock"
require_file "$base_revisions"
require_file "$release_env"
(
  cd "$project_root/patches"
  sha256sum --check --strict --status SHA256SUMS
) || die "reviewed patch files do not match the patch lock"
"$script_dir/check-source.sh" --allow-patches

hash_regular_output() {
  local path=$1
  local description=$2
  local digest
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || \
    die "$description is missing, empty, or not a regular file: $path"
  digest=$(sha256sum -- "$path")
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "failed to hash $description"
  printf '%s\n' "$digest"
}

resolved_manifest_sha256=$(hash_regular_output \
  "$resolved_manifest" "resolved source manifest")
patch_lock_sha256=$(hash_regular_output "$patch_lock" "patch lock")
base_revisions_sha256=$(hash_regular_output \
  "$base_revisions" "patch-base revision lock")
release_env_sha256=$(hash_regular_output "$release_env" "release configuration")
soong_variables="$out_dir/soong/soong.$soong_product.variables"
soong_variables_sha256=$(hash_regular_output \
  "$soong_variables" "Soong product variables")
# The Armv9 Pixel configuration deliberately enables heap MTE globally. Keep
# that security property exact for cubs while continuing to reject ambient
# sanitizer settings in the generic GSI build.
jq -e --arg kind "$kind" '
  .Allow_missing_dependencies == false and
  .SelinuxIgnoreNeverallows == false and
  .Unbundled_build == false and
  .Unbundled_build_apps == [] and
  .Unbundled_build_image == false and
  .SanitizeHost == [] and
  .SanitizeDevice == (if $kind == "cubs" then ["memtag_heap"] else [] end) and
  .SanitizeDeviceDiag == [] and
  .SanitizeDeviceArch == [] and
  .GcovCoverage == false and
  .ClangCoverage == false and
  .ClangCoverageContinuousMode == false and
  .JavaCoveragePaths == [] and
  .JavaCoverageExcludePaths == [] and
  .NativeCoveragePaths == [] and
  .NativeCoverageExcludePaths == [] and
  .Debuggable == true and
  .Eng == false and
  .BuildType == "release" and
  .BuildBrokenPluginValidation == [] and
  .BuildBrokenClangProperty == false and
  .BuildBrokenClangAsFlags == false and
  .BuildBrokenClangCFlags == false and
  .BuildBrokenEnforceSyspropOwner == false and
  .BuildBrokenTrebleSyspropNeverallow == false and
  .BuildBrokenVendorPropertyNamespace == false and
  .BuildBrokenIncorrectPartitionImages == false and
  .BuildBrokenInputDirModules == [] and
  .BuildBrokenDontCheckSystemSdk == false and
  .BuildBrokenDupSysprop == false and
  .BuildBrokenPrebuiltELFFiles == false and
  .WithDexpreopt == true and
  .ClangTidy == false
' "$soong_variables" >/dev/null || \
  die "$kind output violates the strict Soong build policy"

soong_environment_used="$out_dir/soong/soong.environment.used.$soong_product.build"
soong_environment_used_sha256=$(hash_regular_output \
  "$soong_environment_used" "Soong used-environment record")
relative_out_dir=$(realpath --relative-to="$source_dir" "$out_dir")
expected_build_datetime_file="$relative_out_dir/build_date.txt"
jq -e \
  --arg kind "$kind" \
  --arg product "$soong_product" \
  --arg out_dir "$relative_out_dir" \
  --arg build_datetime_file "$expected_build_datetime_file" \
  --arg build_number "$AOSP_BUILD_NUMBER" \
  --arg build_username "$AOSP_BUILD_USERNAME" \
  --arg build_hostname "$AOSP_BUILD_HOSTNAME" \
  --arg build_datetime "$AOSP_BUILD_DATETIME" '
  type == "array" and
  all(.[];
    type == "object" and
    (keys | sort) == ["Key", "Value"] and
    (.Key | type) == "string" and
    (.Value | type) == "string"
  ) and
  ((map(.Key) | length) == (map(.Key) | unique | length)) and
  all(.[];
    .Value == "" or
    (.Key == "ANDROID_JAVA8_HOME" and
      .Value == "prebuilts/jdk/jdk8/linux-x86") or
    (.Key == "ANDROID_JAVA_HOME" and
      .Value == "prebuilts/jdk/jdk21/linux-x86") or
    (.Key == "BUILD_DATETIME_FILE" and .Value == $build_datetime_file) or
    (.Key == "BUILD_DATETIME" and .Value == $build_datetime) or
    (.Key == "BUILD_HOSTNAME" and .Value == $build_hostname) or
    (.Key == "BUILD_NUMBER" and .Value == $build_number) or
    (.Key == "BUILD_USERNAME" and .Value == $build_username) or
    (.Key == "CC_WRAPPER" and .Value == "/usr/bin/ccache") or
    (.Key == "OUT_DIR" and .Value == $out_dir) or
    (.Key == "SOONG_GENERATES_NINJA_HINT" and .Value == "depend") or
    (.Key == "TARGET_PRODUCT" and .Value == $product) or
    (.Key == "TARGET_RELEASE" and .Value == "aosp_current") or
    (.Key == "USE_CCACHE" and (.Value == "0" or .Value == "1")) or
    (.Key == "USE_STOCK_KERNEL" and $kind == "cubs" and .Value == "true")
  )
' "$soong_environment_used" >/dev/null || \
  die "$kind output used an unaudited nonempty build environment value"
source_lock_sha256=$(
  {
    printf 'resolved_manifest_sha256=%s\n' "$resolved_manifest_sha256"
    printf 'patch_lock_sha256=%s\n' "$patch_lock_sha256"
    printf 'base_revisions_sha256=%s\n' "$base_revisions_sha256"
    printf 'release_env_sha256=%s\n' "$release_env_sha256"
  } | sha256sum
)
source_lock_sha256=${source_lock_sha256%% *}

read_exact_property() {
  local property_file=$1
  local property_name=$2
  local property_values=()
  mapfile -t property_values < <(
    awk -v key="$property_name" \
      'index($0, key "=") == 1 {print substr($0, length(key) + 2)}' \
      "$property_file"
  )
  (( ${#property_values[@]} == 1 )) || \
    die "expected exactly one $property_name in built system properties"
  printf '%s\n' "${property_values[0]}"
}

validate_boot_identity_salts() {
  local misc_info_file=$1
  local expected_salt=$2
  local description=$3
  local property_name
  local actual_args
  local expected_prefix="--salt $expected_salt "

  [[ -f "$misc_info_file" && ! -L "$misc_info_file" && \
     -s "$misc_info_file" ]] || \
    die "$description is missing, empty, or not a regular file"
  for property_name in \
    avb_init_boot_add_hash_footer_args \
    avb_vendor_boot_add_hash_footer_args \
    avb_vendor_kernel_boot_add_hash_footer_args; do
    actual_args=$(read_exact_property "$misc_info_file" "$property_name")
    [[ "$actual_args" == "$expected_prefix"* ]] || die \
      "$description has an incorrect or split identity salt for $property_name"
  done
  if awk '
    BEGIN { found = 0 }
    /^[0-9a-f]{64}([[:space:]]|$)/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$misc_info_file"; then
    die "$description contains an orphaned AVB identity-salt line"
  fi
}

validate_pvmfw_signing_metadata() {
  local misc_info_file=$1
  local description=$2
  local actual_key_path
  local actual_algorithm
  local footer_args
  local expected_salt
  local salt_count=0
  local token_index
  local -a footer_tokens

  actual_key_path=$(read_exact_property \
    "$misc_info_file" avb_pvmfw_signing_key_path)
  actual_algorithm=$(read_exact_property \
    "$misc_info_file" avb_pvmfw_signing_algorithm)
  [[ "$actual_key_path" == \
     external/avb/test/data/testkey_rsa4096.pem ]] || \
    die "$description has an unexpected pvmfw AVB key"
  [[ "$actual_algorithm" == SHA256_RSA4096 ]] || \
    die "$description has an unexpected pvmfw AVB algorithm"
  if grep -Eq \
      '^avb_pvmfw_(key_path|algorithm|rollback_index_location)=' \
      "$misc_info_file"; then
    die "$description incorrectly configures pvmfw as an AVB chain"
  fi

  expected_salt=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  footer_args=$(read_exact_property \
    "$misc_info_file" avb_pvmfw_add_hash_footer_args)
  read -r -a footer_tokens <<< "$footer_args"
  for ((token_index = 0; token_index < ${#footer_tokens[@]}; token_index++)); do
    if [[ "${footer_tokens[token_index]}" == --salt ]]; then
      (( token_index + 1 < ${#footer_tokens[@]} )) || \
        die "$description has a value-less pvmfw AVB salt"
      [[ "${footer_tokens[token_index + 1]}" == "$expected_salt" ]] || \
        die "$description has an unexpected pvmfw AVB salt"
      ((salt_count += 1))
    fi
  done
  (( salt_count == 1 )) || \
    die "$description must contain exactly one deterministic pvmfw AVB salt"
}

system_build_prop="$out_dir/soong/.intermediates/build/soong/system-build.prop/android_common/build.prop"
system_build_prop_sha256=$(hash_regular_output \
  "$system_build_prop" "built system properties")
actual_output_build_id=$(read_exact_property "$system_build_prop" ro.build.id)
actual_system_build_id=$(read_exact_property "$system_build_prop" ro.system.build.id)
actual_framework_security_patch=$(read_exact_property \
  "$system_build_prop" ro.build.version.security_patch)
actual_build_variant=$(read_exact_property "$system_build_prop" ro.build.type)
actual_sdk=$(read_exact_property "$system_build_prop" ro.build.version.sdk)
actual_build_number=$(read_exact_property \
  "$system_build_prop" ro.build.version.incremental)
actual_system_build_number=$(read_exact_property \
  "$system_build_prop" ro.system.build.version.incremental)
actual_build_username=$(read_exact_property "$system_build_prop" ro.build.user)
actual_build_hostname=$(read_exact_property "$system_build_prop" ro.build.host)
actual_build_datetime=$(read_exact_property "$system_build_prop" ro.build.date.utc)
actual_system_build_datetime=$(read_exact_property \
  "$system_build_prop" ro.system.build.date.utc)
actual_build_date=$(read_exact_property "$system_build_prop" ro.build.date)
actual_system_build_date=$(read_exact_property \
  "$system_build_prop" ro.system.build.date)
expected_build_date=$(TZ="$AOSP_BUILD_TIMEZONE" LC_ALL="$AOSP_BUILD_LOCALE" \
  date -d "@$AOSP_BUILD_DATETIME" '+%a %b %d %T %Z %Y')
case "$kind" in
  gsi) expected_output_build_id=$AOSP_BUILD_ID ;;
  cubs) expected_output_build_id=$STOCK_BUILD_ID ;;
esac
[[ "$actual_output_build_id" == "$expected_output_build_id" && \
   "$actual_system_build_id" == "$expected_output_build_id" ]] || \
  die "$kind output build ID does not match $expected_output_build_id"
[[ "$actual_framework_security_patch" == "$AOSP_SECURITY_PATCH" ]] || \
  die "$kind framework SPL does not match $AOSP_SECURITY_PATCH"
[[ "$actual_build_variant" == userdebug ]] || \
  die "$kind output is not userdebug"
[[ "$actual_sdk" == 37 ]] || die "$kind output is not Android SDK 37"
[[ "$actual_build_number" == "$AOSP_BUILD_NUMBER" && \
   "$actual_system_build_number" == "$AOSP_BUILD_NUMBER" ]] || \
  die "$kind output build number is not the pinned reproducible value"
[[ "$actual_build_username" == "$AOSP_BUILD_USERNAME" ]] || \
  die "$kind output embeds an unexpected build username"
[[ "$actual_build_hostname" == "$AOSP_BUILD_HOSTNAME" ]] || \
  die "$kind output embeds an unexpected build hostname"
[[ "$actual_build_datetime" == "$AOSP_BUILD_DATETIME" && \
   "$actual_system_build_datetime" == "$AOSP_BUILD_DATETIME" ]] || \
  die "$kind output build epoch is not the pinned reproducible value"
[[ "$actual_build_date" == "$expected_build_date" && \
   "$actual_system_build_date" == "$expected_build_date" ]] || \
  die "$kind output build date is not rendered in the pinned timezone/locale"

temporary_marker=$(mktemp "$out_dir/.build-completion-$kind.XXXXXX")
cleanup() {
  [[ -z "${temporary_marker:-}" ]] || rm -f -- "$temporary_marker"
  [[ -z "${vintf_misc_info:-}" ]] || rm -f -- "$vintf_misc_info"
  [[ -z "${pvmfw_scratch:-}" ]] || rm -f -- "$pvmfw_scratch"
  [[ -z "${pvmfw_scratch_dir:-}" ]] || rmdir -- "$pvmfw_scratch_dir"
  [[ -z "${dexpreopt_scratch:-}" ]] || rm -f -- "$dexpreopt_scratch"
  [[ -z "${malibu_semantic_scratch:-}" ]] || \
    rm -f -- "$malibu_semantic_scratch"
}
trap cleanup EXIT

{
  printf 'format=pixel-aosp-build-completion-v1\n'
  printf 'kind=%s\n' "$kind"
  printf 'source_lock_sha256=%s\n' "$source_lock_sha256"
  printf 'resolved_manifest_sha256=%s\n' "$resolved_manifest_sha256"
  printf 'patch_lock_sha256=%s\n' "$patch_lock_sha256"
  printf 'base_revisions_sha256=%s\n' "$base_revisions_sha256"
  printf 'release_env_sha256=%s\n' "$release_env_sha256"
  printf 'soong_variables_sha256=%s\n' "$soong_variables_sha256"
  printf 'soong_environment_used_sha256=%s\n' \
    "$soong_environment_used_sha256"
  printf 'strict_build_policy=true\n'
  printf 'allow_missing_dependencies=false\n'
  printf 'selinux_ignore_neverallows=false\n'
  printf 'repo_revision=%s\n' "$REPO_REVISION"
  printf 'aosp_revision=%s\n' "$AOSP_REVISION"
  printf 'source_aosp_build_id=%s\n' "$AOSP_BUILD_ID"
  printf 'output_build_id=%s\n' "$actual_output_build_id"
  printf 'framework_security_patch=%s\n' \
    "$actual_framework_security_patch"
  printf 'build_variant=userdebug\n'
  printf 'build_number=%s\n' "$actual_build_number"
  printf 'build_username=%s\n' "$actual_build_username"
  printf 'build_hostname=%s\n' "$actual_build_hostname"
  printf 'build_datetime=%s\n' "$actual_build_datetime"
  printf 'build_timezone=%s\n' "$AOSP_BUILD_TIMEZONE"
  printf 'build_locale=%s\n' "$AOSP_BUILD_LOCALE"
  printf 'system_build_prop_sha256=%s\n' "$system_build_prop_sha256"
} > "$temporary_marker"

case "$kind" in
  gsi)
    target_name=gsi_arm64-aosp_current-userdebug
    product_out="$out_dir/target/product/generic_arm64"
    artifact_dir=${GSI_ARTIFACT_DIR:-"$project_root/artifacts/gsi"}
    artifact_dir=$(realpath -m -- "$artifact_dir")
    assert_inside_project "$artifact_dir"
    images=(system.img pvmfw.img vbmeta.img)

    printf 'target=%s\n' "$target_name" >> "$temporary_marker"
    printf 'product=generic_arm64\n' >> "$temporary_marker"
    for image_name in "${images[@]}"; do
      product_digest=$(hash_regular_output \
        "$product_out/$image_name" "GSI product output $image_name")
      artifact_digest=$(hash_regular_output \
        "$artifact_dir/$image_name" "GSI staged artifact $image_name")
      [[ "$product_digest" == "$artifact_digest" ]] || \
        die "GSI staged artifact differs from product output: $image_name"
      image_key=${image_name%.img}
      printf 'output_%s_sha256=%s\n' "$image_key" "$product_digest" \
        >> "$temporary_marker"
    done
    [[ -x "$out_dir/host/linux-x86/bin/avbtool" ]] || \
      die "built avbtool is not executable"
    avbtool_digest=$(hash_regular_output \
      "$out_dir/host/linux-x86/bin/avbtool" "built avbtool")
    printf 'host_avbtool_sha256=%s\n' "$avbtool_digest" \
      >> "$temporary_marker"
    ;;
  cubs)
    declare -A cubs_dexpreopt_hashes=()
    declare -A cubs_direct_image_hashes=()
    declare -A cubs_target_image_hashes=()
    declare -A cubs_malibu_semantics=()
    declare -A cubs_wifi_vintf_hashes=()
    target_name="${DEVICE_CODENAME}-aosp_current-userdebug"
    product_out="$out_dir/target/product/$DEVICE_CODENAME"
    validate_cubs_wifi_vintf_soong_installs "$source_dir" "$out_dir"
    dexpreopt_config="$out_dir/soong/dexpreopt-$DEVICE_CODENAME.config"
    validate_cubs_dexpreopt_config "$dexpreopt_config"
    dexpreopt_config_sha256=$(hash_regular_output \
      "$dexpreopt_config" "cubs dexpreopt configuration")
    vendor_attestation="$project_root/work/attestations/${DEVICE_CODENAME}-generated-vendor.attestation"
    vendor_attestation_sha256=$(hash_regular_output \
      "$vendor_attestation" "generated-vendor attestation")
    product_images=(
      boot.img
      init_boot.img
      dtbo.img
      vendor_boot.img
      vendor_kernel_boot.img
    )

    build_number_file="$out_dir/soong/build_number.txt"
    build_datetime_file="$out_dir/build_date.txt"
    hash_regular_output "$build_number_file" "build-number identity file" \
      >/dev/null
    hash_regular_output "$build_datetime_file" "build-date identity file" \
      >/dev/null
    expected_boot_identity_salt=$(
      sha256sum -- "$build_number_file" "$build_datetime_file" | \
        awk '{printf "%s", $1}'
    )
    [[ "$expected_boot_identity_salt" =~ ^[0-9a-f]{128}$ ]] || \
      die "failed to derive the 128-character boot-image identity salt"
    product_misc_info="$product_out/misc_info.txt"
    validate_boot_identity_salts "$product_misc_info" \
      "$expected_boot_identity_salt" "cubs product misc_info"
    validate_pvmfw_signing_metadata \
      "$product_misc_info" "cubs product misc_info"

    target_files_root="$product_out/obj/PACKAGING/target_files_intermediates"
    [[ -d "$target_files_root" && ! -L "$target_files_root" ]] || \
      die "target-files output directory is missing or unsafe: $target_files_root"
    target_files_root=$(realpath -e -- "$target_files_root")
    if [[ -n "${CUBS_TARGET_FILES:-}" ]]; then
      target_files=$(realpath -e -- "$CUBS_TARGET_FILES")
      case "$target_files" in
        "$target_files_root"/*) ;;
        *) die "CUBS_TARGET_FILES must be inside the current cubs output tree" ;;
      esac
      [[ -f "$target_files" && ! -L "$target_files" ]] || \
        die "CUBS_TARGET_FILES is not a regular file"
    else
      mapfile -d '' -t target_files_candidates < <(
        find "$target_files_root" -type f -name '*target_files*.zip' -print0 | \
          LC_ALL=C sort -z
      )
      (( ${#target_files_candidates[@]} == 1 )) || die \
        "expected exactly one target-files package; found ${#target_files_candidates[@]}; set CUBS_TARGET_FILES explicitly"
      target_files=${target_files_candidates[0]}
    fi
    target_files_name=${target_files##*/}
    [[ "$target_files_name" =~ ^[-A-Za-z0-9._+=]+$ ]] || \
      die "unsafe target-files package name"
    unzip -tq "$target_files" >/dev/null || die "invalid target-files ZIP"
    mapfile -t misc_info_entries < <(
      unzip -Z1 "$target_files" | \
        awk '$0 == "META/misc_info.txt" {print}'
    )
    (( ${#misc_info_entries[@]} == 1 )) || \
      die "target-files must contain exactly one META/misc_info.txt"
    vintf_misc_info=$(mktemp "$out_dir/.target-files-misc-info.XXXXXX")
    unzip -p "$target_files" META/misc_info.txt > "$vintf_misc_info" || \
      die "failed to read target-files VINTF metadata"
    validate_boot_identity_salts "$vintf_misc_info" \
      "$expected_boot_identity_salt" "cubs target-files misc_info"
    validate_pvmfw_signing_metadata \
      "$vintf_misc_info" "cubs target-files misc_info"
    cmp -s -- "$product_misc_info" "$vintf_misc_info" || \
      die "cubs product and target-files misc_info differ"
    note "verified cubs product and target-files boot identity salts"
    for image_name in "${product_images[@]}"; do
      mapfile -t target_image_entries < <(
        unzip -Z1 "$target_files" | \
          awk -v expected="IMAGES/$image_name" '$0 == expected {print}'
      )
      (( ${#target_image_entries[@]} == 1 )) || die \
        "target-files must contain exactly one IMAGES/$image_name"
      product_digest=$(hash_regular_output \
        "$product_out/$image_name" "cubs product output $image_name")
      target_files_digest=$(unzip -p "$target_files" "IMAGES/$image_name" | \
        sha256sum)
      target_files_digest=${target_files_digest%% *}
      [[ "$target_files_digest" =~ ^[0-9a-f]{64}$ ]] || \
        die "failed to hash target-files IMAGES/$image_name"
      [[ "$product_digest" == "$target_files_digest" ]] || die \
        "cubs product and target-files images differ: $image_name"
      cubs_direct_image_hashes["$image_name"]=$product_digest
    done
    note "verified five cubs product and target-files leaf images are byte-identical"
    for image_name in pvmfw.img vbmeta.img; do
      mapfile -t target_image_entries < <(
        unzip -Z1 "$target_files" | \
          awk -v expected="IMAGES/$image_name" '$0 == expected {print}'
      )
      (( ${#target_image_entries[@]} == 1 )) || \
        die "target-files must contain exactly one IMAGES/$image_name"
      target_files_digest=$(
        unzip -p "$target_files" "IMAGES/$image_name" | sha256sum
      )
      target_files_digest=${target_files_digest%% *}
      [[ "$target_files_digest" =~ ^[0-9a-f]{64}$ ]] || \
        die "failed to hash target-files IMAGES/$image_name"
      cubs_target_image_hashes["$image_name"]=$target_files_digest
    done
    avbtool="$out_dir/host/linux-x86/bin/avbtool"
    pvmfw_key="$source_dir/external/avb/test/data/testkey_rsa4096.pem"
    [[ -x "$avbtool" && ! -L "$avbtool" ]] || \
      die "built avbtool is missing or unsafe"
    [[ -f "$pvmfw_key" && ! -L "$pvmfw_key" && -s "$pvmfw_key" ]] || \
      die "AOSP RSA-4096 pvmfw signing key is missing or unsafe"
    pvmfw_scratch_dir=$(mktemp -d "$out_dir/.target-files-pvmfw.XXXXXX")
    pvmfw_scratch="$pvmfw_scratch_dir/pvmfw.img"
    unzip -p "$target_files" IMAGES/pvmfw.img > "$pvmfw_scratch" || \
      die "failed to extract target-files pvmfw.img"
    "$avbtool" verify_image --image "$pvmfw_scratch" --key "$pvmfw_key" \
      >/dev/null || die \
      "target-files pvmfw.img is not signed by the pinned RSA-4096 key"
    pvmfw_info=$("$avbtool" info_image --image "$pvmfw_scratch") || \
      die "failed to inspect target-files pvmfw AVB metadata"
    [[ $(awk '/^Algorithm:/ {print $2}' <<< "$pvmfw_info") == \
       SHA256_RSA4096 ]] || \
      die "target-files pvmfw.img uses an unexpected AVB algorithm"
    (( $(grep -c '^    Hash descriptor:$' <<< "$pvmfw_info" || true) == 1 )) || \
      die "target-files pvmfw.img must contain exactly one hash descriptor"
    mapfile -t pvmfw_partitions < <(
      sed -n 's/^[[:space:]]*Partition Name:[[:space:]]*//p' \
        <<< "$pvmfw_info"
    )
    (( ${#pvmfw_partitions[@]} == 1 )) && \
      [[ "${pvmfw_partitions[0]}" == pvmfw ]] || \
      die "target-files pvmfw.img has an unexpected AVB partition descriptor"
    mapfile -t pvmfw_salts < <(
      sed -n 's/^[[:space:]]*Salt:[[:space:]]*//p' <<< "$pvmfw_info"
    )
    (( ${#pvmfw_salts[@]} == 1 )) && \
      [[ "${pvmfw_salts[0]}" == \
         e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]] || \
      die "target-files pvmfw.img has an unexpected AVB hash salt"
    rm -f -- "$pvmfw_scratch"
    pvmfw_scratch=
    rmdir -- "$pvmfw_scratch_dir"
    pvmfw_scratch_dir=
    note "verified target-files pvmfw signature and canonical root vbmeta"
    validate_cubs_wifi_vintf_target_files \
      "$target_files" cubs_wifi_vintf_hashes
    dexpreopt_source_jar="$source_dir/vendor/google_devices/$DEVICE_CODENAME/proprietary/system_ext/framework/malibu-plugin-provider.jar"
    dexpreopt_scratch="$temporary_marker.malibu-plugin-provider"
    validate_cubs_standalone_dexpreopt \
      "$target_files" "$product_out" "$dexpreopt_source_jar" \
      "$dexpreopt_scratch" cubs_dexpreopt_hashes
    malibu_semantic_config="$project_root/config/cubs-dexpreopt.env"
    malibu_semantic_config_sha256=$(hash_regular_output \
      "$malibu_semantic_config" "cubs Malibu dexpreopt semantic policy")
    malibu_intermediate="$out_dir/soong/.intermediates/vendor/google_devices/$DEVICE_CODENAME/proprietary/malibu-plugin-provider/android_common"
    malibu_product="$product_out/system_ext/framework"
    malibu_semantic_scratch="$temporary_marker.malibu-oatdump"
    validate_cubs_malibu_dexpreopt_semantics \
      "$malibu_intermediate/dexpreopt/malibu-plugin-provider/oat/arm64/javalib.invocation" \
      "$out_dir/host/linux-x86/bin/oatdump" \
      "$malibu_product/malibu-plugin-provider.jar" \
      "$malibu_product/oat/arm64/malibu-plugin-provider.odex" \
      "$malibu_product/oat/arm64/malibu-plugin-provider.vdex" \
      "$malibu_semantic_scratch" "$malibu_semantic_config" \
      cubs_malibu_semantics
    malibu_semantic_scratch=
    note "verified cubs standalone system_server JAR and arm64 dexpreopt semantics"
    actual_vintf_enforce=$(read_exact_property \
      "$vintf_misc_info" vintf_enforce)
    rm -f -- "$vintf_misc_info"
    vintf_misc_info=
    [[ "$actual_vintf_enforce" == true ]] || \
      die "target-files does not enforce VINTF compatibility"
    target_files_sha256=$(hash_regular_output \
      "$target_files" "cubs target-files package")
    check_target_files_vintf="$out_dir/host/linux-x86/bin/check_target_files_vintf"
    checkvintf="$out_dir/host/linux-x86/bin/checkvintf"
    [[ -x "$check_target_files_vintf" && ! -L "$check_target_files_vintf" ]] || \
      die "built check_target_files_vintf is missing or unsafe"
    [[ -x "$checkvintf" && ! -L "$checkvintf" ]] || \
      die "built checkvintf is missing or unsafe"
    note "checking exact cubs target-files VINTF compatibility"
    PATH="$out_dir/host/linux-x86/bin:$PATH" \
      "$check_target_files_vintf" "$target_files" || \
      die "cubs target-files failed VINTF compatibility"
    check_target_files_vintf_sha256=$(hash_regular_output \
      "$check_target_files_vintf" "built check_target_files_vintf")
    checkvintf_sha256=$(hash_regular_output \
      "$checkvintf" "built checkvintf")

    printf 'target=%s\n' "$target_name" >> "$temporary_marker"
    printf 'product=%s\n' "$DEVICE_CODENAME" >> "$temporary_marker"
    printf 'stock_vendor_build=%s\n' "$STOCK_BUILD_ID" >> "$temporary_marker"
    printf 'generated_vendor_attestation_sha256=%s\n' \
      "$vendor_attestation_sha256" >> "$temporary_marker"
    printf 'boot_identity_salt=%s\n' "$expected_boot_identity_salt" \
      >> "$temporary_marker"
    printf 'dexpreopt_config_sha256=%s\n' "$dexpreopt_config_sha256" \
      >> "$temporary_marker"
    printf 'malibu_dexpreopt_semantic_config_sha256=%s\n' \
      "$malibu_semantic_config_sha256" >> "$temporary_marker"
    printf 'target_files_name=%s\n' "$target_files_name" >> "$temporary_marker"
    printf 'target_files_sha256=%s\n' "$target_files_sha256" \
      >> "$temporary_marker"
    printf 'wifi_hostapd_vendor_manifest_sha256=%s\n' \
      "${cubs_wifi_vintf_hashes[wifi_hostapd_vendor_manifest_sha256]}" \
      >> "$temporary_marker"
    printf 'wifi_supplicant_vendor_manifest_sha256=%s\n' \
      "${cubs_wifi_vintf_hashes[wifi_supplicant_vendor_manifest_sha256]}" \
      >> "$temporary_marker"
    printf 'malibu_plugin_provider_jar_sha256=%s\n' \
      "${cubs_dexpreopt_hashes[malibu_plugin_provider_jar_sha256]}" \
      >> "$temporary_marker"
    printf 'malibu_plugin_provider_arm64_odex_sha256=%s\n' \
      "${cubs_dexpreopt_hashes[malibu_plugin_provider_arm64_odex_sha256]}" \
      >> "$temporary_marker"
    printf 'malibu_plugin_provider_arm64_vdex_sha256=%s\n' \
      "${cubs_dexpreopt_hashes[malibu_plugin_provider_arm64_vdex_sha256]}" \
      >> "$temporary_marker"
    for semantic_key in \
      malibu_dexpreopt_invocation_sha256 \
      cubs_host_oatdump_sha256 \
      malibu_target_classes_dex_crc32 \
      malibu_effective_class_loader_context_sha256 \
      malibu_oatdump_semantics_sha256; do
      printf '%s=%s\n' "$semantic_key" \
        "${cubs_malibu_semantics[$semantic_key]}" >> "$temporary_marker"
    done
    printf 'host_check_target_files_vintf_sha256=%s\n' \
      "$check_target_files_vintf_sha256" >> "$temporary_marker"
    printf 'host_checkvintf_sha256=%s\n' "$checkvintf_sha256" \
      >> "$temporary_marker"
    for image_name in "${product_images[@]}"; do
      product_digest=$(hash_regular_output \
        "$product_out/$image_name" "cubs product output $image_name")
      [[ "$product_digest" == \
         "${cubs_direct_image_hashes[$image_name]}" ]] || die \
        "cubs product output changed during attestation: $image_name"
      image_key=${image_name%.img}
      printf 'output_%s_sha256=%s\n' "$image_key" "$product_digest" \
        >> "$temporary_marker"
    done
    printf 'output_pvmfw_sha256=%s\n' \
      "${cubs_target_image_hashes[pvmfw.img]}" >> "$temporary_marker"
    printf 'output_vbmeta_sha256=%s\n' \
      "${cubs_target_image_hashes[vbmeta.img]}" >> "$temporary_marker"
    [[ -x "$out_dir/host/linux-x86/bin/img_from_target_files" ]] || \
      die "built img_from_target_files is not executable"
    [[ -x "$out_dir/host/linux-x86/bin/avbtool" ]] || \
      die "built avbtool is not executable"
    img_from_target_files_digest=$(hash_regular_output \
      "$out_dir/host/linux-x86/bin/img_from_target_files" \
      "built img_from_target_files")
    avbtool_digest=$(hash_regular_output \
      "$out_dir/host/linux-x86/bin/avbtool" "built avbtool")
    printf 'host_img_from_target_files_sha256=%s\n' \
      "$img_from_target_files_digest" >> "$temporary_marker"
    printf 'host_avbtool_sha256=%s\n' "$avbtool_digest" \
      >> "$temporary_marker"
    ;;
esac

case "$action" in
  create)
    # Recheck immediately before the atomic rename to catch a concurrent build
    # claiming the same output directory.
    [[ ! -e "$marker" && ! -L "$marker" ]] || \
      die "build-completion attestation was not invalidated before the build"
    chmod 0644 "$temporary_marker"
    mv -- "$temporary_marker" "$marker"
    temporary_marker=
    note "created $kind build-completion attestation: $marker"
    ;;
  verify)
    cmp -s -- "$marker" "$temporary_marker" || \
      die "$kind outputs do not match their successful-build attestation"
    note "$kind successful-build outputs verified"
    ;;
esac
