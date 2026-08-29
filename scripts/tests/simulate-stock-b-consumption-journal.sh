#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
set -euo pipefail
export LC_ALL=C

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
# shellcheck source=../lib/common.sh disable=SC1091
source "$project_root/scripts/lib/common.sh"

scratch_parent="$project_root/work/stock-b-consumption-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -d "${scratch_dir:-}" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT
export CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery"
# shellcheck source=../lib/recovery-handoff.sh disable=SC1091
source "$project_root/scripts/lib/recovery-handoff.sh"
cubs_prepare_recovery_state_dir

active_paths=(
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

seed_active_evidence() {
  local preparation_id=$1 index
  local source_policy=${2:-$CUBS_STOCK_B_PREPARATION_POLICY_SHA256}
  for ((index = 0; index < ${#active_paths[@]}; index += 1)); do
    printf '%s-%s\n' "$preparation_id" "${archive_names[$index]}" \
      >"${active_paths[$index]}"
    chmod 0600 "${active_paths[$index]}"
  done
  cubs_verified_stock_b_preparation_id=$preparation_id
  cubs_verified_stock_a_baseline_sha256=$(sha256sum \
    "$cubs_stock_a_baseline_evidence" | awk '{print $1}')
  CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256=$cubs_verified_stock_a_baseline_sha256
  cubs_verified_stock_a_preflight_sha256=$(sha256sum \
    "$cubs_stock_a_physical_b_preflight" | awk '{print $1}')
  cubs_verified_stock_a_logical_sizes_sha256=$(printf '%s' \
    "$preparation_id-logical-a-sizes" | sha256sum | awk '{print $1}')
  cubs_verified_stock_b_source_payload_manifest_sha256=$(sha256sum \
    "$cubs_stock_b_source_payload_manifest" | awk '{print $1}')
  CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256=$cubs_verified_stock_b_source_payload_manifest_sha256
  cubs_verified_stock_b_receipt_sha256=$(sha256sum \
    "$cubs_stock_b_preparation_receipt" | awk '{print $1}')
  cubs_verified_stock_b_trial_sha256=$(sha256sum \
    "$cubs_stock_b_fastbootd_trial_receipt" | awk '{print $1}')
  cubs_verified_stock_b_preparation_policy_sha256=$source_policy
  cubs_verified_stock_b_trial_policy_sha256=$CUBS_STOCK_B_PREPARATION_POLICY_SHA256
}

write_consumption_v3() {
  local destination_basename=$1
  {
    printf 'schema=cubs-stock-b-consumption-v3\n'
    printf 'preparation_id=%s\n' "$cubs_verified_stock_b_preparation_id"
    printf 'receipt_sha256=%s\n' "$cubs_verified_stock_b_receipt_sha256"
    printf 'source_payload_manifest_sha256=%s\n' \
      "$cubs_verified_stock_b_source_payload_manifest_sha256"
    printf 'stock_a_preflight_sha256=%s\n' \
      "$cubs_verified_stock_a_preflight_sha256"
    printf 'stock_a_baseline_evidence_sha256=%s\n' \
      "$cubs_verified_stock_a_baseline_sha256"
    printf 'stock_a_logical_sizes_sha256=%s\n' \
      "$cubs_verified_stock_a_logical_sizes_sha256"
    printf 'fastbootd_trial_receipt_sha256=%s\n' \
      "$cubs_verified_stock_b_trial_sha256"
    printf 'destination_basename=%s\n' "$destination_basename"
    printf 'source_preparation_policy_sha256=%s\n' \
      "$cubs_verified_stock_b_preparation_policy_sha256"
    printf 'trial_policy_sha256=%s\n' \
      "$cubs_verified_stock_b_trial_policy_sha256"
  } >"$cubs_stock_b_consumption_transaction"
  chmod 0600 "$cubs_stock_b_consumption_transaction"
}

assert_active_consumed() {
  local path
  for path in "${active_paths[@]}" "$cubs_stock_b_consumption_transaction"; do
    [[ ! -e "$path" && ! -L "$path" ]] || {
      printf 'error: active evidence remains after journal completion: %s\n' \
        "$path" >&2
      exit 1
    }
  done
}

assert_complete_archive() {
  local destination=$1 index
  cubs_private_dir "$destination"
  for ((index = 0; index < ${#archive_names[@]}; index += 1)); do
    cubs_private_file "$destination/${archive_names[$index]}"
  done
}

assert_active_retained() {
  local path
  for path in "${active_paths[@]}" "$cubs_stock_b_consumption_transaction"; do
    [[ -f "$path" && ! -L "$path" ]] || {
      printf 'error: rejected archive collision removed active evidence: %s\n' \
        "$path" >&2
      exit 1
    }
  done
}

copy_active_archive() {
  local destination=$1 index
  mkdir -m 0700 "$destination"
  for ((index = 0; index < ${#active_paths[@]}; index += 1)); do
    cp -- "${active_paths[$index]}" \
      "$destination/${archive_names[$index]}"
    chmod 0600 "$destination/${archive_names[$index]}"
  done
}

# Normal publication is one directory rename followed by journaled cleanup.
seed_active_evidence 11111111111111111111111111111111
cubs_consume_verified_stock_b_preparation
assert_active_consumed
first_destination=$cubs_completed_stock_b_consumption_destination
assert_complete_archive "$first_destination"

# No legacy preparation policy or migration path has current authority.
seed_active_evidence 12121212121212121212121212121212 \
  1111111111111111111111111111111111111111111111111111111111111111
if (cubs_consume_verified_stock_b_preparation >/dev/null 2>&1); then
  printf 'error: consumption-v3 accepted a non-current preparation policy\n' >&2
  exit 1
fi
rm -f -- "${active_paths[@]}"

# Simulate a kill after atomic archive publication and after three of five
# active files were removed. The exact durable transaction must finish cleanup.
seed_active_evidence 22222222222222222222222222222222
second_destination_basename="stock-b-${cubs_verified_stock_b_preparation_id}-${cubs_verified_stock_b_receipt_sha256}"
second_destination="$cubs_recovery_state_dir/consumed/$second_destination_basename"
mkdir -m 0700 "$second_destination"
for ((index = 0; index < ${#active_paths[@]}; index += 1)); do
  cp -- "${active_paths[$index]}" \
    "$second_destination/${archive_names[$index]}"
  chmod 0600 "$second_destination/${archive_names[$index]}"
done
write_consumption_v3 "$second_destination_basename"
rm -f -- "${active_paths[0]}" "${active_paths[1]}" "${active_paths[2]}"
cubs_finish_pending_stock_b_consumption
assert_active_consumed
[[ "$cubs_completed_stock_b_consumption_destination" == \
   "$second_destination" ]] || {
  printf 'error: cleanup continuation selected the wrong archive\n' >&2
  exit 1
}
assert_complete_archive "$second_destination"

# Simulate a kill after journal publication but before archive publication.
# All five sources remain, so continuation must publish the archive first.
seed_active_evidence 33333333333333333333333333333333
third_destination_basename="stock-b-${cubs_verified_stock_b_preparation_id}-${cubs_verified_stock_b_receipt_sha256}"
write_consumption_v3 "$third_destination_basename"
cubs_finish_pending_stock_b_consumption
assert_active_consumed
assert_complete_archive \
  "$cubs_recovery_state_dir/consumed/$third_destination_basename"

# A colliding archive with the five expected bytes plus any sixth entry is not
# a crash-recovery candidate. Hidden files and symbolic links are both counted
# before any active evidence is deleted.
seed_active_evidence 34343434343434343434343434343434
extra_destination_basename="stock-b-${cubs_verified_stock_b_preparation_id}-${cubs_verified_stock_b_receipt_sha256}"
extra_destination="$cubs_recovery_state_dir/consumed/$extra_destination_basename"
copy_active_archive "$extra_destination"
printf 'unexpected\n' >"$extra_destination/.unexpected-entry"
chmod 0600 "$extra_destination/.unexpected-entry"
write_consumption_v3 "$extra_destination_basename"
if (cubs_finish_pending_stock_b_consumption >/dev/null 2>&1); then
  printf 'error: consumption-v3 accepted a colliding archive with an extra file\n' >&2
  exit 1
fi
assert_active_retained
rm -f -- "$cubs_stock_b_consumption_transaction" "${active_paths[@]}" \
  "$extra_destination/.unexpected-entry" \
  "$extra_destination"/stock-a-baseline-evidence \
  "$extra_destination"/stock-a-preflight \
  "$extra_destination"/source-payload-manifest \
  "$extra_destination"/receipt \
  "$extra_destination"/fastbootd-trial-receipt
rmdir -- "$extra_destination"

seed_active_evidence 35353535353535353535353535353535
symlink_destination_basename="stock-b-${cubs_verified_stock_b_preparation_id}-${cubs_verified_stock_b_receipt_sha256}"
symlink_destination="$cubs_recovery_state_dir/consumed/$symlink_destination_basename"
copy_active_archive "$symlink_destination"
ln -s -- "$symlink_destination/receipt" \
  "$symlink_destination/unexpected-link"
write_consumption_v3 "$symlink_destination_basename"
if (cubs_finish_pending_stock_b_consumption >/dev/null 2>&1); then
  printf 'error: consumption-v3 accepted a colliding archive with a symlink\n' >&2
  exit 1
fi
assert_active_retained
rm -f -- "$cubs_stock_b_consumption_transaction" "${active_paths[@]}" \
  "$symlink_destination/unexpected-link" \
  "$symlink_destination"/stock-a-baseline-evidence \
  "$symlink_destination"/stock-a-preflight \
  "$symlink_destination"/source-payload-manifest \
  "$symlink_destination"/receipt \
  "$symlink_destination"/fastbootd-trial-receipt
rmdir -- "$symlink_destination"

seed_active_evidence 36363636363636363636363636363636
directory_destination_basename="stock-b-${cubs_verified_stock_b_preparation_id}-${cubs_verified_stock_b_receipt_sha256}"
directory_destination="$cubs_recovery_state_dir/consumed/$directory_destination_basename"
copy_active_archive "$directory_destination"
mkdir -m 0700 "$directory_destination/unexpected-directory"
write_consumption_v3 "$directory_destination_basename"
if (cubs_finish_pending_stock_b_consumption >/dev/null 2>&1); then
  printf 'error: consumption-v3 accepted a colliding archive with a directory\n' >&2
  exit 1
fi
assert_active_retained
rm -f -- "$cubs_stock_b_consumption_transaction" "${active_paths[@]}" \
  "$directory_destination"/stock-a-baseline-evidence \
  "$directory_destination"/stock-a-preflight \
  "$directory_destination"/source-payload-manifest \
  "$directory_destination"/receipt \
  "$directory_destination"/fastbootd-trial-receipt
rmdir -- "$directory_destination/unexpected-directory" "$directory_destination"

# A legacy v2 journal and a v3 journal with any extra field fail closed before
# source cleanup or archive publication.
seed_active_evidence 44444444444444444444444444444444
fourth_destination_basename="stock-b-${cubs_verified_stock_b_preparation_id}-${cubs_verified_stock_b_receipt_sha256}"
write_consumption_v3 "$fourth_destination_basename"
sed -i 's/cubs-stock-b-consumption-v3/cubs-stock-b-consumption-v2/' \
  "$cubs_stock_b_consumption_transaction"
if (cubs_finish_pending_stock_b_consumption >/dev/null 2>&1); then
  printf 'error: consumption-v3 accepted a legacy journal\n' >&2
  exit 1
fi
[[ -f "${active_paths[0]}" ]] || {
  printf 'error: malformed legacy journal consumed active evidence\n' >&2
  exit 1
}
rm -f -- "$cubs_stock_b_consumption_transaction"
write_consumption_v3 "$fourth_destination_basename"
printf 'migration_kind=legacy_v2_started\n' \
  >>"$cubs_stock_b_consumption_transaction"
if (cubs_finish_pending_stock_b_consumption >/dev/null 2>&1); then
  printf 'error: consumption-v3 accepted an extra migration field\n' >&2
  exit 1
fi
rm -f -- "$cubs_stock_b_consumption_transaction" "${active_paths[@]}"

# A partially journaled restore belongs exclusively to restore-stock; no new
# direct preparation may enter through the shared absence gate.
printf 'schema=test-only-stock-restore-transaction\n' \
  >"$cubs_stock_restore_transaction"
chmod 0600 "$cubs_stock_restore_transaction"
if (cubs_require_no_stock_b_preparation >/dev/null 2>&1); then
  printf 'error: shared entry gate ignored an active stock-restore transaction\n' >&2
  exit 1
fi
rm -f -- "$cubs_stock_restore_transaction"

printf 'schema=test-only-slot-a-flash-transaction\n' \
  >"$cubs_slot_a_flash_transaction"
chmod 0600 "$cubs_slot_a_flash_transaction"
if (cubs_require_no_stock_b_preparation >/dev/null 2>&1); then
  printf 'error: shared entry gate ignored an active slot-A flash transaction\n' >&2
  exit 1
fi
rm -f -- "$cubs_slot_a_flash_transaction"

printf 'schema=test-only-retired-lpdump\n' >"$cubs_stock_a_lpdump_evidence"
chmod 0600 "$cubs_stock_a_lpdump_evidence"
if (cubs_require_no_stock_b_preparation >/dev/null 2>&1); then
  printf 'error: shared entry gate ignored conflicting legacy lpdump evidence\n' >&2
  exit 1
fi
rm -f -- "$cubs_stock_a_lpdump_evidence"

printf 'stock-B evidence-consumption v3 crash journal simulation passed\n'
