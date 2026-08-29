#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
# shellcheck source=lib/stock-adb-shell.sh disable=SC1091
source "$script_dir/lib/stock-adb-shell.sh"
# shellcheck source=lib/recovery-handoff.sh disable=SC1091
source "$script_dir/lib/recovery-handoff.sh"

require_command awk chmod cp date find flock grep mkdir mktemp mv openssl realpath \
  od rm sed sha256sum sleep sort stat tail timeout tr unzip

restore_transaction_receipt="$cubs_stock_restore_transaction"
flash_retirement_transaction="$cubs_recovery_state_dir/flash-retirement-transaction"
slot_a_flash_transaction="$cubs_recovery_state_dir/slot-a-flash-transaction"
expected_fastboot_version=37.0.1
expected_fastboot_sha256=a686e2c7e8dc9cf4cba0cb8a2eef05f7b2bd682c925abd032fe203215d80b618
expected_adb_sha256=$PLATFORM_TOOLS_ADB_SHA256
expected_stock_fingerprint_sha256=$CUBS_STOCK_FINGERPRINT_SHA256

declare -A restore_flash_abort=()
declare -A restore_runtime_attestation=()
inspect_restore_flash_abort() {
  local actual_sha expected_targets_sha

  observed_restore_flash_abort_sha256=none
  observed_restore_runtime_attestation_sha256=none
  restore_flash_abort=()
  restore_runtime_attestation=()
  if [[ ! -e "$slot_a_flash_transaction" && \
        ! -L "$slot_a_flash_transaction" ]]; then
    [[ ! -e "$cubs_runtime_boot_attestation" && \
       ! -L "$cubs_runtime_boot_attestation" ]] || \
      die "runtime boot attestation exists without an adoptable aborted flash transaction"
    return
  fi
  cubs_private_file "$slot_a_flash_transaction"
  [[ $(grep -Fxc 'state=aborted_for_restore' \
       "$slot_a_flash_transaction" || true) -eq 1 ]] || \
    die "slot-A flash transaction is not an exact terminal aborted_for_restore handoff"
  cubs_load_exact_kv "$slot_a_flash_transaction" restore_flash_abort \
    schema state created_epoch transaction_id serial_binding_sha256 device \
    anchor_id lineage_sha256 handoff_sha256 physical_b_sizes_sha256 \
    stock_b_source stock_b_provenance_sha256 bundle_kind \
    bundle_manifest_sha256 logical_targets_sha256 \
    logical_image_sizes_sha256 recovery_policy_sha256
  case "${restore_flash_abort[bundle_kind]}" in
    gsi)
      expected_targets_sha=$(printf 'system\n' | sha256sum | awk '{print $1}')
      ;;
    cubs)
      expected_targets_sha=$(printf '%s\n' \
        system system_dlkm system_ext product vendor vendor_dlkm | \
        sha256sum | awk '{print $1}')
      ;;
    *) die "aborted flash transaction has an unsupported bundle kind" ;;
  esac
  [[ "${restore_flash_abort[schema]}" == \
       cubs-slot-a-flash-transaction-v1 && \
     "${restore_flash_abort[state]}" == aborted_for_restore && \
     "${restore_flash_abort[created_epoch]}" =~ ^[1-9][0-9]{0,17}$ && \
     "${restore_flash_abort[transaction_id]}" =~ ^[0-9a-f]{32}$ && \
     "${restore_flash_abort[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${restore_flash_abort[device]}" == "$DEVICE_CODENAME" && \
     "${restore_flash_abort[anchor_id]}" =~ ^[0-9a-f]{32}$ && \
     "${restore_flash_abort[lineage_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${restore_flash_abort[handoff_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${restore_flash_abort[physical_b_sizes_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${restore_flash_abort[stock_b_source]}" =~ \
       ^(full_ota|direct_factory_physical_b)$ && \
     "${restore_flash_abort[stock_b_provenance_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${restore_flash_abort[bundle_manifest_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${restore_flash_abort[logical_targets_sha256]}" == \
       "$expected_targets_sha" && \
     "${restore_flash_abort[logical_image_sizes_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${restore_flash_abort[recovery_policy_sha256]}" == \
       "$CUBS_RECOVERY_POLICY_SHA256" ]] || \
    die "slot-A flash transaction is not an exact terminal aborted_for_restore handoff"
  case "${restore_flash_abort[stock_b_source]}" in
    full_ota)
      [[ "${restore_flash_abort[stock_b_provenance_sha256]}" == \
           "$FULL_OTA_SHA256" ]] || \
        die "aborted flash transaction has invalid full-OTA provenance"
      ;;
  esac
  actual_sha=$(sha256sum "$slot_a_flash_transaction" | awk '{print $1}')
  observed_restore_flash_abort_sha256=$actual_sha

  if [[ -e "$cubs_runtime_boot_attestation" || \
        -L "$cubs_runtime_boot_attestation" ]]; then
    cubs_private_file "$cubs_runtime_boot_attestation"
    cubs_load_exact_kv "$cubs_runtime_boot_attestation" \
      restore_runtime_attestation \
      schema created_epoch anchor_id serial_binding_sha256 lineage_sha256 \
      handoff_sha256 flash_transaction_sha256 claimed_epoch device slot_suffix \
      bundle_kind bundle_manifest_sha256 output_build_id build_type \
      framework_security_patch build_fingerprint_sha256 boot_id uptime_seconds \
      sys_boot_completed validation_result runtime_report_basename \
      runtime_report_sha256 recovery_policy_sha256
    [[ "${restore_runtime_attestation[schema]}" == \
         cubs-runtime-boot-attestation-v2 && \
       "${restore_runtime_attestation[created_epoch]}" =~ ^[1-9][0-9]{0,17}$ && \
       "${restore_runtime_attestation[anchor_id]}" =~ ^[0-9a-f]{32}$ && \
       "${restore_runtime_attestation[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
       "${restore_runtime_attestation[lineage_sha256]}" =~ ^[0-9a-f]{64}$ && \
       "${restore_runtime_attestation[handoff_sha256]}" =~ ^[0-9a-f]{64}$ && \
       "${restore_runtime_attestation[flash_transaction_sha256]}" =~ ^[0-9a-f]{64}$ && \
       "${restore_runtime_attestation[claimed_epoch]}" =~ ^[1-9][0-9]{0,17}$ && \
       "${restore_runtime_attestation[device]}" == "$DEVICE_CODENAME" && \
       "${restore_runtime_attestation[slot_suffix]}" == _a && \
       "${restore_runtime_attestation[bundle_kind]}" == \
         "${restore_flash_abort[bundle_kind]}" && \
       "${restore_runtime_attestation[bundle_manifest_sha256]}" == \
         "${restore_flash_abort[bundle_manifest_sha256]}" && \
       "${restore_runtime_attestation[output_build_id]}" =~ ^[A-Za-z0-9._-]+$ && \
       "${restore_runtime_attestation[build_type]}" == userdebug && \
       "${restore_runtime_attestation[framework_security_patch]}" =~ \
         ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && \
       "${restore_runtime_attestation[build_fingerprint_sha256]}" =~ ^[0-9a-f]{64}$ && \
       "${restore_runtime_attestation[boot_id]}" =~ \
         ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ && \
       "${restore_runtime_attestation[uptime_seconds]}" =~ ^[1-9][0-9]*$ && \
       "${restore_runtime_attestation[sys_boot_completed]}" == 1 && \
       "${restore_runtime_attestation[validation_result]}" =~ \
         ^(PASS|PASS_WITH_WARNINGS)$ && \
       "${restore_runtime_attestation[runtime_report_basename]}" =~ \
         ^runtime-validation-(gsi|cubs)-[0-9]{8}T[0-9]{6}Z-[0-9]+\.txt$ && \
       "${restore_runtime_attestation[runtime_report_sha256]}" =~ ^[0-9a-f]{64}$ && \
       "${restore_runtime_attestation[recovery_policy_sha256]}" == \
         "$CUBS_RECOVERY_POLICY_SHA256" ]] || \
      die "runtime marker beside the aborted flash is not exact"
    observed_restore_runtime_attestation_sha256=$(sha256sum \
      "$cubs_runtime_boot_attestation" | awk '{print $1}')
  fi
}

require_no_conflicting_recovery_transaction() {
  local path
  [[ ! -e "$flash_retirement_transaction" && \
     ! -L "$flash_retirement_transaction" ]] || \
    die "finish the exact flash-retirement transaction before starting stock restore"
  [[ ! -e "$cubs_stock_b_consumption_transaction" && \
     ! -L "$cubs_stock_b_consumption_transaction" ]] || \
    die "finish the direct physical-B trial transaction before starting stock restore"
  # Only flash-a's terminal, device-reconciled abort handoff is adoptable.  Its
  # exact digest is bound into every restore receipt revision below.
  inspect_restore_flash_abort
  for path in \
      "$cubs_stock_a_baseline_evidence" \
      "$cubs_stock_a_physical_b_preflight" \
      "$cubs_stock_a_lpdump_evidence" \
      "$cubs_stock_b_source_payload_manifest" \
      "$cubs_stock_b_preparation_receipt" \
      "$cubs_stock_b_fastbootd_trial_receipt"; do
    [[ ! -e "$path" && ! -L "$path" ]] || \
      die "finish or recover the unresolved direct physical-B workflow before stock restore"
  done
}

