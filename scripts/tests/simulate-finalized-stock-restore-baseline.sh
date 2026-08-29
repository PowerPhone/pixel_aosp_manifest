#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2154
set -euo pipefail
export LC_ALL=C

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
attest_script="$project_root/scripts/attest-stock-a-for-physical-b.sh"
# shellcheck source=../lib/common.sh disable=SC1091
source "$project_root/scripts/lib/common.sh"
# shellcheck source=../../config/recovery.env disable=SC1091
source "$project_root/config/recovery.env"

scratch_parent="$project_root/work/finalized-restore-baseline-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -d "${scratch_dir:-}" && "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

# Load the fixed physical-partition order for synthetic receipt construction.
export CUBS_RECOVERY_STATE_DIR="$scratch_dir/definitions"
# shellcheck source=../lib/recovery-handoff.sh disable=SC1091
source "$project_root/scripts/lib/recovery-handoff.sh"

mock_fastboot="$scratch_dir/fastboot"
mock_fastboot_source="$scratch_dir/mock-fastboot-source"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'if [[ "${1:-}" == --version ]]; then'
  printf '%s\n' '  printf "fastboot version 99.0\nInstalled as test fixture\n"'
  printf '%s\n' '  exit 0'
  printf '%s\n' 'fi'
  printf '%s\n' 'if [[ "${1:-}" == devices ]]; then'
  printf '%s\n' '  printf "%s\tfastboot\n" "$MOCK_SERIAL"'
  printf '%s\n' '  exit 0'
  printf '%s\n' 'fi'
  printf '%s\n' '[[ "${1:-}" == -s && "${2:-}" == "$MOCK_SERIAL" ]] || exit 70'
  printf '%s\n' 'shift 2'
  printf '%s\n' 'case "${1:-}" in'
  printf '%s\n' '  getvar)'
  printf '%s\n' '    variable=${2:-}'
  printf '%s\n' '    case "$variable" in'
  printf '%s\n' '      product) value=${MOCK_PRODUCT:-cubs} ;;'
  printf '%s\n' '      version-bootloader) value=${MOCK_BOOTLOADER:-test-bootloader} ;;'
  printf '%s\n' '      version-baseband) value=${MOCK_BASEBAND:-test-baseband} ;;'
  printf '%s\n' '      unlocked) value=${MOCK_UNLOCKED:-yes} ;;'
  printf '%s\n' '      is-userspace) value=${MOCK_IS_USERSPACE:-no} ;;'
  printf '%s\n' '      slot-count) value=${MOCK_SLOT_COUNT:-2} ;;'
  printf '%s\n' '      current-slot)'
  printf '%s\n' '        if [[ -f "$MOCK_STATE_DIR/current-slot" ]]; then'
  printf '%s\n' '          IFS= read -r value <"$MOCK_STATE_DIR/current-slot"'
  printf '%s\n' '        else'
  printf '%s\n' '          value=${MOCK_CURRENT_SLOT:-a}'
  printf '%s\n' '        fi'
  printf '%s\n' '        ;;'
  printf '%s\n' '      snapshot-update-status) value=${MOCK_SNAPSHOT_STATUS:-none} ;;'
  printf '%s\n' '      slot-successful:a) value=${MOCK_A_SUCCESSFUL:-yes} ;;'
  printf '%s\n' '      slot-unbootable:a) value=${MOCK_A_UNBOOTABLE:-no} ;;'
  printf '%s\n' '      slot-successful:b) value=${MOCK_B_SUCCESSFUL:-yes} ;;'
  printf '%s\n' '      slot-unbootable:b) value=${MOCK_B_UNBOOTABLE:-no} ;;'
  printf '%s\n' '      battery-soc) value=${MOCK_BATTERY:-90} ;;'
  printf '%s\n' '      has-slot:*) value=yes ;;'
  printf '%s\n' '      is-logical:*) value=no ;;'
  printf '%s\n' '      partition-size:*)'
  printf '%s\n' '        partition=${variable#partition-size:}'
  printf '%s\n' '        if [[ "$partition" == "${MOCK_DRIFT_PARTITION:-none}" ]]; then'
  printf '%s\n' '          value=8000'
  printf '%s\n' '        elif [[ "$partition" == vendor_boot_a || "$partition" == vendor_boot_b ]]; then'
  printf '%s\n' '          value=0x00001000'
  printf '%s\n' '        else'
  printf '%s\n' '          value=0x00004000'
  printf '%s\n' '        fi'
  printf '%s\n' '        ;;'
  printf '%s\n' '      *) printf "FAILED (remote: unknown variable)\n" >&2; exit 1 ;;'
  printf '%s\n' '    esac'
  printf '%s\n' '    printf "(bootloader) %s: %s\n" "$variable" "$value" >&2'
  printf '%s\n' '    if [[ "$variable" == "${MOCK_DUPLICATE_VAR:-none}" ]]; then'
  printf '%s\n' '      printf "%s: %s\n" "$variable" "$value" >&2'
  printf '%s\n' '    fi'
  printf '%s\n' '    if [[ "$variable" == "${MOCK_FAILED_VAR:-none}" ]]; then'
  printf '%s\n' '      printf "FAILED (test fixture)\n" >&2'
  printf '%s\n' '    fi'
  printf '%s\n' '    ;;'
  printf '%s\n' '  fetch)'
  printf '%s\n' '    partition=${2:-}'
  printf '%s\n' '    destination=${3:-}'
  printf '%s\n' '    [[ "$partition" == vendor_boot_a || "$partition" == vendor_boot_b ]] || exit 71'
  printf '%s\n' '    count=0'
  printf '%s\n' '    if [[ -f "$MOCK_STATE_DIR/fetch-count" ]]; then'
  printf '%s\n' '      IFS= read -r count <"$MOCK_STATE_DIR/fetch-count"'
  printf '%s\n' '    fi'
  printf '%s\n' '    printf "%s\n" "$((count + 1))" >"$MOCK_STATE_DIR/fetch-count"'
  printf '%s\n' '    case "${MOCK_FETCH_MODE:-exact}" in'
  printf '%s\n' '      exact) cp -- "$MOCK_VENDOR_BOOT_IMAGE" "$destination" ;;'
  printf '%s\n' '      short) head -c 2048 "$MOCK_VENDOR_BOOT_IMAGE" >"$destination" ;;'
  printf '%s\n' '      wrong) dd if=/dev/zero bs=4096 count=1 status=none | tr "\000" "\001" >"$destination" ;;'
  printf '%s\n' '      *) exit 72 ;;'
  printf '%s\n' '    esac'
  printf '%s\n' '    ;;'
  printf '%s\n' '  *) exit 73 ;;'
  printf '%s\n' 'esac'
} >"$mock_fastboot_source"
mv -T -- "$mock_fastboot_source" "$mock_fastboot"
chmod 0700 "$mock_fastboot"
mock_fastboot_sha256=$(sha256sum "$mock_fastboot" | awk '{print $1}')

