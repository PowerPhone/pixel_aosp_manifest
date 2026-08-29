#!/usr/bin/env bash
set -euo pipefail

# This file is copied into each locally generated image bundle as flash-all.sh.
# It is intentionally standalone: the bundle can be moved without carrying the
# source checkout or any proprietary extraction tree with it.

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

require_command() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || \
      die "required command not found: $command_name"
  done
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$script_dir/bundle-kind" ]]; then
  default_bundle_dir=$script_dir
  project_candidate=$(realpath -m -- "$script_dir/../..")
else
  default_bundle_dir=
  project_candidate=$(realpath -m -- "$script_dir/..")
fi

if (( $# > 1 )); then
  die "usage: $0 [BUNDLE_DIRECTORY]"
fi
bundle_dir=${1:-$default_bundle_dir}
[[ -n "$bundle_dir" ]] || \
  die "pass a generated GSI or cubs bundle directory"
bundle_dir=$(realpath -e -- "$bundle_dir")
[[ -d "$bundle_dir" ]] || die "bundle directory not found: $bundle_dir"

require_command awk chmod cmp cp date find flock grep mkdir mktemp mv od openssl \
  realpath rm sed sha256sum sleep sort stat tail tr

expected_fastboot_version=37.0.1
expected_fastboot_sha256=a686e2c7e8dc9cf4cba0cb8a2eef05f7b2bd682c925abd032fe203215d80b618
expected_recovery_policy_sha256=4b6a1e6b772d7a1dcb5d6ad9eec27c626e697ae582e610922e874b2120cad193
expected_factory_sha256=a529c4361135624068e07d06c01bdfb1d4016e0510ae5a3b5bab03832674cf12
expected_full_ota_sha256=4834ee9d9e3ef1cff9805922d6671b6056cf0bc6952060fb31c7a49fedf3c5ca
expected_stock_fingerprint_sha256=9248b7cbc423d1f7fd6b9c244da98eb831e986142a66e82d480daedb36a5ba68
expected_ab_ota_partitions_sha256=7da4e2833f9451e032f61fec9ab2f1d24a6d61c41a2c7079e8cd4df2f248c6a6
expected_shared_super_layout_sha256=1ec66e6b6dac725130c48414364b0ed6911118521f93936fc052429e33ade795
expected_physical_b_source_manifest_sha256=6ea5aedf6a520b2086a1e65392b17590f6f233c524fa375949eddd817cd487da
expected_physical_b_vendor_boot_fetch_sha256=0e7cd320bbd2f24f64723e170d87d09a3e648babf835a17433ea66e00190bf0f
handoff_ready_seconds=3600
handoff_resume_seconds=86400
resume_confirmation=RESUME_EXACT_CUBS_A_TRANSACTION_USING_PHYSICAL_B_LIFEBOAT
finalize_confirmation=FINALIZE_EXACT_CUBS_A_TRANSACTION_AFTER_SUCCESSFUL_ANDROID_BOOT
abort_confirmation=ABORT_EXACT_CUBS_A_TRANSACTION_FOR_STOCK_RESTORE

require_file_in_bundle() {
  local name=$1
  [[ "$name" != */* && "$name" != .* ]] || \
    die "invalid bundle filename: $name"
  [[ -f "$bundle_dir/$name" && ! -L "$bundle_dir/$name" ]] || \
    die "required regular file not found in bundle: $name"
}

require_file_in_bundle bundle-kind
bundle_kind=$(<"$bundle_dir/bundle-kind")
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
firmware_image_files=()
for partition in "${firmware_partitions[@]}"; do
  firmware_image_files+=("$partition.img")
done
cubs_early_physical_partitions=(
  "${firmware_partitions[@]}"
  boot
  init_boot
  dtbo
  vendor_boot
  vendor_kernel_boot
  pvmfw
)
cubs_vbmeta_partitions=(vbmeta_system vbmeta_vendor vbmeta)
preserved_b_physical_partitions=(
  "${cubs_early_physical_partitions[@]}"
  "${cubs_vbmeta_partitions[@]}"
)
all_logical_partitions=(
  system system_dlkm system_ext product vendor vendor_dlkm
)
case "$bundle_kind" in
  gsi)
    image_files=(system.img pvmfw.img vbmeta.img)
    logical_partitions=(system)
    ;;
  cubs)
    image_files=(
      "${firmware_image_files[@]}"
      boot.img
      init_boot.img
      dtbo.img
      vendor_boot.img
      vendor_kernel_boot.img
      pvmfw.img
      vbmeta.img
      vbmeta_system.img
      vbmeta_vendor.img
      system.img
      system_dlkm.img
      system_ext.img
      product.img
      vendor.img
      vendor_dlkm.img
    )
    logical_partitions=("${all_logical_partitions[@]}")
    ;;
  *) die "unsupported bundle kind: $bundle_kind" ;;
esac

manifest_files=(
  bundle-kind
  BUNDLE_INFO.txt
  BUILD_ATTESTATION.txt
  firmware-requirements.txt
  flash-all.sh
  "${image_files[@]}"
)
require_file_in_bundle SHA256SUMS
for name in "${manifest_files[@]}"; do
  require_file_in_bundle "$name"
done
[[ -x "$bundle_dir/flash-all.sh" ]] || \
  die "bundle flash-all.sh is not executable"

expected_bundle_entries=(SHA256SUMS "${manifest_files[@]}")
mapfile -d '' -t actual_bundle_entries < <(
  find "$bundle_dir" -mindepth 1 -maxdepth 1 -printf '%f\0' | LC_ALL=C sort -z
)
mapfile -t expected_bundle_entries_sorted < <(
  printf '%s\n' "${expected_bundle_entries[@]}" | LC_ALL=C sort
)
(( ${#actual_bundle_entries[@]} == ${#expected_bundle_entries_sorted[@]} )) || \
  die "bundle directory does not match the exact reviewed file allowlist"
for ((entry_index = 0;
      entry_index < ${#expected_bundle_entries_sorted[@]};
      entry_index += 1)); do
  [[ "${actual_bundle_entries[$entry_index]}" == \
     "${expected_bundle_entries_sorted[$entry_index]}" ]] || \
    die "bundle directory does not match the exact reviewed file allowlist"
done

declare -A expected_files=()
for name in "${manifest_files[@]}"; do
  expected_files["$name"]=1
done

declare -A seen_files=()
manifest_count=0
while read -r digest name extra; do
  [[ -n "$digest" && -n "$name" && -z "${extra:-}" ]] || \
    die "malformed SHA256SUMS entry"
  name=${name#\*}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || \
    die "malformed SHA-256 digest for $name"
  [[ -n "${expected_files[$name]+present}" ]] || \
    die "unexpected file in SHA256SUMS: $name"
  [[ -z "${seen_files[$name]+present}" ]] || \
    die "duplicate file in SHA256SUMS: $name"
  seen_files["$name"]=1
  ((manifest_count += 1))
done < "$bundle_dir/SHA256SUMS"

(( manifest_count == ${#manifest_files[@]} )) || \
  die "SHA256SUMS does not cover the exact bundle allowlist"
for name in "${manifest_files[@]}"; do
  [[ -n "${seen_files[$name]+present}" ]] || \
    die "SHA256SUMS is missing $name"
done
(
  cd "$bundle_dir"
  sha256sum --check --strict SHA256SUMS
) || die "bundle checksum verification failed"
bundle_manifest_sha256=$(sha256sum "$bundle_dir/SHA256SUMS")
bundle_manifest_sha256=${bundle_manifest_sha256%% *}
[[ "$bundle_manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || \
  die "unable to bind the bundle checksum manifest"

logical_targets_sha256=$(
  printf '%s\n' "${logical_partitions[@]}" | sha256sum | awk '{print $1}'
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

logical_image_size_lines=
declare -A expected_logical_sizes=()
for partition in "${logical_partitions[@]}"; do
  logical_image_size=$(logical_image_expanded_size \
    "$bundle_dir/$partition.img")
  expected_logical_sizes["$partition"]=$(printf '%x' "$logical_image_size")
  logical_image_size_lines+="$partition=$logical_image_size"$'\n'
done
logical_image_sizes_sha256=$(
  printf '%s' "$logical_image_size_lines" | sha256sum | awk '{print $1}'
)

recorded_attestation_sha256=$(
  sed -n 's/^build_attestation_sha256=//p' "$bundle_dir/BUNDLE_INFO.txt"
)
[[ $(grep -c '^build_attestation_sha256=' "$bundle_dir/BUNDLE_INFO.txt") -eq 1 ]] || \
  die "bundle must record exactly one build-attestation digest"
[[ "$recorded_attestation_sha256" =~ ^[0-9a-f]{64}$ ]] || \
  die "bundle records an invalid build-attestation digest"
actual_attestation_sha256=$(sha256sum "$bundle_dir/BUILD_ATTESTATION.txt")
actual_attestation_sha256=${actual_attestation_sha256%% *}
[[ "$actual_attestation_sha256" == "$recorded_attestation_sha256" ]] || \
  die "BUILD_ATTESTATION.txt does not match BUNDLE_INFO.txt"
attested_kind=$(sed -n 's/^kind=//p' "$bundle_dir/BUILD_ATTESTATION.txt")
[[ $(grep -c '^kind=' "$bundle_dir/BUILD_ATTESTATION.txt") -eq 1 && \
   "$attested_kind" == "$bundle_kind" ]] || \
  die "build attestation does not match the bundle kind"
[[ $(grep -c '^build_variant=userdebug$' \
      "$bundle_dir/BUILD_ATTESTATION.txt") -eq 1 ]] || \
  die "build attestation is not for exactly one userdebug build"
for provenance_key in \
  source_aosp_build_id output_build_id framework_security_patch; do
  [[ $(grep -c "^${provenance_key}=" "$bundle_dir/BUNDLE_INFO.txt") -eq 1 && \
     $(grep -c "^${provenance_key}=" \
       "$bundle_dir/BUILD_ATTESTATION.txt") -eq 1 ]] || \
    die "bundle provenance field is missing or duplicated: $provenance_key"
  bundle_provenance_value=$(
    sed -n "s/^${provenance_key}=//p" "$bundle_dir/BUNDLE_INFO.txt"
  )
  attested_provenance_value=$(
    sed -n "s/^${provenance_key}=//p" \
      "$bundle_dir/BUILD_ATTESTATION.txt"
  )
  [[ -n "$bundle_provenance_value" && \
     "$bundle_provenance_value" == "$attested_provenance_value" ]] || \
    die "bundle provenance disagrees with its build attestation: $provenance_key"
done

bundle_flash_scope=$(sed -n 's/^flash_scope=//p' "$bundle_dir/BUNDLE_INFO.txt")
bundle_recovery_anchor=$(
  sed -n 's/^recovery_anchor=//p' "$bundle_dir/BUNDLE_INFO.txt"
)
bundle_stock_build=$(sed -n 's/^stock_vendor_build=//p' "$bundle_dir/BUNDLE_INFO.txt")
bundle_output_build_id=$(sed -n 's/^output_build_id=//p' "$bundle_dir/BUNDLE_INFO.txt")
bundle_framework_security_patch=$(
  sed -n 's/^framework_security_patch=//p' "$bundle_dir/BUNDLE_INFO.txt"
)
[[ $(grep -c '^flash_scope=' "$bundle_dir/BUNDLE_INFO.txt") -eq 1 && \
   "$bundle_flash_scope" == slot_a_partition_names_shared_super ]] || \
  die "bundle does not disclose the shared-super slot-A flash scope"
[[ $(grep -c '^recovery_anchor=' "$bundle_dir/BUNDLE_INFO.txt") -eq 1 && \
   "$bundle_recovery_anchor" == slot_b_physical_fastbootd_lifeboat ]] || \
  die "bundle does not identify the physical slot-B fastbootd lifeboat"
[[ $(grep -c '^stock_vendor_build=' "$bundle_dir/BUNDLE_INFO.txt") -eq 1 && \
   "$bundle_stock_build" == CD1A.260714.001.A9 ]] || \
  die "bundle does not identify the exact stock recovery baseline"
[[ $(grep -c '^output_build_id=' "$bundle_dir/BUNDLE_INFO.txt") -eq 1 && \
   -n "$bundle_output_build_id" ]] || \
  die "bundle does not identify exactly one output build ID"
[[ $(grep -c '^framework_security_patch=' \
      "$bundle_dir/BUNDLE_INFO.txt") -eq 1 && \
   "$bundle_framework_security_patch" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || \
  die "bundle does not identify exactly one framework security patch"

requirements_file="$bundle_dir/firmware-requirements.txt"
expected_product=$(sed -n 's/^require product=//p' "$requirements_file")
expected_bootloader=$(sed -n 's/^require version-bootloader=//p' "$requirements_file")
expected_baseband=$(sed -n 's/^require version-baseband=//p' "$requirements_file")
[[ "$expected_product" == cubs ]] || \
  die "bundle firmware requirements do not identify cubs"
[[ -n "$expected_bootloader" ]] || \
  die "bundle has no pinned bootloader requirement"
[[ -n "$expected_baseband" ]] || \
  die "bundle has no pinned baseband requirement"
[[ $(grep -c '^require product=' "$requirements_file") -eq 1 ]] || \
  die "bundle must contain exactly one product requirement"
[[ $(grep -c '^require version-bootloader=' "$requirements_file") -eq 1 ]] || \
  die "bundle must contain exactly one bootloader requirement"
[[ $(grep -c '^require version-baseband=' "$requirements_file") -eq 1 ]] || \
  die "bundle must contain exactly one baseband requirement"

[[ "${CUBS_ALLOW_DATA_WIPE:-}" == 1 ]] || die \
  "flashing erases userdata and metadata; set CUBS_ALLOW_DATA_WIPE=1"
expected_confirmation=FLASH_CUBS_A_SHARED_SUPER_INVALIDATES_B_ANDROID
[[ "${CUBS_FLASH_CONFIRM:-}" == "$expected_confirmation" ]] || die \
  "set CUBS_FLASH_CONFIRM=$expected_confirmation only after accepting that slot-B Android will no longer be a fallback"
if [[ "$bundle_kind" == gsi ]]; then
  [[ "${CUBS_GSI_STOCK_A_BASELINE_CONFIRMED:-}" == 1 ]] || die \
    "the GSI reuses stock slot-A kernel/vendor views; set CUBS_GSI_STOCK_A_BASELINE_CONFIRMED=1 only after proving that baseline"
fi

[[ -z "${CUBS_FLASH_RESUME_CONFIRM:-}" || \
   "${CUBS_FLASH_RESUME_CONFIRM:-}" == "$resume_confirmation" ]] || \
  die "CUBS_FLASH_RESUME_CONFIRM has an invalid value"
[[ -z "${CUBS_FLASH_FINALIZE_CONFIRM:-}" || \
   "${CUBS_FLASH_FINALIZE_CONFIRM:-}" == "$finalize_confirmation" ]] || \
  die "CUBS_FLASH_FINALIZE_CONFIRM has an invalid value"
[[ -z "${CUBS_FLASH_ABORT_CONFIRM:-}" || \
   "${CUBS_FLASH_ABORT_CONFIRM:-}" == "$abort_confirmation" ]] || \
  die "CUBS_FLASH_ABORT_CONFIRM has an invalid value"
transaction_action_count=0
[[ -n "${CUBS_FLASH_RESUME_CONFIRM:-}" ]] && \
  ((transaction_action_count += 1))
[[ -n "${CUBS_FLASH_FINALIZE_CONFIRM:-}" ]] && \
  ((transaction_action_count += 1))
[[ -n "${CUBS_FLASH_ABORT_CONFIRM:-}" ]] && \
  ((transaction_action_count += 1))
(( transaction_action_count <= 1 )) || \
  die "select only one slot-A resume, finalize, or stock-restore abort action"

if [[ -n "${CUBS_FASTBOOT_SERIAL:-}" && -n "${ANDROID_SERIAL:-}" && \
      "$CUBS_FASTBOOT_SERIAL" != "$ANDROID_SERIAL" ]]; then
  die "CUBS_FASTBOOT_SERIAL and ANDROID_SERIAL select different devices"
fi
device_serial=${CUBS_FASTBOOT_SERIAL:-${ANDROID_SERIAL:-}}
[[ -n "$device_serial" ]] || die \
  "select the phone explicitly with CUBS_FASTBOOT_SERIAL"
[[ "$device_serial" != -* && ! "$device_serial" =~ [[:space:]] ]] || \
  die "invalid fastboot serial"

if [[ -n "${FASTBOOT:-}" ]]; then
  [[ "$FASTBOOT" == /* ]] || die "FASTBOOT must be an absolute path"
  fastboot_bin=$FASTBOOT
elif [[ -f "$project_candidate/config/release.env" && \
        -f "$project_candidate/config/recovery.env" && \
        -x "$project_candidate/work/toolchains/platform-tools/fastboot" ]]; then
  fastboot_bin="$project_candidate/work/toolchains/platform-tools/fastboot"
else
  require_command fastboot
  fastboot_bin=$(command -v fastboot)
fi
[[ -f "$fastboot_bin" && ! -L "$fastboot_bin" && -x "$fastboot_bin" ]] || \
  die "fastboot is not a safe executable: $fastboot_bin"
fastboot_bin=$(realpath -e -- "$fastboot_bin")
fastboot_sha256=$(sha256sum "$fastboot_bin")
fastboot_sha256=${fastboot_sha256%% *}
[[ "$fastboot_sha256" == "$expected_fastboot_sha256" ]] || \
  die "fastboot does not match the pinned Platform-Tools binary digest"
fastboot_version_output=$("$fastboot_bin" --version 2>&1)
if [[ "$fastboot_version_output" =~ fastboot[[:space:]]version[[:space:]]([0-9]+(\.[0-9]+)*) ]]; then
  fastboot_version=${BASH_REMATCH[1]}
else
  die "unable to determine fastboot version"
fi
[[ "$fastboot_version" == "$expected_fastboot_version" ]] || die \
  "this release is pinned to fastboot $expected_fastboot_version; found $fastboot_version"

mapfile -t attached_devices < <("$fastboot_bin" devices | awk 'NF {print $1}')
(( ${#attached_devices[@]} == 1 )) || \
  die "expected exactly one fastboot device; found ${#attached_devices[@]}"
[[ "${attached_devices[0]}" == "$device_serial" ]] || \
  die "the explicitly selected fastboot device is not the sole attached device"
fastboot_command=("$fastboot_bin" -s "$device_serial")

fastboot_value() {
  local variable=$1
  local output
  output=$("${fastboot_command[@]}" getvar "$variable" 2>&1) || true
  sed -nE \
    "s/^(\(bootloader\)[[:space:]]*)?$variable:[[:space:]]*//p" \
    <<<"$output" | tail -n 1
}

load_exact_kv() {
  local path=$1 destination_name=$2
  shift 2
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
      die "malformed private recovery state"
    [[ -n "${expected[$key]+present}" ]] || \
      die "unknown key in private recovery state: $key"
    [[ -z "${destination[$key]+present}" ]] || \
      die "duplicate key in private recovery state: $key"
    destination["$key"]=$value
    ((count += 1))
  done <"$path"
  (( count == expected_count )) || \
    die "private recovery state does not match its exact schema"
  for allowed in "$@"; do
    [[ -n "${destination[$allowed]+present}" ]] || \
      die "private recovery state omits $allowed"
  done
}

require_private_recovery_file() {
  local path=$1 mode owner links
  [[ -f "$path" && ! -L "$path" ]] || \
    die "private recovery state is missing or unsafe"
  mode=$(stat -c '%a' "$path")
  owner=$(stat -c '%u' "$path")
  links=$(stat -c '%h' "$path")
  [[ "$mode" == 600 && "$owner" == "$EUID" && "$links" == 1 ]] || \
    die "private recovery state has unsafe ownership, mode, or link count"
}

require_private_recovery_dir() {
  local path=$1 mode owner
  [[ -d "$path" && ! -L "$path" ]] || \
    die "private recovery directory is missing or unsafe"
  mode=$(stat -c '%a' "$path")
  owner=$(stat -c '%u' "$path")
  [[ "$mode" == 700 && "$owner" == "$EUID" ]] || \
    die "private recovery directory has unsafe ownership or mode"
}

serial_binding() {
  local anchor_id=$1 serial=$2 digest
  digest=$(printf '%s\0%s' "$anchor_id" "$serial" | sha256sum)
  digest=${digest%% *}
  printf '%s\n' "$digest"
}

normalize_partition_size() {
  local value=${1,,}
  [[ "$value" =~ ^(0x)?[0-9a-f]+$ && "$value" =~ [1-9a-f] ]] || \
    die "invalid or zero physical partition size"
  value=${value#0x}
  while [[ ${#value} -gt 1 && ${value:0:1} == 0 ]]; do
    value=${value:1}
  done
  printf '%s\n' "$value"
}

physical_b_sizes_sha256() {
  local partition size digest lines=
  for partition in "${preserved_b_physical_partitions[@]}"; do
    size=$(normalize_partition_size \
      "$(fastboot_value "partition-size:${partition}_b")")
    lines+="${partition}_b=${size}"$'\n'
  done
  digest=$(printf '%s' "$lines" | sha256sum)
  printf '%s\n' "${digest%% *}"
}

verify_live_vendor_boot_control() {
  local slot=$1 actual_sha fetched fetched_size_hex partition target_size
  [[ "$slot" =~ ^(a|b)$ ]] || die "invalid vendor_boot control slot"
  partition="vendor_boot_$slot"

  fetched=$(mktemp "$recovery_state_dir/.vendor-boot-${slot}-fetch.XXXXXX")
  rm -f -- "$fetched"
  if ! "${fastboot_command[@]}" fetch "$partition" "$fetched"; then
    rm -f -- "$fetched"
    die "unable to fetch the complete live $partition recovery partition"
  fi
  [[ -f "$fetched" && ! -L "$fetched" && \
     $(stat -c '%u' "$fetched") == "$EUID" && \
     $(stat -c '%h' "$fetched") == 1 ]] || {
    rm -f -- "$fetched"
    die "live $partition fetch is unsafe"
  }
  target_size=$(normalize_partition_size \
    "$(fastboot_value "partition-size:$partition")")
  fetched_size_hex=$(printf '%x' "$(stat -c '%s' "$fetched")")
  [[ "$fetched_size_hex" == "$target_size" ]] || {
    rm -f -- "$fetched"
    die "live $partition fetch does not cover its full physical partition"
  }
  actual_sha=$(sha256sum "$fetched")
  actual_sha=${actual_sha%% *}
  rm -f -- "$fetched"
  [[ "$actual_sha" == "$expected_physical_b_vendor_boot_fetch_sha256" ]] || \
    die "live $partition bytes differ from the exact stock vendor_boot pin"
}

verify_live_vendor_boot_b_control() {
  verify_live_vendor_boot_control b
}

verify_live_vendor_boot_a_control() {
  verify_live_vendor_boot_control a
}

declare -A recovery_handoff=()
declare -A recovery_lineage=()
declare -A slot_a_flash_transaction=()
handoff_claimed=
handoff_consumed=
retirement_completed=
retirement_in_progress=
slot_a_flash_transaction_present=
slot_a_flash_transaction_state=
loaded_slot_a_flash_transaction_sha256=

initialize_recovery_handoff() {
  local requested parent mode owner canonical now created expires claimed
  local current_slot pending_direct_path
  local lineage_actual serial_actual state

  if [[ -n "${CUBS_RECOVERY_HANDOFF:-}" ]]; then
    [[ "$CUBS_RECOVERY_HANDOFF" == /* ]] || \
      die "CUBS_RECOVERY_HANDOFF must be an absolute path"
    requested=$CUBS_RECOVERY_HANDOFF
  else
    [[ -f "$project_candidate/config/release.env" && \
       -f "$project_candidate/config/recovery.env" && \
       -x "$project_candidate/scripts/prepare-recovery-anchor.sh" ]] || \
      die "set CUBS_RECOVERY_HANDOFF to the private handoff created by the recovery workflow"
    requested="$project_candidate/.cache/recovery-anchor/flash-handoff"
  fi
  [[ ! -L "$requested" ]] || die "recovery handoff must not be a symbolic link"
  canonical=$(realpath -m -- "$requested")
  [[ "$canonical" == "$requested" ]] || \
    die "recovery handoff path must already be canonical"
  recovery_handoff_path=$canonical
  recovery_state_dir=$(dirname -- "$recovery_handoff_path")
  runtime_boot_attestation_path="$recovery_state_dir/runtime-boot-attestation"
  recovery_lineage_path="$recovery_state_dir/lifeboat-lineage"
  retirement_transaction_path="$recovery_state_dir/flash-retirement-transaction"
  slot_a_flash_transaction_path="$recovery_state_dir/slot-a-flash-transaction"
  stock_restore_transaction_path="$recovery_state_dir/stock-restore-transaction"
  stock_b_consumption_transaction_path="$recovery_state_dir/stock-b-consumption-transaction"
  parent=$(realpath -e -- "$recovery_state_dir")
  [[ "$parent" == "$recovery_state_dir" && ! -L "$recovery_state_dir" ]] || \
    die "recovery state directory is unsafe"
  mode=$(stat -c '%a' "$recovery_state_dir")
  owner=$(stat -c '%u' "$recovery_state_dir")
  [[ "$mode" == 700 && "$owner" == "$EUID" ]] || \
    die "recovery state directory must be private to the current user"
  [[ ! -L "$recovery_state_dir/lock" ]] || \
    die "recovery-state lock must not be a symbolic link"
  exec {recovery_lock_fd}>"$recovery_state_dir/lock"
  chmod 0600 "$recovery_state_dir/lock"
  [[ -f "$recovery_state_dir/lock" && ! -L "$recovery_state_dir/lock" ]] || \
    die "recovery-state lock is unsafe"
  flock -n "$recovery_lock_fd" || die "another recovery or flash transaction is active"
  [[ ! -e "$stock_restore_transaction_path" && \
     ! -L "$stock_restore_transaction_path" ]] || \
    die "an active stock-restore transaction blocks development flashing"
  [[ ! -e "$stock_b_consumption_transaction_path" && \
     ! -L "$stock_b_consumption_transaction_path" ]] || \
    die "finish the direct-lifeboat resume-finalize consumption transaction before flashing"
  if [[ -e "$slot_a_flash_transaction_path" || \
        -L "$slot_a_flash_transaction_path" ]]; then
    slot_a_flash_transaction_present=1
  fi
  for pending_direct_path in \
      stock-a-baseline-evidence stock-a-physical-b-preflight \
      stock-a-complete-lpdump \
      stock-b-preparation-receipt stock-b-source-payload-manifest \
      stock-b-fastbootd-trial-receipt; do
    [[ ! -e "$recovery_state_dir/$pending_direct_path" && \
       ! -L "$recovery_state_dir/$pending_direct_path" ]] || \
      die "finish the direct-lifeboat resume-finalize workflow before flashing"
  done

  if [[ -e "$retirement_transaction_path" || \
        -L "$retirement_transaction_path" ]]; then
    retirement_in_progress=1
    finish_pending_flash_retirement
    retirement_completed=1
    return
  fi
  if [[ ! -e "$recovery_handoff_path" && \
        ! -L "$recovery_handoff_path" && \
        ! -e "$recovery_lineage_path" && \
        ! -L "$recovery_lineage_path" && \
        ! -e "$runtime_boot_attestation_path" && \
        ! -L "$runtime_boot_attestation_path" && \
        ! -e "$slot_a_flash_transaction_path" && \
        ! -L "$slot_a_flash_transaction_path" ]] && \
      detect_completed_flash_retirement; then
    die "no active flash authority remains; an exact historical retirement archive exists but does not attest the current slot-A bytes"
  fi
  require_private_recovery_file "$recovery_handoff_path"
  require_private_recovery_file "$recovery_lineage_path"

  load_exact_kv "$recovery_lineage_path" recovery_lineage \
    schema anchor_id created_epoch serial_binding_sha256 device stock_build_id \
    stock_fingerprint_sha256 factory_sha256 full_ota_sha256 bootloader baseband \
    ab_ota_partitions_sha256 shared_super_layout_sha256 \
    physical_b_sizes_sha256 stock_b_source stock_b_provenance_sha256 \
    physical_b_source_manifest_sha256 physical_b_vendor_boot_fetch_sha256 \
    recovery_policy_sha256
  [[ "${recovery_lineage[schema]}" == cubs-recovery-lineage-v2 && \
     "${recovery_lineage[anchor_id]}" =~ ^[0-9a-f]{32}$ && \
     "${recovery_lineage[created_epoch]}" =~ ^[0-9]+$ && \
     "${recovery_lineage[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${recovery_lineage[device]}" == "$expected_product" && \
     "${recovery_lineage[stock_build_id]}" == "$bundle_stock_build" && \
     "${recovery_lineage[stock_fingerprint_sha256]}" == "$expected_stock_fingerprint_sha256" && \
     "${recovery_lineage[factory_sha256]}" == "$expected_factory_sha256" && \
     "${recovery_lineage[full_ota_sha256]}" == "$expected_full_ota_sha256" && \
     "${recovery_lineage[bootloader]}" == "$expected_bootloader" && \
     "${recovery_lineage[baseband]}" == "$expected_baseband" && \
     "${recovery_lineage[ab_ota_partitions_sha256]}" == "$expected_ab_ota_partitions_sha256" && \
     "${recovery_lineage[shared_super_layout_sha256]}" == "$expected_shared_super_layout_sha256" && \
     "${recovery_lineage[physical_b_sizes_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${recovery_lineage[recovery_policy_sha256]}" == "$expected_recovery_policy_sha256" ]] || \
    die "recovery lineage does not match this exact cubs release policy"
  case "${recovery_lineage[stock_b_source]}" in
    full_ota)
      [[ "${recovery_lineage[stock_b_provenance_sha256]}" == \
           "$expected_full_ota_sha256" && \
         "${recovery_lineage[physical_b_source_manifest_sha256]}" == none && \
         "${recovery_lineage[physical_b_vendor_boot_fetch_sha256]}" == none ]] || \
        die "full-OTA recovery lineage has invalid source provenance"
      ;;
    direct_factory_physical_b)
      [[ "${recovery_lineage[stock_b_provenance_sha256]}" =~ ^[0-9a-f]{64}$ && \
         "${recovery_lineage[physical_b_source_manifest_sha256]}" == \
           "$expected_physical_b_source_manifest_sha256" && \
         "${recovery_lineage[physical_b_vendor_boot_fetch_sha256]}" == \
           "$expected_physical_b_vendor_boot_fetch_sha256" ]] || \
        die "direct-factory recovery lineage has invalid source provenance"
      ;;
    *) die "unsupported stock-B recovery lineage source" ;;
  esac
  serial_actual=$(serial_binding "${recovery_lineage[anchor_id]}" "$device_serial")
  [[ "$serial_actual" == "${recovery_lineage[serial_binding_sha256]}" ]] || \
    die "recovery lineage belongs to another USB transport"
  lineage_actual=$(sha256sum "$recovery_lineage_path")
  lineage_actual=${lineage_actual%% *}
  loaded_lineage_sha256=$lineage_actual

  load_exact_kv "$recovery_handoff_path" recovery_handoff \
    schema state handoff_kind created_epoch expires_epoch claimed_epoch \
    anchor_id serial_binding_sha256 lineage_sha256 physical_b_sizes_sha256 \
    recovery_policy_sha256 bundle_kind bundle_manifest_sha256
  [[ "${recovery_handoff[schema]}" == cubs-recovery-handoff-v2 && \
     "${recovery_handoff[handoff_kind]}" =~ ^(stock_b_anchor|physical_b_lifeboat)$ && \
     "${recovery_handoff[anchor_id]}" == "${recovery_lineage[anchor_id]}" && \
     "${recovery_handoff[serial_binding_sha256]}" == "$serial_actual" && \
     "${recovery_handoff[lineage_sha256]}" == "$lineage_actual" && \
     "${recovery_handoff[physical_b_sizes_sha256]}" == \
       "${recovery_lineage[physical_b_sizes_sha256]}" && \
     "${recovery_handoff[recovery_policy_sha256]}" == "$expected_recovery_policy_sha256" && \
     "${recovery_handoff[created_epoch]}" =~ ^[0-9]+$ && \
     "${recovery_handoff[expires_epoch]}" =~ ^[0-9]+$ && \
     "${recovery_handoff[claimed_epoch]}" =~ ^[0-9]+$ ]] || \
    die "recovery handoff does not match its private lineage"
  if [[ "${recovery_lineage[stock_b_source]}" == direct_factory_physical_b && \
        "${recovery_handoff[handoff_kind]}" != physical_b_lifeboat ]]; then
    die "direct-factory lineage may authorize only a physical-B lifeboat handoff"
  fi

  now=$(date +%s)
  created=${recovery_handoff[created_epoch]}
  expires=${recovery_handoff[expires_epoch]}
  claimed=${recovery_handoff[claimed_epoch]}
  state=${recovery_handoff[state]}
  [[ "$expires" -eq $((created + handoff_ready_seconds)) ]] || \
    die "recovery handoff has an invalid freshness interval"
  case "$state" in
    ready)
      [[ "$now" -ge "$created" && "$now" -le "$expires" && \
         "$claimed" == 0 && "${recovery_handoff[bundle_kind]}" == none && \
         "${recovery_handoff[bundle_manifest_sha256]}" == none ]] || \
        die "stock-B recovery handoff is stale or malformed"
      ;;
    claimed)
      [[ "$claimed" -ge "$created" && "$claimed" -le "$expires" && \
         "$now" -ge "$claimed" && \
         "${recovery_handoff[bundle_kind]}" == "$bundle_kind" && \
         "${recovery_handoff[bundle_manifest_sha256]}" == "$bundle_manifest_sha256" ]] || \
        die "incomplete flash handoff is malformed or belongs to another bundle"
      if [[ -n "$slot_a_flash_transaction_present" ]]; then
        [[ "${CUBS_FLASH_RESUME_CONFIRM:-}" == "$resume_confirmation" || \
           "${CUBS_FLASH_FINALIZE_CONFIRM:-}" == "$finalize_confirmation" || \
           "${CUBS_FLASH_ABORT_CONFIRM:-}" == "$abort_confirmation" ]] || \
          die "an exact slot-A transaction requires its resume, finalize, or stock-restore abort token"
      else
        current_slot=$(fastboot_value current-slot)
        if [[ "$current_slot" == a ]]; then
          [[ "${CUBS_FLASH_FINALIZE_CONFIRM:-}" == \
               "$finalize_confirmation" ]] || \
            die "exact post-boot finalization is required for a claimed slot-A handoff"
        else
          [[ "$current_slot" == b ]] || \
            die "claimed flash handoff has an unreadable current slot"
          [[ "$now" -le $((claimed + handoff_resume_seconds)) ]] || \
            die "the exact slot-B flash-resume window has expired; restore stock A"
          [[ "${CUBS_FLASH_RESUME_CONFIRM:-}" == "$resume_confirmation" ]] || \
            die "set CUBS_FLASH_RESUME_CONFIRM=$resume_confirmation only to resume this exact incomplete bundle"
        fi
      fi
      handoff_claimed=1
      ;;
    *) die "unsupported recovery handoff state: $state" ;;
  esac
  loaded_handoff_sha256=$(sha256sum "$recovery_handoff_path")
  loaded_handoff_sha256=${loaded_handoff_sha256%% *}
  if [[ -n "$slot_a_flash_transaction_present" ]]; then
    load_slot_a_flash_transaction
  fi
}

slot_a_flash_state_valid() {
  [[ "$1" =~ ^(select_a_bootloader_pending|enter_a_fastbootd_pending|logical_writes_pending|return_a_bootloader_pending|post_logicals_a_bootloader|activate_a_pending|awaiting_runtime|abort_return_bootloader_pending|aborted_for_restore)$ ]]
}

slot_a_flash_transition_valid() {
  case "$1:$2" in
    none:select_a_bootloader_pending|\
    select_a_bootloader_pending:enter_a_fastbootd_pending|\
    enter_a_fastbootd_pending:logical_writes_pending|\
    logical_writes_pending:return_a_bootloader_pending|\
    return_a_bootloader_pending:post_logicals_a_bootloader|\
    post_logicals_a_bootloader:activate_a_pending|\
    activate_a_pending:awaiting_runtime|\
    select_a_bootloader_pending:abort_return_bootloader_pending|\
    enter_a_fastbootd_pending:abort_return_bootloader_pending|\
    logical_writes_pending:abort_return_bootloader_pending|\
    return_a_bootloader_pending:abort_return_bootloader_pending|\
    post_logicals_a_bootloader:abort_return_bootloader_pending|\
    activate_a_pending:abort_return_bootloader_pending|\
    awaiting_runtime:abort_return_bootloader_pending|\
    abort_return_bootloader_pending:aborted_for_restore)
      return 0
      ;;
    *) return 1 ;;
  esac
}

load_slot_a_flash_transaction() {
  local actual_binding actual_sha created now

  require_private_recovery_file "$slot_a_flash_transaction_path"
  load_exact_kv "$slot_a_flash_transaction_path" slot_a_flash_transaction \
    schema state created_epoch transaction_id serial_binding_sha256 device \
    anchor_id lineage_sha256 handoff_sha256 physical_b_sizes_sha256 \
    stock_b_source stock_b_provenance_sha256 bundle_kind \
    bundle_manifest_sha256 logical_targets_sha256 \
    logical_image_sizes_sha256 recovery_policy_sha256
  slot_a_flash_state_valid "${slot_a_flash_transaction[state]}" || \
    die "slot-A flash transaction has an unsupported state"
  [[ "${slot_a_flash_transaction[schema]}" == \
       cubs-slot-a-flash-transaction-v1 && \
     "${slot_a_flash_transaction[created_epoch]}" =~ ^[1-9][0-9]{0,17}$ && \
     "${slot_a_flash_transaction[transaction_id]}" =~ ^[0-9a-f]{32}$ && \
     "${slot_a_flash_transaction[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${slot_a_flash_transaction[device]}" == "$expected_product" && \
     "${slot_a_flash_transaction[anchor_id]}" == \
       "${recovery_lineage[anchor_id]}" && \
     "${slot_a_flash_transaction[lineage_sha256]}" == \
       "$loaded_lineage_sha256" && \
     "${slot_a_flash_transaction[handoff_sha256]}" == \
       "$loaded_handoff_sha256" && \
     "${slot_a_flash_transaction[physical_b_sizes_sha256]}" == \
       "${recovery_handoff[physical_b_sizes_sha256]}" && \
     "${slot_a_flash_transaction[stock_b_source]}" == \
       "${recovery_lineage[stock_b_source]}" && \
     "${slot_a_flash_transaction[stock_b_provenance_sha256]}" == \
       "${recovery_lineage[stock_b_provenance_sha256]}" && \
     "${slot_a_flash_transaction[bundle_kind]}" == "$bundle_kind" && \
     "${slot_a_flash_transaction[bundle_manifest_sha256]}" == \
       "$bundle_manifest_sha256" && \
     "${slot_a_flash_transaction[logical_targets_sha256]}" == \
       "$logical_targets_sha256" && \
     "${slot_a_flash_transaction[logical_image_sizes_sha256]}" == \
       "$logical_image_sizes_sha256" && \
     "${slot_a_flash_transaction[recovery_policy_sha256]}" == \
       "$expected_recovery_policy_sha256" && \
     "${recovery_handoff[state]}" == claimed ]] || \
    die "slot-A flash transaction does not match this exact claimed bundle"
  actual_binding=$(serial_binding \
    "${slot_a_flash_transaction[transaction_id]}" "$device_serial")
  [[ "$actual_binding" == \
       "${slot_a_flash_transaction[serial_binding_sha256]}" ]] || \
    die "slot-A flash transaction belongs to another USB transport"
  created=${slot_a_flash_transaction[created_epoch]}
  now=$(date +%s)
  (( 10#$created >= 10#${recovery_handoff[claimed_epoch]} && \
     10#$created <= 10#$now )) || \
    die "slot-A flash transaction has an inconsistent timestamp"
  if [[ ! "${slot_a_flash_transaction[state]}" =~ \
        ^(awaiting_runtime|abort_return_bootloader_pending|aborted_for_restore)$ ]]; then
    (( 10#$now <= \
       10#${recovery_handoff[claimed_epoch]} + handoff_resume_seconds )) || {
      [[ "${CUBS_FLASH_ABORT_CONFIRM:-}" == "$abort_confirmation" ]] || \
        die "the exact slot-A flash-resume window expired; abort it for stock restore"
    }
  fi
  actual_sha=$(sha256sum "$slot_a_flash_transaction_path")
  loaded_slot_a_flash_transaction_sha256=${actual_sha%% *}
  slot_a_flash_transaction_state=${slot_a_flash_transaction[state]}
  slot_a_flash_transaction_present=1
}

write_slot_a_flash_transaction() {
  local new_state=$1 current_state current_sha temporary

  slot_a_flash_state_valid "$new_state" || \
    die "invalid slot-A flash transaction state"
  current_state=${slot_a_flash_transaction_state:-none}
  slot_a_flash_transition_valid "$current_state" "$new_state" || \
    die "invalid slot-A flash transaction transition: $current_state -> $new_state"
  if [[ "$current_state" == none ]]; then
    [[ ! -e "$slot_a_flash_transaction_path" && \
       ! -L "$slot_a_flash_transaction_path" ]] || \
      die "slot-A flash transaction appeared unexpectedly"
    slot_a_flash_transaction=()
    slot_a_flash_transaction[created_epoch]=$(date +%s)
    slot_a_flash_transaction[transaction_id]=$(openssl rand -hex 16)
    slot_a_flash_transaction[serial_binding_sha256]=$(serial_binding \
      "${slot_a_flash_transaction[transaction_id]}" "$device_serial")
  else
    require_private_recovery_file "$slot_a_flash_transaction_path"
    current_sha=$(sha256sum "$slot_a_flash_transaction_path")
    current_sha=${current_sha%% *}
    [[ "$current_sha" == "$loaded_slot_a_flash_transaction_sha256" ]] || \
      die "slot-A flash transaction changed during the operation"
  fi
  temporary=$(mktemp "$recovery_state_dir/.slot-a-flash.XXXXXX")
  {
    printf 'schema=cubs-slot-a-flash-transaction-v1\n'
    printf 'state=%s\n' "$new_state"
    printf 'created_epoch=%s\n' \
      "${slot_a_flash_transaction[created_epoch]}"
    printf 'transaction_id=%s\n' \
      "${slot_a_flash_transaction[transaction_id]}"
    printf 'serial_binding_sha256=%s\n' \
      "${slot_a_flash_transaction[serial_binding_sha256]}"
    printf 'device=%s\n' "$expected_product"
    printf 'anchor_id=%s\n' "${recovery_lineage[anchor_id]}"
    printf 'lineage_sha256=%s\n' "$loaded_lineage_sha256"
    printf 'handoff_sha256=%s\n' "$loaded_handoff_sha256"
    printf 'physical_b_sizes_sha256=%s\n' \
      "${recovery_handoff[physical_b_sizes_sha256]}"
    printf 'stock_b_source=%s\n' "${recovery_lineage[stock_b_source]}"
    printf 'stock_b_provenance_sha256=%s\n' \
      "${recovery_lineage[stock_b_provenance_sha256]}"
    printf 'bundle_kind=%s\n' "$bundle_kind"
    printf 'bundle_manifest_sha256=%s\n' "$bundle_manifest_sha256"
    printf 'logical_targets_sha256=%s\n' "$logical_targets_sha256"
    printf 'logical_image_sizes_sha256=%s\n' \
      "$logical_image_sizes_sha256"
    printf 'recovery_policy_sha256=%s\n' \
      "$expected_recovery_policy_sha256"
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$slot_a_flash_transaction_path"
  load_slot_a_flash_transaction
  [[ "$slot_a_flash_transaction_state" == "$new_state" ]] || \
    die "slot-A flash transaction state was not published"
}

verify_runtime_boot_attestation() {
  local actual_sha created created_number now now_number
  local -A runtime_attestation=()

  require_private_recovery_file "$runtime_boot_attestation_path"
  [[ "$slot_a_flash_transaction_state" == awaiting_runtime ]] || \
    die "runtime boot proof requires an awaiting-runtime slot-A transaction"
  load_exact_kv "$runtime_boot_attestation_path" runtime_attestation \
    schema created_epoch anchor_id serial_binding_sha256 lineage_sha256 \
    handoff_sha256 flash_transaction_sha256 claimed_epoch device slot_suffix bundle_kind \
    bundle_manifest_sha256 output_build_id build_type \
    framework_security_patch build_fingerprint_sha256 boot_id uptime_seconds \
    sys_boot_completed validation_result runtime_report_basename \
    runtime_report_sha256 recovery_policy_sha256
  [[ "${runtime_attestation[schema]}" == cubs-runtime-boot-attestation-v2 && \
     "${runtime_attestation[anchor_id]}" == "${recovery_lineage[anchor_id]}" && \
     "${runtime_attestation[serial_binding_sha256]}" == \
       "${recovery_lineage[serial_binding_sha256]}" && \
     "${runtime_attestation[lineage_sha256]}" == \
       "${recovery_handoff[lineage_sha256]}" && \
     "${runtime_attestation[handoff_sha256]}" == "$loaded_handoff_sha256" && \
     "${runtime_attestation[flash_transaction_sha256]}" == \
       "$loaded_slot_a_flash_transaction_sha256" && \
     "${runtime_attestation[claimed_epoch]}" == \
       "${recovery_handoff[claimed_epoch]}" && \
     "${runtime_attestation[device]}" == "$expected_product" && \
     "${runtime_attestation[slot_suffix]}" == _a && \
     "${runtime_attestation[bundle_kind]}" == "$bundle_kind" && \
     "${runtime_attestation[bundle_manifest_sha256]}" == \
       "$bundle_manifest_sha256" && \
     "${runtime_attestation[output_build_id]}" == "$bundle_output_build_id" && \
     "${runtime_attestation[build_type]}" == userdebug && \
     "${runtime_attestation[framework_security_patch]}" == \
       "$bundle_framework_security_patch" && \
     "${runtime_attestation[build_fingerprint_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${runtime_attestation[boot_id]}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ && \
     "${runtime_attestation[uptime_seconds]}" =~ ^[1-9][0-9]*$ && \
     "${runtime_attestation[sys_boot_completed]}" == 1 && \
     "${runtime_attestation[validation_result]}" =~ ^(PASS|PASS_WITH_WARNINGS)$ && \
     "${runtime_attestation[runtime_report_basename]}" =~ \
       ^runtime-validation-(gsi|cubs)-[0-9]{8}T[0-9]{6}Z-[0-9]+\.txt$ && \
     "${runtime_attestation[runtime_report_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${runtime_attestation[recovery_policy_sha256]}" == \
       "$expected_recovery_policy_sha256" ]] || \
    die "runtime boot attestation does not match this exact claimed bundle"
  created=${runtime_attestation[created_epoch]}
  [[ "$created" =~ ^[1-9][0-9]{0,17}$ ]] || \
    die "runtime boot attestation has a malformed timestamp"
  created_number=$((10#$created))
  now=$(date +%s)
  now_number=$((10#$now))
  (( created_number >= 10#${recovery_handoff[claimed_epoch]} && \
     created_number <= now_number )) || \
    die "runtime boot attestation timestamp is inconsistent"
  actual_sha=$(sha256sum "$runtime_boot_attestation_path")
  loaded_runtime_attestation_sha256=${actual_sha%% *}
}

load_flash_retirement_receipt() {
  local path=$1 destination_name=$2 actual_binding created now
  local -n receipt_ref=$destination_name

  require_private_recovery_file "$path"
  load_exact_kv "$path" "$destination_name" \
    schema created_epoch anchor_id serial_binding_sha256 lineage_sha256 \
    handoff_sha256 flash_transaction_sha256 claimed_epoch \
    runtime_attestation_sha256 bundle_kind \
    bundle_manifest_sha256 destination_basename recovery_policy_sha256
  [[ "${receipt_ref[schema]}" == cubs-flash-retirement-v2 && \
     "${receipt_ref[created_epoch]}" =~ ^[1-9][0-9]{0,17}$ && \
     "${receipt_ref[anchor_id]}" =~ ^[0-9a-f]{32}$ && \
     "${receipt_ref[serial_binding_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt_ref[lineage_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt_ref[handoff_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt_ref[flash_transaction_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt_ref[claimed_epoch]}" =~ ^[1-9][0-9]{0,17}$ && \
     "${receipt_ref[runtime_attestation_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${receipt_ref[bundle_kind]}" == "$bundle_kind" && \
     "${receipt_ref[bundle_manifest_sha256]}" == "$bundle_manifest_sha256" && \
     "${receipt_ref[destination_basename]}" == \
       "flash-${receipt_ref[anchor_id]}-${bundle_manifest_sha256:0:16}-${receipt_ref[runtime_attestation_sha256]}" && \
     "${receipt_ref[recovery_policy_sha256]}" == \
       "$expected_recovery_policy_sha256" ]] || \
    die "flash-retirement receipt does not match this exact bundle"
  actual_binding=$(serial_binding "${receipt_ref[anchor_id]}" "$device_serial")
  [[ "$actual_binding" == "${receipt_ref[serial_binding_sha256]}" ]] || \
    die "flash-retirement receipt belongs to another USB transport"
  created=${receipt_ref[created_epoch]}
  now=$(date +%s)
  (( 10#$created >= 10#${receipt_ref[claimed_epoch]} && \
     10#$created <= 10#$now )) || \
    die "flash-retirement receipt has inconsistent timestamps"
}

verify_flash_retirement_archive() {
  local destination=$1 receipt_name=$2 archive_handoff archive_lineage
  local archive_runtime archive_slot_a_transaction expected_entries
  local actual_lineage_sha archived_transaction_binding
  local -n receipt_ref=$receipt_name
  local -A archived_handoff=() archived_lineage=() archived_runtime=()
  local -A archived_slot_a_transaction=()
  local -a entries=()

  require_private_recovery_dir "$destination"
  mapfile -t entries < <(
    find "$destination" -mindepth 1 -maxdepth 1 -printf '%f\n' | \
      LC_ALL=C sort
  )
  expected_entries=$'flash-handoff\nlifeboat-lineage\nretirement-receipt\nruntime-boot-attestation\nslot-a-flash-transaction'
  [[ "$(printf '%s\n' "${entries[@]}")" == "$expected_entries" ]] || \
    die "published flash-retirement archive has unexpected entries"
  archive_handoff="$destination/flash-handoff"
  archive_lineage="$destination/lifeboat-lineage"
  archive_runtime="$destination/runtime-boot-attestation"
  archive_slot_a_transaction="$destination/slot-a-flash-transaction"
  require_private_recovery_file "$destination/retirement-receipt"
  require_private_recovery_file "$archive_handoff"
  require_private_recovery_file "$archive_lineage"
  require_private_recovery_file "$archive_runtime"
  require_private_recovery_file "$archive_slot_a_transaction"
  cmp -s "$retirement_transaction_path" \
    "$destination/retirement-receipt" || \
    die "published retirement receipt differs from its active journal"
  [[ $(sha256sum "$archive_lineage" | awk '{print $1}') == \
       "${receipt_ref[lineage_sha256]}" && \
     $(sha256sum "$archive_handoff" | awk '{print $1}') == \
       "${receipt_ref[handoff_sha256]}" && \
     $(sha256sum "$archive_runtime" | awk '{print $1}') == \
       "${receipt_ref[runtime_attestation_sha256]}" && \
     $(sha256sum "$archive_slot_a_transaction" | awk '{print $1}') == \
       "${receipt_ref[flash_transaction_sha256]}" ]] || \
    die "published flash-retirement archive differs from its journal"

  load_exact_kv "$archive_lineage" archived_lineage \
    schema anchor_id created_epoch serial_binding_sha256 device stock_build_id \
    stock_fingerprint_sha256 factory_sha256 full_ota_sha256 bootloader baseband \
    ab_ota_partitions_sha256 shared_super_layout_sha256 \
    physical_b_sizes_sha256 stock_b_source stock_b_provenance_sha256 \
    physical_b_source_manifest_sha256 physical_b_vendor_boot_fetch_sha256 \
    recovery_policy_sha256
  actual_lineage_sha=$(sha256sum "$archive_lineage" | awk '{print $1}')
  [[ "${archived_lineage[schema]}" == cubs-recovery-lineage-v2 && \
     "${archived_lineage[anchor_id]}" == "${receipt_ref[anchor_id]}" && \
     "${archived_lineage[serial_binding_sha256]}" == \
       "${receipt_ref[serial_binding_sha256]}" && \
     "${archived_lineage[device]}" == "$expected_product" && \
     "${archived_lineage[stock_build_id]}" == "$bundle_stock_build" && \
     "${archived_lineage[recovery_policy_sha256]}" == \
       "$expected_recovery_policy_sha256" && \
     "$actual_lineage_sha" == "${receipt_ref[lineage_sha256]}" ]] || \
    die "archived recovery lineage is not the retired lineage"

  load_exact_kv "$archive_handoff" archived_handoff \
    schema state handoff_kind created_epoch expires_epoch claimed_epoch \
    anchor_id serial_binding_sha256 lineage_sha256 physical_b_sizes_sha256 \
    recovery_policy_sha256 bundle_kind bundle_manifest_sha256
  [[ "${archived_handoff[schema]}" == cubs-recovery-handoff-v2 && \
     "${archived_handoff[state]}" == claimed && \
     "${archived_handoff[anchor_id]}" == "${receipt_ref[anchor_id]}" && \
     "${archived_handoff[serial_binding_sha256]}" == \
       "${receipt_ref[serial_binding_sha256]}" && \
     "${archived_handoff[lineage_sha256]}" == \
       "${receipt_ref[lineage_sha256]}" && \
     "${archived_handoff[physical_b_sizes_sha256]}" == \
       "${archived_lineage[physical_b_sizes_sha256]}" && \
     "${archived_handoff[claimed_epoch]}" == \
       "${receipt_ref[claimed_epoch]}" && \
     "${archived_handoff[recovery_policy_sha256]}" == \
       "$expected_recovery_policy_sha256" && \
     "${archived_handoff[bundle_kind]}" == "$bundle_kind" && \
     "${archived_handoff[bundle_manifest_sha256]}" == \
       "$bundle_manifest_sha256" ]] || \
    die "archived claimed handoff is not the retired handoff"

  load_exact_kv "$archive_runtime" archived_runtime \
    schema created_epoch anchor_id serial_binding_sha256 lineage_sha256 \
    handoff_sha256 flash_transaction_sha256 claimed_epoch device slot_suffix bundle_kind \
    bundle_manifest_sha256 output_build_id build_type \
    framework_security_patch build_fingerprint_sha256 boot_id uptime_seconds \
    sys_boot_completed validation_result runtime_report_basename \
    runtime_report_sha256 recovery_policy_sha256
  [[ "${archived_runtime[schema]}" == cubs-runtime-boot-attestation-v2 && \
     "${archived_runtime[anchor_id]}" == "${receipt_ref[anchor_id]}" && \
     "${archived_runtime[serial_binding_sha256]}" == \
       "${receipt_ref[serial_binding_sha256]}" && \
     "${archived_runtime[lineage_sha256]}" == \
       "${receipt_ref[lineage_sha256]}" && \
     "${archived_runtime[handoff_sha256]}" == \
       "${receipt_ref[handoff_sha256]}" && \
     "${archived_runtime[flash_transaction_sha256]}" == \
       "${receipt_ref[flash_transaction_sha256]}" && \
     "${archived_runtime[claimed_epoch]}" == \
       "${receipt_ref[claimed_epoch]}" && \
     "${archived_runtime[device]}" == "$expected_product" && \
     "${archived_runtime[slot_suffix]}" == _a && \
     "${archived_runtime[bundle_kind]}" == "$bundle_kind" && \
     "${archived_runtime[bundle_manifest_sha256]}" == \
       "$bundle_manifest_sha256" && \
     "${archived_runtime[output_build_id]}" == "$bundle_output_build_id" && \
     "${archived_runtime[build_type]}" == userdebug && \
     "${archived_runtime[framework_security_patch]}" == \
       "$bundle_framework_security_patch" && \
     "${archived_runtime[sys_boot_completed]}" == 1 && \
     "${archived_runtime[validation_result]}" =~ \
       ^(PASS|PASS_WITH_WARNINGS)$ && \
     "${archived_runtime[recovery_policy_sha256]}" == \
       "$expected_recovery_policy_sha256" ]] || \
    die "archived runtime attestation is not the retired boot proof"

  load_exact_kv "$archive_slot_a_transaction" archived_slot_a_transaction \
    schema state created_epoch transaction_id serial_binding_sha256 device \
    anchor_id lineage_sha256 handoff_sha256 physical_b_sizes_sha256 \
    stock_b_source stock_b_provenance_sha256 bundle_kind \
    bundle_manifest_sha256 logical_targets_sha256 \
    logical_image_sizes_sha256 recovery_policy_sha256
  archived_transaction_binding=$(serial_binding \
    "${archived_slot_a_transaction[transaction_id]}" "$device_serial")
  [[ "${archived_slot_a_transaction[schema]}" == \
       cubs-slot-a-flash-transaction-v1 && \
     "${archived_slot_a_transaction[state]}" == awaiting_runtime && \
     "${archived_slot_a_transaction[created_epoch]}" =~ \
       ^[1-9][0-9]{0,17}$ && \
     "${archived_slot_a_transaction[transaction_id]}" =~ \
       ^[0-9a-f]{32}$ && \
     "${archived_slot_a_transaction[anchor_id]}" == \
       "${receipt_ref[anchor_id]}" && \
     "${archived_slot_a_transaction[serial_binding_sha256]}" == \
       "$archived_transaction_binding" && \
     "${archived_slot_a_transaction[device]}" == "$expected_product" && \
     "${archived_slot_a_transaction[lineage_sha256]}" == \
       "${receipt_ref[lineage_sha256]}" && \
     "${archived_slot_a_transaction[handoff_sha256]}" == \
       "${receipt_ref[handoff_sha256]}" && \
     "${archived_slot_a_transaction[physical_b_sizes_sha256]}" == \
       "${archived_lineage[physical_b_sizes_sha256]}" && \
     "${archived_slot_a_transaction[stock_b_source]}" == \
       "${archived_lineage[stock_b_source]}" && \
     "${archived_slot_a_transaction[stock_b_provenance_sha256]}" == \
       "${archived_lineage[stock_b_provenance_sha256]}" && \
     "${archived_slot_a_transaction[bundle_kind]}" == "$bundle_kind" && \
     "${archived_slot_a_transaction[bundle_manifest_sha256]}" == \
       "$bundle_manifest_sha256" && \
     "${archived_slot_a_transaction[logical_targets_sha256]}" == \
       "$logical_targets_sha256" && \
     "${archived_slot_a_transaction[logical_image_sizes_sha256]}" == \
       "$logical_image_sizes_sha256" && \
     "${archived_slot_a_transaction[recovery_policy_sha256]}" == \
       "$expected_recovery_policy_sha256" ]] || \
    die "archived slot-A transaction is not the retired flash proof"
  (( 10#${archived_slot_a_transaction[created_epoch]} >= \
       10#${receipt_ref[claimed_epoch]} && \
     10#${archived_slot_a_transaction[created_epoch]} <= \
       10#${receipt_ref[created_epoch]} )) || \
    die "archived slot-A transaction has inconsistent timestamps"
}

finish_pending_flash_retirement() {
  local consumed_dir destination temporary_dir source target index
  local -A receipt=()
  local -a sources archive_names expected_hashes

  [[ ! -e "$stock_restore_transaction_path" && \
     ! -L "$stock_restore_transaction_path" ]] || \
    die "a stock-restore transaction conflicts with flash retirement"
  load_flash_retirement_receipt "$retirement_transaction_path" receipt
  consumed_dir="$recovery_state_dir/consumed"
  [[ ! -L "$consumed_dir" ]] || die "consumed recovery directory is unsafe"
  mkdir -p "$consumed_dir"
  chmod 0700 "$consumed_dir"
  require_private_recovery_dir "$consumed_dir"
  destination="$consumed_dir/${receipt[destination_basename]}"
  sources=(
    "$recovery_lineage_path"
    "$recovery_handoff_path"
    "$runtime_boot_attestation_path"
    "$slot_a_flash_transaction_path"
  )
  archive_names=(
    lifeboat-lineage flash-handoff runtime-boot-attestation
    slot-a-flash-transaction
  )
  expected_hashes=(
    "${receipt[lineage_sha256]}"
    "${receipt[handoff_sha256]}"
    "${receipt[runtime_attestation_sha256]}"
    "${receipt[flash_transaction_sha256]}"
  )

  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    temporary_dir=$(mktemp -d "$consumed_dir/.flash-retirement.XXXXXX")
    chmod 0700 "$temporary_dir"
    require_private_recovery_dir "$temporary_dir"
    for ((index = 0; index < ${#sources[@]}; index += 1)); do
      source=${sources[$index]}
      target="$temporary_dir/${archive_names[$index]}"
      require_private_recovery_file "$source"
      [[ $(sha256sum "$source" | awk '{print $1}') == \
           "${expected_hashes[$index]}" ]] || \
        die "active recovery evidence differs from retirement journal"
      cp --reflink=auto --preserve=mode -- "$source" "$target"
      chmod 0600 "$target"
      require_private_recovery_file "$target"
      cmp -s "$source" "$target" || \
        die "copied recovery evidence changed before archive publication"
    done
    cp --reflink=auto --preserve=mode -- "$retirement_transaction_path" \
      "$temporary_dir/retirement-receipt"
    chmod 0600 "$temporary_dir/retirement-receipt"
    require_private_recovery_file "$temporary_dir/retirement-receipt"
    cmp -s "$retirement_transaction_path" \
      "$temporary_dir/retirement-receipt" || \
      die "copied retirement receipt changed before archive publication"
    mv -T -- "$temporary_dir" "$destination"
  fi

  verify_flash_retirement_archive "$destination" receipt
  for ((index = 0; index < ${#sources[@]}; index += 1)); do
    source=${sources[$index]}
    target="$destination/${archive_names[$index]}"
    if [[ -e "$source" || -L "$source" ]]; then
      require_private_recovery_file "$source"
      [[ $(sha256sum "$source" | awk '{print $1}') == \
           "${expected_hashes[$index]}" ]] || \
        die "active recovery evidence changed during retirement"
      cmp -s "$source" "$target" || \
        die "active recovery evidence differs from its published archive"
      rm -f -- "$source"
    fi
  done
  cmp -s "$retirement_transaction_path" \
    "$destination/retirement-receipt" || \
    die "flash-retirement journal changed during cleanup"
  rm -f -- "$retirement_transaction_path"
  handoff_consumed=1
}

publish_and_finish_flash_retirement() {
  local created current_flash_transaction_sha current_handoff_sha
  local current_lineage_sha current_runtime_sha
  local destination_basename temporary

  [[ ! -e "$retirement_transaction_path" && \
     ! -L "$retirement_transaction_path" && \
     ! -e "$stock_restore_transaction_path" && \
     ! -L "$stock_restore_transaction_path" ]] || \
    die "another recovery retirement or restore transaction is active"
  current_lineage_sha=$(sha256sum "$recovery_lineage_path" | awk '{print $1}')
  current_handoff_sha=$(sha256sum "$recovery_handoff_path" | awk '{print $1}')
  current_runtime_sha=$(sha256sum "$runtime_boot_attestation_path" | awk '{print $1}')
  current_flash_transaction_sha=$(sha256sum \
    "$slot_a_flash_transaction_path" | awk '{print $1}')
  [[ "$current_lineage_sha" == "$loaded_lineage_sha256" && \
     "$current_handoff_sha" == "$loaded_handoff_sha256" && \
     "$current_runtime_sha" == "$loaded_runtime_attestation_sha256" && \
     "$current_flash_transaction_sha" == \
       "$loaded_slot_a_flash_transaction_sha256" && \
     "$slot_a_flash_transaction_state" == awaiting_runtime ]] || \
    die "recovery evidence changed before journaled retirement"
  destination_basename="flash-${recovery_lineage[anchor_id]}-${bundle_manifest_sha256:0:16}-${current_runtime_sha}"
  created=$(date +%s)
  temporary=$(mktemp "$recovery_state_dir/.flash-retirement.XXXXXX")
  {
    printf 'schema=cubs-flash-retirement-v2\n'
    printf 'created_epoch=%s\n' "$created"
    printf 'anchor_id=%s\n' "${recovery_lineage[anchor_id]}"
    printf 'serial_binding_sha256=%s\n' \
      "${recovery_lineage[serial_binding_sha256]}"
    printf 'lineage_sha256=%s\n' "$current_lineage_sha"
    printf 'handoff_sha256=%s\n' "$current_handoff_sha"
    printf 'flash_transaction_sha256=%s\n' \
      "$current_flash_transaction_sha"
    printf 'claimed_epoch=%s\n' "${recovery_handoff[claimed_epoch]}"
    printf 'runtime_attestation_sha256=%s\n' "$current_runtime_sha"
    printf 'bundle_kind=%s\n' "$bundle_kind"
    printf 'bundle_manifest_sha256=%s\n' "$bundle_manifest_sha256"
    printf 'destination_basename=%s\n' "$destination_basename"
    printf 'recovery_policy_sha256=%s\n' \
      "$expected_recovery_policy_sha256"
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$retirement_transaction_path"
  require_private_recovery_file "$retirement_transaction_path"
  retirement_in_progress=1
  finish_pending_flash_retirement
}

detect_completed_flash_retirement() {
  local consumed_dir candidate count=0
  local -A receipt=()
  local -a candidates=()

  [[ "${CUBS_FLASH_FINALIZE_CONFIRM:-}" == "$finalize_confirmation" ]] || \
    return 1
  [[ $(fastboot_value current-slot) == a && \
     $(fastboot_value slot-successful:a) == yes && \
     $(fastboot_value slot-unbootable:a) == no ]] || return 1
  check_identity_and_firmware
  consumed_dir="$recovery_state_dir/consumed"
  [[ -d "$consumed_dir" && ! -L "$consumed_dir" ]] || return 1
  require_private_recovery_dir "$consumed_dir"
  mapfile -d '' -t candidates < <(
    find "$consumed_dir" -mindepth 1 -maxdepth 1 -type d \
      -name "flash-*-${bundle_manifest_sha256:0:16}-*" -print0
  )
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate/retirement-receipt" && \
       ! -L "$candidate/retirement-receipt" ]] || continue
    retirement_transaction_path="$candidate/retirement-receipt"
    load_flash_retirement_receipt "$retirement_transaction_path" receipt
    [[ "${candidate##*/}" == "${receipt[destination_basename]}" ]] || \
      die "historical flash-retirement directory has the wrong name"
    verify_flash_retirement_archive "$candidate" receipt
    ((count += 1))
  done
  retirement_transaction_path="$recovery_state_dir/flash-retirement-transaction"
  (( count >= 1 )) || return 1
  handoff_consumed=1
  return 0
}

rewrite_recovery_handoff() {
  local state=$1 claimed_epoch=$2 kind=$3 manifest=$4 temporary current_sha
  current_sha=$(sha256sum "$recovery_handoff_path")
  current_sha=${current_sha%% *}
  [[ "$current_sha" == "$loaded_handoff_sha256" ]] || \
    die "recovery handoff changed during preflight"
  temporary=$(mktemp "$recovery_state_dir/.handoff.XXXXXX")
  {
    printf 'schema=cubs-recovery-handoff-v2\n'
    printf 'state=%s\n' "$state"
    printf 'handoff_kind=%s\n' "${recovery_handoff[handoff_kind]}"
    printf 'created_epoch=%s\n' "${recovery_handoff[created_epoch]}"
    printf 'expires_epoch=%s\n' "${recovery_handoff[expires_epoch]}"
    printf 'claimed_epoch=%s\n' "$claimed_epoch"
    printf 'anchor_id=%s\n' "${recovery_handoff[anchor_id]}"
    printf 'serial_binding_sha256=%s\n' "${recovery_handoff[serial_binding_sha256]}"
    printf 'lineage_sha256=%s\n' "${recovery_handoff[lineage_sha256]}"
    printf 'physical_b_sizes_sha256=%s\n' "${recovery_handoff[physical_b_sizes_sha256]}"
    printf 'recovery_policy_sha256=%s\n' "${recovery_handoff[recovery_policy_sha256]}"
    printf 'bundle_kind=%s\n' "$kind"
    printf 'bundle_manifest_sha256=%s\n' "$manifest"
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$recovery_handoff_path"
  loaded_handoff_sha256=$(sha256sum "$recovery_handoff_path")
  loaded_handoff_sha256=${loaded_handoff_sha256%% *}
  recovery_handoff[state]=$state
  recovery_handoff[claimed_epoch]=$claimed_epoch
  recovery_handoff[bundle_kind]=$kind
  recovery_handoff[bundle_manifest_sha256]=$manifest
}

claim_recovery_handoff() {
  local physical_sha now
  physical_sha=$(physical_b_sizes_sha256)
  [[ "$physical_sha" == "${recovery_handoff[physical_b_sizes_sha256]}" ]] || \
    die "physical slot-B sizes differ from the verified recovery lineage"
  if [[ -z "$handoff_claimed" ]]; then
    now=$(date +%s)
    [[ "$now" -le "${recovery_handoff[expires_epoch]}" ]] || \
      die "recovery handoff expired during preflight"
    rewrite_recovery_handoff claimed "$now" "$bundle_kind" \
      "$bundle_manifest_sha256"
    handoff_claimed=1
  fi
}

warn_incomplete_handoff() {
  local status=$?
  if (( status != 0 )); then
    if [[ -n "$retirement_in_progress" && -z "$handoff_consumed" ]]; then
      printf '%s\n' \
        'WARNING: exact recovery-evidence retirement remains journaled.' \
        'Keep slot A selected and rerun this bundle with the post-boot finalize token.' >&2
    elif [[ "$slot_a_flash_transaction_state" == aborted_for_restore ]]; then
      printf '%s\n' \
        'WARNING: the exact slot-A transaction is handed off for stock restore.' \
        'Do not resume development flashing; run the matching stock restore workflow.' >&2
    elif [[ -n "$slot_a_flash_transaction_present" ]]; then
      printf '%s\n' \
        "WARNING: slot-A transaction remains journaled at $slot_a_flash_transaction_state." \
        'Never normal-boot Android B; resume this bundle or explicitly abort it for stock restore.' >&2
    elif [[ -n "$handoff_claimed" && -z "$handoff_consumed" ]]; then
      printf '%s\n' \
        'WARNING: the private handoff remains claimed by this exact bundle.' \
        'Do not boot Android B. Resume only with the exact resume token or restore stock A.' >&2
    fi
  fi
  exit "$status"
}
trap warn_incomplete_handoff EXIT

wait_for_selected_device() {
  local attempt
  local -a devices=()
  for ((attempt = 1; attempt <= 90; attempt += 1)); do
    mapfile -t devices < <(
      "$fastboot_bin" devices 2>/dev/null | awk 'NF {print $1}'
    )
    if (( ${#devices[@]} == 1 )) && [[ "${devices[0]}" == "$device_serial" ]]; then
      return 0
    fi
    if (( ${#devices[@]} > 0 )); then
      die "an unexpected or additional fastboot device appeared during USB transition"
    fi
    sleep 1
  done
  die "timed out waiting for the selected device; restore USB forwarding and rerun"
}

check_identity_and_firmware() {
  local product bootloader baseband unlocked slot_count snapshot_status
  product=$(fastboot_value product)
  bootloader=$(fastboot_value version-bootloader)
  baseband=$(fastboot_value version-baseband)
  unlocked=$(fastboot_value unlocked)
  slot_count=$(fastboot_value slot-count)
  snapshot_status=$(fastboot_value snapshot-update-status)

  [[ "$product" == "$expected_product" ]] || \
    die "expected product $expected_product; found ${product:-unknown}"
  [[ "$bootloader" == "$expected_bootloader" ]] || \
    die "bootloader mismatch: expected $expected_bootloader; found ${bootloader:-unknown}"
  [[ "$baseband" == "$expected_baseband" ]] || \
    die "baseband mismatch: expected $expected_baseband; found ${baseband:-unknown}"
  [[ "$unlocked" == yes ]] || die "device bootloader is not unlocked"
  [[ "$slot_count" == 2 ]] || \
    die "expected two boot slots; found ${slot_count:-unknown}"
  [[ "$snapshot_status" == none ]] || die \
    "snapshot update status must be none; found ${snapshot_status:-unknown}"
}

check_current_b_lifeboat_flags() {
  local current_slot slot_a_successful slot_a_unbootable
  local slot_b_successful slot_b_unbootable
  current_slot=$(fastboot_value current-slot)
  slot_a_successful=$(fastboot_value slot-successful:a)
  slot_a_unbootable=$(fastboot_value slot-unbootable:a)
  slot_b_successful=$(fastboot_value slot-successful:b)
  slot_b_unbootable=$(fastboot_value slot-unbootable:b)
  [[ "$current_slot" == b ]] || die \
    "slot B must be current before flashing; found ${current_slot:-unknown}"
  [[ "$slot_b_unbootable" == no ]] || die \
    "slot B is marked unbootable; refusing to risk the fastbootd lifeboat"
  [[ "$slot_a_successful" == yes && "$slot_a_unbootable" == no ]] || die \
    "healthy stock slot A is unavailable before the lifeboat transaction"
  require_b_success_for_lineage "$slot_b_successful"
}

require_b_success_for_lineage() {
  local value=$1
  case "${recovery_lineage[stock_b_source]}" in
    full_ota)
      [[ "$value" == yes || \
         ( "$value" == no && \
           "${recovery_handoff[handoff_kind]:-}" == physical_b_lifeboat ) ]] || die \
        "full-OTA slot B lacks a successful flag or exact selector handoff"
      ;;
    direct_factory_physical_b)
      [[ "$value" =~ ^(yes|no)$ ]] || die \
        "direct physical-B lifeboat has an unreadable successful flag"
      ;;
    *) die "unsupported stock-B lineage source" ;;
  esac
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

capture_b_physical_lifeboat() {
  local partition
  check_current_b_lifeboat_flags
  for partition in "${preserved_b_physical_partitions[@]}"; do
    require_slotted_partition "$partition"
    require_nonzero_partition_size "${partition}_b" >/dev/null
    require_nonzero_partition_size "${partition}_a" >/dev/null
  done
  note "verified nonzero, slotted A/B firmware and boot/recovery partitions"
}

verify_transaction_physical_b() {
  local current_slot partition current_digest
  check_identity_and_firmware
  require_bootloader_fastboot
  current_slot=$(fastboot_value current-slot)
  [[ "$current_slot" =~ ^(a|b)$ ]] || \
    die "unable to determine the current boot-control slot"
  [[ $(fastboot_value slot-unbootable:b) == no ]] || \
    die "physical slot-B lifeboat is marked unbootable"
  require_b_success_for_lineage "$(fastboot_value slot-successful:b)"
  for partition in "${preserved_b_physical_partitions[@]}"; do
    require_slotted_partition "$partition"
    require_nonzero_partition_size "${partition}_b" >/dev/null
  done
  current_digest=$(physical_b_sizes_sha256)
  [[ "$current_digest" == \
       "${recovery_handoff[physical_b_sizes_sha256]}" ]] || \
    die "physical slot-B sizes changed during the slot-A transaction"
  if [[ -n "$slot_a_flash_transaction_present" ]]; then
    [[ "$current_digest" == \
         "${slot_a_flash_transaction[physical_b_sizes_sha256]}" ]] || \
      die "physical slot-B sizes differ from the transaction journal"
  fi
  verify_live_vendor_boot_b_control
}

check_battery() {
  local battery_soc battery_soc_number
  battery_soc=$(fastboot_value battery-soc)
  battery_soc_number=$(tr -d '[:space:]%' <<<"$battery_soc")
  [[ "$battery_soc_number" =~ ^[0-9]+$ ]] || \
    die "unable to read battery state of charge"
  (( battery_soc_number >= 50 )) || \
    die "battery must be at least 50%; found $battery_soc"
}

require_bootloader_fastboot() {
  local userspace
  userspace=$(fastboot_value is-userspace)
  [[ "$userspace" == no ]] || die \
    "operation must start in bootloader fastboot, not fastbootd"
}

fastboot_transport_mode() {
  case "$(fastboot_value is-userspace)" in
    no) printf 'bootloader\n' ;;
    yes) printf 'fastbootd\n' ;;
    *) die "unable to determine whether the selected device is in bootloader fastboot or fastbootd" ;;
  esac
}

fastbootd_getvar_status=
fastbootd_getvar_output=
fastbootd_getvar_value=
fastbootd_getvar_value_count=0
fastbootd_getvar_failed_count=0
fastbootd_getvar_partition_not_found_count=0

capture_fastbootd_getvar() {
  local variable=$1 line remainder value_pattern partition_not_found_pattern

  fastbootd_getvar_status=0
  fastbootd_getvar_output=
  fastbootd_getvar_value=
  fastbootd_getvar_value_count=0
  fastbootd_getvar_failed_count=0
  fastbootd_getvar_partition_not_found_count=0
  if fastbootd_getvar_output=$(
    "${fastboot_command[@]}" getvar "$variable" 2>&1
  ); then
    fastbootd_getvar_status=0
  else
    fastbootd_getvar_status=$?
  fi

  # Parse the complete combined output rather than accepting the last value
  # that happened to match. Platform-Tools may prefix successful device
  # responses with "(bootloader)", while its partition-not-found diagnostic
  # is a host-side getvar failure line.
  value_pattern="^(\\(bootloader\\)[[:space:]]*)?${variable}:[[:space:]]*(.*)$"
  partition_not_found_pattern="^getvar:${variable}[[:space:]]+FAILED \\(remote: 'Partition not found'\\)$"
  while IFS= read -r line; do
    if [[ "$line" =~ $value_pattern ]]; then
      fastbootd_getvar_value=${BASH_REMATCH[2]}
      fastbootd_getvar_value_count=$((fastbootd_getvar_value_count + 1))
    fi
    if [[ "$line" =~ $partition_not_found_pattern ]]; then
      fastbootd_getvar_partition_not_found_count=$((
        fastbootd_getvar_partition_not_found_count + 1
      ))
    fi
    remainder=$line
    while [[ "$remainder" == *FAILED* ]]; do
      fastbootd_getvar_failed_count=$((fastbootd_getvar_failed_count + 1))
      remainder=${remainder#*FAILED}
    done
  done <<<"$fastbootd_getvar_output"
}

require_fastbootd_single_value() {
  local variable=$1
  capture_fastbootd_getvar "$variable"
  (( fastbootd_getvar_status == 0 && \
     fastbootd_getvar_value_count == 1 && \
     fastbootd_getvar_failed_count == 0 )) || \
    die "ambiguous fastbootd getvar response for $variable"
}

require_fastbootd_boolean() {
  local variable=$1
  require_fastbootd_single_value "$variable"
  [[ "$fastbootd_getvar_value" =~ ^(yes|no)$ ]] || \
    die "fastbootd getvar did not return yes or no for $variable"
}

require_fastbootd_partition_absent() {
  local variable=$1
  capture_fastbootd_getvar "$variable"
  # Stock fastbootd has been observed returning host status zero for this
  # exact FAILED response. Accept that quirk and the conventional status one,
  # but never infer absence from an explicit is-logical:no value.
  (( (fastbootd_getvar_status == 0 || fastbootd_getvar_status == 1) && \
     fastbootd_getvar_value_count == 0 && \
     fastbootd_getvar_failed_count == 1 && \
     fastbootd_getvar_partition_not_found_count == 1 )) || \
    die "fastbootd did not return exact partition absence for $variable"
}

require_fastbootd_hex_size() {
  local variable=$1
  require_fastbootd_single_value "$variable"
  [[ "$fastbootd_getvar_value" =~ ^0x[0-9a-fA-F]+$ ]] || \
    die "fastbootd did not return one strict hexadecimal size for $variable"
}

require_fastbootd_a_namespace() {
  local partition has_slot_mode=
  check_identity_and_firmware
  require_fastbootd_boolean is-userspace
  [[ "$fastbootd_getvar_value" == yes ]] || \
    die "the selected device is not in fastbootd"
  require_fastbootd_single_value current-slot
  [[ "$fastbootd_getvar_value" == a ]] || \
    die "refusing every slot-B fastbootd operation during development flashing"

  # Fastbootd implementations expose logical bases in one of two coherent
  # has-slot modes. Mixing the modes makes unsuffixed-name interpretation
  # unsafe, so establish one uniform mode across the complete six-base set.
  for partition in "${all_logical_partitions[@]}"; do
    require_fastbootd_boolean "has-slot:$partition"
    if [[ -z "$has_slot_mode" ]]; then
      has_slot_mode=$fastbootd_getvar_value
    elif [[ "$fastbootd_getvar_value" != "$has_slot_mode" ]]; then
      die "fastbootd exposes mixed has-slot modes for logical partitions"
    fi
  done
  [[ "$has_slot_mode" =~ ^(yes|no)$ ]] || \
    die "fastbootd logical has-slot mode is unreadable"

  # In uniform-no mode an unsuffixed name must not alias either slot. Uniform
  # yes supplies no safe unsuffixed inference, so only explicit A/B names are
  # authoritative in that mode.
  if [[ "$has_slot_mode" == no ]]; then
    for partition in "${all_logical_partitions[@]}"; do
      require_fastbootd_partition_absent "is-logical:$partition"
    done
  fi

  for partition in "${all_logical_partitions[@]}"; do
    require_fastbootd_boolean "is-logical:${partition}_a"
    [[ "$fastbootd_getvar_value" == yes ]] || \
      die "fastbootd does not expose the complete slot-A logical namespace"
    require_fastbootd_hex_size "partition-size:${partition}_a"
    require_fastbootd_partition_absent "is-logical:${partition}_b"
    [[ "$fastbootd_getvar_value_count" == 0 ]] || \
      die "fastbootd exposes a mixed or slot-B logical namespace"
  done
}

require_expected_logical_a_sizes() {
  local partition actual_size
  for partition in "${logical_partitions[@]}"; do
    actual_size=$(normalize_partition_size \
      "$(fastboot_value "partition-size:${partition}_a")")
    [[ "$actual_size" == "${expected_logical_sizes[$partition]}" ]] || \
      die "${partition}_a size differs from its exact expanded image size"
  done
}

require_global_wipe_partition() {
  local partition=$1
  [[ $(fastboot_value "has-slot:$partition") == no ]] || \
    die "$partition unexpectedly reports slotting; refusing the global wipe"
  require_nonzero_partition_size "$partition" >/dev/null
}

flash_explicit_a() {
  local partition=$1
  local image_name=${2:-"$partition.img"}
  note "flashing explicit partition ${partition}_a"
  "${fastboot_command[@]}" flash "${partition}_a" \
    "$bundle_dir/$image_name"
}

flash_explicit_physical_a() {
  local partition=$1
  require_slotted_partition "$partition"
  require_nonzero_partition_size "${partition}_a" >/dev/null
  flash_explicit_a "$partition"
  require_nonzero_partition_size "${partition}_a" >/dev/null
}

reboot_fastbootd_to_bootloader() {
  local current_slot
  check_identity_and_firmware
  [[ $(fastboot_value is-userspace) == yes ]] || \
    die "fastbootd-to-bootloader normalization did not start in fastbootd"
  current_slot=$(fastboot_value current-slot)
  [[ "$current_slot" =~ ^(a|b)$ ]] || \
    die "fastbootd exposes an unreadable current slot"
  note "returning the exact journaled transaction to bootloader fastboot"
  "${fastboot_command[@]}" reboot bootloader
  wait_for_selected_device
  check_identity_and_firmware
  require_bootloader_fastboot
  [[ $(fastboot_value current-slot) == "$current_slot" ]] || \
    die "boot-control slot changed during fastbootd-to-bootloader return"
}

select_stock_a_bootloader_for_logicals() {
  check_identity_and_firmware
  require_bootloader_fastboot
  [[ $(fastboot_value current-slot) =~ ^(a|b)$ ]] || \
    die "unable to read the boot-control slot before selecting stock A"
  verify_transaction_physical_b
  verify_live_vendor_boot_a_control
  note "selecting stock physical A before entering its fastbootd"
  "${fastboot_command[@]}" set_active a
  [[ $(fastboot_value current-slot) == a && \
     $(fastboot_value slot-unbootable:a) == no && \
     $(fastboot_value slot-unbootable:b) == no ]] || \
    die "slot A selection did not produce safe boot-control flags"
  verify_transaction_physical_b
  verify_live_vendor_boot_a_control
}

enter_stock_a_fastbootd() {
  check_identity_and_firmware
  require_bootloader_fastboot
  case "$(fastboot_value current-slot)" in
    a)
      [[ $(fastboot_value slot-unbootable:a) == no && \
         $(fastboot_value slot-unbootable:b) == no ]] || \
        die "stock A is not safely selectable before fastbootd entry"
      verify_transaction_physical_b
      verify_live_vendor_boot_a_control
      ;;
    b)
      select_stock_a_bootloader_for_logicals
      ;;
    *) die "unable to read the boot-control slot before fastbootd entry" ;;
  esac
  note "entering stock physical-A fastbootd for the slot-A logical namespace"
  "${fastboot_command[@]}" reboot fastboot
  wait_for_selected_device
  require_fastbootd_a_namespace
}

ensure_stock_a_fastbootd_for_logicals() {
  case "$(fastboot_transport_mode)" in
    fastbootd)
      if [[ $(fastboot_value current-slot) != a ]]; then
        reboot_fastbootd_to_bootloader
        enter_stock_a_fastbootd
      else
        require_fastbootd_a_namespace
      fi
      ;;
    bootloader)
      enter_stock_a_fastbootd
      ;;
  esac
}

replay_logical_a_writes() {
  local partition
  require_fastbootd_a_namespace
  note "WARNING: the first logical write invalidates stock Android B, but not its physical fastbootd lifeboat"
  for partition in "${logical_partitions[@]}"; do
    note "resizing explicit logical partition ${partition}_a to zero"
    "${fastboot_command[@]}" resize-logical-partition "${partition}_a" 0
    require_zero_partition_size "${partition}_a"
  done
  for partition in "${logical_partitions[@]}"; do
    flash_explicit_a "$partition"
  done
  require_fastbootd_a_namespace
  require_expected_logical_a_sizes
}

select_a_bootloader_after_logicals() {
  local current_slot
  check_identity_and_firmware
  require_bootloader_fastboot
  current_slot=$(fastboot_value current-slot)
  [[ "$current_slot" =~ ^(a|b)$ ]] || \
    die "unable to read the boot-control slot after logical writes"
  verify_transaction_physical_b
  if [[ "$current_slot" == b ]]; then
    note "reselecting A under the journaled post-logical transaction"
    "${fastboot_command[@]}" set_active a
  fi
  [[ $(fastboot_value current-slot) == a && \
     $(fastboot_value slot-unbootable:a) == no && \
     $(fastboot_value slot-unbootable:b) == no ]] || \
    die "slot A could not be selected safely after logical writes"
  verify_transaction_physical_b
}

resume_to_post_logicals_a_bootloader() {
  while [[ "$slot_a_flash_transaction_state" != \
           post_logicals_a_bootloader ]]; do
    case "$slot_a_flash_transaction_state" in
      select_a_bootloader_pending)
        if [[ $(fastboot_transport_mode) == fastbootd ]]; then
          reboot_fastbootd_to_bootloader
        fi
        select_stock_a_bootloader_for_logicals
        write_slot_a_flash_transaction enter_a_fastbootd_pending
        ;;
      enter_a_fastbootd_pending)
        ensure_stock_a_fastbootd_for_logicals
        write_slot_a_flash_transaction logical_writes_pending
        ;;
      logical_writes_pending)
        ensure_stock_a_fastbootd_for_logicals
        replay_logical_a_writes
        write_slot_a_flash_transaction return_a_bootloader_pending
        ;;
      return_a_bootloader_pending)
        if [[ $(fastboot_transport_mode) == fastbootd ]]; then
          require_fastbootd_a_namespace
          require_expected_logical_a_sizes
          reboot_fastbootd_to_bootloader
        fi
        select_a_bootloader_after_logicals
        write_slot_a_flash_transaction post_logicals_a_bootloader
        ;;
      *)
        die "slot-A transaction is not in a resumable pre-physical state"
        ;;
    esac
  done
}

flash_a_physical_payloads_and_wipe() {
  local partition
  if [[ $(fastboot_transport_mode) == fastbootd ]]; then
    reboot_fastbootd_to_bootloader
  fi
  select_a_bootloader_after_logicals
  if [[ "$bundle_kind" == gsi ]]; then
    flash_explicit_physical_a pvmfw
    note "flashing slot A vbmeta with verification disabled for the raw GSI trial"
    "${fastboot_command[@]}" \
      --disable-verity --disable-verification flash vbmeta_a \
      "$bundle_dir/vbmeta.img"
  else
    note "replaying all cubs physical slot-A payloads after logical completion"
    for partition in "${cubs_early_physical_partitions[@]}"; do
      flash_explicit_physical_a "$partition"
    done
    note "flashing chained vbmeta_system_a and vbmeta_vendor_a, then root vbmeta_a last"
    for partition in "${cubs_vbmeta_partitions[@]}"; do
      flash_explicit_physical_a "$partition"
    done
  fi
  verify_transaction_physical_b
  require_global_wipe_partition userdata
  require_global_wipe_partition metadata
  note "erasing shared userdata and metadata"
  "${fastboot_command[@]}" erase userdata
  "${fastboot_command[@]}" erase metadata
  verify_transaction_physical_b
}

activate_a_and_publish_awaiting_runtime() {
  if [[ $(fastboot_transport_mode) == fastbootd ]]; then
    reboot_fastbootd_to_bootloader
  fi
  check_identity_and_firmware
  require_bootloader_fastboot
  [[ $(fastboot_value current-slot) =~ ^(a|b)$ ]] || \
    die "unable to read the current slot before final A activation"
  verify_transaction_physical_b
  note "activating slot A only after every journaled write completed"
  "${fastboot_command[@]}" set_active a
  [[ $(fastboot_value current-slot) == a && \
     $(fastboot_value slot-unbootable:a) == no && \
     $(fastboot_value slot-unbootable:b) == no ]] || \
    die "final slot-A activation did not produce safe boot-control flags"
  verify_transaction_physical_b
  write_slot_a_flash_transaction awaiting_runtime
}

abort_slot_a_flash_for_stock_restore() {
  case "$slot_a_flash_transaction_state" in
    aborted_for_restore) ;;
    abort_return_bootloader_pending) ;;
    *) write_slot_a_flash_transaction abort_return_bootloader_pending ;;
  esac
  if [[ $(fastboot_transport_mode) == fastbootd ]]; then
    reboot_fastbootd_to_bootloader
  fi
  check_identity_and_firmware
  require_bootloader_fastboot
  [[ $(fastboot_value current-slot) =~ ^(a|b)$ ]] || \
    die "unable to bind the stock-restore handoff to a bootloader slot"
  verify_transaction_physical_b
  if [[ "$slot_a_flash_transaction_state" != aborted_for_restore ]]; then
    write_slot_a_flash_transaction aborted_for_restore
  fi
  note "slot-A flashing is durably aborted for the stock-restore workflow"
  note "the exact transaction, claimed handoff, and lineage remain active for restore adoption"
}