verify_restore_flash_abort_adoption() {
  local serial=$1 physical_b_sizes_sha256=$2 actual_binding actual_sha
  local claimed created now
  local -A handoff=()

  if [[ "${observed_restore_flash_abort_sha256:-none}" == none ]]; then
    verified_restore_adopted_flash_transaction_sha256=none
    verified_restore_adopted_flash_serial_binding_sha256=none
    verified_restore_adopted_runtime_attestation_sha256=none
    if [[ -n "${restore_transaction_adopted_flash_transaction_sha256:-}" && \
          "$restore_transaction_adopted_flash_transaction_sha256" != none && \
          "${restore_transaction_state:-}" != retiring_evidence ]]; then
      die "the adopted aborted_for_restore transaction disappeared before retirement"
    fi
    return
  fi

  cubs_private_file "$slot_a_flash_transaction"
  actual_sha=$(sha256sum "$slot_a_flash_transaction" | awk '{print $1}')
  [[ "$actual_sha" == "$observed_restore_flash_abort_sha256" ]] || \
    die "aborted_for_restore transaction changed after inspection"
  cubs_load_exact_kv "$cubs_recovery_handoff" handoff \
    schema state handoff_kind created_epoch expires_epoch claimed_epoch \
    anchor_id serial_binding_sha256 lineage_sha256 physical_b_sizes_sha256 \
    recovery_policy_sha256 bundle_kind bundle_manifest_sha256
  claimed=${handoff[claimed_epoch]}
  created=${restore_flash_abort[created_epoch]}
  now=$(date +%s)
  actual_binding=$(cubs_serial_binding \
    "${restore_flash_abort[transaction_id]}" "$serial")
  [[ "${handoff[schema]}" == cubs-recovery-handoff-v2 && \
     "${handoff[state]}" == claimed && \
     "$claimed" =~ ^[1-9][0-9]{0,17}$ && \
     "${restore_flash_abort[anchor_id]}" == "$cubs_verified_anchor_id" && \
     "${restore_flash_abort[lineage_sha256]}" == \
       "$cubs_verified_lineage_sha256" && \
     "${restore_flash_abort[handoff_sha256]}" == \
       "$cubs_verified_recovery_handoff_sha256" && \
     "${restore_flash_abort[physical_b_sizes_sha256]}" == \
       "$physical_b_sizes_sha256" && \
     "${restore_flash_abort[stock_b_source]}" == \
       "$cubs_verified_stock_b_source" && \
     "${restore_flash_abort[stock_b_provenance_sha256]}" == \
       "$cubs_verified_stock_b_provenance_sha256" && \
     "${restore_flash_abort[bundle_kind]}" == "${handoff[bundle_kind]}" && \
     "${restore_flash_abort[bundle_manifest_sha256]}" == \
       "${handoff[bundle_manifest_sha256]}" && \
     "${restore_flash_abort[serial_binding_sha256]}" == "$actual_binding" ]] || \
    die "terminal flash abort does not match the active claimed recovery evidence"
  (( 10#$created >= 10#$claimed && 10#$created <= 10#$now )) || \
    die "terminal flash abort has an inconsistent timestamp"
  if [[ -n "${restore_transaction_adopted_flash_transaction_sha256:-}" && \
        "$restore_transaction_adopted_flash_transaction_sha256" != \
          "$observed_restore_flash_abort_sha256" ]]; then
    die "stock-restore receipt does not bind the active aborted flash transaction"
  fi
  if [[ -n "${restore_transaction_adopted_runtime_attestation_sha256:-}" && \
        "$restore_transaction_adopted_runtime_attestation_sha256" != \
          "$observed_restore_runtime_attestation_sha256" ]]; then
    die "stock-restore receipt does not bind the adopted runtime marker"
  fi
  verified_restore_adopted_flash_transaction_sha256=$observed_restore_flash_abort_sha256
  verified_restore_adopted_flash_serial_binding_sha256=${restore_flash_abort[serial_binding_sha256]}
  verified_restore_adopted_runtime_attestation_sha256=none
  if [[ "$observed_restore_runtime_attestation_sha256" != none ]]; then
    cubs_private_file "$cubs_runtime_boot_attestation"
    actual_sha=$(sha256sum "$cubs_runtime_boot_attestation" | awk '{print $1}')
    [[ "$actual_sha" == "$observed_restore_runtime_attestation_sha256" && \
       "${restore_runtime_attestation[anchor_id]}" == \
         "$cubs_verified_anchor_id" && \
       "${restore_runtime_attestation[serial_binding_sha256]}" == \
         "$cubs_verified_serial_binding" && \
       "${restore_runtime_attestation[lineage_sha256]}" == \
         "$cubs_verified_lineage_sha256" && \
       "${restore_runtime_attestation[handoff_sha256]}" == \
         "$cubs_verified_recovery_handoff_sha256" && \
       "${restore_runtime_attestation[claimed_epoch]}" == "$claimed" ]] || \
      die "runtime marker does not match the adopted abort's recovery evidence"
    created=${restore_runtime_attestation[created_epoch]}
    (( 10#$created >= 10#$claimed && 10#$created <= 10#$now )) || \
      die "adopted runtime marker has an inconsistent timestamp"
    verified_restore_adopted_runtime_attestation_sha256=$actual_sha
  fi
}

select_pinned_restore_fastboot() {
  local actual_path digest output version
  if [[ -z "${fastboot_bin:-}" ]]; then
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
  fi
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

action=${1:-restore}
(( $# <= 1 )) || die \
  "usage: $0 [restore|finalize-activation|finalize-stock-android]"
case "$action" in
  restore)
    expected_confirmation=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID
    ;;
  finalize-activation)
    expected_confirmation=FINALIZE_STOCK_A_RESTORE_ACTIVATION_NO_REFLASH
    ;;
  finalize-stock-android)
    expected_confirmation=FINALIZE_EXACT_STOCK_A_RESTORE_AFTER_SUCCESSFUL_ANDROID_BOOT
    ;;
  -h|--help|help)
    cat <<'EOF'
Usage: scripts/restore-stock.sh [restore|finalize-activation|finalize-stock-android]

  restore              Restore exact stock A, resuming a bound in-progress
                       transaction from either bootloader slot.
  finalize-activation  Finish an activate_a_pending transaction after a host
                       or USB interruption without reflashing.
  finalize-stock-android
                       After exact restored stock A boots successfully, retire
                       the retained recovery evidence.
EOF
    exit 0
    ;;
  *) die "unsupported stock-restore action: $action" ;;
esac
if [[ "$action" == finalize-stock-android ]]; then
  [[ "${CUBS_ALLOW_STOCK_RESTORE_FINALIZE:-}" == 1 ]] || die \
    "set CUBS_ALLOW_STOCK_RESTORE_FINALIZE=1 only after exact restored stock A boots"
else
  [[ "${CUBS_ALLOW_DATA_WIPE:-}" == 1 ]] || die \
    "stock restore erases userdata and metadata; set CUBS_ALLOW_DATA_WIPE=1"
fi
[[ "${CUBS_RESTORE_CONFIRM:-}" == "$expected_confirmation" ]] || die \
  "set CUBS_RESTORE_CONFIRM=$expected_confirmation for this exact restore action"

load_restore_transaction_receipt() {
  local serial=${1:-} actual_binding created now receipt_sha
  local -A receipt=()

  cubs_private_file "$restore_transaction_receipt"
  cubs_load_exact_kv "$restore_transaction_receipt" receipt \
    schema state created_epoch transaction_id serial_binding_sha256 device \
    stock_build_id factory_sha256 physical_b_sizes_sha256 lineage_sha256 \
    handoff_sha256 stock_b_source stock_b_provenance_sha256 \
    adopted_flash_transaction_sha256 adopted_flash_serial_binding_sha256 \
    adopted_runtime_attestation_sha256 recovery_policy_sha256
  [[ "${receipt[schema]}" == cubs-stock-restore-v2 && \
     "${receipt[state]}" =~ ^(select_b_pending|enter_b_fastbootd_pending|pivot_a_metadata_pending|restoring_logicals|return_bootloader_pending|restoring_physical|activate_a_pending|awaiting_stock_android|boot_control_pending|retiring_evidence)$ && \
     "${receipt[created_epoch]}" =~ ^[1-9][0-9]{0,17}$ && \
     "${receipt[transaction_id]}" =~ ^[0-9a-f]{32}$ && \
     "${receipt[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[device]}" == "$DEVICE_CODENAME" && \
     "${receipt[stock_build_id]}" == "$STOCK_BUILD_ID" && \
     "${receipt[factory_sha256]}" == "$FACTORY_IMAGE_SHA256" && \
     "${receipt[physical_b_sizes_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[lineage_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[handoff_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt[adopted_flash_transaction_sha256]}" =~ ^(none|[0-9a-f]{64})$ && \
     "${receipt[adopted_flash_serial_binding_sha256]}" =~ \
       ^(none|[0-9a-f]{64})$ && \
     "${receipt[adopted_runtime_attestation_sha256]}" =~ \
       ^(none|[0-9a-f]{64})$ && \
     ( ( "${receipt[adopted_flash_transaction_sha256]}" == none && \
         "${receipt[adopted_flash_serial_binding_sha256]}" == none && \
         "${receipt[adopted_runtime_attestation_sha256]}" == none ) || \
       ( "${receipt[adopted_flash_transaction_sha256]}" != none && \
         "${receipt[adopted_flash_serial_binding_sha256]}" != none ) ) && \
     "${receipt[recovery_policy_sha256]}" == "$CUBS_RECOVERY_POLICY_SHA256" ]] || \
    die "stock-restore transaction receipt does not match this exact release"
  case "${receipt[stock_b_source]}" in
    full_ota)
      [[ "${receipt[stock_b_provenance_sha256]}" == "$FULL_OTA_SHA256" ]] || \
        die "stock-restore receipt has invalid full-OTA provenance"
      ;;
    direct_factory_physical_b)
      [[ "${receipt[stock_b_provenance_sha256]}" =~ ^[0-9a-f]{64}$ ]] || \
        die "stock-restore receipt has invalid direct-B provenance"
      ;;
    *) die "stock-restore receipt has an unsupported B source" ;;
  esac
  if [[ -n "$serial" ]]; then
    actual_binding=$(cubs_serial_binding "${receipt[transaction_id]}" "$serial")
    [[ "$actual_binding" == "${receipt[serial_binding_sha256]}" ]] || \
      die "stock-restore receipt belongs to another USB transport"
  else
    [[ "${receipt[state]}" == retiring_evidence ]] || \
      die "an unbound stock-restore receipt is usable only after retirement commit"
  fi
  created=${receipt[created_epoch]}
  now=$(date +%s)
  (( 10#$now >= 10#$created )) || \
    die "stock-restore receipt is dated in the future"
  receipt_sha=$(sha256sum "$restore_transaction_receipt" | awk '{print $1}')
  restore_transaction_state=${receipt[state]}
  restore_transaction_created_epoch=$created
  restore_transaction_id=${receipt[transaction_id]}
  restore_transaction_serial_binding=${receipt[serial_binding_sha256]}
  restore_transaction_physical_b_sizes_sha256=${receipt[physical_b_sizes_sha256]}
  restore_transaction_lineage_sha256=${receipt[lineage_sha256]}
  restore_transaction_handoff_sha256=${receipt[handoff_sha256]}
  restore_transaction_stock_b_source=${receipt[stock_b_source]}
  restore_transaction_stock_b_provenance_sha256=${receipt[stock_b_provenance_sha256]}
  restore_transaction_adopted_flash_transaction_sha256=${receipt[adopted_flash_transaction_sha256]}
  restore_transaction_adopted_flash_serial_binding_sha256=${receipt[adopted_flash_serial_binding_sha256]}
  restore_transaction_adopted_runtime_attestation_sha256=${receipt[adopted_runtime_attestation_sha256]}
  loaded_restore_transaction_sha256=$receipt_sha
  case "$restore_transaction_state" in
    pivot_a_metadata_pending|restoring_logicals|return_bootloader_pending|\
    restoring_physical|activate_a_pending)
      shared_super_modified=1
      ;;
  esac
}

archive_restore_transaction_receipt() {
  local consumed_dir current_sha destination
  cubs_private_file "$restore_transaction_receipt"
  current_sha=$(sha256sum "$restore_transaction_receipt" | awk '{print $1}')
  [[ "$current_sha" == "$loaded_restore_transaction_sha256" ]] || \
    die "stock-restore transaction receipt changed after verification"
  consumed_dir="$cubs_recovery_state_dir/consumed"
  [[ ! -L "$consumed_dir" ]] || die "consumed recovery directory is unsafe"
  mkdir -p "$consumed_dir"
  chmod 0700 "$consumed_dir"
  [[ -d "$consumed_dir" && ! -L "$consumed_dir" ]] || \
    die "consumed recovery directory is unsafe"
  destination="$consumed_dir/stock-restore-${restore_transaction_id}-${current_sha}"
  [[ ! -e "$destination" && ! -L "$destination" ]] || \
    die "consumed stock-restore receipt destination already exists"
  mv -T -- "$restore_transaction_receipt" "$destination"
  cubs_private_file "$destination"
}

archive_adopted_restore_sources() {
  local active consumed_dir destination expected_entries runtime_active runtime_archive
  local temporary transaction_archive
  local -a entries=()

  if [[ "$restore_transaction_adopted_flash_transaction_sha256" == none ]]; then
    [[ "$restore_transaction_adopted_flash_serial_binding_sha256" == none && \
       "$restore_transaction_adopted_runtime_attestation_sha256" == none ]] || \
      die "restore receipt has inconsistent empty adoption evidence"
    return
  fi
  [[ "$restore_transaction_state" == retiring_evidence ]] || \
    die "adopted flash evidence may be archived only after retirement commit"

  consumed_dir="$cubs_recovery_state_dir/consumed"
  [[ ! -L "$consumed_dir" ]] || die "consumed recovery directory is unsafe"
  mkdir -p "$consumed_dir"
  chmod 0700 "$consumed_dir"
  [[ -d "$consumed_dir" && ! -L "$consumed_dir" ]] || \
    die "consumed recovery directory is unsafe"
  destination="$consumed_dir/stock-restore-adoption-${restore_transaction_id}-${restore_transaction_adopted_flash_transaction_sha256}"
  transaction_archive="$destination/slot-a-flash-transaction"
  runtime_archive="$destination/runtime-boot-attestation"

  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    active=$slot_a_flash_transaction
    cubs_private_file "$active"
    [[ $(sha256sum "$active" | awk '{print $1}') == \
         "$restore_transaction_adopted_flash_transaction_sha256" ]] || \
      die "adopted flash transaction changed before archive publication"
    temporary=$(mktemp -d "$consumed_dir/.stock-restore-adoption.XXXXXX")
    chmod 0700 "$temporary"
    cp --reflink=auto --preserve=mode -- "$active" \
      "$temporary/slot-a-flash-transaction"
    chmod 0600 "$temporary/slot-a-flash-transaction"
    if [[ "$restore_transaction_adopted_runtime_attestation_sha256" != none ]]; then
      cubs_private_file "$cubs_runtime_boot_attestation"
      [[ $(sha256sum "$cubs_runtime_boot_attestation" | awk '{print $1}') == \
           "$restore_transaction_adopted_runtime_attestation_sha256" ]] || \
        die "adopted runtime marker changed before archive publication"
      cp --reflink=auto --preserve=mode -- "$cubs_runtime_boot_attestation" \
        "$temporary/runtime-boot-attestation"
      chmod 0600 "$temporary/runtime-boot-attestation"
    fi
    mv -T -- "$temporary" "$destination"
  fi

  cubs_private_dir "$destination"
  mapfile -t entries < <(
    find "$destination" -mindepth 1 -maxdepth 1 -printf '%f\n' | \
      LC_ALL=C sort
  )
  expected_entries='slot-a-flash-transaction'
  if [[ "$restore_transaction_adopted_runtime_attestation_sha256" != none ]]; then
    expected_entries=$'runtime-boot-attestation\nslot-a-flash-transaction'
  fi
  [[ "$(printf '%s\n' "${entries[@]}")" == "$expected_entries" ]] || \
    die "published stock-restore adoption archive has unexpected entries"
  cubs_private_file "$transaction_archive"
  [[ $(sha256sum "$transaction_archive" | awk '{print $1}') == \
       "$restore_transaction_adopted_flash_transaction_sha256" ]] || \
    die "archived adopted flash transaction differs from the restore receipt"
  if [[ "$restore_transaction_adopted_runtime_attestation_sha256" != none ]]; then
    cubs_private_file "$runtime_archive"
    [[ $(sha256sum "$runtime_archive" | awk '{print $1}') == \
         "$restore_transaction_adopted_runtime_attestation_sha256" ]] || \
      die "archived runtime marker differs from the restore receipt"
  fi

  runtime_active=$cubs_runtime_boot_attestation
  if [[ -e "$runtime_active" || -L "$runtime_active" ]]; then
    [[ "$restore_transaction_adopted_runtime_attestation_sha256" != none ]] || \
      die "unexpected runtime marker appeared during adopted-evidence retirement"
    cubs_private_file "$runtime_active"
    cmp -s "$runtime_active" "$runtime_archive" || \
      die "active runtime marker differs from its adoption archive"
    rm -f -- "$runtime_active"
  fi
  # The terminal transaction is the discoverability anchor. Remove an optional
  # runtime marker first and the transaction last, so every crash before the
  # final unlink remains inspectable and resumable from retiring_evidence.
  if [[ -e "$slot_a_flash_transaction" || -L "$slot_a_flash_transaction" ]]; then
    cubs_private_file "$slot_a_flash_transaction"
    cmp -s "$slot_a_flash_transaction" "$transaction_archive" || \
      die "active adopted flash transaction differs from its archive"
    rm -f -- "$slot_a_flash_transaction"
  fi
}