physical_size_for_partition() {
  local partition=$1
  if [[ "$partition" == vendor_boot ]]; then
    printf '1000\n'
  else
    printf '4000\n'
  fi
}

create_finalized_receipt() {
  local scenario_root=$1 binding_serial=$2 placement=${3:-source}
  local adopted_runtime=${4:-$CUBS_FINALIZED_STOCK_RESTORE_ADOPTED_RUNTIME_ATTESTATION_SHA256}
  local binding created destination physical_b_digest receipt_sha temporary
  local partition lines=''
  local recovery_dir="$scenario_root/recovery"
  mkdir -p "$recovery_dir/consumed"
  chmod 0700 "$recovery_dir" "$recovery_dir/consumed"
  for partition in "${cubs_preserved_b_partitions[@]}"; do
    lines+="${partition}_b=$(physical_size_for_partition "$partition")"$'\n'
  done
  physical_b_digest=$(printf '%s' "$lines" | sha256sum | awk '{print $1}')
  binding=$(cubs_serial_binding "$CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID" "$binding_serial")
  created=$(( $(date +%s) - 7200 ))
  temporary="$recovery_dir/.synthetic-finalized-receipt"
  {
    printf 'schema=cubs-stock-restore-v2\n'
    printf 'state=retiring_evidence\n'
    printf 'created_epoch=%s\n' "$created"
    printf 'transaction_id=%s\n' "$CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID"
    printf 'serial_binding_sha256=%s\n' "$binding"
    printf 'device=%s\n' "$DEVICE_CODENAME"
    printf 'stock_build_id=%s\n' "$STOCK_BUILD_ID"
    printf 'factory_sha256=%s\n' "$FACTORY_IMAGE_SHA256"
    printf 'physical_b_sizes_sha256=%s\n' "$physical_b_digest"
    printf 'lineage_sha256=%064d\n' 1
    printf 'handoff_sha256=%064d\n' 2
    printf 'stock_b_source=direct_factory_physical_b\n'
    printf 'stock_b_provenance_sha256=%064d\n' 3
    printf 'adopted_flash_transaction_sha256=%064d\n' 4
    printf 'adopted_flash_serial_binding_sha256=%064d\n' 5
    printf 'adopted_runtime_attestation_sha256=%s\n' "$adopted_runtime"
    printf 'recovery_policy_sha256=%s\n' "$CUBS_FINALIZED_STOCK_RESTORE_RECOVERY_POLICY_SHA256"
  } >"$temporary"
  chmod 0600 "$temporary"
  receipt_sha=$(sha256sum "$temporary" | awk '{print $1}')
  printf '%s\n' "$receipt_sha" >"$scenario_root/receipt.sha256"
  case "$placement" in
    source)
      destination="$recovery_dir/consumed/stock-restore-${CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID}-$receipt_sha"
      ;;
    claimed)
      destination="$recovery_dir/stock-a-baseline-evidence"
      ;;
    *) die "invalid synthetic finalized-receipt placement" ;;
  esac
  mv -T -- "$temporary" "$destination"
  chmod 0600 "$destination"
}

