#!/usr/bin/env bash

# Validate the prebuilt standalone system_server JAR whose upstream
# dexpreopt_systemserver_check is disabled by the pinned GrapheneOS patch.
# Callers must source lib/common.sh first so die() is available.

validate_cubs_dexpreopt_config() {
  local config=$1
  [[ -f "$config" && ! -L "$config" && -s "$config" ]] || \
    die "cubs dexpreopt configuration is missing, empty, or unsafe"
  jq -e '
    .DisablePreopt == false and
    .OnlyPreoptArtBootImage == false and
    .HasSystemOther == false and
    .StandaloneSystemServerJars == ["system_ext:malibu-plugin-provider"]
  ' "$config" >/dev/null || \
    die "cubs dexpreopt configuration does not enable the pinned standalone system_server JAR policy"
}

cubs_sha256_text() {
  local value=$1
  local digest
  digest=$(printf '%s' "$value" | sha256sum)
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || \
    die "failed to hash cubs dexpreopt semantic text"
  printf '%s\n' "$digest"
}

cubs_require_sha256_constant() {
  local name=$1
  local value=${!name-}
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || \
    die "invalid or missing pinned cubs dexpreopt constant: $name"
}

cubs_malibu_expected_clc() {
  local names_name=$1
  local locations_name=$2
  local checksums_name=$3
  local -n names_ref=$names_name
  local -n locations_ref=$locations_name
  local -n checksums_ref=$checksums_name

  # shellcheck disable=SC2034 # returned through the caller's nameref
  names_ref=(
    com.android.location.provider.jar
    services.jar
    service-adservices.jar
    service-sdksandbox.jar
    service-appsearch.jar
    service-art.jar
    service-compos.jar
    service-configinfrastructure.jar
    service-crashrecovery.jar
    service-healthfitness.jar
    service-media-s.jar
    service-npumanager.jar
    service-ondevicepersonalization.jar
    service-permission.jar
    service-anomaly-detector.jar
    service-rkp.jar
    service-telecom.jar
    service-virtualization.jar
  )
  # shellcheck disable=SC2034 # returned through the caller's nameref
  locations_ref=(
    /system/framework/com.android.location.provider.jar
    /system/framework/services.jar
    /apex/com.android.adservices/javalib/service-adservices.jar
    /apex/com.android.adservices/javalib/service-sdksandbox.jar
    /apex/com.android.appsearch/javalib/service-appsearch.jar
    /apex/com.android.art/javalib/service-art.jar
    /apex/com.android.compos/javalib/service-compos.jar
    /apex/com.android.configinfrastructure/javalib/service-configinfrastructure.jar
    /apex/com.android.crashrecovery/javalib/service-crashrecovery.jar
    /apex/com.android.healthfitness/javalib/service-healthfitness.jar
    /apex/com.android.media/javalib/service-media-s.jar
    /apex/com.android.npumanager/javalib/service-npumanager.jar
    /apex/com.android.ondevicepersonalization/javalib/service-ondevicepersonalization.jar
    /apex/com.android.permission/javalib/service-permission.jar
    /apex/com.android.profiling/javalib/service-anomaly-detector.jar
    /apex/com.android.rkpd/javalib/service-rkp.jar
    /apex/com.android.telephonycore/javalib/service-telecom.jar
    /apex/com.android.virt/javalib/service-virtualization.jar
  )
  # shellcheck disable=SC2034 # returned through the caller's nameref
  checksums_ref=(
    1154147141
    1799210233
    1001009613
    4267864558
    2841290063
    1770337302
    2257985963
    38306297
    2899682267
    512638394
    351192476
    2595718617
    180365847
    1946835241
    3621658134
    607796744
    50313661
    63015338
  )
}