find_single_stock_adb() {
  local output record
  local -a records=()
  select_pinned_stock_adb
  output=$("$adb_bin" devices) || die "unable to enumerate ADB transports"
  mapfile -t records < <(awk \
    'NR > 1 && NF >= 2 {print $1 "\t" $2}' <<<"$output")
  (( ${#records[@]} == 1 )) || die "expected exactly one ADB transport"
  record=${records[0]}
  stock_adb_serial=${record%%$'\t'*}
  [[ ${record#*$'\t'} == device ]] || \
    die "the sole ADB transport is not authorized Android"
  if [[ -n "${CUBS_ADB_SERIAL:-}" && "$CUBS_ADB_SERIAL" != "$stock_adb_serial" ]]; then
    die "CUBS_ADB_SERIAL does not select the sole stock-Android transport"
  fi
  if [[ -n "${ANDROID_SERIAL:-}" && "$ANDROID_SERIAL" != "$stock_adb_serial" ]]; then
    die "ANDROID_SERIAL does not select the sole stock-Android transport"
  fi
  [[ "$stock_adb_serial" != -* && ! "$stock_adb_serial" =~ [[:space:]] ]] || \
    die "invalid ADB serial"
  cubs_require_normal_stock_adb_shell "$adb_bin" "$stock_adb_serial"
}

select_pinned_stock_adb() {
  local actual_path digest output version
  if [[ -z "${adb_bin:-}" ]]; then
    if [[ -n "${ADB:-}" ]]; then
      [[ "$ADB" == /* ]] || die "ADB must be an absolute path"
      adb_bin=$ADB
    else
      adb_bin="$project_root/work/toolchains/platform-tools/adb"
    fi
    [[ -f "$adb_bin" && ! -L "$adb_bin" && -x "$adb_bin" ]] || \
      die "pinned workspace adb is not a safe executable: $adb_bin"
    adb_bin=$(realpath -e -- "$adb_bin")
  fi
  [[ -f "$adb_bin" && ! -L "$adb_bin" && -x "$adb_bin" ]] || \
    die "pinned workspace adb is not a safe executable: $adb_bin"
  actual_path=$(realpath -e -- "$adb_bin")
  [[ "$actual_path" == "$adb_bin" ]] || \
    die "the selected adb executable path changed during authorization"
  digest=$(sha256sum "$adb_bin")
  digest=${digest%% *}
  [[ "$digest" == "$expected_adb_sha256" ]] || \
    die "adb does not match the pinned Platform-Tools binary digest"
  output=$("$adb_bin" version 2>&1) || \
    die "unable to execute the pinned adb version check"
  if [[ "$output" =~ Version[[:space:]]([0-9]+(\.[0-9]+)*)- ]]; then
    version=${BASH_REMATCH[1]}
  else
    die "unable to determine adb version"
  fi
  [[ "$version" == "$PLATFORM_TOOLS_VERSION" ]] || die \
    "this release is pinned to adb $PLATFORM_TOOLS_VERSION; found $version"
}

stock_adb_prop() {
  local property=$1
  timeout 20 "$adb_bin" -s "$stock_adb_serial" shell getprop "$property" | tr -d '\r'
}

load_exact_stock_runtime_requirements() {
  local android_info board factory_image stock_dir stock_images

  [[ -n "${runtime_expected_bootloader:-}" && \
     -n "${runtime_expected_baseband:-}" ]] && return 0
  factory_image="$project_root/downloads/$FACTORY_IMAGE_FILENAME"
  verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"
  "$script_dir/extract-stock.sh"
  stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
  stock_images="$stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
  require_file "$stock_images"
  [[ ! -L "$stock_images" ]] || \
    die "refusing a symlinked stock image archive during runtime finalization"
  [[ $(unzip -Z1 "$stock_images" | grep -Fxc android-info.txt || true) -eq 1 ]] || \
    die "stock image package must contain exactly one root android-info.txt"
  android_info=$(unzip -p "$stock_images" android-info.txt) || \
    die "unable to read stock android-info.txt"
  board=$(sed -n 's/^require board=//p' <<<"$android_info")
  runtime_expected_bootloader=$(sed -n \
    's/^require version-bootloader=//p' <<<"$android_info")
  runtime_expected_baseband=$(sed -n \
    's/^require version-baseband=//p' <<<"$android_info")
  [[ "|$board|" == *"|$DEVICE_CODENAME|"* && \
     $(grep -c '^require board=' <<<"$android_info") -eq 1 && \
     $(grep -c '^require version-bootloader=' <<<"$android_info") -eq 1 && \
     $(grep -c '^require version-baseband=' <<<"$android_info") -eq 1 && \
     -n "$runtime_expected_bootloader" && \
     -n "$runtime_expected_baseband" ]] || \
    die "pinned stock package has malformed runtime firmware requirements"
}

audit_exact_stock_a_runtime() {
  local baseband boot_completed bootloader build_id build_type device
  local fingerprint fingerprint_sha flash_locked lpdump_output partition
  local slot_suffix snapshot_merge_status snapshot_merging
  local vbmeta_state verified_boot_state
  local -a modem_versions=()
  local -A first_extent_end=()

  find_single_stock_adb
  load_exact_stock_runtime_requirements
  device=$(stock_adb_prop ro.product.device)
  build_id=$(stock_adb_prop ro.build.id)
  fingerprint=$(stock_adb_prop ro.build.fingerprint)
  build_type=$(stock_adb_prop ro.build.type)
  slot_suffix=$(stock_adb_prop ro.boot.slot_suffix)
  bootloader=$(stock_adb_prop ro.bootloader)
  baseband=$(stock_adb_prop gsm.version.baseband)
  boot_completed=$(stock_adb_prop sys.boot_completed)
  flash_locked=$(stock_adb_prop ro.boot.flash.locked)
  vbmeta_state=$(stock_adb_prop ro.boot.vbmeta.device_state)
  verified_boot_state=$(stock_adb_prop ro.boot.verifiedbootstate)
  snapshot_merge_status=$(stock_adb_prop ro.boot.snapshot_merge_status)
  snapshot_merging=$(stock_adb_prop sys.snapshot_merging)
  fingerprint_sha=$(printf '%s' "$fingerprint" | sha256sum | awk '{print $1}')

  [[ "$device" == "$DEVICE_CODENAME" && \
     "$build_id" == "$STOCK_BUILD_ID" && \
     "$fingerprint_sha" == "$expected_stock_fingerprint_sha256" && \
     "$build_type" == user && "$slot_suffix" == _a && \
     "$bootloader" == "$runtime_expected_bootloader" && \
     "$boot_completed" == 1 ]] || \
    die "Android is not the exact successfully booted stock-A release"
  IFS=, read -r -a modem_versions <<<"$baseband"
  (( ${#modem_versions[@]} > 0 )) || die "stock Android reports no modem firmware"
  for modem in "${modem_versions[@]}"; do
    [[ "$modem" == "$runtime_expected_baseband" ]] || \
      die "stock Android baseband differs from the pinned factory release"
  done
  [[ "$flash_locked" == 0 && \
     ( -z "$vbmeta_state" || "$vbmeta_state" == unlocked ) && \
     "$verified_boot_state" == orange ]] || \
    die "stock Android does not report the expected unlocked boot state"
  [[ -z "$snapshot_merge_status" || \
     "$snapshot_merge_status" =~ ^(none|cancelled|completed)$ ]] || \
    die "stock Android reports an active snapshot update"
  [[ -z "$snapshot_merging" || "$snapshot_merging" =~ ^(0|false)$ ]] || \
    die "stock Android reports active snapshot merging"

  lpdump_output=$(timeout 30 "$adb_bin" -s "$stock_adb_serial" shell lpdump -a | \
    tr -d '\r') || die "unable to inspect restored stock-A logical metadata"
  [[ $(grep -c '^Current slot: _a$' <<<"$lpdump_output") -ge 1 && \
     $(grep -c '^Update state: none$' <<<"$lpdump_output") -eq 1 ]] || \
    die "restored stock-A logical metadata has the wrong slot or update state"
  while read -r partition extent_end; do
    [[ -n "$partition" && "$extent_end" =~ ^[0-9]+$ ]] || \
      die "malformed stock-A logical extent record"
    first_extent_end["$partition"]=$extent_end
  done < <(
    awk '
      /^  Name: / { partition = $2; next }
      partition != "" && /^    [0-9]+ \.\. [0-9]+ / {
        print partition, $3
        partition = ""
      }
    ' <<<"$lpdump_output"
  )
  for partition in system system_dlkm system_ext product vendor vendor_dlkm; do
    [[ -n "${first_extent_end[${partition}_a]+present}" && \
       "${first_extent_end[${partition}_a]}" =~ ^[1-9][0-9]*$ ]] || \
      die "restored stock-A logical partition is absent or empty: ${partition}_a"
  done
  runtime_stock_bootloader=$bootloader
  runtime_stock_baseband=$runtime_expected_baseband
  note "verified exact stock $STOCK_BUILD_ID runtime on slot A without an active update"
}

verify_stock_android_restore_evidence() {
  local handoff_present='' lineage_present='' lineage_sha
  local -A lineage=()

  find_single_stock_adb
  load_restore_transaction_receipt "$stock_adb_serial"
  [[ "$restore_transaction_state" =~ ^(awaiting_stock_android|boot_control_pending|retiring_evidence)$ ]] || \
    die "stock Android finalization requires an awaiting, boot-control, or retiring receipt"
  if [[ -e "$cubs_recovery_lineage" || -L "$cubs_recovery_lineage" ]]; then
    cubs_private_file "$cubs_recovery_lineage"
    lineage_present=1
  fi
  if [[ -e "$cubs_recovery_handoff" || -L "$cubs_recovery_handoff" ]]; then
    cubs_private_file "$cubs_recovery_handoff"
    handoff_present=1
  fi
  if [[ "$restore_transaction_state" =~ ^(awaiting_stock_android|boot_control_pending)$ ]]; then
    [[ -n "$lineage_present" && -n "$handoff_present" ]] || \
      die "active recovery evidence disappeared before retirement was journaled"
  fi
  if [[ -n "$lineage_present" ]]; then
    lineage_sha=$(sha256sum "$cubs_recovery_lineage" | awk '{print $1}')
    [[ "$lineage_sha" == "$restore_transaction_lineage_sha256" ]] || \
      die "recovery lineage differs from the completed restore transaction"
    cubs_verify_lifeboat_lineage "$stock_adb_serial" \
      "$restore_transaction_physical_b_sizes_sha256" \
      "$runtime_stock_bootloader" "$runtime_stock_baseband"
    [[ "$cubs_verified_lineage_sha256" == \
         "$restore_transaction_lineage_sha256" && \
       "$cubs_verified_stock_b_source" == "$restore_transaction_stock_b_source" && \
       "$cubs_verified_stock_b_provenance_sha256" == \
         "$restore_transaction_stock_b_provenance_sha256" ]] || \
      die "active recovery lineage differs from the completed restore transaction"
  fi
  if [[ -n "$handoff_present" ]]; then
    [[ $(sha256sum "$cubs_recovery_handoff" | awk '{print $1}') == \
         "$restore_transaction_handoff_sha256" ]] || \
      die "active recovery handoff differs from the completed restore transaction"
    if [[ -n "$lineage_present" ]]; then
      cubs_verify_lifeboat_handoff_for_recovery \
        "$restore_transaction_physical_b_sizes_sha256"
      [[ "$cubs_verified_recovery_handoff_sha256" == \
           "$restore_transaction_handoff_sha256" ]] || \
        die "active recovery handoff differs from the completed restore transaction"
    elif [[ "$restore_transaction_state" != retiring_evidence ]]; then
      die "recovery handoff cannot be verified without its active lineage"
    fi
  fi
  if [[ "$restore_transaction_state" != retiring_evidence ]]; then
    verify_restore_flash_abort_adoption "$stock_adb_serial" \
      "$restore_transaction_physical_b_sizes_sha256"
    [[ "$verified_restore_adopted_flash_transaction_sha256" == \
         "$restore_transaction_adopted_flash_transaction_sha256" && \
       "$verified_restore_adopted_flash_serial_binding_sha256" == \
         "$restore_transaction_adopted_flash_serial_binding_sha256" && \
       "$verified_restore_adopted_runtime_attestation_sha256" == \
         "$restore_transaction_adopted_runtime_attestation_sha256" ]] || \
      die "adopted flash-abort evidence differs from the restore receipt"
  fi
}

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

wait_for_stock_a_bootloader() {
  local attempt record
  local -a records=()

  for ((attempt = 1; attempt <= 90; attempt += 1)); do
    mapfile -t records < <("$fastboot_bin" devices 2>/dev/null | \
      awk 'NF {print $1}')
    if (( ${#records[@]} == 1 )); then
      record=${records[0]}
      [[ "$record" != -* && ! "$record" =~ [[:space:]] ]] || \
        die "invalid fastboot serial after stock-A reboot"
      stock_fastboot_serial=$record
      return 0
    fi
    if (( ${#records[@]} > 0 )); then
      die "an unexpected or additional fastboot device appeared during stock-A transition"
    fi
    sleep 1
  done
  die "timed out waiting for restored stock A in bootloader fastboot"
}

verify_stock_a_fastboot_retirement_gate() {
  local actual_binding actual_sha baseband bootloader current_slot fetched
  local fetched_size_hex partition physical_sizes product slot_a_successful
  local slot_a_unbootable slot_b_unbootable slot_count snapshot_status target_size
  local unlocked userspace

  device_serial=$stock_fastboot_serial
  fastboot_command=("$fastboot_bin" -s "$device_serial")
  load_restore_transaction_receipt "$device_serial"
  [[ "$restore_transaction_state" == boot_control_pending ]] || \
    die "stock-restore state changed during the ADB-to-bootloader transition"
  actual_binding=$(cubs_serial_binding "$restore_transaction_id" \
    "$stock_fastboot_serial")
  [[ "$actual_binding" == "$restore_transaction_serial_binding" ]] || \
    die "bootloader transport is not the stock Android device audited before reboot"

  product=$(fastboot_value product)
  bootloader=$(fastboot_value version-bootloader)
  baseband=$(fastboot_value version-baseband)
  unlocked=$(fastboot_value unlocked)
  userspace=$(fastboot_value is-userspace)
  current_slot=$(fastboot_value current-slot)
  slot_count=$(fastboot_value slot-count)
  snapshot_status=$(fastboot_value snapshot-update-status)
  slot_a_successful=$(fastboot_value slot-successful:a)
  slot_a_unbootable=$(fastboot_value slot-unbootable:a)
  slot_b_unbootable=$(fastboot_value slot-unbootable:b)
  [[ "$product" == "$DEVICE_CODENAME" && \
     "$bootloader" == "$runtime_stock_bootloader" && \
     "$baseband" == "$runtime_stock_baseband" && \
     "$unlocked" == yes && "$userspace" == no && \
     "$current_slot" == a && "$slot_count" == 2 && \
     "$snapshot_status" == none && \
     "$slot_a_successful" == yes && "$slot_a_unbootable" == no && \
     "$slot_b_unbootable" == no ]] || \
    die "restored stock A lacks exact successful boot-control proof"

  for partition in "${cubs_preserved_b_partitions[@]}"; do
    [[ $(fastboot_value "has-slot:$partition") == yes && \
       $(fastboot_value "is-logical:${partition}_a") == no && \
       $(fastboot_value "is-logical:${partition}_b") == no ]] || \
      die "recovery partition is no longer an explicit physical A/B pair: $partition"
  done
  physical_sizes=$(cubs_physical_b_sizes_sha256)
  [[ "$physical_sizes" == "$restore_transaction_physical_b_sizes_sha256" ]] || \
    die "physical slot-B lifeboat sizes changed before evidence retirement"

  cubs_verify_lifeboat_lineage "$device_serial" "$physical_sizes" \
    "$runtime_stock_bootloader" "$runtime_stock_baseband"
  [[ "$cubs_verified_lineage_sha256" == \
       "$restore_transaction_lineage_sha256" && \
     "$cubs_verified_stock_b_source" == "$restore_transaction_stock_b_source" && \
     "$cubs_verified_stock_b_provenance_sha256" == \
       "$restore_transaction_stock_b_provenance_sha256" ]] || \
    die "recovery lineage differs after the stock-A bootloader transition"
  cubs_verify_lifeboat_handoff_for_recovery "$physical_sizes"
  [[ "$cubs_verified_recovery_handoff_sha256" == \
       "$restore_transaction_handoff_sha256" ]] || \
    die "recovery handoff differs after the stock-A bootloader transition"
  verify_restore_flash_abort_adoption "$device_serial" "$physical_sizes"
  [[ "$verified_restore_adopted_flash_transaction_sha256" == \
       "$restore_transaction_adopted_flash_transaction_sha256" && \
     "$verified_restore_adopted_flash_serial_binding_sha256" == \
       "$restore_transaction_adopted_flash_serial_binding_sha256" && \
     "$verified_restore_adopted_runtime_attestation_sha256" == \
       "$restore_transaction_adopted_runtime_attestation_sha256" ]] || \
    die "adopted flash-abort evidence changed before retirement"

  fetched=$(mktemp "$cubs_recovery_state_dir/.stock-finalize-vendor-boot.XXXXXX")
  rm -f -- "$fetched"
  "${fastboot_command[@]}" fetch vendor_boot_b "$fetched"
  [[ -f "$fetched" && ! -L "$fetched" && \
     $(stat -c '%u' "$fetched") == "$EUID" && \
     $(stat -c '%h' "$fetched") == 1 ]] || \
    die "stock-finalization vendor_boot_b fetch is unsafe"
  target_size=$(cubs_normalize_partition_size \
    "$(fastboot_value partition-size:vendor_boot_b)")
  fetched_size_hex=$(printf '%x' "$(stat -c '%s' "$fetched")")
  [[ "$fetched_size_hex" == "$target_size" ]] || {
    rm -f -- "$fetched"
    die "stock-finalization vendor_boot_b fetch is not full-size"
  }
  actual_sha=$(sha256sum "$fetched" | awk '{print $1}')
  rm -f -- "$fetched"
  [[ "$actual_sha" == "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || \
    die "stock-finalization vendor_boot_b bytes differ from the exact pin"
}

transition_verified_stock_a_to_bootloader() {
  local adb_reboot_status=0

  select_pinned_restore_fastboot
  timeout 20 "$adb_bin" -s "$stock_adb_serial" reboot bootloader || \
    adb_reboot_status=$?
  if (( adb_reboot_status != 0 )); then
    note "ADB reboot returned $adb_reboot_status; checking for a completed bootloader transition"
  fi
  wait_for_stock_a_bootloader
  verify_stock_a_fastboot_retirement_gate
}

rewrite_restore_receipt_state() {
  local expected_state=$1 new_state=$2 serial=$3 current_sha temporary
  [[ "$expected_state" =~ ^(awaiting_stock_android|boot_control_pending)$ && \
     "$new_state" =~ ^(boot_control_pending|retiring_evidence)$ ]] || \
    die "invalid stock-restore finalization transition"
  [[ "$restore_transaction_state" == "$expected_state" ]] || \
    die "stock-restore finalization state changed unexpectedly"
  cubs_private_file "$restore_transaction_receipt"
  current_sha=$(sha256sum "$restore_transaction_receipt" | awk '{print $1}')
  [[ "$current_sha" == "$loaded_restore_transaction_sha256" ]] || \
    die "stock-restore receipt changed before finalization transition"
  temporary=$(mktemp "$cubs_recovery_state_dir/.stock-restore-finalize.XXXXXX")
  awk -v expected="state=$expected_state" -v replacement="state=$new_state" '
    $0 == expected { print replacement; changed += 1; next }
    { print }
    END { if (changed != 1) exit 1 }
  ' "$restore_transaction_receipt" >"$temporary" || {
    rm -f -- "$temporary"
    die "unable to journal stock-restore finalization transition"
  }
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$restore_transaction_receipt"
  cubs_private_file "$restore_transaction_receipt"
  load_restore_transaction_receipt "$serial"
  [[ "$restore_transaction_state" == "$new_state" ]] || \
    die "stock-restore finalization transition was not published"
}

promote_restore_receipt_boot_control_pending() {
  rewrite_restore_receipt_state awaiting_stock_android boot_control_pending \
    "$stock_adb_serial"
}

promote_restore_receipt_retiring() {
  local serial=${1:-$device_serial}
  rewrite_restore_receipt_state boot_control_pending retiring_evidence "$serial"
}

resume_committed_evidence_retirement() {
  local path expected_sha

  load_restore_transaction_receipt
  [[ "$restore_transaction_state" == retiring_evidence ]] || \
    die "host-only retirement resume requires its committed receipt"
  for path in "$cubs_recovery_lineage" "$cubs_recovery_handoff"; do
    if [[ -e "$path" || -L "$path" ]]; then
      cubs_private_file "$path"
      if [[ "$path" == "$cubs_recovery_lineage" ]]; then
        expected_sha=$restore_transaction_lineage_sha256
      else
        expected_sha=$restore_transaction_handoff_sha256
      fi
      [[ $(sha256sum "$path" | awk '{print $1}') == "$expected_sha" ]] || \
        die "remaining recovery evidence differs from the committed retirement"
    fi
  done
  archive_adopted_restore_sources
  cubs_invalidate_recovery_handoff
  archive_restore_transaction_receipt
  note "completed the already committed recovery-evidence retirement"
}

resume_boot_control_pending() {
  local adb_records

  load_exact_stock_runtime_requirements
  runtime_stock_bootloader=$runtime_expected_bootloader
  runtime_stock_baseband=$runtime_expected_baseband
  select_pinned_restore_fastboot
  select_pinned_stock_adb
  adb_records=$("$adb_bin" devices | awk 'NR > 1 && NF >= 2 {count += 1} END {print count + 0}') || \
    die "unable to inspect ADB while resuming stock boot-control verification"
  if (( adb_records > 0 )); then
    # If Android never left (or was booted again after a failed success-bit
    # check), repeat the full exact runtime and evidence audits before reboot.
    audit_exact_stock_a_runtime
    verify_stock_android_restore_evidence
    transition_verified_stock_a_to_bootloader
  else
    wait_for_stock_a_bootloader
    verify_stock_a_fastboot_retirement_gate
  fi
  promote_restore_receipt_retiring "$device_serial"
  archive_adopted_restore_sources
  cubs_invalidate_recovery_handoff
  archive_restore_transaction_receipt
  note "completed stock-A boot-control verification and recovery-evidence retirement"
  note "the exact successful stock A remains selected in bootloader fastboot"
}

confirm_stock_android_finalization() {
  local entered
  [[ -t 0 && -t 1 ]] || \
    die "refusing recovery-evidence retirement without an interactive terminal"
  printf '\nType exactly: %s\n> ' "$expected_confirmation" >/dev/tty
  IFS= read -r entered </dev/tty
  [[ "$entered" == "$expected_confirmation" ]] || \
    die "confirmation phrase did not match"
}

finalize_stock_android_restore() {
  cubs_lock_recovery_state
  require_no_conflicting_recovery_transaction
  if [[ -e "$restore_transaction_receipt" || \
        -L "$restore_transaction_receipt" ]]; then
    cubs_private_file "$restore_transaction_receipt"
    if grep -Fxq 'state=retiring_evidence' "$restore_transaction_receipt"; then
      # The atomic retiring state is published only after both exact stock-A
      # runtime audits and the post-TTY evidence verification. Cleanup after
      # that semantic commit is host-only and idempotent, so a later ADB loss
      # cannot strand a partially removed evidence set.
      resume_committed_evidence_retirement
      return
    fi
    if grep -Fxq 'state=boot_control_pending' \
        "$restore_transaction_receipt"; then
      # Both interactive stock-Android audits were committed before the reboot.
      # Resume from Android (reaudit, then reboot) or from the same fastboot
      # transport (verify success bits) without weakening either gate.
      resume_boot_control_pending
      return
    fi
  fi
  audit_exact_stock_a_runtime
  verify_stock_android_restore_evidence
  confirm_stock_android_finalization

  # Repeat the dedicated post-restore stock-A audit, salted transport binding,
  # transaction, lineage, and handoff validation after the TTY pause. Unlike
  # anchor issuance, this audit deliberately does not require A/B logical views
  # to alias: restoring A reallocates those shared-super extents.
  audit_exact_stock_a_runtime
  verify_stock_android_restore_evidence
  # Publish this checkpoint before the ADB reboot. It is not retirement
  # authority: only the following pinned-fastboot success-bit audit can advance
  # it to retiring_evidence.
  promote_restore_receipt_boot_control_pending
  transition_verified_stock_a_to_bootloader
  promote_restore_receipt_retiring "$device_serial"
  archive_adopted_restore_sources
  cubs_invalidate_recovery_handoff
  archive_restore_transaction_receipt
  note "retired recovery evidence only after exact restored stock A booted successfully"
}

if [[ "$action" == finalize-stock-android ]]; then
  finalize_stock_android_restore
  exit 0
fi

if [[ -n "${CUBS_FASTBOOT_SERIAL:-}" && -n "${ANDROID_SERIAL:-}" && \
      "$CUBS_FASTBOOT_SERIAL" != "$ANDROID_SERIAL" ]]; then
  die "CUBS_FASTBOOT_SERIAL and ANDROID_SERIAL select different devices"
fi
device_serial=${CUBS_FASTBOOT_SERIAL:-${ANDROID_SERIAL:-}}
[[ -n "$device_serial" ]] || die \
  "select the phone explicitly with CUBS_FASTBOOT_SERIAL"
[[ "$device_serial" != -* && ! "$device_serial" =~ [[:space:]] ]] || \
  die "invalid fastboot serial"

select_pinned_restore_fastboot
fastboot_command=("$fastboot_bin" -s "$device_serial")

logical_partitions=(
  system
  system_dlkm
  system_ext
  product
  vendor
  vendor_dlkm
)
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
      die "logical sparse image has an invalid header: ${image##*/}"
    expanded_size=$((10#$block_size * 10#$total_blocks))
  else
    expanded_size=$(stat -c '%s' "$image")
  fi
  [[ "$expanded_size" =~ ^[1-9][0-9]*$ && \
     $((expanded_size % 4096)) -eq 0 ]] || \
    die "logical image has an invalid expanded size: ${image##*/}"
  printf '%s\n' "$expanded_size"
}
firmware_partitions=(
  abl
  bl31
  cap
  cpm
  dbc
  dbl
  dram_init_0
  dram_init_1
  dram_init_2
  dram_init_3
  dram_init_4
  dram_init_5
  dram_init_6
  dram_init_7
  dram_init_8
  dram_init_9
  dram_init_10
  dram_init_11
  dram_phy
  gc
  gdmc
  gsa_bl1
  gsa_fw
  tzsw
  modem
)
early_physical_partitions=(
  "${firmware_partitions[@]}"
  boot
  init_boot
  dtbo
  vendor_boot
  vendor_kernel_boot
  pvmfw
)
vbmeta_partitions=(vbmeta_system vbmeta_vendor vbmeta)
preserved_b_physical_partitions=(
  "${early_physical_partitions[@]}"
  "${vbmeta_partitions[@]}"
)
stock_image_files=()
for partition in "${logical_partitions[@]}" \
    "${preserved_b_physical_partitions[@]}"; do
  stock_image_files+=("$partition.img")
done

factory_image="$project_root/downloads/$FACTORY_IMAGE_FILENAME"
verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"
"$script_dir/extract-stock.sh"
stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
stock_images="$stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
require_file "$stock_images"
[[ ! -L "$stock_images" ]] || die "refusing a symlinked stock image archive"

stock_archive_entries=$(unzip -Z1 "$stock_images")
for image_name in android-info.txt "${stock_image_files[@]}"; do
  entry_count=$(grep -Fxc -- "$image_name" <<<"$stock_archive_entries" || true)
  (( entry_count == 1 )) || die \
    "stock archive must contain exactly one root entry named $image_name"
done
stock_android_info=$(unzip -p "$stock_images" android-info.txt) || \
  die "stock image package has no android-info.txt"
expected_board=$(sed -n 's/^require board=//p' <<<"$stock_android_info")
expected_bootloader=$(sed -n 's/^require version-bootloader=//p' <<<"$stock_android_info")
expected_baseband=$(sed -n 's/^require version-baseband=//p' <<<"$stock_android_info")
[[ "|$expected_board|" == *"|$DEVICE_CODENAME|"* ]] || \
  die "stock image package does not allow product $DEVICE_CODENAME"
[[ $(grep -c '^require board=' <<<"$stock_android_info") -eq 1 && \
   $(grep -c '^require version-bootloader=' <<<"$stock_android_info") -eq 1 && \
   $(grep -c '^require version-baseband=' <<<"$stock_android_info") -eq 1 ]] || \
  die "stock image package has malformed firmware requirements"
[[ -n "$expected_bootloader" && -n "$expected_baseband" ]] || \
  die "stock image package has empty firmware requirements"

restore_parent="$project_root/work/restore-stock"
assert_inside_work "$restore_parent"
mkdir -p "$restore_parent"
restore_dir=$(mktemp -d "$restore_parent/.images.XXXXXX")
shared_super_modified=
slot_b_activation_attempted=
activation_finalization_attempted=
slot_a_activated=
cleanup() {
  local status=$? journaled_restore_risk=
  trap - EXIT
  if [[ -n "${restore_dir:-}" && -d "$restore_dir" && \
        "$restore_dir" == "$restore_parent"/.images.* ]]; then
    rm -rf -- "$restore_dir"
  fi
  if [[ -f "$restore_transaction_receipt" && \
        ! -L "$restore_transaction_receipt" ]] && \
      grep -Eq '^state=(select_b_pending|enter_b_fastbootd_pending|pivot_a_metadata_pending|restoring_logicals|return_bootloader_pending|restoring_physical|activate_a_pending)$' \
        "$restore_transaction_receipt"; then
    journaled_restore_risk=1
  fi
  if (( status != 0 )) && \
      [[ ( -n "$shared_super_modified" || \
           -n "$slot_b_activation_attempted" || \
           -n "$activation_finalization_attempted" || \
           -n "$journaled_restore_risk" ) && \
         -z "$slot_a_activated" ]]; then
    printf '%s\n' \
      'WARNING: restore stopped after a slot-selection mutation may have started or' \
      'shared-super slot-A metadata was modified.' \
      'Slot-B Android is not a valid fallback. Keep the phone in bootloader/fastbootd;' \
      'rerun the journaled restore; physical slot B remains the recovery lifeboat.' >&2
  fi
  exit "$status"
}
trap cleanup EXIT

note "extracting the exact allowlisted stock A images into ignored work storage"
unzip -q "$stock_images" "${stock_image_files[@]}" -d "$restore_dir"
for image_name in "${stock_image_files[@]}"; do
  [[ -f "$restore_dir/$image_name" && ! -L "$restore_dir/$image_name" && \
     -s "$restore_dir/$image_name" ]] || \
    die "unsafe or empty extracted stock image: $image_name"
done
declare -A expected_stock_logical_sizes=()
for partition in "${logical_partitions[@]}"; do
  expanded_size=$(logical_image_expanded_size "$restore_dir/$partition.img")
  expected_stock_logical_sizes["$partition"]=$(printf '%x' "$expanded_size")
done

assert_single_selected_device() {
  local output
  local -a devices=()
  select_pinned_restore_fastboot
  output=$("$fastboot_bin" devices) || \
    die "unable to enumerate fastboot devices"
  mapfile -t devices < <(awk 'NF {print $1}' <<<"$output")
  (( ${#devices[@]} == 1 )) || \
    die "expected exactly one fastboot device; found ${#devices[@]}"
  [[ "${devices[0]}" == "$device_serial" ]] || \
    die "the explicitly selected phone is not the sole fastboot device"
}

wait_for_selected_device() {
  local attempt
  local -a devices=()
  for ((attempt = 1; attempt <= 90; attempt += 1)); do
    mapfile -t devices < <("$fastboot_bin" devices 2>/dev/null | awk 'NF {print $1}')
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
  local partition=$1
  local size
  size=$(fastboot_value "partition-size:$partition")
  [[ "$size" =~ ^(0[xX])?[0-9a-fA-F]+$ && \
     "$size" =~ [1-9a-fA-F] ]] || \
    die "unable to prove a nonzero partition size for $partition"
  printf '%s\n' "$size"
}

require_zero_partition_size() {
  local partition=$1
  local size
  size=$(fastboot_value "partition-size:$partition")
  [[ "$size" =~ ^(0[xX])?0+$ ]] || \
    die "$partition did not resize to zero; reported ${size:-unknown}"
}

require_slotted_partition() {
  local partition=$1
  [[ $(fastboot_value "has-slot:$partition") == yes ]] || \
    die "$partition is not reported slotted; refusing an unsuffixed/global write"
}

require_physical_pair() {
  local partition=$1
  require_slotted_partition "$partition"
  [[ $(fastboot_value "is-logical:${partition}_a") == no && \
     $(fastboot_value "is-logical:${partition}_b") == no ]] || \
    die "$partition is not reported as a physical A/B partition"
}

partition_size_kind() {
  local value=${1:-}
  if [[ "$value" =~ ^(0[xX])?0+$ ]]; then
    printf 'zero\n'
  elif [[ "$value" =~ ^(0[xX])?[0-9a-fA-F]+$ && \
          "$value" =~ [1-9a-fA-F] ]]; then
    printf 'nonzero\n'
  else
    printf 'invalid\n'
  fi
}

declare -A logical_a_size_kind=()
declare -A logical_b_size_kind=()
fastboot_yes_no_value() {
  local variable=$1 failed_count output status=0 value value_count
  local -a values=()
  output=$("${fastboot_command[@]}" getvar "$variable" 2>&1) || status=$?
  mapfile -t values < <(
    sed -nE \
      "s/^(\(bootloader\)[[:space:]]*)?$variable:[[:space:]]*//p" \
      <<<"$output"
  )
  value_count=${#values[@]}
  value=${values[0]:-}
  failed_count=$(grep -o 'FAILED' <<<"$output" | wc -l || true)
  [[ $status -eq 0 && $value_count -eq 1 && \
     "$value" =~ ^(yes|no)$ && $failed_count -eq 0 ]] || \
    die "ambiguous yes/no fastboot probe for $variable"
  printf '%s\n' "$value"
}

logical_partition_presence() {
  local partition=$1 failure_line_count failed_count output status=0 value
  local value_count
  local -a values=()
  [[ "$partition" =~ ^[a-z0-9_]+$ ]] || \
    die "unsafe logical-partition probe name"
  output=$("${fastboot_command[@]}" getvar "is-logical:$partition" 2>&1) || \
    status=$?
  mapfile -t values < <(
    sed -nE \
      "s/^(\(bootloader\)[[:space:]]*)?is-logical:$partition:[[:space:]]*//p" \
      <<<"$output"
  )
  value_count=${#values[@]}
  value=${values[0]:-}
  failed_count=$(grep -o 'FAILED' <<<"$output" | wc -l || true)
  if (( status == 0 && value_count == 1 && failed_count == 0 )) && \
      [[ "$value" == yes ]]; then
    printf 'present\n'
  elif (( status == 0 && value_count == 1 && failed_count == 0 )) && \
      [[ "$value" == no ]]; then
    printf 'not-logical\n'
  else
    failure_line_count=$(grep -Ec \
      "^getvar:is-logical:${partition}[[:space:]]+FAILED \\(remote: 'Partition not found'\\)$" \
      <<<"$output" || true)
    if (( status == 0 && failure_line_count == 1 && failed_count == 1 )) && \
        (( value_count == 0 )); then
    # Cub's stock fastbootd returns FAILED/empty for a logical name absent from
    # the selected unslotted-super metadata table, while pinned fastboot 37.0.1
    # still exits zero. Treat no other transport or parse failure as absence.
      printf 'absent\n'
    else
      die "ambiguous logical-partition probe for $partition"
    fi
  fi
}

inspect_fastbootd_logical_namespace() {
  local partition has_slot has_slot_mode='' unsuffixed_logical
  local a_logical b_logical a_size b_size
  local a_only_count=0 b_only_count=0 invalid_count=0

  logical_a_size_kind=()
  logical_b_size_kind=()
  for partition in "${logical_partitions[@]}"; do
    has_slot=$(fastboot_yes_no_value "has-slot:$partition")
    if [[ -z "$has_slot_mode" ]]; then
      has_slot_mode=$has_slot
    else
      [[ "$has_slot" == "$has_slot_mode" ]] || \
        die "fastbootd logical bases report mixed has-slot values"
    fi
    if [[ "$has_slot" == no ]]; then
      unsuffixed_logical=$(logical_partition_presence "$partition")
      [[ "$unsuffixed_logical" == absent ]] || \
        die "fastbootd exposes or ambiguously describes unsuffixed logical partition $partition"
    fi
    a_logical=$(logical_partition_presence "${partition}_a")
    b_logical=$(logical_partition_presence "${partition}_b")
    case "$a_logical:$b_logical" in
      present:absent)
        a_size=$(fastboot_value "partition-size:${partition}_a")
        logical_a_size_kind["$partition"]=$(partition_size_kind "$a_size")
        logical_b_size_kind["$partition"]=absent
        if [[ "${logical_a_size_kind[$partition]}" == invalid ]]; then
          ((invalid_count += 1))
        else
          ((a_only_count += 1))
        fi
        ;;
      absent:present)
        b_size=$(fastboot_value "partition-size:${partition}_b")
        logical_a_size_kind["$partition"]=absent
        logical_b_size_kind["$partition"]=$(partition_size_kind "$b_size")
        if [[ "${logical_b_size_kind[$partition]}" == nonzero ]]; then
          ((b_only_count += 1))
        else
          ((invalid_count += 1))
        fi
        ;;
      *)
        logical_a_size_kind["$partition"]=invalid
        logical_b_size_kind["$partition"]=invalid
        ((invalid_count += 1))
        ;;
    esac
  done

  if (( invalid_count == 0 && a_only_count == ${#logical_partitions[@]} )); then
    logical_namespace=a_only
  elif (( invalid_count == 0 && b_only_count == ${#logical_partitions[@]} )); then
    logical_namespace=b_only
  else
    logical_namespace=mixed
  fi
}

require_reconciled_a_namespace() {
  local partition
  inspect_fastbootd_logical_namespace
  [[ "$logical_namespace" == a_only ]] || \
    die "fastbootd exposes an irreconcilable $logical_namespace logical namespace"
  for partition in "${logical_partitions[@]}"; do
    [[ "${logical_a_size_kind[$partition]}" =~ ^(zero|nonzero)$ ]] || \
      die "unable to classify exact zero/nonzero state for ${partition}_a"
  done
}

require_global_wipe_partition() {
  local partition=$1
  [[ $(fastboot_value "has-slot:$partition") == no ]] || \
    die "$partition unexpectedly reports slotting; refusing the global wipe"
  require_nonzero_partition_size "$partition" >/dev/null
}

check_bootloader_identity() {
  local baseband bootloader product slot_count snapshot_status unlocked userspace
  product=$(fastboot_value product)
  bootloader=$(fastboot_value version-bootloader)
  baseband=$(fastboot_value version-baseband)
  unlocked=$(fastboot_value unlocked)
  userspace=$(fastboot_value is-userspace)
  slot_count=$(fastboot_value slot-count)
  snapshot_status=$(fastboot_value snapshot-update-status)
  [[ "$product" == "$DEVICE_CODENAME" ]] || \
    die "expected product $DEVICE_CODENAME; found ${product:-unknown}"
  [[ "$bootloader" == "$expected_bootloader" ]] || \
    die "bootloader mismatch: expected $expected_bootloader; found ${bootloader:-unknown}"
  [[ "$baseband" == "$expected_baseband" ]] || \
    die "baseband mismatch: expected $expected_baseband; found ${baseband:-unknown}"
  [[ "$unlocked" == yes ]] || die "device bootloader is not unlocked"
  [[ "$userspace" == no ]] || die "operation must start in bootloader fastboot"
  [[ "$slot_count" == 2 ]] || \
    die "expected two boot slots; found ${slot_count:-unknown}"
  [[ "$snapshot_status" == none ]] || \
    die "snapshot update status must be none; found ${snapshot_status:-unknown}"
}

check_restore_boot_control() {
  local expected_slot=$1
  local current_slot slot_a_successful slot_a_unbootable
  local slot_b_successful slot_b_unbootable
  current_slot=$(fastboot_value current-slot)
  slot_a_successful=$(fastboot_value slot-successful:a)
  slot_a_unbootable=$(fastboot_value slot-unbootable:a)
  slot_b_successful=$(fastboot_value slot-successful:b)
  slot_b_unbootable=$(fastboot_value slot-unbootable:b)
  [[ "$expected_slot" =~ ^(a|b)$ && "$current_slot" == "$expected_slot" ]] || die \
    "restore expected current slot $expected_slot; found ${current_slot:-unknown}"
  [[ "$slot_b_successful" =~ ^(yes|no)$ ]] || \
    die "slot B has an unreadable successful flag"
  [[ "$slot_b_unbootable" == no ]] || \
    die "slot B is marked unbootable; refusing to risk the fastbootd lifeboat"
  [[ "$slot_a_successful" =~ ^(yes|no)$ && \
     "$slot_a_unbootable" =~ ^(yes|no)$ ]] || \
    die "slot A boot-control flags are unreadable"
}

check_battery() {
  local battery_soc battery_number
  battery_soc=$(fastboot_value battery-soc)
  battery_number=$(tr -d '[:space:]%' <<<"$battery_soc")
  [[ "$battery_number" =~ ^[0-9]+$ ]] || \
    die "unable to read battery state of charge"
  (( battery_number >= 50 )) || \
    die "battery must be at least 50%; found $battery_soc"
}

verify_live_vendor_boot_b_control() {
  local actual_sha fetched size_hex target_size
  fetched=$(mktemp "$restore_dir/.vendor-boot-b-fetch.XXXXXX")
  rm -f -- "$fetched"
  "${fastboot_command[@]}" fetch vendor_boot_b "$fetched"
  [[ -f "$fetched" && ! -L "$fetched" && \
     $(stat -c '%u' "$fetched") == "$EUID" && \
     $(stat -c '%h' "$fetched") == 1 ]] || \
    die "live vendor_boot_b fetch is unsafe"
  target_size=$(cubs_normalize_partition_size \
    "$(fastboot_value partition-size:vendor_boot_b)")
  size_hex=$(printf '%x' "$(stat -c '%s' "$fetched")")
  [[ "$size_hex" == "$target_size" ]] || \
    die "live vendor_boot_b fetch does not cover its full physical partition"
  actual_sha=$(sha256sum "$fetched" | awk '{print $1}')
  rm -f -- "$fetched"
  [[ "$actual_sha" == "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || \
    die "live vendor_boot_b bytes differ from the exact stock lifeboat pin"
}

check_fastbootd_identity() {
  local baseband bootloader current_slot product slot_count snapshot_status
  local unlocked userspace
  product=$(fastboot_value product)
  bootloader=$(fastboot_value version-bootloader)
  baseband=$(fastboot_value version-baseband)
  unlocked=$(fastboot_value unlocked)
  userspace=$(fastboot_value is-userspace)
  slot_count=$(fastboot_value slot-count)
  snapshot_status=$(fastboot_value snapshot-update-status)
  current_slot=$(fastboot_value current-slot)
  [[ "$product" == "$DEVICE_CODENAME" && \
     "$bootloader" == "$expected_bootloader" && \
     "$baseband" == "$expected_baseband" && \
     "$unlocked" == yes && "$userspace" == yes && \
     "$slot_count" == 2 && "$snapshot_status" == none ]] || \
    die "fastbootd identity, firmware, lock, slot, or snapshot state is unsafe"
  [[ "$current_slot" =~ ^(a|b)$ ]] || \
    die "fastbootd reports an invalid current slot"
  check_restore_boot_control "$current_slot"
  fastbootd_current_slot=$current_slot
}

declare -A lifeboat_b_sizes=()
capture_b_lifeboat() {
  local partition
  for partition in "${preserved_b_physical_partitions[@]}"; do
    require_physical_pair "$partition"
    require_nonzero_partition_size "${partition}_a" >/dev/null
    lifeboat_b_sizes["$partition"]=$(
      require_nonzero_partition_size "${partition}_b"
    )
  done
  note "verified nonzero, slotted A/B firmware and boot/recovery partitions"
}

verify_b_lifeboat() {
  local current_size current_slot partition
  current_slot=$(fastboot_value current-slot)
  check_restore_boot_control "$current_slot"
  require_restore_b_success "$(fastboot_value slot-successful:b)"
  for partition in "${preserved_b_physical_partitions[@]}"; do
    require_physical_pair "$partition"
    current_size=$(require_nonzero_partition_size "${partition}_b")
    [[ "$current_size" == "${lifeboat_b_sizes[$partition]}" ]] || \
      die "slot-B physical partition size changed unexpectedly: ${partition}_b"
  done
  verify_full_restore_evidence
  require_receipt_matches_restore_evidence
}

flash_stock_physical_a() {
  local partition=$1
  require_physical_pair "$partition"
  require_nonzero_partition_size "${partition}_a" >/dev/null
  note "flashing exact stock physical partition ${partition}_a"
  "${fastboot_command[@]}" flash "${partition}_a" \
    "$restore_dir/$partition.img"
  require_nonzero_partition_size "${partition}_a" >/dev/null
}

require_restore_b_success() {
  local value=$1
  local -A handoff=()
  if [[ "$cubs_verified_stock_b_source" == full_ota && "$value" == no ]]; then
    cubs_load_exact_kv "$cubs_recovery_handoff" handoff \
      schema state handoff_kind created_epoch expires_epoch claimed_epoch \
      anchor_id serial_binding_sha256 lineage_sha256 physical_b_sizes_sha256 \
      recovery_policy_sha256 bundle_kind bundle_manifest_sha256
    if [[ "${handoff[handoff_kind]}" != physical_b_lifeboat ]]; then
      [[ "${restore_transaction_state:-}" =~ \
           ^(select_b_pending|enter_b_fastbootd_pending|pivot_a_metadata_pending|restoring_logicals|return_bootloader_pending|restoring_physical|activate_a_pending|awaiting_stock_android)$ && \
         "${restore_transaction_handoff_sha256:-}" == \
           "$cubs_verified_recovery_handoff_sha256" ]] || \
        die "full-OTA stock_b_anchor requires B successful=yes before a journaled restore activation"
    fi
  else
    cubs_require_verified_lineage_b_success "$value"
  fi
}

verify_full_restore_evidence() {
  local physical_b_sizes_sha256
  physical_b_sizes_sha256=$(cubs_physical_b_sizes_sha256)
  cubs_verify_lifeboat_lineage "$device_serial" "$physical_b_sizes_sha256" \
    "$expected_bootloader" "$expected_baseband"
  cubs_verify_lifeboat_handoff_for_recovery "$physical_b_sizes_sha256"
  require_restore_b_success "$(fastboot_value slot-successful:b)"
  verified_restore_physical_b_sizes_sha256=$physical_b_sizes_sha256
  verified_restore_lineage_sha256=$cubs_verified_lineage_sha256
  verified_restore_handoff_sha256=$cubs_verified_recovery_handoff_sha256
  verified_restore_stock_b_source=$cubs_verified_stock_b_source
  verified_restore_stock_b_provenance_sha256=$cubs_verified_stock_b_provenance_sha256
  verify_restore_flash_abort_adoption "$device_serial" \
    "$physical_b_sizes_sha256"
}

verify_fastbootd_journaled_b_evidence() {
  local physical_b_sizes_sha256

  [[ "${restore_transaction_state:-}" =~ \
       ^(enter_b_fastbootd_pending|pivot_a_metadata_pending|restoring_logicals|return_bootloader_pending)$ ]] || \
    die "fastbootd recovery lacks a journaled bootloader-B verification state"
  physical_b_sizes_sha256=$restore_transaction_physical_b_sizes_sha256
  [[ "$physical_b_sizes_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    die "fastbootd recovery receipt has no physical-B size digest"

  # Pixel 11 fastbootd cannot open physical partition-size:*_a/b targets. The
  # enter_b_fastbootd_pending receipt was published only after bootloader
  # fastboot recomputed this digest, verified the exact lineage/handoff, and
  # fetched all of vendor_boot_b. Revalidate those immutable bindings here;
  # live physical sizes and bytes are required again immediately on return to
  # bootloader before any physical-A write.
  cubs_verify_lifeboat_lineage "$device_serial" "$physical_b_sizes_sha256" \
    "$expected_bootloader" "$expected_baseband"
  cubs_verify_lifeboat_handoff_for_recovery "$physical_b_sizes_sha256"
  require_restore_b_success "$(fastboot_value slot-successful:b)"
  verified_restore_physical_b_sizes_sha256=$physical_b_sizes_sha256
  verified_restore_lineage_sha256=$cubs_verified_lineage_sha256
  verified_restore_handoff_sha256=$cubs_verified_recovery_handoff_sha256
  verified_restore_stock_b_source=$cubs_verified_stock_b_source
  verified_restore_stock_b_provenance_sha256=$cubs_verified_stock_b_provenance_sha256
  verify_restore_flash_abort_adoption "$device_serial" \
    "$physical_b_sizes_sha256"
  require_receipt_matches_restore_evidence
}

require_receipt_matches_restore_evidence() {
  [[ "$restore_transaction_physical_b_sizes_sha256" == \
       "$verified_restore_physical_b_sizes_sha256" && \
     "$restore_transaction_lineage_sha256" == \
       "$verified_restore_lineage_sha256" && \
     "$restore_transaction_handoff_sha256" == \
       "$verified_restore_handoff_sha256" && \
     "$restore_transaction_stock_b_source" == \
       "$verified_restore_stock_b_source" && \
     "$restore_transaction_stock_b_provenance_sha256" == \
       "$verified_restore_stock_b_provenance_sha256" && \
     "$restore_transaction_adopted_flash_transaction_sha256" == \
       "$verified_restore_adopted_flash_transaction_sha256" && \
     "$restore_transaction_adopted_flash_serial_binding_sha256" == \
       "$verified_restore_adopted_flash_serial_binding_sha256" && \
     "$restore_transaction_adopted_runtime_attestation_sha256" == \
       "$verified_restore_adopted_runtime_attestation_sha256" ]] || \
    die "stock-restore receipt differs from the active recovery evidence"
}

write_restore_transaction_receipt() {
  local new_state=$1 current_sha temporary
  [[ "$new_state" =~ ^(select_b_pending|enter_b_fastbootd_pending|pivot_a_metadata_pending|restoring_logicals|return_bootloader_pending|restoring_physical|activate_a_pending|awaiting_stock_android)$ ]] || \
    die "invalid stock-restore transaction state"
  if [[ -e "$restore_transaction_receipt" || -L "$restore_transaction_receipt" ]]; then
    cubs_private_file "$restore_transaction_receipt"
    current_sha=$(sha256sum "$restore_transaction_receipt" | awk '{print $1}')
    [[ "$current_sha" == "$loaded_restore_transaction_sha256" ]] || \
      die "stock-restore transaction receipt changed during the operation"
    case "$restore_transaction_state:$new_state" in
      select_b_pending:enter_b_fastbootd_pending|\
      enter_b_fastbootd_pending:pivot_a_metadata_pending|\
      enter_b_fastbootd_pending:restoring_logicals|\
      pivot_a_metadata_pending:restoring_logicals|\
      restoring_logicals:return_bootloader_pending|\
      return_bootloader_pending:restoring_physical|\
      restoring_physical:activate_a_pending|\
      activate_a_pending:awaiting_stock_android|\
      awaiting_stock_android:select_b_pending|\
      awaiting_stock_android:enter_b_fastbootd_pending)
        ;;
      *) die "invalid stock-restore transaction transition: $restore_transaction_state -> $new_state" ;;
    esac
  else
    [[ "$new_state" =~ ^(select_b_pending|enter_b_fastbootd_pending)$ ]] || \
      die "a new stock restore must begin before activation"
    restore_transaction_created_epoch=$(date +%s)
    restore_transaction_id=$(cubs_random_anchor_id)
    restore_transaction_serial_binding=$(cubs_serial_binding \
      "$restore_transaction_id" "$device_serial")
    restore_transaction_physical_b_sizes_sha256=$verified_restore_physical_b_sizes_sha256
    restore_transaction_lineage_sha256=$verified_restore_lineage_sha256
    restore_transaction_handoff_sha256=$verified_restore_handoff_sha256
    restore_transaction_stock_b_source=$verified_restore_stock_b_source
    restore_transaction_stock_b_provenance_sha256=$verified_restore_stock_b_provenance_sha256
    restore_transaction_adopted_flash_transaction_sha256=${verified_restore_adopted_flash_transaction_sha256:-none}
    restore_transaction_adopted_flash_serial_binding_sha256=${verified_restore_adopted_flash_serial_binding_sha256:-none}
    restore_transaction_adopted_runtime_attestation_sha256=${verified_restore_adopted_runtime_attestation_sha256:-none}
  fi
  temporary=$(mktemp "$cubs_recovery_state_dir/.stock-restore.XXXXXX")
  {
    printf 'schema=cubs-stock-restore-v2\n'
    printf 'state=%s\n' "$new_state"
    printf 'created_epoch=%s\n' "$restore_transaction_created_epoch"
    printf 'transaction_id=%s\n' "$restore_transaction_id"
    printf 'serial_binding_sha256=%s\n' "$restore_transaction_serial_binding"
    printf 'device=%s\n' "$DEVICE_CODENAME"
    printf 'stock_build_id=%s\n' "$STOCK_BUILD_ID"
    printf 'factory_sha256=%s\n' "$FACTORY_IMAGE_SHA256"
    printf 'physical_b_sizes_sha256=%s\n' \
      "$restore_transaction_physical_b_sizes_sha256"
    printf 'lineage_sha256=%s\n' "$restore_transaction_lineage_sha256"
    printf 'handoff_sha256=%s\n' "$restore_transaction_handoff_sha256"
    printf 'stock_b_source=%s\n' "$restore_transaction_stock_b_source"
    printf 'stock_b_provenance_sha256=%s\n' \
      "$restore_transaction_stock_b_provenance_sha256"
    printf 'adopted_flash_transaction_sha256=%s\n' \
      "$restore_transaction_adopted_flash_transaction_sha256"
    printf 'adopted_flash_serial_binding_sha256=%s\n' \
      "$restore_transaction_adopted_flash_serial_binding_sha256"
    printf 'adopted_runtime_attestation_sha256=%s\n' \
      "$restore_transaction_adopted_runtime_attestation_sha256"
    printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$restore_transaction_receipt"
  cubs_private_file "$restore_transaction_receipt"
  load_restore_transaction_receipt "$device_serial"
  [[ "$restore_transaction_state" == "$new_state" ]] || \
    die "stock-restore transaction state was not published"
}

load_existing_restore_transaction_if_any() {
  if [[ -e "$restore_transaction_receipt" || -L "$restore_transaction_receipt" ]]; then
    load_restore_transaction_receipt "$device_serial"
  else
    unset \
      restore_transaction_state loaded_restore_transaction_sha256 \
      restore_transaction_handoff_sha256
  fi
}

preflight_restore_bootloader() {
  local live_byte_check=${1:-verify-live-bytes} current_slot
  require_no_conflicting_recovery_transaction
  assert_single_selected_device
  check_bootloader_identity
  check_battery
  current_slot=$(fastboot_value current-slot)
  [[ "$current_slot" =~ ^(a|b)$ ]] || \
    die "stock restore requires current physical slot A or B"
  check_restore_boot_control "$current_slot"
  load_existing_restore_transaction_if_any
  verify_full_restore_evidence
  if [[ -n "${restore_transaction_state:-}" ]]; then
    require_receipt_matches_restore_evidence
  fi
  case "$live_byte_check" in
    verify-live-bytes) verify_live_vendor_boot_b_control ;;
    sizes-only) ;;
    *) die "invalid bootloader preflight mode" ;;
  esac
  capture_b_lifeboat
  restore_current_slot=$current_slot
  restore_device_mode=bootloader
}

preflight_restore_fastbootd() {
  require_no_conflicting_recovery_transaction
  assert_single_selected_device
  check_fastbootd_identity
  check_battery
  load_existing_restore_transaction_if_any
  [[ -n "${restore_transaction_state:-}" ]] || \
    die "fastbootd stock restore requires an existing bound transaction"
  verify_fastbootd_journaled_b_evidence
  restore_current_slot=$fastbootd_current_slot
  restore_device_mode=fastbootd
}

detect_restore_device_mode() {
  local userspace
  assert_single_selected_device
  userspace=$(fastboot_value is-userspace)
  case "$userspace" in
    no) printf 'bootloader\n' ;;
    yes) printf 'fastbootd\n' ;;
    *) die "unable to determine whether the selected device is in bootloader or fastbootd" ;;
  esac
}

select_b_before_fastbootd_entry() {
  case "${restore_transaction_state:-none}" in
    none|awaiting_stock_android)
      write_restore_transaction_receipt select_b_pending
      ;;
    select_b_pending|enter_b_fastbootd_pending)
      ;;
    *) die "stock restore cannot select B from state ${restore_transaction_state:-none}" ;;
  esac
  note "selecting the verified physical-B boot-support lifeboat"
  slot_b_activation_attempted=1
  "${fastboot_command[@]}" set_active b
  preflight_restore_bootloader
  [[ "$restore_current_slot" == b ]] || \
    die "physical B was not selected before entering stock fastbootd"
}

enter_journaled_b_fastbootd() {
  local reboot_status=0

  [[ "$restore_device_mode" == bootloader && \
     "$restore_current_slot" == b ]] || \
    die "stock fastbootd entry requires the verified B bootloader"
  case "${restore_transaction_state:-none}" in
    none|select_b_pending|awaiting_stock_android)
      write_restore_transaction_receipt enter_b_fastbootd_pending
      ;;
    enter_b_fastbootd_pending)
      ;;
    *) die "stock fastbootd entry is not authorized by the restore receipt" ;;
  esac

  verify_b_lifeboat
  note "entering physical-B stock fastbootd; no Android-B reboot is authorized"
  "${fastboot_command[@]}" reboot fastboot || reboot_status=$?
  if (( reboot_status != 0 )); then
    note "reboot-fastboot returned $reboot_status; reconciling the journaled device mode"
  fi
  wait_for_selected_device
  preflight_restore_fastbootd
  [[ "$restore_transaction_state" == enter_b_fastbootd_pending ]] || \
    die "restore receipt changed during the B-fastbootd transition"
  [[ "$restore_current_slot" == b ]] || \
    die "B-origin fastbootd did not preserve the B selector before metadata pivot"
}

prepare_restore_state() {
  local mode
  mode=$(detect_restore_device_mode)
  if [[ "$mode" == fastbootd ]]; then
    preflight_restore_fastbootd
    case "$restore_transaction_state" in
      enter_b_fastbootd_pending|pivot_a_metadata_pending|\
      restoring_logicals|return_bootloader_pending)
        return
        ;;
      *) die "restore state $restore_transaction_state cannot resume in fastbootd" ;;
    esac
  fi

  preflight_restore_bootloader
  case "${restore_transaction_state:-none}" in
    activate_a_pending)
      die "activation is already pending; use finalize-activation without reflashing"
      ;;
    return_bootloader_pending|restoring_physical)
      return
      ;;
    pivot_a_metadata_pending|restoring_logicals)
      die "logical restore lost fastbootd before its journaled return-to-bootloader step"
      ;;
    boot_control_pending|retiring_evidence)
      die "stock restore is already in its post-Android finalization protocol"
      ;;
  esac

  if [[ "$restore_current_slot" == a ]]; then
    select_b_before_fastbootd_entry
  fi
  [[ "$restore_current_slot" == b ]] || \
    die "unable to reconcile the verified B bootloader for stock-fastbootd entry"
  enter_journaled_b_fastbootd
}

pivot_fastbootd_to_a_metadata() {
  local attempt pivot_status=0 first_partition=${logical_partitions[0]}

  [[ "$restore_device_mode" == fastbootd ]] || \
    die "logical metadata pivot requires fastbootd"
  case "$restore_transaction_state" in
    enter_b_fastbootd_pending)
      inspect_fastbootd_logical_namespace
      case "$logical_namespace" in
        b_only)
          write_restore_transaction_receipt pivot_a_metadata_pending
          ;;
        a_only)
          shared_super_modified=1
          write_restore_transaction_receipt restoring_logicals
          return
          ;;
        mixed)
          die "B-origin fastbootd exposes an irreconcilable mixed logical namespace"
          ;;
      esac
      ;;
    pivot_a_metadata_pending)
      ;;
    restoring_logicals|return_bootloader_pending)
      return
      ;;
    *) die "restore receipt does not authorize an A-metadata pivot" ;;
  esac

  for ((attempt = 1; attempt <= 2; attempt += 1)); do
    inspect_fastbootd_logical_namespace
    case "$logical_namespace" in
      a_only)
        shared_super_modified=1
        if [[ "${logical_a_size_kind[$first_partition]}" == zero ]]; then
          write_restore_transaction_receipt restoring_logicals
          return
        fi
        ;;
      b_only)
        ;;
      mixed)
        die "metadata pivot produced an irreconcilable mixed logical namespace"
        ;;
    esac

    note "pivoting to A metadata and resizing ${first_partition}_a in one fastboot connection"
    shared_super_modified=1
    pivot_status=0
    "${fastboot_command[@]}" \
      set_active a \
      resize-logical-partition "${first_partition}_a" 0 || pivot_status=$?
    if (( pivot_status != 0 )); then
      note "metadata pivot returned $pivot_status; reconciling namespace and exact size"
    fi
    wait_for_selected_device
    preflight_restore_fastbootd
    [[ "$restore_transaction_state" == pivot_a_metadata_pending ]] || \
      die "restore receipt changed during the A-metadata pivot"
    inspect_fastbootd_logical_namespace
    case "$logical_namespace:${logical_a_size_kind[$first_partition]:-invalid}" in
      a_only:zero)
        write_restore_transaction_receipt restoring_logicals
        return
        ;;
      b_only:*)
        note "metadata fanout remains B-only; repeating the journaled pivot"
        ;;
      a_only:nonzero)
        note "A namespace is visible but the pivot resize is incomplete; repeating it"
        ;;
      *)
        die "metadata pivot left an irreconcilable mixed or unreadable namespace"
        ;;
    esac
  done
  die "A-metadata pivot remains incomplete; rerun the journaled restore in fastbootd"
}

