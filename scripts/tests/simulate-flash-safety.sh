#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
mock_fastboot="$test_dir/mock-fastboot.sh"
# shellcheck source=../../config/release.env disable=SC1091
source "$project_root/config/release.env"
# shellcheck source=../../config/recovery.env disable=SC1091
source "$project_root/config/recovery.env"

for command_name in awk chmod cp date find grep mkdir mktemp od realpath rm \
    sed sha256sum sort stat truncate wc; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'error: missing test command: %s\n' "$command_name" >&2
    exit 1
  }
done
[[ -x "$mock_fastboot" ]] || {
  printf 'error: mock fastboot is not executable: %s\n' "$mock_fastboot" >&2
  exit 1
}

mock_fastboot_sha256=$(sha256sum "$mock_fastboot" | awk '{print $1}')
firmware_partitions=(
  abl bl31 cap cpm dbc dbl
  dram_init_0 dram_init_1 dram_init_2 dram_init_3
  dram_init_4 dram_init_5 dram_init_6 dram_init_7
  dram_init_8 dram_init_9 dram_init_10 dram_init_11
  dram_phy gc gdmc gsa_bl1 gsa_fw tzsw modem
)
firmware_images=()
for partition in "${firmware_partitions[@]}"; do
  firmware_images+=("$partition.img")
done
preserved_b_partitions=(
  "${firmware_partitions[@]}"
  boot init_boot dtbo vendor_boot vendor_kernel_boot pvmfw
  vbmeta_system vbmeta_vendor vbmeta
)
logical_partitions=(system system_dlkm system_ext product vendor vendor_dlkm)

scratch_parent="$project_root/work/flash-safety-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
mock_vendor_boot="$scratch_dir/vendor_boot.img"
truncate -s 4096 "$mock_vendor_boot"
mock_vendor_boot_sha256=$(sha256sum "$mock_vendor_boot" | awk '{print $1}')
cleanup() {
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

write_mock_sparse_system() {
  local destination=$1
  # Sparse v1: three 4096-byte DONT_CARE blocks. On disk this is 40 bytes;
  # fastboot must expose the expanded logical partition size as 0x3000.
  printf \
    '\x3a\xff\x26\xed\x01\x00\x00\x00\x1c\x00\x0c\x00\x00\x10\x00\x00\x03\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\xc3\xca\x00\x00\x03\x00\x00\x00\x0c\x00\x00\x00' \
    >"$destination"
}

make_bundle() {
  local kind=$1 bundle=$2 image_name attestation_sha
  local -a images=()
  case "$kind" in
    gsi)
      images=(system.img pvmfw.img vbmeta.img)
      ;;
    cubs)
      images=(
        "${firmware_images[@]}"
        boot.img init_boot.img dtbo.img vendor_boot.img
        vendor_kernel_boot.img pvmfw.img vbmeta.img vbmeta_system.img
        vbmeta_vendor.img system.img system_dlkm.img system_ext.img
        product.img vendor.img vendor_dlkm.img
      )
      ;;
    *) printf 'error: unsupported bundle kind: %s\n' "$kind" >&2; exit 1 ;;
  esac

  mkdir -p "$bundle"
  for image_name in "${images[@]}"; do
    truncate -s 4096 "$bundle/$image_name"
  done
  write_mock_sparse_system "$bundle/system.img"
  printf '%s\n' "$kind" >"$bundle/bundle-kind"
  {
    printf 'kind=%s\n' "$kind"
    printf 'build_variant=userdebug\n'
    printf 'source_aosp_build_id=MOCK_SOURCE\n'
    printf 'output_build_id=MOCK_OUTPUT\n'
    printf 'framework_security_patch=2099-01-01\n'
  } >"$bundle/BUILD_ATTESTATION.txt"
  attestation_sha=$(sha256sum "$bundle/BUILD_ATTESTATION.txt" | awk '{print $1}')
  {
    printf 'bundle_kind=%s\n' "$kind"
    printf 'source_aosp_build_id=MOCK_SOURCE\n'
    printf 'output_build_id=MOCK_OUTPUT\n'
    printf 'framework_security_patch=2099-01-01\n'
    printf 'stock_vendor_build=CD1A.260714.001.A9\n'
    printf 'build_attestation_sha256=%s\n' "$attestation_sha"
    printf 'flash_scope=slot_a_partition_names_shared_super\n'
    printf 'recovery_anchor=slot_b_physical_fastbootd_lifeboat\n'
  } >"$bundle/BUNDLE_INFO.txt"
  {
    printf 'require product=cubs\n'
    printf 'require version-bootloader=spacecraft-17.4-15938155\n'
    printf 'require version-baseband=a900a-MP_260716-260716-M-15880348\n'
  } >"$bundle/firmware-requirements.txt"
  sed -E \
    -e "s/^expected_fastboot_sha256=.*/expected_fastboot_sha256=$mock_fastboot_sha256/" \
    -e "s/^expected_recovery_policy_sha256=.*/expected_recovery_policy_sha256=$CUBS_RECOVERY_POLICY_SHA256/" \
    -e "s/^expected_physical_b_vendor_boot_fetch_sha256=.*/expected_physical_b_vendor_boot_fetch_sha256=$mock_vendor_boot_sha256/" \
    "$project_root/scripts/flash-a.sh" >"$bundle/flash-all.sh"
  chmod 0755 "$bundle/flash-all.sh"
  (
    cd "$bundle"
    sha256sum bundle-kind BUNDLE_INFO.txt BUILD_ATTESTATION.txt \
      firmware-requirements.txt flash-all.sh "${images[@]}" >SHA256SUMS
  )
}

