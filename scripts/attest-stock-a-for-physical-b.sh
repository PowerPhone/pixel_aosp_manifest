#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
# shellcheck source=lib/recovery-handoff.sh disable=SC1091
source "$script_dir/lib/recovery-handoff.sh"

require_command awk chmod cmp date flock grep mkdir mktemp mv od openssl \
  realpath rm sed sha256sum sleep stat timeout tr unzip wc

usage() {
  cat <<'EOF'
Usage: scripts/attest-stock-a-for-physical-b.sh adopt-finalized-restore-bootloader

  adopt-finalized-restore-bootloader
      Claim the one exact finalized v6 stock-restore receipt while its bound,
      healthy stock A remains in bootloader fastboot. Verify every physical
      A/B pair, full vendor_boot_a/b bytes, and six expanded stock logical-image
      sizes, then publish a fresh bootloader-verified preflight-v3. No ADB or
      device mutation is used.

The retired Android/two-slot-lpdump actions are not v7 baseline authority.
EOF
}

confirm_adoption_on_tty() {
  local entered
  local phrase=ADOPT_FINALIZED_RESTORE_BOOTLOADER_AS_STOCK_A_BASELINE
  [[ -t 0 && -t 1 ]] || \
    die "refusing finalized-restore baseline adoption without an interactive terminal"
  printf '\nType exactly: %s\n> ' "$phrase" >/dev/tty
  IFS= read -r entered </dev/tty
  [[ "$entered" == "$phrase" ]] || die "confirmation phrase did not match"
}

select_pinned_fastboot() {
  local digest output version
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
  digest=$(sha256sum "$fastboot_bin" | awk '{print $1}')
  [[ "$digest" == "$PLATFORM_TOOLS_FASTBOOT_SHA256" ]] || \
    die "fastboot does not match the pinned Platform-Tools binary digest"
  output=$("$fastboot_bin" --version 2>&1)
  if [[ "$output" =~ fastboot[[:space:]]version[[:space:]]([0-9]+(\.[0-9]+)*) ]]; then
    version=${BASH_REMATCH[1]}
  else
    die "unable to determine fastboot version"
  fi
  [[ "$version" == "$PLATFORM_TOOLS_VERSION" ]] || \
    die "this release is pinned to fastboot $PLATFORM_TOOLS_VERSION; found $version"
}