resize_stock_a_logical() {
  local partition=$1 command_status=0
  note "resizing explicit logical partition ${partition}_a to zero"
  shared_super_modified=1
  "${fastboot_command[@]}" \
    set_active a \
    resize-logical-partition "${partition}_a" 0 || command_status=$?
  wait_for_selected_device
  preflight_restore_fastbootd
  [[ "$restore_transaction_state" == restoring_logicals ]] || \
    die "restore receipt changed during a logical resize"
  require_reconciled_a_namespace
  [[ "${logical_a_size_kind[$partition]}" == zero ]] || \
    die "${partition}_a did not reconcile to exact zero after resize status $command_status"
}

stock_a_logical_has_exact_size() {
  local partition=$1 actual
  actual=$(fastboot_value "partition-size:${partition}_a")
  [[ $(partition_size_kind "$actual") == nonzero ]] || return 1
  actual=$(cubs_normalize_partition_size "$actual")
  [[ "$actual" == "${expected_stock_logical_sizes[$partition]}" ]]
}

flash_stock_a_logical() {
  local partition=$1 attempt command_status
  note "flashing exact stock logical partition ${partition}_a"
  for ((attempt = 1; attempt <= 2; attempt += 1)); do
    command_status=0
    shared_super_modified=1
    "${fastboot_command[@]}" \
      set_active a \
      flash "${partition}_a" "$restore_dir/$partition.img" || command_status=$?
    wait_for_selected_device
    preflight_restore_fastbootd
    [[ "$restore_transaction_state" == restoring_logicals ]] || \
      die "restore receipt changed during a logical flash"
    require_reconciled_a_namespace
    if (( command_status == 0 )) && \
        stock_a_logical_has_exact_size "$partition"; then
      return
    fi
    if (( command_status != 0 && attempt == 1 )); then
      note "logical flash returned $command_status; replaying it once and requiring a clean exact-size result"
      continue
    fi
    die "${partition}_a flash did not complete cleanly at its exact expanded image size"
  done
}