physical_b_sizes_sha256() {
  local partition size lines=
  for partition in "${preserved_b_partitions[@]}"; do
    size=4000000
    [[ "$partition" == vendor_boot ]] && size=1000
    lines+="${partition}_b=$size"$'\n'
  done
  printf '%s' "$lines" | sha256sum | awk '{print $1}'
}

make_recovery_handoff() {
  local kind=${1:-stock_b_anchor} source=${2:-full_ota}
  local anchor_id created expires serial_binding sizes lineage_sha
  local provenance source_manifest vendor_fetch recovery_dir
  recovery_dir="$scratch_dir/recovery"
  rm -rf -- "$recovery_dir"
  mkdir -m 0700 "$recovery_dir"
  anchor_id=0123456789abcdef0123456789abcdef
  created=$(date +%s)
  expires=$((created + CUBS_RECOVERY_HANDOFF_READY_SECONDS))
  serial_binding=$(printf '%s\0%s' "$anchor_id" MOCK_CUBS_SERIAL | \
    sha256sum | awk '{print $1}')
  sizes=$(physical_b_sizes_sha256)
  case "$source" in
    full_ota)
      provenance=$FULL_OTA_SHA256
      source_manifest=none
      vendor_fetch=none
      ;;
    direct_factory_physical_b)
      provenance=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
      source_manifest=$CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256
      vendor_fetch=$mock_vendor_boot_sha256
      ;;
    *) printf 'error: unsupported lineage source: %s\n' "$source" >&2; exit 1 ;;
  esac
  {
    printf 'schema=cubs-recovery-lineage-v2\n'
    printf 'anchor_id=%s\n' "$anchor_id"
    printf 'created_epoch=%s\n' "$created"
    printf 'serial_binding_sha256=%s\n' "$serial_binding"
    printf 'device=cubs\n'
    printf 'stock_build_id=CD1A.260714.001.A9\n'
    printf 'stock_fingerprint_sha256=%s\n' "$CUBS_STOCK_FINGERPRINT_SHA256"
    printf 'factory_sha256=%s\n' "$FACTORY_IMAGE_SHA256"
    printf 'full_ota_sha256=%s\n' "$FULL_OTA_SHA256"
    printf 'bootloader=spacecraft-17.4-15938155\n'
    printf 'baseband=a900a-MP_260716-260716-M-15880348\n'
    printf 'ab_ota_partitions_sha256=%s\n' "$CUBS_AB_OTA_PARTITIONS_SHA256"
    printf 'shared_super_layout_sha256=%s\n' "$CUBS_SHARED_SUPER_LAYOUT_SHA256"
    printf 'physical_b_sizes_sha256=%s\n' "$sizes"
    printf 'stock_b_source=%s\n' "$source"
    printf 'stock_b_provenance_sha256=%s\n' "$provenance"
    printf 'physical_b_source_manifest_sha256=%s\n' "$source_manifest"
    printf 'physical_b_vendor_boot_fetch_sha256=%s\n' "$vendor_fetch"
    printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
  } >"$recovery_dir/lifeboat-lineage"
  chmod 0600 "$recovery_dir/lifeboat-lineage"
  lineage_sha=$(sha256sum "$recovery_dir/lifeboat-lineage" | awk '{print $1}')
  {
    printf 'schema=cubs-recovery-handoff-v2\n'
    printf 'state=ready\n'
    printf 'handoff_kind=%s\n' "$kind"
    printf 'created_epoch=%s\n' "$created"
    printf 'expires_epoch=%s\n' "$expires"
    printf 'claimed_epoch=0\n'
    printf 'anchor_id=%s\n' "$anchor_id"
    printf 'serial_binding_sha256=%s\n' "$serial_binding"
    printf 'lineage_sha256=%s\n' "$lineage_sha"
    printf 'physical_b_sizes_sha256=%s\n' "$sizes"
    printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
    printf 'bundle_kind=none\n'
    printf 'bundle_manifest_sha256=none\n'
  } >"$recovery_dir/flash-handoff"
  chmod 0600 "$recovery_dir/flash-handoff"
}