assert_single_selected_fastboot() {
  local -a devices=()
  mapfile -t devices < <("$fastboot_bin" devices | awk 'NF {print $1}')
  (( ${#devices[@]} == 1 )) || \
    die "expected exactly one fastboot device; found ${#devices[@]}"
  [[ "${devices[0]}" == "$device_serial" ]] || \
    die "the explicitly selected phone is not the sole fastboot device"
}

fastboot_exact_value() {
  local variable=$1 output status=0 failed_count value
  local -a values=()
  [[ "$variable" =~ ^[a-z0-9:_-]+$ ]] || die "unsafe fastboot getvar name"
  output=$("${fastboot_command[@]}" getvar "$variable" 2>&1) || status=$?
  mapfile -t values < <(
    sed -nE \
      "s/^(\(bootloader\)[[:space:]]*)?$variable:[[:space:]]*//p" \
      <<<"$output"
  )
  failed_count=$(grep -o 'FAILED' <<<"$output" | wc -l || true)
  (( status == 0 && ${#values[@]} == 1 && failed_count == 0 )) || \
    die "ambiguous fastboot probe for $variable"
  value=${values[0]}
  [[ -n "$value" && "$value" != *$'\r'* && "$value" != *$'\n'* ]] || \
    die "empty or malformed fastboot value for $variable"
  printf '%s\n' "$value"
}

logical_image_expanded_size() {
  local image=$1 magic major block_size total_blocks expanded_size file_size
  [[ -f "$image" && ! -L "$image" && -s "$image" ]] || \
    die "logical stock image is missing, empty, or unsafe: ${image##*/}"
  file_size=$(stat -c '%s' "$image")
  magic=$(od -An -N4 -j0 -tu4 -- "$image" | tr -d '[:space:]')
  if [[ "$magic" == 3978755898 ]]; then
    (( file_size >= 28 )) || die "logical sparse image has a truncated header"
    major=$(od -An -N2 -j4 -tu2 -- "$image" | tr -d '[:space:]')
    block_size=$(od -An -N4 -j12 -tu4 -- "$image" | tr -d '[:space:]')
    total_blocks=$(od -An -N4 -j16 -tu4 -- "$image" | tr -d '[:space:]')
    [[ "$major" == 1 && "$block_size" =~ ^[1-9][0-9]*$ && \
       "$total_blocks" =~ ^[1-9][0-9]*$ && \
       $((10#$block_size % 4096)) -eq 0 ]] || \
      die "logical sparse image has an invalid header: ${image##*/}"
    expanded_size=$((10#$block_size * 10#$total_blocks))
  else
    expanded_size=$file_size
  fi
  [[ "$expanded_size" =~ ^[1-9][0-9]*$ && \
     $((expanded_size % 4096)) -eq 0 ]] || \
    die "logical image has an invalid expanded size: ${image##*/}"
  printf '%s\n' "$expanded_size"
}

declare -A baseline_logical_sizes=()
declare -A baseline_image_sizes=()
declare -A baseline_image_sha256s=()
baseline_logical_sizes_sha256=
baseline_vendor_boot_image=
baseline_image_dir=
baseline_stock_images=

cleanup_baseline_images() {
  local status=$?
  trap - EXIT
  if [[ -n "${baseline_image_dir:-}" && -d "$baseline_image_dir" && \
        ! -L "$baseline_image_dir" && \
        "$baseline_image_dir" == "$project_root/work/finalized-restore-baseline"/.images.* ]]; then
    rm -rf -- "$baseline_image_dir"
  fi
  exit "$status"
}

load_stock_factory_controls() {
  local archive_entries entry_count expanded image image_name inner_sha
  local partition stock_dir stock_parent
  local -a stock_image_files=(vendor_boot.img)

  verify_sha256 "$FACTORY_IMAGE_SHA256" \
    "$project_root/downloads/$FACTORY_IMAGE_FILENAME"
  "$script_dir/extract-stock.sh"
  stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
  baseline_stock_images="$stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
  require_file "$baseline_stock_images"
  [[ ! -L "$baseline_stock_images" ]] || die "nested stock image ZIP is unsafe"
  inner_sha=$(sha256sum "$baseline_stock_images" | awk '{print $1}')
  [[ "$inner_sha" == "$CUBS_STOCK_INNER_IMAGE_SHA256" ]] || \
    die "nested stock image ZIP differs from its exact recovery-policy pin"
  unzip -tqq "$baseline_stock_images"
  for partition in "${cubs_logical_partitions[@]}"; do
    stock_image_files+=("$partition.img")
  done
  archive_entries=$(unzip -Z1 "$baseline_stock_images")
  for image_name in android-info.txt "${stock_image_files[@]}"; do
    entry_count=$(grep -Fxc -- "$image_name" <<<"$archive_entries" || true)
    (( entry_count == 1 )) || \
      die "nested stock ZIP must contain exactly one root entry named $image_name"
  done

  stock_parent="$project_root/work/finalized-restore-baseline"
  assert_inside_work "$stock_parent"
  [[ ! -L "$stock_parent" ]] || die "baseline image parent is unsafe"
  mkdir -p "$stock_parent"
  baseline_image_dir=$(mktemp -d "$stock_parent/.images.XXXXXX")
  trap cleanup_baseline_images EXIT
  unzip -q "$baseline_stock_images" "${stock_image_files[@]}" -d "$baseline_image_dir"

  baseline_logical_sizes=()
  baseline_image_sizes=()
  baseline_image_sha256s=()
  for image_name in "${stock_image_files[@]}"; do
    image="$baseline_image_dir/$image_name"
    [[ -f "$image" && ! -L "$image" && -s "$image" && \
       $(stat -c '%u' "$image") == "$EUID" && \
       $(stat -c '%h' "$image") == 1 ]] || \
      die "extracted stock image is unsafe: $image_name"
    baseline_image_sizes["$image_name"]=$(stat -c '%s' "$image")
    baseline_image_sha256s["$image_name"]=$(sha256sum "$image" | awk '{print $1}')
  done
  baseline_vendor_boot_image="$baseline_image_dir/vendor_boot.img"
  [[ "${baseline_image_sha256s[vendor_boot.img]}" == \
       "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || \
    die "stock vendor_boot image differs from its exact pin"
  for partition in "${cubs_logical_partitions[@]}"; do
    expanded=$(logical_image_expanded_size "$baseline_image_dir/$partition.img")
    baseline_logical_sizes["${partition}_a"]=$(printf '%x' "$expanded")
  done
  baseline_logical_sizes_sha256=$(
    cubs_stock_a_logical_sizes_sha256 baseline_logical_sizes
  )
}

verify_stock_factory_controls() {
  local current_digest current_inner_sha current_size expanded image_name partition
  local -A current_logical_sizes=()

  verify_sha256 "$FACTORY_IMAGE_SHA256" \
    "$project_root/downloads/$FACTORY_IMAGE_FILENAME"
  [[ -f "$baseline_stock_images" && ! -L "$baseline_stock_images" ]] || \
    die "nested stock image ZIP became unsafe during authorization"
  current_inner_sha=$(sha256sum "$baseline_stock_images" | awk '{print $1}')
  [[ "$current_inner_sha" == "$CUBS_STOCK_INNER_IMAGE_SHA256" ]] || \
    die "nested stock image ZIP changed during authorization"
  for image_name in vendor_boot.img \
      system.img system_dlkm.img system_ext.img product.img vendor.img vendor_dlkm.img; do
    [[ -f "$baseline_image_dir/$image_name" && \
       ! -L "$baseline_image_dir/$image_name" ]] || \
      die "extracted stock image became unsafe: $image_name"
    current_size=$(stat -c '%s' "$baseline_image_dir/$image_name")
    current_digest=$(sha256sum "$baseline_image_dir/$image_name" | awk '{print $1}')
    [[ "$current_size" == "${baseline_image_sizes[$image_name]}" && \
       "$current_digest" == "${baseline_image_sha256s[$image_name]}" ]] || \
      die "extracted stock image changed during authorization: $image_name"
  done
  for partition in "${cubs_logical_partitions[@]}"; do
    expanded=$(logical_image_expanded_size "$baseline_image_dir/$partition.img")
    # shellcheck disable=SC2034 # consumed through the associative-array nameref below.
    current_logical_sizes["${partition}_a"]=$(printf '%x' "$expanded")
  done
  current_digest=$(cubs_stock_a_logical_sizes_sha256 current_logical_sizes)
  [[ "$current_digest" == "$baseline_logical_sizes_sha256" ]] || \
    die "stock logical-image sizes changed during authorization"
}

load_stock_firmware_requirements() {
  local android_info board
  android_info=$(unzip -p "$baseline_stock_images" android-info.txt) || \
    die "unable to read nested stock android-info.txt"
  board=$(sed -n 's/^require board=//p' <<<"$android_info")
  expected_bootloader=$(sed -n 's/^require version-bootloader=//p' <<<"$android_info")
  expected_baseband=$(sed -n 's/^require version-baseband=//p' <<<"$android_info")
  [[ "|$board|" == *"|$DEVICE_CODENAME|"* && \
     $(grep -c '^require board=' <<<"$android_info") -eq 1 && \
     $(grep -c '^require version-bootloader=' <<<"$android_info") -eq 1 && \
     $(grep -c '^require version-baseband=' <<<"$android_info") -eq 1 && \
     -n "$expected_bootloader" && -n "$expected_baseband" ]] || \
    die "nested stock ZIP has malformed firmware requirements"
}

live_physical_a_sizes_sha256=
live_physical_b_sizes_sha256=
check_finalized_stock_a_bootloader() {
  local a_size b_size battery battery_number partition slot_b_success
  local lines_a='' lines_b=''

  [[ $(fastboot_exact_value product) == "$DEVICE_CODENAME" ]] || \
    die "bootloader transport is not product $DEVICE_CODENAME"
  [[ $(fastboot_exact_value version-bootloader) == "$expected_bootloader" && \
     $(fastboot_exact_value version-baseband) == "$expected_baseband" ]] || \
    die "bootloader/baseband differs from the pinned stock release"
  [[ $(fastboot_exact_value unlocked) == yes ]] || \
    die "device bootloader is not unlocked"
  [[ $(fastboot_exact_value is-userspace) == no ]] || \
    die "finalized stock-A adoption requires bootloader fastboot"
  [[ $(fastboot_exact_value slot-count) == 2 && \
     $(fastboot_exact_value current-slot) == a ]] || \
    die "finalized stock-A adoption requires current physical slot A"
  [[ $(fastboot_exact_value snapshot-update-status) == none ]] || \
    die "snapshot update status is not none"
  [[ $(fastboot_exact_value slot-successful:a) == yes && \
     $(fastboot_exact_value slot-unbootable:a) == no ]] || \
    die "finalized stock slot A is not successful and bootable"
  [[ $(fastboot_exact_value slot-unbootable:b) == no ]] || \
    die "physical slot-B fastbootd lifeboat is marked unbootable"
  slot_b_success=$(fastboot_exact_value slot-successful:b)
  [[ "$slot_b_success" =~ ^(yes|no)$ ]] || \
    die "physical slot B has an unreadable successful flag"
  battery=$(fastboot_exact_value battery-soc)
  battery_number=$(tr -d '[:space:]%' <<<"$battery")
  [[ "$battery_number" =~ ^[0-9]+$ ]] || die "unable to read battery state"
  (( battery_number >= 50 )) || \
    die "battery must be at least 50%; found $battery"

  for partition in "${cubs_preserved_b_partitions[@]}"; do
    [[ $(fastboot_exact_value "has-slot:$partition") == yes && \
       $(fastboot_exact_value "is-logical:${partition}_a") == no && \
       $(fastboot_exact_value "is-logical:${partition}_b") == no ]] || \
      die "$partition is not an explicit physical A/B pair"
    a_size=$(cubs_normalize_partition_size \
      "$(fastboot_exact_value "partition-size:${partition}_a")")
    b_size=$(cubs_normalize_partition_size \
      "$(fastboot_exact_value "partition-size:${partition}_b")")
    lines_a+="${partition}_a=$a_size"$'\n'
    lines_b+="${partition}_b=$b_size"$'\n'
  done
  live_physical_a_sizes_sha256=$(printf '%s' "$lines_a" | sha256sum | awk '{print $1}')
  live_physical_b_sizes_sha256=$(printf '%s' "$lines_b" | sha256sum | awk '{print $1}')
  [[ "$live_physical_a_sizes_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    die "unable to hash all physical slot-A sizes"
  [[ "$live_physical_b_sizes_sha256" == \
       "$cubs_verified_stock_a_baseline_physical_b_sizes_sha256" ]] || \
    die "physical slot-B sizes differ from the finalized restore receipt"
}

verify_live_stock_vendor_boot() {
  local slot=$1 actual_sha fetched fetched_size source_size target_size
  [[ "$slot" =~ ^(a|b)$ ]] || die "invalid stock vendor_boot fetch slot"
  source_size=$(stat -c '%s' "$baseline_vendor_boot_image")
  target_size=$(cubs_normalize_partition_size \
    "$(fastboot_exact_value "partition-size:vendor_boot_$slot")")
  [[ $(printf '%x' "$source_size") == "$target_size" ]] || \
    die "pinned vendor_boot image does not cover full vendor_boot_$slot"
  fetched=$(mktemp "$baseline_image_dir/.fetched-vendor_boot_${slot}.XXXXXX")
  rm -f -- "$fetched"
  "${fastboot_command[@]}" fetch "vendor_boot_$slot" "$fetched"
  [[ -f "$fetched" && ! -L "$fetched" && \
     $(stat -c '%u' "$fetched") == "$EUID" && \
     $(stat -c '%h' "$fetched") == 1 ]] || \
    die "fetched vendor_boot_$slot is unsafe"
  fetched_size=$(stat -c '%s' "$fetched")
  [[ "$fetched_size" == "$source_size" && \
     $(printf '%x' "$fetched_size") == "$target_size" ]] || {
    rm -f -- "$fetched"
    die "vendor_boot_$slot fetch does not cover its full physical partition"
  }
  actual_sha=$(sha256sum "$fetched" | awk '{print $1}')
  [[ "$actual_sha" == "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || {
    rm -f -- "$fetched"
    die "vendor_boot_$slot digest differs from the complete stock pin"
  }
  cmp -s "$fetched" "$baseline_vendor_boot_image" || {
    rm -f -- "$fetched"
    die "vendor_boot_$slot bytes differ from the complete pinned stock image"
  }
  rm -f -- "$fetched"
}

assert_no_conflicting_recovery_state() {
  local path
  for path in \
      "$cubs_recovery_handoff" \
      "$cubs_recovery_lineage" \
      "$cubs_sideload_preflight" \
      "$cubs_stock_a_lpdump_evidence" \
      "$cubs_stock_b_preparation_receipt" \
      "$cubs_stock_b_source_payload_manifest" \
      "$cubs_stock_b_fastbootd_trial_receipt" \
      "$cubs_stock_b_consumption_transaction" \
      "$cubs_slot_a_flash_transaction" \
      "$cubs_runtime_boot_attestation" \
      "$cubs_flash_retirement_transaction" \
      "$cubs_stock_restore_transaction"; do
    [[ ! -e "$path" && ! -L "$path" ]] || \
      die "conflicting recovery state blocks finalized baseline adoption: $path"
  done
}

baseline_claim_phase=
inspect_baseline_claim_phase() {
  local source_present=0 baseline_present=0 preflight_present=0
  [[ ! -L "$cubs_finalized_stock_restore_source" ]] || \
    die "canonical finalized stock-restore source is a symbolic link"
  [[ ! -L "$cubs_stock_a_baseline_evidence" ]] || \
    die "active stock-A baseline evidence is a symbolic link"
  [[ ! -L "$cubs_stock_a_physical_b_preflight" ]] || \
    die "active stock-A preflight is a symbolic link"
  [[ -e "$cubs_finalized_stock_restore_source" ]] && source_present=1
  [[ -e "$cubs_stock_a_baseline_evidence" ]] && baseline_present=1
  [[ -e "$cubs_stock_a_physical_b_preflight" ]] && preflight_present=1
  case "$source_present:$baseline_present:$preflight_present" in
    1:0:0) baseline_claim_phase=unclaimed ;;
    0:1:0) baseline_claim_phase=claimed_pending_preflight ;;
    0:1:1) baseline_claim_phase=complete ;;
    0:0:0)
      die "finalized stock-restore baseline was already consumed or is unavailable"
      ;;
    *) die "finalized stock-restore baseline claim is incomplete or duplicated" ;;
  esac
}

verify_baseline_claim_inputs() {
  local expected_phase=$1
  assert_no_conflicting_recovery_state
  inspect_baseline_claim_phase
  [[ "$baseline_claim_phase" == "$expected_phase" ]] || \
    die "finalized stock-restore claim changed during authorization"
  case "$baseline_claim_phase" in
    unclaimed)
      cubs_private_dir "$(dirname -- "$cubs_finalized_stock_restore_source")"
      cubs_verify_finalized_stock_restore_receipt \
        "$cubs_finalized_stock_restore_source" "$device_serial"
      ;;
    claimed_pending_preflight)
      cubs_verify_finalized_stock_restore_receipt \
        "$cubs_stock_a_baseline_evidence" "$device_serial"
      ;;
    complete)
      cubs_verify_stock_a_physical_b_preflight \
        "$device_serial" bootloader_verified historical
      ;;
    *) die "internal finalized-restore claim phase is invalid" ;;
  esac
  [[ "$cubs_verified_stock_a_baseline_sha256" == \
       "$CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256" ]] || \
    die "verified finalized-restore baseline digest is unavailable"
}

stock_a_preflight_needs_renewal() {
  local now remaining required_seconds=$1
  [[ "$required_seconds" =~ ^[1-9][0-9]*$ && \
     "${cubs_verified_stock_a_expires_epoch:-}" =~ ^[1-9][0-9]{0,17}$ ]] || \
    die "verified stock-A preflight renewal state is unavailable"
  now=$(date +%s)
  [[ "$now" =~ ^[1-9][0-9]{0,17}$ ]] || die "unable to read host clock"
  remaining=$((10#$cubs_verified_stock_a_expires_epoch - 10#$now))
  (( remaining < required_seconds ))
}

write_stock_a_preflight_v3() {
  local publication=${1:-create} expected_previous_sha=${2:-}
  local created current_sha expires partition preflight_id serial_binding
  local temporary
  case "$publication" in
    create)
      [[ -z "$expected_previous_sha" && \
         ! -e "$cubs_stock_a_physical_b_preflight" && \
         ! -L "$cubs_stock_a_physical_b_preflight" ]] || \
        die "stock-A preflight appeared before atomic publication"
      ;;
    replace)
      [[ "$expected_previous_sha" =~ ^[0-9a-f]{64}$ ]] || \
        die "stock-A preflight replacement lacks its verified predecessor"
      cubs_private_file "$cubs_stock_a_physical_b_preflight"
      current_sha=$(sha256sum "$cubs_stock_a_physical_b_preflight" | awk '{print $1}')
      [[ "$current_sha" == "$expected_previous_sha" ]] || \
        die "stock-A preflight changed before atomic renewal"
      ;;
    *) die "invalid stock-A preflight publication mode" ;;
  esac
  created=$(date +%s)
  [[ "$created" =~ ^[1-9][0-9]{0,17}$ ]] || die "unable to read host clock"
  expires=$((created + CUBS_STOCK_A_PHYSICAL_B_PREFLIGHT_SECONDS))
  preflight_id=$(cubs_random_anchor_id)
  serial_binding=$(cubs_serial_binding "$preflight_id" "$device_serial")
  temporary=$(mktemp "$cubs_recovery_state_dir/.stock-a-preflight-v3.XXXXXX")
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
    printf 'baseline_transaction_id=%s\n' \
      "$CUBS_FINALIZED_STOCK_RESTORE_TRANSACTION_ID"
    printf 'baseline_evidence_sha256=%s\n' \
      "$CUBS_FINALIZED_STOCK_RESTORE_RECEIPT_SHA256"
    printf 'stock_a_logical_sizes_sha256=%s\n' \
      "$baseline_logical_sizes_sha256"
    for partition in "${cubs_logical_partitions[@]}"; do
      printf 'logical_%s_a_size=%s\n' "$partition" \
        "${baseline_logical_sizes[${partition}_a]}"
    done
    printf 'preparation_policy_sha256=%s\n' \
      "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256"
  } >"$temporary"
  chmod 0600 "$temporary"

  # Recheck the terminal one-shot baseline and the exact publication target at
  # the final host boundary.  Replacement is one atomic rename: a crash leaves
  # either the previously verified preflight or the complete renewed one.
  cubs_verify_finalized_stock_restore_receipt \
    "$cubs_stock_a_baseline_evidence" "$device_serial"
  if [[ "$publication" == create ]]; then
    [[ ! -e "$cubs_stock_a_physical_b_preflight" && \
       ! -L "$cubs_stock_a_physical_b_preflight" ]] || \
      die "stock-A preflight appeared before atomic publication"
  else
    cubs_private_file "$cubs_stock_a_physical_b_preflight"
    current_sha=$(sha256sum "$cubs_stock_a_physical_b_preflight" | awk '{print $1}')
    [[ "$current_sha" == "$expected_previous_sha" ]] || \
      die "stock-A preflight changed before atomic renewal"
  fi
  mv -T -- "$temporary" "$cubs_stock_a_physical_b_preflight"
  cubs_private_file "$cubs_stock_a_physical_b_preflight"
}

claim_finalized_restore_receipt() {
  local destination_device source_device
  [[ "$baseline_claim_phase" == unclaimed ]] || return 0
  source_device=$(stat -c '%d' "$cubs_finalized_stock_restore_source")
  destination_device=$(stat -c '%d' "$cubs_recovery_state_dir")
  [[ "$source_device" == "$destination_device" ]] || \
    die "finalized restore claim must be an atomic same-filesystem move"
  mv -nT -- "$cubs_finalized_stock_restore_source" \
    "$cubs_stock_a_baseline_evidence"
  [[ ! -e "$cubs_finalized_stock_restore_source" && \
     ! -L "$cubs_finalized_stock_restore_source" ]] || \
    die "canonical finalized restore source remained after claim"
  cubs_verify_finalized_stock_restore_receipt \
    "$cubs_stock_a_baseline_evidence" "$device_serial"
  baseline_claim_phase=claimed_pending_preflight
}

adopt_finalized_restore_bootloader() {
  local initial_phase initial_preflight_sha='' partition renew_preflight=0
  [[ "${CUBS_ALLOW_FINALIZED_RESTORE_BASELINE:-}" == 1 ]] || die \
    "set CUBS_ALLOW_FINALIZED_RESTORE_BASELINE=1 for the reviewed one-shot adoption"
  [[ "${CUBS_FINALIZED_RESTORE_CONFIRM:-}" == \
       ADOPT_FINALIZED_RESTORE_BOOTLOADER_AS_STOCK_A_BASELINE ]] || die \
    "set CUBS_FINALIZED_RESTORE_CONFIRM=ADOPT_FINALIZED_RESTORE_BOOTLOADER_AS_STOCK_A_BASELINE"
  if [[ -n "${CUBS_FASTBOOT_SERIAL:-}" && -n "${ANDROID_SERIAL:-}" && \
        "$CUBS_FASTBOOT_SERIAL" != "$ANDROID_SERIAL" ]]; then
    die "CUBS_FASTBOOT_SERIAL and ANDROID_SERIAL select different devices"
  fi
  device_serial=${CUBS_FASTBOOT_SERIAL:-${ANDROID_SERIAL:-}}
  [[ -n "$device_serial" && "$device_serial" != -* && \
     ! "$device_serial" =~ [[:space:]] ]] || \
    die "select the phone explicitly with CUBS_FASTBOOT_SERIAL"

  select_pinned_fastboot
  fastboot_command=("$fastboot_bin" -s "$device_serial")
  load_stock_factory_controls
  load_stock_firmware_requirements
  cubs_lock_recovery_state
  assert_single_selected_fastboot
  inspect_baseline_claim_phase
  initial_phase=$baseline_claim_phase
  verify_baseline_claim_inputs "$initial_phase"
  check_finalized_stock_a_bootloader
  verify_live_stock_vendor_boot a
  verify_live_stock_vendor_boot b
  if [[ "$initial_phase" == complete ]]; then
    initial_preflight_sha=$cubs_verified_stock_a_preflight_sha256
    [[ "$cubs_verified_stock_a_logical_sizes_sha256" == \
         "$baseline_logical_sizes_sha256" ]] || \
      die "published preflight logical sizes differ from pinned factory images"
  fi

  confirm_adoption_on_tty

  # Repeat every private-input, factory, selected-transport, boot-control,
  # physical-pair, and full-byte control after the unbounded operator pause.
  select_pinned_fastboot
  fastboot_command=("$fastboot_bin" -s "$device_serial")
  verify_stock_factory_controls
  load_stock_firmware_requirements
  assert_single_selected_fastboot
  verify_baseline_claim_inputs "$initial_phase"
  check_finalized_stock_a_bootloader
  verify_live_stock_vendor_boot a
  verify_live_stock_vendor_boot b
  if [[ "$initial_phase" == complete ]]; then
    [[ "$cubs_verified_stock_a_preflight_sha256" == \
         "$initial_preflight_sha" ]] || \
      die "published preflight changed during authorization"
    [[ "$cubs_verified_stock_a_logical_sizes_sha256" == \
         "$baseline_logical_sizes_sha256" ]] || \
      die "published preflight logical sizes changed during authorization"
    if stock_a_preflight_needs_renewal \
        "$CUBS_STOCK_B_MIN_PREFLIGHT_SLACK_SECONDS"; then
      renew_preflight=1
    else
      cubs_require_stock_a_preflight_slack \
        "$CUBS_STOCK_B_MIN_PREFLIGHT_SLACK_SECONDS"
      note "the exact finalized-restore baseline and sufficiently fresh preflight-v3 were already claimed"
      return
    fi
  fi

  claim_finalized_restore_receipt
  if (( renew_preflight == 1 )); then
    write_stock_a_preflight_v3 replace "$initial_preflight_sha"
  else
    write_stock_a_preflight_v3 create
  fi
  cubs_verify_stock_a_physical_b_preflight \
    "$device_serial" bootloader_verified fresh
  [[ "$cubs_verified_stock_a_logical_sizes_sha256" == \
       "$baseline_logical_sizes_sha256" ]] || \
    die "published preflight-v3 differs from pinned factory logical sizes"
  cubs_require_stock_a_preflight_slack \
    "$CUBS_STOCK_B_MIN_PREFLIGHT_SLACK_SECONDS"
  for partition in "${cubs_logical_partitions[@]}"; do
    [[ "${cubs_verified_stock_a_logical_sizes[${partition}_a]}" == \
         "${baseline_logical_sizes[${partition}_a]}" ]] || \
      die "published preflight-v3 changed $partition expanded size"
  done
  if (( renew_preflight == 1 )); then
    note "atomically renewed preflight-v3 while preserving the one-shot baseline claim"
  else
    note "atomically claimed the exact finalized v6 restore receipt"
    note "published a fresh bootloader-verified stock-A preflight-v3 without ADB"
  fi
  note "the phone remains on healthy stock A in bootloader fastboot"
}

main() {
  (( $# == 1 )) || {
    usage >&2
    exit 2
  }
  case "$1" in
    adopt-finalized-restore-bootloader)
      adopt_finalized_restore_bootloader
      ;;
    attest-android|reboot-stock-a-to-bootloader|resume-stock-a-to-bootloader)
      die "the Android/two-slot-lpdump baseline path is retired under v7"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
