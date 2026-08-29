#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
# shellcheck source=../lib/common.sh disable=SC1091
source "$project_root/scripts/lib/common.sh"
# shellcheck source=../lib/cubs-dexpreopt.sh disable=SC1091
source "$project_root/scripts/lib/cubs-dexpreopt.sh"

require_command cp grep jq mkdir mktemp od rm sha256sum tr unlink zip unzip

scratch_parent="$project_root/work/dexpreopt-validation-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

fixture_tree=
fixture_product=
fixture_archive=
fixture_target_root=
fixture_product_root=
fixture_source_jar=
fixture_scratch=
jar_counter=0

write_payload() {
  local path=$1
  local payload=$2
  mkdir -p "${path%/*}"
  printf '%s\n' "$payload" > "$path"
}

make_mock_jar() {
  local output=$1
  local dex_payload=$2
  local jar_tree
  ((jar_counter += 1))
  jar_tree="$scratch_dir/jar-contents-$jar_counter"
  mkdir -p "$jar_tree/META-INF" "${output%/*}"
  if [[ -e "$output" || -L "$output" ]]; then
    unlink -- "$output"
  fi
  printf '%s\n' "$dex_payload" > "$jar_tree/classes.dex"
  printf '%s\n' 'Manifest-Version: 1.0' > "$jar_tree/META-INF/MANIFEST.MF"
  (
    cd "$jar_tree"
    zip -q -X "$output" classes.dex META-INF/MANIFEST.MF
  )
}