reset_mock() {
  rm -rf -- "$scratch_dir/state"
  mkdir -p "$scratch_dir/state"
  printf '0x1000\n' >"$scratch_dir/state/size_vendor_boot_a"
  printf '0x1000\n' >"$scratch_dir/state/size_vendor_boot_b"
  : >"$scratch_dir/mutations.log"
  make_recovery_handoff
}

recovery_value() {
  local path=$1 key=$2
  sed -n "s/^$key=//p" "$path"
}

transaction_state() {
  recovery_value "$scratch_dir/recovery/slot-a-flash-transaction" state
}

run_bundle() {
  local bundle=$1
  shift
  env \
    MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
    MOCK_FASTBOOT_LOG="$scratch_dir/mutations.log" \
    MOCK_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    MOCK_VENDOR_BOOT_IMAGE="$mock_vendor_boot" \
    MOCK_RECOVERY_STATE_DIR="$scratch_dir/recovery" \
    FASTBOOT="$mock_fastboot" \
    CUBS_FASTBOOT_SERIAL=MOCK_CUBS_SERIAL \
    CUBS_RECOVERY_HANDOFF="$scratch_dir/recovery/flash-handoff" \
    CUBS_ALLOW_DATA_WIPE=1 \
    CUBS_FLASH_CONFIRM=FLASH_CUBS_A_SHARED_SUPER_INVALIDATES_B_ANDROID \
    CUBS_GSI_STOCK_A_BASELINE_CONFIRMED=1 \
    "$@" "$bundle/flash-all.sh"
}

resume_bundle() {
  local bundle=$1
  shift
  run_bundle "$bundle" \
    CUBS_FLASH_RESUME_CONFIRM=RESUME_EXACT_CUBS_A_TRANSACTION_USING_PHYSICAL_B_LIFEBOAT \
    "$@"
}

abort_bundle() {
  local bundle=$1
  shift
  run_bundle "$bundle" \
    CUBS_FLASH_ABORT_CONFIRM=ABORT_EXACT_CUBS_A_TRANSACTION_FOR_STOCK_RESTORE \
    "$@"
}

finalize_bundle() {
  local bundle=$1
  shift
  run_bundle "$bundle" \
    CUBS_FLASH_FINALIZE_CONFIRM=FINALIZE_EXACT_CUBS_A_TRANSACTION_AFTER_SUCCESSFUL_ANDROID_BOOT \
    "$@"
}

assert_no_forbidden_mutations() {
  if grep -Eq '(^| )[^ ]+_b( |$)|^reboot$|^reboot [^fb]' \
      "$scratch_dir/mutations.log"; then
    printf 'error: mutation log contains a slot-B write or normal reboot\n' >&2
    sed -n '1,160p' "$scratch_dir/mutations.log" >&2
    exit 1
  fi
}

assert_completed_transaction() {
  local description=$1
  [[ $(transaction_state) == awaiting_runtime && \
     $(recovery_value "$scratch_dir/recovery/flash-handoff" state) == claimed && \
     $(sed -n '1p' "$scratch_dir/state/current_slot") == a && \
     $(sed -n '1p' "$scratch_dir/state/mode") == bootloader && \
     $(sed -n '1p' "$scratch_dir/state/fastboot_entry_slot") == a && \
     $(grep -c '^reboot fastboot$' "$scratch_dir/mutations.log") -eq 1 && \
     $(sed -n '1p' "$scratch_dir/state/size_system_a") == 0x3000 && \
     ! -e "$scratch_dir/state/fastbootd_physical_size_probe_count" ]] || {
    printf 'error: %s did not finish the exact A-origin transaction\n' \
      "$description" >&2
    exit 1
  }
  assert_no_forbidden_mutations
}

assert_rejected_without_mutation() {
  local description=$1 bundle=$2
  shift 2
  if run_bundle "$bundle" "$@" >"$scratch_dir/rejected.log" 2>&1; then
    printf 'error: unsafe case was accepted: %s\n' "$description" >&2
    exit 1
  fi
  [[ ! -s "$scratch_dir/mutations.log" ]] || {
    printf 'error: rejection mutated device state: %s\n' "$description" >&2
    exit 1
  }
}