run_adoption() (
  local scenario_root=$1
  local receipt_sha partition image_sha current_digest index=1
  export CUBS_RECOVERY_STATE_DIR="$scenario_root/recovery"
  export CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL
  export CUBS_ALLOW_FINALIZED_RESTORE_BASELINE=1
  export CUBS_FINALIZED_RESTORE_CONFIRM=ADOPT_FINALIZED_RESTORE_BOOTLOADER_AS_STOCK_A_BASELINE
  export FASTBOOT="$mock_fastboot"
  export MOCK_SERIAL=MOCK_CUBS_SERIAL
  export MOCK_STATE_DIR="$scenario_root/mock-state"
  export MOCK_VENDOR_BOOT_IMAGE="$scenario_root/images/vendor_boot.img"
  export MOCK_PRODUCT=${MOCK_PRODUCT:-cubs}
  export MOCK_BOOTLOADER=${MOCK_BOOTLOADER:-test-bootloader}
  export MOCK_BASEBAND=${MOCK_BASEBAND:-test-baseband}
  export MOCK_FETCH_MODE=${MOCK_FETCH_MODE:-exact}
  mkdir -p "$MOCK_STATE_DIR" "$scenario_root/images"

  # shellcheck source=../attest-stock-a-for-physical-b.sh disable=SC1091
  source "$attest_script"
  receipt_sha=$(<"$scenario_root/receipt.sha256")
  CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256=$receipt_sha
  CUBS_FINALIZED_STOCK_RESTORE_ADOPTED_RUNTIME_ATTESTATION_SHA256=${MOCK_FINALIZED_RUNTIME_PIN:-$CUBS_FINALIZED_STOCK_RESTORE_ADOPTED_RUNTIME_ATTESTATION_SHA256}
  cubs_finalized_stock_restore_source="$cubs_recovery_state_dir/consumed/stock-restore-${CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID}-$receipt_sha"
  PLATFORM_TOOLS_VERSION=99.0
  PLATFORM_TOOLS_FASTBOOT_SHA256=$mock_fastboot_sha256

  load_stock_factory_controls() {
    dd if=/dev/zero of="$MOCK_VENDOR_BOOT_IMAGE" bs=4096 count=1 status=none
    chmod 0600 "$MOCK_VENDOR_BOOT_IMAGE"
    baseline_image_dir="$scenario_root/images"
    baseline_vendor_boot_image="$MOCK_VENDOR_BOOT_IMAGE"
    baseline_logical_sizes=()
    index=1
    for partition in "${cubs_logical_partitions[@]}"; do
      baseline_logical_sizes["${partition}_a"]=$(printf '%x' "$((index * 4096))")
      ((index += 1))
    done
    baseline_logical_sizes_sha256=$(cubs_stock_a_logical_sizes_sha256 baseline_logical_sizes
    )
    image_sha=$(sha256sum "$MOCK_VENDOR_BOOT_IMAGE" | awk '{print $1}')
    CUBS_STOCK_VENDOR_BOOT_SHA256=$image_sha
    printf '%s\n' "$image_sha" >"$scenario_root/factory-control.sha256"
  }
  verify_stock_factory_controls() {
    image_sha=$(sha256sum "$MOCK_VENDOR_BOOT_IMAGE" | awk '{print $1}')
    [[ "$image_sha" == "$(<"$scenario_root/factory-control.sha256")" ]] || die "synthetic factory control changed during authorization"
    current_digest=$(cubs_stock_a_logical_sizes_sha256 baseline_logical_sizes)
    [[ "$current_digest" == "$baseline_logical_sizes_sha256" ]] || die "synthetic logical controls changed during authorization"
    printf 'verified\n' >"$scenario_root/factory-reverified"
  }
  load_stock_firmware_requirements() {
    expected_bootloader=test-bootloader
    expected_baseband=test-baseband
  }
  confirm_adoption_on_tty() {
    case "${MOCK_TTY_MUTATION:-none}" in
      none) ;;
      current-slot)
        printf 'b\n' >"$MOCK_STATE_DIR/current-slot"
        ;;
      source-tamper)
        printf 'unexpected=field\n' >>"$cubs_finalized_stock_restore_source"
        ;;
      factory)
        printf 'x' >>"$MOCK_VENDOR_BOOT_IMAGE"
        ;;
      *) die "unknown synthetic TTY mutation" ;;
    esac
  }

  adopt_finalized_restore_bootloader
)

