#!/usr/bin/env bash
set -euo pipefail

# Standalone Pixel 10 slot-A bundle runner. package-device-frankel.sh copies it
# beside the image set; it deliberately has no repository dependencies.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
expected_fastboot_version=37.0.1
expected_fastboot_sha256=a686e2c7e8dc9cf4cba0cb8a2eef05f7b2bd682c925abd032fe203215d80b618
expected_bootloader_version=deepspace-17.2-15372054
expected_baseband_version=g5400i-260317-260429-B-15308590

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
note() {
  printf '==> %s\n' "$*"
}

[[ "${FRANKEL_FLASH_CONFIRM:-}" == FLASH_FRANKEL_A_ERASE_USERDATA ]] || \
  die "set FRANKEL_FLASH_CONFIRM=FLASH_FRANKEL_A_ERASE_USERDATA after accepting the userdata wipe"

bootloader_firmware_partitions=(
  abl bl31 cap cpm dbc dbl
  dram_init_0 dram_init_1 dram_init_2 dram_init_3 dram_init_4
  dram_init_5 dram_init_6 dram_init_7 dram_init_8 dram_init_9
  dram_phy gc gdmc gsa_bl1 gsa_fw tzsw
)
radio_firmware_partitions=(modem)
firmware_partitions=(
  "${bootloader_firmware_partitions[@]}"
  "${radio_firmware_partitions[@]}"
)
static_partitions=(
  boot dtbo init_boot pvmfw vendor_boot vendor_kernel_boot vbmeta
)
logical_partitions=(
  system system_dlkm system_ext product vendor vendor_dlkm
)
image_files=()
for partition in \
    "${firmware_partitions[@]}" \
    "${static_partitions[@]}" \
    "${logical_partitions[@]}"; do
  image_files+=("$partition.img")
done