assert_namespace_rejected_before_write() {
  local description=$1 bundle=$2 write_count
  shift 2
  reset_mock
  if run_bundle "$bundle" "$@" \
      >"$scratch_dir/namespace-$description.log" 2>&1; then
    printf 'error: namespace anomaly was accepted: %s\n' "$description" >&2
    exit 1
  fi
  write_count=$(grep -Ec '^(resize|flash|erase) ' \
    "$scratch_dir/mutations.log" || true)
  [[ $(transaction_state) == enter_a_fastbootd_pending && \
     "$write_count" == 0 && \
     ! -e "$scratch_dir/state/fastbootd_physical_size_probe_count" ]] || {
    printf 'error: namespace anomaly reached a write or physical-size probe: %s\n' \
      "$description" >&2
    exit 1
  }
  abort_bundle "$bundle"
  [[ $(transaction_state) == aborted_for_restore ]] || {
    printf 'error: namespace rejection could not hand off to restore: %s\n' \
      "$description" >&2
    exit 1
  }
}

make_runtime_boot_attestation() {
  local bundle=$1 created kind manifest handoff lineage transaction
  local handoff_sha lineage_sha transaction_sha runtime
  handoff="$scratch_dir/recovery/flash-handoff"
  lineage="$scratch_dir/recovery/lifeboat-lineage"
  transaction="$scratch_dir/recovery/slot-a-flash-transaction"
  runtime="$scratch_dir/recovery/runtime-boot-attestation"
  kind=$(sed -n '1p' "$bundle/bundle-kind")
  manifest=$(sha256sum "$bundle/SHA256SUMS" | awk '{print $1}')
  handoff_sha=$(sha256sum "$handoff" | awk '{print $1}')
  lineage_sha=$(sha256sum "$lineage" | awk '{print $1}')
  transaction_sha=$(sha256sum "$transaction" | awk '{print $1}')
  created=$(date +%s)
  {
    printf 'schema=cubs-runtime-boot-attestation-v2\n'
    printf 'created_epoch=%s\n' "$created"
    printf 'anchor_id=%s\n' "$(recovery_value "$lineage" anchor_id)"
    printf 'serial_binding_sha256=%s\n' \
      "$(recovery_value "$lineage" serial_binding_sha256)"
    printf 'lineage_sha256=%s\n' "$lineage_sha"
    printf 'handoff_sha256=%s\n' "$handoff_sha"
    printf 'flash_transaction_sha256=%s\n' "$transaction_sha"
    printf 'claimed_epoch=%s\n' "$(recovery_value "$handoff" claimed_epoch)"
    printf 'device=cubs\n'
    printf 'slot_suffix=_a\n'
    printf 'bundle_kind=%s\n' "$kind"
    printf 'bundle_manifest_sha256=%s\n' "$manifest"
    printf 'output_build_id=MOCK_OUTPUT\n'
    printf 'build_type=userdebug\n'
    printf 'framework_security_patch=2099-01-01\n'
    printf 'build_fingerprint_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    printf 'boot_id=01234567-89ab-cdef-0123-456789abcdef\n'
    printf 'uptime_seconds=300\n'
    printf 'sys_boot_completed=1\n'
    printf 'validation_result=PASS\n'
    printf 'runtime_report_basename=runtime-validation-%s-20990101T000000Z-1.txt\n' "$kind"
    printf 'runtime_report_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
    printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
  } >"$runtime"
  chmod 0600 "$runtime"
}

make_flash_retirement_journal() {
  local bundle=$1 created destination handoff lineage transaction runtime
  local handoff_sha kind lineage_sha manifest transaction_sha runtime_sha journal
  handoff="$scratch_dir/recovery/flash-handoff"
  lineage="$scratch_dir/recovery/lifeboat-lineage"
  transaction="$scratch_dir/recovery/slot-a-flash-transaction"
  runtime="$scratch_dir/recovery/runtime-boot-attestation"
  journal="$scratch_dir/recovery/flash-retirement-transaction"
  kind=$(sed -n '1p' "$bundle/bundle-kind")
  manifest=$(sha256sum "$bundle/SHA256SUMS" | awk '{print $1}')
  lineage_sha=$(sha256sum "$lineage" | awk '{print $1}')
  handoff_sha=$(sha256sum "$handoff" | awk '{print $1}')
  transaction_sha=$(sha256sum "$transaction" | awk '{print $1}')
  runtime_sha=$(sha256sum "$runtime" | awk '{print $1}')
  destination="flash-$(recovery_value "$lineage" anchor_id)-${manifest:0:16}-$runtime_sha"
  created=$(date +%s)
  {
    printf 'schema=cubs-flash-retirement-v2\n'
    printf 'created_epoch=%s\n' "$created"
    printf 'anchor_id=%s\n' "$(recovery_value "$lineage" anchor_id)"
    printf 'serial_binding_sha256=%s\n' \
      "$(recovery_value "$lineage" serial_binding_sha256)"
    printf 'lineage_sha256=%s\n' "$lineage_sha"
    printf 'handoff_sha256=%s\n' "$handoff_sha"
    printf 'flash_transaction_sha256=%s\n' "$transaction_sha"
    printf 'claimed_epoch=%s\n' "$(recovery_value "$handoff" claimed_epoch)"
    printf 'runtime_attestation_sha256=%s\n' "$runtime_sha"
    printf 'bundle_kind=%s\n' "$kind"
    printf 'bundle_manifest_sha256=%s\n' "$manifest"
    printf 'destination_basename=%s\n' "$destination"
    printf 'recovery_policy_sha256=%s\n' "$CUBS_RECOVERY_POLICY_SHA256"
  } >"$journal"
  chmod 0600 "$journal"
}