assert_unclaimed() {
  local scenario_root=$1 receipt_sha source
  receipt_sha=$(<"$scenario_root/receipt.sha256")
  source="$scenario_root/recovery/consumed/stock-restore-${CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID}-$receipt_sha"
  [[ -f "$source" && ! -e "$scenario_root/recovery/stock-a-baseline-evidence" && ! -e "$scenario_root/recovery/stock-a-physical-b-preflight" ]] || {
    printf 'error: rejected adoption changed the one-shot claim state: %s\n' "${scenario_root##*/}" >&2
    exit 1
  }
}

verify_published_preflight() (
  local scenario_root=$1
  local runtime_pin=${2:-$CUBS_FINALIZED_STOCK_RESTORE_ADOPTED_RUNTIME_ATTESTATION_SHA256}
  local receipt_sha partition
  export CUBS_RECOVERY_STATE_DIR="$scenario_root/recovery"
  # shellcheck source=../lib/recovery-handoff.sh disable=SC1091
  source "$project_root/scripts/lib/recovery-handoff.sh"
  receipt_sha=$(<"$scenario_root/receipt.sha256")
  CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256=$receipt_sha
  CUBS_FINALIZED_STOCK_RESTORE_ADOPTED_RUNTIME_ATTESTATION_SHA256=$runtime_pin
  cubs_verify_stock_a_physical_b_preflight MOCK_CUBS_SERIAL bootloader_verified fresh
  [[ "$cubs_verified_stock_a_baseline_sha256" == "$receipt_sha" && "$cubs_verified_stock_a_logical_sizes_sha256" =~ ^[0-9a-f]{64}$ ]] || die "synthetic published preflight globals are incomplete"
  for partition in "${cubs_logical_partitions[@]}"; do
    [[ "${cubs_verified_stock_a_logical_sizes[${partition}_a]}" =~ ^[0-9a-f]+$ ]] || die "published logical size is unavailable"
  done
)