# SHA256SUMS is the bundle publication marker. Authenticate the exact reviewed
# directory before resolving or invoking fastboot so an interrupted publication,
# mixed image set, or corrupted payload cannot reach a device operation.
manifest_files=(
  bundle-kind
  BUNDLE_INFO.txt
  BUILD_ATTESTATION.txt
  android-info.txt
  fastboot-info.txt
  flash-all.sh
  "${image_files[@]}"
)
(( ${#manifest_files[@]} == 42 )) || \
  die "internal Frankel bundle allowlist is inconsistent"

checksum_manifest="$script_dir/SHA256SUMS"
[[ -f "$checksum_manifest" && ! -L "$checksum_manifest" ]] || \
  die "missing or unsafe bundle checksum manifest: $checksum_manifest"

declare -A expected_manifest_files=()
for name in "${manifest_files[@]}"; do
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    die "internal unsafe bundle filename: $name"
  [[ -z ${expected_manifest_files[$name]+present} ]] || \
    die "internal duplicate bundle filename: $name"
  expected_manifest_files["$name"]=1
  path="$script_dir/$name"
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || \
    die "missing, empty, or unsafe bundle file: $path"
done
[[ -x "$script_dir/flash-all.sh" ]] || \
  die "bundle flash-all.sh is not executable"

expected_bundle_entries=(SHA256SUMS "${manifest_files[@]}")
mapfile -d '' -t actual_bundle_entries < <(
  find "$script_dir" -mindepth 1 -maxdepth 1 -printf '%f\0' | sort -z
)
mapfile -t expected_bundle_entries_sorted < <(
  printf '%s\n' "${expected_bundle_entries[@]}" | sort
)
(( ${#actual_bundle_entries[@]} == ${#expected_bundle_entries_sorted[@]} )) || \
  die "bundle directory does not match the exact reviewed file allowlist"
for index in "${!expected_bundle_entries_sorted[@]}"; do
  [[ "${actual_bundle_entries[$index]}" == \
     "${expected_bundle_entries_sorted[$index]}" ]] || \
    die "bundle directory does not match the exact reviewed file allowlist"
done

declare -A seen_manifest_files=()
manifest_count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^([0-9a-f]{64})\ \ ([A-Za-z0-9][A-Za-z0-9._-]*)$ ]] || \
    die "malformed or unsafe SHA256SUMS entry"
  name=${BASH_REMATCH[2]}
  [[ -n ${expected_manifest_files[$name]+present} ]] || \
    die "unexpected file in SHA256SUMS: $name"
  [[ -z ${seen_manifest_files[$name]+present} ]] || \
    die "duplicate file in SHA256SUMS: $name"
  seen_manifest_files["$name"]=1
  ((manifest_count += 1))
done < "$checksum_manifest"
(( manifest_count == ${#manifest_files[@]} )) || \
  die "SHA256SUMS does not cover the exact 42-file bundle allowlist"
for name in "${manifest_files[@]}"; do
  [[ -n ${seen_manifest_files[$name]+present} ]] || \
    die "SHA256SUMS is missing $name"
done
(
  cd "$script_dir"
  sha256sum --check --strict --status SHA256SUMS
) || die "bundle checksum verification failed"

fastboot_command=${FASTBOOT:-fastboot}
if [[ "$fastboot_command" == */* ]]; then
  [[ -x "$fastboot_command" && ! -d "$fastboot_command" ]] || \
    die "FASTBOOT is not an executable file: $fastboot_command"
else
  fastboot_command=$(command -v -- "$fastboot_command" || true)
  [[ -n "$fastboot_command" ]] || die "fastboot was not found"
fi
fastboot_command=$(realpath -e -- "$fastboot_command") || \
  die "unable to resolve FASTBOOT executable"
[[ -f "$fastboot_command" && ! -L "$fastboot_command" && \
   -x "$fastboot_command" ]] || \
  die "FASTBOOT does not resolve to a safe executable file: $fastboot_command"
fastboot_sha256=$(sha256sum -- "$fastboot_command")
fastboot_sha256=${fastboot_sha256%% *}
[[ "$fastboot_sha256" == "$expected_fastboot_sha256" ]] || \
  die "fastboot does not match the pinned Platform-Tools binary digest"
fastboot_version=$(
  "$fastboot_command" --version | \
    sed -nE 's/^fastboot version ([0-9]+\.[0-9]+\.[0-9]+)(-.*)?$/\1/p' | \
    head -n 1
)
[[ "$fastboot_version" == "$expected_fastboot_version" ]] || \
  die "this bundle requires Platform-Tools fastboot $expected_fastboot_version; found ${fastboot_version:-unknown}"

requested_serial=${FRANKEL_FASTBOOT_SERIAL:-${ANDROID_SERIAL:-}}
mapfile -t connected_serials < <(
  "$fastboot_command" devices | awk 'NF >= 1 {print $1}' | sort -u
)
if [[ -n "$requested_serial" ]]; then
  serial=$requested_serial
  found=false
  for candidate in "${connected_serials[@]}"; do
    [[ "$candidate" == "$serial" ]] && found=true
  done
  [[ "$found" == true ]] || die "selected fastboot device is not connected"
else
  (( ${#connected_serials[@]} == 1 )) || \
    die "connect exactly one phone or set FRANKEL_FASTBOOT_SERIAL"
  serial=${connected_serials[0]}
fi

fb() {
  "$fastboot_command" -s "$serial" "$@"
}
getvar() {
  local name=$1 output
  if ! output=$(fb getvar "$name" 2>&1); then
    die "fastboot getvar failed for $name"
  fi
  sed -nE "s/^\(bootloader\) ${name}: ?//p; s/^${name}: ?//p" <<<"$output" | \
    tail -n 1 | tr -d '\r'
}
try_getvar() {
  local name=$1 output
  output=$(fb getvar "$name" 2>&1) || return 1
  sed -nE "s/^\(bootloader\) ${name}: ?//p; s/^${name}: ?//p" <<<"$output" | \
    tail -n 1 | tr -d '\r'
}

wait_for_fastboot() {
  local expected_userspace=$1 attempt value
  for ((attempt = 0; attempt < 90; attempt += 1)); do
    if "$fastboot_command" -s "$serial" devices | \
        awk 'NF >= 1 {print $1}' | grep -Fxq -- "$serial"; then
      value=$(try_getvar is-userspace || true)
      if [[ "$value" == "$expected_userspace" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  die "phone did not return in the expected fastboot mode"
}

require_target_identity() {
  local mode=$1 product unlocked current_slot
  product=$(getvar product)
  [[ "$product" == frankel ]] || \
    die "bundle is for frankel, attached fastboot product is ${product:-unknown}"
  unlocked=$(getvar unlocked)
  case "$unlocked" in
    yes|true) ;;
    *) die "bootloader must be unlocked; reported ${unlocked:-unknown}" ;;
  esac
  [[ "$(getvar is-userspace)" == "$mode" ]] || \
    die "phone is not in the expected fastboot mode"
  [[ "$(getvar slot-count)" == 2 ]] || \
    die "Frankel must expose exactly two boot slots"
  current_slot=$(getvar current-slot)
  [[ "$current_slot" == a || "$current_slot" == b ]] || \
    die "fastboot does not expose a valid current slot"
}

initial_userspace=$(getvar is-userspace)
[[ "$initial_userspace" == yes || "$initial_userspace" == no ]] || \
  die "fastboot does not expose its userspace mode"
require_target_identity "$initial_userspace"

if [[ "$initial_userspace" == yes ]]; then
  note "returning to bootloader fastboot for physical slot-A images"
  fb reboot bootloader
  wait_for_fastboot no
fi
require_target_identity no

bootloader_version=$(getvar version-bootloader)
baseband_version=$(getvar version-baseband)
[[ "$bootloader_version" == "$expected_bootloader_version" ]] || \
  die "expected donor bootloader $expected_bootloader_version; found ${bootloader_version:-unknown}"
[[ "$baseband_version" == "$expected_baseband_version" ]] || \
  die "expected donor baseband $expected_baseband_version; found ${baseband_version:-unknown}"

snapshot_status=$(getvar snapshot-update-status)
[[ "$snapshot_status" == none ]] || \
  die "refusing to flash during snapshot state: ${snapshot_status:-unknown}"
for partition in \
  "${firmware_partitions[@]}" \
  "${static_partitions[@]}"; do
  [[ "$(getvar "has-slot:$partition")" == yes ]] || \
    die "fastboot does not prove that $partition is slotted"
  partition_size=$(getvar "partition-size:${partition}_a")
  [[ "$partition_size" =~ ^(0x)?[0-9A-Fa-f]+$ ]] || \
    die "fastboot does not expose a valid slot-A size for $partition"
done

note "flashing 22 exact bootloader-firmware images to physical slot A"
note "dram_train, dpm, all unslotted identity/calibration data, and slot B are preserved"
for partition in "${bootloader_firmware_partitions[@]}"; do
  fb --slot=a flash "$partition" "$script_dir/$partition.img"
done
fb reboot bootloader
wait_for_fastboot no
require_target_identity no

note "flashing the exact donor modem image to physical slot A"
fb --slot=a flash modem "$script_dir/modem.img"
fb reboot bootloader
wait_for_fastboot no
require_target_identity no

# Enter fastbootd through the still-coherent currently active slot before any
# slot-A OS image is changed. This also works when A is current: fastbootd is
# already resident in RAM before the logical A set becomes temporarily
# inconsistent with the old root vbmeta.
note "entering fastbootd before changing any slot-A OS image"
fb reboot fastboot
wait_for_fastboot yes
require_target_identity yes
for partition in "${logical_partitions[@]}"; do
  [[ "$(getvar "has-slot:$partition")" == yes ]] || \
    die "fastbootd does not prove that $partition is slotted"
  [[ "$(getvar "is-logical:${partition}_a")" == yes ]] || \
    die "fastbootd does not identify ${partition}_a as logical"
  partition_size=$(getvar "partition-size:${partition}_a")
  [[ "$partition_size" =~ ^(0x)?[0-9A-Fa-f]+$ ]] || \
    die "fastbootd does not expose a valid slot-A size for $partition"
done
for partition in "${logical_partitions[@]}"; do
  fb resize-logical-partition "${partition}_a" 0
done
for partition in "${logical_partitions[@]}"; do
  fb --slot=a flash "$partition" "$script_dir/$partition.img"
done

# Return directly to the bootloader without attempting an Android boot. The
# source-built static set and its root vbmeta are committed together here;
# vbmeta is last so an interrupted earlier write cannot authenticate a mixed
# static set.
fb reboot bootloader
wait_for_fastboot no
require_target_identity no
note "flashing source-built static images to slot A"
for partition in "${static_partitions[@]}"; do
  fb --slot=a flash "$partition" "$script_dir/$partition.img"
done

# Wipe only after every logical and static OS payload has committed.
fb erase userdata
fb erase metadata
fb set_active a

if [[ "${FRANKEL_SKIP_REBOOT:-}" == 1 ]]; then
  note "flash completed without reboot; slot A is active"
else
  fb reboot
  note "flash completed; waiting for the userdebug system to boot"
fi
