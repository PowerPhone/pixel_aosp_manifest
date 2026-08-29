#!/usr/bin/env bash
# shellcheck disable=SC2034

# Private host-side evidence joining an exact stock-B Android verification to
# the fastboot transaction that consumes its physical recovery lifeboat. This
# library is sourced by project scripts; the portable flash runner contains its
# own deliberately standalone verifier for the same exact schema.

# shellcheck source=../../config/recovery.env disable=SC1091,SC2154
source "$project_root/config/recovery.env"

cubs_firmware_partitions=(
  abl bl31 cap cpm dbc dbl
  dram_init_0 dram_init_1 dram_init_2 dram_init_3
  dram_init_4 dram_init_5 dram_init_6 dram_init_7
  dram_init_8 dram_init_9 dram_init_10 dram_init_11
  dram_phy gc gdmc gsa_bl1 gsa_fw tzsw modem
)
cubs_boot_lifeboat_partitions=(
  boot init_boot dtbo vendor_boot vendor_kernel_boot pvmfw
  vbmeta_system vbmeta_vendor vbmeta
)
cubs_preserved_b_partitions=(
  "${cubs_firmware_partitions[@]}"
  "${cubs_boot_lifeboat_partitions[@]}"
)

cubs_recovery_state_dir=${CUBS_RECOVERY_STATE_DIR:-"$project_root/.cache/recovery-anchor"}
cubs_recovery_state_dir=$(realpath -m -- "$cubs_recovery_state_dir")
cubs_recovery_lineage="$cubs_recovery_state_dir/lifeboat-lineage"
cubs_recovery_handoff="$cubs_recovery_state_dir/flash-handoff"
cubs_recovery_lock_file="$cubs_recovery_state_dir/lock"
cubs_sideload_preflight="$cubs_recovery_state_dir/sideload-preflight"
cubs_stock_a_physical_b_preflight="$cubs_recovery_state_dir/stock-a-physical-b-preflight"
# The exact terminal v6 restore receipt is moved here, never copied.  Presence
# of this file is the durable one-shot claim used by preflight-v3.
cubs_stock_a_baseline_evidence="$cubs_recovery_state_dir/stock-a-baseline-evidence"
# Retain the old pathname only as a conflict detector.  No current policy
# grants authority to Android/two-slot-lpdump preflights.
cubs_stock_a_lpdump_evidence="$cubs_recovery_state_dir/stock-a-complete-lpdump"
cubs_stock_b_preparation_receipt="$cubs_recovery_state_dir/stock-b-preparation-receipt"
cubs_stock_b_source_payload_manifest="$cubs_recovery_state_dir/stock-b-source-payload-manifest"
cubs_stock_b_fastbootd_trial_receipt="$cubs_recovery_state_dir/stock-b-fastbootd-trial-receipt"
cubs_stock_b_consumption_transaction="$cubs_recovery_state_dir/stock-b-consumption-transaction"
cubs_slot_a_flash_transaction="$cubs_recovery_state_dir/slot-a-flash-transaction"
cubs_runtime_boot_attestation="$cubs_recovery_state_dir/runtime-boot-attestation"
cubs_flash_retirement_transaction="$cubs_recovery_state_dir/flash-retirement-transaction"
cubs_stock_restore_transaction="$cubs_recovery_state_dir/stock-restore-transaction"
cubs_finalized_stock_restore_source="$cubs_recovery_state_dir/consumed/stock-restore-${CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID}-${CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256}"

cubs_prepare_recovery_state_dir() {
  assert_inside_project "$cubs_recovery_state_dir"
  [[ ! -L "$project_root/.cache" ]] || \
    die "recovery state parent must not be a symbolic link"
  [[ ! -L "$cubs_recovery_state_dir" ]] || \
    die "recovery state directory must not be a symbolic link"
  umask 077
  mkdir -p "$cubs_recovery_state_dir"
  chmod 0700 "$cubs_recovery_state_dir"
  [[ -d "$cubs_recovery_state_dir" && ! -L "$cubs_recovery_state_dir" ]] || \
    die "recovery state directory is unsafe"
}

cubs_lock_recovery_state() {
  cubs_prepare_recovery_state_dir
  [[ ! -L "$cubs_recovery_lock_file" ]] || \
    die "recovery-state lock must not be a symbolic link"
  exec {cubs_recovery_lock_fd}>"$cubs_recovery_lock_file"
  chmod 0600 "$cubs_recovery_lock_file"
  [[ -f "$cubs_recovery_lock_file" && ! -L "$cubs_recovery_lock_file" ]] || \
    die "recovery-state lock is unsafe"
  flock -n "$cubs_recovery_lock_fd" || \
    die "another recovery or flash transaction owns the recovery-state lock"
}

cubs_private_file() {
  local path=$1 mode owner links
  [[ -f "$path" && ! -L "$path" ]] || \
    die "private recovery state is missing or unsafe: $path"
  mode=$(stat -c '%a' "$path")
  owner=$(stat -c '%u' "$path")
  links=$(stat -c '%h' "$path")
  [[ "$mode" == 600 && "$owner" == "$EUID" && "$links" == 1 ]] || \
    die "private recovery state has unsafe ownership, mode, or link count: $path"
}

cubs_private_dir() {
  local path=$1 mode owner
  [[ -d "$path" && ! -L "$path" ]] || \
    die "private recovery directory is missing or unsafe: $path"
  mode=$(stat -c '%a' "$path")
  owner=$(stat -c '%u' "$path")
  [[ "$mode" == 700 && "$owner" == "$EUID" ]] || \
    die "private recovery directory has unsafe ownership or mode: $path"
}

cubs_random_anchor_id() {
  local value
  value=$(openssl rand -hex 16)
  [[ "$value" =~ ^[0-9a-f]{32}$ ]] || die "unable to generate recovery anchor ID"
  printf '%s\n' "$value"
}

cubs_serial_binding() {
  local anchor_id=$1 serial=$2 digest
  [[ "$anchor_id" =~ ^[0-9a-f]{32}$ && -n "$serial" ]] || \
    die "invalid recovery serial-binding input"
  digest=$(printf '%s\0%s' "$anchor_id" "$serial" | sha256sum)
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "unable to bind recovery transport"
  printf '%s\n' "$digest"
}

