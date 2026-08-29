#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
# shellcheck source=lib/recovery-handoff.sh disable=SC1091
source "$script_dir/lib/recovery-handoff.sh"

usage() {
  cat >&2 <<'EOF'
usage: [CUBS_ADB_SERIAL=<serial>] scripts/validate-runtime.sh gsi|cubs

Runs a read-only post-boot audit. Set CUBS_ADB_SERIAL, or leave both serial
variables unset when exactly one usable ADB transport is in device state. The chosen
serial is never written to the report or printed by this script.
EOF
  exit 2
}

(( $# == 1 )) || usage
expected_mode=$1
case "$expected_mode" in
  gsi|cubs) ;;
  *) usage ;;
esac

case "$expected_mode" in
  gsi)
    expected_product_device=generic_arm64
    expected_adb_secure=0
    ;;
  cubs)
    expected_product_device=$DEVICE_CODENAME
    expected_adb_secure='unset-or-0'
    ;;
esac

adb_secure_matches_mode() {
  local actual=$1
  case "$expected_mode" in
    gsi) [[ "$actual" == 0 ]] ;;
    cubs) [[ -z "$actual" || "$actual" == 0 ]] ;;
  esac
}

if [[ -n "${CUBS_ADB_SERIAL:-}" && -n "${ANDROID_SERIAL:-}" && \
      "$CUBS_ADB_SERIAL" != "$ANDROID_SERIAL" ]]; then
  die "CUBS_ADB_SERIAL and ANDROID_SERIAL select different devices"
fi

require_command awk basename cat chmod date flock grep head mkdir mktemp mv \
  od openssl realpath rm sed sha256sum stat tail timeout tr
expected_adb_sha256=$PLATFORM_TOOLS_ADB_SHA256

