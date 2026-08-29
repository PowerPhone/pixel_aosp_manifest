#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
# shellcheck source=lib/recovery-handoff.sh disable=SC1091
source "$script_dir/lib/recovery-handoff.sh"

require_command awk chmod cmp date flock grep mkdir mktemp mv od openssl \
  realpath rm sed sha256sum sort stat tail tr unzip

action=${1:-prepare}
case "$action" in
  prepare)
    expected_confirmation=PREPARE_EXACT_STOCK_PHYSICAL_B_SET_ACTIVE_B_NO_REBOOT
    ;;
  finalize-activation)
    expected_confirmation=FINALIZE_EXACT_STOCK_PHYSICAL_B_ACTIVATION_NO_REBOOT
    ;;
  refresh-ready)
    expected_confirmation=REFRESH_EXACT_STOCK_PHYSICAL_B_RECEIPT_NO_REBOOT
    ;;
  -h|--help|help)
    cat <<'EOF'
Usage: scripts/prepare-stock-b-physical.sh [prepare|finalize-activation|refresh-ready]

  prepare              Exact 34-image physical-B transaction (default).
  finalize-activation  Continue an exact activation_pending receipt without
                       reflashing or ever booting Android B.
  refresh-ready        Revalidate an exact historical ready receipt and its
                       live physical B, then refresh host timestamps only.
EOF
    exit 0
    ;;
  *) die "unsupported physical-B preparation action: $action" ;;
esac
[[ "${CUBS_ALLOW_STOCK_B_WRITE:-}" == 1 ]] || die \
  "set CUBS_ALLOW_STOCK_B_WRITE=1 only for the reviewed physical-B preparation"
[[ "${CUBS_STOCK_B_CONFIRM:-}" == "$expected_confirmation" ]] || die \
  "set CUBS_STOCK_B_CONFIRM=$expected_confirmation after reviewing docs/stock-b-physical-preparation.md"

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
    die "refusing physical-B state changes without an interactive terminal"
  printf '\nType exactly: %s\n> ' "$expected_confirmation" >/dev/tty
  IFS= read -r entered </dev/tty
  [[ "$entered" == "$expected_confirmation" ]] || \
    die "confirmation phrase did not match"
}