publish_mock_flash_retirement_archive() {
  local recovery_dir destination journal
  recovery_dir="$scratch_dir/recovery"
  journal="$recovery_dir/flash-retirement-transaction"
  destination="$recovery_dir/consumed/$(recovery_value "$journal" destination_basename)"
  mkdir -m 0700 "$recovery_dir/consumed"
  mkdir -m 0700 "$destination"
  cp -- "$recovery_dir/lifeboat-lineage" "$destination/lifeboat-lineage"
  cp -- "$recovery_dir/flash-handoff" "$destination/flash-handoff"
  cp -- "$recovery_dir/runtime-boot-attestation" \
    "$destination/runtime-boot-attestation"
  cp -- "$recovery_dir/slot-a-flash-transaction" \
    "$destination/slot-a-flash-transaction"
  cp -- "$journal" "$destination/retirement-receipt"
  chmod 0600 "$destination"/*
}

age_claim_and_rebind_transaction() {
  local now old_created old_claimed old_expires handoff transaction handoff_sha
  now=$(date +%s)
  old_created=$((now - CUBS_RECOVERY_HANDOFF_RESUME_SECONDS - 300))
  old_claimed=$((old_created + 60))
  old_expires=$((old_created + CUBS_RECOVERY_HANDOFF_READY_SECONDS))
  handoff="$scratch_dir/recovery/flash-handoff"
  transaction="$scratch_dir/recovery/slot-a-flash-transaction"
  sed -i \
    -e "s/^created_epoch=.*/created_epoch=$old_created/" \
    -e "s/^expires_epoch=.*/expires_epoch=$old_expires/" \
    -e "s/^claimed_epoch=.*/claimed_epoch=$old_claimed/" \
    "$handoff"
  handoff_sha=$(sha256sum "$handoff" | awk '{print $1}')
  sed -i "s/^handoff_sha256=.*/handoff_sha256=$handoff_sha/" "$transaction"
}

gsi_bundle="$scratch_dir/gsi"
cubs_bundle="$scratch_dir/cubs"
make_bundle gsi "$gsi_bundle"
make_bundle cubs "$cubs_bundle"

# New work must start in bootloader B with complete fresh authority.
reset_mock
rm -f -- "$scratch_dir/recovery/flash-handoff"
assert_rejected_without_mutation missing-handoff "$gsi_bundle"
reset_mock
printf 'fastbootd\n' >"$scratch_dir/state/mode"
assert_rejected_without_mutation initial-b-fastbootd "$gsi_bundle"
reset_mock
printf 'no\n' >"$scratch_dir/state/slot_b_successful"
assert_rejected_without_mutation full-ota-b-unsuccessful "$gsi_bundle"

# Uniform has-slot:no proves every unsuffixed logical name absent before the
# normal B bootloader -> A fastbootd transaction. The sparse system image must
# be checked at its expanded 0x3000 size.
reset_mock
run_bundle "$gsi_bundle" \
  MOCK_LOGICAL_HAS_SLOT_RESPONSE=no \
  MOCK_ABSENT_LOGICAL_STATUS_ZERO=1
assert_completed_transaction uniform-has-slot-no
mapfile -t baseline_mutations <"$scratch_dir/mutations.log"
expected_baseline=(
  'set_active a'
  'reboot fastboot'
  'resize system_a 0'
  'flash system_a'
  'reboot bootloader'
  'flash pvmfw_a'
  'flash vbmeta_a disable-verity disable-verification'
  'erase userdata'
  'erase metadata'
  'set_active a'
)
[[ "${baseline_mutations[*]}" == "${expected_baseline[*]}" ]] || {
  printf 'error: baseline A-origin mutation order differs\n' >&2
  printf 'actual: %s\n' "${baseline_mutations[*]}" >&2
  exit 1
}

