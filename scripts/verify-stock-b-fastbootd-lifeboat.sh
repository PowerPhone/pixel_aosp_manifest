#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
# shellcheck source=lib/recovery-handoff.sh disable=SC1091
source "$script_dir/lib/recovery-handoff.sh"

require_pixel_target cubs "the physical stock-B fastbootd trial"

require_command awk chmod cmp date flock grep mkdir mktemp mv openssl \
  realpath rm sed sha256sum sleep stat unzip

action=${1:-start}
case "$action" in
  start)
    expected_confirmation=TRIAL_PREPARED_PHYSICAL_B_FASTBOOTD_ONLY_NEVER_ANDROID_B
    ;;
  resume-finalize)
    expected_confirmation=RESUME_OR_FINALIZE_ONE_SHOT_PHYSICAL_B_FASTBOOTD_NEVER_ANDROID_B
    ;;
  -h|--help|help)
    cat <<'EOF'
Usage: scripts/verify-stock-b-fastbootd-lifeboat.sh [start|resume-finalize]

  start            Start the one-shot B fastbootd round trip (default).
  resume-finalize  Continue an existing started/verified receipt without ever
                   issuing a second reboot-fastboot trial.
EOF
    exit 0
    ;;
  *) die "unsupported fastbootd-trial action: $action" ;;
esac
[[ "${CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL:-}" == 1 ]] || die \
  "set CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL=1 only for the reviewed fastbootd-only trial"
[[ "${CUBS_STOCK_B_FASTBOOTD_CONFIRM:-}" == "$expected_confirmation" ]] || die \
  "set CUBS_STOCK_B_FASTBOOTD_CONFIRM=$expected_confirmation after reviewing docs/stock-b-physical-preparation.md"

if [[ -n "${CUBS_FASTBOOT_SERIAL:-}" && -n "${ANDROID_SERIAL:-}" && \
      "$CUBS_FASTBOOT_SERIAL" != "$ANDROID_SERIAL" ]]; then
  die "CUBS_FASTBOOT_SERIAL and ANDROID_SERIAL select different devices"
fi
device_serial=${CUBS_FASTBOOT_SERIAL:-${ANDROID_SERIAL:-}}
[[ -n "$device_serial" ]] || die \
  "select the phone explicitly with CUBS_FASTBOOT_SERIAL"
[[ "$device_serial" != -* && ! "$device_serial" =~ [[:space:]] ]] || \
  die "invalid fastboot serial"