pack_fixture() {
  local top=${fixture_target_root%%/*}
  rm -f -- "$fixture_archive"
  (
    cd "$fixture_tree"
    zip -q -r "$fixture_archive" "$top"
  )
}

make_fixture() {
  local name=$1
  fixture_target_root=$2
  fixture_product_root=$3
  fixture_tree="$scratch_dir/$name-target-files"
  fixture_product="$scratch_dir/$name-product"
  fixture_archive="$scratch_dir/$name-target-files.zip"
  fixture_source_jar="$scratch_dir/$name-source.jar"
  fixture_scratch="$scratch_dir/$name-artifact-scratch"
  mkdir -p "$fixture_tree" "$fixture_product"
  make_mock_jar "$fixture_source_jar" \
    'mock aligned standalone system_server classes.dex'
  mkdir -p \
    "$fixture_tree/$fixture_target_root/framework" \
    "$fixture_product/$fixture_product_root/framework"
  cp "$fixture_source_jar" \
    "$fixture_tree/$fixture_target_root/framework/malibu-plugin-provider.jar"
  cp "$fixture_source_jar" \
    "$fixture_product/$fixture_product_root/framework/malibu-plugin-provider.jar"
  write_payload \
    "$fixture_tree/$fixture_target_root/framework/oat/arm64/malibu-plugin-provider.odex" \
    $'mock ELF prefix\noat\nmock arm64 odex suffix'
  write_payload \
    "$fixture_tree/$fixture_target_root/framework/oat/arm64/malibu-plugin-provider.vdex" \
    'vdex mock arm64 payload'
  write_payload \
    "$fixture_product/$fixture_product_root/framework/oat/arm64/malibu-plugin-provider.odex" \
    $'mock ELF prefix\noat\nmock arm64 odex suffix'
  write_payload \
    "$fixture_product/$fixture_product_root/framework/oat/arm64/malibu-plugin-provider.vdex" \
    'vdex mock arm64 payload'
  pack_fixture
}

assert_positive() {
  local description=$1
  local expected
  local -A hashes=()
  validate_cubs_standalone_dexpreopt \
    "$fixture_archive" "$fixture_product" "$fixture_source_jar" \
    "$fixture_scratch" hashes
  expected=$(sha256sum -- \
    "$fixture_product/$fixture_product_root/framework/malibu-plugin-provider.jar")
  expected=${expected%% *}
  [[ "${hashes[malibu_plugin_provider_jar_sha256]}" == "$expected" ]] || \
    die "$description returned the wrong JAR digest"
  expected=$(sha256sum -- \
    "$fixture_product/$fixture_product_root/framework/oat/arm64/malibu-plugin-provider.odex")
  expected=${expected%% *}
  [[ "${hashes[malibu_plugin_provider_arm64_odex_sha256]}" == \
     "$expected" ]] || die "$description returned the wrong odex digest"
  expected=$(sha256sum -- \
    "$fixture_product/$fixture_product_root/framework/oat/arm64/malibu-plugin-provider.vdex")
  expected=${expected%% *}
  [[ "${hashes[malibu_plugin_provider_arm64_vdex_sha256]}" == \
     "$expected" ]] || die "$description returned the wrong vdex digest"
}

expect_failure() {
  local description=$1
  local expected_message=$2
  local log="$scratch_dir/${description//[^a-zA-Z0-9]/-}.log"
  if (
    declare -A hashes=()
    validate_cubs_standalone_dexpreopt \
      "$fixture_archive" "$fixture_product" "$fixture_source_jar" \
      "$fixture_scratch" hashes
  ) >"$log" 2>&1; then
    die "$description unexpectedly passed"
  fi
  grep -Fq -- "$expected_message" "$log" || {
    sed -n '1,120p' "$log" >&2
    die "$description failed for an unexpected reason"
  }
}

dexpreopt_config="$scratch_dir/dexpreopt-cubs.config"
printf '%s\n' \
  '{"DisablePreopt":false,"OnlyPreoptArtBootImage":false,"HasSystemOther":false,"StandaloneSystemServerJars":["system_ext:malibu-plugin-provider"]}' \
  > "$dexpreopt_config"
validate_cubs_dexpreopt_config "$dexpreopt_config"
printf '%s\n' \
  '{"DisablePreopt":true,"OnlyPreoptArtBootImage":false,"HasSystemOther":false,"StandaloneSystemServerJars":["system_ext:malibu-plugin-provider"]}' \
  > "$dexpreopt_config"
if (validate_cubs_dexpreopt_config "$dexpreopt_config") \
    >"$scratch_dir/tampered-config.log" 2>&1; then
  die "disabled dexpreopt configuration unexpectedly passed"
fi
grep -Fq \
  'cubs dexpreopt configuration does not enable the pinned standalone system_server JAR policy' \
  "$scratch_dir/tampered-config.log" || \
  die "disabled dexpreopt configuration failed for an unexpected reason"

make_fixture canonical SYSTEM_EXT system_ext
assert_positive 'canonical separate-system_ext layout'

make_fixture embedded-system-ext SYSTEM/system_ext system/system_ext
expect_failure embedded-system-ext \
  'expected exactly one cubs dexpreopt entry for framework/malibu-plugin-provider.jar; found 0'

make_fixture tampered SYSTEM_EXT system_ext
write_payload \
  "$fixture_tree/$fixture_target_root/framework/oat/arm64/malibu-plugin-provider.vdex" \
  'tampered target-files vdex'
pack_fixture
expect_failure tampered \
  'cubs target-files dexpreopt entry differs from product output'

make_fixture source-mismatch SYSTEM_EXT system_ext
make_mock_jar \
  "$fixture_tree/$fixture_target_root/framework/malibu-plugin-provider.jar" \
  'different but valid installed classes.dex'
cp "$fixture_tree/$fixture_target_root/framework/malibu-plugin-provider.jar" \
  "$fixture_product/$fixture_product_root/framework/malibu-plugin-provider.jar"
pack_fixture
expect_failure source-mismatch \
  'installed malibu-plugin-provider.jar differs from generated vendor source'

make_fixture invalid-jar SYSTEM_EXT system_ext
write_payload \
  "$fixture_tree/$fixture_target_root/framework/malibu-plugin-provider.jar" \
  'not a ZIP/JAR'
cp "$fixture_tree/$fixture_target_root/framework/malibu-plugin-provider.jar" \
  "$fixture_product/$fixture_product_root/framework/malibu-plugin-provider.jar"
pack_fixture
expect_failure invalid-jar \
  'target-files malibu-plugin-provider.jar is not a valid ZIP/JAR'

make_fixture bad-odex-magic SYSTEM_EXT system_ext
write_payload \
  "$fixture_tree/$fixture_target_root/framework/oat/arm64/malibu-plugin-provider.odex" \
  'mock artifact without an OAT header'
cp "$fixture_tree/$fixture_target_root/framework/oat/arm64/malibu-plugin-provider.odex" \
  "$fixture_product/$fixture_product_root/framework/oat/arm64/malibu-plugin-provider.odex"
pack_fixture
expect_failure bad-odex-magic \
  'target-files malibu-plugin-provider.odex lacks exactly one oat magic'

make_fixture bad-vdex-magic SYSTEM_EXT system_ext
write_payload \
  "$fixture_tree/$fixture_target_root/framework/oat/arm64/malibu-plugin-provider.vdex" \
  'bad-vdex-header'
cp "$fixture_tree/$fixture_target_root/framework/oat/arm64/malibu-plugin-provider.vdex" \
  "$fixture_product/$fixture_product_root/framework/oat/arm64/malibu-plugin-provider.vdex"
pack_fixture
expect_failure bad-vdex-magic \
  'target-files malibu-plugin-provider.vdex has invalid magic'

make_fixture missing-target SYSTEM_EXT system_ext
rm -f -- \
  "$fixture_tree/$fixture_target_root/framework/oat/arm64/malibu-plugin-provider.odex"
pack_fixture
expect_failure missing-target \
  'expected exactly one cubs dexpreopt entry for framework/oat/arm64/malibu-plugin-provider.odex; found 0'

make_fixture missing-product SYSTEM_EXT system_ext
rm -f -- \
  "$fixture_product/$fixture_product_root/framework/malibu-plugin-provider.jar"
expect_failure missing-product \
  'cubs product dexpreopt artifact is missing, empty, or unsafe'

printf '%s\n' \
  'mocked cubs standalone system_server dexpreopt positive/tamper/missing validation passed'