cubs_malibu_effective_clc() {
  local output_name=$1
  local -n output_ref=$output_name
  # shellcheck disable=SC2034 # names is populated through a helper nameref
  local -a names=() locations=() checksums=()
  local index

  cubs_malibu_expected_clc names locations checksums
  output_ref='PCL[];PCL['
  for ((index = 0; index < ${#locations[@]}; index += 1)); do
    (( index == 0 )) || output_ref+=:
    output_ref+="${locations[$index]}*${checksums[$index]}"
  done
  output_ref+=']'
}

cubs_assert_text_sha256() {
  local description=$1
  local value=$2
  local expected=$3
  local actual
  actual=$(cubs_sha256_text "$value")
  [[ "$actual" == "$expected" ]] || \
    die "cubs Malibu $description differs from the pinned Android 17 r1 semantics"
}

cubs_assert_exact_invocation_record() {
  local -n records_ref=$1
  local number=$2
  local expected=$3
  [[ "${records_ref[$((number - 1))]}" == "$expected" ]] || \
    die "cubs Malibu dexpreopt invocation record $number is not the pinned value"
}

cubs_oatdump_section_value() {
  local report=$1
  local label=$2
  local output_name=$3
  local -n output_ref=$output_name
  local -a values=()

  mapfile -t values < <(
    awk -v heading="$label:" '
      $0 == heading {
        if (getline > 0) print
      }
    ' "$report"
  )
  (( ${#values[@]} == 1 )) || \
    die "cubs Malibu oatdump report does not contain exactly one $label section"
  output_ref=${values[0]}
}

# Validate the exact dex2oat command and OAT semantics observed for the pinned
# Android 17 r1 cubs build. The host oatdump is itself built from and pinned to
# that source lock. The supplied VDEX must be the ODEX sibling oatdump resolves.
validate_cubs_malibu_dexpreopt_semantics() {
  local invocation=$1
  local oatdump=$2
  local jar=$3
  local odex=$4
  local vdex=$5
  local scratch_report=$6
  local semantic_config=$7
  local output_name=$8
  local -n result=$output_name
  local scratch_parent=${scratch_report%/*}
  local invocation_digest oatdump_digest target_crc
  local bcp_input bcp_locations clc_input stored_clc
  local bcp_prefix='-Xbootclasspath:'
  local bcp_locations_prefix='-Xbootclasspath-locations:'
  local clc_prefix='--class-loader-context=PCL[];PCL['
  local stored_clc_prefix='--stored-class-loader-context=PCL[];PCL['
  local effective_clc effective_clc_digest
  local magic oat_version oat_checksum instruction_set instruction_features
  local dex_file_count report_semantics report_semantics_digest
  local payload index key value
  local -a records=() bcp_entries=() bcp_location_entries=()
  local -a clc_entries=() stored_clc_entries=() dex_metadata=() magic_values=()
  local -a expected_clc_names=() expected_clc_locations=() expected_clc_checksums=()
  local -a kv_lines=()
  local -A kv=()
  local CUBS_MALIBU_INVOCATION_SHA256=
  local CUBS_MALIBU_BCP_INPUT_SHA256=
  local CUBS_MALIBU_BCP_LOCATIONS_SHA256=
  local CUBS_MALIBU_CLC_INPUT_SHA256=
  local CUBS_MALIBU_STORED_CLC_SHA256=
  local CUBS_MALIBU_EFFECTIVE_CLC_SHA256=
  local CUBS_MALIBU_HOST_OATDUMP_SHA256=
  local CUBS_MALIBU_TARGET_DEX_CRC32=
  local CUBS_MALIBU_OAT_VERSION=
  local CUBS_MALIBU_OAT_HEADER_CHECKSUM=
  local CUBS_MALIBU_OAT_INSTRUCTION_SET=
  local CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES=
  local CUBS_MALIBU_BOOTCLASSPATH_CHECKSUMS=

  [[ -f "$semantic_config" && ! -L "$semantic_config" && \
     -s "$semantic_config" ]] || \
    die "cubs Malibu dexpreopt semantic configuration is missing, empty, or unsafe"
  # shellcheck source=/dev/null
  source "$semantic_config"

  for key in \
    CUBS_MALIBU_INVOCATION_SHA256 \
    CUBS_MALIBU_BCP_INPUT_SHA256 \
    CUBS_MALIBU_BCP_LOCATIONS_SHA256 \
    CUBS_MALIBU_CLC_INPUT_SHA256 \
    CUBS_MALIBU_STORED_CLC_SHA256 \
    CUBS_MALIBU_EFFECTIVE_CLC_SHA256 \
    CUBS_MALIBU_HOST_OATDUMP_SHA256; do
    cubs_require_sha256_constant "$key"
  done
  [[ "${CUBS_MALIBU_TARGET_DEX_CRC32-}" =~ ^[0-9a-f]{8}$ ]] || \
    die "invalid or missing pinned cubs Malibu target dex CRC32"
  [[ "${CUBS_MALIBU_OAT_VERSION-}" =~ ^[0-9]{3}$ ]] || \
    die "invalid or missing pinned cubs Malibu OAT version"
  [[ "${CUBS_MALIBU_OAT_HEADER_CHECKSUM-}" =~ ^[0-9a-f]{8}$ ]] || \
    die "invalid or missing pinned cubs Malibu OAT header checksum"
  [[ -n "${CUBS_MALIBU_OAT_INSTRUCTION_SET-}" && \
     -n "${CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES-}" && \
     -n "${CUBS_MALIBU_BOOTCLASSPATH_CHECKSUMS-}" ]] || \
    die "missing pinned cubs Malibu oatdump semantics"

  [[ -f "$invocation" && ! -L "$invocation" && -s "$invocation" ]] || \
    die "cubs Malibu dexpreopt invocation is missing, empty, or unsafe"
  [[ -f "$oatdump" && ! -L "$oatdump" && -x "$oatdump" ]] || \
    die "pinned cubs host oatdump is missing or unsafe"
  [[ -f "$jar" && ! -L "$jar" && -s "$jar" ]] || \
    die "cubs Malibu dexpreopt JAR is missing, empty, or unsafe"
  [[ -f "$odex" && ! -L "$odex" && -s "$odex" ]] || \
    die "cubs Malibu arm64 ODEX is missing, empty, or unsafe"
  [[ -f "$vdex" && ! -L "$vdex" && -s "$vdex" ]] || \
    die "cubs Malibu arm64 VDEX is missing, empty, or unsafe"
  [[ "${odex%.odex}.vdex" == "$vdex" ]] || \
    die "cubs Malibu ODEX/VDEX are not a same-stem sibling pair"
  [[ "$scratch_parent" != "$scratch_report" && -d "$scratch_parent" && \
     ! -L "$scratch_parent" && ! -e "$scratch_report" && \
     ! -L "$scratch_report" ]] || \
    die "unsafe cubs Malibu oatdump scratch path"

  mapfile -t records < "$invocation"
  (( ${#records[@]} == 35 )) || \
    die "cubs Malibu dexpreopt invocation must contain exactly 35 logical records"

  cubs_assert_exact_invocation_record records 1 \
    'out_pixel/cubs/host/linux-x86/bin/dex2oatd'
  cubs_assert_exact_invocation_record records 2 '--avoid-storing-invocation'
  cubs_assert_exact_invocation_record records 3 \
    '--write-invocation-to=out_pixel/cubs/soong/.intermediates/vendor/google_devices/cubs/proprietary/malibu-plugin-provider/android_common/dexpreopt/malibu-plugin-provider/oat/arm64/javalib.invocation'
  cubs_assert_exact_invocation_record records 4 '--runtime-arg'
  cubs_assert_exact_invocation_record records 5 '-Xms64m'
  cubs_assert_exact_invocation_record records 6 '--runtime-arg'
  cubs_assert_exact_invocation_record records 7 '-Xmx512m'
  cubs_assert_exact_invocation_record records 8 '--runtime-arg'
  cubs_assert_exact_invocation_record records 10 '--runtime-arg'
  cubs_assert_exact_invocation_record records 14 \
    '--boot-image=out_pixel/cubs/soong/dexpreopt_arm64/dex_bootjars/android/system/framework/boot.art:out_pixel/cubs/soong/dexpreopt_arm64/dex_mainlinejars/android/system/framework/boot-framework-adservices.art'
  cubs_assert_exact_invocation_record records 15 \
    '--dex-file=out_pixel/cubs/soong/.intermediates/vendor/google_devices/cubs/proprietary/malibu-plugin-provider/android_common/malibu-plugin-provider.jar'
  cubs_assert_exact_invocation_record records 16 \
    '--dex-location=/system_ext/framework/malibu-plugin-provider.jar'
  cubs_assert_exact_invocation_record records 17 \
    '--oat-file=out_pixel/cubs/soong/.intermediates/vendor/google_devices/cubs/proprietary/malibu-plugin-provider/android_common/dexpreopt/malibu-plugin-provider/oat/arm64/javalib.odex'
  cubs_assert_exact_invocation_record records 18 '--android-root=out_pixel/cubs/empty'
  cubs_assert_exact_invocation_record records 19 '--instruction-set=arm64'
  cubs_assert_exact_invocation_record records 20 \
    '--instruction-set-variant=cortex-a76'
  cubs_assert_exact_invocation_record records 21 \
    '--instruction-set-features=default'
  cubs_assert_exact_invocation_record records 22 \
    '--oat-symbols=out_pixel/cubs/soong/.intermediates/vendor/google_devices/cubs/proprietary/malibu-plugin-provider/android_common/dexpreopt/malibu-plugin-provider/oat/arm64/javalib.symbols.odex'
  cubs_assert_exact_invocation_record records 23 '--generate-debug-info'
  cubs_assert_exact_invocation_record records 24 '--strip'
  cubs_assert_exact_invocation_record records 25 '--generate-build-id'
  cubs_assert_exact_invocation_record records 26 '--abort-on-hard-verifier-error'
  cubs_assert_exact_invocation_record records 27 '--force-determinism'
  cubs_assert_exact_invocation_record records 28 '--no-inline-from=core-oj.jar'
  cubs_assert_exact_invocation_record records 29 '--runtime-arg'
  cubs_assert_exact_invocation_record records 30 '-Xgc:CMC'
  cubs_assert_exact_invocation_record records 31 '--copy-dex-files=false'
  cubs_assert_exact_invocation_record records 32 '--compiler-filter=speed'
  cubs_assert_exact_invocation_record records 33 '--generate-mini-debug-info'
  cubs_assert_exact_invocation_record records 34 '--compilation-reason=prebuilt'
  cubs_assert_exact_invocation_record records 35 \
    "--assume-value=Landroid/os/Build\$VERSION;->SDK_INT:37"

  bcp_input=${records[8]}
  bcp_locations=${records[10]}
  clc_input=${records[11]}
  stored_clc=${records[12]}
  cubs_assert_text_sha256 'boot-class-path input record' "$bcp_input" \
    "$CUBS_MALIBU_BCP_INPUT_SHA256"
  cubs_assert_text_sha256 'boot-class-path location record' "$bcp_locations" \
    "$CUBS_MALIBU_BCP_LOCATIONS_SHA256"
  cubs_assert_text_sha256 'class-loader-context input record' "$clc_input" \
    "$CUBS_MALIBU_CLC_INPUT_SHA256"
  cubs_assert_text_sha256 'stored class-loader-context record' "$stored_clc" \
    "$CUBS_MALIBU_STORED_CLC_SHA256"

  [[ "${bcp_input:0:${#bcp_prefix}}" == "$bcp_prefix" ]] || \
    die "cubs Malibu dexpreopt boot class path has invalid grammar"
  payload=${bcp_input:${#bcp_prefix}}
  IFS=: read -r -a bcp_entries <<< "$payload"
  (( ${#bcp_entries[@]} == 52 )) || \
    die "cubs Malibu dexpreopt boot class path must contain exactly 52 JARs"
  [[ "${bcp_entries[0]}" == \
       'out_pixel/cubs/soong/dexpreopt_arm64/dex_bootjars_input/core-oj.jar' && \
     "${bcp_entries[51]}" == \
       'out_pixel/cubs/soong/dexpreopt_arm64/dex_mainlinejars_input/framework-wifi.jar' ]] || \
    die "cubs Malibu dexpreopt boot class path endpoints are not pinned"

  [[ "${bcp_locations:0:${#bcp_locations_prefix}}" == \
     "$bcp_locations_prefix" ]] || \
    die "cubs Malibu dexpreopt boot-class-path locations have invalid grammar"
  payload=${bcp_locations:${#bcp_locations_prefix}}
  IFS=: read -r -a bcp_location_entries <<< "$payload"
  (( ${#bcp_location_entries[@]} == 52 )) || \
    die "cubs Malibu dexpreopt boot-class-path locations must contain exactly 52 JARs"
  [[ "${bcp_location_entries[0]}" == \
       '/apex/com.android.art/javalib/core-oj.jar' && \
     "${bcp_location_entries[51]}" == \
       '/apex/com.android.wifi/javalib/framework-wifi.jar' ]] || \
    die "cubs Malibu dexpreopt boot-class-path location endpoints are not pinned"

  cubs_malibu_expected_clc \
    expected_clc_names expected_clc_locations expected_clc_checksums
  [[ "${clc_input:0:${#clc_prefix}}" == "$clc_prefix" && \
     "${clc_input: -1}" == ']' ]] || \
    die "cubs Malibu dexpreopt class-loader context has invalid grammar"
  payload=${clc_input:${#clc_prefix}:${#clc_input}-${#clc_prefix}-1}
  IFS=: read -r -a clc_entries <<< "$payload"
  (( ${#clc_entries[@]} == 18 )) || \
    die "cubs Malibu dexpreopt class-loader context must contain exactly 18 JARs"
  for ((index = 0; index < 18; index += 1)); do
    [[ "${clc_entries[$index]}" == \
       "out_pixel/cubs/soong/system_server_dexjars/${expected_clc_names[$index]}" ]] || \
      die "cubs Malibu dexpreopt class-loader context JAR $((index + 1)) is not pinned"
  done

  [[ "${stored_clc:0:${#stored_clc_prefix}}" == "$stored_clc_prefix" && \
     "${stored_clc: -1}" == ']' ]] || \
    die "cubs Malibu stored class-loader context has invalid grammar"
  payload=${stored_clc:${#stored_clc_prefix}:${#stored_clc}-${#stored_clc_prefix}-1}
  IFS=: read -r -a stored_clc_entries <<< "$payload"
  (( ${#stored_clc_entries[@]} == 18 )) || \
    die "cubs Malibu stored class-loader context must contain exactly 18 JARs"
  for ((index = 0; index < 18; index += 1)); do
    [[ "${stored_clc_entries[$index]}" == \
       "${expected_clc_locations[$index]}" ]] || \
      die "cubs Malibu stored class-loader context JAR $((index + 1)) is not pinned"
  done

  invocation_digest=$(sha256sum -- "$invocation")
  invocation_digest=${invocation_digest%% *}
  [[ "$invocation_digest" == "$CUBS_MALIBU_INVOCATION_SHA256" ]] || \
    die "cubs Malibu dexpreopt invocation differs byte-for-byte from the pinned build"

  unzip -tq "$jar" >/dev/null || \
    die "cubs Malibu dexpreopt JAR is not a valid ZIP/JAR"
  mapfile -t dex_metadata < <(
    LC_ALL=C unzip -v "$jar" | awk '
      $8 ~ /^classes([0-9]+)?[.]dex$/ { print tolower($7) " " $8 }
    '
  )
  (( ${#dex_metadata[@]} == 1 )) || \
    die "cubs Malibu target JAR must contain exactly one classes.dex entry"
  read -r target_crc value <<< "${dex_metadata[0]}"
  [[ "$value" == classes.dex && "$target_crc" =~ ^[0-9a-f]{8}$ ]] || \
    die "cubs Malibu target classes.dex metadata is malformed"
  [[ "$target_crc" == "$CUBS_MALIBU_TARGET_DEX_CRC32" ]] || \
    die "cubs Malibu target classes.dex CRC32 differs from the pinned build"

  oatdump_digest=$(sha256sum -- "$oatdump")
  oatdump_digest=${oatdump_digest%% *}
  [[ "$oatdump_digest" == "$CUBS_MALIBU_HOST_OATDUMP_SHA256" ]] || \
    die "cubs host oatdump differs from the pinned Android 17 r1 build"

  if ! ANDROID_LOG_TAGS='*:e' "$oatdump" \
      "--oat-file=$odex" "--dex-file=$jar" \
      --header-only --no-disassemble > "$scratch_report" 2>&1; then
    die "pinned cubs host oatdump rejected the Malibu JAR/ODEX/VDEX set"
  fi
  [[ -f "$scratch_report" && ! -L "$scratch_report" && \
     -s "$scratch_report" ]] || \
    die "pinned cubs host oatdump produced an empty or unsafe report"
  if LC_ALL=C grep -Eiq \
      '(^|[[:space:]])(error|fatal|failed|failure|warning)(:|[[:space:]])' \
      "$scratch_report"; then
    die "pinned cubs host oatdump report contains an error or warning"
  fi

  mapfile -t magic_values < <(
    awk '
      $0 == "MAGIC:" {
        if (getline > 0) print
        if (getline > 0) print
      }
    ' "$scratch_report"
  )
  (( ${#magic_values[@]} == 2 )) || \
    die "cubs Malibu oatdump report does not contain one complete OAT magic/version header"
  magic=${magic_values[0]}
  oat_version=${magic_values[1]}
  [[ "$magic" == oat && "$oat_version" == "$CUBS_MALIBU_OAT_VERSION" ]] || \
    die "cubs Malibu oatdump OAT magic/version is not pinned"

  cubs_oatdump_section_value "$scratch_report" CHECKSUM oat_checksum
  cubs_oatdump_section_value "$scratch_report" 'INSTRUCTION SET' instruction_set
  cubs_oatdump_section_value \
    "$scratch_report" 'INSTRUCTION SET FEATURES' instruction_features
  cubs_oatdump_section_value "$scratch_report" 'DEX FILE COUNT' dex_file_count
  [[ "$oat_checksum" == "0x$CUBS_MALIBU_OAT_HEADER_CHECKSUM" ]] || \
    die "cubs Malibu oatdump OAT header checksum is not pinned"
  [[ "$instruction_set" == "$CUBS_MALIBU_OAT_INSTRUCTION_SET" ]] || \
    die "cubs Malibu oatdump instruction set is not pinned"
  [[ "$instruction_features" == \
     "$CUBS_MALIBU_OAT_INSTRUCTION_SET_FEATURES" ]] || \
    die "cubs Malibu oatdump instruction-set features are not pinned"
  [[ "$dex_file_count" == 1 ]] || \
    die "cubs Malibu oatdump must report exactly one dex file"

  (( $(grep -Fxc 'KEY VALUE STORE:' "$scratch_report") == 1 )) || \
    die "cubs Malibu oatdump report does not contain exactly one key-value store"
  mapfile -t kv_lines < <(
    awk '
      found && $0 == "" { exit }
      found { print }
      $0 == "KEY VALUE STORE:" { found = 1 }
    ' "$scratch_report"
  )
  (( ${#kv_lines[@]} == 13 )) || \
    die "cubs Malibu oatdump key-value store must contain exactly 13 records"
  for value in "${kv_lines[@]}"; do
    [[ "$value" == *' = '* ]] || \
      die "cubs Malibu oatdump key-value record has invalid grammar"
    key=${value%% = *}
    [[ "$key" =~ ^[a-z0-9-]+$ ]] || \
      die "cubs Malibu oatdump key-value name has invalid grammar"
    [[ ! -v 'kv[$key]' ]] || \
      die "cubs Malibu oatdump key-value store contains a duplicate $key"
    kv[$key]=${value#* = }
  done

  effective_clc='PCL[];PCL['
  for ((index = 0; index < 18; index += 1)); do
    (( index == 0 )) || effective_clc+=:
    effective_clc+="${expected_clc_locations[$index]}*${expected_clc_checksums[$index]}"
  done
  effective_clc+=']'
  effective_clc_digest=$(cubs_sha256_text "$effective_clc")
  [[ "$effective_clc_digest" == "$CUBS_MALIBU_EFFECTIVE_CLC_SHA256" ]] || \
    die "internal cubs Malibu checksum-bearing class-loader-context pin is inconsistent"
  # Compare bootclasspath to invocation record 11 after its prefix; payload was
  # reused while parsing the CLC above, so recover it explicitly here.
  payload=${bcp_locations:${#bcp_locations_prefix}}
  [[ "${kv[apex-versions]-missing}" == \
       '////////////////////////////////////////////' ]] || \
    die "cubs Malibu oatdump APEX-version state is not pinned"
  [[ "${kv[assume-value-sdk-int]-missing}" == 37 ]] || \
    die "cubs Malibu oatdump assumed SDK is not 37"
  [[ "${kv[bootclasspath]-missing}" == "$payload" ]] || \
    die "cubs Malibu oatdump boot class path differs from the invocation"
  [[ "${kv[bootclasspath-checksums]-missing}" == \
     "$CUBS_MALIBU_BOOTCLASSPATH_CHECKSUMS" ]] || \
    die "cubs Malibu oatdump boot-class-path checksums are not pinned"
  [[ "${kv[classpath]-missing}" == "$effective_clc" ]] || \
    die "cubs Malibu oatdump checksum-bearing stored class-loader context is not pinned"
  [[ "${kv[compilation-reason]-missing}" == prebuilt && \
     "${kv[compiler-filter]-missing}" == speed && \
     "${kv[concurrent-copying]-missing}" == false && \
     "${kv[debuggable]-missing}" == false && \
     "${kv[dex2oat-cmdline]-missing}" == '' && \
     "${kv[enable-profile-code]-missing}" == false && \
     "${kv[native-debuggable]-missing}" == false && \
     "${kv[requires-image]-missing}" == false ]] || \
    die "cubs Malibu oatdump compilation/runtime policy is not pinned"

  report_semantics=$(printf '%s\n' \
    "oat_version=$oat_version" \
    "oat_header_checksum=$oat_checksum" \
    "instruction_set=$instruction_set" \
    "instruction_set_features=$instruction_features" \
    "dex_file_count=$dex_file_count" \
    "bootclasspath=${kv[bootclasspath]}" \
    "bootclasspath_checksums=${kv[bootclasspath-checksums]}" \
    "classpath=${kv[classpath]}" \
    "compilation_reason=${kv[compilation-reason]}" \
    "compiler_filter=${kv[compiler-filter]}" \
    "concurrent_copying=${kv[concurrent-copying]}" \
    "assume_value_sdk_int=${kv[assume-value-sdk-int]}")
  report_semantics_digest=$(cubs_sha256_text "$report_semantics")

  result=()
  # shellcheck disable=SC2034,SC2154 # returned through the caller's nameref
  result[malibu_dexpreopt_invocation_sha256]=$invocation_digest
  # shellcheck disable=SC2034,SC2154 # returned through the caller's nameref
  result[cubs_host_oatdump_sha256]=$oatdump_digest
  # shellcheck disable=SC2034,SC2154 # returned through the caller's nameref
  result[malibu_target_classes_dex_crc32]=$target_crc
  # shellcheck disable=SC2034,SC2154 # returned through the caller's nameref
  result[malibu_effective_class_loader_context_sha256]=$effective_clc_digest
  # shellcheck disable=SC2034,SC2154 # returned through the caller's nameref
  result[malibu_oatdump_semantics_sha256]=$report_semantics_digest
  unlink -- "$scratch_report"
}

cubs_odex_has_exact_oat_magic() {
  od -An -tu1 -v "$1" | awk '
    {
      for (field = 1; field <= NF; field += 1) {
        byte = $field + 0
        if (previous3 == 111 && previous2 == 97 &&
            previous1 == 116 && byte == 10) {
          matches += 1
        }
        previous3 = previous2
        previous2 = previous1
        previous1 = byte
      }
    }
    END { exit matches == 1 ? 0 : 1 }
  '
}

cubs_vdex_has_exact_magic() {
  local magic
  magic=$(od -An -tx1 -N 4 -v "$1" | tr -d ' \n')
  [[ "$magic" == 76646578 ]]
}

validate_cubs_standalone_dexpreopt() {
  local target_files=$1
  local product_out=$2
  local source_jar=$3
  local scratch_file=$4
  local output_name=$5
  # shellcheck disable=SC2178 # caller supplies an associative-array nameref
  local -n result=$output_name
  local rel_path key entry digest basename
  local product_digest source_jar_digest index
  local target_count basename_count
  local target_root=SYSTEM_EXT
  local product_root=system_ext
  local -a target_entries=()
  local -a rel_paths=(
    framework/malibu-plugin-provider.jar
    framework/oat/arm64/malibu-plugin-provider.odex
    framework/oat/arm64/malibu-plugin-provider.vdex
  )
  local -a keys=(
    malibu_plugin_provider_jar_sha256
    malibu_plugin_provider_arm64_odex_sha256
    malibu_plugin_provider_arm64_vdex_sha256
  )

  [[ -f "$target_files" && ! -L "$target_files" ]] || \
    die "cubs target-files package is missing or unsafe"
  [[ -d "$product_out" && ! -L "$product_out" ]] || \
    die "cubs product output directory is missing or unsafe"
  [[ -f "$source_jar" && ! -L "$source_jar" && -s "$source_jar" ]] || \
    die "generated malibu-plugin-provider.jar is missing, empty, or unsafe"
  unzip -tq "$source_jar" >/dev/null || \
    die "generated malibu-plugin-provider.jar is not a valid ZIP/JAR"
  source_jar_digest=$(sha256sum -- "$source_jar")
  source_jar_digest=${source_jar_digest%% *}
  [[ "$source_jar_digest" =~ ^[0-9a-f]{64}$ ]] || \
    die "invalid generated malibu-plugin-provider.jar digest"
  [[ -d "${scratch_file%/*}" && ! -L "${scratch_file%/*}" && \
     ! -e "$scratch_file" && ! -L "$scratch_file" ]] || \
    die "unsafe cubs dexpreopt-validation scratch path"
  unzip -tq "$target_files" >/dev/null || \
    die "invalid cubs target-files ZIP"
  mapfile -t target_entries < <(unzip -Z1 "$target_files")
  (( ${#target_entries[@]} > 0 )) || \
    die "cubs target-files ZIP has no entries"

  result=()
  for ((index = 0; index < ${#rel_paths[@]}; index += 1)); do
    rel_path=${rel_paths[$index]}
    key=${keys[$index]}
    target_count=0
    basename_count=0
    basename=${rel_path##*/}
    for entry in "${target_entries[@]}"; do
      [[ "$entry" == "$target_root/$rel_path" ]] && \
        ((target_count += 1))
      [[ "${entry##*/}" == "$basename" ]] && ((basename_count += 1))
    done
    (( target_count == 1 )) || \
      die "expected exactly one cubs dexpreopt entry for $rel_path; found $target_count"
    (( basename_count == 1 )) || \
      die "cubs target-files contains an alternate or duplicate $basename artifact"

    entry="$product_out/$product_root/$rel_path"
    [[ -f "$entry" && ! -L "$entry" && -s "$entry" ]] || \
      die "cubs product dexpreopt artifact is missing, empty, or unsafe: $entry"
    [[ ! -e "$product_out/system/system_ext/$rel_path" && \
       ! -L "$product_out/system/system_ext/$rel_path" ]] || \
      die "cubs product output contains an alternate system_ext dexpreopt artifact: $rel_path"

    unzip -p "$target_files" "$target_root/$rel_path" > "$scratch_file" || \
      die "failed to extract cubs target-files dexpreopt entry: $target_root/$rel_path"
    [[ -f "$scratch_file" && ! -L "$scratch_file" && -s "$scratch_file" ]] || \
      die "cubs target-files dexpreopt entry is empty or unsafe: $target_root/$rel_path"
    digest=$(sha256sum -- "$scratch_file")
    digest=${digest%% *}
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || \
      die "invalid cubs target-files dexpreopt digest for $rel_path"
    entry="$product_out/$product_root/$rel_path"
    product_digest=$(sha256sum -- "$entry")
    product_digest=${product_digest%% *}
    [[ "$product_digest" =~ ^[0-9a-f]{64}$ ]] || \
      die "invalid cubs product dexpreopt digest for $rel_path"
    [[ "$digest" == "$product_digest" ]] || \
      die "cubs target-files dexpreopt entry differs from product output: $rel_path"
    case "$rel_path" in
      *.jar)
        unzip -tq "$scratch_file" >/dev/null || \
          die "target-files malibu-plugin-provider.jar is not a valid ZIP/JAR"
        unzip -tq "$entry" >/dev/null || \
          die "product-output malibu-plugin-provider.jar is not a valid ZIP/JAR"
        [[ "$digest" == "$source_jar_digest" ]] || \
          die "installed malibu-plugin-provider.jar differs from generated vendor source"
        ;;
      *.odex)
        cubs_odex_has_exact_oat_magic "$scratch_file" || \
          die "target-files malibu-plugin-provider.odex lacks exactly one oat magic"
        cubs_odex_has_exact_oat_magic "$entry" || \
          die "product-output malibu-plugin-provider.odex lacks exactly one oat magic"
        ;;
      *.vdex)
        cubs_vdex_has_exact_magic "$scratch_file" || \
          die "target-files malibu-plugin-provider.vdex has invalid magic"
        cubs_vdex_has_exact_magic "$entry" || \
          die "product-output malibu-plugin-provider.vdex has invalid magic"
        ;;
      *) die "internal error: unsupported cubs dexpreopt artifact $rel_path" ;;
    esac
    # shellcheck disable=SC2034 # returned to the caller through the nameref
    result["$key"]=$digest
    unlink -- "$scratch_file"
  done
}
