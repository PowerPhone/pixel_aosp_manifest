#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
mock_fastboot="$test_dir/mock-stock-b-fastboot.sh"
# shellcheck source=../../config/release.env disable=SC1091
source "$project_root/config/release.env"
# shellcheck source=../../config/targets/cubs/release.env disable=SC1091
source "$project_root/config/targets/cubs/release.env"
# shellcheck source=../../config/recovery.env disable=SC1091
source "$project_root/config/recovery.env"

for command_name in awk chmod date find grep mktemp realpath script sed sha256sum \
    sleep stat unzip; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'error: missing test command: %s\n' "$command_name" >&2
    exit 1
  }
done
[[ -x "$mock_fastboot" ]] || {
  printf 'error: mock fastboot is not executable: %s\n' "$mock_fastboot" >&2
  exit 1
}
factory_image="$project_root/downloads/$FACTORY_IMAGE_FILENAME"
[[ -f "$factory_image" ]] || {
  printf 'error: pinned factory archive is required for this focused simulation\n' >&2
  exit 1
}
stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
stock_images="$stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
[[ -f "$stock_images" ]] || {
  printf 'error: extracted pinned nested stock ZIP is required for this simulation\n' >&2
  exit 1
}

physical_partitions=(
  abl bl31 cap cpm dbc dbl
  dram_init_0 dram_init_1 dram_init_2 dram_init_3
  dram_init_4 dram_init_5 dram_init_6 dram_init_7
  dram_init_8 dram_init_9 dram_init_10 dram_init_11
  dram_phy gc gdmc gsa_bl1 gsa_fw tzsw modem
  boot init_boot dtbo vendor_boot vendor_kernel_boot pvmfw
  vbmeta_system vbmeta_vendor vbmeta
)
(( ${#physical_partitions[@]} == 34 )) || {
  printf 'error: focused test physical allowlist does not contain 34 entries\n' >&2
  exit 1
}

scratch_parent="$project_root/work/stock-b-physical-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
prepare_runner=
trial_runner=
cleanup() {
  if [[ -n "${prepare_runner:-}" && \
        "$prepare_runner" == "$project_root/scripts/".prepare-stock-b-test.* ]]; then
    rm -f -- "$prepare_runner"
  fi
  if [[ -n "${trial_runner:-}" && \
        "$trial_runner" == "$project_root/scripts/".trial-stock-b-test.* ]]; then
    rm -f -- "$trial_runner"
  fi
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

production_fastboot_sha256=$PLATFORM_TOOLS_FASTBOOT_SHA256
mock_fastboot_sha256=$(sha256sum "$mock_fastboot" | awk '{print $1}')
prepare_runner=$(mktemp "$project_root/scripts/.prepare-stock-b-test.XXXXXX")
trial_runner=$(mktemp "$project_root/scripts/.trial-stock-b-test.XXXXXX")
# shellcheck disable=SC2016 # Literal test substitutions preserve runtime variables.
sed \
  -e "s/^expected_fastboot_sha256=$production_fastboot_sha256$/expected_fastboot_sha256=$mock_fastboot_sha256/" \
  -e '/^source "$script_dir\/lib\/recovery-handoff.sh"$/a CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256=${MOCK_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256:?set test baseline digest}' \
  "$project_root/scripts/prepare-stock-b-physical.sh" >"$prepare_runner"
# shellcheck disable=SC2016 # Literal test substitutions must preserve runtime variable names.
sed \
  -e "s/^expected_fastboot_sha256=$production_fastboot_sha256$/expected_fastboot_sha256=$mock_fastboot_sha256/" \
  -e '/^source "$script_dir\/lib\/recovery-handoff.sh"$/a CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256=${MOCK_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256:?set test baseline digest}' \
  -e 's@^[[:space:]]*verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"$@: # TEST ONLY: preparer verifies the exact factory archive@' \
  -e 's@^[[:space:]]*"$script_dir/extract-stock.sh"$@: # TEST ONLY: preparer extracts and verifies stock first@' \
  -e 's@^[[:space:]]*current_inner_sha=.*sha256sum.*stock_images.*$@  current_inner_sha=$CUBS_STOCK_INNER_IMAGE_SHA256 # TEST ONLY: preparer verifies the exact nested archive@' \
  "$project_root/scripts/verify-stock-b-fastbootd-lifeboat.sh" >"$trial_runner"
chmod 0755 "$prepare_runner" "$trial_runner"
grep -Fxq "expected_fastboot_sha256=$mock_fastboot_sha256" "$prepare_runner"
grep -Fxq "expected_fastboot_sha256=$mock_fastboot_sha256" "$trial_runner"
# shellcheck disable=SC2016 # Count literal replacement text, not expanded test variables.
[[ $(grep -Fc ': # TEST ONLY: preparer verifies the exact factory archive' \
      "$trial_runner") -eq 2 && \
   $(grep -Fc ': # TEST ONLY: preparer extracts and verifies stock first' \
      "$trial_runner") -eq 1 && \
   $(grep -Fc 'current_inner_sha=$CUBS_STOCK_INNER_IMAGE_SHA256 # TEST ONLY:' \
      "$trial_runner") -eq 1 ]] || {
  printf 'error: test-only trial archive-verification substitution drifted\n' >&2
  exit 1
}

state_dir="$scratch_dir/state"
recovery_dir="$scratch_dir/recovery"
log_file="$scratch_dir/fastboot.log"
mkdir -m 0700 "$state_dir" "$recovery_dir"
: >"$log_file"
printf 'bootloader\n' >"$state_dir/mode"
printf 'a\n' >"$state_dir/current_slot"

unzip -l "$stock_images" >"$scratch_dir/zip-list"
for partition in "${physical_partitions[@]}"; do
  image_size=$(awk -v name="$partition.img" '$4 == name {print $1}' \
    "$scratch_dir/zip-list")
  [[ "$image_size" =~ ^[1-9][0-9]*$ ]] || {
    printf 'error: cannot read one exact %s.img size from nested ZIP\n' \
      "$partition" >&2
    exit 1
  }
  size_hex=$(printf '0x%x' "$image_size")
  printf '%s\n' "$size_hex" >"$state_dir/size_${partition}_a"
  printf '%s\n' "$size_hex" >"$state_dir/size_${partition}_b"
done
logical_partitions=(system system_dlkm system_ext product vendor vendor_dlkm)
logical_a_sizes=(526f0000 c50000 1ed65000 1308a2000 444a6000 281d000)
for ((logical_index = 0; logical_index < ${#logical_partitions[@]}; logical_index += 1)); do
  partition=${logical_partitions[$logical_index]}
  printf '0x%s\n' "${logical_a_sizes[$logical_index]}" \
    >"$state_dir/size_${partition}_a"
done
serial=MOCK_CUBS_SERIAL
created=$(date +%s)

# The production bridge is pinned to one private terminal restore receipt.
# This focused simulation uses the same exact schema and overrides only its
# digest in generated test runners; production scripts still reject this mock.
baseline_transaction_id=$CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID
baseline_serial_binding=$(printf '%s\0%s' "$baseline_transaction_id" "$serial" | \
  sha256sum | awk '{print $1}')
baseline_physical_b_lines=
for partition in "${physical_partitions[@]}"; do
  size_hex=$(sed -n '1p' "$state_dir/size_${partition}_b")
  size_hex=${size_hex#0x}
  while [[ ${#size_hex} -gt 1 && ${size_hex:0:1} == 0 ]]; do
    size_hex=${size_hex:1}
  done
  baseline_physical_b_lines+="${partition}_b=$size_hex"$'\n'
done
baseline_physical_b_sizes_sha=$(printf '%s' "$baseline_physical_b_lines" | \
  sha256sum | awk '{print $1}')
{
  printf 'schema=cubs-stock-restore-v2\n'
  printf 'state=retiring_evidence\n'
  printf 'created_epoch=%s\n' "$created"
  printf 'transaction_id=%s\n' "$baseline_transaction_id"
  printf 'serial_binding_sha256=%s\n' "$baseline_serial_binding"
  printf 'device=%s\n' "$DEVICE_CODENAME"
  printf 'stock_build_id=%s\n' "$STOCK_BUILD_ID"
  printf 'factory_sha256=%s\n' "$FACTORY_IMAGE_SHA256"
  printf 'physical_b_sizes_sha256=%s\n' "$baseline_physical_b_sizes_sha"
  printf 'lineage_sha256=%064d\n' 2
  printf 'handoff_sha256=%064d\n' 3
  printf 'stock_b_source=direct_factory_physical_b\n'
  printf 'stock_b_provenance_sha256=%064d\n' 4
  printf 'adopted_flash_transaction_sha256=%064d\n' 5
  printf 'adopted_flash_serial_binding_sha256=%064d\n' 6
  printf 'adopted_runtime_attestation_sha256=%s\n' \
    "$CUBS_FINALIZED_STOCK_RESTORE_ADOPTED_RUNTIME_ATTESTATION_SHA256"
  printf 'recovery_policy_sha256=%s\n' \
    "$CUBS_FINALIZED_STOCK_RESTORE_RECOVERY_POLICY_SHA256"
} >"$recovery_dir/stock-a-baseline-evidence"
chmod 0600 "$recovery_dir/stock-a-baseline-evidence"
baseline_sha=$(sha256sum "$recovery_dir/stock-a-baseline-evidence" | awk '{print $1}')

logical_size_lines=
for ((logical_index = 0; logical_index < ${#logical_partitions[@]}; logical_index += 1)); do
  logical_size_lines+="${logical_partitions[$logical_index]}_a=${logical_a_sizes[$logical_index]}"$'\n'
done
logical_sizes_sha=$(printf '%s' "$logical_size_lines" | sha256sum | awk '{print $1}')
[[ "$logical_sizes_sha" == 8a7d16993d0f210b9be5150c947d8ca094d9094e3a4a45f0bddee34d1c1ba81b ]] || {
  printf 'error: pinned expanded logical-size fixture drifted\n' >&2
  exit 1
}

preflight_id=0123456789abcdef0123456789abcdef
serial_binding=$(printf '%s\0%s' "$preflight_id" "$serial" | \
  sha256sum | awk '{print $1}')
expires=$((created + CUBS_STOCK_A_PHYSICAL_B_PREFLIGHT_SECONDS))
{
  printf 'schema=cubs-stock-a-physical-b-preflight-v3\n'
  printf 'state=bootloader_verified\n'
  printf 'created_epoch=%s\n' "$created"
  printf 'expires_epoch=%s\n' "$expires"
  printf 'bootloader_verified_epoch=%s\n' "$created"
  printf 'preflight_id=%s\n' "$preflight_id"
  printf 'serial_binding_sha256=%s\n' "$serial_binding"
  printf 'device=%s\n' "$DEVICE_CODENAME"
  printf 'stock_build_id=%s\n' "$STOCK_BUILD_ID"
  printf 'stock_fingerprint_sha256=%s\n' "$CUBS_STOCK_FINGERPRINT_SHA256"
  printf 'factory_sha256=%s\n' "$FACTORY_IMAGE_SHA256"
  printf 'full_ota_sha256=%s\n' "$FULL_OTA_SHA256"
  printf 'source_slot=a\n'
  printf 'baseline_kind=finalized_stock_restore_v2\n'
  printf 'baseline_transaction_id=%s\n' "$baseline_transaction_id"
  printf 'baseline_evidence_sha256=%s\n' "$baseline_sha"
  printf 'stock_a_logical_sizes_sha256=%s\n' "$logical_sizes_sha"
  for ((logical_index = 0; logical_index < ${#logical_partitions[@]}; logical_index += 1)); do
    printf 'logical_%s_a_size=%s\n' \
      "${logical_partitions[$logical_index]}" "${logical_a_sizes[$logical_index]}"
  done
  printf 'preparation_policy_sha256=%s\n' \
    "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256"
} >"$recovery_dir/stock-a-physical-b-preflight"
chmod 0600 "$recovery_dir/stock-a-physical-b-preflight"

# An exact but expired OTA-resume marker has no resume authority. The direct
# transaction must archive it under the lock rather than silently delete it.
sideload_created=$((created - 7200))
sideload_serial_sha=$(printf '%s' "$serial" | sha256sum | awk '{print $1}')
{
  printf 'created=%s\n' "$sideload_created"
  printf 'serial_sha256=%s\n' "$sideload_serial_sha"
  printf 'ota_sha256=%s\n' "$FULL_OTA_SHA256"
  printf 'source_slot=a\n'
} >"$recovery_dir/sideload-preflight"
chmod 0600 "$recovery_dir/sideload-preflight"
sideload_sha=$(sha256sum "$recovery_dir/sideload-preflight" | awk '{print $1}')

common_environment=(
  MOCK_STOCK_B_STATE_DIR="$state_dir"
  MOCK_STOCK_B_LOG="$log_file"
  MOCK_STOCK_B_SERIAL="$serial"
  FASTBOOT="$mock_fastboot"
  CUBS_FASTBOOT_SERIAL="$serial"
  CUBS_RECOVERY_STATE_DIR="$recovery_dir"
  MOCK_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256="$baseline_sha"
)

run_with_tty_confirmation() {
  local phrase=$1 command_string
  shift
  printf -v command_string '%q ' "$@"
  printf '%s\n' "$phrase" | \
    script --quiet --return --command "$command_string" /dev/null
}

if env "${common_environment[@]}" \
    CUBS_ALLOW_STOCK_B_WRITE=1 \
    CUBS_STOCK_B_CONFIRM=PREPARE_EXACT_STOCK_PHYSICAL_B_SET_ACTIVE_B_NO_REBOOT \
    "$project_root/scripts/prepare-stock-b-physical.sh" \
    >"$scratch_dir/production-digest-rejection.log" 2>&1; then
  printf 'error: production physical-B preparer accepted the mock fastboot\n' >&2
  exit 1
fi
grep -Fq 'fastboot does not match the pinned Platform-Tools binary digest' \
  "$scratch_dir/production-digest-rejection.log"
[[ ! -s "$log_file" ]] || {
  printf 'error: digest rejection occurred after a mock mutation\n' >&2
  exit 1
}

run_with_tty_confirmation \
  PREPARE_EXACT_STOCK_PHYSICAL_B_SET_ACTIVE_B_NO_REBOOT \
  env "${common_environment[@]}" \
    CUBS_ALLOW_STOCK_B_WRITE=1 \
    CUBS_STOCK_B_CONFIRM=PREPARE_EXACT_STOCK_PHYSICAL_B_SET_ACTIVE_B_NO_REBOOT \
    "$prepare_runner"

expected=()
for partition in "${physical_partitions[@]}"; do
  expected+=("flash ${partition}_b")
done
expected+=('fetch vendor_boot_b' 'set_active b')
mapfile -t actual <"$log_file"
(( ${#actual[@]} == ${#expected[@]} )) || {
  printf 'error: physical-B preparation command count mismatch\n' >&2
  exit 1
}
for ((index = 0; index < ${#expected[@]}; index += 1)); do
  [[ "${actual[$index]}" == "${expected[$index]}" ]] || {
    printf 'error: physical-B command %d: expected %s, found %s\n' \
      "$index" "${expected[$index]}" "${actual[$index]}" >&2
    exit 1
  }
done
[[ $(sed -n '1p' "$state_dir/current_slot") == b && \
   $(sed -n '1p' "$state_dir/mode") == bootloader && \
   $(sed -n '1p' "$state_dir/slot_b_successful") == no ]] || {
  printf 'error: preparer did not leave selected B in bootloader with mock successful=no\n' >&2
  exit 1
}
grep -Fxq 'schema=cubs-stock-b-preparation-v2' \
  "$recovery_dir/stock-b-preparation-receipt"
grep -Fxq 'state=ready' "$recovery_dir/stock-b-preparation-receipt"
grep -Fxq 'android_b_booted=no' "$recovery_dir/stock-b-preparation-receipt"
grep -Fxq "stock_a_baseline_evidence_sha256=$baseline_sha" \
  "$recovery_dir/stock-b-preparation-receipt"
grep -Fxq "stock_a_logical_sizes_sha256=$logical_sizes_sha" \
  "$recovery_dir/stock-b-preparation-receipt"
grep -Fxq 'acknowledged_flash_count=34' \
  "$recovery_dir/stock-b-preparation-receipt"
[[ $(stat -c '%a' "$recovery_dir/stock-b-preparation-receipt") == 600 && \
   $(wc -l <"$recovery_dir/stock-b-source-payload-manifest") == 34 ]] || {
  printf 'error: private preparation receipt or source manifest is malformed\n' >&2
  exit 1
}
[[ ! -e "$recovery_dir/sideload-preflight" && \
   -f "$recovery_dir/retired/sideload-preflight-${sideload_created}-${sideload_sha}.abandoned-for-physical-b" ]] || {
  printf 'error: exact expired sideload marker was not collision-safely archived\n' >&2
  exit 1
}

# A ready receipt can expire while WSL USB forwarding is repaired. Backdate
# the baseline-bound preflight/receipt pair while preserving every exact
# interval and hash relationship, proving refresh accepts historical—not merely
# fresh—evidence. It must perform two complete live vendor_boot controls around
# its TTY gate, refresh only receipt timestamps, and emit no mutation.
historical_preflight_created=$(( $(date +%s) - 7200 ))
historical_preflight_expires=$((
  historical_preflight_created + CUBS_STOCK_A_PHYSICAL_B_PREFLIGHT_SECONDS
))
sed -i \
  -e "s/^created_epoch=.*/created_epoch=$historical_preflight_created/" \
  -e "s/^expires_epoch=.*/expires_epoch=$historical_preflight_expires/" \
  -e "s/^bootloader_verified_epoch=.*/bootloader_verified_epoch=$historical_preflight_created/" \
  "$recovery_dir/stock-a-physical-b-preflight"
historical_preflight_sha=$(sha256sum \
  "$recovery_dir/stock-a-physical-b-preflight" | awk '{print $1}')
historical_receipt_created=$((historical_preflight_created + 1))
historical_receipt_expires=$((
  historical_receipt_created + CUBS_STOCK_B_PREPARATION_RECEIPT_SECONDS
))
sed -i \
  -e "s/^authorization_epoch=.*/authorization_epoch=$historical_preflight_created/" \
  -e "s/^created_epoch=.*/created_epoch=$historical_receipt_created/" \
  -e "s/^expires_epoch=.*/expires_epoch=$historical_receipt_expires/" \
  -e "s/^stock_a_preflight_sha256=.*/stock_a_preflight_sha256=$historical_preflight_sha/" \
  "$recovery_dir/stock-b-preparation-receipt"
ready_created_before=$(sed -n 's/^created_epoch=//p' \
  "$recovery_dir/stock-b-preparation-receipt")
ready_sha_before=$(sha256sum "$recovery_dir/stock-b-preparation-receipt" | awk '{print $1}')
post_fetch_before=$(sed -n '1p' "$state_dir/post_activation_fetch_count" 2>/dev/null || printf '0\n')
command_count_before_refresh=$(wc -l <"$log_file")
run_with_tty_confirmation \
  REFRESH_EXACT_STOCK_PHYSICAL_B_RECEIPT_NO_REBOOT \
  env "${common_environment[@]}" \
    CUBS_ALLOW_STOCK_B_WRITE=1 \
    CUBS_STOCK_B_CONFIRM=REFRESH_EXACT_STOCK_PHYSICAL_B_RECEIPT_NO_REBOOT \
    "$prepare_runner" refresh-ready
ready_created_after=$(sed -n 's/^created_epoch=//p' \
  "$recovery_dir/stock-b-preparation-receipt")
ready_sha_after=$(sha256sum "$recovery_dir/stock-b-preparation-receipt" | awk '{print $1}')
post_fetch_after=$(sed -n '1p' "$state_dir/post_activation_fetch_count")
[[ "$ready_created_after" -gt "$ready_created_before" && \
   "$ready_sha_after" != "$ready_sha_before" && \
   "$post_fetch_after" -eq $((post_fetch_before + 2)) && \
   $(wc -l <"$log_file") -eq "$command_count_before_refresh" && \
   $(sed -n '1p' "$state_dir/current_slot") == b && \
   $(sed -n '1p' "$state_dir/mode") == bootloader ]] || {
  printf 'error: ready refresh changed device state or omitted exact revalidation\n' >&2
  exit 1
}

# Exercise the conservative no-fastbootd-proof branch and its most dangerous
# crash boundary: set_active A took effect, but the host died before receipt
# promotion/consumption. The aborting_to_a receipt must resume on current A and
# must never issue a second slot change or mint lifeboat lineage.
abort_state_dir="$scratch_dir/abort-state"
abort_recovery_dir="$scratch_dir/abort-recovery"
abort_log_file="$scratch_dir/abort-fastboot.log"
cp -a -- "$state_dir" "$abort_state_dir"
cp -a -- "$recovery_dir" "$abort_recovery_dir"
: >"$abort_log_file"
abort_environment=(
  MOCK_STOCK_B_STATE_DIR="$abort_state_dir"
  MOCK_STOCK_B_LOG="$abort_log_file"
  MOCK_STOCK_B_SERIAL="$serial"
  FASTBOOT="$mock_fastboot"
  CUBS_FASTBOOT_SERIAL="$serial"
  CUBS_RECOVERY_STATE_DIR="$abort_recovery_dir"
  MOCK_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256="$baseline_sha"
)
if run_with_tty_confirmation \
    TRIAL_PREPARED_PHYSICAL_B_FASTBOOTD_ONLY_NEVER_ANDROID_B \
    env "${abort_environment[@]}" \
      MOCK_FAIL_BEFORE_REBOOT_FASTBOOT=1 \
      CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL=1 \
      CUBS_STOCK_B_FASTBOOTD_CONFIRM=TRIAL_PREPARED_PHYSICAL_B_FASTBOOTD_ONLY_NEVER_ANDROID_B \
      "$trial_runner"; then
  printf 'error: injected pre-fastbootd failure did not stop start\n' >&2
  exit 1
fi
grep -Fxq 'state=started' \
  "$abort_recovery_dir/stock-b-fastbootd-trial-receipt"
if run_with_tty_confirmation \
    RESUME_OR_FINALIZE_ONE_SHOT_PHYSICAL_B_FASTBOOTD_NEVER_ANDROID_B \
    env "${abort_environment[@]}" \
      MOCK_FAIL_AFTER_SET_ACTIVE_A=1 \
      CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL=1 \
      CUBS_STOCK_B_FASTBOOTD_CONFIRM=RESUME_OR_FINALIZE_ONE_SHOT_PHYSICAL_B_FASTBOOTD_NEVER_ANDROID_B \
      "$trial_runner" resume-finalize; then
  printf 'error: injected post-set-active-A failure did not stop abort\n' >&2
  exit 1
fi
[[ $(sed -n '1p' "$abort_state_dir/current_slot") == a ]] || {
  printf 'error: injected abort did not take effect on current slot A\n' >&2
  exit 1
}
grep -Fxq 'state=aborting_to_a' \
  "$abort_recovery_dir/stock-b-fastbootd-trial-receipt"
run_with_tty_confirmation \
  RESUME_OR_FINALIZE_ONE_SHOT_PHYSICAL_B_FASTBOOTD_NEVER_ANDROID_B \
  env "${abort_environment[@]}" \
    CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL=1 \
    CUBS_STOCK_B_FASTBOOTD_CONFIRM=RESUME_OR_FINALIZE_ONE_SHOT_PHYSICAL_B_FASTBOOTD_NEVER_ANDROID_B \
    "$trial_runner" resume-finalize
[[ $(grep -c '^set_active a$' "$abort_log_file") -eq 1 && \
   ! -e "$abort_recovery_dir/lifeboat-lineage" && \
   ! -e "$abort_recovery_dir/flash-handoff" && \
   ! -e "$abort_recovery_dir/stock-b-fastbootd-trial-receipt" && \
   ! -e "$abort_recovery_dir/stock-b-consumption-transaction" ]] || {
  printf 'error: abort-to-A continuation replayed mutation or minted lineage\n' >&2
  exit 1
}
abort_consumed_trial=$(find "$abort_recovery_dir/consumed" -mindepth 2 \
  -maxdepth 2 -type f -name fastbootd-trial-receipt -print -quit)
grep -Fxq 'state=aborted_to_a' "$abort_consumed_trial"

before_trial_count=${#actual[@]}
if env "${common_environment[@]}" \
    CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL=1 \
    CUBS_STOCK_B_FASTBOOTD_CONFIRM=TRIAL_PREPARED_PHYSICAL_B_FASTBOOTD_ONLY_NEVER_ANDROID_B \
    "$project_root/scripts/verify-stock-b-fastbootd-lifeboat.sh" \
    >"$scratch_dir/trial-production-digest-rejection.log" 2>&1; then
  printf 'error: production fastbootd trial accepted the mock fastboot\n' >&2
  exit 1
fi
grep -Fq 'fastboot does not match the pinned Platform-Tools binary digest' \
  "$scratch_dir/trial-production-digest-rejection.log"
[[ $(wc -l <"$log_file") == "$before_trial_count" ]] || {
  printf 'error: trial digest rejection occurred after a mock mutation\n' >&2
  exit 1
}

if run_with_tty_confirmation \
    TRIAL_PREPARED_PHYSICAL_B_FASTBOOTD_ONLY_NEVER_ANDROID_B \
    env "${common_environment[@]}" \
      MOCK_FAIL_AFTER_REBOOT_FASTBOOT=1 \
      CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL=1 \
      CUBS_STOCK_B_FASTBOOTD_CONFIRM=TRIAL_PREPARED_PHYSICAL_B_FASTBOOTD_ONLY_NEVER_ANDROID_B \
      "$trial_runner"; then
  printf 'error: injected post-reboot-fastboot USB failure did not stop start\n' >&2
  exit 1
fi
grep -Fxq 'state=started' "$recovery_dir/stock-b-fastbootd-trial-receipt"
[[ $(sed -n '1p' "$state_dir/mode") == fastbootd && \
   $(tail -n 1 "$log_file") == 'reboot fastboot' ]] || {
  printf 'error: injected trial did not leave resumable started+fastbootd state\n' >&2
  exit 1
}
assert_trial_getvar_rejected() {
  local description=$1 before_count
  shift
  before_count=$(wc -l <"$log_file")
  if run_with_tty_confirmation \
      RESUME_OR_FINALIZE_ONE_SHOT_PHYSICAL_B_FASTBOOTD_NEVER_ANDROID_B \
      env "${common_environment[@]}" "$@" \
        CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL=1 \
        CUBS_STOCK_B_FASTBOOTD_CONFIRM=RESUME_OR_FINALIZE_ONE_SHOT_PHYSICAL_B_FASTBOOTD_NEVER_ANDROID_B \
        "$trial_runner" resume-finalize; then
    printf 'error: strict fastbootd parser accepted %s\n' "$description" >&2
    exit 1
  fi
  [[ $(wc -l <"$log_file") -eq "$before_count" && \
     $(sed -n '1p' "$state_dir/mode") == fastbootd && \
     ! -e "$state_dir/fastbootd_physical_size_probe" ]] || {
    printf 'error: rejected parser case changed fastboot state: %s\n' \
      "$description" >&2
    exit 1
  }
  grep -Fxq 'state=started' \
    "$recovery_dir/stock-b-fastbootd-trial-receipt"
}

assert_trial_getvar_rejected extra-failed-line \
  MOCK_EXTRA_GETVAR_FAILURE=1
assert_trial_getvar_rejected duplicate-value \
  MOCK_GETVAR_FAULT_VARIABLE=product \
  MOCK_GETVAR_FAULT_MODE=duplicate_value
assert_trial_getvar_rejected contradictory-values \
  MOCK_GETVAR_FAULT_VARIABLE=current-slot \
  MOCK_GETVAR_FAULT_MODE=contradictory_value
assert_trial_getvar_rejected value-plus-failed \
  MOCK_GETVAR_FAULT_VARIABLE=product \
  MOCK_GETVAR_FAULT_MODE=value_and_failed
assert_trial_getvar_rejected nonzero-value-status \
  MOCK_GETVAR_FAULT_VARIABLE=product \
  MOCK_GETVAR_FAULT_MODE=nonzero_value
assert_trial_getvar_rejected malformed-keyed-value \
  MOCK_GETVAR_FAULT_VARIABLE=product \
  MOCK_GETVAR_FAULT_MODE=malformed_value
assert_trial_getvar_rejected wrong-single-value \
  MOCK_GETVAR_FAULT_VARIABLE=product \
  MOCK_GETVAR_FAULT_MODE=wrong_value
assert_trial_getvar_rejected explicit-a-is-logical-no \
  MOCK_GETVAR_FAULT_VARIABLE=is-logical:system_a \
  MOCK_GETVAR_FAULT_MODE=is_logical_no
assert_trial_getvar_rejected absent-response-status-two \
  MOCK_GETVAR_FAULT_VARIABLE=is-logical:system \
  MOCK_GETVAR_FAULT_MODE=absence_status_two

run_with_tty_confirmation \
  RESUME_OR_FINALIZE_ONE_SHOT_PHYSICAL_B_FASTBOOTD_NEVER_ANDROID_B \
  env "${common_environment[@]}" \
    MOCK_ABSENT_GETVAR_STATUS_ONE=1 \
    CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL=1 \
    CUBS_STOCK_B_FASTBOOTD_CONFIRM=RESUME_OR_FINALIZE_ONE_SHOT_PHYSICAL_B_FASTBOOTD_NEVER_ANDROID_B \
    "$trial_runner" resume-finalize
mapfile -t actual <"$log_file"
[[ "${actual[-2]}" == 'reboot fastboot' && \
   "${actual[-1]}" == 'reboot bootloader' ]] || {
  printf 'error: one-shot trial did not perform only the reviewed round trip\n' >&2
  exit 1
}
(( ${#actual[@]} == before_trial_count + 2 )) || {
  printf 'error: one-shot trial emitted an unexpected fastboot command\n' >&2
  exit 1
}
[[ $(sed -n '1p' "$state_dir/post_activation_fetch_count") -ge 3 ]] || {
  printf 'error: trial did not repeat the live full vendor_boot_b byte control\n' >&2
  exit 1
}
[[ ! -e "$state_dir/fastbootd_physical_size_probe" ]] || {
  printf 'error: trial queried a physical partition size inside fastbootd\n' >&2
  exit 1
}
[[ $(sed -n '1p' "$state_dir/current_slot") == b && \
   $(sed -n '1p' "$state_dir/mode") == bootloader ]] || {
  printf 'error: fastbootd trial did not return current B to bootloader\n' >&2
  exit 1
}
grep -Fxq 'stock_b_source=direct_factory_physical_b' \
  "$recovery_dir/lifeboat-lineage"
grep -Fxq 'handoff_kind=physical_b_lifeboat' \
  "$recovery_dir/flash-handoff"
for active in \
    stock-a-baseline-evidence stock-a-physical-b-preflight \
    stock-b-preparation-receipt stock-b-source-payload-manifest \
    stock-b-fastbootd-trial-receipt; do
  [[ ! -e "$recovery_dir/$active" && ! -L "$recovery_dir/$active" ]] || {
    printf 'error: consumed direct evidence remains active: %s\n' "$active" >&2
    exit 1
  }
done
mapfile -t consumed_dirs < <(find "$recovery_dir/consumed" -mindepth 1 \
  -maxdepth 1 -type d -name 'stock-b-*')
(( ${#consumed_dirs[@]} == 1 )) || {
  printf 'error: expected exactly one consumed direct-provenance directory\n' >&2
  exit 1
}
consumed_dir=${consumed_dirs[0]}
for evidence in receipt source-payload-manifest stock-a-preflight \
    stock-a-baseline-evidence fastbootd-trial-receipt; do
  [[ -f "$consumed_dir/$evidence" && \
     $(stat -c '%a' "$consumed_dir/$evidence") == 600 ]] || {
    printf 'error: consumed provenance evidence is missing or non-private: %s\n' \
      "$evidence" >&2
    exit 1
  }
done
grep -Fxq 'schema=cubs-stock-b-fastbootd-trial-v4' \
  "$consumed_dir/fastbootd-trial-receipt"
grep -Fxq 'state=verified' "$consumed_dir/fastbootd-trial-receipt"
grep -Fxq 'android_b_booted=no' "$consumed_dir/fastbootd-trial-receipt"
grep -Fxq 'logical_base_has_slot_mode=no' \
  "$consumed_dir/fastbootd-trial-receipt"
grep -Fxq 'logical_namespace=a_only' \
  "$consumed_dir/fastbootd-trial-receipt"
[[ $(grep -Ec '^logical_(system|system_dlkm|system_ext|product|vendor|vendor_dlkm)_a_size=[0-9a-f]+$' \
      "$consumed_dir/fastbootd-trial-receipt") == 6 && \
   $(grep -Ec '^logical_(system|system_dlkm|system_ext|product|vendor|vendor_dlkm)_b_size=' \
      "$consumed_dir/fastbootd-trial-receipt") == 0 ]] || {
  printf 'error: trial receipt does not record the exact A-only namespace\n' >&2
  exit 1
}
trial_sha=$(sha256sum "$consumed_dir/fastbootd-trial-receipt" | awk '{print $1}')
grep -Fxq "stock_b_provenance_sha256=$trial_sha" \
  "$recovery_dir/lifeboat-lineage"

command_count_before_rerun=$(wc -l <"$log_file")
if env "${common_environment[@]}" \
    CUBS_ALLOW_STOCK_B_FASTBOOTD_TRIAL=1 \
    CUBS_STOCK_B_FASTBOOTD_CONFIRM=TRIAL_PREPARED_PHYSICAL_B_FASTBOOTD_ONLY_NEVER_ANDROID_B \
    "$trial_runner" >"$scratch_dir/second-trial-rejection.log" 2>&1; then
  printf 'error: one-shot fastbootd trial was accepted twice\n' >&2
  exit 1
fi
grep -Fq 'an active recovery lineage, handoff, or trial receipt already exists' \
  "$scratch_dir/second-trial-rejection.log"
[[ $(wc -l <"$log_file") == "$command_count_before_rerun" ]] || {
  printf 'error: rejected second trial emitted a fastboot command\n' >&2
  exit 1
}

printf 'mocked exact physical-B preparation and one-shot fastbootd lifeboat passed\n'