cubs_normalize_partition_size() {
  local value=${1,,}
  [[ "$value" =~ ^(0x)?[0-9a-f]+$ && "$value" =~ [1-9a-f] ]] || \
    die "invalid or zero physical partition size"
  value=${value#0x}
  while [[ ${#value} -gt 1 && ${value:0:1} == 0 ]]; do
    value=${value:1}
  done
  printf '%s\n' "$value"
}

cubs_logical_partitions=(
  system system_dlkm system_ext product vendor vendor_dlkm
)
cubs_stock_a_logical_size_keys=()
for cubs_logical_partition in "${cubs_logical_partitions[@]}"; do
  cubs_stock_a_logical_size_keys+=("logical_${cubs_logical_partition}_a_size")
done
unset cubs_logical_partition

# Hash normalized expanded byte sizes in the one fixed literal-name order used
# by preflight-v3, preparation-v2, and trial-v4.
cubs_stock_a_logical_sizes_sha256() {
  local source_name=$1 partition key value normalized lines=
  local -n source=$source_name

  for partition in "${cubs_logical_partitions[@]}"; do
    key=${partition}_a
    value=${source[$key]:-}
    normalized=$(cubs_normalize_partition_size "$value")
    [[ "$value" == "$normalized" ]] || \
      die "stock-A logical size is not canonical lowercase hexadecimal: $key"
    (( (16#$normalized) % 4096 == 0 )) || \
      die "stock-A logical size is not 4096-byte aligned: $key"
    lines+="$key=$normalized"$'\n'
  done
  printf '%s' "$lines" | sha256sum | awk '{print $1}'
}

# The caller supplies fastboot_value(). The fixed order and normalized values
# make this digest stable across harmless fastboot hexadecimal formatting.
cubs_physical_slot_sizes_sha256() {
  local slot=$1 partition size digest lines=
  [[ "$slot" =~ ^(a|b)$ ]] || die "invalid physical-size digest slot"
  for partition in "${cubs_preserved_b_partitions[@]}"; do
    size=$(cubs_normalize_partition_size \
      "$(fastboot_value "partition-size:${partition}_$slot")")
    lines+="${partition}_$slot=${size}"$'\n'
  done
  digest=$(printf '%s' "$lines" | sha256sum)
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || \
    die "unable to hash physical slot-$slot partition sizes"
  printf '%s\n' "$digest"
}

cubs_physical_b_sizes_sha256() {
  cubs_physical_slot_sizes_sha256 b
}

cubs_load_exact_kv() {
  local path=$1 destination_name=$2
  shift 2
  # shellcheck disable=SC2178 # destination is intentionally an associative-array nameref.
  local -n destination=$destination_name
  local key value extra allowed expected_count=0 count=0
  local -A expected=()

  destination=()
  for allowed in "$@"; do
    expected["$allowed"]=1
    ((expected_count += 1))
  done
  while IFS='=' read -r key value extra; do
    [[ -n "$key" && -n "$value" && -z "${extra:-}" ]] || \
      die "malformed private recovery state: $path"
    [[ -n "${expected[$key]+present}" ]] || \
      die "unknown key in private recovery state: $key"
    [[ -z "${destination[$key]+present}" ]] || \
      die "duplicate key in private recovery state: $key"
    destination["$key"]=$value
    ((count += 1))
  done <"$path"
  (( count == expected_count )) || \
    die "private recovery state does not match its exact schema: $path"
  for allowed in "$@"; do
    [[ -n "${destination[$allowed]+present}" ]] || \
      die "private recovery state omits $allowed"
  done
}

cubs_verify_finalized_stock_restore_receipt() {
  local path=$1 serial=$2 actual_binding actual_sha created now
  local -A receipt=()

  cubs_private_file "$path"
  actual_sha=$(sha256sum "$path" | awk '{print $1}')
  [[ "$actual_sha" == "$CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256" ]] || \
    die "finalized stock-restore baseline differs from its one-shot pin"
  cubs_load_exact_kv "$path" receipt \
    schema state created_epoch transaction_id serial_binding_sha256 device \
    stock_build_id factory_sha256 physical_b_sizes_sha256 lineage_sha256 \
    handoff_sha256 stock_b_source stock_b_provenance_sha256 \
    adopted_flash_transaction_sha256 adopted_flash_serial_binding_sha256 \
    adopted_runtime_attestation_sha256 recovery_policy_sha256
  [[ "${receipt[schema]}" == cubs-stock-restore-v2 && \
     "${receipt[state]}" == retiring_evidence && \
     "${receipt[created_epoch]}" =~ ^[1-9][0-9]{0,17}$ && \
     "${receipt[transaction_id]}" == \
       "$CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID" && \
     "${receipt[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[device]}" == "$DEVICE_CODENAME" && \
     "${receipt[stock_build_id]}" == "$STOCK_BUILD_ID" && \
     "${receipt[factory_sha256]}" == "$FACTORY_IMAGE_SHA256" && \
     "${receipt[physical_b_sizes_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[lineage_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[handoff_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[stock_b_source]}" == direct_factory_physical_b && \
     "${receipt[stock_b_provenance_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[adopted_flash_transaction_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[adopted_flash_serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "$CUBS_FINALIZED_STOCK_RESTORE_ADOPTED_RUNTIME_ATTESTATION_SHA256" =~ \
       ^(none|[0-9a-f]{64})$ && \
     "${receipt[adopted_runtime_attestation_sha256]}" == \
       "$CUBS_FINALIZED_STOCK_RESTORE_ADOPTED_RUNTIME_ATTESTATION_SHA256" && \
     "${receipt[recovery_policy_sha256]}" == \
       "$CUBS_FINALIZED_STOCK_RESTORE_RECOVERY_POLICY_SHA256" ]] || \
    die "finalized stock-restore receipt is not the exact pinned terminal bridge"
  created=${receipt[created_epoch]}
  now=$(date +%s)
  [[ "$now" =~ ^[1-9][0-9]{0,17}$ ]] || die "unable to read the host clock"
  (( 10#$now >= 10#$created )) || \
    die "finalized stock-restore receipt is dated in the future"
  actual_binding=$(cubs_serial_binding "${receipt[transaction_id]}" "$serial")
  [[ "$actual_binding" == "${receipt[serial_binding_sha256]}" ]] || \
    die "finalized stock-restore receipt belongs to another USB transport"

  cubs_verified_stock_a_baseline_sha256=$actual_sha
  cubs_verified_stock_a_baseline_transaction_id=${receipt[transaction_id]}
  cubs_verified_stock_a_baseline_serial_binding=${receipt[serial_binding_sha256]}
  cubs_verified_stock_a_baseline_physical_b_sizes_sha256=${receipt[physical_b_sizes_sha256]}
  cubs_verified_stock_a_baseline_created_epoch=$created
}

declare -A cubs_verified_stock_a_logical_sizes=()
cubs_verify_stock_a_physical_b_preflight() {
  local serial=$1 required_state=$2 freshness=${3:-fresh}
  local actual_binding baseline_sha bootloader_epoch created created_number
  local expires expires_number logical_digest now now_number partition
  local preflight_sha size_value
  local -A logical_sizes=() preflight=()

  [[ "$required_state" == bootloader_verified ]] || \
    die "v7 direct preparation accepts only bootloader-verified stock-A preflight-v3"
  [[ "$freshness" =~ ^(fresh|historical)$ ]] || \
    die "invalid stock-A preflight freshness requirement"
  cubs_private_file "$cubs_stock_a_physical_b_preflight"
  cubs_private_file "$cubs_stock_a_baseline_evidence"
  cubs_load_exact_kv "$cubs_stock_a_physical_b_preflight" preflight \
    schema state created_epoch expires_epoch bootloader_verified_epoch \
    preflight_id serial_binding_sha256 device stock_build_id \
    stock_fingerprint_sha256 factory_sha256 full_ota_sha256 source_slot \
    baseline_kind baseline_transaction_id baseline_evidence_sha256 \
    stock_a_logical_sizes_sha256 "${cubs_stock_a_logical_size_keys[@]}" \
    preparation_policy_sha256
  [[ "${preflight[schema]}" == cubs-stock-a-physical-b-preflight-v3 && \
     "${preflight[state]}" == bootloader_verified && \
     "${preflight[preflight_id]}" =~ ^[0-9a-f]{32}$ && \
     "${preflight[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${preflight[device]}" == "$DEVICE_CODENAME" && \
     "${preflight[stock_build_id]}" == "$STOCK_BUILD_ID" && \
     "${preflight[stock_fingerprint_sha256]}" == \
       "$CUBS_STOCK_FINGERPRINT_SHA256" && \
     "${preflight[factory_sha256]}" == "$FACTORY_IMAGE_SHA256" && \
     "${preflight[full_ota_sha256]}" == "$FULL_OTA_SHA256" && \
     "${preflight[source_slot]}" == a && \
     "${preflight[baseline_kind]}" == finalized_stock_restore_v2 && \
     "${preflight[baseline_transaction_id]}" == \
       "$CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID" && \
     "${preflight[baseline_evidence_sha256]}" == \
       "$CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256" && \
     "${preflight[stock_a_logical_sizes_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${preflight[preparation_policy_sha256]}" == \
       "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256" ]] || \
    die "stock-A physical-B preflight does not match exact v7 bridge policy"

  created=${preflight[created_epoch]}
  expires=${preflight[expires_epoch]}
  bootloader_epoch=${preflight[bootloader_verified_epoch]}
  [[ "$created" =~ ^[1-9][0-9]{0,17}$ && \
     "$expires" =~ ^[1-9][0-9]{0,17}$ && \
     "$bootloader_epoch" =~ ^[1-9][0-9]{0,17}$ ]] || \
    die "stock-A physical-B preflight has malformed timestamps"
  created_number=$((10#$created))
  expires_number=$((10#$expires))
  now=$(date +%s)
  [[ "$now" =~ ^[1-9][0-9]{0,17}$ ]] || die "unable to read the host clock"
  now_number=$((10#$now))
  (( expires_number == \
       created_number + CUBS_STOCK_A_PHYSICAL_B_PREFLIGHT_SECONDS && \
     10#$bootloader_epoch >= created_number && \
     10#$bootloader_epoch <= expires_number && \
     10#$bootloader_epoch <= now_number && now_number >= created_number )) || \
    die "stock-A physical-B preflight has inconsistent timestamps"
  if [[ "$freshness" == fresh ]]; then
    (( now_number <= expires_number )) || \
      die "stock-A physical-B preflight is not fresh"
  fi
  actual_binding=$(cubs_serial_binding "${preflight[preflight_id]}" "$serial")
  [[ "$actual_binding" == "${preflight[serial_binding_sha256]}" ]] || \
    die "stock-A physical-B preflight belongs to another USB transport"

  cubs_verify_finalized_stock_restore_receipt \
    "$cubs_stock_a_baseline_evidence" "$serial"
  baseline_sha=$(sha256sum "$cubs_stock_a_baseline_evidence" | awk '{print $1}')
  [[ "$baseline_sha" == "${preflight[baseline_evidence_sha256]}" && \
     "$cubs_verified_stock_a_baseline_transaction_id" == \
       "${preflight[baseline_transaction_id]}" ]] || \
    die "claimed finalized-restore baseline does not match preflight-v3"

  for partition in "${cubs_logical_partitions[@]}"; do
    size_value=${preflight[logical_${partition}_a_size]}
    logical_sizes["${partition}_a"]=$size_value
  done
  logical_digest=$(cubs_stock_a_logical_sizes_sha256 logical_sizes)
  [[ "$logical_digest" == "${preflight[stock_a_logical_sizes_sha256]}" ]] || \
    die "stock-A expanded logical sizes do not match preflight-v3"

  preflight_sha=$(sha256sum "$cubs_stock_a_physical_b_preflight" | awk '{print $1}')
  cubs_verified_stock_a_preflight_id=${preflight[preflight_id]}
  cubs_verified_stock_a_serial_binding=${preflight[serial_binding_sha256]}
  cubs_verified_stock_a_preflight_sha256=$preflight_sha
  cubs_verified_stock_a_logical_sizes_sha256=$logical_digest
  cubs_verified_stock_a_logical_sizes=()
  for partition in "${cubs_logical_partitions[@]}"; do
    cubs_verified_stock_a_logical_sizes["${partition}_a"]=${logical_sizes[${partition}_a]}
  done
  cubs_verified_stock_a_created_epoch=$created
  cubs_verified_stock_a_expires_epoch=$expires
  cubs_verified_stock_a_bootloader_epoch=$bootloader_epoch
  cubs_verified_stock_a_preparation_policy_sha256=${preflight[preparation_policy_sha256]}
}

cubs_require_stock_a_preflight_slack() {
  local required_seconds=$1 now remaining
  [[ "$required_seconds" =~ ^[1-9][0-9]*$ && \
     "${cubs_verified_stock_a_expires_epoch:-}" =~ ^[1-9][0-9]{0,17}$ ]] || \
    die "verified stock-A preflight freshness is unavailable"
  now=$(date +%s)
  remaining=$((10#$cubs_verified_stock_a_expires_epoch - 10#$now))
  (( remaining >= required_seconds )) || \
    die "stock-A preflight needs at least $required_seconds seconds of freshness; $remaining remain"
}

# Validate the direct physical-B factory-preparation evidence while the phone
# remains on the selected B boot-control slot in bootloader fastboot. This
# evidence authorizes only the separately gated fastbootd lifeboat trial; the
# divergent logical B metadata must never be used to boot Android B. No raw
# serial is stored: receipts use random-ID salted transport bindings.
_cubs_verify_stock_b_preparation() {
  local serial=$1 expected_bootloader=$2 expected_baseband=$3
  local required_state=${4:-ready}
  local freshness=${5:-fresh}
  local actual_binding actual_inner_sha authorization authorization_number
  local created created_number current_manifest_sha expires expires_number
  local index line manifest_sha now now_number receipt_sha
  local stock_inner
  local sha size filename extra
  local -a manifest_lines=()
  local -A receipt=()

  [[ "$required_state" =~ ^(activation_pending|ready)$ ]] || \
    die "invalid stock-B preparation receipt state requirement"
  [[ "$freshness" =~ ^(fresh|historical)$ ]] || \
    die "invalid stock-B preparation freshness requirement"
  cubs_verify_stock_a_physical_b_preflight \
    "$serial" bootloader_verified historical
  cubs_private_file "$cubs_stock_b_preparation_receipt"
  cubs_private_file "$cubs_stock_b_source_payload_manifest"
  cubs_load_exact_kv "$cubs_stock_b_preparation_receipt" receipt \
    schema state authorization_epoch created_epoch expires_epoch preparation_id \
    serial_binding_sha256 stock_a_preflight_sha256 \
    stock_a_baseline_evidence_sha256 stock_a_logical_sizes_sha256 \
    device stock_build_id factory_filename \
    factory_sha256 inner_image_filename inner_image_sha256 \
    source_payload_manifest_sha256 acknowledged_flash_count \
    vendor_boot_b_fetch_sha256 android_b_booted \
    source_slot target_slot bootloader baseband \
    physical_a_sizes_sha256 physical_b_sizes_sha256 \
    preparation_policy_sha256 retired_sideload_preflight_sha256

  [[ "${receipt[schema]}" == cubs-stock-b-preparation-v2 && \
     "${receipt[state]}" == "$required_state" && \
     "${receipt[authorization_epoch]}" =~ ^[1-9][0-9]{0,17}$ && \
     "${receipt[preparation_id]}" =~ ^[0-9a-f]{32}$ && \
     "${receipt[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[stock_a_preflight_sha256]}" == \
       "$cubs_verified_stock_a_preflight_sha256" && \
     "${receipt[stock_a_baseline_evidence_sha256]}" == \
       "$cubs_verified_stock_a_baseline_sha256" && \
     "${receipt[stock_a_logical_sizes_sha256]}" == \
       "$cubs_verified_stock_a_logical_sizes_sha256" && \
     "${receipt[device]}" == "$DEVICE_CODENAME" && \
     "${receipt[stock_build_id]}" == "$STOCK_BUILD_ID" && \
     "${receipt[factory_filename]}" == "$FACTORY_IMAGE_FILENAME" && \
     "${receipt[factory_sha256]}" == "$FACTORY_IMAGE_SHA256" && \
     "${receipt[inner_image_filename]}" == \
       "image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip" && \
     "${receipt[inner_image_sha256]}" == "$CUBS_STOCK_INNER_IMAGE_SHA256" && \
     "${receipt[source_payload_manifest_sha256]}" == \
       "$CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256" && \
     "${receipt[acknowledged_flash_count]}" == 34 && \
     "${receipt[vendor_boot_b_fetch_sha256]}" == \
       "$CUBS_STOCK_VENDOR_BOOT_SHA256" && \
     "${receipt[android_b_booted]}" == no && \
     "${receipt[source_slot]}" == a && \
     "${receipt[target_slot]}" == b && \
     "${receipt[bootloader]}" == "$expected_bootloader" && \
     "${receipt[baseband]}" == "$expected_baseband" && \
     "${receipt[physical_a_sizes_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[physical_b_sizes_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[preparation_policy_sha256]}" == \
       "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256" && \
     "${receipt[retired_sideload_preflight_sha256]}" =~ \
       ^(none|[0-9a-f]{64})$ ]] || \
    die "stock-B preparation receipt does not match this exact release policy"

  authorization=${receipt[authorization_epoch]}
  created=${receipt[created_epoch]}
  expires=${receipt[expires_epoch]}
  [[ "$created" =~ ^[1-9][0-9]{0,17}$ && \
     "$expires" =~ ^[1-9][0-9]{0,17}$ ]] || \
    die "stock-B preparation receipt has malformed timestamps"
  created_number=$((10#$created))
  authorization_number=$((10#$authorization))
  expires_number=$((10#$expires))
  (( expires_number == \
     created_number + CUBS_STOCK_B_PREPARATION_RECEIPT_SECONDS )) || \
    die "stock-B preparation receipt has an invalid freshness interval"
  now=$(date +%s)
  [[ "$now" =~ ^[1-9][0-9]{0,17}$ ]] || die "unable to read the host clock"
  now_number=$((10#$now))
  (( now_number >= created_number )) || \
    die "stock-B preparation receipt is dated in the future"
  if [[ "$freshness" == fresh ]]; then
    (( now_number <= expires_number )) || \
      die "stock-B preparation receipt is not fresh"
  fi
  (( authorization_number >= 10#$cubs_verified_stock_a_bootloader_epoch && \
     authorization_number <= 10#$cubs_verified_stock_a_expires_epoch && \
     created_number >= authorization_number )) || \
    die "stock-B preparation did not begin within its bound stock-A authorization"

  actual_binding=$(cubs_serial_binding \
    "${receipt[preparation_id]}" "$serial")
  [[ "$actual_binding" == "${receipt[serial_binding_sha256]}" ]] || \
    die "stock-B preparation receipt belongs to another USB transport"

  stock_inner="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
  cubs_private_file "$cubs_stock_a_physical_b_preflight"
  require_file "$stock_inner"
  [[ ! -L "$stock_inner" ]] || die "nested stock image ZIP is unsafe"
  actual_inner_sha=$(sha256sum "$stock_inner" | awk '{print $1}')
  [[ "$actual_inner_sha" == "${receipt[inner_image_sha256]}" ]] || \
    die "stock-B preparation receipt does not match the pinned nested image ZIP"

  mapfile -t manifest_lines <"$cubs_stock_b_source_payload_manifest"
  (( ${#manifest_lines[@]} == ${#cubs_preserved_b_partitions[@]} )) || \
    die "private stock-B source-payload manifest has the wrong cardinality"
  for ((index = 0; index < ${#cubs_preserved_b_partitions[@]}; index += 1)); do
    line=${manifest_lines[$index]}
    read -r sha size filename extra <<<"$line"
    [[ "$sha" =~ ^[0-9a-f]{64}$ && "$size" =~ ^[1-9][0-9]*$ && \
       "$filename" == "${cubs_preserved_b_partitions[$index]}.img" && \
       -z "${extra:-}" ]] || \
      die "private stock-B source-payload manifest is malformed or out of order"
    if [[ "${cubs_preserved_b_partitions[$index]}" == vendor_boot ]]; then
      [[ "$sha" == "$CUBS_STOCK_VENDOR_BOOT_SHA256" && \
         "$sha" == "${receipt[vendor_boot_b_fetch_sha256]}" ]] || \
        die "vendor_boot source and full fetched-partition digests differ"
    fi
  done
  current_manifest_sha=$(sha256sum "$cubs_stock_b_source_payload_manifest")
  current_manifest_sha=${current_manifest_sha%% *}
  manifest_sha=${receipt[source_payload_manifest_sha256]}
  [[ "$current_manifest_sha" == "$manifest_sha" ]] || \
    die "private stock-B source-payload manifest does not match its receipt"

  receipt_sha=$(sha256sum "$cubs_stock_b_preparation_receipt")
  cubs_verified_stock_b_preparation_id=${receipt[preparation_id]}
  cubs_verified_stock_b_serial_binding=${receipt[serial_binding_sha256]}
  cubs_verified_stock_b_receipt_sha256=${receipt_sha%% *}
  cubs_verified_stock_b_source_payload_manifest_sha256=$manifest_sha
  cubs_verified_stock_b_vendor_boot_fetch_sha256=${receipt[vendor_boot_b_fetch_sha256]}
  cubs_verified_stock_b_a_sizes_sha256=${receipt[physical_a_sizes_sha256]}
  cubs_verified_stock_b_b_sizes_sha256=${receipt[physical_b_sizes_sha256]}
  cubs_verified_stock_b_created_epoch=$created
  cubs_verified_stock_b_expires_epoch=$expires
  cubs_verified_stock_b_authorization_epoch=$authorization
  cubs_verified_stock_b_preparation_policy_sha256=${receipt[preparation_policy_sha256]}
  cubs_verified_stock_b_baseline_sha256=${receipt[stock_a_baseline_evidence_sha256]}
  cubs_verified_stock_b_logical_sizes_sha256=${receipt[stock_a_logical_sizes_sha256]}
}

cubs_verify_stock_b_preparation() {
  local serial=$1 expected_bootloader=$2 expected_baseband=$3
  local required_state=${4:-ready} freshness=${5:-fresh}
  _cubs_verify_stock_b_preparation \
    "$serial" "$expected_bootloader" "$expected_baseband" \
    "$required_state" "$freshness"
}

cubs_require_stock_b_preparation_slack() {
  local required_seconds=$1 now remaining
  [[ "$required_seconds" =~ ^[1-9][0-9]*$ && \
     "${cubs_verified_stock_b_expires_epoch:-}" =~ ^[1-9][0-9]{0,17}$ ]] || \
    die "verified stock-B preparation freshness is unavailable"
  now=$(date +%s)
  remaining=$((10#$cubs_verified_stock_b_expires_epoch - 10#$now))
  (( remaining >= required_seconds )) || \
    die "stock-B receipt needs at least $required_seconds seconds of freshness; $remaining remain"
}

cubs_detect_and_verify_stock_b_preparation() {
  local serial=$1 expected_bootloader=$2 expected_baseband=$3
  if [[ ! -e "$cubs_stock_b_preparation_receipt" && \
        ! -L "$cubs_stock_b_preparation_receipt" && \
        ! -e "$cubs_stock_b_source_payload_manifest" && \
        ! -L "$cubs_stock_b_source_payload_manifest" ]]; then
    return 1
  fi
  [[ -e "$cubs_stock_b_preparation_receipt" && \
     ! -L "$cubs_stock_b_preparation_receipt" && \
     -e "$cubs_stock_b_source_payload_manifest" && \
     ! -L "$cubs_stock_b_source_payload_manifest" ]] || \
    die "stock-B preparation receipt and source-payload manifest are incomplete"
  cubs_verify_stock_b_preparation \
    "$serial" "$expected_bootloader" "$expected_baseband"
}

cubs_require_no_stock_b_preparation() {
  [[ ! -e "$cubs_stock_a_physical_b_preflight" && \
     ! -L "$cubs_stock_a_physical_b_preflight" && \
     ! -e "$cubs_stock_a_baseline_evidence" && \
     ! -L "$cubs_stock_a_baseline_evidence" && \
     ! -e "$cubs_stock_a_lpdump_evidence" && \
     ! -L "$cubs_stock_a_lpdump_evidence" && \
     ! -e "$cubs_stock_b_preparation_receipt" && \
     ! -L "$cubs_stock_b_preparation_receipt" && \
     ! -e "$cubs_stock_b_source_payload_manifest" && \
     ! -L "$cubs_stock_b_source_payload_manifest" && \
     ! -e "$cubs_stock_b_fastbootd_trial_receipt" && \
     ! -L "$cubs_stock_b_fastbootd_trial_receipt" && \
     ! -e "$cubs_stock_b_consumption_transaction" && \
     ! -L "$cubs_stock_b_consumption_transaction" && \
     ! -e "$cubs_slot_a_flash_transaction" && \
     ! -L "$cubs_slot_a_flash_transaction" && \
     ! -e "$cubs_runtime_boot_attestation" && \
     ! -L "$cubs_runtime_boot_attestation" && \
     ! -e "$cubs_flash_retirement_transaction" && \
     ! -L "$cubs_flash_retirement_transaction" && \
     ! -e "$cubs_stock_restore_transaction" && \
     ! -L "$cubs_stock_restore_transaction" ]] || \
    die "direct physical-B evidence must be verified or recovered before another OTA workflow"
}

cubs_finish_pending_stock_b_consumption() {
  local consumed_dir destination destination_basename index marker_sha
  local dotglob_was_set=0 nullglob_was_set=0
  local source target temporary_dir
  local -a archive_entries archive_names expected_hashes sources targets
  local -A transaction=()

  if [[ ! -e "$cubs_stock_b_consumption_transaction" && \
        ! -L "$cubs_stock_b_consumption_transaction" ]]; then
    return 1
  fi
  cubs_private_file "$cubs_stock_b_consumption_transaction"
  cubs_load_exact_kv "$cubs_stock_b_consumption_transaction" transaction \
    schema preparation_id receipt_sha256 source_payload_manifest_sha256 \
    stock_a_preflight_sha256 stock_a_baseline_evidence_sha256 \
    stock_a_logical_sizes_sha256 \
    fastbootd_trial_receipt_sha256 destination_basename \
    source_preparation_policy_sha256 trial_policy_sha256
  destination_basename=${transaction[destination_basename]}
  [[ "${transaction[schema]}" == cubs-stock-b-consumption-v3 && \
     "${transaction[preparation_id]}" =~ ^[0-9a-f]{32}$ && \
     "${transaction[receipt_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${transaction[source_payload_manifest_sha256]}" == \
       "$CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256" && \
     "${transaction[stock_a_preflight_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${transaction[stock_a_baseline_evidence_sha256]}" == \
       "$CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256" && \
     "${transaction[stock_a_logical_sizes_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${transaction[fastbootd_trial_receipt_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "$destination_basename" == \
       "stock-b-${transaction[preparation_id]}-${transaction[receipt_sha256]}" && \
     "${transaction[source_preparation_policy_sha256]}" == \
       "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256" && \
     "${transaction[trial_policy_sha256]}" == \
       "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256" ]] || \
    die "pending stock-B evidence-consumption transaction is malformed"
  marker_sha=$(sha256sum "$cubs_stock_b_consumption_transaction" | awk '{print $1}')

  sources=(
    "$cubs_stock_a_baseline_evidence"
    "$cubs_stock_a_physical_b_preflight"
    "$cubs_stock_b_source_payload_manifest"
    "$cubs_stock_b_preparation_receipt"
    "$cubs_stock_b_fastbootd_trial_receipt"
  )
  archive_names=(
    stock-a-baseline-evidence
    stock-a-preflight
    source-payload-manifest
    receipt
    fastbootd-trial-receipt
  )
  expected_hashes=(
    "${transaction[stock_a_baseline_evidence_sha256]}"
    "${transaction[stock_a_preflight_sha256]}"
    "${transaction[source_payload_manifest_sha256]}"
    "${transaction[receipt_sha256]}"
    "${transaction[fastbootd_trial_receipt_sha256]}"
  )

  consumed_dir="$cubs_recovery_state_dir/consumed"
  [[ ! -L "$consumed_dir" ]] || die "consumed recovery directory is unsafe"
  mkdir -p "$consumed_dir"
  chmod 0700 "$consumed_dir"
  cubs_private_dir "$consumed_dir"
  destination="$consumed_dir/$destination_basename"
  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    temporary_dir=$(mktemp -d "$consumed_dir/.stock-b.XXXXXX")
    chmod 0700 "$temporary_dir"
    cubs_private_dir "$temporary_dir"
    for ((index = 0; index < ${#sources[@]}; index += 1)); do
      source=${sources[$index]}
      target="$temporary_dir/${archive_names[$index]}"
      cubs_private_file "$source"
      [[ $(sha256sum "$source" | awk '{print $1}') == \
           "${expected_hashes[$index]}" ]] || \
        die "active direct evidence differs from its consumption transaction"
      cp --reflink=auto --preserve=mode -- "$source" "$target"
      chmod 0600 "$target"
      cubs_private_file "$target"
      cmp -s "$source" "$target" || \
        die "copied direct physical-B evidence differs before publication"
    done
    mv -T -- "$temporary_dir" "$destination"
  fi
  cubs_private_dir "$destination"

  # A pre-existing destination is accepted only as the exact atomic archive
  # this transaction would have published.  Count dotfiles and every other
  # directory entry before deleting any active evidence; the five expected
  # private regular files below must be the complete directory contents.
  if shopt -q dotglob; then
    dotglob_was_set=1
  fi
  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s dotglob nullglob
  archive_entries=("$destination"/*)
  if (( dotglob_was_set == 0 )); then
    shopt -u dotglob
  fi
  if (( nullglob_was_set == 0 )); then
    shopt -u nullglob
  fi
  (( ${#archive_entries[@]} == ${#archive_names[@]} )) || \
    die "published direct physical-B archive has unexpected directory entries"
  targets=()
  for ((index = 0; index < ${#archive_names[@]}; index += 1)); do
    target="$destination/${archive_names[$index]}"
    cubs_private_file "$target"
    [[ $(sha256sum "$target" | awk '{print $1}') == \
         "${expected_hashes[$index]}" ]] || \
      die "published direct physical-B archive differs from its transaction"
    targets+=("$target")
  done

  # The directory publication above is atomic. The transaction marker is
  # removed last, so any crash during cleanup has an exact, idempotent resume
  # path and never leaves the archive as an unreferenced partial substitute.
  for ((index = 0; index < ${#sources[@]}; index += 1)); do
    source=${sources[$index]}
    target=${targets[$index]}
    if [[ -e "$source" || -L "$source" ]]; then
      cubs_private_file "$source"
      cmp -s "$source" "$target" || \
        die "active direct evidence differs from its published archive"
      rm -f -- "$source"
    fi
  done
  [[ $(sha256sum "$cubs_stock_b_consumption_transaction" | awk '{print $1}') == \
       "$marker_sha" ]] || \
    die "stock-B evidence-consumption transaction changed during cleanup"
  rm -f -- "$cubs_stock_b_consumption_transaction"
  cubs_completed_stock_b_consumption_destination=$destination
  return 0
}

cubs_consume_verified_stock_b_preparation() {
  local current_baseline_sha current_manifest_sha current_preflight_sha
  local current_receipt_sha destination_basename temporary trial_sha

  if [[ -e "$cubs_stock_b_consumption_transaction" || \
        -L "$cubs_stock_b_consumption_transaction" ]]; then
    cubs_finish_pending_stock_b_consumption
    return
  fi
  [[ "${cubs_verified_stock_b_preparation_id:-}" =~ ^[0-9a-f]{32}$ && \
     "${cubs_verified_stock_b_receipt_sha256:-}" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_stock_b_source_payload_manifest_sha256:-}" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_stock_a_preflight_sha256:-}" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_stock_a_baseline_sha256:-}" == \
       "$CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256" && \
     "${cubs_verified_stock_a_logical_sizes_sha256:-}" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_stock_b_preparation_policy_sha256:-}" == \
       "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256" && \
     "${cubs_verified_stock_b_trial_policy_sha256:-}" == \
       "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256" ]] || \
    die "verified stock-B preparation evidence is unavailable"
  cubs_private_file "$cubs_stock_a_physical_b_preflight"
  cubs_private_file "$cubs_stock_a_baseline_evidence"
  cubs_private_file "$cubs_stock_b_preparation_receipt"
  cubs_private_file "$cubs_stock_b_source_payload_manifest"
  cubs_private_file "$cubs_stock_b_fastbootd_trial_receipt"
  current_preflight_sha=$(sha256sum "$cubs_stock_a_physical_b_preflight" | awk '{print $1}')
  current_baseline_sha=$(sha256sum "$cubs_stock_a_baseline_evidence" | awk '{print $1}')
  current_receipt_sha=$(sha256sum "$cubs_stock_b_preparation_receipt" | awk '{print $1}')
  current_manifest_sha=$(sha256sum "$cubs_stock_b_source_payload_manifest" | awk '{print $1}')
  trial_sha=$(sha256sum "$cubs_stock_b_fastbootd_trial_receipt" | awk '{print $1}')
  [[ "$current_preflight_sha" == "$cubs_verified_stock_a_preflight_sha256" && \
     "$current_baseline_sha" == "$cubs_verified_stock_a_baseline_sha256" && \
     "$current_receipt_sha" == "$cubs_verified_stock_b_receipt_sha256" && \
     "$current_manifest_sha" == \
       "$cubs_verified_stock_b_source_payload_manifest_sha256" && \
     "$trial_sha" == "${cubs_verified_stock_b_trial_sha256:-}" ]] || \
    die "stock-B preparation evidence changed after verification"

  destination_basename="stock-b-${cubs_verified_stock_b_preparation_id}-${current_receipt_sha}"
  temporary=$(mktemp "$cubs_recovery_state_dir/.stock-b-consumption.XXXXXX")
  {
    printf 'schema=cubs-stock-b-consumption-v3\n'
    printf 'preparation_id=%s\n' "$cubs_verified_stock_b_preparation_id"
    printf 'receipt_sha256=%s\n' "$current_receipt_sha"
    printf 'source_payload_manifest_sha256=%s\n' "$current_manifest_sha"
    printf 'stock_a_preflight_sha256=%s\n' "$current_preflight_sha"
    printf 'stock_a_baseline_evidence_sha256=%s\n' "$current_baseline_sha"
    printf 'stock_a_logical_sizes_sha256=%s\n' \
      "$cubs_verified_stock_a_logical_sizes_sha256"
    printf 'fastbootd_trial_receipt_sha256=%s\n' "$trial_sha"
    printf 'destination_basename=%s\n' "$destination_basename"
    printf 'source_preparation_policy_sha256=%s\n' \
      "$cubs_verified_stock_b_preparation_policy_sha256"
    printf 'trial_policy_sha256=%s\n' \
      "$cubs_verified_stock_b_trial_policy_sha256"
  } >"$temporary"
  chmod 0600 "$temporary"
  [[ ! -e "$cubs_stock_b_consumption_transaction" && \
     ! -L "$cubs_stock_b_consumption_transaction" ]] || \
    die "stock-B evidence-consumption transaction appeared unexpectedly"
  mv -T -- "$temporary" "$cubs_stock_b_consumption_transaction"
  cubs_private_file "$cubs_stock_b_consumption_transaction"
  cubs_finish_pending_stock_b_consumption
}

cubs_verify_lifeboat_lineage() {
  local serial=$1 physical_sizes_sha256=$2 bootloader=$3 baseband=$4
  local actual_binding actual_sha
  local -A lineage=()

  # In lineage-v2 shared_super_layout_sha256 is intentionally a historical
  # factory-release topology pin.  For a direct v7 lifeboat, trial-v4 (bound as
  # stock_b_provenance_sha256) is the live A-only namespace proof.
  cubs_private_file "$cubs_recovery_lineage"
  cubs_load_exact_kv "$cubs_recovery_lineage" lineage \
    schema anchor_id created_epoch serial_binding_sha256 device stock_build_id \
    stock_fingerprint_sha256 factory_sha256 full_ota_sha256 bootloader baseband \
    ab_ota_partitions_sha256 shared_super_layout_sha256 \
    physical_b_sizes_sha256 stock_b_source stock_b_provenance_sha256 \
    physical_b_source_manifest_sha256 physical_b_vendor_boot_fetch_sha256 \
    recovery_policy_sha256
  [[ "${lineage[schema]}" == cubs-recovery-lineage-v2 && \
     "${lineage[anchor_id]}" =~ ^[0-9a-f]{32}$ && \
     "${lineage[created_epoch]}" =~ ^[0-9]+$ && \
     "${lineage[device]}" == "$DEVICE_CODENAME" && \
     "${lineage[stock_build_id]}" == "$STOCK_BUILD_ID" && \
     "${lineage[stock_fingerprint_sha256]}" == "$CUBS_STOCK_FINGERPRINT_SHA256" && \
     "${lineage[factory_sha256]}" == "$FACTORY_IMAGE_SHA256" && \
     "${lineage[full_ota_sha256]}" == "$FULL_OTA_SHA256" && \
     "${lineage[bootloader]}" == "$bootloader" && \
     "${lineage[baseband]}" == "$baseband" && \
     "${lineage[ab_ota_partitions_sha256]}" == "$CUBS_AB_OTA_PARTITIONS_SHA256" && \
     "${lineage[shared_super_layout_sha256]}" == "$CUBS_SHARED_SUPER_LAYOUT_SHA256" && \
     "${lineage[physical_b_sizes_sha256]}" == "$physical_sizes_sha256" && \
     "${lineage[recovery_policy_sha256]}" == "$CUBS_RECOVERY_POLICY_SHA256" ]] || \
    die "physical slot-B lifeboat no longer matches its verified lineage"
  case "${lineage[stock_b_source]}" in
    full_ota)
      [[ "${lineage[stock_b_provenance_sha256]}" == "$FULL_OTA_SHA256" && \
         "${lineage[physical_b_source_manifest_sha256]}" == none && \
         "${lineage[physical_b_vendor_boot_fetch_sha256]}" == none ]] || \
        die "full-OTA stock-B lineage has invalid source provenance"
      ;;
    direct_factory_physical_b)
      [[ "${lineage[stock_b_provenance_sha256]}" =~ ^[0-9a-f]{64}$ && \
         "${lineage[physical_b_source_manifest_sha256]}" == \
           "$CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256" && \
         "${lineage[physical_b_vendor_boot_fetch_sha256]}" == \
           "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || \
        die "direct-factory stock-B lineage has invalid source provenance"
      ;;
    *)
      die "unsupported stock-B lineage source"
      ;;
  esac
  actual_binding=$(cubs_serial_binding "${lineage[anchor_id]}" "$serial")
  [[ "$actual_binding" == "${lineage[serial_binding_sha256]}" ]] || \
    die "physical lifeboat belongs to another USB transport"
  actual_sha=$(sha256sum "$cubs_recovery_lineage")
  cubs_verified_anchor_id=${lineage[anchor_id]}
  cubs_verified_serial_binding=${lineage[serial_binding_sha256]}
  cubs_verified_lineage_sha256=${actual_sha%% *}
  cubs_verified_stock_b_source=${lineage[stock_b_source]}
  cubs_verified_stock_b_provenance_sha256=${lineage[stock_b_provenance_sha256]}
  cubs_verified_physical_b_source_manifest_sha256=${lineage[physical_b_source_manifest_sha256]}
  cubs_verified_physical_b_vendor_boot_fetch_sha256=${lineage[physical_b_vendor_boot_fetch_sha256]}
}

cubs_require_verified_lineage_b_success() {
  local value=$1
  case "${cubs_verified_stock_b_source:-}" in
    full_ota)
      [[ "$value" == yes ]] || \
        die "full-OTA stock B is not marked successful"
      ;;
    direct_factory_physical_b)
      [[ "$value" =~ ^(yes|no)$ ]] || \
        die "direct physical-B lifeboat has an unreadable successful flag"
      ;;
    *)
      die "verified stock-B lineage source is unavailable"
      ;;
  esac
}

# Recovery must remain possible after a development flash fails, including
# after the normal resume window. Prove the active ready/claimed receipt is the
# exact handoff for the already verified lineage, but do not impose freshness:
# expiration revokes flashing/resume authority, not emergency stock restore.
cubs_verify_lifeboat_handoff_for_recovery() {
  local physical_sizes_sha256=$1 actual_sha created expires claimed
  local -A handoff=()
  [[ "${cubs_verified_anchor_id:-}" =~ ^[0-9a-f]{32}$ && \
     "${cubs_verified_serial_binding:-}" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_lineage_sha256:-}" =~ ^[0-9a-f]{64}$ ]] || \
    die "verified lifeboat lineage is unavailable for stock recovery"
  cubs_private_file "$cubs_recovery_handoff"
  cubs_load_exact_kv "$cubs_recovery_handoff" handoff \
    schema state handoff_kind created_epoch expires_epoch claimed_epoch \
    anchor_id serial_binding_sha256 lineage_sha256 physical_b_sizes_sha256 \
    recovery_policy_sha256 bundle_kind bundle_manifest_sha256
  [[ "${handoff[schema]}" == cubs-recovery-handoff-v2 && \
     "${handoff[handoff_kind]}" =~ ^(stock_b_anchor|physical_b_lifeboat)$ && \
     "${handoff[anchor_id]}" == "$cubs_verified_anchor_id" && \
     "${handoff[serial_binding_sha256]}" == "$cubs_verified_serial_binding" && \
     "${handoff[lineage_sha256]}" == "$cubs_verified_lineage_sha256" && \
     "${handoff[physical_b_sizes_sha256]}" == "$physical_sizes_sha256" && \
     "${handoff[recovery_policy_sha256]}" == "$CUBS_RECOVERY_POLICY_SHA256" ]] || \
    die "active recovery handoff does not match the verified lifeboat lineage"
  if [[ "$cubs_verified_stock_b_source" == direct_factory_physical_b && \
        "${handoff[handoff_kind]}" != physical_b_lifeboat ]]; then
    die "direct physical-B lineage has the wrong recovery handoff kind"
  fi
  created=${handoff[created_epoch]}
  expires=${handoff[expires_epoch]}
  claimed=${handoff[claimed_epoch]}
  [[ "$created" =~ ^[1-9][0-9]{0,17}$ && \
     "$expires" =~ ^[1-9][0-9]{0,17}$ && \
     "$claimed" =~ ^[0-9]{1,18}$ && \
     $((10#$expires)) -eq \
       $((10#$created + CUBS_RECOVERY_HANDOFF_READY_SECONDS)) ]] || \
    die "active recovery handoff has malformed timestamps"
  case "${handoff[state]}" in
    ready)
      [[ "$claimed" == 0 && "${handoff[bundle_kind]}" == none && \
         "${handoff[bundle_manifest_sha256]}" == none ]] || \
        die "ready recovery handoff is malformed"
      ;;
    claimed)
      [[ "$claimed" =~ ^[1-9][0-9]{0,17}$ && \
         $((10#$claimed)) -ge $((10#$created)) && \
         $((10#$claimed)) -le $((10#$expires)) && \
         "${handoff[bundle_kind]}" =~ ^(cubs|gsi)$ && \
         "${handoff[bundle_manifest_sha256]}" =~ ^[0-9a-f]{64}$ ]] || \
        die "claimed recovery handoff is malformed"
      ;;
    *) die "unsupported recovery handoff state for stock restore" ;;
  esac
  actual_sha=$(sha256sum "$cubs_recovery_handoff")
  cubs_verified_recovery_handoff_sha256=${actual_sha%% *}
}

cubs_write_lifeboat_handoff() {
  local physical_sizes_sha256=$1 created expires temporary
  [[ "$physical_sizes_sha256" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_anchor_id:-}" =~ ^[0-9a-f]{32}$ && \
     "${cubs_verified_lineage_sha256:-}" =~ ^[0-9a-f]{64}$ ]] || \
    die "verified lineage is unavailable for a lifeboat handoff"
  [[ ! -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]] || \
    die "an active recovery handoff already exists"
  created=$(date +%s)
  expires=$((created + CUBS_RECOVERY_HANDOFF_READY_SECONDS))
  temporary=$(mktemp "$cubs_recovery_state_dir/.handoff.XXXXXX")
  {
    printf 'schema=cubs-recovery-handoff-v2\n'
    printf 'state=ready\n'
    printf 'handoff_kind=physical_b_lifeboat\n'
    printf 'created_epoch=%s\n' "$created"
    printf 'expires_epoch=%s\n' "$expires"
    printf 'claimed_epoch=0\n'
    printf 'anchor_id=%s\n' "$cubs_verified_anchor_id"
    printf 'serial_binding_sha256=%s\n' "$cubs_verified_serial_binding"
    printf 'lineage_sha256=%s\n' "$cubs_verified_lineage_sha256"
    printf 'physical_b_sizes_sha256=%s\n' "$physical_sizes_sha256"
    printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
    printf 'bundle_kind=none\n'
    printf 'bundle_manifest_sha256=none\n'
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$cubs_recovery_handoff"
}

cubs_write_lineage_and_handoff() {
  local anchor_id=$1 serial_binding=$2 physical_sizes_sha256=$3
  local bootloader=$4 baseband=$5
  local stock_b_source=${6:-full_ota}
  local stock_b_provenance_sha256=${7:-$FULL_OTA_SHA256}
  local physical_b_source_manifest_sha256=${8:-none}
  local physical_b_vendor_boot_fetch_sha256=${9:-none}
  local handoff_kind=${10:-stock_b_anchor}
  local created expires lineage_sha temporary

  [[ "$anchor_id" =~ ^[0-9a-f]{32}$ && \
     "$serial_binding" =~ ^[0-9a-f]{64}$ && \
     "$physical_sizes_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    die "invalid recovery lineage input"
  [[ -n "$bootloader" && -n "$baseband" ]] || \
    die "recovery lineage has empty firmware identity"
  [[ "$handoff_kind" =~ ^(stock_b_anchor|physical_b_lifeboat)$ ]] || \
    die "invalid recovery handoff kind"
  case "$stock_b_source" in
    full_ota)
      [[ "$stock_b_provenance_sha256" == "$FULL_OTA_SHA256" && \
         "$physical_b_source_manifest_sha256" == none && \
         "$physical_b_vendor_boot_fetch_sha256" == none ]] || \
        die "invalid full-OTA stock-B provenance input"
      ;;
    direct_factory_physical_b)
      [[ "$stock_b_provenance_sha256" =~ ^[0-9a-f]{64}$ && \
         "$physical_b_source_manifest_sha256" == \
           "$CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256" && \
         "$physical_b_vendor_boot_fetch_sha256" == \
           "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || \
        die "invalid direct-factory stock-B provenance input"
      ;;
    *)
      die "unsupported stock-B lineage source input"
      ;;
  esac
  [[ ! -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]] || \
    die "an active recovery handoff already exists"

  created=$(date +%s)
  expires=$((created + CUBS_RECOVERY_HANDOFF_READY_SECONDS))
  temporary=$(mktemp "$cubs_recovery_state_dir/.lineage.XXXXXX")
  {
    printf 'schema=cubs-recovery-lineage-v2\n'
    printf 'anchor_id=%s\n' "$anchor_id"
    printf 'created_epoch=%s\n' "$created"
    printf 'serial_binding_sha256=%s\n' "$serial_binding"
    printf 'device=%s\n' "$DEVICE_CODENAME"
    printf 'stock_build_id=%s\n' "$STOCK_BUILD_ID"
    printf 'stock_fingerprint_sha256=%s\n' "$CUBS_STOCK_FINGERPRINT_SHA256"
    printf 'factory_sha256=%s\n' "$FACTORY_IMAGE_SHA256"
    printf 'full_ota_sha256=%s\n' "$FULL_OTA_SHA256"
    printf 'bootloader=%s\n' "$bootloader"
    printf 'baseband=%s\n' "$baseband"
    printf 'ab_ota_partitions_sha256=%s\n' "$CUBS_AB_OTA_PARTITIONS_SHA256"
    printf 'shared_super_layout_sha256=%s\n' "$CUBS_SHARED_SUPER_LAYOUT_SHA256"
    printf 'physical_b_sizes_sha256=%s\n' "$physical_sizes_sha256"
    printf 'stock_b_source=%s\n' "$stock_b_source"
    printf 'stock_b_provenance_sha256=%s\n' "$stock_b_provenance_sha256"
    printf 'physical_b_source_manifest_sha256=%s\n' \
      "$physical_b_source_manifest_sha256"
    printf 'physical_b_vendor_boot_fetch_sha256=%s\n' \
      "$physical_b_vendor_boot_fetch_sha256"
    printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -fT -- "$temporary" "$cubs_recovery_lineage"
  lineage_sha=$(sha256sum "$cubs_recovery_lineage")
  lineage_sha=${lineage_sha%% *}

  temporary=$(mktemp "$cubs_recovery_state_dir/.handoff.XXXXXX")
  {
    printf 'schema=cubs-recovery-handoff-v2\n'
    printf 'state=ready\n'
    printf 'handoff_kind=%s\n' "$handoff_kind"
    printf 'created_epoch=%s\n' "$created"
    printf 'expires_epoch=%s\n' "$expires"
    printf 'claimed_epoch=0\n'
    printf 'anchor_id=%s\n' "$anchor_id"
    printf 'serial_binding_sha256=%s\n' "$serial_binding"
    printf 'lineage_sha256=%s\n' "$lineage_sha"
    printf 'physical_b_sizes_sha256=%s\n' "$physical_sizes_sha256"
    printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
    printf 'bundle_kind=none\n'
    printf 'bundle_manifest_sha256=none\n'
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$cubs_recovery_handoff"
}

# Prove that the current handoff is safe to retire. Only an expired receipt
# which was never claimed by a bundle is eligible: a claimed receipt is
# recovery evidence for a possibly incomplete flash and must remain intact.
# The caller supplies the currently observed fastboot identity and physical-B
# size digest, so reissuing a receipt also revalidates its exact lineage.
cubs_verify_stale_ready_handoff() {
  local serial=$1 physical_sizes_sha256=$2 bootloader=$3 baseband=$4
  local created created_number expires expires_number handoff_sha now now_number
  local -A handoff=()

  unset \
    cubs_verified_stale_handoff_sha256 \
    cubs_verified_stale_handoff_created_epoch \
    cubs_verified_stale_handoff_kind
  cubs_verify_lifeboat_lineage \
    "$serial" "$physical_sizes_sha256" "$bootloader" "$baseband"
  cubs_private_file "$cubs_recovery_handoff"
  cubs_load_exact_kv "$cubs_recovery_handoff" handoff \
    schema state handoff_kind created_epoch expires_epoch claimed_epoch \
    anchor_id serial_binding_sha256 lineage_sha256 physical_b_sizes_sha256 \
    recovery_policy_sha256 bundle_kind bundle_manifest_sha256

  [[ "${handoff[schema]}" == cubs-recovery-handoff-v2 && \
     "${handoff[state]}" == ready && \
     "${handoff[handoff_kind]}" =~ ^(stock_b_anchor|physical_b_lifeboat)$ && \
     "${handoff[claimed_epoch]}" == 0 && \
     "${handoff[anchor_id]}" == "$cubs_verified_anchor_id" && \
     "${handoff[serial_binding_sha256]}" == "$cubs_verified_serial_binding" && \
     "${handoff[lineage_sha256]}" == "$cubs_verified_lineage_sha256" && \
     "${handoff[physical_b_sizes_sha256]}" == "$physical_sizes_sha256" && \
     "${handoff[recovery_policy_sha256]}" == "$CUBS_RECOVERY_POLICY_SHA256" && \
     "${handoff[bundle_kind]}" == none && \
     "${handoff[bundle_manifest_sha256]}" == none ]] || \
    die "only an exact, unclaimed ready handoff can be reissued"

  created=${handoff[created_epoch]}
  expires=${handoff[expires_epoch]}
  [[ "$created" =~ ^[1-9][0-9]{0,17}$ && \
     "$expires" =~ ^[1-9][0-9]{0,17}$ ]] || \
    die "recovery handoff has malformed freshness timestamps"
  created_number=$((10#$created))
  expires_number=$((10#$expires))
  (( expires_number == created_number + CUBS_RECOVERY_HANDOFF_READY_SECONDS )) || \
    die "recovery handoff has an invalid freshness interval"
  now=$(date +%s)
  [[ "$now" =~ ^[1-9][0-9]{0,17}$ ]] || die "unable to read the host clock"
  now_number=$((10#$now))
  (( now_number > expires_number )) || \
    die "recovery handoff is still fresh; use it instead of reissuing it"

  handoff_sha=$(sha256sum "$cubs_recovery_handoff")
  cubs_verified_stale_handoff_sha256=${handoff_sha%% *}
  cubs_verified_stale_handoff_created_epoch=$created
  cubs_verified_stale_handoff_kind=${handoff[handoff_kind]}
}

# Archive the verified stale receipt and publish its replacement while holding
# the caller's recovery-state lock. Copy and atomically publish the archive
# first, then atomically replace the still-active receipt. Thus a host failure
# always leaves an active handoff, and a retry can validate an already-published
# identical archive before replacing the stale active copy.
cubs_reissue_verified_stale_handoff() {
  local physical_sizes_sha256=$1 current_sha created expires temporary
  local retired_dir destination archive_temporary

  [[ "$physical_sizes_sha256" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_anchor_id:-}" =~ ^[0-9a-f]{32}$ && \
     "${cubs_verified_serial_binding:-}" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_lineage_sha256:-}" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_stale_handoff_sha256:-}" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_stale_handoff_created_epoch:-}" =~ ^[1-9][0-9]{0,17}$ && \
     "${cubs_verified_stale_handoff_kind:-}" =~ ^(stock_b_anchor|physical_b_lifeboat)$ ]] || \
    die "a verified stale ready handoff is unavailable"

  current_sha=$(sha256sum "$cubs_recovery_handoff")
  current_sha=${current_sha%% *}
  [[ "$current_sha" == "$cubs_verified_stale_handoff_sha256" ]] || \
    die "recovery handoff changed after stale-state verification"

  created=$(date +%s)
  expires=$((created + CUBS_RECOVERY_HANDOFF_READY_SECONDS))
  temporary=$(mktemp "$cubs_recovery_state_dir/.handoff.XXXXXX")
  {
    printf 'schema=cubs-recovery-handoff-v2\n'
    printf 'state=ready\n'
    printf 'handoff_kind=%s\n' "$cubs_verified_stale_handoff_kind"
    printf 'created_epoch=%s\n' "$created"
    printf 'expires_epoch=%s\n' "$expires"
    printf 'claimed_epoch=0\n'
    printf 'anchor_id=%s\n' "$cubs_verified_anchor_id"
    printf 'serial_binding_sha256=%s\n' "$cubs_verified_serial_binding"
    printf 'lineage_sha256=%s\n' "$cubs_verified_lineage_sha256"
    printf 'physical_b_sizes_sha256=%s\n' "$physical_sizes_sha256"
    printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
    printf 'bundle_kind=none\n'
    printf 'bundle_manifest_sha256=none\n'
  } >"$temporary"
  chmod 0600 "$temporary"

  retired_dir="$cubs_recovery_state_dir/retired"
  [[ ! -L "$retired_dir" ]] || die "retired handoff directory is unsafe"
  mkdir -p "$retired_dir"
  chmod 0700 "$retired_dir"
  [[ -d "$retired_dir" && ! -L "$retired_dir" ]] || \
    die "retired handoff directory is unsafe"
  destination="$retired_dir/${cubs_verified_anchor_id}-${cubs_verified_stale_handoff_created_epoch}-${cubs_verified_stale_handoff_sha256:0:16}.ready"
  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    archive_temporary=$(mktemp "$retired_dir/.handoff-archive.XXXXXX")
    cp --reflink=auto --preserve=mode -- \
      "$cubs_recovery_handoff" "$archive_temporary"
    chmod 0600 "$archive_temporary"
    cubs_private_file "$archive_temporary"
    cmp -s "$cubs_recovery_handoff" "$archive_temporary" || \
      die "copied stale handoff differs before archive publication"
    mv -T -- "$archive_temporary" "$destination"
  else
    cubs_private_file "$destination"
    [[ $(sha256sum "$destination" | awk '{print $1}') == \
         "$cubs_verified_stale_handoff_sha256" ]] || \
      die "retired stale-handoff destination has conflicting evidence"
  fi
  cubs_private_file "$destination"
  current_sha=$(sha256sum "$cubs_recovery_handoff" | awk '{print $1}')
  [[ "$current_sha" == "$cubs_verified_stale_handoff_sha256" ]] || \
    die "active stale handoff changed after archive publication"
  mv -fT -- "$temporary" "$cubs_recovery_handoff"
  cubs_private_file "$cubs_recovery_handoff"
}

cubs_invalidate_recovery_handoff() {
  cubs_prepare_recovery_state_dir
  for path in \
      "$cubs_recovery_handoff" \
      "$cubs_recovery_lineage" \
      "$cubs_stock_a_physical_b_preflight" \
      "$cubs_stock_a_baseline_evidence" \
      "$cubs_stock_a_lpdump_evidence" \
      "$cubs_stock_b_preparation_receipt" \
      "$cubs_stock_b_source_payload_manifest" \
      "$cubs_stock_b_fastbootd_trial_receipt" \
      "$cubs_stock_b_consumption_transaction" \
      "$cubs_runtime_boot_attestation" \
      "$cubs_flash_retirement_transaction"; do
    if [[ -e "$path" || -L "$path" ]]; then
      cubs_private_file "$path"
      rm -f -- "$path"
    fi
  done
}
