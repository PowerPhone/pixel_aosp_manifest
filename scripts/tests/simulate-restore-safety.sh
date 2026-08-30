#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
mock_fastboot="$test_dir/mock-fastboot.sh"
mock_adb="$test_dir/mock-adb.sh"
# shellcheck source=../../config/release.env
source "$project_root/config/release.env"
# shellcheck source=../../config/targets/cubs/release.env
source "$project_root/config/targets/cubs/release.env"
# shellcheck source=../../config/recovery.env
source "$project_root/config/recovery.env"
production_fastboot_sha256=$PLATFORM_TOOLS_FASTBOOT_SHA256
mock_fastboot_sha256=$(sha256sum "$mock_fastboot" | awk '{print $1}')
mock_adb_sha256=$(sha256sum "$mock_adb" | awk '{print $1}')
mock_stock_fingerprint='mock/stock/cubs:17/MOCK/user/release-keys'
mock_stock_fingerprint_sha256=$(printf '%s' "$mock_stock_fingerprint" | \
  sha256sum | awk '{print $1}')
# Pinned Platform-Tools 37.0.1 reports an absent stock-fastbootd logical as an
# exact FAILED/Partition-not-found line while still exiting zero.
export MOCK_ABSENT_LOGICAL_STATUS_ZERO=1

[[ -x "$mock_fastboot" && -x "$mock_adb" ]] || {
  printf 'error: mock platform tools are not executable\n' >&2
  exit 1
}
[[ -f "$project_root/downloads/$FACTORY_IMAGE_FILENAME" ]] || {
  printf '%s\n' \
    'error: the pinned factory archive is required for the restore simulation' >&2
  exit 1
}
stock_inner="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
[[ -f "$stock_inner" && ! -L "$stock_inner" ]] || {
  printf 'error: extract the pinned nested stock image ZIP before simulation\n' >&2
  exit 1
}

firmware_partitions=(
  abl bl31 cap cpm dbc dbl
  dram_init_0 dram_init_1 dram_init_2 dram_init_3
  dram_init_4 dram_init_5 dram_init_6 dram_init_7
  dram_init_8 dram_init_9 dram_init_10 dram_init_11
  dram_phy gc gdmc gsa_bl1 gsa_fw tzsw modem
)