restore_all_stock_a_logicals() {
  local partition
  [[ "$restore_transaction_state" == restoring_logicals ]] || \
    die "logical replay requires restoring_logicals authorization"
  require_reconciled_a_namespace
  for partition in "${logical_partitions[@]}"; do
    resize_stock_a_logical "$partition"
  done
  for partition in "${logical_partitions[@]}"; do
    flash_stock_a_logical "$partition"
  done
  verify_fastbootd_journaled_b_evidence
  write_restore_transaction_receipt return_bootloader_pending
}

return_to_bootloader_for_physical_restore() {
  local mode reboot_status=0 select_status=0

  [[ "$restore_transaction_state" == return_bootloader_pending ]] || \
    die "bootloader return requires return_bootloader_pending authorization"
  mode=$(detect_restore_device_mode)
  if [[ "$mode" == fastbootd ]]; then
    preflight_restore_fastbootd
    note "returning explicitly to bootloader fastboot for physical-A restoration"
    "${fastboot_command[@]}" reboot bootloader || reboot_status=$?
    if (( reboot_status != 0 )); then
      note "reboot-bootloader returned $reboot_status; reconciling the journaled mode"
    fi
    wait_for_selected_device
    mode=$(detect_restore_device_mode)
    [[ "$mode" == bootloader ]] || \
      die "journaled return remains in fastbootd; rerun the restore without rebooting Android"
  fi

  preflight_restore_bootloader
  [[ "$restore_transaction_state" == return_bootloader_pending ]] || \
    die "restore receipt changed during the bootloader return"
  if [[ "$restore_current_slot" == b ]]; then
    note "reconciling activation target A before physical restoration"
    "${fastboot_command[@]}" set_active a || select_status=$?
    if (( select_status != 0 )); then
      note "set-active-A returned $select_status; reconciling boot control"
    fi
    preflight_restore_bootloader
    [[ "$restore_current_slot" == a ]] || \
      die "activation target A could not be reconciled after shared-super mutation"
  fi
  verify_b_lifeboat
  write_restore_transaction_receipt restoring_physical
}