set_preflight_remaining_seconds() {
  local scenario_root=$1 remaining=$2 created expires now preflight
  [[ "$remaining" =~ ^-?[0-9]+$ ]] || die "invalid synthetic preflight lifetime"
  preflight="$scenario_root/recovery/stock-a-physical-b-preflight"
  [[ -f "$preflight" && ! -L "$preflight" ]] || \
    die "synthetic preflight is unavailable for lifetime adjustment"
  now=$(date +%s)
  expires=$((now + remaining))
  created=$((expires - CUBS_STOCK_A_PHYSICAL_B_PREFLIGHT_SECONDS))
  sed -i \
    -e "s/^created_epoch=.*/created_epoch=$created/" \
    -e "s/^expires_epoch=.*/expires_epoch=$expires/" \
    -e "s/^bootloader_verified_epoch=.*/bootloader_verified_epoch=$created/" \
    "$preflight"
  chmod 0600 "$preflight"
}

clone_completed_baseline() {
  local source_root=$1 destination_root=$2
  mkdir -p "$destination_root"
  cp -- "$source_root/receipt.sha256" "$destination_root/receipt.sha256"
  cp -a -- "$source_root/recovery" "$destination_root/recovery"
}

expect_adoption_failure() {
  local scenario_root=$1 message=$2
  if run_adoption "$scenario_root" >"$scenario_root/rejected.log" 2>&1; then
    printf 'error: expected adoption rejection: %s\n' "$message" >&2
    exit 1
  fi
}

# Clean one-shot claim, exact preflight-v3 publication, and idempotent complete
# replay. Each pass must repeat full vendor_boot_a/b controls after the pause.
success_root="$scratch_dir/success"
mkdir -p "$success_root"
create_finalized_receipt "$success_root" MOCK_CUBS_SERIAL source
run_adoption "$success_root" >"$success_root/first.log" 2>&1
receipt_sha=$(<"$success_root/receipt.sha256")
canonical_source="$success_root/recovery/consumed/stock-restore-${CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID}-$receipt_sha"
[[ ! -e "$canonical_source" && -f "$success_root/recovery/stock-a-baseline-evidence" && -f "$success_root/recovery/stock-a-physical-b-preflight" && -f "$success_root/factory-reverified" && $(<"$success_root/mock-state/fetch-count") == 4 ]] || {
  printf 'error: clean finalized-restore claim did not publish exact evidence\n' >&2
  exit 1
}
grep -Fxq 'schema=cubs-stock-a-physical-b-preflight-v3' "$success_root/recovery/stock-a-physical-b-preflight"
grep -Fxq 'state=bootloader_verified' "$success_root/recovery/stock-a-physical-b-preflight"
grep -Fxq 'baseline_kind=finalized_stock_restore_v2' "$success_root/recovery/stock-a-physical-b-preflight"
[[ $(grep -Ec '^logical_(system|system_dlkm|system_ext|product|vendor|vendor_dlkm)_a_size=[0-9a-f]+$' "$success_root/recovery/stock-a-physical-b-preflight") == 6 ]] || {
  printf 'error: preflight-v3 lacks six exact A logical sizes\n' >&2
  exit 1
}
verify_published_preflight "$success_root"
preflight_sha_before=$(sha256sum "$success_root/recovery/stock-a-physical-b-preflight" | awk '{print $1}')
run_adoption "$success_root" >"$success_root/replay.log" 2>&1
preflight_sha_after=$(sha256sum "$success_root/recovery/stock-a-physical-b-preflight" | awk '{print $1}')
[[ "$preflight_sha_before" == "$preflight_sha_after" && $(<"$success_root/mock-state/fetch-count") == 8 ]] || {
  printf 'error: complete baseline replay was not exact and idempotent\n' >&2
  exit 1
}

# A finalized exact-stock restore may legitimately adopt an aborted diagnostic
# flash that never published runtime authority. The receipt must then bind the
# literal `none`, and the bridge pin must independently authorize that exact
# value.
none_root="$scratch_dir/exact-none-runtime"
mkdir -p "$none_root"
create_finalized_receipt "$none_root" MOCK_CUBS_SERIAL source none
MOCK_FINALIZED_RUNTIME_PIN=none \
  run_adoption "$none_root" >"$none_root/adopt.log" 2>&1
[[ -f "$none_root/recovery/stock-a-baseline-evidence" && \
   -f "$none_root/recovery/stock-a-physical-b-preflight" ]] || {
  printf 'error: exact none adopted-runtime bridge was not accepted\n' >&2
  exit 1
}
verify_published_preflight "$none_root" none