# Uniform has-slot:yes intentionally makes no claim about unsuffixed logical
# names. A forbidden mock response proves they are never queried. Conventional
# status-one Partition-not-found responses still prove every explicit B name
# absent.
reset_mock
run_bundle "$gsi_bundle" \
  MOCK_LOGICAL_HAS_SLOT_RESPONSE=yes \
  MOCK_UNSUFFIXED_LOGICAL_RESPONSE=query_forbidden \
  MOCK_ABSENT_LOGICAL_STATUS_ZERO=0
assert_completed_transaction uniform-has-slot-yes

# Crash after a representative mutation in every durable phase, then replay
# the exact transaction. Every path enters fastbootd exactly once and only A.
crash_points=(1 2 3 5 6 10)
expected_states=(
  select_a_bootloader_pending
  enter_a_fastbootd_pending
  logical_writes_pending
  return_a_bootloader_pending
  post_logicals_a_bootloader
  activate_a_pending
)
for ((index = 0; index < ${#crash_points[@]}; index += 1)); do
  reset_mock
  crash_point=${crash_points[$index]}
  if run_bundle "$gsi_bundle" MOCK_FAIL_AFTER_MUTATION="$crash_point" \
      >"$scratch_dir/crash-$crash_point.log" 2>&1; then
    printf 'error: injected crash %s unexpectedly completed\n' "$crash_point" >&2
    exit 1
  fi
  [[ $(transaction_state) == "${expected_states[$index]}" ]] || {
    printf 'error: crash %s left state %s, expected %s\n' \
      "$crash_point" "$(transaction_state)" "${expected_states[$index]}" >&2
    exit 1
  }
  resume_bundle "$gsi_bundle"
  assert_completed_transaction "crash-resume-$crash_point"
done

# Strict parsing must reject every malformed, duplicated, contradictory, or
# incomplete namespace before resize/flash/erase. Each row also proves the
# journal can still take the crash-safe stock-restore handoff.
while IFS='|' read -r anomaly first_setting second_setting; do
  settings=("$first_setting")
  [[ -z "$second_setting" ]] || settings+=("$second_setting")
  assert_namespace_rejected_before_write \
    "$anomaly" "$gsi_bundle" "${settings[@]}"
done <<'EOF'
has-slot-mixed|MOCK_LOGICAL_HAS_SLOT_RESPONSE=mixed|
has-slot-duplicate|MOCK_LOGICAL_HAS_SLOT_RESPONSE=duplicate|
has-slot-contradictory|MOCK_LOGICAL_HAS_SLOT_RESPONSE=contradictory|
has-slot-malformed|MOCK_LOGICAL_HAS_SLOT_RESPONSE=malformed|
has-slot-value-failed|MOCK_LOGICAL_HAS_SLOT_RESPONSE=yes_with_failed|
unsuffixed-present|MOCK_LOGICAL_HAS_SLOT_RESPONSE=no|MOCK_UNSUFFIXED_LOGICAL_RESPONSE=present
unsuffixed-explicit-no|MOCK_LOGICAL_HAS_SLOT_RESPONSE=no|MOCK_UNSUFFIXED_LOGICAL_RESPONSE=no
a-explicit-no|MOCK_LOGICAL_PRESENT_RESPONSE=no|
a-duplicate|MOCK_LOGICAL_PRESENT_RESPONSE=duplicate|
a-contradictory|MOCK_LOGICAL_PRESENT_RESPONSE=contradictory|
a-malformed|MOCK_LOGICAL_PRESENT_RESPONSE=malformed|
a-value-failed|MOCK_LOGICAL_PRESENT_RESPONSE=yes_with_failed|
b-explicit-no|MOCK_LOGICAL_HAS_SLOT_RESPONSE=yes|MOCK_ABSENT_LOGICAL_RESPONSE=no
b-generic-failure|MOCK_LOGICAL_HAS_SLOT_RESPONSE=yes|MOCK_ABSENT_LOGICAL_RESPONSE=generic
b-duplicate-failure|MOCK_LOGICAL_HAS_SLOT_RESPONSE=yes|MOCK_ABSENT_LOGICAL_RESPONSE=duplicate
b-value-failed|MOCK_LOGICAL_HAS_SLOT_RESPONSE=yes|MOCK_ABSENT_LOGICAL_RESPONSE=value_with_failed
b-empty-response|MOCK_LOGICAL_HAS_SLOT_RESPONSE=yes|MOCK_ABSENT_LOGICAL_RESPONSE=empty
b-impossible-status|MOCK_LOGICAL_HAS_SLOT_RESPONSE=yes|MOCK_ABSENT_LOGICAL_EXIT_STATUS=2
size-duplicate|MOCK_LOGICAL_SIZE_RESPONSE=duplicate|
size-contradictory|MOCK_LOGICAL_SIZE_RESPONSE=contradictory|
size-malformed|MOCK_LOGICAL_SIZE_RESPONSE=malformed|
size-unprefixed|MOCK_LOGICAL_SIZE_RESPONSE=unprefixed|
size-value-failed|MOCK_LOGICAL_SIZE_RESPONSE=value_with_failed|
size-nonzero-status|MOCK_LOGICAL_SIZE_RESPONSE=nonzero_status|
namespace-mixed|MOCK_NAMESPACE_MODE=mixed|
namespace-incomplete|MOCK_NAMESPACE_MODE=incomplete|
namespace-both-present|MOCK_NAMESPACE_MODE=both_present|
namespace-both-absent|MOCK_NAMESPACE_MODE=both_absent|
EOF

# Abort is durable from bootloader and fastbootd. A crash after the
# fastbootd->bootloader ACK leaves a resumable abort journal, never deletion.
reset_mock
if run_bundle "$gsi_bundle" MOCK_FAIL_AFTER_MUTATION=1 >/dev/null 2>&1; then
  printf 'error: bootloader abort fixture did not crash\n' >&2
  exit 1
fi
abort_bundle "$gsi_bundle"
[[ $(transaction_state) == aborted_for_restore && \
   -f "$scratch_dir/recovery/flash-handoff" && \
   -f "$scratch_dir/recovery/lifeboat-lineage" ]] || {
  printf 'error: bootloader abort did not preserve terminal restore evidence\n' >&2
  exit 1
}
if resume_bundle "$gsi_bundle" >/dev/null 2>&1; then
  printf 'error: terminal restore handoff resumed development flashing\n' >&2
  exit 1
fi

reset_mock
if run_bundle "$gsi_bundle" MOCK_FAIL_AFTER_MUTATION=2 >/dev/null 2>&1; then
  printf 'error: fastbootd abort fixture did not crash\n' >&2
  exit 1
fi
if abort_bundle "$gsi_bundle" MOCK_FAIL_AFTER_MUTATION=3 >/dev/null 2>&1; then
  printf 'error: abort-return crash fixture unexpectedly completed\n' >&2
  exit 1
fi
[[ $(transaction_state) == abort_return_bootloader_pending && \
   $(sed -n '1p' "$scratch_dir/state/mode") == bootloader ]] || {
  printf 'error: abort-return ACK was not crash-resumable\n' >&2
  exit 1
}
abort_bundle "$gsi_bundle"
[[ $(transaction_state) == aborted_for_restore ]] || {
  printf 'error: abort-return journal did not reach terminal restore state\n' >&2
  exit 1
}

# Stale slot-successful A is insufficient without runtime v2. A valid marker
# binds the awaiting-runtime transaction SHA and retires all five evidence
# files through the v2 retirement journal.
reset_mock
run_bundle "$gsi_bundle" MOCK_PRESERVE_SLOT_A_SUCCESSFUL=1
: >"$scratch_dir/mutations.log"
if finalize_bundle "$gsi_bundle" MOCK_PRESERVE_SLOT_A_SUCCESSFUL=1 \
    >"$scratch_dir/no-runtime.log" 2>&1; then
  printf 'error: stale successful A retired evidence without runtime proof\n' >&2
  exit 1
fi
[[ ! -s "$scratch_dir/mutations.log" && \
   $(transaction_state) == awaiting_runtime ]] || {
  printf 'error: rejected runtime finalization mutated or lost evidence\n' >&2
  exit 1
}
make_runtime_boot_attestation "$gsi_bundle"
finalize_bundle "$gsi_bundle" MOCK_PRESERVE_SLOT_A_SUCCESSFUL=1
[[ ! -e "$scratch_dir/recovery/lifeboat-lineage" && \
   ! -e "$scratch_dir/recovery/flash-handoff" && \
   ! -e "$scratch_dir/recovery/runtime-boot-attestation" && \
   ! -e "$scratch_dir/recovery/slot-a-flash-transaction" && \
   ! -e "$scratch_dir/recovery/flash-retirement-transaction" && \
   $(find "$scratch_dir/recovery/consumed" -mindepth 1 -maxdepth 1 \
       -type d -name 'flash-*' | wc -l) -eq 1 ]] || {
  printf 'error: runtime v2 finalization did not retire five-file evidence\n' >&2
  exit 1
}
: >"$scratch_dir/mutations.log"
if finalize_bundle "$gsi_bundle" >"$scratch_dir/historical.log" 2>&1; then
  printf 'error: historical archive was reused as current authority\n' >&2
  exit 1
fi
grep -Fq 'no active flash authority remains' "$scratch_dir/historical.log" || {
  printf 'error: historical retirement rejection was not explicit\n' >&2
  exit 1
}
[[ ! -s "$scratch_dir/mutations.log" ]] || {
  printf 'error: historical retirement rejection mutated the device\n' >&2
  exit 1
}

# Crash after archive publication and one unlink: the active v2 journal alone
# reconciles hash-identical evidence, including the slot-A transaction.
reset_mock
run_bundle "$gsi_bundle"
printf 'yes\n' >"$scratch_dir/state/slot_a_successful"
make_runtime_boot_attestation "$gsi_bundle"
make_flash_retirement_journal "$gsi_bundle"
publish_mock_flash_retirement_archive
rm -f -- "$scratch_dir/recovery/lifeboat-lineage"
: >"$scratch_dir/mutations.log"
finalize_bundle "$gsi_bundle"
[[ ! -e "$scratch_dir/recovery/flash-retirement-transaction" && \
   ! -e "$scratch_dir/recovery/slot-a-flash-transaction" && \
   ! -e "$scratch_dir/recovery/flash-handoff" && \
   ! -e "$scratch_dir/recovery/runtime-boot-attestation" && \
   ! -s "$scratch_dir/mutations.log" ]] || {
  printf 'error: partial five-file retirement did not reconcile\n' >&2
  exit 1
}

# Awaiting-runtime may exceed the development replay window, but exact current
# A runtime proof still permits final retirement.
reset_mock
run_bundle "$gsi_bundle"
age_claim_and_rebind_transaction
printf 'yes\n' >"$scratch_dir/state/slot_a_successful"
make_runtime_boot_attestation "$gsi_bundle"
finalize_bundle "$gsi_bundle"
[[ ! -e "$scratch_dir/recovery/slot-a-flash-transaction" ]] || {
  printf 'error: exact old awaiting-runtime transaction did not finalize\n' >&2
  exit 1
}

# The complete cubs bundle uses the same logical-first transaction and flashes
# every physical A payload only after returning from A fastbootd.
reset_mock
run_bundle "$cubs_bundle"
assert_completed_transaction cubs
for partition in "${firmware_partitions[@]}" \
    boot init_boot dtbo vendor_boot vendor_kernel_boot pvmfw \
    vbmeta_system vbmeta_vendor vbmeta; do
  grep -Fxq "flash ${partition}_a" "$scratch_dir/mutations.log" || {
    printf 'error: cubs transaction omitted physical A payload: %s\n' \
      "$partition" >&2
    exit 1
  }
done
for partition in "${logical_partitions[@]}"; do
  grep -Fxq "resize ${partition}_a 0" "$scratch_dir/mutations.log" || {
    printf 'error: cubs transaction omitted logical resize: %s\n' \
      "$partition" >&2
    exit 1
  }
  grep -Fxq "flash ${partition}_a" "$scratch_dir/mutations.log" || {
    printf 'error: cubs transaction omitted logical flash: %s\n' \
      "$partition" >&2
    exit 1
  }
done
assert_no_forbidden_mutations

assert_no_forbidden_mutations

# Direct physical-B lineage permits a readable B successful=no flag. The same
# flag was rejected above for stock-B-anchor/full-OTA authority.
reset_mock
make_recovery_handoff physical_b_lifeboat direct_factory_physical_b
printf 'no\n' >"$scratch_dir/state/slot_b_successful"
run_bundle "$gsi_bundle"
assert_completed_transaction direct-physical-b

# More than 24 hours revokes development replay but still permits the explicit
# crash-safe handoff to stock restore.
reset_mock
if run_bundle "$gsi_bundle" MOCK_FAIL_AFTER_MUTATION=1 >/dev/null 2>&1; then
  printf 'error: expiry fixture did not crash\n' >&2
  exit 1
fi
age_claim_and_rebind_transaction
if resume_bundle "$gsi_bundle" >"$scratch_dir/expired-resume.log" 2>&1; then
  printf 'error: expired development transaction resumed\n' >&2
  exit 1
fi
grep -Fq 'flash-resume window expired' "$scratch_dir/expired-resume.log" || {
  printf 'error: expired resume did not report its exact blocker\n' >&2
  exit 1
}
abort_bundle "$gsi_bundle"
[[ $(transaction_state) == aborted_for_restore ]] || {
  printf 'error: expired development transaction could not hand off to restore\n' >&2
  exit 1
}

printf 'A-origin namespace, phase replay, abort, runtime-v2, and retirement-v2 flash simulations passed\n'