finish_stock_a_activation() {
  check_bootloader_identity
  [[ $(fastboot_value current-slot) == a ]] || \
    die "slot A was not selected after restore"
  [[ $(fastboot_value slot-unbootable:a) == no ]] || \
    die "slot A remains marked unbootable after selection"
  [[ $(fastboot_value slot-unbootable:b) == no ]] || \
    die "physical slot B became unbootable during stock restore"
  verify_full_restore_evidence
  require_receipt_matches_restore_evidence
  write_restore_transaction_receipt awaiting_stock_android
  # Suppress the recovery warning only after every post-activation flag and
  # evidence check passed and the durable awaiting-stock receipt was published.
  slot_a_activated=1
  note "retained the exact recovery handoff until restored stock A boots successfully"
}

confirm_restore_activation_finalization() {
  local entered
  [[ -t 0 && -t 1 ]] || \
    die "refusing restore activation finalization without an interactive terminal"
  printf '\nType exactly: %s\n> ' "$expected_confirmation" >/dev/tty
  IFS= read -r entered </dev/tty
  [[ "$entered" == "$expected_confirmation" ]] || \
    die "confirmation phrase did not match"
}

finalize_restore_activation() {
  cubs_lock_recovery_state
  preflight_restore_bootloader
  [[ "$restore_transaction_state" == activate_a_pending ]] || \
    die "finalize-activation requires an activate_a_pending restore receipt"
  activation_finalization_attempted=1
  confirm_restore_activation_finalization

  # Repeat the pinned tool, sole transport, firmware, flags, transaction,
  # lineage, handoff, size, and live vendor_boot checks after the TTY pause.
  preflight_restore_bootloader
  [[ "$restore_transaction_state" == activate_a_pending ]] || \
    die "restore activation state changed while waiting for confirmation"
  if [[ "$restore_current_slot" == b ]]; then
    "${fastboot_command[@]}" set_active a
  fi
  finish_stock_a_activation
  note "finalized stock-A activation without reflashing; boot stock A next"
}