finalize_successful_slot_a_transaction() {
  if [[ $(fastboot_transport_mode) == fastbootd ]]; then
    [[ $(fastboot_value current-slot) == a ]] || \
      die "post-boot finalization may leave only slot-A fastbootd"
    reboot_fastbootd_to_bootloader
  fi
  check_identity_and_firmware
  require_bootloader_fastboot
  [[ $(fastboot_value current-slot) == a && \
     $(fastboot_value slot-successful:a) == yes && \
     $(fastboot_value slot-unbootable:a) == no && \
     $(fastboot_value slot-unbootable:b) == no ]] || \
    die "cannot retire recovery evidence until slot A has booted successfully"
  verify_runtime_boot_attestation
  verify_transaction_physical_b
  publish_and_finish_flash_retirement
  note "atomically retired the exact lineage, handoff, flash transaction, and runtime proof"
}

initialize_recovery_handoff
if [[ -n "$retirement_completed" ]]; then
  note "flash recovery evidence was already retired atomically for this exact bundle"
  exit 0
fi

if [[ -n "$slot_a_flash_transaction_present" ]]; then
  if [[ "${CUBS_FLASH_ABORT_CONFIRM:-}" == "$abort_confirmation" ]]; then
    abort_slot_a_flash_for_stock_restore
    exit 0
  fi
  case "$slot_a_flash_transaction_state" in
    aborted_for_restore|abort_return_bootloader_pending)
      die "finish or rerun the exact abort-for-stock-restore handoff before any development flash"
      ;;
    awaiting_runtime)
      [[ "${CUBS_FLASH_FINALIZE_CONFIRM:-}" == \
           "$finalize_confirmation" ]] || \
        die "slot-A flash awaits exact runtime validation or an explicit stock-restore abort"
      finalize_successful_slot_a_transaction
      exit 0
      ;;
    *)
      [[ "${CUBS_FLASH_RESUME_CONFIRM:-}" == "$resume_confirmation" ]] || \
        die "set the exact resume token for this journaled slot-A transaction"
      ;;
  esac
  check_battery
