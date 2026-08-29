#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
# shellcheck source=../lib/common.sh disable=SC1091
source "$project_root/scripts/lib/common.sh"
# shellcheck source=../lib/cubs-dexpreopt.sh disable=SC1091
source "$project_root/scripts/lib/cubs-dexpreopt.sh"
# shellcheck source=../../config/cubs-dexpreopt.env disable=SC1091
source "$project_root/config/cubs-dexpreopt.env"

require_command awk chmod cp grep mkdir mktemp sed sha256sum unlink unzip zip

scratch_parent="$project_root/work/dexpreopt-semantic-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

invocation="$scratch_dir/javalib.invocation"
oatdump="$scratch_dir/oatdump"
oatdump_report="$oatdump.report"
jar="$scratch_dir/malibu-plugin-provider.jar"
canonical_jar="$scratch_dir/canonical-malibu-plugin-provider.jar"
odex="$scratch_dir/malibu-plugin-provider.odex"
vdex="$scratch_dir/malibu-plugin-provider.vdex"
scratch_report="$scratch_dir/oatdump-output.txt"
semantic_config="$scratch_dir/cubs-dexpreopt.env"
jar_tree="$scratch_dir/jar-tree"

mkdir -p "$jar_tree"
printf '%s\n' 'mock arm64 ODEX' > "$odex"
printf '%s\n' 'mock arm64 VDEX' > "$vdex"

# shellcheck disable=SC2016 # emit a mock script whose expansions occur later
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ $# == 4 ]] || { printf "ERROR: wrong oatdump argument count\n" >&2; exit 64; }' \
  '[[ $1 == --oat-file=* && $2 == --dex-file=* && $3 == --header-only && $4 == --no-disassemble ]] || { printf "ERROR: wrong oatdump grammar\n" >&2; exit 64; }' \
  'if [[ -e "${0}.fail" ]]; then' \
  '  printf "ERROR: forced mock oatdump failure\n" >&2' \
  '  exit 23' \
  'fi' \
  'sed -n "1,$ p" "${0}.report"' \
  > "$oatdump"
chmod 0755 "$oatdump"

make_mock_jar() {
  local payload=$1
  if [[ -e "$jar" || -L "$jar" ]]; then
    unlink -- "$jar"
  fi
  printf '%s\n' "$payload" > "$jar_tree/classes.dex"
  (
    cd "$jar_tree"
    zip -q -X "$jar" classes.dex
  )
}

local_target_crc() {
  local path=$1
  local crc
  crc=$(LC_ALL=C unzip -v "$path" | \
    awk '$8 == "classes.dex" { print tolower($7) }')
  [[ "$crc" =~ ^[0-9a-f]{8}$ ]] || \
    die "mock target CRC could not be determined"
  printf '%s\n' "$crc"
}

join_by_colon() {
  local output_name=$1
  shift
  local -n output_ref=$output_name
  local entry
  output_ref=
  for entry in "$@"; do
    [[ -z "$output_ref" ]] || output_ref+=:
    output_ref+=$entry
  done
}

declare -a expected_names=() expected_locations=() expected_checksums=()
cubs_malibu_expected_clc \
  expected_names expected_locations expected_checksums