run_stock_restore() {
  local activation_status=0 partition
  cubs_lock_recovery_state
  prepare_restore_state

  case "$restore_transaction_state" in
    enter_b_fastbootd_pending|pivot_a_metadata_pending)
      note "WARNING: A/B logical views share physical super extents on cubs"
      note "the journaled metadata pivot invalidates Android B, never its physical boot lifeboat"
      pivot_fastbootd_to_a_metadata
      ;;
  esac
  if [[ "$restore_transaction_state" == restoring_logicals ]]; then
    note "replaying every exact stock-A logical zero and flash operation"
    restore_all_stock_a_logicals
  fi
  if [[ "$restore_transaction_state" == return_bootloader_pending ]]; then
    return_to_bootloader_for_physical_restore
  fi

  [[ "$restore_transaction_state" == restoring_physical ]] || \
    die "stock restore did not reconcile to physical-A restoration"
  [[ "$restore_device_mode" == bootloader ]] || \
    die "physical-A restoration requires bootloader fastboot"
  if [[ "$restore_current_slot" == b ]]; then
    activation_status=0
    "${fastboot_command[@]}" set_active a || activation_status=$?
    if (( activation_status != 0 )); then
      note "set-active-A returned $activation_status; reconciling before physical writes"
    fi
    preflight_restore_bootloader
    [[ "$restore_current_slot" == a ]] || \
      die "slot A is not the activation target for physical restoration"
  fi

  note "restoring exact stock $STOCK_BUILD_ID to literal slot-A partition names"
  note "flashing all 25 firmware and six boot-support payloads only after logical recovery"
  for partition in "${early_physical_partitions[@]}"; do
    flash_stock_physical_a "$partition"
  done
  verify_b_lifeboat

  note "flashing vbmeta_system_a and vbmeta_vendor_a, then root vbmeta_a last"
  for partition in "${vbmeta_partitions[@]}"; do
    flash_stock_physical_a "$partition"
  done
  verify_b_lifeboat
  verify_live_vendor_boot_b_control

  require_global_wipe_partition userdata
  require_global_wipe_partition metadata
  note "erasing shared userdata and metadata"
  "${fastboot_command[@]}" erase userdata
  "${fastboot_command[@]}" erase metadata

  write_restore_transaction_receipt activate_a_pending
  note "reasserting slot A as the final device write"
  activation_status=0
  "${fastboot_command[@]}" set_active a || activation_status=$?
  if (( activation_status != 0 )); then
    note "final set-active-A returned $activation_status; reconciling its durable effect"
  fi
  preflight_restore_bootloader sizes-only
  [[ "$restore_transaction_state" == activate_a_pending && \
     "$restore_current_slot" == a ]] || \
    die "slot-A activation did not reconcile to the journaled final state"
  finish_stock_a_activation

  note "exact stock A restore completed; the phone remains in bootloader fastboot"
  note "boot stock A, enable ADB, then run finalize-stock-android"
  note "slot-B Android is invalid, but all physical B lifeboat partitions remain untouched"
}

case "$action" in
  restore) run_stock_restore ;;
  finalize-activation) finalize_restore_activation ;;
esac