if [[ -n "${ADB:-}" ]]; then
  [[ "$ADB" == /* ]] || die "ADB must be an absolute path"
  adb_bin=$ADB
else
  adb_bin="$workspace_platform_tools/adb"
fi
[[ -f "$adb_bin" && ! -L "$adb_bin" && -x "$adb_bin" ]] || \
  die "adb is not the safe workspace Platform-Tools executable: $adb_bin"
adb_bin=$(realpath -e -- "$adb_bin")
adb_sha256=$(sha256sum "$adb_bin" | awk '{print $1}')
[[ "$adb_sha256" == "$expected_adb_sha256" ]] || \
  die "adb does not match the pinned Platform-Tools binary digest"
adb_version_output=$("$adb_bin" version 2>&1)
if [[ "$adb_version_output" =~ Version[[:space:]]([0-9]+(\.[0-9]+)*)- ]]; then
  adb_version=${BASH_REMATCH[1]}
else
  die "unable to determine adb version"
fi
[[ "$adb_version" == "$PLATFORM_TOOLS_VERSION" ]] || \
  die "this runtime audit requires adb $PLATFORM_TOOLS_VERSION; found $adb_version"
adb_timeout_seconds=${CUBS_ADB_TIMEOUT_SECONDS:-20}
[[ "$adb_timeout_seconds" =~ ^[0-9]+$ ]] || \
  die "CUBS_ADB_TIMEOUT_SECONDS must be an integer"
(( adb_timeout_seconds >= 1 && adb_timeout_seconds <= 120 )) || \
  die "CUBS_ADB_TIMEOUT_SECONDS must be between 1 and 120"
timeout_command=(timeout --foreground --signal=TERM "${adb_timeout_seconds}s")

device_serial=${CUBS_ADB_SERIAL:-${ANDROID_SERIAL:-}}
if [[ -n "$device_serial" ]]; then
  device_selection=explicit
else
  devices_output=
  if ! devices_output=$("${timeout_command[@]}" "$adb_bin" devices 2>/dev/null); then
    die "unable to enumerate ADB transports within the timeout"
  fi
  mapfile -t usable_devices < <(
    awk '$2 == "device" {print $1}' <<< "$devices_output"
  )
  (( ${#usable_devices[@]} == 1 )) || die \
    "set CUBS_ADB_SERIAL unless exactly one ADB transport is in device state"
  device_serial=${usable_devices[0]}
  device_selection=sole-device-state
fi
[[ "$device_serial" =~ ^[[:alnum:]_.:-]+$ ]] || \
  die "selected ADB serial contains unsupported characters"
adb_command=("$adb_bin" -s "$device_serial")

logs_dir="$project_root/logs"
assert_inside_project "$logs_dir"
mkdir -p "$logs_dir"
umask 077
timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
timestamp_file=$(date -u +%Y%m%dT%H%M%SZ)
report_path="$logs_dir/runtime-validation-${expected_mode}-${timestamp_file}-${BASHPID}.txt"
body_path=$(mktemp "$logs_dir/.runtime-validation-body.XXXXXX")
report_tmp=$(mktemp "$logs_dir/.runtime-validation-report.XXXXXX")

trap 'rm -f -- "$body_path" "$report_tmp"' EXIT

pass_count=0
failure_count=0
warning_count=0

one_line() {
  local value=${1//$'\r'/}
  value=${value//$'\n'/'; '}
  value=${value//"$device_serial"/'<redacted>'}
  [[ -n "$value" ]] || value='<empty>'
  printf '%s' "$value"
}

record() {
  printf '%s\n' "$*" >> "$body_path"
}

section() {
  printf '\n[%s]\n' "$1" >> "$body_path"
}

pass() {
  ((pass_count += 1))
  record "PASS $*"
}

fail() {
  ((failure_count += 1))
  record "FAIL $*"
}

warn() {
  ((warning_count += 1))
  record "WARN $*"
}

record_value() {
  local key=$1
  local value
  value=$(one_line "$2")
  record "$key=$value"
}

check_equal() {
  local label=$1
  local actual=$2
  local expected=$3
  if [[ "$actual" == "$expected" ]]; then
    pass "$label: $(one_line "$actual")"
  else
    fail "$label: expected $(one_line "$expected"), found $(one_line "$actual")"
  fi
}

check_contains() {
  local label=$1
  local actual=$2
  local expected_fragment=$3
  if [[ "$actual" == *"$expected_fragment"* ]]; then
    pass "$label contains $(one_line "$expected_fragment")"
  else
    fail "$label does not contain $(one_line "$expected_fragment"): $(one_line "$actual")"
  fi
}

check_nonempty() {
  local label=$1
  local actual=$2
  if [[ -n "$actual" && "$actual" != '<unavailable>' ]]; then
    pass "$label is present"
  else
    fail "$label is unavailable"
  fi
}

adb_capture() {
  local output status
  if output=$("${timeout_command[@]}" "${adb_command[@]}" "$@" 2>&1); then
    status=0
  else
    status=$?
  fi
  output=${output//$'\r'/}
  output=${output//"$device_serial"/'<redacted>'}
  printf '%s' "$output"
  return "$status"
}

adb_prop() {
  local value
  if value=$(adb_capture shell getprop "$1"); then
    printf '%s' "$value"
  else
    printf '<unavailable>'
  fi
}

logical_image_expanded_size() {
  local image=$1 magic major block_size total_blocks expanded_size
  magic=$(od -An -N4 -j0 -tu4 -- "$image" | tr -d '[:space:]')
  if [[ "$magic" == 3978755898 ]]; then
    major=$(od -An -N2 -j4 -tu2 -- "$image" | tr -d '[:space:]')
    block_size=$(od -An -N4 -j12 -tu4 -- "$image" | tr -d '[:space:]')
    total_blocks=$(od -An -N4 -j16 -tu4 -- "$image" | tr -d '[:space:]')
    [[ "$major" == 1 && "$block_size" =~ ^[1-9][0-9]*$ && \
       "$total_blocks" =~ ^[1-9][0-9]*$ && \
       $((block_size % 4096)) -eq 0 ]] || \
      die "runtime-attestation sparse image header is malformed"
    expanded_size=$((10#$block_size * 10#$total_blocks))
  else
    expanded_size=$(stat -c '%s' "$image")
  fi
  [[ "$expanded_size" =~ ^[1-9][0-9]*$ && \
     $((expanded_size % 4096)) -eq 0 ]] || \
    die "runtime-attestation logical image has an invalid expanded size"
  printf '%s\n' "$expanded_size"
}

finish_report() {
  local result report_display
  if (( failure_count == 0 )); then
    if (( warning_count == 0 )); then
      result=PASS
    else
      result=PASS_WITH_WARNINGS
    fi
  else
    result=FAIL
  fi
  {
    printf 'Pixel 11 runtime validation\n'
    printf 'timestamp_utc=%s\n' "$timestamp_utc"
    printf 'expected_mode=%s\n' "$expected_mode"
    printf 'selected_device=<redacted>\n'
    printf 'device_selection=%s\n' "$device_selection"
    printf 'adb_version=%s\n' "$adb_version"
    printf 'adb_sha256=%s\n' "$adb_sha256"
    printf 'adb_command_timeout_seconds=%s\n' "$adb_timeout_seconds"
    printf 'access=read-only-adb\n'
    printf 'result=%s\n' "$result"
    printf 'passes=%d\n' "$pass_count"
    printf 'failures=%d\n' "$failure_count"
    printf 'warnings=%d\n' "$warning_count"
    cat "$body_path"
  } > "$report_tmp"
  chmod 0600 "$report_tmp"
  mv -- "$report_tmp" "$report_path"
  report_display=${report_path#"$project_root"/}
  printf 'runtime validation %s: %d passed, %d failed, %d warnings\n' \
    "$result" "$pass_count" "$failure_count" "$warning_count"
  printf 'report: %s\n' "$report_display"
  if (( failure_count > 0 )); then
    grep '^FAIL ' "$report_path" >&2 || true
    exit 1
  fi
  if [[ "${CUBS_PUBLISH_RUNTIME_ATTESTATION:-0}" == 1 ]]; then
    publish_runtime_boot_attestation "$result"
  elif [[ "${CUBS_PUBLISH_RUNTIME_ATTESTATION:-0}" != 0 ]]; then
    die "CUBS_PUBLISH_RUNTIME_ATTESTATION must be 0 or 1"
  fi
  exit 0
}

publish_runtime_boot_attestation() {
  local result=$1 actual_binding actual_handoff_sha actual_lineage_sha
  local boot_id bundle_dir bundle_kind bundle_manifest_sha claimed created
  local expected_baseband expected_bootloader expected_framework_spl
  local expected_output_build_id flash_created flash_now flash_transaction_path
  local flash_transaction_sha logical_image_size logical_image_size_lines=
  local logical_image_sizes_sha logical_target logical_targets_sha
  local fingerprint fingerprint_sha lineage_baseband
  local lineage_bootloader lineage_physical_sizes marker_sha report_basename
  local partition expected_id expected_type id_property type_property
  local report_sha runtime_adb_secure runtime_build_id runtime_build_tags
  local runtime_build_type runtime_device runtime_partition_id
  local runtime_partition_type runtime_slot runtime_spl runtime_state
  local runtime_uptime runtime_vendor_device temporary
  local -A flash_transaction=() handoff=()
  local -a logical_targets=()

  bundle_dir=${CUBS_RUNTIME_BUNDLE_DIR:-"$project_root/artifacts/$expected_mode"}
  bundle_dir=$(realpath -e -- "$bundle_dir")
  [[ -d "$bundle_dir" && ! -L "$bundle_dir" ]] || \
    die "runtime-attestation bundle directory is unsafe"
  for runtime_file in bundle-kind BUNDLE_INFO.txt firmware-requirements.txt \
      SHA256SUMS; do
    [[ -f "$bundle_dir/$runtime_file" && ! -L "$bundle_dir/$runtime_file" ]] || \
      die "runtime-attestation bundle input is unsafe: $runtime_file"
  done
  bundle_kind=$(<"$bundle_dir/bundle-kind")
  [[ "$bundle_kind" == "$expected_mode" ]] || \
    die "runtime-attestation bundle kind differs from the validated mode"
  bundle_manifest_sha=$(sha256sum "$bundle_dir/SHA256SUMS" | awk '{print $1}')
  expected_output_build_id=$(sed -n 's/^output_build_id=//p' \
    "$bundle_dir/BUNDLE_INFO.txt")
  expected_framework_spl=$(sed -n 's/^framework_security_patch=//p' \
    "$bundle_dir/BUNDLE_INFO.txt")
  expected_bootloader=$(sed -n 's/^require version-bootloader=//p' \
    "$bundle_dir/firmware-requirements.txt")
  expected_baseband=$(sed -n 's/^require version-baseband=//p' \
    "$bundle_dir/firmware-requirements.txt")
  [[ $(grep -c '^output_build_id=' "$bundle_dir/BUNDLE_INFO.txt") -eq 1 && \
     $(grep -c '^framework_security_patch=' \
       "$bundle_dir/BUNDLE_INFO.txt") -eq 1 && \
     $(grep -c '^require version-bootloader=' \
       "$bundle_dir/firmware-requirements.txt") -eq 1 && \
     $(grep -c '^require version-baseband=' \
       "$bundle_dir/firmware-requirements.txt") -eq 1 && \
     "$bundle_manifest_sha" =~ ^[0-9a-f]{64}$ && \
     -n "$expected_output_build_id" && \
     "$expected_framework_spl" == "$AOSP_SECURITY_PATCH" && \
     -n "$expected_bootloader" && \
     -n "$expected_baseband" ]] || \
    die "runtime-attestation bundle provenance is malformed"

  cubs_lock_recovery_state
  [[ ! -e "$cubs_stock_restore_transaction" && \
     ! -L "$cubs_stock_restore_transaction" ]] || \
    die "an active stock-restore transaction blocks runtime publication"
  [[ ! -e "$cubs_flash_retirement_transaction" && \
     ! -L "$cubs_flash_retirement_transaction" ]] || \
    die "an active flash-retirement transaction blocks runtime publication"
  [[ ! -e "$cubs_stock_b_consumption_transaction" && \
     ! -L "$cubs_stock_b_consumption_transaction" ]] || \
    die "an active direct-lifeboat consumption transaction blocks runtime publication"
  [[ ! -e "$cubs_runtime_boot_attestation" && \
     ! -L "$cubs_runtime_boot_attestation" ]] || \
    die "a runtime boot attestation already exists; finalize or recover it"
  cubs_private_file "$cubs_recovery_lineage"
  lineage_physical_sizes=$(sed -n 's/^physical_b_sizes_sha256=//p' \
    "$cubs_recovery_lineage")
  lineage_bootloader=$(sed -n 's/^bootloader=//p' "$cubs_recovery_lineage")
  lineage_baseband=$(sed -n 's/^baseband=//p' "$cubs_recovery_lineage")
  [[ $(grep -c '^physical_b_sizes_sha256=' "$cubs_recovery_lineage") -eq 1 && \
     $(grep -c '^bootloader=' "$cubs_recovery_lineage") -eq 1 && \
     $(grep -c '^baseband=' "$cubs_recovery_lineage") -eq 1 && \
     "$lineage_physical_sizes" =~ ^[0-9a-f]{64}$ && \
     "$lineage_bootloader" == "$expected_bootloader" && \
     "$lineage_baseband" == "$expected_baseband" ]] || \
    die "runtime-attestation lineage firmware provenance is malformed"
  cubs_verify_lifeboat_lineage "$device_serial" "$lineage_physical_sizes" \
    "$expected_bootloader" "$expected_baseband"
  cubs_verify_lifeboat_handoff_for_recovery "$lineage_physical_sizes"
  cubs_load_exact_kv "$cubs_recovery_handoff" handoff \
    schema state handoff_kind created_epoch expires_epoch claimed_epoch \
    anchor_id serial_binding_sha256 lineage_sha256 physical_b_sizes_sha256 \
    recovery_policy_sha256 bundle_kind bundle_manifest_sha256
  [[ "${handoff[state]}" == claimed && \
     "${handoff[anchor_id]}" == "$cubs_verified_anchor_id" && \
     "${handoff[serial_binding_sha256]}" == "$cubs_verified_serial_binding" && \
     "${handoff[bundle_kind]}" == "$bundle_kind" && \
     "${handoff[bundle_manifest_sha256]}" == "$bundle_manifest_sha" ]] || \
    die "runtime boot does not match the active claimed bundle handoff"
  claimed=${handoff[claimed_epoch]}
  actual_handoff_sha=$(sha256sum "$cubs_recovery_handoff" | awk '{print $1}')
  actual_lineage_sha=$(sha256sum "$cubs_recovery_lineage" | awk '{print $1}')
  [[ "$actual_handoff_sha" == "$cubs_verified_recovery_handoff_sha256" && \
     "$actual_lineage_sha" == "$cubs_verified_lineage_sha256" ]] || \
    die "runtime recovery evidence changed after verification"

  case "$bundle_kind" in
    gsi) logical_targets=(system) ;;
    cubs)
      logical_targets=(
        system system_dlkm system_ext product vendor vendor_dlkm
      )
      ;;
    *) die "runtime-attestation bundle has an unsupported logical target set" ;;
  esac
  logical_targets_sha=$(
    printf '%s\n' "${logical_targets[@]}" | sha256sum | awk '{print $1}'
  )
  for logical_target in "${logical_targets[@]}"; do
    [[ -f "$bundle_dir/$logical_target.img" && \
       ! -L "$bundle_dir/$logical_target.img" ]] || \
      die "runtime-attestation logical image is unsafe: $logical_target.img"
    logical_image_size=$(logical_image_expanded_size \
      "$bundle_dir/$logical_target.img")
    logical_image_size_lines+="$logical_target=$logical_image_size"$'\n'
  done
  logical_image_sizes_sha=$(
    printf '%s' "$logical_image_size_lines" | sha256sum | awk '{print $1}'
  )

  flash_transaction_path=$cubs_slot_a_flash_transaction
  cubs_private_file "$flash_transaction_path"
  cubs_load_exact_kv "$flash_transaction_path" flash_transaction \
    schema state created_epoch transaction_id serial_binding_sha256 device \
    anchor_id lineage_sha256 handoff_sha256 physical_b_sizes_sha256 \
    stock_b_source stock_b_provenance_sha256 bundle_kind \
    bundle_manifest_sha256 logical_targets_sha256 \
    logical_image_sizes_sha256 recovery_policy_sha256
  [[ "${flash_transaction[schema]}" == \
       cubs-slot-a-flash-transaction-v1 && \
     "${flash_transaction[state]}" == awaiting_runtime && \
     "${flash_transaction[created_epoch]}" =~ ^[1-9][0-9]{0,17}$ && \
     "${flash_transaction[transaction_id]}" =~ ^[0-9a-f]{32}$ && \
     "${flash_transaction[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${flash_transaction[device]}" == "$DEVICE_CODENAME" && \
     "${flash_transaction[anchor_id]}" == "$cubs_verified_anchor_id" && \
     "${flash_transaction[lineage_sha256]}" == "$actual_lineage_sha" && \
     "${flash_transaction[handoff_sha256]}" == "$actual_handoff_sha" && \
     "${flash_transaction[physical_b_sizes_sha256]}" == \
       "$lineage_physical_sizes" && \
     "${flash_transaction[stock_b_source]}" == \
       "$cubs_verified_stock_b_source" && \
     "${flash_transaction[stock_b_provenance_sha256]}" == \
       "$cubs_verified_stock_b_provenance_sha256" && \
     "${flash_transaction[bundle_kind]}" == "$bundle_kind" && \
     "${flash_transaction[bundle_manifest_sha256]}" == \
       "$bundle_manifest_sha" && \
     "${flash_transaction[logical_targets_sha256]}" == \
       "$logical_targets_sha" && \
     "${flash_transaction[logical_image_sizes_sha256]}" == \
       "$logical_image_sizes_sha" && \
     "${flash_transaction[recovery_policy_sha256]}" == \
       "$CUBS_RECOVERY_POLICY_SHA256" ]] || \
    die "runtime boot does not match the exact slot-A flash transaction"
  actual_binding=$(cubs_serial_binding \
    "${flash_transaction[transaction_id]}" "$device_serial")
  [[ "$actual_binding" == \
       "${flash_transaction[serial_binding_sha256]}" ]] || \
    die "slot-A flash transaction belongs to another USB transport"
  flash_created=${flash_transaction[created_epoch]}
  flash_now=$(date +%s)
  (( 10#$flash_created >= 10#$claimed && \
     10#$flash_created <= 10#$flash_now )) || \
    die "slot-A flash transaction has an inconsistent timestamp"
  flash_transaction_sha=$(sha256sum "$flash_transaction_path" | awk '{print $1}')

  # Repeat the boot identity after the report is complete. Publication therefore
  # proves a still-live, exact slot-A Android boot rather than only a stale log.
  runtime_state=$(adb_capture get-state) || \
    die "selected ADB transport disappeared before runtime attestation publication"
  runtime_device=$(adb_prop ro.product.device)
  runtime_vendor_device=$(adb_prop ro.product.vendor.device)
  runtime_slot=$(adb_prop ro.boot.slot_suffix)
  runtime_build_id=$(adb_prop ro.build.id)
  runtime_build_type=$(adb_prop ro.build.type)
  runtime_build_tags=$(adb_prop ro.build.tags)
  runtime_spl=$(adb_prop ro.build.version.security_patch)
  runtime_adb_secure=$(adb_prop ro.adb.secure)
  fingerprint=$(adb_prop ro.build.fingerprint)
  runtime_uptime=$(adb_capture shell cat /proc/uptime) || \
    die "unable to re-read runtime uptime for attestation"
  runtime_uptime=${runtime_uptime%%.*}
  boot_id=$(adb_capture shell cat /proc/sys/kernel/random/boot_id) || \
    die "unable to read the runtime boot ID"
  actual_binding=$(cubs_serial_binding "$cubs_verified_anchor_id" "$device_serial")
  adb_secure_matches_mode "$runtime_adb_secure" || \
    die "live Android ADB authentication mode changed before runtime attestation publication"
  [[ "$runtime_state" == device && \
     "$runtime_device" == "$expected_product_device" && \
     "$runtime_vendor_device" == "$DEVICE_CODENAME" && \
     "$runtime_slot" == _a && "$runtime_build_id" == "$expected_output_build_id" && \
     "$runtime_build_type" == userdebug && \
     "$runtime_build_tags" == *test-keys* && \
     "$runtime_spl" == "$expected_framework_spl" && \
     $(adb_prop sys.boot_completed) == 1 && \
     "$fingerprint" != '<unavailable>' && -n "$fingerprint" && \
     "$fingerprint" == *"$expected_output_build_id"* && \
     "$runtime_uptime" =~ ^[1-9][0-9]*$ && \
     "$boot_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ && \
     "$actual_binding" == "$cubs_verified_serial_binding" ]] || \
    die "live Android state changed before runtime attestation publication"

  # The report already checked these identities, but publication re-reads them
  # so a stale report cannot qualify a different mixed-partition boot.
  for partition in "${partitions[@]}"; do
    id_property=${partition_id_property[$partition]}
    type_property=${partition_type_property[$partition]}
    expected_id=${expected_partition_build_id[$partition]}
    expected_type=${expected_partition_build_type[$partition]}
    runtime_partition_id=$(adb_prop "$id_property")
    runtime_partition_type=$(adb_prop "$type_property")
    [[ "$runtime_partition_id" == "$expected_id" && \
       "$runtime_partition_type" == "$expected_type" ]] || \
      die "live $partition identity changed before runtime attestation publication"
  done

  fingerprint_sha=$(printf '%s' "$fingerprint" | sha256sum | awk '{print $1}')
  report_sha=$(sha256sum "$report_path" | awk '{print $1}')
  report_basename=$(basename -- "$report_path")
  created=$(date +%s)
  (( 10#$created >= 10#$claimed )) || \
    die "runtime attestation predates the claimed flash transaction"
  temporary=$(mktemp "$cubs_recovery_state_dir/.runtime-boot-attestation.XXXXXX")
  {
    printf 'schema=cubs-runtime-boot-attestation-v2\n'
    printf 'created_epoch=%s\n' "$created"
    printf 'anchor_id=%s\n' "$cubs_verified_anchor_id"
    printf 'serial_binding_sha256=%s\n' "$cubs_verified_serial_binding"
    printf 'lineage_sha256=%s\n' "$actual_lineage_sha"
    printf 'handoff_sha256=%s\n' "$actual_handoff_sha"
    printf 'flash_transaction_sha256=%s\n' "$flash_transaction_sha"
    printf 'claimed_epoch=%s\n' "$claimed"
    # Schema v2's device field identifies the physical cubs target. The GSI's
    # ro.product.device is generic_arm64 and was verified separately above.
    printf 'device=%s\n' "$runtime_vendor_device"
    printf 'slot_suffix=%s\n' "$runtime_slot"
    printf 'bundle_kind=%s\n' "$bundle_kind"
    printf 'bundle_manifest_sha256=%s\n' "$bundle_manifest_sha"
    printf 'output_build_id=%s\n' "$runtime_build_id"
    printf 'build_type=%s\n' "$runtime_build_type"
    printf 'framework_security_patch=%s\n' "$runtime_spl"
    printf 'build_fingerprint_sha256=%s\n' "$fingerprint_sha"
    printf 'boot_id=%s\n' "$boot_id"
    printf 'uptime_seconds=%s\n' "$runtime_uptime"
    printf 'sys_boot_completed=1\n'
    printf 'validation_result=%s\n' "$result"
    printf 'runtime_report_basename=%s\n' "$report_basename"
    printf 'runtime_report_sha256=%s\n' "$report_sha"
    printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$cubs_runtime_boot_attestation"
  cubs_private_file "$cubs_runtime_boot_attestation"
  marker_sha=$(sha256sum "$cubs_runtime_boot_attestation" | awk '{print $1}')
  printf 'runtime boot attestation: .cache/recovery-anchor/runtime-boot-attestation (%s)\n' \
    "$marker_sha"
}

section preflight
adb_state=
if adb_state=$(adb_capture get-state); then
  check_equal "selected ADB transport state" "$adb_state" device
else
  fail "selected ADB transport is not in device state: $(one_line "$adb_state")"
  finish_report
fi

shell_probe=
if shell_probe=$(adb_capture shell true); then
  pass "selected ADB shell command completed"
else
  fail "selected ADB shell command failed: $(one_line "$shell_probe")"
  finish_report
fi

declare -a property_keys=(
  ro.product.device
  ro.product.vendor.device
  ro.build.id
  ro.build.type
  ro.build.tags
  ro.build.version.release
  ro.build.version.sdk
  ro.build.version.security_patch
  ro.build.fingerprint
  ro.system.build.id
  ro.system.build.type
  ro.system.build.tags
  ro.system.build.version.sdk
  ro.system.build.version.security_patch
  ro.system.build.fingerprint
  ro.system_dlkm.build.id
  ro.system_dlkm.build.type
  ro.system_dlkm.build.version.security_patch
  ro.system_dlkm.build.fingerprint
  ro.system_ext.build.id
  ro.system_ext.build.type
  ro.system_ext.build.version.security_patch
  ro.system_ext.build.fingerprint
  ro.product.build.id
  ro.product.build.type
  ro.product.build.version.security_patch
  ro.product.build.fingerprint
  ro.vendor.build.id
  ro.vendor.build.type
  ro.vendor.build.version.security_patch
  ro.vendor.build.fingerprint
  ro.vendor_dlkm.build.id
  ro.vendor_dlkm.build.type
  ro.vendor_dlkm.build.version.security_patch
  ro.vendor_dlkm.build.fingerprint
  ro.debuggable
  ro.secure
  ro.adb.secure
  service.adb.root
  ro.product.cpu.abilist
  ro.product.cpu.abilist32
  ro.product.cpu.abilist64
  ro.product.first_api_level
  ro.vendor.api_level
  ro.boot.slot_suffix
  ro.boot.flash.locked
  ro.boot.verifiedbootstate
  ro.boot.vbmeta.device_state
  ro.boot.veritymode
  ro.boot.bootreason
  ro.boot.dynamic_partitions
  ro.virtual_ab.enabled
  ro.virtual_ab.compression.enabled
  ro.virtual_ab.userspace.snapshots.enabled
  ro.boot.snapshot_merge_status
  sys.snapshot_merging
  sys.boot_completed
  dev.bootcomplete
  init.svc.bootanim
)
declare -A props=()
for property_key in "${property_keys[@]}"; do
  props["$property_key"]=$(adb_prop "$property_key")
done

section identity
record_value mode_expected "$expected_mode"
record_value product_device "${props[ro.product.device]}"
record_value vendor_device "${props[ro.product.vendor.device]}"
record_value build_id "${props[ro.build.id]}"
record_value build_type "${props[ro.build.type]}"
record_value build_tags "${props[ro.build.tags]}"
record_value build_fingerprint "${props[ro.build.fingerprint]}"
record_value android_release "${props[ro.build.version.release]}"
record_value android_sdk "${props[ro.build.version.sdk]}"
record_value framework_security_patch "${props[ro.build.version.security_patch]}"
record_value first_api_level "${props[ro.product.first_api_level]}"
record_value vendor_api_level "${props[ro.vendor.api_level]}"

check_equal "$expected_mode product device" \
  "${props[ro.product.device]}" "$expected_product_device"
check_equal "vendor device" "${props[ro.product.vendor.device]}" "$DEVICE_CODENAME"
check_equal "Android release" "${props[ro.build.version.release]}" 17
check_equal "Android SDK" "${props[ro.build.version.sdk]}" 37
check_equal "system SDK" "${props[ro.system.build.version.sdk]}" 37
check_equal "build variant" "${props[ro.build.type]}" userdebug
check_equal "debuggable property" "${props[ro.debuggable]}" 1
check_equal "secure adbd base mode" "${props[ro.secure]}" 1
if adb_secure_matches_mode "${props[ro.adb.secure]}"; then
  pass "$expected_mode ADB authentication mode: ${props[ro.adb.secure]:-<unset>} (effective unauthenticated)"
else
  fail "$expected_mode ADB authentication mode: expected $expected_adb_secure, found $(one_line "${props[ro.adb.secure]}")"
fi
if [[ -z "${props[ro.adb.secure]}" || "${props[ro.adb.secure]}" == 0 ]]; then
  warn "development adbd accepts unauthenticated USB clients; do not expose this boot to untrusted USB hosts"
fi
check_contains "build tags" "${props[ro.build.tags]}" test-keys
check_equal "framework security patch" \
  "${props[ro.build.version.security_patch]}" "$AOSP_SECURITY_PATCH"
check_equal "first API level" "${props[ro.product.first_api_level]}" 37
check_equal "vendor API level" "${props[ro.vendor.api_level]}" 202604
check_contains "64-bit ABI list" "${props[ro.product.cpu.abilist64]}" arm64-v8a
check_equal "32-bit ABI list" "${props[ro.product.cpu.abilist32]}" ""

section partition-identities
declare -a partitions=(system system_dlkm system_ext product vendor vendor_dlkm)
declare -A partition_id_property=(
  [system]=ro.system.build.id
  [system_dlkm]=ro.system_dlkm.build.id
  [system_ext]=ro.system_ext.build.id
  [product]=ro.product.build.id
  [vendor]=ro.vendor.build.id
  [vendor_dlkm]=ro.vendor_dlkm.build.id
)
declare -A partition_type_property=(
  [system]=ro.system.build.type
  [system_dlkm]=ro.system_dlkm.build.type
  [system_ext]=ro.system_ext.build.type
  [product]=ro.product.build.type
  [vendor]=ro.vendor.build.type
  [vendor_dlkm]=ro.vendor_dlkm.build.type
)
declare -A partition_fingerprint_property=(
  [system]=ro.system.build.fingerprint
  [system_dlkm]=ro.system_dlkm.build.fingerprint
  [system_ext]=ro.system_ext.build.fingerprint
  [product]=ro.product.build.fingerprint
  [vendor]=ro.vendor.build.fingerprint
  [vendor_dlkm]=ro.vendor_dlkm.build.fingerprint
)
declare -A partition_spl_property=(
  [system]=ro.system.build.version.security_patch
  [system_dlkm]=ro.system_dlkm.build.version.security_patch
  [system_ext]=ro.system_ext.build.version.security_patch
  [product]=ro.product.build.version.security_patch
  [vendor]=ro.vendor.build.version.security_patch
  [vendor_dlkm]=ro.vendor_dlkm.build.version.security_patch
)
declare -A expected_partition_build_id=()
declare -A expected_partition_build_type=()

for partition in "${partitions[@]}"; do
  id_property=${partition_id_property[$partition]}
  type_property=${partition_type_property[$partition]}
  fingerprint_property=${partition_fingerprint_property[$partition]}
  spl_property=${partition_spl_property[$partition]}
  partition_id=${props[$id_property]}
  partition_type=${props[$type_property]}
  partition_fingerprint=${props[$fingerprint_property]}
  record "partition.$partition.build_id=$(one_line "$partition_id")"
  record "partition.$partition.build_type=$(one_line "$partition_type")"
  record "partition.$partition.security_patch=$(one_line "${props[$spl_property]}")"
  record "partition.$partition.fingerprint=$(one_line "$partition_fingerprint")"

  if [[ "$expected_mode" == gsi && \
        "$partition" =~ ^(system|system_ext|product)$ ]]; then
    expected_partition_id=$AOSP_BUILD_ID
    expected_partition_type=userdebug
  elif [[ "$expected_mode" == gsi ]]; then
    expected_partition_id=$STOCK_BUILD_ID
    expected_partition_type=user
  else
    expected_partition_id=$STOCK_BUILD_ID
    expected_partition_type=userdebug
  fi
  expected_partition_build_id["$partition"]=$expected_partition_id
  expected_partition_build_type["$partition"]=$expected_partition_type
  check_equal "$partition build ID" "$partition_id" "$expected_partition_id"
  check_equal "$partition build type" "$partition_type" "$expected_partition_type"
  check_nonempty "$partition fingerprint" "$partition_fingerprint"
  check_contains "$partition fingerprint" "$partition_fingerprint" "$expected_partition_id"
done

if [[ "$expected_mode" == gsi ]]; then
  check_equal "top-level GSI build ID" "${props[ro.build.id]}" "$AOSP_BUILD_ID"
  pass "mixed-partition expectation: GSI system/product/system_ext with stock system_dlkm/vendor/vendor_dlkm"
else
  check_equal "top-level cubs build ID" "${props[ro.build.id]}" "$STOCK_BUILD_ID"
  pass "complete cubs expectation: all audited dynamic partitions are locally built"
fi

section debug-and-security
shell_uid=$(adb_capture shell id -u || true)
record_value shell_uid "$shell_uid"
record_value service_adb_root "${props[service.adb.root]}"
if [[ "$shell_uid" == 0 ]]; then
  pass "adbd is already running with root privileges"
elif [[ "$shell_uid" == 2000 && "${props[ro.debuggable]}" == 1 && \
        "${props[ro.build.type]}" == userdebug ]]; then
  pass "adbd root-capable userdebug configuration is present; root transition intentionally not exercised"
else
  fail "ADB shell/root capability is inconsistent with a userdebug build"
fi

selinux_mode=$(adb_capture shell getenforce || true)
record_value selinux "$selinux_mode"
check_equal "SELinux mode" "$selinux_mode" Enforcing
record_value verified_boot_state "${props[ro.boot.verifiedbootstate]}"
record_value vbmeta_device_state "${props[ro.boot.vbmeta.device_state]}"
record_value flash_locked "${props[ro.boot.flash.locked]}"
record_value verity_mode "${props[ro.boot.veritymode]}"
check_equal "bootloader lock property" "${props[ro.boot.flash.locked]}" 0
check_equal "verified boot state for unlocked development device" \
  "${props[ro.boot.verifiedbootstate]}" orange
if [[ "$expected_mode" == cubs ]]; then
  check_equal "full cubs dm-verity mode" \
    "${props[ro.boot.veritymode]}" enforcing
fi

section boot-health
record_value slot_suffix "${props[ro.boot.slot_suffix]}"
record_value boot_reason "${props[ro.boot.bootreason]}"
record_value sys_boot_completed "${props[sys.boot_completed]}"
record_value dev_bootcomplete "${props[dev.bootcomplete]}"
record_value boot_animation "${props[init.svc.bootanim]}"
check_equal "active Android slot" "${props[ro.boot.slot_suffix]}" _a
check_equal "framework boot completion" "${props[sys.boot_completed]}" 1
check_equal "device boot completion" "${props[dev.bootcomplete]}" 1
check_equal "boot animation state" "${props[init.svc.bootanim]}" stopped

uptime=$(adb_capture shell cat /proc/uptime || true)
record_value proc_uptime "$uptime"
uptime_seconds=${uptime%%.*}
if [[ "$uptime_seconds" =~ ^[0-9]+$ && "$uptime_seconds" -gt 0 ]]; then
  pass "kernel uptime is positive"
else
  fail "kernel uptime is unavailable or invalid"
fi

check_equal "dynamic partitions" "${props[ro.boot.dynamic_partitions]}" true
check_equal "virtual A/B" "${props[ro.virtual_ab.enabled]}" true
check_equal "compressed snapshots" \
  "${props[ro.virtual_ab.compression.enabled]}" true
check_equal "userspace snapshots" \
  "${props[ro.virtual_ab.userspace.snapshots.enabled]}" true
record_value boot_snapshot_merge_status "${props[ro.boot.snapshot_merge_status]}"
record_value runtime_snapshot_merging "${props[sys.snapshot_merging]}"
if [[ -z "${props[ro.boot.snapshot_merge_status]}" && \
      -z "${props[sys.snapshot_merging]}" ]]; then
  warn "Android exposes no unprivileged runtime snapshot-merge status; confirm snapshot-update-status=none in bootloader preflight"
elif [[ "${props[ro.boot.snapshot_merge_status]}" =~ ^(none|cancelled|completed)$ || \
        "${props[sys.snapshot_merging]}" =~ ^(0|false)$ ]]; then
  pass "runtime properties do not report an active snapshot merge"
else
  fail "runtime properties may report an active snapshot merge"
fi

if [[ "$shell_uid" == 0 ]]; then
  bootctl_slot=$(adb_capture shell bootctl get-current-slot || true)
  check_equal "boot-control current slot index" "$bootctl_slot" 0
  if bootctl_result=$(adb_capture shell bootctl is-slot-bootable 0); then
    pass "slot A is bootable according to boot control"
  else
    fail "slot A is not bootable according to boot control: $(one_line "$bootctl_result")"
  fi
  if bootctl_result=$(adb_capture shell bootctl is-slot-marked-successful 0); then
    pass "slot A is marked successful according to boot control"
  else
    fail "slot A is not marked successful according to boot control: $(one_line "$bootctl_result")"
  fi
else
  warn "boot-control success flags are inaccessible to the non-root shell; no adb root transition was performed"
fi

section mounts
declare -A partition_mountpoint=(
  [system]=/
  [system_dlkm]=/system_dlkm
  [system_ext]=/system_ext
  [product]=/product
  [vendor]=/vendor
  [vendor_dlkm]=/vendor_dlkm
)
declare -A gsi_embedded_target=(
  [system_ext]=/system/system_ext
  [product]=/system/product
)
mount_table=$(adb_capture shell cat /proc/mounts || true)
if [[ -z "$mount_table" ]]; then
  fail "/proc/mounts is unavailable"
else
  pass "/proc/mounts is readable"
fi

for partition in "${partitions[@]}"; do
  mountpoint=${partition_mountpoint[$partition]}
  mount_line=$(awk -v mountpoint="$mountpoint" \
    '$2 == mountpoint {print; exit}' <<< "$mount_table")
  if [[ "$expected_mode" == gsi && \
        -n "${gsi_embedded_target[$partition]+present}" ]]; then
    embedded_target=${gsi_embedded_target[$partition]}
    embedded_mount_line=$(awk -v mountpoint="$embedded_target" \
      '$2 == mountpoint {print; exit}' <<< "$mount_table")
    alias_target=$(adb_capture shell readlink "$mountpoint" || true)
    root_mount_line=$(awk '$2 == "/" {print; exit}' <<< "$mount_table")
    root_mount_source=$(awk '{print $1}' <<< "$root_mount_line")
    root_mount_fstype=$(awk '{print $3}' <<< "$root_mount_line")
    root_mount_options=$(awk '{print $4}' <<< "$root_mount_line")
    record "mount.$partition=embedded-root source=$(one_line "$root_mount_source") target=$embedded_target alias=$mountpoint fs=$(one_line "$root_mount_fstype") mode=$(one_line "${root_mount_options%%,*}")"
    check_equal "$partition GSI alias target" "$alias_target" "$embedded_target"
    if [[ -z "$mount_line" && -z "$embedded_mount_line" ]]; then
      pass "$partition is embedded in the GSI root rather than separately mounted"
    else
      fail "$partition unexpectedly has a separate GSI mount"
    fi
    check_equal "$partition inherited root filesystem" "$root_mount_fstype" ext4
    if [[ ",$root_mount_options," == *,ro,* ]]; then
      pass "$partition inherits a read-only GSI root mount"
    else
      fail "$partition inherits a non-read-only GSI root mount: $(one_line "$root_mount_options")"
    fi
    if adb_capture shell test -d "$embedded_target" >/dev/null; then
      pass "$partition embedded directory is present"
    else
      fail "$partition embedded directory is absent: $embedded_target"
    fi
    mapper_target=$(adb_capture shell readlink \
      "/dev/block/mapper/${partition}_a" || true)
    record "mount.$partition.logical_mapper=$(one_line "$mapper_target") (not-mounted)"
    if adb_capture shell test -e "/dev/block/mapper/${partition}_a-cow" \
        >/dev/null; then
      record "mount.$partition.cow_mapper=present (not-mounted)"
    else
      record "mount.$partition.cow_mapper=absent (not-mounted)"
    fi
    continue
  fi
  if [[ -z "$mount_line" ]]; then
    fail "$partition mount at $mountpoint is absent"
    continue
  fi
  mount_source=$(awk '{print $1}' <<< "$mount_line")
  mount_fstype=$(awk '{print $3}' <<< "$mount_line")
  mount_options=$(awk '{print $4}' <<< "$mount_line")
  mount_mode=${mount_options%%,*}
  mapper_path="/dev/block/mapper/${partition}_a"
  mapper_target=$(adb_capture shell readlink "$mapper_path" || true)
  verity_mapper_path="/dev/block/mapper/${partition}-verity"
  verity_mapper_target=$(adb_capture shell readlink \
    "$verity_mapper_path" || true)
  record "mount.$partition=source=$(one_line "$mount_source") target=$mountpoint fs=$(one_line "$mount_fstype") mode=$(one_line "$mount_mode") logical_mapper=$(one_line "$mapper_target") verity_mapper=$(one_line "$verity_mapper_target")"
  check_nonempty "$partition logical mapper target" "$mapper_target"
  if [[ "$expected_mode" == cubs ]]; then
    check_equal "$partition verity mapper source" \
      "$mount_source" "$verity_mapper_target"
  elif [[ -n "$verity_mapper_target" && \
          "$mount_source" == "$verity_mapper_target" ]]; then
    pass "$partition mount uses its verity mapper"
  elif [[ "$mount_source" == "$mapper_target" ]]; then
    pass "$partition mount uses its logical mapper"
  else
    fail "$partition mount source matches neither logical nor verity mapper: $(one_line "$mount_source")"
  fi
  if [[ "$mount_fstype" == erofs || "$mount_fstype" == ext4 ]]; then
    pass "$partition filesystem is $mount_fstype"
  else
    fail "$partition filesystem is unexpected: $(one_line "$mount_fstype")"
  fi
  if [[ "$expected_mode" == gsi && "$partition" == system ]]; then
    check_equal "GSI root filesystem" "$mount_fstype" ext4
  fi
  if [[ ",$mount_options," == *,ro,* ]]; then
    pass "$partition is mounted read-only"
  else
    fail "$partition is not mounted read-only: $(one_line "$mount_options")"
  fi
  if adb_capture shell test -e "/dev/block/mapper/${partition}_a-cow" \
      >/dev/null; then
    record "mount.$partition.cow_mapper=present"
  else
    record "mount.$partition.cow_mapper=absent"
  fi
done

data_mount=$(awk '$2 == "/data" {print; exit}' <<< "$mount_table")
metadata_mount=$(awk '$2 == "/metadata" {print; exit}' <<< "$mount_table")
record_value mount_data "$data_mount"
record_value mount_metadata "$metadata_mount"
if [[ -n "$data_mount" && ",$(awk '{print $4}' <<< "$data_mount")," == *,rw,* ]]; then
  pass "/data is mounted read-write"
else
  fail "/data is absent or not mounted read-write"
fi
check_nonempty "/metadata mount record" "$metadata_mount"

df_data=$(adb_capture shell df -k /data || true)
df_data_line=$(tail -n 1 <<< "$df_data")
record_value data_capacity "$df_data_line"
data_available_kib=$(awk 'NF >= 4 {print $4}' <<< "$df_data_line")
if [[ "$data_available_kib" =~ ^[0-9]+$ && "$data_available_kib" -ge 1048576 ]]; then
  pass "/data has at least 1 GiB available"
else
  fail "/data free-space check failed: $(one_line "$data_available_kib") KiB"
fi

section vintf
for vintf_file in \
  /vendor/etc/vintf/manifest.xml \
  /vendor/etc/vintf/compatibility_matrix.xml \
  /system/etc/vintf/manifest.xml; do
  if vintf_probe=$(adb_capture shell test -r "$vintf_file"); then
    pass "VINTF input is readable: $vintf_file"
  else
    fail "VINTF input is not readable: $vintf_file ($(one_line "$vintf_probe"))"
  fi
done
if framework_matrices=$(adb_capture shell \
    'ls /system/etc/vintf/compatibility_matrix*.xml'); then
  matrix_count=$(grep -c . <<< "$framework_matrices" || true)
  if (( matrix_count > 0 )); then
    pass "framework VINTF matrices are present ($matrix_count files)"
  else
    fail "framework VINTF matrix set is empty"
  fi
else
  fail "framework VINTF matrices are unavailable: $(one_line "$framework_matrices")"
fi

if vintf_check=$(adb_capture shell checkvintf --check-compat); then
  record "vintf_compatibility=pass"
  pass "on-device checkvintf compatibility check passed"
  record_value checkvintf_output "$vintf_check"
else
  if [[ "$vintf_check" == *"not found"* || \
        "$vintf_check" == *"inaccessible"* ]]; then
    vintf_checker_unavailable=1
    warn "on-device checkvintf binary is unavailable; boot logs can detect a recorded failure but cannot prove compatibility"
  else
    vintf_checker_unavailable=0
    record "vintf_compatibility=fail"
    fail "on-device checkvintf compatibility check failed: $(one_line "$vintf_check")"
  fi
  if vintf_log=$(adb_capture shell logcat -d -b system -s \
      Build:E ActivityTaskManager:E); then
    if [[ "$vintf_log" == *"Vendor interface is incompatible"* || \
          "$vintf_log" == *"Build fingerprint is not consistent"* ]]; then
      if [[ "$vintf_checker_unavailable" == 1 ]]; then
        record "vintf_compatibility=fail"
      fi
      fail "Android boot-time build/VINTF consistency check reported incompatibility"
    elif [[ "${props[sys.boot_completed]}" == 1 && \
            "$vintf_checker_unavailable" == 1 ]]; then
      record "vintf_compatibility=inconclusive"
      warn "VINTF compatibility is inconclusive: Android reached system-ready with no recorded incompatibility, but absence of a log error is not a compatibility check"
    elif [[ "${props[sys.boot_completed]}" == 1 ]]; then
      warn "no additional build/VINTF incompatibility marker appears in the system log"
    else
      if [[ "$vintf_checker_unavailable" == 1 ]]; then
        record "vintf_compatibility=inconclusive"
      fi
      fail "boot-time VINTF fallback is inconclusive before system-ready"
    fi
  else
    if [[ "$vintf_checker_unavailable" == 1 ]]; then
      record "vintf_compatibility=inconclusive"
    fi
    fail "unable to inspect boot-time VINTF diagnostics: $(one_line "$vintf_log")"
  fi
fi

section kernel-and-hardware
kernel_arch=$(adb_capture shell uname -m || true)
kernel_release=$(adb_capture shell uname -r || true)
page_size=$(adb_capture shell getconf PAGESIZE || true)
record_value kernel_arch "$kernel_arch"
record_value kernel_release "$kernel_release"
record_value page_size "$page_size"
check_equal "kernel architecture" "$kernel_arch" aarch64
check_equal "kernel page size" "$page_size" 4096
check_nonempty "kernel release" "$kernel_release"

service_table=$(adb_capture shell service list || true)
declare -a required_services=(
  'SurfaceFlinger:'
  'android.hardware.audio.core.IConfig/default:'
  'android.hardware.biometrics.fingerprint.IFingerprint/default:'
  'android.hardware.bluetooth.IBluetoothHci/default:'
  'android.hardware.camera.provider.ICameraProvider/internal/0:'
  'android.hardware.gnss.IGnss/default:'
  'android.hardware.graphics.composer3.IComposer/default:'
  'android.hardware.health.IHealth/default:'
  'android.hardware.nfc.INfc/default:'
  'android.hardware.radio.config.IRadioConfig/default:'
  'android.hardware.sensors.ISensors/default:'
  'android.hardware.wifi.IWifi/default:'
  'audio:'
  'bluetooth_manager:'
  'media.camera:'
  'phone:'
  'sensorservice:'
  'wifi:'
)
for required_service in "${required_services[@]}"; do
  if grep -Fq "$required_service" <<< "$service_table"; then
    pass "service registered: ${required_service%:}"
  else
    fail "required service is absent: ${required_service%:}"
  fi
done

feature_table=$(adb_capture shell pm list features || true)
declare -a required_features=(
  android.hardware.bluetooth
  android.hardware.camera
  android.hardware.camera.front
  android.hardware.fingerprint
  android.hardware.location.gps
  android.hardware.nfc
  android.hardware.sensor.accelerometer
  android.hardware.sensor.gyroscope
  android.hardware.telephony
  android.hardware.wifi
)
for required_feature in "${required_features[@]}"; do
  if grep -Fxq "feature:$required_feature" <<< "$feature_table"; then
    pass "feature declared: $required_feature"
  else
    fail "required feature is absent: $required_feature"
  fi
done

for process_name in system_server surfaceflinger audioserver cameraserver; do
  process_ids=$(adb_capture shell pidof "$process_name" || true)
  record "process.$process_name=$(one_line "$process_ids")"
  if [[ "$process_ids" =~ ^[0-9]+([[:space:]][0-9]+)*$ ]]; then
    pass "$process_name is running"
  else
    fail "$process_name is not running"
  fi
done

display_size=$(adb_capture shell wm size || true)
display_density=$(adb_capture shell wm density || true)
record_value display_size "$display_size"
record_value display_density "$display_density"
check_contains "display size query" "$display_size" "Physical size:"
check_contains "display density query" "$display_density" "Physical density:"

battery_dump=$(adb_capture shell dumpsys battery || true)
battery_level=$(sed -n 's/^[[:space:]]*level: //p' <<< "$battery_dump" | head -n 1)
battery_status=$(sed -n 's/^[[:space:]]*status: //p' <<< "$battery_dump" | head -n 1)
battery_temperature=$(sed -n 's/^[[:space:]]*temperature: //p' <<< "$battery_dump" | head -n 1)
record_value battery_level_percent "$battery_level"
record_value battery_status "$battery_status"
record_value battery_temperature_tenths_c "$battery_temperature"
if [[ "$battery_level" =~ ^[0-9]+$ && "$battery_level" -ge 10 ]]; then
  pass "battery level is readable and at least 10%"
else
  fail "battery level is unavailable or below 10%"
fi

finish_report