(( ${#expected_checksums[@]} == 18 )) || \
  die "mock expected class-loader checksum table is incomplete"

declare -a bcp_inputs=() bcp_locations=()
for ((index = 0; index < 52; index += 1)); do
  bcp_inputs+=("out_pixel/cubs/soong/dexpreopt_arm64/dex_bootjars_input/mock-$index.jar")
  bcp_locations+=("/apex/mock.$index/javalib/mock-$index.jar")
done
bcp_inputs[0]='out_pixel/cubs/soong/dexpreopt_arm64/dex_bootjars_input/core-oj.jar'
bcp_inputs[51]='out_pixel/cubs/soong/dexpreopt_arm64/dex_mainlinejars_input/framework-wifi.jar'
bcp_locations[0]='/apex/com.android.art/javalib/core-oj.jar'
bcp_locations[51]='/apex/com.android.wifi/javalib/framework-wifi.jar'
bcp_input_payload=
bcp_location_payload=
join_by_colon bcp_input_payload "${bcp_inputs[@]}"
join_by_colon bcp_location_payload "${bcp_locations[@]}"
bcp_input_record="-Xbootclasspath:$bcp_input_payload"
bcp_location_record="-Xbootclasspath-locations:$bcp_location_payload"

write_invocation() {
  local collector=$1
  local clc_count=$2
  local clc_input_payload=''
  local stored_clc_payload=''
  local -a records=()
  local record

  for ((index = 0; index < clc_count; index += 1)); do
    [[ -z "$clc_input_payload" ]] || clc_input_payload+=:
    [[ -z "$stored_clc_payload" ]] || stored_clc_payload+=:
    clc_input_payload+="out_pixel/cubs/soong/system_server_dexjars/${expected_names[$index]}"
    stored_clc_payload+="${expected_locations[$index]}"
  done
  records=(
    'out_pixel/cubs/host/linux-x86/bin/dex2oatd'
    '--avoid-storing-invocation'
    '--write-invocation-to=out_pixel/cubs/soong/.intermediates/vendor/google_devices/cubs/proprietary/malibu-plugin-provider/android_common/dexpreopt/malibu-plugin-provider/oat/arm64/javalib.invocation'
    '--runtime-arg'
    '-Xms64m'
    '--runtime-arg'
    '-Xmx512m'
    '--runtime-arg'
    "$bcp_input_record"
    '--runtime-arg'
    "$bcp_location_record"
    "--class-loader-context=PCL[];PCL[$clc_input_payload]"
    "--stored-class-loader-context=PCL[];PCL[$stored_clc_payload]"
    '--boot-image=out_pixel/cubs/soong/dexpreopt_arm64/dex_bootjars/android/system/framework/boot.art:out_pixel/cubs/soong/dexpreopt_arm64/dex_mainlinejars/android/system/framework/boot-framework-adservices.art'
    '--dex-file=out_pixel/cubs/soong/.intermediates/vendor/google_devices/cubs/proprietary/malibu-plugin-provider/android_common/malibu-plugin-provider.jar'
    '--dex-location=/system_ext/framework/malibu-plugin-provider.jar'
    '--oat-file=out_pixel/cubs/soong/.intermediates/vendor/google_devices/cubs/proprietary/malibu-plugin-provider/android_common/dexpreopt/malibu-plugin-provider/oat/arm64/javalib.odex'
    '--android-root=out_pixel/cubs/empty'
    '--instruction-set=arm64'
    '--instruction-set-variant=cortex-a76'
    '--instruction-set-features=default'
    '--oat-symbols=out_pixel/cubs/soong/.intermediates/vendor/google_devices/cubs/proprietary/malibu-plugin-provider/android_common/dexpreopt/malibu-plugin-provider/oat/arm64/javalib.symbols.odex'
    '--generate-debug-info'
    '--strip'
    '--generate-build-id'
    '--abort-on-hard-verifier-error'
    '--force-determinism'
    '--no-inline-from=core-oj.jar'
    '--runtime-arg'
    "$collector"
    '--copy-dex-files=false'
    '--compiler-filter=speed'
    '--generate-mini-debug-info'
    '--compilation-reason=prebuilt'
    "--assume-value=Landroid/os/Build\$VERSION;->SDK_INT:37"
  )
  : > "$invocation"
  for ((index = 0; index < ${#records[@]}; index += 1)); do
    record=${records[$index]}
    if (( index + 1 == ${#records[@]} )); then
      printf '%s' "$record" >> "$invocation"
    else
      printf '%s\n' "$record" >> "$invocation"
    fi
  done
}

effective_clc=
cubs_malibu_effective_clc effective_clc

write_oatdump_report() {
  local isa=$1
  local features=$2
  local classpath=$3
  local extra_line=${4-}
  {
    printf '%s\n' \
      'MAGIC:' \
      'oat' \
      "$CUBS_MALIBU_OAT_VERSION" \
      '' \
      'LOCATION:' \
      "$odex" \
      '' \
      'CHECKSUM:' \
      "0x$CUBS_MALIBU_OAT_HEADER_CHECKSUM" \
      '' \
      'INSTRUCTION SET:' \
      "$isa" \
      '' \
      'INSTRUCTION SET FEATURES:' \
      "$features" \
      '' \
      'DEX FILE COUNT:' \
      '1' \
      '' \
      'KEY VALUE STORE:' \
      'apex-versions = ////////////////////////////////////////////' \
      'assume-value-sdk-int = 37' \
      "bootclasspath = $bcp_location_payload" \
      "bootclasspath-checksums = $CUBS_MALIBU_BOOTCLASSPATH_CHECKSUMS" \
      "classpath = $classpath" \
      'compilation-reason = prebuilt' \
      'compiler-filter = speed' \
      'concurrent-copying = false' \
      'debuggable = false' \
      'dex2oat-cmdline = ' \
      'enable-profile-code = false' \
      'native-debuggable = false' \
      'requires-image = false' \
      '' \
      'SIZE:' \
      '1'
    [[ -z "$extra_line" ]] || printf '%s\n' "$extra_line"
  } > "$oatdump_report"
}

clear_scratch_report() {
  [[ ! -e "$scratch_report" && ! -L "$scratch_report" ]] || \
    unlink -- "$scratch_report"
}

expect_failure() {
  local description=$1
  local expected_message=$2
  local log="$scratch_dir/${description//[^a-zA-Z0-9]/-}.log"
  clear_scratch_report
  if (
    # shellcheck disable=SC2034 # consumed through a validator nameref
    declare -A semantic=()
    validate_cubs_malibu_dexpreopt_semantics \
      "$invocation" "$oatdump" "$jar" "$odex" "$vdex" \
      "$scratch_report" "$semantic_config" semantic
  ) > "$log" 2>&1; then
    die "$description unexpectedly passed"
  fi
  grep -Fq -- "$expected_message" "$log" || {
    sed -n '1,120p' "$log" >&2
    die "$description failed for an unexpected reason"
  }
  clear_scratch_report
}

make_mock_jar 'canonical Malibu classes.dex payload'
cp "$jar" "$canonical_jar"
write_invocation '-Xgc:CMC' 18
write_oatdump_report \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET" \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES" "$effective_clc"

# Mock artifacts exercise the production parser while preserving independent
# fixed release pins in config/release.env for real builds.
CUBS_MALIBU_INVOCATION_SHA256=$(sha256sum -- "$invocation")
CUBS_MALIBU_INVOCATION_SHA256=${CUBS_MALIBU_INVOCATION_SHA256%% *}
CUBS_MALIBU_BCP_INPUT_SHA256=$(cubs_sha256_text "$bcp_input_record")
CUBS_MALIBU_BCP_LOCATIONS_SHA256=$(cubs_sha256_text "$bcp_location_record")
mapfile -t canonical_records < "$invocation"
CUBS_MALIBU_CLC_INPUT_SHA256=$(cubs_sha256_text "${canonical_records[11]}")
CUBS_MALIBU_STORED_CLC_SHA256=$(cubs_sha256_text "${canonical_records[12]}")
CUBS_MALIBU_HOST_OATDUMP_SHA256=$(sha256sum -- "$oatdump")
CUBS_MALIBU_HOST_OATDUMP_SHA256=${CUBS_MALIBU_HOST_OATDUMP_SHA256%% *}
CUBS_MALIBU_TARGET_DEX_CRC32=$(local_target_crc "$jar")

write_mock_semantic_config() {
  printf '%s\n' \
    "CUBS_MALIBU_INVOCATION_SHA256=$CUBS_MALIBU_INVOCATION_SHA256" \
    "CUBS_MALIBU_BCP_INPUT_SHA256=$CUBS_MALIBU_BCP_INPUT_SHA256" \
    "CUBS_MALIBU_BCP_LOCATIONS_SHA256=$CUBS_MALIBU_BCP_LOCATIONS_SHA256" \
    "CUBS_MALIBU_CLC_INPUT_SHA256=$CUBS_MALIBU_CLC_INPUT_SHA256" \
    "CUBS_MALIBU_STORED_CLC_SHA256=$CUBS_MALIBU_STORED_CLC_SHA256" \
    "CUBS_MALIBU_EFFECTIVE_CLC_SHA256=$CUBS_MALIBU_EFFECTIVE_CLC_SHA256" \
    "CUBS_MALIBU_HOST_OATDUMP_SHA256=$CUBS_MALIBU_HOST_OATDUMP_SHA256" \
    "CUBS_MALIBU_TARGET_DEX_CRC32=$CUBS_MALIBU_TARGET_DEX_CRC32" \
    "CUBS_MALIBU_OAT_VERSION=$CUBS_MALIBU_OAT_VERSION" \
    "CUBS_MALIBU_OAT_HEADER_CHECKSUM=$CUBS_MALIBU_OAT_HEADER_CHECKSUM" \
    "CUBS_MALIBU_OAT_INSTRUCTION_SET=$CUBS_MALIBU_OAT_INSTRUCTION_SET" \
    "CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES=$CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES" \
    "CUBS_MALIBU_BOOTCLASSPATH_CHECKSUMS='$CUBS_MALIBU_BOOTCLASSPATH_CHECKSUMS'" \
    > "$semantic_config"
}
write_mock_semantic_config

clear_scratch_report
declare -A positive_semantics=()
validate_cubs_malibu_dexpreopt_semantics \
  "$invocation" "$oatdump" "$jar" "$odex" "$vdex" \
  "$scratch_report" "$semantic_config" positive_semantics
[[ "${positive_semantics[malibu_dexpreopt_invocation_sha256]}" == \
     "$CUBS_MALIBU_INVOCATION_SHA256" && \
   "${positive_semantics[cubs_host_oatdump_sha256]}" == \
     "$CUBS_MALIBU_HOST_OATDUMP_SHA256" && \
   "${positive_semantics[malibu_target_classes_dex_crc32]}" == \
     "$CUBS_MALIBU_TARGET_DEX_CRC32" && \
   "${positive_semantics[malibu_effective_class_loader_context_sha256]}" == \
     "$CUBS_MALIBU_EFFECTIVE_CLC_SHA256" && \
   "${positive_semantics[malibu_oatdump_semantics_sha256]}" =~ \
     ^[0-9a-f]{64}$ ]] || \
  die "canonical Malibu semantic validation returned incomplete evidence"

write_invocation '-Xgc:CC' 18
expect_failure altered-cmc \
  'cubs Malibu dexpreopt invocation record 30 is not the pinned value'
write_invocation '-Xgc:CMC' 18

write_invocation '-Xgc:CMC' 17
expect_failure shortened-clc \
  'cubs Malibu class-loader-context input record differs from the pinned Android 17 r1 semantics'
write_invocation '-Xgc:CMC' 18

wrong_services_clc=${effective_clc/services.jar\*1799210233/services.jar\*1799210234}
write_oatdump_report \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET" \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES" "$wrong_services_clc"
expect_failure wrong-services-checksum \
  'cubs Malibu oatdump checksum-bearing stored class-loader context is not pinned'

write_oatdump_report X86_64 \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES" "$effective_clc"
expect_failure wrong-instruction-set \
  'cubs Malibu oatdump instruction set is not pinned'

write_oatdump_report \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET" 'default' "$effective_clc"
expect_failure wrong-instruction-features \
  'cubs Malibu oatdump instruction-set features are not pinned'

write_oatdump_report \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET" \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES" "$effective_clc"
make_mock_jar 'different target classes.dex payload with a different CRC'
[[ "$(local_target_crc "$jar")" != "$CUBS_MALIBU_TARGET_DEX_CRC32" ]] || \
  die "wrong-target-CRC fixture unexpectedly preserved the canonical CRC"
expect_failure wrong-target-crc \
  'cubs Malibu target classes.dex CRC32 differs from the pinned build'
cp "$canonical_jar" "$jar"

: > "$oatdump.fail"
expect_failure oatdump-execution-failure \
  'pinned cubs host oatdump rejected the Malibu JAR/ODEX/VDEX set'
unlink -- "$oatdump.fail"

write_oatdump_report \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET" \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES" "$effective_clc" \
  'ERROR: mock parser accepted corrupt trailing metadata'
expect_failure oatdump-reported-error \
  'pinned cubs host oatdump report contains an error or warning'
write_oatdump_report \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET" \
  "$CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES" "$effective_clc"

saved_oatdump_sha256=$CUBS_MALIBU_HOST_OATDUMP_SHA256
CUBS_MALIBU_HOST_OATDUMP_SHA256=$(printf '0%.0s' {1..64})
write_mock_semantic_config
expect_failure wrong-oatdump-hash \
  'cubs host oatdump differs from the pinned Android 17 r1 build'
CUBS_MALIBU_HOST_OATDUMP_SHA256=$saved_oatdump_sha256
write_mock_semantic_config

printf '%s\n' \
  'mocked cubs Malibu invocation/CMC/CLC/CRC/oatdump semantic validation passed'