else
  (( transaction_action_count == 0 )) || \
    die "transaction action tokens cannot authorize a new slot-A flash"
  check_identity_and_firmware
  require_bootloader_fastboot
  check_battery
  [[ $(fastboot_value current-slot) == b ]] || \
    die "a new slot-A flash must begin from the verified slot-B bootloader"
  [[ ! -e "$runtime_boot_attestation_path" && \
     ! -L "$runtime_boot_attestation_path" ]] || \
    die "a stale runtime boot attestation exists before this slot-A flash"
  capture_b_physical_lifeboat
  verify_live_vendor_boot_b_control
  verify_live_vendor_boot_a_control
  claim_recovery_handoff
  write_slot_a_flash_transaction select_a_bootloader_pending
  note "preflight passed; the exact private handoff and slot-A transaction are journaled"
fi

case "$slot_a_flash_transaction_state" in
  select_a_bootloader_pending|enter_a_fastbootd_pending|\
  logical_writes_pending|return_a_bootloader_pending)
    resume_to_post_logicals_a_bootloader
    ;;
  post_logicals_a_bootloader) ;;
  activate_a_pending) ;;
  *) die "slot-A transaction cannot continue development flashing" ;;
esac
if [[ "$slot_a_flash_transaction_state" == post_logicals_a_bootloader ]]; then
  flash_a_physical_payloads_and_wipe
  write_slot_a_flash_transaction activate_a_pending
fi
activate_a_and_publish_awaiting_runtime

note "slot-A flash completed; the phone remains in bootloader fastboot"
note "retained the exact transaction, claimed handoff, and physical-B lifeboat until runtime proof"
note "slot-B Android is invalid, but physical B remains the stock fastbootd recovery anchor"
note "inspect device state, keep USB forwarding ready, then reboot slot A explicitly"
note "after runtime validation, return to fastboot and use the exact post-boot finalize token"
note "if slot A cannot boot, use the explicit abort-for-stock-restore token instead"