# Preserve coverage for the historical reviewed-runtime form even when the
# active generation pins literal `none`.
hash_runtime_pin=$(printf '%064d' 6)
hash_root="$scratch_dir/exact-hash-runtime"
mkdir -p "$hash_root"
create_finalized_receipt \
  "$hash_root" MOCK_CUBS_SERIAL source "$hash_runtime_pin"
MOCK_FINALIZED_RUNTIME_PIN=$hash_runtime_pin \
  run_adoption "$hash_root" >"$hash_root/adopt.log" 2>&1
[[ -f "$hash_root/recovery/stock-a-baseline-evidence" && \
   -f "$hash_root/recovery/stock-a-physical-b-preflight" ]] || {
  printf 'error: exact hash adopted-runtime bridge was not accepted\n' >&2
  exit 1
}
verify_published_preflight "$hash_root" "$hash_runtime_pin"

# A validly shaped but different runtime digest is not interchangeable with
# either the historical digest or the exact `none` generation.
runtime_mismatch_root="$scratch_dir/runtime-pin-mismatch"
mkdir -p "$runtime_mismatch_root"
if [[ "$CUBS_FINALIZED_STOCK_RESTORE_ADOPTED_RUNTIME_ATTESTATION_SHA256" == \
      none ]]; then
  mismatched_runtime=$hash_runtime_pin
else
  mismatched_runtime=none
fi
create_finalized_receipt \
  "$runtime_mismatch_root" MOCK_CUBS_SERIAL source "$mismatched_runtime"
expect_adoption_failure "$runtime_mismatch_root" 'adopted-runtime pin mismatch'
assert_unclaimed "$runtime_mismatch_root"

# Validate the pin grammar independently of equality: matching malformed
# config/receipt values must still be rejected.
runtime_malformed_root="$scratch_dir/runtime-pin-malformed"
mkdir -p "$runtime_malformed_root"
create_finalized_receipt "$runtime_malformed_root" \
  MOCK_CUBS_SERIAL source malformed
MOCK_FINALIZED_RUNTIME_PIN=malformed \
  expect_adoption_failure "$runtime_malformed_root" \
    'malformed adopted-runtime pin'
assert_unclaimed "$runtime_malformed_root"

# A complete but low-slack preflight is replaced only after both strict live
# validation passes and TTY authorization. The terminal receipt is neither
# copied nor moved again, and the renewed preflight is itself idempotent.
low_slack_root="$scratch_dir/low-slack-renewal"
clone_completed_baseline "$success_root" "$low_slack_root"
set_preflight_remaining_seconds "$low_slack_root" \
  "$((CUBS_STOCK_B_MIN_PREFLIGHT_SLACK_SECONDS - 1))"
low_old_preflight_sha=$(sha256sum \
  "$low_slack_root/recovery/stock-a-physical-b-preflight" | awk '{print $1}')
low_baseline_sha=$(sha256sum \
  "$low_slack_root/recovery/stock-a-baseline-evidence" | awk '{print $1}')
low_baseline_inode=$(stat -c '%d:%i' \
  "$low_slack_root/recovery/stock-a-baseline-evidence")
run_adoption "$low_slack_root" >"$low_slack_root/renew.log" 2>&1
low_new_preflight_sha=$(sha256sum \
  "$low_slack_root/recovery/stock-a-physical-b-preflight" | awk '{print $1}')
[[ "$low_new_preflight_sha" != "$low_old_preflight_sha" && \
   $(sha256sum "$low_slack_root/recovery/stock-a-baseline-evidence" | awk '{print $1}') == "$low_baseline_sha" && \
   $(stat -c '%d:%i' "$low_slack_root/recovery/stock-a-baseline-evidence") == "$low_baseline_inode" && \
   $(<"$low_slack_root/mock-state/fetch-count") == 4 ]] || {
  printf 'error: low-slack renewal changed the one-shot baseline or skipped controls\n' >&2
  exit 1
}
verify_published_preflight "$low_slack_root"
run_adoption "$low_slack_root" >"$low_slack_root/idempotent.log" 2>&1
[[ $(sha256sum "$low_slack_root/recovery/stock-a-physical-b-preflight" | awk '{print $1}') == "$low_new_preflight_sha" && \
   $(<"$low_slack_root/mock-state/fetch-count") == 8 ]] || {
  printf 'error: renewed low-slack preflight was not idempotent\n' >&2
  exit 1
}