scratch_parent="$project_root/work/restore-safety-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
test_restore_runner=
cleanup() {
  if [[ -n "${test_restore_runner:-}" && \
        "$test_restore_runner" == "$project_root/scripts/".restore-stock-test.* ]]; then
    rm -f -- "$test_restore_runner"
  fi
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT
test_restore_runner=$(mktemp "$project_root/scripts/.restore-stock-test.XXXXXX")
# The single-quoted sed patterns intentionally match literal shell variables
# in the generated runner; they are not meant to expand in this test process.
# shellcheck disable=SC2016
sed \
  -e "s/^expected_fastboot_sha256=$production_fastboot_sha256$/expected_fastboot_sha256=$mock_fastboot_sha256/" \
  -e "s/^expected_adb_sha256=\$PLATFORM_TOOLS_ADB_SHA256$/expected_adb_sha256=$mock_adb_sha256/" \
  -e "s/^expected_stock_fingerprint_sha256=\$CUBS_STOCK_FINGERPRINT_SHA256$/expected_stock_fingerprint_sha256=$mock_stock_fingerprint_sha256/" \
  -e 's|^  verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"$|  : # nested stock fixture was verified before the simulation|' \
  -e 's|^verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"$|: # nested stock fixture was verified before the simulation|' \
  -e 's|^  "$script_dir/extract-stock.sh"$|  : # reuse pre-extracted simulation fixture|' \
  -e 's|^"$script_dir/extract-stock.sh"$|: # reuse pre-extracted simulation fixture|' \
  -e 's|^unzip -q "$stock_images" "${stock_image_files\[@\]}" -d "$restore_dir"$|for image_name in "${stock_image_files[@]}"; do truncate -s 2097152 "$restore_dir/$image_name"; done|' \
  "$project_root/scripts/restore-stock.sh" >"$test_restore_runner"
chmod 0755 "$test_restore_runner"
grep -Fxq "expected_fastboot_sha256=$mock_fastboot_sha256" \
  "$test_restore_runner" || {
    printf 'error: failed to create digest-pinned restore test runner\n' >&2
    exit 1
  }
grep -Fxq "expected_adb_sha256=$mock_adb_sha256" \
  "$test_restore_runner" || {
    printf 'error: failed to create digest-pinned ADB restore test runner\n' >&2
    exit 1
  }

mkdir -p "$scratch_dir/state"
: >"$scratch_dir/mutations.log"
mock_vendor_boot="$scratch_dir/vendor_boot_b.img"
unzip -p "$stock_inner" vendor_boot.img >"$mock_vendor_boot"
[[ $(sha256sum "$mock_vendor_boot" | awk '{print $1}') == \
   "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || {
  printf 'error: simulated vendor_boot fixture differs from the exact pin\n' >&2
  exit 1
}
vendor_boot_size=$(stat -c '%s' "$mock_vendor_boot")
vendor_boot_size_hex=$(printf '%x' "$vendor_boot_size")
printf '0x%s\n' "$vendor_boot_size_hex" >"$scratch_dir/state/size_vendor_boot_a"
printf '0x%s\n' "$vendor_boot_size_hex" >"$scratch_dir/state/size_vendor_boot_b"
mkdir -m 0700 "$scratch_dir/recovery"
anchor_id=0123456789abcdef0123456789abcdef
created=$(date +%s)
expires=$((created + CUBS_RECOVERY_HANDOFF_READY_SECONDS))
serial_binding=$(printf '%s\0%s' "$anchor_id" MOCK_CUBS_SERIAL | \
  sha256sum | awk '{print $1}')
physical_size_lines=
for partition in "${firmware_partitions[@]}" \
    boot init_boot dtbo vendor_boot vendor_kernel_boot pvmfw \
    vbmeta_system vbmeta_vendor vbmeta; do
  if [[ "$partition" == vendor_boot ]]; then
    physical_size_lines+="${partition}_b=${vendor_boot_size_hex}"$'\n'
  else
    physical_size_lines+="${partition}_b=4000000"$'\n'
  fi
done
physical_sizes_sha=$(printf '%s' "$physical_size_lines" | \
  sha256sum | awk '{print $1}')
{
  printf 'schema=cubs-recovery-lineage-v2\n'
  printf 'anchor_id=%s\n' "$anchor_id"
  printf 'created_epoch=%s\n' "$created"
  printf 'serial_binding_sha256=%s\n' "$serial_binding"
  printf 'device=cubs\n'
  printf 'stock_build_id=%s\n' "$STOCK_BUILD_ID"
  printf 'stock_fingerprint_sha256=%s\n' "$CUBS_STOCK_FINGERPRINT_SHA256"
  printf 'factory_sha256=%s\n' "$FACTORY_IMAGE_SHA256"
  printf 'full_ota_sha256=%s\n' "$FULL_OTA_SHA256"
  printf 'bootloader=spacecraft-17.4-15938155\n'
  printf 'baseband=a900a-MP_260716-260716-M-15880348\n'
  printf 'ab_ota_partitions_sha256=%s\n' "$CUBS_AB_OTA_PARTITIONS_SHA256"
  printf 'shared_super_layout_sha256=%s\n' "$CUBS_SHARED_SUPER_LAYOUT_SHA256"
  printf 'physical_b_sizes_sha256=%s\n' "$physical_sizes_sha"
  printf 'stock_b_source=full_ota\n'
  printf 'stock_b_provenance_sha256=%s\n' "$FULL_OTA_SHA256"
  printf 'physical_b_source_manifest_sha256=none\n'
  printf 'physical_b_vendor_boot_fetch_sha256=none\n'
  printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
} >"$scratch_dir/recovery/lifeboat-lineage"
lineage_sha=$(sha256sum "$scratch_dir/recovery/lifeboat-lineage" | awk '{print $1}')
{
  printf 'schema=cubs-recovery-handoff-v2\n'
  printf 'state=ready\n'
  printf 'handoff_kind=stock_b_anchor\n'
  printf 'created_epoch=%s\n' "$created"
  printf 'expires_epoch=%s\n' "$expires"
  printf 'claimed_epoch=0\n'
  printf 'anchor_id=%s\n' "$anchor_id"
  printf 'serial_binding_sha256=%s\n' "$serial_binding"
  printf 'lineage_sha256=%s\n' "$lineage_sha"
  printf 'physical_b_sizes_sha256=%s\n' "$physical_sizes_sha"
  printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
  printf 'bundle_kind=none\n'
  printf 'bundle_manifest_sha256=none\n'
} >"$scratch_dir/recovery/flash-handoff"
chmod 0600 \
  "$scratch_dir/recovery/lifeboat-lineage" \
  "$scratch_dir/recovery/flash-handoff"

if MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
    MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
    MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    MOCK_VENDOR_BOOT_IMAGE="$mock_vendor_boot" \
    FASTBOOT="$mock_fastboot" \
    CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    CUBS_ALLOW_DATA_WIPE=1 \
    CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID \
      "$project_root/scripts/restore-stock.sh" \
      >"$scratch_dir/digest-rejection.log" 2>&1; then
  printf 'error: production restore accepted an unpinned fastboot digest\n' >&2
  exit 1
fi
grep -Fq 'fastboot does not match the pinned Platform-Tools binary digest' \
  "$scratch_dir/digest-rejection.log" || {
    printf 'error: production restore did not report its digest rejection\n' >&2
    exit 1
  }
[[ ! -s "$scratch_dir/mutations.log" ]] || {
  printf 'error: fastboot digest rejection occurred after a mutation\n' >&2
  exit 1
}

ln -s "$mock_fastboot" "$scratch_dir/fastboot-symlink"
if MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
    MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
    MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    MOCK_VENDOR_BOOT_IMAGE="$mock_vendor_boot" \
    FASTBOOT="$scratch_dir/fastboot-symlink" \
    CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    CUBS_ALLOW_DATA_WIPE=1 \
    CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID \
      "$test_restore_runner" >"$scratch_dir/symlink-rejection.log" 2>&1; then
  printf 'error: restore accepted a symlinked fastboot executable\n' >&2
  exit 1
fi
grep -Fq 'fastboot is not a safe executable' \
  "$scratch_dir/symlink-rejection.log" || {
    printf 'error: restore did not report its fastboot symlink rejection\n' >&2
    exit 1
  }

if (
  cd "$project_root"
  MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
  MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
  MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
  MOCK_VENDOR_BOOT_IMAGE="$mock_vendor_boot" \
  FASTBOOT=scripts/tests/mock-fastboot.sh \
  CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
  CUBS_ALLOW_DATA_WIPE=1 \
  CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID \
    "$test_restore_runner"
) >"$scratch_dir/relative-path-rejection.log" 2>&1; then
  printf 'error: restore accepted a relative FASTBOOT path\n' >&2
  exit 1
fi
grep -Fq 'FASTBOOT must be an absolute path' \
  "$scratch_dir/relative-path-rejection.log" || {
    printf 'error: restore did not report its relative FASTBOOT rejection\n' >&2
    exit 1
  }

# A full-OTA lineage with the original stock_b_anchor receipt remains
# successful=yes only. The no value becomes acceptable solely after the
# selector has published an exact physical_b_lifeboat handoff.
printf 'no\n' >"$scratch_dir/state/slot_b_successful"
if MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
    MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
    MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    MOCK_VENDOR_BOOT_IMAGE="$mock_vendor_boot" \
    FASTBOOT="$mock_fastboot" \
    CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery" \
    CUBS_ALLOW_DATA_WIPE=1 \
    CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID \
      "$test_restore_runner" >"$scratch_dir/stock-anchor-b-no.log" 2>&1; then
  printf 'error: restore accepted full-OTA stock_b_anchor with B successful=no\n' >&2
  exit 1
fi
grep -Fq 'stock_b_anchor requires B successful=yes' \
  "$scratch_dir/stock-anchor-b-no.log" || {
    printf 'error: restore did not report the stock-anchor B-success rejection\n' >&2
    exit 1
  }
sed -i 's/^handoff_kind=stock_b_anchor$/handoff_kind=physical_b_lifeboat/' \
  "$scratch_dir/recovery/flash-handoff"
if MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
    MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
    MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    FASTBOOT="$mock_fastboot" \
    CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery" \
    CUBS_ALLOW_DATA_WIPE=1 \
    CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID \
      "$test_restore_runner" >"$scratch_dir/selector-b-no.log" 2>&1; then
  printf 'error: selector acceptance probe unexpectedly completed restore\n' >&2
  exit 1
fi
grep -Fq 'MOCK_VENDOR_BOOT_IMAGE' "$scratch_dir/selector-b-no.log" || {
  printf 'error: physical-lifeboat B=no did not reach the live-byte gate\n' >&2
  exit 1
}
[[ ! -s "$scratch_dir/mutations.log" ]] || {
  printf 'error: B-success source-gate probes performed a mutation\n' >&2
  exit 1
}
sed -i 's/^handoff_kind=physical_b_lifeboat$/handoff_kind=stock_b_anchor/' \
  "$scratch_dir/recovery/flash-handoff"
printf 'yes\n' >"$scratch_dir/state/slot_b_successful"

# Preserve the pristine B-bootloader/B-only metadata fixture for the
# journal/crash reconciliation branches below.
cp -a -- "$scratch_dir/state" "$scratch_dir/state-pristine-template"
cp -a -- "$scratch_dir/recovery" "$scratch_dir/recovery-pristine-template"

MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
MOCK_VENDOR_BOOT_IMAGE="$mock_vendor_boot" \
MOCK_EXPECT_RECOVERY_HANDOFF="$scratch_dir/recovery" \
MOCK_UNSUFFIXED_LOGICAL_RESPONSE=present_in_b \
FASTBOOT="$mock_fastboot" \
CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery" \
CUBS_ALLOW_DATA_WIPE=1 \
CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID \
  "$test_restore_runner"

expected=()
expected+=(
  'reboot fastboot'
  'set_active a'
  'resize system_a 0'
)
for partition in system system_dlkm system_ext product vendor vendor_dlkm; do
  expected+=("set_active a" "resize ${partition}_a 0")
done
for partition in system system_dlkm system_ext product vendor vendor_dlkm; do
  expected+=("set_active a" "flash ${partition}_a")
done
expected+=('reboot bootloader')
for partition in "${firmware_partitions[@]}" \
    boot init_boot dtbo vendor_boot vendor_kernel_boot pvmfw; do
  expected+=("flash ${partition}_a")
done
expected+=(
  'flash vbmeta_system_a'
  'flash vbmeta_vendor_a'
  'flash vbmeta_a'
  'erase userdata'
  'erase metadata'
  'set_active a'
)
(( ${#expected[@]} == 65 )) || {
  printf 'error: internal restore mutation allowlist count is not 65\n' >&2
  exit 1
}
mapfile -t actual <"$scratch_dir/mutations.log"
if (( ${#actual[@]} != ${#expected[@]} )); then
  printf 'error: restore mutation count mismatch\n' >&2
  printf 'expected: %s\n' "${expected[*]}" >&2
  printf 'actual:   %s\n' "${actual[*]}" >&2
  exit 1
fi
for ((index = 0; index < ${#expected[@]}; index += 1)); do
  [[ "${actual[$index]}" == "${expected[$index]}" ]] || {
    printf 'error: restore mutation %d mismatch: expected %s, found %s\n' \
      "$index" "${expected[$index]}" "${actual[$index]}" >&2
    exit 1
  }
done
[[ ! -e "$scratch_dir/state/fastbootd_physical_size_probe_count" || \
   $(sed -n '1p' \
     "$scratch_dir/state/fastbootd_physical_size_probe_count") == 0 ]] || {
  printf 'error: restore queried physical partition sizes in fastbootd\n' >&2
  exit 1
}
[[ $(sed -n '1p' "$scratch_dir/state/current_slot") == a ]] || {
  printf 'error: restore did not activate A last\n' >&2
  exit 1
}
[[ $(sed -n '1p' "$scratch_dir/state/mode") == bootloader ]] || {
  printf 'error: restore did not leave the phone in bootloader mode\n' >&2
  exit 1
}
for partition in "${firmware_partitions[@]}"; do
  for proof in \
      "proved_has_slot_$partition" \
      "proved_size_${partition}_a" \
      "proved_size_${partition}_b" \
      "flashed_${partition}_a"; do
    [[ -f "$scratch_dir/state/$proof" && \
       $(sed -n '1p' "$scratch_dir/state/$proof") == yes ]] || {
      printf 'error: missing restore firmware proof: %s\n' "$proof" >&2
      exit 1
    }
  done
done
[[ -f "$scratch_dir/recovery/lifeboat-lineage" && \
   -f "$scratch_dir/recovery/flash-handoff" ]] || {
  printf 'error: stock restore retired recovery evidence before stock A booted\n' >&2
  exit 1
}
grep -Fxq 'state=awaiting_stock_android' \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: stock restore did not publish awaiting_stock_android\n' >&2
  exit 1
}
[[ $(sed -n '1p' "$scratch_dir/state/slot_a_successful") == no ]] || {
  printf 'error: mock set_active A did not clear the target success flag\n' >&2
  exit 1
}
[[ $(sed -n '1p' "$scratch_dir/state/vendor_boot_fetch_count") == 3 ]] || {
  printf 'error: restore did not perform three full live vendor_boot checks\n' >&2
  exit 1
}

cp -a -- "$scratch_dir/state" "$scratch_dir/state-completed-template"
cp -a -- "$scratch_dir/recovery" "$scratch_dir/recovery-completed-template"

reset_pristine_restore_fixture() {
  rm -rf -- "$scratch_dir/state" "$scratch_dir/recovery"
  cp -a -- "$scratch_dir/state-pristine-template" "$scratch_dir/state"
  cp -a -- "$scratch_dir/recovery-pristine-template" "$scratch_dir/recovery"
  : >"$scratch_dir/mutations.log"
  printf '0\n' >"$scratch_dir/state/mutation_count"
  printf '0\n' >"$scratch_dir/state/vendor_boot_fetch_count"
}

run_mocked_restore() {
  env \
    MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
    MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
    MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    MOCK_VENDOR_BOOT_IMAGE="$mock_vendor_boot" \
    MOCK_EXPECT_RECOVERY_HANDOFF="$scratch_dir/recovery" \
    FASTBOOT="$mock_fastboot" \
    CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery" \
    CUBS_ALLOW_DATA_WIPE=1 \
    CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID \
    "$@" "$test_restore_runner"
}

assert_mutations_equal() {
  local expected_name=$1 index
  local -n expected_ref=$expected_name
  local -a observed=()
  mapfile -t observed <"$scratch_dir/mutations.log"
  (( ${#observed[@]} == ${#expected_ref[@]} )) || {
    printf 'error: %s mutation count mismatch\n' "$expected_name" >&2
    return 1
  }
  for ((index = 0; index < ${#expected_ref[@]}; index += 1)); do
    [[ "${observed[$index]}" == "${expected_ref[$index]}" ]] || {
      printf 'error: %s mutation %d mismatch\n' "$expected_name" "$index" >&2
      return 1
    }
  done
}

# The production cubs path consumes preparation-v2/trial-v4 evidence into a
# direct_factory_physical_b lineage and leaves B successful=no. Exercise that
# exact source-aware restore path end to end, including the physical-lifeboat
# handoff, rather than relying only on the older full-OTA stock-B fixture.
reset_pristine_restore_fixture
direct_provenance_sha=$(printf 'mock-direct-v7-fastbootd-trial\n' | \
  sha256sum | awk '{print $1}')
sed -i \
  -e 's/^stock_b_source=full_ota$/stock_b_source=direct_factory_physical_b/' \
  -e "s/^stock_b_provenance_sha256=.*/stock_b_provenance_sha256=$direct_provenance_sha/" \
  -e "s/^physical_b_source_manifest_sha256=.*/physical_b_source_manifest_sha256=$CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256/" \
  -e "s/^physical_b_vendor_boot_fetch_sha256=.*/physical_b_vendor_boot_fetch_sha256=$CUBS_STOCK_VENDOR_BOOT_SHA256/" \
  "$scratch_dir/recovery/lifeboat-lineage"
direct_lineage_sha=$(sha256sum "$scratch_dir/recovery/lifeboat-lineage" | \
  awk '{print $1}')
sed -i \
  -e 's/^handoff_kind=stock_b_anchor$/handoff_kind=physical_b_lifeboat/' \
  -e "s/^lineage_sha256=.*/lineage_sha256=$direct_lineage_sha/" \
  "$scratch_dir/recovery/flash-handoff"
printf 'no\n' >"$scratch_dir/state/slot_b_successful"
run_mocked_restore >"$scratch_dir/direct-v7-restore.log" 2>&1
assert_mutations_equal expected
grep -Fxq 'stock_b_source=direct_factory_physical_b' \
  "$scratch_dir/recovery/lifeboat-lineage"
grep -Fxq "stock_b_provenance_sha256=$direct_provenance_sha" \
  "$scratch_dir/recovery/lifeboat-lineage"
grep -Fxq 'handoff_kind=physical_b_lifeboat' \
  "$scratch_dir/recovery/flash-handoff"
grep -Fxq 'stock_b_source=direct_factory_physical_b' \
  "$scratch_dir/recovery/stock-restore-transaction"
grep -Fxq "stock_b_provenance_sha256=$direct_provenance_sha" \
  "$scratch_dir/recovery/stock-restore-transaction"
grep -Fxq 'state=awaiting_stock_android' \
  "$scratch_dir/recovery/stock-restore-transaction"
[[ $(sed -n '1p' "$scratch_dir/state/current_slot") == a && \
   $(sed -n '1p' "$scratch_dir/state/mode") == bootloader && \
   $(sed -n '1p' "$scratch_dir/state/vendor_boot_fetch_count") == 3 ]] || {
  printf 'error: direct-v7 restore did not finish safely on A bootloader\n' >&2
  exit 1
}
if grep -Eq '(^|[[:space:]])[^[:space:]]+_b($|[[:space:]])' \
    "$scratch_dir/mutations.log"; then
  printf 'error: direct-v7 restore mutated a B partition\n' >&2
  exit 1
fi

# A host-visible failure after set_active A but before the compound pivot
# resize must not be treated as success.  Namespace/size reconciliation repeats
# the still-journaled pivot and then completes normally.
reset_pristine_restore_fixture
# shellcheck disable=SC2034
pivot_retry_expected=(
  "${expected[0]}" "${expected[1]}" "${expected[@]:1}"
)
run_mocked_restore MOCK_FAIL_AFTER_MUTATION=2 \
  >"$scratch_dir/pivot-set-active-ack-failure.log" 2>&1
assert_mutations_equal pivot_retry_expected
grep -Fxq 'state=awaiting_stock_android' \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: journaled pivot retry did not complete stock restore\n' >&2
  exit 1
}

# A nonzero flash status is ambiguous even when the target reached its exact
# size.  The same logical payload must be replayed once with a clean status.
reset_pristine_restore_fixture
# shellcheck disable=SC2034
flash_retry_expected=(
  "${expected[@]:0:17}"
  'set_active a'
  'flash system_a'
  "${expected[@]:17}"
)
run_mocked_restore MOCK_FAIL_AFTER_MUTATION=17 \
  >"$scratch_dir/logical-flash-ack-failure.log" 2>&1
assert_mutations_equal flash_retry_expected

# A failed ACK after fastbootd already returned to bootloader is reconciled by
# mode and receipt, without issuing a bare reboot or replaying logical writes.
reset_pristine_restore_fixture
run_mocked_restore MOCK_FAIL_AFTER_MUTATION=28 \
  >"$scratch_dir/return-bootloader-ack-failure.log" 2>&1
assert_mutations_equal expected

# A physical-B size change injected at the fastbootd-to-bootloader boundary
# must fail the full live digest check before the first physical-A flash.
reset_pristine_restore_fixture
if run_mocked_restore MOCK_DRIFT_PHYSICAL_B_AFTER_BOOTLOADER_RETURN=1 \
    >"$scratch_dir/post-logical-b-drift-rejection.log" 2>&1; then
  printf 'error: restore accepted physical-B drift after bootloader return\n' >&2
  exit 1
fi
grep -Fq 'physical slot-B lifeboat no longer matches its verified lineage' \
  "$scratch_dir/post-logical-b-drift-rejection.log" || {
  printf 'error: post-logical physical-B drift rejection was not explicit\n' >&2
  exit 1
}
# shellcheck disable=SC2034
post_logical_b_drift_expected=("${expected[@]:0:28}")
assert_mutations_equal post_logical_b_drift_expected
[[ $(sed -n '1p' "$scratch_dir/state/mode") == bootloader ]] || {
  printf 'error: physical-B drift was not detected in bootloader mode\n' >&2
  exit 1
}
grep -Fxq 'state=return_bootloader_pending' \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: physical-B drift advanced the restore transaction\n' >&2
  exit 1
}

# The pristine B-only success above exercises uniform has-slot=yes. Its mock
# deliberately exposes an unsuffixed alias, proving that this legacy-reporting
# mode never probes or relies on the alias. Current-only cubs fastbootd instead
# reports uniform has-slot=no and must report every unsuffixed alias as exactly
# absent. An exposed alias or a status-zero "no" is rejected before the pivot.
for unsuffixed_response in present no; do
  reset_pristine_restore_fixture
  if run_mocked_restore \
      MOCK_LOGICAL_HAS_SLOT_RESPONSE=no \
      "MOCK_UNSUFFIXED_LOGICAL_RESPONSE=$unsuffixed_response" \
      >"$scratch_dir/unsuffixed-${unsuffixed_response}-rejection.log" 2>&1; then
    printf 'error: restore accepted unsuffixed logical response %s\n' \
      "$unsuffixed_response" >&2
    exit 1
  fi
  grep -Fq \
    'fastbootd exposes or ambiguously describes unsuffixed logical partition system' \
    "$scratch_dir/unsuffixed-${unsuffixed_response}-rejection.log" || {
    printf 'error: unsuffixed logical response %s was not rejected explicitly\n' \
      "$unsuffixed_response" >&2
    exit 1
  }
  mapfile -t unsuffixed_mutations <"$scratch_dir/mutations.log"
  [[ ${#unsuffixed_mutations[@]} -eq 1 && \
     "${unsuffixed_mutations[0]}" == 'reboot fastboot' ]] || {
    printf 'error: unsuffixed logical rejection reached metadata mutation\n' >&2
    exit 1
  }
done

# Slotting reports must be strict and uniform across all six logical bases.
reset_pristine_restore_fixture
if run_mocked_restore MOCK_LOGICAL_HAS_SLOT_RESPONSE=mixed \
    >"$scratch_dir/mixed-has-slot-rejection.log" 2>&1; then
  printf 'error: restore accepted mixed fastbootd logical slotting\n' >&2
  exit 1
fi
grep -Fq 'fastbootd logical bases report mixed has-slot values' \
  "$scratch_dir/mixed-has-slot-rejection.log" || {
  printf 'error: mixed logical has-slot rejection was not explicit\n' >&2
  exit 1
}
mapfile -t mixed_has_slot_mutations <"$scratch_dir/mutations.log"
[[ ${#mixed_has_slot_mutations[@]} -eq 1 && \
   "${mixed_has_slot_mutations[0]}" == 'reboot fastboot' ]] || {
  printf 'error: mixed logical has-slot rejection reached metadata mutation\n' >&2
  exit 1
}

for malformed_has_slot in malformed duplicate yes_with_failed; do
  reset_pristine_restore_fixture
  if run_mocked_restore \
      "MOCK_LOGICAL_HAS_SLOT_RESPONSE=$malformed_has_slot" \
      >"$scratch_dir/${malformed_has_slot}-has-slot-rejection.log" 2>&1; then
    printf 'error: restore accepted %s has-slot output\n' \
      "$malformed_has_slot" >&2
    exit 1
  fi
  grep -Fq 'ambiguous yes/no fastboot probe for has-slot:system' \
    "$scratch_dir/${malformed_has_slot}-has-slot-rejection.log" || {
    printf 'error: %s has-slot output was not rejected explicitly\n' \
      "$malformed_has_slot" >&2
    exit 1
  }
  mapfile -t malformed_has_slot_mutations <"$scratch_dir/mutations.log"
  [[ ${#malformed_has_slot_mutations[@]} -eq 1 && \
     "${malformed_has_slot_mutations[0]}" == 'reboot fastboot' ]] || {
    printf 'error: %s has-slot rejection reached metadata mutation\n' \
      "$malformed_has_slot" >&2
    exit 1
  }
done

# Paired visibility in the initial B-origin daemon is never interpreted as
# either stock namespace and must be rejected before the metadata pivot.
reset_pristine_restore_fixture
if run_mocked_restore MOCK_NAMESPACE_MODE=both_present \
    >"$scratch_dir/mixed-namespace-rejection.log" 2>&1; then
  printf 'error: restore accepted a mixed fastbootd logical namespace\n' >&2
  exit 1
fi
grep -Fq 'B-origin fastbootd exposes an irreconcilable mixed logical namespace' \
  "$scratch_dir/mixed-namespace-rejection.log" || {
  printf 'error: mixed namespace rejection was not explicit\n' >&2
  sed -n '1,160p' "$scratch_dir/mixed-namespace-rejection.log" >&2 || true
  exit 1
}
mapfile -t mixed_mutations <"$scratch_dir/mutations.log"
[[ ${#mixed_mutations[@]} -eq 1 && \
   "${mixed_mutations[0]}" == 'reboot fastboot' ]] || {
  printf 'error: mixed namespace rejection occurred after metadata mutation\n' >&2
  exit 1
}
grep -Fxq 'state=enter_b_fastbootd_pending' \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: mixed namespace rejection lost its entry journal\n' >&2
  exit 1
}

# Neither two absent explicit suffixes nor status-zero no/malformed present
# responses may be interpreted as a selected logical namespace.
reset_pristine_restore_fixture
if run_mocked_restore MOCK_NAMESPACE_MODE=both_absent \
    >"$scratch_dir/both-absent-namespace-rejection.log" 2>&1; then
  printf 'error: restore accepted an all-absent explicit namespace\n' >&2
  exit 1
fi
grep -Fq 'irreconcilable mixed logical namespace' \
  "$scratch_dir/both-absent-namespace-rejection.log" || {
  printf 'error: all-absent explicit namespace rejection was not explicit\n' >&2
  exit 1
}
mapfile -t both_absent_mutations <"$scratch_dir/mutations.log"
[[ ${#both_absent_mutations[@]} -eq 1 && \
   "${both_absent_mutations[0]}" == 'reboot fastboot' ]] || {
  printf 'error: all-absent explicit namespace reached metadata mutation\n' >&2
  exit 1
}

reset_pristine_restore_fixture
if run_mocked_restore MOCK_LOGICAL_PRESENT_RESPONSE=no \
    >"$scratch_dir/explicit-no-rejection.log" 2>&1; then
  printf 'error: restore accepted status-zero no for an explicit logical\n' >&2
  exit 1
fi
grep -Fq 'irreconcilable mixed logical namespace' \
  "$scratch_dir/explicit-no-rejection.log" || {
  printf 'error: explicit status-zero no rejection was not explicit\n' >&2
  exit 1
}
mapfile -t explicit_no_mutations <"$scratch_dir/mutations.log"
[[ ${#explicit_no_mutations[@]} -eq 1 && \
   "${explicit_no_mutations[0]}" == 'reboot fastboot' ]] || {
  printf 'error: explicit status-zero no reached metadata mutation\n' >&2
  exit 1
}

for malformed_present in malformed duplicate yes_with_failed; do
  reset_pristine_restore_fixture
  if run_mocked_restore \
      "MOCK_LOGICAL_PRESENT_RESPONSE=$malformed_present" \
      >"$scratch_dir/${malformed_present}-present-rejection.log" 2>&1; then
    printf 'error: restore accepted %s explicit-present output\n' \
      "$malformed_present" >&2
    exit 1
  fi
  grep -Fq 'ambiguous logical-partition probe for system_b' \
    "$scratch_dir/${malformed_present}-present-rejection.log" || {
    printf 'error: %s explicit-present output was not rejected explicitly\n' \
      "$malformed_present" >&2
    exit 1
  }
  mapfile -t malformed_present_mutations <"$scratch_dir/mutations.log"
  [[ ${#malformed_present_mutations[@]} -eq 1 && \
     "${malformed_present_mutations[0]}" == 'reboot fastboot' ]] || {
    printf 'error: %s explicit-present rejection reached metadata mutation\n' \
      "$malformed_present" >&2
    exit 1
  }
done

for malformed_absence in generic duplicate; do
  reset_pristine_restore_fixture
  if run_mocked_restore \
      "MOCK_ABSENT_LOGICAL_RESPONSE=$malformed_absence" \
      >"$scratch_dir/${malformed_absence}-absence-rejection.log" 2>&1; then
    printf 'error: restore accepted %s absent-logical output\n' \
      "$malformed_absence" >&2
    exit 1
  fi
  grep -Fq 'ambiguous logical-partition probe' \
    "$scratch_dir/${malformed_absence}-absence-rejection.log" || {
    printf 'error: %s absent-logical output was not rejected explicitly\n' \
      "$malformed_absence" >&2
    exit 1
  }
  mapfile -t malformed_absence_mutations <"$scratch_dir/mutations.log"
  [[ ${#malformed_absence_mutations[@]} -eq 1 && \
     "${malformed_absence_mutations[0]}" == 'reboot fastboot' ]] || {
    printf 'error: %s absence rejection reached metadata mutation\n' \
      "$malformed_absence" >&2
    exit 1
  }
done

# Exact absence text is not authoritative when the transport exits with an
# unaudited status. In particular, status 2 must not be confused with pinned
# Platform-Tools 37's observed status-zero Partition-not-found response.
reset_pristine_restore_fixture
if run_mocked_restore MOCK_ABSENT_LOGICAL_EXIT_STATUS=2 \
    >"$scratch_dir/status-two-absence-rejection.log" 2>&1; then
  printf 'error: restore accepted status-two absent-logical output\n' >&2
  exit 1
fi
grep -Fq 'ambiguous logical-partition probe' \
  "$scratch_dir/status-two-absence-rejection.log" || {
  printf 'error: status-two absence was not rejected explicitly\n' >&2
  exit 1
}
mapfile -t status_two_absence_mutations <"$scratch_dir/mutations.log"
[[ ${#status_two_absence_mutations[@]} -eq 1 && \
   "${status_two_absence_mutations[0]}" == 'reboot fastboot' ]] || {
  printf 'error: status-two absence rejection reached metadata mutation\n' >&2
  exit 1
}

# Platform-Tools 37 cannot read physical partition sizes from cubs fastbootd:
# the transport returns this exact remote failure with status zero. Reconcile
# an interrupted enter_b_fastbootd_pending transaction from the already-A-only
# namespace produced by the GSI flash. This must skip the B-to-A metadata pivot
# and reach the stock logical replay without any B write or physical fastbootd
# query.
reset_pristine_restore_fixture
if run_mocked_restore MOCK_NAMESPACE_MODE=both_present \
    >"$scratch_dir/a-only-resume-setup.log" 2>&1; then
  printf 'error: A-only resume setup unexpectedly completed restore\n' >&2
  exit 1
fi
[[ $(sed -n '1p' "$scratch_dir/state/mode") == fastbootd ]] || {
  printf 'error: A-only resume setup did not remain in fastbootd\n' >&2
  exit 1
}
grep -Fxq 'state=enter_b_fastbootd_pending' \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: A-only resume setup lacks its entry journal\n' >&2
  exit 1
}
printf 'a\n' >"$scratch_dir/state/daemon_namespace"
printf 'a\n' >"$scratch_dir/state/metadata_namespace_a"
printf 'a\n' >"$scratch_dir/state/metadata_namespace_b"
printf '0x6B8BB000\n' >"$scratch_dir/state/size_system_a"
printf '0xC50000\n' >"$scratch_dir/state/size_system_dlkm_a"
printf '0x1ED65000\n' >"$scratch_dir/state/size_system_ext_a"
printf '0x1308A2000\n' >"$scratch_dir/state/size_product_a"
printf '0x444A6000\n' >"$scratch_dir/state/size_vendor_a"
printf '0x281D000\n' >"$scratch_dir/state/size_vendor_dlkm_a"
namespace_probe_status=0
namespace_probe=$(MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
  MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
  MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
  "$mock_fastboot" -s MOCK_CUBS_SERIAL \
    getvar has-slot:system 2>&1) || namespace_probe_status=$?
[[ $namespace_probe_status -eq 0 && \
   $(grep -Ec '^\(bootloader\) has-slot:system: no$' \
     <<<"$namespace_probe" || true) -eq 1 ]] || {
  printf 'error: mock does not reproduce fastbootd has-slot:system=no\n' >&2
  exit 1
}
namespace_probe_status=0
namespace_probe=$(MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
  MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
  MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
  "$mock_fastboot" -s MOCK_CUBS_SERIAL \
    getvar is-logical:system 2>&1) || namespace_probe_status=$?
[[ $namespace_probe_status -eq 0 && \
   $(grep -Ec \
     "^getvar:is-logical:system[[:space:]]+FAILED \(remote: 'Partition not found'\)$" \
     <<<"$namespace_probe" || true) -eq 1 ]] || {
  printf 'error: mock does not reproduce exact unsuffixed logical absence\n' >&2
  exit 1
}
physical_probe_status=0
physical_probe=$(MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
  MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
  MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
  "$mock_fastboot" -s MOCK_CUBS_SERIAL \
    getvar partition-size:vendor_boot_b 2>&1) || physical_probe_status=$?
[[ $physical_probe_status -eq 0 && \
   $(grep -Ec \
     "^getvar:partition-size:vendor_boot_b[[:space:]]+FAILED \(remote: 'Could not open partition'\)$" \
     <<<"$physical_probe" || true) -eq 1 ]] || {
  printf 'error: mock does not reproduce the PT37 fastbootd physical-size failure\n' >&2
  exit 1
}
[[ $(sed -n '1p' \
     "$scratch_dir/state/fastbootd_physical_size_probe_count") == 1 ]] || {
  printf 'error: PT37 fastbootd physical-size probe was not counted\n' >&2
  exit 1
}
: >"$scratch_dir/mutations.log"
printf '0\n' >"$scratch_dir/state/mutation_count"
printf '0\n' >"$scratch_dir/state/fastbootd_physical_size_probe_count"
run_mocked_restore >"$scratch_dir/a-only-fastbootd-resume.log" 2>&1
# shellcheck disable=SC2034
a_only_resume_expected=("${expected[@]:3}")
assert_mutations_equal a_only_resume_expected
[[ $(sed -n '1p' \
     "$scratch_dir/state/fastbootd_physical_size_probe_count") == 0 ]] || {
  printf 'error: A-only resume queried physical partition sizes in fastbootd\n' >&2
  exit 1
}
[[ $(sed -n '1p' "$scratch_dir/state/current_slot") == a && \
   $(sed -n '1p' "$scratch_dir/state/mode") == bootloader ]] || {
  printf 'error: A-only fastbootd resume did not finish on A bootloader\n' >&2
  exit 1
}
grep -Fxq 'state=awaiting_stock_android' \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: A-only fastbootd resume did not complete stock restore\n' >&2
  exit 1
}
if grep -Eq '(^|[[:space:]])[^[:space:]]+_b($|[[:space:]])' \
    "$scratch_dir/mutations.log"; then
  printf 'error: A-only fastbootd resume attempted a B-partition mutation\n' >&2
  exit 1
fi

# A nonterminal development transaction is a hard conflict.  Only flash-a's
# exact terminal aborted_for_restore handoff may be adopted.
reset_pristine_restore_fixture
printf 'state=abort_return_bootloader_pending\n' \
  >"$scratch_dir/recovery/slot-a-flash-transaction"
chmod 0600 "$scratch_dir/recovery/slot-a-flash-transaction"
if run_mocked_restore >"$scratch_dir/nonterminal-flash-conflict.log" 2>&1; then
  printf 'error: restore adopted a nonterminal flash transaction\n' >&2
  exit 1
fi
grep -Fq 'not an exact terminal aborted_for_restore handoff' \
  "$scratch_dir/nonterminal-flash-conflict.log" || {
  printf 'error: nonterminal flash conflict was not explicit\n' >&2
  exit 1
}
[[ ! -s "$scratch_dir/mutations.log" ]] || {
  printf 'error: nonterminal flash conflict was detected after a mutation\n' >&2
  exit 1
}

# A claimed v7 finalized-restore baseline belongs exclusively to the direct
# physical-B workflow until its five-file consumption journal retires it.
reset_pristine_restore_fixture
printf 'claimed-finalized-restore-baseline\n' \
  >"$scratch_dir/recovery/stock-a-baseline-evidence"
chmod 0600 "$scratch_dir/recovery/stock-a-baseline-evidence"
if run_mocked_restore >"$scratch_dir/active-baseline-conflict.log" 2>&1; then
  printf 'error: restore accepted an active direct-preparation baseline\n' >&2
  exit 1
fi
grep -Fq 'finish or recover the unresolved direct physical-B workflow' \
  "$scratch_dir/active-baseline-conflict.log" || {
  printf 'error: active baseline conflict was not explicit\n' >&2
  exit 1
}
[[ ! -s "$scratch_dir/mutations.log" ]] || {
  printf 'error: active baseline conflict was detected after a mutation\n' >&2
  exit 1
}

reset_pristine_restore_fixture
claimed=$created
adopted_bundle_manifest=$(printf 'mock-aborted-gsi-bundle\n' | \
  sha256sum | awk '{print $1}')
{
  printf 'schema=cubs-recovery-handoff-v2\n'
  printf 'state=claimed\n'
  printf 'handoff_kind=stock_b_anchor\n'
  printf 'created_epoch=%s\n' "$created"
  printf 'expires_epoch=%s\n' "$expires"
  printf 'claimed_epoch=%s\n' "$claimed"
  printf 'anchor_id=%s\n' "$anchor_id"
  printf 'serial_binding_sha256=%s\n' "$serial_binding"
  printf 'lineage_sha256=%s\n' "$lineage_sha"
  printf 'physical_b_sizes_sha256=%s\n' "$physical_sizes_sha"
  printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
  printf 'bundle_kind=gsi\n'
  printf 'bundle_manifest_sha256=%s\n' "$adopted_bundle_manifest"
} >"$scratch_dir/recovery/flash-handoff"
chmod 0600 "$scratch_dir/recovery/flash-handoff"
adopted_handoff_sha=$(sha256sum "$scratch_dir/recovery/flash-handoff" | \
  awk '{print $1}')
adopted_transaction_id=abcdef0123456789abcdef0123456789
adopted_transaction_binding=$(printf '%s\0%s' \
  "$adopted_transaction_id" MOCK_CUBS_SERIAL | sha256sum | awk '{print $1}')
adopted_targets_sha=$(printf 'system\n' | sha256sum | awk '{print $1}')
adopted_sizes_sha=$(printf 'system=2097152\n' | sha256sum | awk '{print $1}')
{
  printf 'schema=cubs-slot-a-flash-transaction-v1\n'
  printf 'state=aborted_for_restore\n'
  printf 'created_epoch=%s\n' "$created"
  printf 'transaction_id=%s\n' "$adopted_transaction_id"
  printf 'serial_binding_sha256=%s\n' "$adopted_transaction_binding"
  printf 'device=cubs\n'
  printf 'anchor_id=%s\n' "$anchor_id"
  printf 'lineage_sha256=%s\n' "$lineage_sha"
  printf 'handoff_sha256=%s\n' "$adopted_handoff_sha"
  printf 'physical_b_sizes_sha256=%s\n' "$physical_sizes_sha"
  printf 'stock_b_source=full_ota\n'
  printf 'stock_b_provenance_sha256=%s\n' "$FULL_OTA_SHA256"
  printf 'bundle_kind=gsi\n'
  printf 'bundle_manifest_sha256=%s\n' "$adopted_bundle_manifest"
  printf 'logical_targets_sha256=%s\n' "$adopted_targets_sha"
  printf 'logical_image_sizes_sha256=%s\n' "$adopted_sizes_sha"
  printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
} >"$scratch_dir/recovery/slot-a-flash-transaction"
chmod 0600 "$scratch_dir/recovery/slot-a-flash-transaction"
adopted_transaction_sha=$(sha256sum \
  "$scratch_dir/recovery/slot-a-flash-transaction" | awk '{print $1}')
pre_abort_transaction_sha=$(printf 'awaiting-runtime-transaction\n' | \
  sha256sum | awk '{print $1}')
runtime_report_sha=$(printf 'mock-runtime-report\n' | sha256sum | awk '{print $1}')
{
  printf 'schema=cubs-runtime-boot-attestation-v2\n'
  printf 'created_epoch=%s\n' "$created"
  printf 'anchor_id=%s\n' "$anchor_id"
  printf 'serial_binding_sha256=%s\n' "$serial_binding"
  printf 'lineage_sha256=%s\n' "$lineage_sha"
  printf 'handoff_sha256=%s\n' "$adopted_handoff_sha"
  printf 'flash_transaction_sha256=%s\n' "$pre_abort_transaction_sha"
  printf 'claimed_epoch=%s\n' "$claimed"
  printf 'device=cubs\n'
  printf 'slot_suffix=_a\n'
  printf 'bundle_kind=gsi\n'
  printf 'bundle_manifest_sha256=%s\n' "$adopted_bundle_manifest"
  printf 'output_build_id=mock_aosp17\n'
  printf 'build_type=userdebug\n'
  printf 'framework_security_patch=2026-08-05\n'
  printf 'build_fingerprint_sha256=%064d\n' 1
  printf 'boot_id=01234567-89ab-cdef-0123-456789abcdef\n'
  printf 'uptime_seconds=123\n'
  printf 'sys_boot_completed=1\n'
  printf 'validation_result=PASS\n'
  printf 'runtime_report_basename=runtime-validation-gsi-20260829T000000Z-1.txt\n'
  printf 'runtime_report_sha256=%s\n' "$runtime_report_sha"
  printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
} >"$scratch_dir/recovery/runtime-boot-attestation"
chmod 0600 "$scratch_dir/recovery/runtime-boot-attestation"
adopted_runtime_sha=$(sha256sum \
  "$scratch_dir/recovery/runtime-boot-attestation" | awk '{print $1}')
run_mocked_restore >"$scratch_dir/adopted-abort-restore.log" 2>&1
grep -Fxq "adopted_flash_transaction_sha256=$adopted_transaction_sha" \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: restore receipt did not bind the adopted terminal transaction\n' >&2
  exit 1
}
grep -Fxq "adopted_flash_serial_binding_sha256=$adopted_transaction_binding" \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: restore receipt did not bind the adopted salted serial\n' >&2
  exit 1
}
grep -Fxq "adopted_runtime_attestation_sha256=$adopted_runtime_sha" \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: restore receipt did not bind the coexisting runtime marker\n' >&2
  exit 1
}
cp -a -- "$scratch_dir/state" "$scratch_dir/state-adopted-template"
cp -a -- "$scratch_dir/recovery" "$scratch_dir/recovery-adopted-template"

# Continue the failed-stock-A recovery test from the original completed state.
rm -rf -- "$scratch_dir/state" "$scratch_dir/recovery"
cp -a -- "$scratch_dir/state-completed-template" "$scratch_dir/state"
cp -a -- "$scratch_dir/recovery-completed-template" "$scratch_dir/recovery"
: >"$scratch_dir/mutations.log"

# A failed restored A must remain recoverable with the retained receipt from
# current A. Inject the host-visible failure after set_active B has already
# changed boot control; the select_b_pending journal must make rerun safe.
lineage_before=$(sha256sum "$scratch_dir/recovery/lifeboat-lineage" | awk '{print $1}')
handoff_before=$(sha256sum "$scratch_dir/recovery/flash-handoff" | awk '{print $1}')
: >"$scratch_dir/mutations.log"
printf 'yes\n' >"$scratch_dir/state/slot_a_unbootable"
if MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
    MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
    MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    MOCK_VENDOR_BOOT_IMAGE="$mock_vendor_boot" \
    MOCK_ALLOW_SET_ACTIVE_B=1 \
    MOCK_FAIL_AFTER_SET_ACTIVE_B=1 \
    FASTBOOT="$mock_fastboot" \
    CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery" \
    CUBS_ALLOW_DATA_WIPE=1 \
    CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID \
      "$test_restore_runner" >"$scratch_dir/set-b-ack-failure.log" 2>&1; then
  printf 'error: injected post-set-active-B failure unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq 'slot-selection mutation may have started' \
  "$scratch_dir/set-b-ack-failure.log" || {
  printf 'error: restore suppressed the post-set-active-B recovery warning\n' >&2
  tail -80 "$scratch_dir/set-b-ack-failure.log" >&2 || true
  sed -n '1,120p' "$scratch_dir/mutations.log" >&2 || true
  exit 1
}
[[ $(sed -n '1p' "$scratch_dir/state/current_slot") == b && \
   $(sed -n '1p' "$scratch_dir/mutations.log") == 'set_active b' ]] || {
  printf 'error: set-active-B crash injection changed unexpected state\n' >&2
  exit 1
}
grep -Fxq 'state=select_b_pending' \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: select-B authorization was not durable before its ACK\n' >&2
  exit 1
}
[[ $(sha256sum "$scratch_dir/recovery/lifeboat-lineage" | awk '{print $1}') == \
     "$lineage_before" && \
   $(sha256sum "$scratch_dir/recovery/flash-handoff" | awk '{print $1}') == \
     "$handoff_before" ]] || {
  printf 'error: failed B selection altered recovery evidence\n' >&2
  exit 1
}

: >"$scratch_dir/mutations.log"
printf '0\n' >"$scratch_dir/state/vendor_boot_fetch_count"
MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
MOCK_VENDOR_BOOT_IMAGE="$mock_vendor_boot" \
FASTBOOT="$mock_fastboot" \
CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery" \
CUBS_ALLOW_DATA_WIPE=1 \
CUBS_RESTORE_CONFIRM=RESTORE_STOCK_A_SHARED_SUPER_INVALIDATES_B_ANDROID \
  "$test_restore_runner" >"$scratch_dir/resumed-restore.log" 2>&1
mapfile -t resumed_actual <"$scratch_dir/mutations.log"
resumed_expected=("${expected[0]}" "${expected[@]:3}")
(( ${#resumed_actual[@]} == ${#resumed_expected[@]} )) || {
  printf 'error: resumed restore mutation count mismatch\n' >&2
  exit 1
}
for ((index = 0; index < ${#resumed_expected[@]}; index += 1)); do
  [[ "${resumed_actual[$index]}" == "${resumed_expected[$index]}" ]] || {
    printf 'error: resumed restore mutation %d mismatch\n' "$index" >&2
    exit 1
  }
done
[[ $(sed -n '1p' "$scratch_dir/state/current_slot") == a && \
   $(sed -n '1p' "$scratch_dir/state/vendor_boot_fetch_count") == 3 ]] || {
  printf 'error: resumed restore did not finish on A with all live fetches\n' >&2
  exit 1
}
grep -Fxq 'state=awaiting_stock_android' \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: resumed restore did not republish awaiting stock Android\n' >&2
  exit 1
}

# Save the exact awaiting transaction so each boot-control/finalization crash
# branch starts from identical private evidence.
cp -a -- "$scratch_dir/recovery" "$scratch_dir/recovery-template"

reset_finalization_fixture() {
  local mode=$1 slot_a_successful=$2
  rm -rf -- "$scratch_dir/recovery"
  cp -a -- "$scratch_dir/recovery-template" "$scratch_dir/recovery"
  : >"$scratch_dir/mutations.log"
  : >"$scratch_dir/adb-mutations.log"
  printf '%s\n' "$mode" >"$scratch_dir/state/mode"
  printf 'a\n' >"$scratch_dir/state/current_slot"
  printf '%s\n' "$slot_a_successful" >"$scratch_dir/state/slot_a_successful"
  printf 'no\n' >"$scratch_dir/state/slot_a_unbootable"
  printf 'no\n' >"$scratch_dir/state/slot_b_unbootable"
  printf '0\n' >"$scratch_dir/state/vendor_boot_fetch_count"
  sed -i 's/^state=awaiting_stock_android$/state=boot_control_pending/' \
    "$scratch_dir/recovery/stock-restore-transaction"
}

run_pending_finalization() {
  local fastboot_serial=${1:-MOCK_CUBS_SERIAL}
  MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
  MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
  MOCK_FASTBOOT_SERIAL="$fastboot_serial" \
  MOCK_VENDOR_BOOT_IMAGE="$mock_vendor_boot" \
  MOCK_ADB_LOG="$scratch_dir/adb-mutations.log" \
  MOCK_ADB_SERIAL=MOCK_CUBS_SERIAL \
  FASTBOOT="$mock_fastboot" \
  ADB="$mock_adb" \
  CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery" \
  CUBS_ALLOW_STOCK_RESTORE_FINALIZE=1 \
  CUBS_RESTORE_CONFIRM=FINALIZE_EXACT_STOCK_A_RESTORE_AFTER_SUCCESSFUL_ANDROID_BOOT \
    "$test_restore_runner" finalize-stock-android
}

# Retirement of an adopted abort first publishes an exact private archive,
# then removes the active terminal transaction and generic recovery evidence.
rm -rf -- "$scratch_dir/state" "$scratch_dir/recovery"
cp -a -- "$scratch_dir/state-adopted-template" "$scratch_dir/state"
cp -a -- "$scratch_dir/recovery-adopted-template" "$scratch_dir/recovery"
: >"$scratch_dir/mutations.log"
: >"$scratch_dir/adb-mutations.log"
printf 'bootloader\n' >"$scratch_dir/state/mode"
printf 'a\n' >"$scratch_dir/state/current_slot"
printf 'yes\n' >"$scratch_dir/state/slot_a_successful"
printf 'no\n' >"$scratch_dir/state/slot_a_unbootable"
printf 'no\n' >"$scratch_dir/state/slot_b_unbootable"
printf '0\n' >"$scratch_dir/state/vendor_boot_fetch_count"
sed -i 's/^state=awaiting_stock_android$/state=boot_control_pending/' \
  "$scratch_dir/recovery/stock-restore-transaction"
run_pending_finalization >"$scratch_dir/adopted-retirement.log" 2>&1
mapfile -t adoption_archives < <(
  find "$scratch_dir/recovery/consumed" -mindepth 1 -maxdepth 1 -type d \
    -name 'stock-restore-adoption-*'
)
[[ ${#adoption_archives[@]} -eq 1 ]] || {
  printf 'error: adopted abort archive cardinality is not one\n' >&2
  exit 1
}
adoption_archive=${adoption_archives[0]}
[[ ! -e "$scratch_dir/recovery/slot-a-flash-transaction" && \
   -f "$adoption_archive/slot-a-flash-transaction" && \
   -f "$adoption_archive/runtime-boot-attestation" && \
   $(sha256sum "$adoption_archive/slot-a-flash-transaction" | awk '{print $1}') == \
     "$adopted_transaction_sha" && \
   $(sha256sum "$adoption_archive/runtime-boot-attestation" | awk '{print $1}') == \
     "$adopted_runtime_sha" && \
   ! -e "$scratch_dir/recovery/lifeboat-lineage" && \
   ! -e "$scratch_dir/recovery/flash-handoff" && \
   ! -e "$scratch_dir/recovery/stock-restore-transaction" ]] || {
  printf 'error: adopted abort was not atomically archived and retired\n' >&2
  exit 1
}

# Model a process death after archive publication and runtime-marker removal,
# but before the terminal transaction (the discoverability anchor) is removed.
# Host-only retiring_evidence resume must finish that exact cleanup.
rm -rf -- "$scratch_dir/state" "$scratch_dir/recovery"
cp -a -- "$scratch_dir/state-adopted-template" "$scratch_dir/state"
cp -a -- "$scratch_dir/recovery-adopted-template" "$scratch_dir/recovery"
sed -i 's/^state=awaiting_stock_android$/state=retiring_evidence/' \
  "$scratch_dir/recovery/stock-restore-transaction"
crash_restore_id=$(sed -n 's/^transaction_id=//p' \
  "$scratch_dir/recovery/stock-restore-transaction")
crash_archive="$scratch_dir/recovery/consumed/stock-restore-adoption-${crash_restore_id}-${adopted_transaction_sha}"
mkdir -p "$scratch_dir/recovery/consumed"
chmod 0700 "$scratch_dir/recovery/consumed"
mkdir -m 0700 "$crash_archive"
cp -- "$scratch_dir/recovery/slot-a-flash-transaction" \
  "$crash_archive/slot-a-flash-transaction"
cp -- "$scratch_dir/recovery/runtime-boot-attestation" \
  "$crash_archive/runtime-boot-attestation"
chmod 0600 "$crash_archive/slot-a-flash-transaction" \
  "$crash_archive/runtime-boot-attestation"
rm -f -- "$scratch_dir/recovery/runtime-boot-attestation"
CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery" \
CUBS_ALLOW_STOCK_RESTORE_FINALIZE=1 \
CUBS_RESTORE_CONFIRM=FINALIZE_EXACT_STOCK_A_RESTORE_AFTER_SUCCESSFUL_ANDROID_BOOT \
  "$test_restore_runner" finalize-stock-android \
  >"$scratch_dir/adoption-unlink-crash-resume.log" 2>&1
[[ ! -e "$scratch_dir/recovery/slot-a-flash-transaction" && \
   ! -e "$scratch_dir/recovery/lifeboat-lineage" && \
   ! -e "$scratch_dir/recovery/flash-handoff" && \
   ! -e "$scratch_dir/recovery/stock-restore-transaction" && \
   -f "$crash_archive/slot-a-flash-transaction" && \
   -f "$crash_archive/runtime-boot-attestation" ]] || {
  printf 'error: adopted-evidence unlink crash did not resume exactly\n' >&2
  exit 1
}

# Fastboot cannot commit retirement until the restored target is marked
# successful, even though the earlier exact Android audit was journaled.
reset_finalization_fixture bootloader no
if run_pending_finalization >"$scratch_dir/pending-a-not-successful.log" 2>&1; then
  printf 'error: boot-control pending retired unsuccessful stock A\n' >&2
  exit 1
fi
grep -Fq 'lacks exact successful boot-control proof' \
  "$scratch_dir/pending-a-not-successful.log" || {
  printf 'error: unsuccessful stock-A finalization did not report its blocker\n' >&2
  exit 1
}
grep -Fxq 'state=boot_control_pending' \
  "$scratch_dir/recovery/stock-restore-transaction" || {
  printf 'error: failed success-bit audit changed the pending journal\n' >&2
  exit 1
}
[[ -f "$scratch_dir/recovery/lifeboat-lineage" && \
   -f "$scratch_dir/recovery/flash-handoff" && \
   ! -s "$scratch_dir/mutations.log" ]] || {
  printf 'error: failed success-bit audit changed recovery evidence or device state\n' >&2
  exit 1
}

# The fastboot serial is rebound to the transaction salt; a different sole
# transport is rejected before live-byte fetch or evidence retirement.
reset_finalization_fixture bootloader yes
if run_pending_finalization WRONG_CUBS_SERIAL \
    >"$scratch_dir/pending-wrong-fastboot-serial.log" 2>&1; then
  printf 'error: boot-control pending accepted another fastboot transport\n' >&2
  exit 1
fi
grep -Fq 'belongs to another USB transport' \
  "$scratch_dir/pending-wrong-fastboot-serial.log" || {
  printf 'error: pending serial mismatch was not explicitly rejected\n' >&2
  exit 1
}
[[ ! -s "$scratch_dir/mutations.log" && \
   $(sed -n '1p' "$scratch_dir/state/vendor_boot_fetch_count") == 0 ]] || {
  printf 'error: serial mismatch reached a mutation or live fetch\n' >&2
  exit 1
}

# Resume directly from the bound successful-A bootloader state.
reset_finalization_fixture bootloader yes
run_pending_finalization >"$scratch_dir/pending-fastboot-resume.log" 2>&1
[[ ! -e "$scratch_dir/recovery/lifeboat-lineage" && \
   ! -e "$scratch_dir/recovery/flash-handoff" && \
   ! -e "$scratch_dir/recovery/stock-restore-transaction" && \
   ! -s "$scratch_dir/adb-mutations.log" && \
   $(sed -n '1p' "$scratch_dir/state/vendor_boot_fetch_count") == 1 ]] || {
  printf 'error: fastboot boot-control pending resume did not retire exactly\n' >&2
  exit 1
}

# If the process died before issuing the ADB reboot (or A was booted again),
# pending resume repeats the full Android audit, reboots the same salted serial,
# and then applies the identical fastboot success gate.
reset_finalization_fixture android yes
run_pending_finalization >"$scratch_dir/pending-android-resume.log" 2>&1
[[ ! -e "$scratch_dir/recovery/lifeboat-lineage" && \
   ! -e "$scratch_dir/recovery/flash-handoff" && \
   ! -e "$scratch_dir/recovery/stock-restore-transaction" && \
   $(sed -n '1p' "$scratch_dir/state/mode") == bootloader && \
   $(sed -n '1p' "$scratch_dir/state/vendor_boot_fetch_count") == 1 && \
   $(sed -n '1p' "$scratch_dir/adb-mutations.log") == 'reboot bootloader' ]] || {
  printf 'error: Android boot-control pending resume did not reverify and retire\n' >&2
  exit 1
}

# Simulate a process death after the semantic retirement commit and after only
# the first evidence unlink. This resume deliberately needs no USB transport.
reset_finalization_fixture bootloader yes
sed -i 's/^state=boot_control_pending$/state=retiring_evidence/' \
  "$scratch_dir/recovery/stock-restore-transaction"
rm -f -- "$scratch_dir/recovery/flash-handoff"
CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery" \
CUBS_ALLOW_STOCK_RESTORE_FINALIZE=1 \
CUBS_RESTORE_CONFIRM=FINALIZE_EXACT_STOCK_A_RESTORE_AFTER_SUCCESSFUL_ANDROID_BOOT \
  "$test_restore_runner" finalize-stock-android \
  >"$scratch_dir/retirement-resume.log" 2>&1
[[ ! -e "$scratch_dir/recovery/lifeboat-lineage" && \
   ! -e "$scratch_dir/recovery/flash-handoff" && \
   ! -e "$scratch_dir/recovery/stock-restore-transaction" ]] || {
  printf 'error: committed evidence retirement did not finish idempotently\n' >&2
  exit 1
}
[[ $(find "$scratch_dir/recovery/consumed" -maxdepth 1 -type f \
       -name 'stock-restore-*' | wc -l) -eq 1 ]] || {
  printf 'error: completed restore receipt was not archived exactly once\n' >&2
  exit 1
}

printf 'mocked restore, failed-A recovery, boot-control resume, and retirement passed\n'