expected_fastboot_version=37.0.1
expected_fastboot_sha256=a686e2c7e8dc9cf4cba0cb8a2eef05f7b2bd682c925abd032fe203215d80b618
if [[ -n "${FASTBOOT:-}" ]]; then
  [[ "$FASTBOOT" == /* ]] || die "FASTBOOT must be an absolute path"
  fastboot_bin=$FASTBOOT
elif [[ -x "$project_root/work/toolchains/platform-tools/fastboot" ]]; then
  fastboot_bin="$project_root/work/toolchains/platform-tools/fastboot"
else
  require_command fastboot
  fastboot_bin=$(command -v fastboot)
fi
[[ -f "$fastboot_bin" && ! -L "$fastboot_bin" && -x "$fastboot_bin" ]] || \
  die "fastboot is not a safe executable: $fastboot_bin"
fastboot_bin=$(realpath -e -- "$fastboot_bin")
fastboot_command=("$fastboot_bin" -s "$device_serial")

revalidate_pinned_fastboot() {
  local actual_path digest output version
  [[ -f "$fastboot_bin" && ! -L "$fastboot_bin" && -x "$fastboot_bin" ]] || \
    die "fastboot is not a safe executable: $fastboot_bin"
  actual_path=$(realpath -e -- "$fastboot_bin")
  [[ "$actual_path" == "$fastboot_bin" ]] || \
    die "the selected fastboot executable path changed during authorization"
  digest=$(sha256sum "$fastboot_bin")
  digest=${digest%% *}
  [[ "$digest" == "$expected_fastboot_sha256" ]] || \
    die "fastboot does not match the pinned Platform-Tools binary digest"
  output=$("$fastboot_bin" --version 2>&1) || \
    die "unable to execute the pinned fastboot version check"
  if [[ "$output" =~ fastboot[[:space:]]version[[:space:]]([0-9]+(\.[0-9]+)*) ]]; then
    version=${BASH_REMATCH[1]}
  else
    die "unable to determine fastboot version"
  fi
  [[ "$version" == "$expected_fastboot_version" ]] || die \
    "this release is pinned to fastboot $expected_fastboot_version; found $version"
}

revalidate_pinned_fastboot

confirm_on_tty() {
  local entered
  [[ -t 0 && -t 1 ]] || \
    die "refusing the fastbootd lifeboat action without an interactive terminal"
  printf '\nType exactly: %s\n> ' "$expected_confirmation" >/dev/tty
  IFS= read -r entered </dev/tty
  [[ "$entered" == "$expected_confirmation" ]] || \
    die "confirmation phrase did not match"
}

factory_image="$project_root/downloads/$FACTORY_IMAGE_FILENAME"
verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"
"$script_dir/extract-stock.sh"
stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
stock_images="$stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
require_file "$stock_images"
[[ ! -L "$stock_images" ]] || die "refusing a symlinked stock image archive"
stock_android_info=$(unzip -p "$stock_images" android-info.txt) || \
  die "nested stock ZIP has no android-info.txt"
expected_board=$(sed -n 's/^require board=//p' <<<"$stock_android_info")
expected_bootloader=$(sed -n 's/^require version-bootloader=//p' \
  <<<"$stock_android_info")
expected_baseband=$(sed -n 's/^require version-baseband=//p' \
  <<<"$stock_android_info")
[[ "|$expected_board|" == *"|$DEVICE_CODENAME|"* && \
   $(grep -c '^require board=' <<<"$stock_android_info") -eq 1 && \
   $(grep -c '^require version-bootloader=' <<<"$stock_android_info") -eq 1 && \
   $(grep -c '^require version-baseband=' <<<"$stock_android_info") -eq 1 && \
   -n "$expected_bootloader" && -n "$expected_baseband" ]] || \
  die "nested stock ZIP has malformed firmware requirements"

verify_trial_archive_inputs() {
  local current_android_info current_inner_sha
  verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"
  current_inner_sha=$(sha256sum "$stock_images" | awk '{print $1}')
  [[ "$current_inner_sha" == "$CUBS_STOCK_INNER_IMAGE_SHA256" ]] || \
    die "nested stock image ZIP differs from its exact recovery-policy pin"
  current_android_info=$(unzip -p "$stock_images" android-info.txt) || \
    die "nested stock ZIP lost android-info.txt"
  [[ "$current_android_info" == "$stock_android_info" ]] || \
    die "nested stock firmware requirements changed during authorization"
}

verify_trial_archive_inputs

# Capture getvar status and output separately. A value response and an absent
# response have disjoint acceptance rules; is-logical:no is never absence.
declare -a fastboot_getvar_values=()
fastboot_getvar_capture() {
  local variable=$1 line output status value
  local failed_count=0 parsed_count=0
  [[ "$variable" =~ ^[a-z0-9][a-z0-9:_-]*$ ]] || \
    die "unsafe fastboot getvar name: $variable"
  if output=$("${fastboot_command[@]}" getvar "$variable" 2>&1); then
    status=0
  else
    status=$?
  fi
  [[ "$output" != *$'\r'* ]] || \
    die "$variable returned a carriage-return-bearing response"
  fastboot_getvar_values=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *FAILED* ]]; then
      ((failed_count += 1))
    fi
    if [[ "$line" =~ ^(\(bootloader\)[[:space:]]*)?"$variable":[[:space:]]*(.*)$ ]]; then
      value=${BASH_REMATCH[2]}
      fastboot_getvar_values+=("$value")
      ((parsed_count += 1))
    fi
  done <<<"$output"
  fastboot_getvar_output=$output
  fastboot_getvar_status=$status
  fastboot_getvar_parsed_count=$parsed_count
  fastboot_getvar_failed_count=$failed_count
}

fastboot_value() {
  local variable=$1 value
  fastboot_getvar_capture "$variable"
  [[ "$fastboot_getvar_status" -eq 0 && \
     "$fastboot_getvar_parsed_count" -eq 1 && \
     "$fastboot_getvar_failed_count" -eq 0 ]] || \
    die "$variable did not return exactly one successful getvar value"
  value=${fastboot_getvar_values[0]}
  [[ -n "$value" && "$value" != *$'\n'* && \
     ! "$value" =~ ^[[:space:]] && ! "$value" =~ [[:space:]]$ ]] || \
    die "$variable returned an empty or whitespace-padded getvar value"
  printf '%s\n' "$value"
}

require_fastboot_value_exact() {
  local variable=$1 expected=$2 actual
  actual=$(fastboot_value "$variable")
  [[ "$actual" == "$expected" ]] || \
    die "$variable differs from its exact required value"
}

require_fastboot_getvar_absent() {
  local variable=$1 expected_remote=$2 failure_suffix line
  local exact_failure=0
  failure_suffix="FAILED (remote: '$expected_remote')"
  fastboot_getvar_capture "$variable"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^"getvar:$variable"[[:space:]]+"$failure_suffix"$ ]]; then
      ((exact_failure += 1))
    fi
  done <<<"$fastboot_getvar_output"
  [[ "$fastboot_getvar_parsed_count" -eq 0 && \
     "$fastboot_getvar_failed_count" -eq 1 && \
     "$exact_failure" -eq 1 && \
     ( "$fastboot_getvar_status" -eq 0 || \
       "$fastboot_getvar_status" -eq 1 ) ]] || \
    die "$variable did not return the exact audited absent-partition response"
}

assert_single_selected_device() {
  local output
  local -a devices=()
  revalidate_pinned_fastboot
  output=$("$fastboot_bin" devices) || \
    die "unable to enumerate fastboot devices"
  mapfile -t devices < <(awk 'NF {print $1}' <<<"$output")
  (( ${#devices[@]} == 1 )) || \
    die "expected exactly one fastboot device; found ${#devices[@]}"
  [[ "${devices[0]}" == "$device_serial" ]] || \
    die "the explicitly selected phone is not the sole fastboot device"
}

wait_for_selected_device() {
  local attempt output
  local -a devices=()
  for ((attempt = 1; attempt <= 90; attempt += 1)); do
    output=$("$fastboot_bin" devices 2>/dev/null) || output=
    mapfile -t devices < <(awk 'NF {print $1}' <<<"$output")
    if (( ${#devices[@]} == 1 )) && [[ "${devices[0]}" == "$device_serial" ]]; then
      return 0
    fi
    if (( ${#devices[@]} > 0 )); then
      die "an unexpected or additional fastboot device appeared during USB transition"
    fi
    sleep 1
  done
  die "timed out waiting for $device_serial; restore WSL USB forwarding and rerun"
}

require_nonzero_partition_size() {
  local partition=$1 size
  size=$(cubs_normalize_partition_size \
    "$(fastboot_value "partition-size:$partition")")
  [[ "$size" =~ ^[0-9a-f]+$ && "$size" =~ [1-9a-f] ]] || \
    die "unable to prove a nonzero partition size for $partition"
}

require_b_success_value() {
  local value
  value=$(fastboot_value slot-successful:b)
  [[ "$value" =~ ^(yes|no)$ ]] || \
    die "slot B has an unreadable successful flag: ${value:-unknown}"
}

check_healthy_a() {
  require_fastboot_value_exact slot-successful:a yes
  require_fastboot_value_exact slot-unbootable:a no
}

check_bootloader_identity_and_flags() {
  local expected_slot=${1:-b} a_success
  [[ "$expected_slot" =~ ^(a|b)$ ]] || die "invalid expected bootloader slot"
  require_fastboot_value_exact product "$DEVICE_CODENAME"
  require_fastboot_value_exact version-bootloader "$expected_bootloader"
  require_fastboot_value_exact version-baseband "$expected_baseband"
  require_fastboot_value_exact unlocked yes
  require_fastboot_value_exact is-userspace no
  require_fastboot_value_exact slot-count 2
  require_fastboot_value_exact current-slot "$expected_slot"
  require_fastboot_value_exact snapshot-update-status none
  require_fastboot_value_exact slot-unbootable:b no
  require_b_success_value
  if [[ "$expected_slot" == b ]]; then
    check_healthy_a
  else
    require_fastboot_value_exact slot-unbootable:a no
    a_success=$(fastboot_value slot-successful:a)
    [[ "$a_success" =~ ^(yes|no)$ ]] || \
      die "abort-to-A recovery left slot A's successful flag unreadable"
  fi
}

check_physical_pairs() {
  local partition
  for partition in "${cubs_preserved_b_partitions[@]}"; do
    require_fastboot_value_exact "has-slot:$partition" yes
    require_fastboot_value_exact "is-logical:${partition}_a" no
    require_fastboot_value_exact "is-logical:${partition}_b" no
    require_nonzero_partition_size "${partition}_a"
    require_nonzero_partition_size "${partition}_b"
  done
}

verify_live_vendor_boot_b_control() {
  local actual_sha fetched size_hex target_size
  fetched=$(mktemp "$cubs_recovery_state_dir/.vendor-boot-b-fetch.XXXXXX")
  rm -f -- "$fetched"
  if ! "${fastboot_command[@]}" fetch vendor_boot_b "$fetched"; then
    rm -f -- "$fetched"
    die "unable to fetch the full live vendor_boot_b partition"
  fi
  [[ -f "$fetched" && ! -L "$fetched" && \
     $(stat -c '%u' "$fetched") == "$EUID" && \
     $(stat -c '%h' "$fetched") == 1 ]] || {
    rm -f -- "$fetched"
    die "live vendor_boot_b fetch is unsafe"
  }
  target_size=$(cubs_normalize_partition_size \
    "$(fastboot_value partition-size:vendor_boot_b)")
  size_hex=$(printf '%x' "$(stat -c '%s' "$fetched")")
  [[ "$size_hex" == "$target_size" ]] || {
    rm -f -- "$fetched"
    die "live vendor_boot_b fetch does not cover its full physical partition"
  }
  actual_sha=$(sha256sum "$fetched" | awk '{print $1}')
  rm -f -- "$fetched"
  [[ "$actual_sha" == "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || \
    die "live vendor_boot_b bytes differ from the exact direct-lifeboat pin"
}

logical_partitions=(system system_dlkm system_ext product vendor vendor_dlkm)
trial_size_keys=()
for partition in "${logical_partitions[@]}"; do
  trial_size_keys+=("logical_${partition}_a_size")
done
declare -A fastbootd_logical_sizes=()
declare -A recorded_logical_sizes=()

verify_bound_preparation() {
  local freshness=$1 partition size
  cubs_verify_stock_b_preparation \
    "$device_serial" "$expected_bootloader" "$expected_baseband" ready \
    "$freshness"
  [[ "$cubs_verified_stock_b_preparation_policy_sha256" == \
       "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256" && \
     "$cubs_verified_stock_b_baseline_sha256" == \
       "$cubs_verified_stock_a_baseline_sha256" && \
     "$cubs_verified_stock_b_logical_sizes_sha256" == \
       "$cubs_verified_stock_a_logical_sizes_sha256" ]] || \
    die "stock-B preparation is not bound to the current v7 stock-A baseline"
  for partition in "${logical_partitions[@]}"; do
    size=${cubs_verified_stock_a_logical_sizes[${partition}_a]:-}
    [[ "$size" =~ ^[0-9a-f]+$ && "$size" =~ [1-9a-f] ]] || \
      die "verified stock-A expanded logical size is unavailable: ${partition}_a"
  done
}

check_fastbootd_a_only() {
  local a_size base_mode partition
  require_fastboot_value_exact product "$DEVICE_CODENAME"
  require_fastboot_value_exact is-userspace yes
  require_fastboot_value_exact unlocked yes
  require_fastboot_value_exact slot-count 2
  require_fastboot_value_exact current-slot b
  require_fastboot_value_exact snapshot-update-status none
  require_fastboot_value_exact has-slot:super no
  fastbootd_logical_sizes=()
  for partition in "${logical_partitions[@]}"; do
    base_mode=$(fastboot_value "has-slot:$partition")
    [[ "$base_mode" == no ]] || \
      die "$partition does not report the uniform non-slotted A-only namespace"
    require_fastboot_getvar_absent \
      "is-logical:$partition" 'Partition not found'
    require_fastboot_getvar_absent \
      "partition-size:$partition" 'Could not open partition'
    require_fastboot_value_exact "is-logical:${partition}_a" yes
    a_size=$(cubs_normalize_partition_size \
      "$(fastboot_value "partition-size:${partition}_a")")
    [[ "$a_size" == \
       "${cubs_verified_stock_a_logical_sizes[${partition}_a]}" ]] || \
      die "${partition}_a differs from its factory-expanded preflight size"
    fastbootd_logical_sizes["${partition}_a"]=$a_size
    require_fastboot_getvar_absent \
      "is-logical:${partition}_b" 'Partition not found'
    require_fastboot_getvar_absent \
      "partition-size:${partition}_b" 'Could not open partition'
  done
  require_fastboot_value_exact product "$DEVICE_CODENAME"
  require_fastboot_value_exact is-userspace yes
  require_fastboot_value_exact current-slot b
  require_fastboot_value_exact snapshot-update-status none
}

write_fastbootd_trial_receipt() {
  local state=$1 fastbootd_epoch=$2 bootloader_epoch=$3
  local abort_started_epoch=$4 abort_verified_epoch=$5
  local current_sha logical_mode logical_namespace partition temporary value_a
  [[ "$state" =~ ^(started|fastbootd_verified|verified|aborting_to_a|aborted_to_a)$ ]] || \
    die "invalid fastbootd trial receipt state"
  if [[ "$state" == started ]]; then
    [[ ! -e "$cubs_stock_b_fastbootd_trial_receipt" && \
       ! -L "$cubs_stock_b_fastbootd_trial_receipt" ]] || \
      die "the one-shot fastbootd trial was already started"
  else
    cubs_private_file "$cubs_stock_b_fastbootd_trial_receipt"
    current_sha=$(sha256sum "$cubs_stock_b_fastbootd_trial_receipt")
    current_sha=${current_sha%% *}
    [[ "$current_sha" == "$loaded_trial_receipt_sha256" ]] || \
      die "one-shot fastbootd trial receipt changed during the USB round trip"
  fi
  if [[ "$state" =~ ^(fastbootd_verified|verified)$ ]]; then
    logical_mode=no
    logical_namespace=a_only
  else
    logical_mode=pending
    logical_namespace=pending
  fi
  temporary=$(mktemp "$cubs_recovery_state_dir/.fastbootd-trial.XXXXXX")
  {
    printf 'schema=cubs-stock-b-fastbootd-trial-v4\n'
    printf 'state=%s\n' "$state"
    printf 'created_epoch=%s\n' "$trial_created_epoch"
    printf 'fastbootd_verified_epoch=%s\n' "$fastbootd_epoch"
    printf 'bootloader_verified_epoch=%s\n' "$bootloader_epoch"
    printf 'abort_started_epoch=%s\n' "$abort_started_epoch"
    printf 'abort_verified_epoch=%s\n' "$abort_verified_epoch"
    printf 'trial_id=%s\n' "$trial_id"
    printf 'serial_binding_sha256=%s\n' "$trial_serial_binding_sha256"
    printf 'preparation_receipt_sha256=%s\n' \
      "$cubs_verified_stock_b_receipt_sha256"
    printf 'source_payload_manifest_sha256=%s\n' \
      "$cubs_verified_stock_b_source_payload_manifest_sha256"
    printf 'stock_a_preflight_sha256=%s\n' \
      "$cubs_verified_stock_a_preflight_sha256"
    printf 'stock_a_baseline_evidence_sha256=%s\n' \
      "$cubs_verified_stock_a_baseline_sha256"
    printf 'stock_a_logical_sizes_sha256=%s\n' \
      "$cubs_verified_stock_a_logical_sizes_sha256"
    printf 'logical_base_has_slot_mode=%s\n' "$logical_mode"
    printf 'logical_namespace=%s\n' "$logical_namespace"
    printf 'device=%s\n' "$DEVICE_CODENAME"
    printf 'target_slot=b\n'
    printf 'android_b_booted=no\n'
    for partition in "${logical_partitions[@]}"; do
      if [[ "$state" =~ ^(fastbootd_verified|verified)$ ]]; then
        value_a=${fastbootd_logical_sizes[${partition}_a]:-}
        [[ "$value_a" == \
           "${cubs_verified_stock_a_logical_sizes[${partition}_a]}" ]] || \
          die "verified fastbootd logical evidence is incomplete"
      else
        value_a=pending
      fi
      printf 'logical_%s_a_size=%s\n' "$partition" "$value_a"
    done
    printf 'source_preparation_policy_sha256=%s\n' \
      "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256"
    printf 'trial_policy_sha256=%s\n' \
      "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256"
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$cubs_stock_b_fastbootd_trial_receipt"
  cubs_private_file "$cubs_stock_b_fastbootd_trial_receipt"
  loaded_trial_receipt_sha256=$(sha256sum \
    "$cubs_stock_b_fastbootd_trial_receipt" | awk '{print $1}')
  cubs_verified_stock_b_trial_policy_sha256=$CUBS_STOCK_B_PREPARATION_POLICY_SHA256
}

load_fastbootd_trial_receipt() {
  local abort_started abort_verified actual_binding boot_epoch created
  local fastbootd_epoch now partition
  local abort_started_number abort_verified_number boot_number created_number
  local fastbootd_number now_number preparation_created_number
  local preparation_expires_number value_a
  local -A trial=()
  cubs_private_file "$cubs_stock_b_fastbootd_trial_receipt"
  cubs_load_exact_kv "$cubs_stock_b_fastbootd_trial_receipt" trial \
    schema state created_epoch fastbootd_verified_epoch \
    bootloader_verified_epoch abort_started_epoch abort_verified_epoch \
    trial_id serial_binding_sha256 preparation_receipt_sha256 \
    source_payload_manifest_sha256 stock_a_preflight_sha256 \
    stock_a_baseline_evidence_sha256 stock_a_logical_sizes_sha256 \
    logical_base_has_slot_mode logical_namespace device target_slot \
    android_b_booted "${trial_size_keys[@]}" \
    source_preparation_policy_sha256 trial_policy_sha256
  [[ "${trial[schema]}" == cubs-stock-b-fastbootd-trial-v4 && \
     "${trial[state]}" =~ ^(started|fastbootd_verified|verified|aborting_to_a|aborted_to_a)$ && \
     "${trial[trial_id]}" =~ ^[0-9a-f]{32}$ && \
     "${trial[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${trial[preparation_receipt_sha256]}" == \
       "$cubs_verified_stock_b_receipt_sha256" && \
     "${trial[source_payload_manifest_sha256]}" == \
       "$cubs_verified_stock_b_source_payload_manifest_sha256" && \
     "${trial[stock_a_preflight_sha256]}" == \
       "$cubs_verified_stock_a_preflight_sha256" && \
     "${trial[stock_a_baseline_evidence_sha256]}" == \
       "$cubs_verified_stock_a_baseline_sha256" && \
     "${trial[stock_a_logical_sizes_sha256]}" == \
       "$cubs_verified_stock_a_logical_sizes_sha256" && \
     "${trial[device]}" == "$DEVICE_CODENAME" && \
     "${trial[target_slot]}" == b && \
     "${trial[android_b_booted]}" == no && \
     "${trial[source_preparation_policy_sha256]}" == \
       "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256" && \
     "${trial[trial_policy_sha256]}" == \
       "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256" ]] || \
    die "fastbootd trial receipt does not match this exact v7 direct policy"

  actual_binding=$(cubs_serial_binding "${trial[trial_id]}" "$device_serial")
  [[ "$actual_binding" == "${trial[serial_binding_sha256]}" ]] || \
    die "fastbootd trial receipt belongs to another USB transport"
  created=${trial[created_epoch]}
  fastbootd_epoch=${trial[fastbootd_verified_epoch]}
  boot_epoch=${trial[bootloader_verified_epoch]}
  abort_started=${trial[abort_started_epoch]}
  abort_verified=${trial[abort_verified_epoch]}
  now=$(date +%s)
  [[ "$created" =~ ^[1-9][0-9]{0,17}$ && \
     "$fastbootd_epoch" =~ ^[0-9]{1,18}$ && \
     "$boot_epoch" =~ ^[0-9]{1,18}$ && \
     "$abort_started" =~ ^[0-9]{1,18}$ && \
     "$abort_verified" =~ ^[0-9]{1,18}$ && \
     "$now" =~ ^[1-9][0-9]{0,17}$ ]] || \
    die "fastbootd trial receipt has invalid authorization timestamps"
  created_number=$((10#$created))
  fastbootd_number=$((10#$fastbootd_epoch))
  boot_number=$((10#$boot_epoch))
  abort_started_number=$((10#$abort_started))
  abort_verified_number=$((10#$abort_verified))
  now_number=$((10#$now))
  preparation_created_number=$((10#$cubs_verified_stock_b_created_epoch))
  preparation_expires_number=$((10#$cubs_verified_stock_b_expires_epoch))
  (( created_number >= preparation_created_number && \
     created_number <= preparation_expires_number && \
     created_number <= now_number )) || \
    die "fastbootd trial was not started within its preparation authorization"

  recorded_logical_sizes=()
  case "${trial[state]}" in
    started)
      [[ "$fastbootd_epoch" == 0 && "$boot_epoch" == 0 && \
         "$abort_started" == 0 && "$abort_verified" == 0 && \
         "${trial[logical_base_has_slot_mode]}" == pending && \
         "${trial[logical_namespace]}" == pending ]] || \
        die "started fastbootd trial has premature verification evidence"
      ;;
    fastbootd_verified|verified)
      [[ "$abort_started" == 0 && "$abort_verified" == 0 && \
         "${trial[logical_base_has_slot_mode]}" == no && \
         "${trial[logical_namespace]}" == a_only && \
         "$fastbootd_epoch" =~ ^[1-9][0-9]{0,17}$ ]] || \
        die "successful fastbootd trial has invalid namespace or timestamps"
      (( fastbootd_number >= created_number && \
         fastbootd_number <= now_number )) || \
        die "fastbootd verification timestamp is inconsistent"
      if [[ "${trial[state]}" == fastbootd_verified ]]; then
        [[ "$boot_epoch" == 0 ]] || \
          die "fastbootd-only receipt has a bootloader verification timestamp"
      else
        [[ "$boot_epoch" =~ ^[1-9][0-9]{0,17}$ ]] || \
          die "bootloader verification timestamp is malformed"
        (( boot_number >= fastbootd_number && boot_number <= now_number )) || \
          die "bootloader verification timestamp is inconsistent"
      fi
      ;;
    aborting_to_a|aborted_to_a)
      [[ "$fastbootd_epoch" == 0 && "$boot_epoch" == 0 && \
         "$abort_started" =~ ^[1-9][0-9]{0,17}$ && \
         "${trial[logical_base_has_slot_mode]}" == pending && \
         "${trial[logical_namespace]}" == pending ]] || \
        die "aborted fastbootd trial has forbidden namespace evidence"
      (( abort_started_number >= created_number && \
         abort_started_number <= now_number )) || \
        die "abort-to-A authorization timestamp is inconsistent"
      if [[ "${trial[state]}" == aborting_to_a ]]; then
        [[ "$abort_verified" == 0 ]] || \
          die "pending abort-to-A receipt has a completion timestamp"
      else
        [[ "$abort_verified" =~ ^[1-9][0-9]{0,17}$ ]] || \
          die "completed abort-to-A receipt lacks its completion timestamp"
        (( abort_verified_number >= abort_started_number && \
           abort_verified_number <= now_number )) || \
          die "abort-to-A completion timestamp is inconsistent"
      fi
      ;;
  esac

  for partition in "${logical_partitions[@]}"; do
    value_a=${trial[logical_${partition}_a_size]}
    if [[ "${trial[state]}" =~ ^(fastbootd_verified|verified)$ ]]; then
      [[ "$value_a" == \
         "${cubs_verified_stock_a_logical_sizes[${partition}_a]}" ]] || \
        die "fastbootd trial receipt has an invalid stock-A logical size"
      recorded_logical_sizes["${partition}_a"]=$value_a
      fastbootd_logical_sizes["${partition}_a"]=$value_a
    else
      [[ "$value_a" == pending ]] || \
        die "unverified trial receipt has forbidden logical-size evidence"
    fi
  done
  trial_state=${trial[state]}
  trial_id=${trial[trial_id]}
  trial_created_epoch=$created
  trial_fastbootd_verified_epoch=$fastbootd_epoch
  trial_bootloader_verified_epoch=$boot_epoch
  trial_abort_started_epoch=$abort_started
  trial_abort_verified_epoch=$abort_verified
  trial_serial_binding_sha256=${trial[serial_binding_sha256]}
  cubs_verified_stock_b_trial_policy_sha256=${trial[trial_policy_sha256]}
  loaded_trial_receipt_sha256=$(sha256sum \
    "$cubs_stock_b_fastbootd_trial_receipt" | awk '{print $1}')
}

compare_fastbootd_sizes_to_receipt() {
  local partition
  for partition in "${logical_partitions[@]}"; do
    [[ "${fastbootd_logical_sizes[${partition}_a]:-}" == \
       "${recorded_logical_sizes[${partition}_a]:-}" ]] || \
      die "live fastbootd logical sizes differ from the one-shot receipt"
  done
}

preflight_preparation_in_bootloader() {
  local freshness=$1 a_sizes b_sizes
  verify_bound_preparation "$freshness"
  check_bootloader_identity_and_flags b
  check_physical_pairs
  a_sizes=$(cubs_physical_slot_sizes_sha256 a)
  b_sizes=$(cubs_physical_slot_sizes_sha256 b)
  [[ "$a_sizes" == "$cubs_verified_stock_b_a_sizes_sha256" && \
     "$b_sizes" == "$cubs_verified_stock_b_b_sizes_sha256" ]] || \
    die "physical A/B sizes differ from the exact preparation receipt"
  verified_b_sizes_sha256=$b_sizes
  verify_live_vendor_boot_b_control
}

preflight_preparation_in_a_bootloader() {
  local freshness=$1 a_sizes b_sizes
  verify_bound_preparation "$freshness"
  check_bootloader_identity_and_flags a
  check_physical_pairs
  a_sizes=$(cubs_physical_slot_sizes_sha256 a)
  b_sizes=$(cubs_physical_slot_sizes_sha256 b)
  [[ "$a_sizes" == "$cubs_verified_stock_b_a_sizes_sha256" && \
     "$b_sizes" == "$cubs_verified_stock_b_b_sizes_sha256" ]] || \
    die "physical A/B sizes differ from the exact preparation receipt"
  verified_b_sizes_sha256=$b_sizes
  verify_live_vendor_boot_b_control
}

set_trial_consumption_authority() {
  cubs_verified_stock_b_trial_sha256=$loaded_trial_receipt_sha256
  cubs_verified_stock_b_trial_policy_sha256=$CUBS_STOCK_B_PREPARATION_POLICY_SHA256
}

verify_or_publish_lineage() {
  local anchor_id orphan_sha retired_dir destination serial_binding_sha256
  local lineage_present=0 handoff_present=0
  set_trial_consumption_authority
  [[ ! -e "$cubs_recovery_lineage" && ! -L "$cubs_recovery_lineage" ]] || \
    lineage_present=1
  [[ ! -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]] || \
    handoff_present=1
  if [[ -e "$cubs_recovery_lineage" && ! -L "$cubs_recovery_lineage" && \
        ! -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]]; then
    cubs_verify_lifeboat_lineage "$device_serial" "$verified_b_sizes_sha256" \
      "$expected_bootloader" "$expected_baseband"
    [[ "$cubs_verified_stock_b_source" == direct_factory_physical_b && \
       "$cubs_verified_stock_b_provenance_sha256" == \
         "$loaded_trial_receipt_sha256" ]] || \
      die "orphan direct lineage does not match the verified trial receipt"
    orphan_sha=$cubs_verified_lineage_sha256
    retired_dir="$cubs_recovery_state_dir/retired"
    [[ ! -L "$retired_dir" ]] || die "retired recovery directory is unsafe"
    mkdir -p "$retired_dir"
    chmod 0700 "$retired_dir"
    cubs_private_dir "$retired_dir"
    destination="$retired_dir/orphan-direct-lineage-${orphan_sha}"
    [[ ! -e "$destination" && ! -L "$destination" ]] || \
      die "retired orphan-lineage destination already exists"
    mv -T -- "$cubs_recovery_lineage" "$destination"
    cubs_private_file "$destination"
    lineage_present=0
  elif (( lineage_present != handoff_present )); then
    die "direct lineage and handoff are incompletely published"
  fi
  if [[ ! -e "$cubs_recovery_lineage" && ! -L "$cubs_recovery_lineage" && \
        ! -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]]; then
    anchor_id=$(cubs_random_anchor_id)
    serial_binding_sha256=$(cubs_serial_binding "$anchor_id" "$device_serial")
    cubs_write_lineage_and_handoff \
      "$anchor_id" "$serial_binding_sha256" "$verified_b_sizes_sha256" \
      "$expected_bootloader" "$expected_baseband" \
      direct_factory_physical_b "$loaded_trial_receipt_sha256" \
      "$cubs_verified_stock_b_source_payload_manifest_sha256" \
      "$cubs_verified_stock_b_vendor_boot_fetch_sha256" \
      physical_b_lifeboat
  fi
  cubs_verify_lifeboat_lineage "$device_serial" "$verified_b_sizes_sha256" \
    "$expected_bootloader" "$expected_baseband"
  [[ "$cubs_verified_stock_b_source" == direct_factory_physical_b && \
     "$cubs_verified_stock_b_provenance_sha256" == \
       "$loaded_trial_receipt_sha256" && \
     "$cubs_verified_physical_b_source_manifest_sha256" == \
       "$CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256" && \
     "$cubs_verified_physical_b_vendor_boot_fetch_sha256" == \
       "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || \
    die "published direct lineage does not match the exact trial provenance"
  cubs_verify_lifeboat_handoff_for_recovery "$verified_b_sizes_sha256"
  set_trial_consumption_authority
  cubs_consume_verified_stock_b_preparation
}

finish_verified_fastbootd_from_bootloader() {
  preflight_preparation_in_bootloader historical
  if [[ "$trial_state" == fastbootd_verified ]]; then
    trial_bootloader_verified_epoch=$(date +%s)
    write_fastbootd_trial_receipt verified \
      "$trial_fastbootd_verified_epoch" "$trial_bootloader_verified_epoch" 0 0
    trial_state=verified
  fi
  verify_or_publish_lineage
  note "verified the direct physical-B A-only fastbootd lifeboat and archived its provenance"
  note "created a one-hour private physical_b_lifeboat handoff"
  note "the phone remains in bootloader fastboot with B current; never boot Android B"
}

require_no_conflicting_trial_state() {
  [[ ! -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" && \
     ! -e "$cubs_recovery_lineage" && ! -L "$cubs_recovery_lineage" && \
     ! -e "$cubs_stock_b_fastbootd_trial_receipt" && \
     ! -L "$cubs_stock_b_fastbootd_trial_receipt" && \
     ! -e "$cubs_stock_b_consumption_transaction" && \
     ! -L "$cubs_stock_b_consumption_transaction" && \
     ! -e "$cubs_stock_a_lpdump_evidence" && \
     ! -L "$cubs_stock_a_lpdump_evidence" && \
     ! -e "$cubs_slot_a_flash_transaction" && \
     ! -L "$cubs_slot_a_flash_transaction" && \
     ! -e "$cubs_runtime_boot_attestation" && \
     ! -L "$cubs_runtime_boot_attestation" && \
     ! -e "$cubs_flash_retirement_transaction" && \
     ! -L "$cubs_flash_retirement_transaction" && \
     ! -e "$cubs_stock_restore_transaction" && \
     ! -L "$cubs_stock_restore_transaction" ]] || \
    die "an active recovery lineage, handoff, or trial receipt already exists"
}

start_trial() {
  cubs_lock_recovery_state
  require_no_conflicting_trial_state
  assert_single_selected_device
  preflight_preparation_in_bootloader fresh
  cubs_require_stock_b_preparation_slack \
    "$CUBS_STOCK_B_TRIAL_MIN_RECEIPT_SLACK_SECONDS"
  confirm_on_tty
  verify_trial_archive_inputs
  require_no_conflicting_trial_state
  assert_single_selected_device
  preflight_preparation_in_bootloader fresh
  cubs_require_stock_b_preparation_slack \
    "$CUBS_STOCK_B_TRIAL_MIN_RECEIPT_SLACK_SECONDS"
  trial_id=$(cubs_random_anchor_id)
  trial_serial_binding_sha256=$(cubs_serial_binding "$trial_id" "$device_serial")
  trial_created_epoch=$(date +%s)
  write_fastbootd_trial_receipt started 0 0 0 0
  trial_state=started
  note "entering prepared physical B only as the fastbootd recovery lifeboat"
  note "Android B is forbidden; only the exact stock-A logical namespace is authorized"
  "${fastboot_command[@]}" reboot fastboot
  wait_for_selected_device
  check_fastbootd_a_only
  trial_fastbootd_verified_epoch=$(date +%s)
  write_fastbootd_trial_receipt fastbootd_verified \
    "$trial_fastbootd_verified_epoch" 0 0 0
  trial_state=fastbootd_verified
  note "A-only fastbootd trial passed; returning the same transport to bootloader fastboot"
  "${fastboot_command[@]}" reboot bootloader
  wait_for_selected_device
  finish_verified_fastbootd_from_bootloader
}

resume_or_finalize_trial() {
  local current_slot lineage_present=0 handoff_present=0 userspace
  cubs_lock_recovery_state
  [[ ! -e "$cubs_slot_a_flash_transaction" && \
     ! -L "$cubs_slot_a_flash_transaction" ]] || \
    die "slot-A flash transaction conflicts with a direct physical-B trial"
  [[ ! -e "$cubs_runtime_boot_attestation" && \
     ! -L "$cubs_runtime_boot_attestation" ]] || \
    die "runtime boot attestation conflicts with a direct physical-B trial"
  [[ ! -e "$cubs_flash_retirement_transaction" && \
     ! -L "$cubs_flash_retirement_transaction" ]] || \
    die "flash-retirement transaction conflicts with a direct physical-B trial"
  [[ ! -e "$cubs_stock_restore_transaction" && \
     ! -L "$cubs_stock_restore_transaction" ]] || \
    die "stock-restore transaction conflicts with a direct physical-B trial"
  [[ ! -e "$cubs_stock_a_lpdump_evidence" && \
     ! -L "$cubs_stock_a_lpdump_evidence" ]] || \
    die "legacy stock-A lpdump evidence has no v7 trial authority"
  if [[ -e "$cubs_stock_b_consumption_transaction" || \
        -L "$cubs_stock_b_consumption_transaction" ]]; then
    [[ ! -e "$cubs_recovery_lineage" && ! -L "$cubs_recovery_lineage" ]] || \
      lineage_present=1
    [[ ! -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]] || \
      handoff_present=1
    (( lineage_present == handoff_present )) || \
      die "pending evidence consumption has incomplete lineage publication"
    cubs_finish_pending_stock_b_consumption
    if (( lineage_present == 1 )); then
      note "completed the interrupted archive cleanup for a verified physical-B lifeboat"
    else
      note "completed the interrupted archive cleanup for an aborted trial"
    fi
    note "no device command was replayed"
    return
  fi
  [[ -e "$cubs_stock_b_fastbootd_trial_receipt" && \
     ! -L "$cubs_stock_b_fastbootd_trial_receipt" ]] || \
    die "resume-finalize requires an existing one-shot trial receipt"
  assert_single_selected_device
  verify_bound_preparation historical
  load_fastbootd_trial_receipt
  userspace=$(fastboot_value is-userspace)
  [[ "$userspace" =~ ^(yes|no)$ ]] || \
    die "unable to identify the current fastboot mode"
  current_slot=unknown
  if [[ "$userspace" == no ]]; then
    current_slot=$(fastboot_value current-slot)
    [[ "$current_slot" =~ ^(a|b)$ ]] || \
      die "unable to identify the current bootloader slot"
  fi
  case "$trial_state:$userspace:$current_slot" in
    started:yes:unknown)
      check_fastbootd_a_only
      confirm_on_tty
      verify_trial_archive_inputs
      assert_single_selected_device
      verify_bound_preparation historical
      load_fastbootd_trial_receipt
      [[ "$trial_state" == started ]] || \
        die "started trial receipt changed during continuation authorization"
      check_fastbootd_a_only
      trial_fastbootd_verified_epoch=$(date +%s)
      write_fastbootd_trial_receipt fastbootd_verified \
        "$trial_fastbootd_verified_epoch" 0 0 0
      trial_state=fastbootd_verified
      "${fastboot_command[@]}" reboot bootloader
      wait_for_selected_device
      finish_verified_fastbootd_from_bootloader
      ;;
    fastbootd_verified:yes:unknown)
      check_fastbootd_a_only
      compare_fastbootd_sizes_to_receipt
      confirm_on_tty
      verify_trial_archive_inputs
      assert_single_selected_device
      verify_bound_preparation historical
      load_fastbootd_trial_receipt
      [[ "$trial_state" == fastbootd_verified ]] || \
        die "verified fastbootd receipt changed during continuation authorization"
      check_fastbootd_a_only
      compare_fastbootd_sizes_to_receipt
      "${fastboot_command[@]}" reboot bootloader
      wait_for_selected_device
      finish_verified_fastbootd_from_bootloader
      ;;
    fastbootd_verified:no:b|verified:no:b)
      preflight_preparation_in_bootloader historical
      confirm_on_tty
      verify_trial_archive_inputs
      assert_single_selected_device
      verify_bound_preparation historical
      load_fastbootd_trial_receipt
      [[ "$trial_state" =~ ^(fastbootd_verified|verified)$ ]] || \
        die "trial receipt changed while waiting for finalization confirmation"
      preflight_preparation_in_bootloader historical
      finish_verified_fastbootd_from_bootloader
      ;;
    started:no:b)
      preflight_preparation_in_bootloader historical
      confirm_on_tty
      verify_trial_archive_inputs
      assert_single_selected_device
      verify_bound_preparation historical
      load_fastbootd_trial_receipt
      [[ "$trial_state" == started ]] || \
        die "ambiguous trial receipt changed during abort authorization"
      preflight_preparation_in_bootloader historical
      note "the one-shot command has no fastbootd proof; returning safely to stock A"
      trial_abort_started_epoch=$(date +%s)
      write_fastbootd_trial_receipt aborting_to_a 0 0 \
        "$trial_abort_started_epoch" 0
      trial_state=aborting_to_a
      "${fastboot_command[@]}" set_active a
      preflight_preparation_in_a_bootloader historical
      trial_abort_verified_epoch=$(date +%s)
      write_fastbootd_trial_receipt aborted_to_a 0 0 \
        "$trial_abort_started_epoch" "$trial_abort_verified_epoch"
      trial_state=aborted_to_a
      set_trial_consumption_authority
      cubs_consume_verified_stock_b_preparation
      note "archived the aborted one-shot evidence; the phone remains on stock A in bootloader"
      ;;
    aborting_to_a:no:a|aborting_to_a:no:b)
      if [[ "$current_slot" == a ]]; then
        preflight_preparation_in_a_bootloader historical
      else
        preflight_preparation_in_bootloader historical
      fi
      confirm_on_tty
      verify_trial_archive_inputs
      assert_single_selected_device
      verify_bound_preparation historical
      load_fastbootd_trial_receipt
      [[ "$trial_state" == aborting_to_a ]] || \
        die "abort-to-A receipt changed while waiting for continuation confirmation"
      current_slot=$(fastboot_value current-slot)
      if [[ "$current_slot" == b ]]; then
        preflight_preparation_in_bootloader historical
        "${fastboot_command[@]}" set_active a
      elif [[ "$current_slot" != a ]]; then
        die "abort-to-A continuation found an unexpected current slot"
      fi
      preflight_preparation_in_a_bootloader historical
      trial_abort_verified_epoch=$(date +%s)
      write_fastbootd_trial_receipt aborted_to_a 0 0 \
        "$trial_abort_started_epoch" "$trial_abort_verified_epoch"
      trial_state=aborted_to_a
      set_trial_consumption_authority
      cubs_consume_verified_stock_b_preparation
      note "finished and archived the interrupted abort-to-A transaction"
      ;;
    aborted_to_a:no:a)
      preflight_preparation_in_a_bootloader historical
      confirm_on_tty
      verify_trial_archive_inputs
      assert_single_selected_device
      verify_bound_preparation historical
      load_fastbootd_trial_receipt
      [[ "$trial_state" == aborted_to_a ]] || \
        die "completed abort-to-A receipt changed while waiting for confirmation"
      preflight_preparation_in_a_bootloader historical
      set_trial_consumption_authority
      cubs_consume_verified_stock_b_preparation
      note "archived the completed abort-to-A evidence; stock A remains selected"
      ;;
    *) die "trial receipt and current fastboot mode are inconsistent" ;;
  esac
}

case "$action" in
  start) start_trial ;;
  resume-finalize) resume_or_finalize_trial ;;
esac