# An expired predecessor is the durable state left by a crash before the
# renewal rename. Reauthorization replaces it atomically; a replay models a
# crash immediately after publication and must preserve the renewed bytes.
expired_root="$scratch_dir/expired-renewal-crash"
clone_completed_baseline "$success_root" "$expired_root"
set_preflight_remaining_seconds "$expired_root" -30
expired_old_preflight_sha=$(sha256sum \
  "$expired_root/recovery/stock-a-physical-b-preflight" | awk '{print $1}')
expired_baseline_sha=$(sha256sum \
  "$expired_root/recovery/stock-a-baseline-evidence" | awk '{print $1}')
run_adoption "$expired_root" >"$expired_root/renew-after-crash.log" 2>&1
expired_new_preflight_sha=$(sha256sum \
  "$expired_root/recovery/stock-a-physical-b-preflight" | awk '{print $1}')
[[ "$expired_new_preflight_sha" != "$expired_old_preflight_sha" && \
   $(sha256sum "$expired_root/recovery/stock-a-baseline-evidence" | awk '{print $1}') == "$expired_baseline_sha" && \
   $(<"$expired_root/mock-state/fetch-count") == 4 ]] || {
  printf 'error: expired preflight crash reconciliation was not atomic\n' >&2
  exit 1
}
verify_published_preflight "$expired_root"
run_adoption "$expired_root" >"$expired_root/post-publication-replay.log" 2>&1
[[ $(sha256sum "$expired_root/recovery/stock-a-physical-b-preflight" | awk '{print $1}') == "$expired_new_preflight_sha" && \
   $(<"$expired_root/mock-state/fetch-count") == 8 ]] || {
  printf 'error: post-renewal crash replay changed fresh preflight authority\n' >&2
  exit 1
}

# A crash after the atomic move but before preflight publication resumes from
# the claimed receipt and publishes the same strict v3 evidence.
crash_root="$scratch_dir/crash-after-move"
mkdir -p "$crash_root"
create_finalized_receipt "$crash_root" MOCK_CUBS_SERIAL claimed
run_adoption "$crash_root" >"$crash_root/resume.log" 2>&1
[[ -f "$crash_root/recovery/stock-a-baseline-evidence" && -f "$crash_root/recovery/stock-a-physical-b-preflight" ]] || {
  printf 'error: post-move crash reconciliation did not complete\n' >&2
  exit 1
}
verify_published_preflight "$crash_root"

# Once the baseline/preflight pair has been consumed, absence is terminal and
# the canonical receipt cannot be recreated or replayed.
mkdir -m 0700 "$success_root/consumed-simulation"
mv -T -- "$success_root/recovery/stock-a-baseline-evidence" "$success_root/consumed-simulation/stock-a-baseline-evidence"
mv -T -- "$success_root/recovery/stock-a-physical-b-preflight" "$success_root/consumed-simulation/stock-a-preflight"
expect_adoption_failure "$success_root" 'consumed baseline replay'
[[ ! -e "$canonical_source" && ! -e "$success_root/recovery/stock-a-baseline-evidence" ]] || {
  printf 'error: consumed baseline replay recreated active authority\n' >&2
  exit 1
}

# Foreign serial binding and byte tampering fail before the move claim.
foreign_root="$scratch_dir/foreign-binding"
mkdir -p "$foreign_root"
create_finalized_receipt "$foreign_root" OTHER_SERIAL source
expect_adoption_failure "$foreign_root" 'foreign receipt serial binding'
assert_unclaimed "$foreign_root"

tamper_root="$scratch_dir/receipt-tamper"
mkdir -p "$tamper_root"
create_finalized_receipt "$tamper_root" MOCK_CUBS_SERIAL source
tamper_sha=$(<"$tamper_root/receipt.sha256")
printf 'unexpected=field\n' >>"$tamper_root/recovery/consumed/stock-restore-${CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID}-$tamper_sha"
expect_adoption_failure "$tamper_root" 'receipt byte tamper'
assert_unclaimed "$tamper_root"