firmware_partitions=("${cubs_firmware_partitions[@]}")
boot_partitions=("${cubs_boot_lifeboat_partitions[@]}")
early_partitions=(
  "${firmware_partitions[@]}"
  boot init_boot dtbo vendor_boot vendor_kernel_boot pvmfw
)
vbmeta_partitions=(vbmeta_system vbmeta_vendor vbmeta)
physical_partitions=("${early_partitions[@]}" "${vbmeta_partitions[@]}")
logical_partitions=(system system_dlkm system_ext product vendor vendor_dlkm)
(( ${#firmware_partitions[@]} == 25 && \
   ${#boot_partitions[@]} == 9 && \
   ${#physical_partitions[@]} == 34 && \
   ${#logical_partitions[@]} == 6 )) || \
  die "internal physical/logical stock image allowlist has the wrong cardinality"
[[ "${physical_partitions[*]}" == "${cubs_preserved_b_partitions[*]}" ]] || \
  die "physical-B preparation order differs from the recovery allowlist"
[[ "${logical_partitions[*]}" == "${cubs_logical_partitions[*]}" ]] || \
  die "logical stock-image order differs from the recovery allowlist"

stock_image_files=()
for partition in "${physical_partitions[@]}"; do
  stock_image_files+=("$partition.img")
done
logical_image_files=()
for partition in "${logical_partitions[@]}"; do
  logical_image_files+=("$partition.img")
done
all_image_partitions=("${physical_partitions[@]}" "${logical_partitions[@]}")

factory_image="$project_root/downloads/$FACTORY_IMAGE_FILENAME"
verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"
"$script_dir/extract-stock.sh"
stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
stock_images="$stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
require_file "$stock_images"
[[ ! -L "$stock_images" ]] || die "refusing a symlinked stock image archive"

outer_inner_entry="${FACTORY_IMAGE_FILENAME%-factory-*}/$(basename -- "$stock_images")"
outer_entries=$(unzip -Z1 "$factory_image")
[[ $(grep -Fxc -- "$outer_inner_entry" <<<"$outer_entries" || true) -eq 1 ]] || \
  die "verified factory archive must contain exactly one $outer_inner_entry"
expected_inner_sha256=$(unzip -p "$factory_image" "$outer_inner_entry" | \
  sha256sum | awk '{print $1}')
actual_inner_sha256=$(sha256sum "$stock_images")
actual_inner_sha256=${actual_inner_sha256%% *}
[[ "$actual_inner_sha256" == "$expected_inner_sha256" ]] || \
  die "nested stock image ZIP does not match the pinned factory archive"
[[ "$actual_inner_sha256" == "$CUBS_STOCK_INNER_IMAGE_SHA256" ]] || \
  die "nested stock image ZIP differs from the exact recovery-policy pin"
unzip -tqq "$stock_images"

stock_archive_entries=$(unzip -Z1 "$stock_images")
for image_name in android-info.txt "${stock_image_files[@]}" \
    "${logical_image_files[@]}"; do
  entry_count=$(grep -Fxc -- "$image_name" <<<"$stock_archive_entries" || true)
  (( entry_count == 1 )) || die \
    "nested stock ZIP must contain exactly one root entry named $image_name"
done
stock_android_info=$(unzip -p "$stock_images" android-info.txt) || \
  die "nested stock ZIP has no android-info.txt"
expected_board=$(sed -n 's/^require board=//p' <<<"$stock_android_info")
expected_bootloader=$(sed -n 's/^require version-bootloader=//p' \
  <<<"$stock_android_info")
expected_baseband=$(sed -n 's/^require version-baseband=//p' \
  <<<"$stock_android_info")
[[ "|$expected_board|" == *"|$DEVICE_CODENAME|"* ]] || \
  die "nested stock ZIP does not allow product $DEVICE_CODENAME"
[[ $(grep -c '^require board=' <<<"$stock_android_info") -eq 1 && \
   $(grep -c '^require version-bootloader=' <<<"$stock_android_info") -eq 1 && \
   $(grep -c '^require version-baseband=' <<<"$stock_android_info") -eq 1 ]] || \
  die "nested stock ZIP has malformed firmware requirements"
[[ -n "$expected_bootloader" && -n "$expected_baseband" ]] || \
  die "nested stock ZIP has empty firmware requirements"

preparation_parent="$project_root/work/prepare-stock-b"
assert_inside_work "$preparation_parent"
[[ ! -L "$preparation_parent" ]] || \
  die "physical-B preparation root must not be a symbolic link"
umask 077
mkdir -p "$preparation_parent"
[[ -d "$preparation_parent" && ! -L "$preparation_parent" ]] || \
  die "physical-B preparation root is unsafe"
image_dir=$(mktemp -d "$preparation_parent/.images.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "${image_dir:-}" && -d "$image_dir" && ! -L "$image_dir" && \
        "$image_dir" == "$preparation_parent"/.images.* ]]; then
    rm -rf -- "$image_dir"
  fi
  exit "$status"
}
trap cleanup EXIT

note "extracting 34 physical and six logical images from the pinned nested ZIP"
unzip -q "$stock_images" "${stock_image_files[@]}" \
  "${logical_image_files[@]}" -d "$image_dir"

declare -A image_sizes=()
declare -A image_sha256s=()
source_payload_manifest_lines=
for partition in "${all_image_partitions[@]}"; do
  image_path="$image_dir/$partition.img"
  [[ -f "$image_path" && ! -L "$image_path" && -s "$image_path" ]] || \
    die "unsafe or empty extracted stock image: $partition.img"
  [[ $(stat -c '%u' "$image_path") == "$EUID" && \
     $(stat -c '%h' "$image_path") == 1 ]] || \
    die "extracted stock image has unsafe ownership or link count: $partition.img"
  image_sizes["$partition"]=$(stat -c '%s' "$image_path")
  image_sha256s["$partition"]=$(sha256sum "$image_path" | awk '{print $1}')
  [[ "${image_sizes[$partition]}" =~ ^[1-9][0-9]*$ && \
     "${image_sha256s[$partition]}" =~ ^[0-9a-f]{64}$ ]] || \
    die "unable to identify extracted stock image: $partition.img"
done
for partition in "${physical_partitions[@]}"; do
  source_payload_manifest_lines+="${image_sha256s[$partition]}  ${image_sizes[$partition]}  $partition.img"$'\n'
done
source_payload_manifest_sha256=$(
  printf '%s' "$source_payload_manifest_lines" | sha256sum
)
source_payload_manifest_sha256=${source_payload_manifest_sha256%% *}
[[ "$source_payload_manifest_sha256" == \
   "$CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256" ]] || \
  die "canonical stock-B source-payload manifest differs from its exact pin"
[[ "${image_sha256s[vendor_boot]}" == "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || \
  die "stock vendor_boot.img differs from its exact recovery-policy pin"

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

declare -A factory_logical_sizes=()
for partition in "${logical_partitions[@]}"; do
  expanded_size=$(logical_image_expanded_size "$image_dir/$partition.img")
  factory_logical_sizes["${partition}_a"]=$(printf '%x' "$expanded_size")
done
factory_logical_sizes_sha256=$(cubs_stock_a_logical_sizes_sha256 \
  factory_logical_sizes)

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

require_physical_slotted_partition() {
  local partition=$1
  [[ $(fastboot_value "has-slot:$partition") == yes ]] || \
    die "$partition is not reported slotted; refusing an unsuffixed/global write"
  [[ $(fastboot_value "is-logical:${partition}_a") == no && \
     $(fastboot_value "is-logical:${partition}_b") == no ]] || \
    die "$partition is not reported as a physical A/B partition"
}

partition_size_hex() {
  local partition=$1
  cubs_normalize_partition_size "$(fastboot_value "partition-size:$partition")"
}

hex_is_at_least() {
  local available=${1,,} required=${2,,}
  available=${available#0x}
  required=${required#0x}
  while [[ ${#available} -gt 1 && ${available:0:1} == 0 ]]; do
    available=${available:1}
  done
  while [[ ${#required} -gt 1 && ${required:0:1} == 0 ]]; do
    required=${required:1}
  done
  if (( ${#available} != ${#required} )); then
    (( ${#available} > ${#required} ))
    return
  fi
  [[ "$available" == "$required" || "$available" > "$required" ]]
}

require_image_fits() {
  local partition=$1 target_size_hex=$2 image_size_hex
  image_size_hex=$(printf '%x' "${image_sizes[$partition]}")
  hex_is_at_least "$target_size_hex" "$image_size_hex" || die \
    "$partition.img is larger than physical partition ${partition}_b"
}

check_device_identity() {
  local expected_slot=$1
  local baseband bootloader current_slot product slot_count snapshot_status
  local slot_a_successful slot_a_unbootable unlocked userspace
  product=$(fastboot_value product)
  bootloader=$(fastboot_value version-bootloader)
  baseband=$(fastboot_value version-baseband)
  unlocked=$(fastboot_value unlocked)
  userspace=$(fastboot_value is-userspace)
  slot_count=$(fastboot_value slot-count)
  current_slot=$(fastboot_value current-slot)
  snapshot_status=$(fastboot_value snapshot-update-status)
  slot_a_successful=$(fastboot_value slot-successful:a)
  slot_a_unbootable=$(fastboot_value slot-unbootable:a)

  [[ "$product" == "$DEVICE_CODENAME" ]] || \
    die "expected product $DEVICE_CODENAME; found ${product:-unknown}"
  [[ "$bootloader" == "$expected_bootloader" ]] || \
    die "bootloader mismatch: expected $expected_bootloader; found ${bootloader:-unknown}"
  [[ "$baseband" == "$expected_baseband" ]] || \
    die "baseband mismatch: expected $expected_baseband; found ${baseband:-unknown}"
  [[ "$unlocked" == yes ]] || die "device bootloader is not unlocked"
  [[ "$userspace" == no ]] || \
    die "physical-B preparation must run in bootloader fastboot, not fastbootd"
  [[ "$slot_count" == 2 ]] || \
    die "expected two boot slots; found ${slot_count:-unknown}"
  [[ "$current_slot" == "$expected_slot" ]] || \
    die "expected current slot $expected_slot; found ${current_slot:-unknown}"
  [[ "$snapshot_status" == none ]] || \
    die "snapshot update status must be none; found ${snapshot_status:-unknown}"
  [[ "$slot_a_successful" == yes ]] || \
    die "source slot A is not marked successful"
  [[ "$slot_a_unbootable" == no ]] || \
    die "source slot A is marked unbootable"
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

check_ready_b_flags() {
  [[ $(fastboot_value slot-unbootable:b) == no ]] || \
    die "prepared physical B is marked unbootable"
  [[ $(fastboot_value slot-successful:b) =~ ^(yes|no)$ ]] || \
    die "prepared physical B has an unreadable successful flag"
}

declare -A physical_a_sizes=()
declare -A physical_b_sizes=()
capture_physical_sizes_and_fit() {
  local a_size b_size partition
  physical_a_size_lines=
  physical_b_size_lines=
  for partition in "${physical_partitions[@]}"; do
    require_physical_slotted_partition "$partition"
    a_size=$(partition_size_hex "${partition}_a")
    b_size=$(partition_size_hex "${partition}_b")
    require_image_fits "$partition" "$b_size"
    physical_a_sizes["$partition"]=$a_size
    physical_b_sizes["$partition"]=$b_size
    physical_a_size_lines+="${partition}_a=$a_size"$'\n'
    physical_b_size_lines+="${partition}_b=$b_size"$'\n'
  done
  physical_a_sizes_sha256=$(printf '%s' "$physical_a_size_lines" | sha256sum)
  physical_a_sizes_sha256=${physical_a_sizes_sha256%% *}
  physical_b_sizes_sha256=$(printf '%s' "$physical_b_size_lines" | sha256sum)
  physical_b_sizes_sha256=${physical_b_sizes_sha256%% *}
}

verify_physical_b_geometry_against_baseline() {
  [[ "${cubs_verified_stock_a_baseline_physical_b_sizes_sha256:-}" =~ \
       ^[0-9a-f]{64}$ && \
     "$physical_b_sizes_sha256" == \
       "$cubs_verified_stock_a_baseline_physical_b_sizes_sha256" ]] || \
    die "physical slot-B geometry differs from the exact finalized-restore baseline"
}

verify_physical_sizes() {
  local a_size b_size partition
  for partition in "${physical_partitions[@]}"; do
    require_physical_slotted_partition "$partition"
    a_size=$(partition_size_hex "${partition}_a")
    b_size=$(partition_size_hex "${partition}_b")
    [[ "$a_size" == "${physical_a_sizes[$partition]}" ]] || \
      die "source slot-A partition size changed unexpectedly: ${partition}_a"
    [[ "$b_size" == "${physical_b_sizes[$partition]}" ]] || \
      die "target slot-B partition size changed unexpectedly: ${partition}_b"
    require_image_fits "$partition" "$b_size"
  done
}

verify_local_image() {
  local partition=$1 image_path actual_size actual_sha256
  image_path="$image_dir/$partition.img"
  [[ -f "$image_path" && ! -L "$image_path" ]] || \
    die "stock image changed during preparation: $partition.img"
  actual_size=$(stat -c '%s' "$image_path")
  actual_sha256=$(sha256sum "$image_path" | awk '{print $1}')
  [[ "$actual_size" == "${image_sizes[$partition]}" && \
     "$actual_sha256" == "${image_sha256s[$partition]}" ]] || \
    die "stock image changed during preparation: $partition.img"
}

verify_all_local_images() {
  local partition current_manifest_sha current_inner_sha
  verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"
  current_inner_sha=$(sha256sum "$stock_images" | awk '{print $1}')
  [[ "$current_inner_sha" == "$actual_inner_sha256" ]] || \
    die "nested stock image ZIP changed during preparation"
  for partition in "${all_image_partitions[@]}"; do
    verify_local_image "$partition"
  done
  current_manifest_sha=$(printf '%s' "$source_payload_manifest_lines" | \
    sha256sum | awk '{print $1}')
  [[ "$current_manifest_sha" == "$source_payload_manifest_sha256" ]] || \
    die "stock-B source-payload manifest changed during preparation"
}

verify_factory_logical_sizes_against_preflight() {
  local current_digest expanded_size key partition
  declare -A current_sizes=()

  [[ "${cubs_verified_stock_a_baseline_sha256:-}" =~ ^[0-9a-f]{64}$ && \
     "${cubs_verified_stock_a_logical_sizes_sha256:-}" =~ ^[0-9a-f]{64}$ ]] || \
    die "verified stock-A baseline logical-size evidence is unavailable"
  for partition in "${logical_partitions[@]}"; do
    verify_local_image "$partition"
    key=${partition}_a
    expanded_size=$(logical_image_expanded_size "$image_dir/$partition.img")
    current_sizes["$key"]=$(printf '%x' "$expanded_size")
    [[ "${current_sizes[$key]}" == "${factory_logical_sizes[$key]}" && \
       "${current_sizes[$key]}" == \
         "${cubs_verified_stock_a_logical_sizes[$key]:-}" ]] || \
      die "$partition.img expanded size differs from the claimed exact-stock-A baseline"
  done
  current_digest=$(cubs_stock_a_logical_sizes_sha256 current_sizes)
  [[ "$current_digest" == "$factory_logical_sizes_sha256" && \
     "$current_digest" == "$cubs_verified_stock_a_logical_sizes_sha256" ]] || \
    die "factory logical-image sizes differ from the claimed exact-stock-A baseline digest"
}

flash_stock_physical_b() {
  local partition=$1 a_size b_size
  check_device_identity a
  require_physical_slotted_partition "$partition"
  a_size=$(partition_size_hex "${partition}_a")
  b_size=$(partition_size_hex "${partition}_b")
  [[ "$a_size" == "${physical_a_sizes[$partition]}" ]] || \
    die "source slot-A size changed before flashing ${partition}_b"
  [[ "$b_size" == "${physical_b_sizes[$partition]}" ]] || \
    die "target slot-B size changed before flashing ${partition}_b"
  require_image_fits "$partition" "$b_size"
  verify_local_image "$partition"
  note "flashing exact stock physical partition ${partition}_b"
  "${fastboot_command[@]}" flash "${partition}_b" \
    "$image_dir/$partition.img"
  ((acknowledged_flash_count += 1))
  [[ $(fastboot_value current-slot) == a ]] || \
    die "current slot changed before final activation"
  [[ $(partition_size_hex "${partition}_a") == \
     "${physical_a_sizes[$partition]}" ]] || \
    die "source slot-A size changed after flashing ${partition}_b"
  [[ $(partition_size_hex "${partition}_b") == \
     "${physical_b_sizes[$partition]}" ]] || \
    die "target slot-B size changed after flashing ${partition}_b"
}

stock_b_receipt=$cubs_stock_b_preparation_receipt
stock_b_manifest=$cubs_stock_b_source_payload_manifest
orphan_manifest_sha256=
ensure_unused_private_state() {
  local current_sha path
  for path in "$cubs_recovery_handoff" "$cubs_recovery_lineage" \
      "$cubs_stock_a_lpdump_evidence" \
      "$stock_b_receipt" "$cubs_stock_b_fastbootd_trial_receipt" \
      "$cubs_stock_b_consumption_transaction" \
      "$cubs_runtime_boot_attestation" \
      "$cubs_flash_retirement_transaction" \
      "$cubs_slot_a_flash_transaction" \
      "$cubs_stock_restore_transaction"; do
    [[ ! -e "$path" && ! -L "$path" ]] || die \
      "existing recovery/preparation state must use its documented continuation: $path"
  done
  if [[ -e "$stock_b_manifest" || -L "$stock_b_manifest" ]]; then
    cubs_private_file "$stock_b_manifest"
    current_sha=$(sha256sum "$stock_b_manifest" | awk '{print $1}')
    [[ "$current_sha" == "$CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256" ]] || \
      die "orphan stock-B source manifest differs from the exact pinned payload"
    orphan_manifest_sha256=$current_sha
  else
    orphan_manifest_sha256=
  fi
}

archive_orphan_manifest_if_present() {
  local current_sha destination retired_dir
  [[ -n "$orphan_manifest_sha256" ]] || return 0
  cubs_private_file "$stock_b_manifest"
  current_sha=$(sha256sum "$stock_b_manifest" | awk '{print $1}')
  [[ "$current_sha" == "$orphan_manifest_sha256" ]] || \
    die "orphan stock-B source manifest changed while authorizing retry"
  retired_dir="$cubs_recovery_state_dir/retired"
  [[ ! -L "$retired_dir" ]] || die "retired recovery directory is unsafe"
  mkdir -p "$retired_dir"
  chmod 0700 "$retired_dir"
  destination="$retired_dir/orphan-stock-b-source-manifest-${current_sha}-$(date +%s)"
  [[ ! -e "$destination" && ! -L "$destination" ]] || \
    die "retired orphan-manifest destination already exists"
  mv -T -- "$stock_b_manifest" "$destination"
  cubs_private_file "$destination"
  orphan_manifest_sha256=
  note "archived an exact orphan source manifest before replaying the full transaction"
}

retired_sideload_preflight_sha256=none
archive_sideload_preflight_if_present() {
  local created created_number current_serial_sha marker_sha now now_number
  local retired_dir destination
  local -A marker=()

  if [[ ! -e "$cubs_sideload_preflight" && \
        ! -L "$cubs_sideload_preflight" ]]; then
    return 0
  fi
  cubs_private_file "$cubs_sideload_preflight"
  cubs_load_exact_kv "$cubs_sideload_preflight" marker \
    created serial_sha256 ota_sha256 source_slot
  created=${marker[created]}
  [[ "$created" =~ ^[1-9][0-9]{0,17}$ && \
     "${marker[serial_sha256]}" =~ ^[0-9a-f]{64}$ && \
     "${marker[ota_sha256]}" == "$FULL_OTA_SHA256" && \
     "${marker[source_slot]}" == a ]] || \
    die "sideload preflight marker is malformed or belongs to another workflow"
  current_serial_sha=$(printf '%s' "$device_serial" | sha256sum | awk '{print $1}')
  [[ "$current_serial_sha" == "${marker[serial_sha256]}" ]] || \
    die "sideload preflight marker belongs to another USB transport"
  created_number=$((10#$created))
  now=$(date +%s)
  [[ "$now" =~ ^[1-9][0-9]{0,17}$ ]] || die "unable to read the host clock"
  now_number=$((10#$now))
  (( created_number <= now_number )) || \
    die "sideload preflight marker is dated in the future"

  marker_sha=$(sha256sum "$cubs_sideload_preflight")
  marker_sha=${marker_sha%% *}
  retired_dir="$cubs_recovery_state_dir/retired"
  [[ ! -L "$retired_dir" ]] || die "retired recovery directory is unsafe"
  mkdir -p "$retired_dir"
  chmod 0700 "$retired_dir"
  [[ -d "$retired_dir" && ! -L "$retired_dir" ]] || \
    die "retired recovery directory is unsafe"
  destination="$retired_dir/sideload-preflight-${created}-${marker_sha}.abandoned-for-physical-b"
  [[ ! -e "$destination" && ! -L "$destination" ]] || \
    die "retired sideload-preflight destination already exists"
  mv -T -- "$cubs_sideload_preflight" "$destination"
  cubs_private_file "$destination"
  retired_sideload_preflight_sha256=$marker_sha
  note "archived the exact incompatible OTA-resume marker without deleting its evidence"
}

write_private_manifest() {
  local temporary current_sha
  temporary=$(mktemp "$cubs_recovery_state_dir/.stock-b-images.XXXXXX")
  printf '%s' "$source_payload_manifest_lines" >"$temporary"
  chmod 0600 "$temporary"
  current_sha=$(sha256sum "$temporary")
  current_sha=${current_sha%% *}
  [[ "$current_sha" == "$source_payload_manifest_sha256" ]] || \
    die "private stock-B source-payload manifest changed while publishing"
  mv -T -- "$temporary" "$stock_b_manifest"
  cubs_private_file "$stock_b_manifest"
}

write_preparation_receipt() {
  local state=$1 temporary current_sha
  [[ "$state" =~ ^(activation_pending|ready)$ ]] || \
    die "invalid stock-B preparation receipt state"
  if [[ -e "$stock_b_receipt" || -L "$stock_b_receipt" ]]; then
    cubs_private_file "$stock_b_receipt"
    current_sha=$(sha256sum "$stock_b_receipt")
    current_sha=${current_sha%% *}
    [[ "$state" == ready && "$current_sha" == "$pending_receipt_sha256" ]] || \
      die "stock-B preparation receipt changed during activation"
  fi
  temporary=$(mktemp "$cubs_recovery_state_dir/.stock-b-receipt.XXXXXX")
  {
    printf 'schema=cubs-stock-b-preparation-v2\n'
    printf 'state=%s\n' "$state"
    printf 'authorization_epoch=%s\n' "$receipt_authorization_epoch"
    printf 'created_epoch=%s\n' "$receipt_created_epoch"
    printf 'expires_epoch=%s\n' "$receipt_expires_epoch"
    printf 'preparation_id=%s\n' "$preparation_id"
    printf 'serial_binding_sha256=%s\n' "$serial_binding_sha256"
    printf 'stock_a_preflight_sha256=%s\n' \
      "$cubs_verified_stock_a_preflight_sha256"
    printf 'stock_a_baseline_evidence_sha256=%s\n' \
      "$cubs_verified_stock_a_baseline_sha256"
    printf 'stock_a_logical_sizes_sha256=%s\n' \
      "$cubs_verified_stock_a_logical_sizes_sha256"
    printf 'device=%s\n' "$DEVICE_CODENAME"
    printf 'stock_build_id=%s\n' "$STOCK_BUILD_ID"
    printf 'factory_filename=%s\n' "$FACTORY_IMAGE_FILENAME"
    printf 'factory_sha256=%s\n' "$FACTORY_IMAGE_SHA256"
    printf 'inner_image_filename=%s\n' "$(basename -- "$stock_images")"
    printf 'inner_image_sha256=%s\n' "$actual_inner_sha256"
    printf 'source_payload_manifest_sha256=%s\n' \
      "$source_payload_manifest_sha256"
    printf 'acknowledged_flash_count=%s\n' "$acknowledged_flash_count"
    printf 'vendor_boot_b_fetch_sha256=%s\n' "$vendor_boot_b_fetch_sha256"
    printf 'android_b_booted=no\n'
    printf 'source_slot=a\n'
    printf 'target_slot=b\n'
    printf 'bootloader=%s\n' "$expected_bootloader"
    printf 'baseband=%s\n' "$expected_baseband"
    printf 'physical_a_sizes_sha256=%s\n' "$physical_a_sizes_sha256"
    printf 'physical_b_sizes_sha256=%s\n' "$physical_b_sizes_sha256"
    printf 'preparation_policy_sha256=%s\n' \
      "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256"
    printf 'retired_sideload_preflight_sha256=%s\n' \
      "$retired_sideload_preflight_sha256"
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$stock_b_receipt"
  cubs_private_file "$stock_b_receipt"
}

verify_fetched_vendor_boot_b() {
  local fetched_vendor_boot vendor_boot_image_size_hex
  vendor_boot_image_size_hex=$(printf '%x' "${image_sizes[vendor_boot]}")
  [[ "$vendor_boot_image_size_hex" == "${physical_b_sizes[vendor_boot]}" ]] || \
    die "pinned vendor_boot.img does not cover the full vendor_boot_b partition"
  fetched_vendor_boot="$image_dir/fetched-vendor_boot_b.img"
  if [[ -e "$fetched_vendor_boot" || -L "$fetched_vendor_boot" ]]; then
    [[ -f "$fetched_vendor_boot" && ! -L "$fetched_vendor_boot" && \
       $(stat -c '%u' "$fetched_vendor_boot") == "$EUID" && \
       $(stat -c '%h' "$fetched_vendor_boot") == 1 ]] || \
      die "existing private vendor_boot_b fetch destination is unsafe"
    rm -f -- "$fetched_vendor_boot"
  fi
  note "fetching vendor_boot_b for the supported post-flash byte control"
  "${fastboot_command[@]}" fetch vendor_boot_b "$fetched_vendor_boot"
  [[ -f "$fetched_vendor_boot" && ! -L "$fetched_vendor_boot" && \
     $(stat -c '%u' "$fetched_vendor_boot") == "$EUID" && \
     $(stat -c '%h' "$fetched_vendor_boot") == 1 && \
     $(stat -c '%s' "$fetched_vendor_boot") == "${image_sizes[vendor_boot]}" ]] || \
    die "fetched vendor_boot_b is unsafe or does not cover its full partition"
  cmp -s "$fetched_vendor_boot" "$image_dir/vendor_boot.img" || \
    die "fetched vendor_boot_b differs from the pinned stock source payload"
  vendor_boot_b_fetch_sha256=$(sha256sum "$fetched_vendor_boot" | awk '{print $1}')
  [[ "$vendor_boot_b_fetch_sha256" == "${image_sha256s[vendor_boot]}" && \
     "$vendor_boot_b_fetch_sha256" == "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || \
    die "fetched vendor_boot_b digest differs from the exact stock pin"
  note "vendor_boot_b matches the complete pinned stock partition byte-for-byte"
}

promote_activation_pending_receipt() {
  local current_sha now new_expires temporary
  cubs_private_file "$stock_b_receipt"
  current_sha=$(sha256sum "$stock_b_receipt" | awk '{print $1}')
  [[ "$current_sha" == "$pending_receipt_sha256" && \
     $(grep -c '^state=activation_pending$' "$stock_b_receipt") -eq 1 && \
     $(grep -c '^created_epoch=' "$stock_b_receipt") -eq 1 && \
     $(grep -c '^expires_epoch=' "$stock_b_receipt") -eq 1 ]] || \
    die "activation-pending receipt changed before finalization"
  now=$(date +%s)
  new_expires=$((now + CUBS_STOCK_B_PREPARATION_RECEIPT_SECONDS))
  temporary=$(mktemp "$cubs_recovery_state_dir/.stock-b-finalize.XXXXXX")
  awk -v now="$now" -v expires="$new_expires" '
    /^state=activation_pending$/ { print "state=ready"; next }
    /^created_epoch=/ { print "created_epoch=" now; next }
    /^expires_epoch=/ { print "expires_epoch=" expires; next }
    { print }
  ' "$stock_b_receipt" >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$stock_b_receipt"
  cubs_private_file "$stock_b_receipt"
}

refresh_ready_receipt() {
  local current_sha now new_expires temporary
  cubs_private_file "$stock_b_receipt"
  current_sha=$(sha256sum "$stock_b_receipt" | awk '{print $1}')
  [[ "$current_sha" == "$ready_receipt_sha256" && \
     $(grep -c '^state=ready$' "$stock_b_receipt") -eq 1 && \
     $(grep -c '^created_epoch=' "$stock_b_receipt") -eq 1 && \
     $(grep -c '^expires_epoch=' "$stock_b_receipt") -eq 1 ]] || \
    die "ready preparation receipt changed before refresh"
  now=$(date +%s)
  new_expires=$((now + CUBS_STOCK_B_PREPARATION_RECEIPT_SECONDS))
  temporary=$(mktemp "$cubs_recovery_state_dir/.stock-b-refresh.XXXXXX")
  awk -v now="$now" -v expires="$new_expires" '
    /^created_epoch=/ { print "created_epoch=" now; next }
    /^expires_epoch=/ { print "expires_epoch=" expires; next }
    { print }
  ' "$stock_b_receipt" >"$temporary"
  chmod 0600 "$temporary"
  mv -T -- "$temporary" "$stock_b_receipt"
  cubs_private_file "$stock_b_receipt"
}

prepare_physical_b() {
cubs_lock_recovery_state
ensure_unused_private_state
assert_single_selected_device
cubs_verify_stock_a_physical_b_preflight "$device_serial" bootloader_verified
cubs_require_stock_a_preflight_slack \
  "$CUBS_STOCK_B_MIN_PREFLIGHT_SLACK_SECONDS"
verify_factory_logical_sizes_against_preflight
check_device_identity a
check_battery
capture_physical_sizes_and_fit
verify_physical_b_geometry_against_baseline
note "verified current healthy A, no snapshot, and 34 nonzero slotted A/B physical pairs"
note "verified every exact stock image fits its literal slot-B partition"

confirm_on_tty

# Confirmation can take arbitrarily long. Repeat every live-device, private
# receipt, archive, extracted-image, fit, and invariant check immediately
# before retiring host evidence or sending the first fastboot mutation.
ensure_unused_private_state
assert_single_selected_device
cubs_verify_stock_a_physical_b_preflight "$device_serial" bootloader_verified
cubs_require_stock_a_preflight_slack \
  "$CUBS_STOCK_B_MIN_PREFLIGHT_SLACK_SECONDS"
verify_factory_logical_sizes_against_preflight
check_device_identity a
check_battery
verify_physical_sizes
verify_physical_b_geometry_against_baseline
verify_all_local_images

note "preparing exact stock $STOCK_BUILD_ID in physical slot B without touching shared super"
archive_orphan_manifest_if_present
archive_sideload_preflight_if_present
acknowledged_flash_count=0
for partition in "${early_partitions[@]}"; do
  flash_stock_physical_b "$partition"
done
note "flashing chained vbmeta children before the root"
flash_stock_physical_b vbmeta_system
flash_stock_physical_b vbmeta_vendor
note "flashing root vbmeta_b as the final image write"
flash_stock_physical_b vbmeta
(( acknowledged_flash_count == 34 )) || \
  die "fastboot did not acknowledge exactly 34 physical-B flash commands"

check_device_identity a
verify_physical_sizes
note "all slot-A sizes and health flags remain unchanged after 34 explicit slot-B writes"

verify_fetched_vendor_boot_b

# The 34 writes can be slow. Bind the activation receipt only if the original
# stock-A authorization is still fresh at this exact post-flash boundary.
cubs_verify_stock_a_physical_b_preflight "$device_serial" bootloader_verified
verify_factory_logical_sizes_against_preflight

preparation_id=$(cubs_random_anchor_id)
serial_binding_sha256=$(cubs_serial_binding "$preparation_id" "$device_serial")
receipt_created_epoch=$(date +%s)
[[ "$receipt_created_epoch" =~ ^[1-9][0-9]{0,17}$ ]] || \
  die "unable to read the host clock"
(( 10#$receipt_created_epoch <= 10#$cubs_verified_stock_a_expires_epoch )) || \
  die "stock-A authorization expired before activation receipt publication; B remains unselected"
receipt_expires_epoch=$((receipt_created_epoch + CUBS_STOCK_B_PREPARATION_RECEIPT_SECONDS))
receipt_authorization_epoch=$receipt_created_epoch
write_private_manifest
write_preparation_receipt activation_pending
cubs_verify_stock_b_preparation \
  "$device_serial" "$expected_bootloader" "$expected_baseband" \
  activation_pending historical
verify_factory_logical_sizes_against_preflight
pending_receipt_sha256=$cubs_verified_stock_b_receipt_sha256
check_device_identity a
verify_physical_sizes

note "selecting slot B only after every physical image and invariant check passed"
"${fastboot_command[@]}" set_active b
check_device_identity b
[[ $(fastboot_value slot-unbootable:b) == no ]] || \
  die "prepared slot B is marked unbootable after activation"
[[ $(fastboot_value slot-successful:b) =~ ^(yes|no)$ ]] || \
  die "prepared slot B has an unreadable successful flag after activation"
verify_physical_sizes
[[ $(sha256sum "$stock_b_manifest" | awk '{print $1}') == \
   "$source_payload_manifest_sha256" ]] || \
  die "private stock-B source-payload manifest changed during activation"
write_preparation_receipt ready
cubs_verify_stock_b_preparation \
  "$device_serial" "$expected_bootloader" "$expected_baseband" ready
verify_factory_logical_sizes_against_preflight

note "exact stock physical slot B is prepared and selected"
note "the phone remains in bootloader fastboot; this script never issued reboot"
note "created a private receipt bound to the source-payload manifest and 34 acknowledged flashes"
note "never boot Android B; run the separately gated fastbootd-only trial next"
}

finalize_activation() {
  local current_slot path
  cubs_lock_recovery_state
  for path in "$cubs_recovery_handoff" "$cubs_recovery_lineage" \
      "$cubs_stock_a_lpdump_evidence" \
      "$cubs_stock_b_fastbootd_trial_receipt" \
      "$cubs_stock_b_consumption_transaction" \
      "$cubs_runtime_boot_attestation" \
      "$cubs_flash_retirement_transaction" \
      "$cubs_slot_a_flash_transaction" \
      "$cubs_stock_restore_transaction" "$cubs_sideload_preflight"; do
    [[ ! -e "$path" && ! -L "$path" ]] || \
      die "activation finalization conflicts with active recovery state: $path"
  done
  [[ -e "$stock_b_receipt" && ! -L "$stock_b_receipt" && \
     -e "$stock_b_manifest" && ! -L "$stock_b_manifest" ]] || \
    die "finalization requires the complete activation_pending receipt and manifest"
  assert_single_selected_device
  cubs_verify_stock_b_preparation \
    "$device_serial" "$expected_bootloader" "$expected_baseband" \
    activation_pending historical
  verify_factory_logical_sizes_against_preflight
  pending_receipt_sha256=$cubs_verified_stock_b_receipt_sha256
  current_slot=$(fastboot_value current-slot)
  [[ "$current_slot" =~ ^(a|b)$ ]] || \
    die "activation finalization requires current physical slot A or B"
  check_device_identity "$current_slot"
  check_battery
  if [[ "$current_slot" == b ]]; then
    [[ $(fastboot_value slot-unbootable:b) == no ]] || \
      die "already-selected physical B is marked unbootable"
  else
    [[ $(fastboot_value slot-unbootable:b) =~ ^(yes|no)$ ]] || \
      die "physical B has an unreadable pre-activation unbootable flag"
  fi
  capture_physical_sizes_and_fit
  verify_physical_b_geometry_against_baseline
  [[ "$physical_a_sizes_sha256" == "$cubs_verified_stock_b_a_sizes_sha256" && \
     "$physical_b_sizes_sha256" == "$cubs_verified_stock_b_b_sizes_sha256" ]] || \
    die "physical A/B sizes differ from the activation-pending receipt"
  verify_all_local_images

  confirm_on_tty

  assert_single_selected_device
  cubs_verify_stock_b_preparation \
    "$device_serial" "$expected_bootloader" "$expected_baseband" \
    activation_pending historical
  verify_factory_logical_sizes_against_preflight
  [[ "$cubs_verified_stock_b_receipt_sha256" == "$pending_receipt_sha256" ]] || \
    die "activation-pending receipt changed while waiting for confirmation"
  current_slot=$(fastboot_value current-slot)
  [[ "$current_slot" =~ ^(a|b)$ ]] || \
    die "activation finalization lost its physical slot state"
  check_device_identity "$current_slot"
  check_battery
  if [[ "$current_slot" == b ]]; then
    [[ $(fastboot_value slot-unbootable:b) == no ]] || \
      die "already-selected physical B is marked unbootable"
  else
    [[ $(fastboot_value slot-unbootable:b) =~ ^(yes|no)$ ]] || \
      die "physical B has an unreadable pre-activation unbootable flag"
  fi
  capture_physical_sizes_and_fit
  verify_physical_b_geometry_against_baseline
  [[ "$physical_a_sizes_sha256" == "$cubs_verified_stock_b_a_sizes_sha256" && \
     "$physical_b_sizes_sha256" == "$cubs_verified_stock_b_b_sizes_sha256" ]] || \
    die "physical A/B sizes changed while authorizing activation finalization"
  verify_all_local_images
  verify_fetched_vendor_boot_b

  if [[ "$current_slot" == a ]]; then
    note "continuing the already-authorized final slot-B selection"
    "${fastboot_command[@]}" set_active b
  else
    note "slot B was already selected; finalizing only the bound host receipt"
  fi
  check_device_identity b
  [[ $(fastboot_value slot-unbootable:b) == no && \
     $(fastboot_value slot-successful:b) =~ ^(yes|no)$ ]] || \
    die "prepared physical B has invalid boot-control flags after finalization"
  verify_physical_sizes
  promote_activation_pending_receipt
  cubs_verify_stock_b_preparation \
    "$device_serial" "$expected_bootloader" "$expected_baseband" ready
  verify_factory_logical_sizes_against_preflight
  note "finalized the exact physical-B preparation without booting Android B"
  note "the phone remains in bootloader fastboot with B current"
}

refresh_ready() {
  local path
  cubs_lock_recovery_state
  for path in "$cubs_recovery_handoff" "$cubs_recovery_lineage" \
      "$cubs_stock_a_lpdump_evidence" \
      "$cubs_stock_b_fastbootd_trial_receipt" \
      "$cubs_stock_b_consumption_transaction" \
      "$cubs_runtime_boot_attestation" \
      "$cubs_flash_retirement_transaction" \
      "$cubs_slot_a_flash_transaction" \
      "$cubs_stock_restore_transaction" "$cubs_sideload_preflight"; do
    [[ ! -e "$path" && ! -L "$path" ]] || \
      die "ready-receipt refresh conflicts with active recovery state: $path"
  done
  assert_single_selected_device
  cubs_verify_stock_b_preparation \
    "$device_serial" "$expected_bootloader" "$expected_baseband" ready historical
  verify_factory_logical_sizes_against_preflight
  ready_receipt_sha256=$cubs_verified_stock_b_receipt_sha256
  check_device_identity b
  check_ready_b_flags
  check_battery
  capture_physical_sizes_and_fit
  verify_physical_b_geometry_against_baseline
  [[ "$physical_a_sizes_sha256" == "$cubs_verified_stock_b_a_sizes_sha256" && \
     "$physical_b_sizes_sha256" == "$cubs_verified_stock_b_b_sizes_sha256" ]] || \
    die "physical A/B sizes differ from the historical ready receipt"
  verify_all_local_images
  verify_fetched_vendor_boot_b

  confirm_on_tty

  assert_single_selected_device
  cubs_verify_stock_b_preparation \
    "$device_serial" "$expected_bootloader" "$expected_baseband" ready historical
  verify_factory_logical_sizes_against_preflight
  [[ "$cubs_verified_stock_b_receipt_sha256" == "$ready_receipt_sha256" ]] || \
    die "ready preparation receipt changed while waiting for confirmation"
  check_device_identity b
  check_ready_b_flags
  check_battery
  capture_physical_sizes_and_fit
  verify_physical_b_geometry_against_baseline
  [[ "$physical_a_sizes_sha256" == "$cubs_verified_stock_b_a_sizes_sha256" && \
     "$physical_b_sizes_sha256" == "$cubs_verified_stock_b_b_sizes_sha256" ]] || \
    die "physical A/B sizes changed while authorizing receipt refresh"
  verify_all_local_images
  verify_fetched_vendor_boot_b
  refresh_ready_receipt
  cubs_verify_stock_b_preparation \
    "$device_serial" "$expected_bootloader" "$expected_baseband" ready fresh
  verify_factory_logical_sizes_against_preflight
  cubs_require_stock_b_preparation_slack \
    "$CUBS_STOCK_B_TRIAL_MIN_RECEIPT_SLACK_SECONDS"
  note "refreshed the exact ready physical-B receipt after full live revalidation"
  note "no device command mutated state; B remains current in bootloader fastboot"
  note "never boot Android B; run the gated fastbootd-only trial next"
}

case "$action" in
  prepare) prepare_physical_b ;;
  finalize-activation) finalize_activation ;;
  refresh-ready) refresh_ready ;;
esac