mode_root="$scratch_dir/unsafe-mode"
mkdir -p "$mode_root"
create_finalized_receipt "$mode_root" MOCK_CUBS_SERIAL source
mode_sha=$(<"$mode_root/receipt.sha256")
chmod 0644 "$mode_root/recovery/consumed/stock-restore-${CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID}-$mode_sha"
expect_adoption_failure "$mode_root" 'non-private receipt mode'
assert_unclaimed "$mode_root"

# A duplicated source/active claim is not a resumable crash shape.
duplicate_root="$scratch_dir/duplicate-claim"
mkdir -p "$duplicate_root"
create_finalized_receipt "$duplicate_root" MOCK_CUBS_SERIAL source
duplicate_sha=$(<"$duplicate_root/receipt.sha256")
cp -- "$duplicate_root/recovery/consumed/stock-restore-${CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID}-$duplicate_sha" "$duplicate_root/recovery/stock-a-baseline-evidence"
chmod 0600 "$duplicate_root/recovery/stock-a-baseline-evidence"
expect_adoption_failure "$duplicate_root" 'duplicated move claim'

# Initial live gates, full vendor_boot fetch control, and the strict getvar
# parser all fail closed without claiming the finalized receipt.
product_root="$scratch_dir/wrong-product"
mkdir -p "$product_root"
create_finalized_receipt "$product_root" MOCK_CUBS_SERIAL source
MOCK_PRODUCT=not-cubs expect_adoption_failure "$product_root" 'wrong live product'
assert_unclaimed "$product_root"

slot_root="$scratch_dir/wrong-slot"
mkdir -p "$slot_root"
create_finalized_receipt "$slot_root" MOCK_CUBS_SERIAL source
MOCK_CURRENT_SLOT=b expect_adoption_failure "$slot_root" 'wrong current physical slot'
assert_unclaimed "$slot_root"

drift_root="$scratch_dir/physical-size-drift"
mkdir -p "$drift_root"
create_finalized_receipt "$drift_root" MOCK_CUBS_SERIAL source
MOCK_DRIFT_PARTITION=boot_b expect_adoption_failure "$drift_root" 'physical B size drift'
assert_unclaimed "$drift_root"

fetch_root="$scratch_dir/short-fetch"
mkdir -p "$fetch_root"
create_finalized_receipt "$fetch_root" MOCK_CUBS_SERIAL source
MOCK_FETCH_MODE=short expect_adoption_failure "$fetch_root" 'short vendor_boot fetch'
assert_unclaimed "$fetch_root"

parser_root="$scratch_dir/duplicate-getvar"
mkdir -p "$parser_root"
create_finalized_receipt "$parser_root" MOCK_CUBS_SERIAL source
MOCK_DUPLICATE_VAR=product expect_adoption_failure "$parser_root" 'duplicate fastboot getvar response'
assert_unclaimed "$parser_root"

failed_root="$scratch_dir/failed-getvar"
mkdir -p "$failed_root"
create_finalized_receipt "$failed_root" MOCK_CUBS_SERIAL source
MOCK_FAILED_VAR=product expect_adoption_failure "$failed_root" 'FAILED marker in fastboot getvar response'
assert_unclaimed "$failed_root"

# Inputs and live gates are repeated after the unbounded authorization pause.
post_tty_source_root="$scratch_dir/post-tty-source-tamper"
mkdir -p "$post_tty_source_root"
create_finalized_receipt "$post_tty_source_root" MOCK_CUBS_SERIAL source
MOCK_TTY_MUTATION=source-tamper expect_adoption_failure "$post_tty_source_root" 'post-TTY receipt mutation'
assert_unclaimed "$post_tty_source_root"

post_tty_live_root="$scratch_dir/post-tty-live-change"
mkdir -p "$post_tty_live_root"
create_finalized_receipt "$post_tty_live_root" MOCK_CUBS_SERIAL source
MOCK_TTY_MUTATION=current-slot expect_adoption_failure "$post_tty_live_root" 'post-TTY live slot change'
assert_unclaimed "$post_tty_live_root"

printf 'finalized stock-restore baseline bridge simulation passed\n'
