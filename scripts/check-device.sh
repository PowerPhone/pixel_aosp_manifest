#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"

require_command fastboot unzip

mapfile -t attached_devices < <(fastboot devices | awk 'NF {print $1}')
(( ${#attached_devices[@]} == 1 )) || \
  die "expected exactly one fastboot device; found ${#attached_devices[@]}"
device_serial=${attached_devices[0]}
fastboot_command=(fastboot -s "$device_serial")

fastboot_value() {
  local variable=$1
  local output
  output=$("${fastboot_command[@]}" getvar "$variable" 2>&1) || true
  sed -nE "s/^(\(bootloader\)[[:space:]]*)?$variable:[[:space:]]*//p" <<<"$output" | tail -n 1
}

product=$(fastboot_value product)
bootloader=$(fastboot_value version-bootloader)
baseband=$(fastboot_value version-baseband)
unlocked=$(fastboot_value unlocked)
current_slot=$(fastboot_value current-slot)
userspace=$(fastboot_value is-userspace)
battery_soc=$(fastboot_value battery-soc)
battery=$(fastboot_value battery-voltage)
slot_count=$(fastboot_value slot-count)
snapshot_status=$(fastboot_value snapshot-update-status)
slot_a_successful=$(fastboot_value slot-successful:a)
slot_a_unbootable=$(fastboot_value slot-unbootable:a)
slot_b_successful=$(fastboot_value slot-successful:b)
slot_b_unbootable=$(fastboot_value slot-unbootable:b)

[[ "$product" == "$DEVICE_CODENAME" ]] || \
  die "expected product $DEVICE_CODENAME; found ${product:-unknown}"
[[ "$unlocked" == yes ]] || die "device bootloader is not unlocked"
[[ "$slot_count" == 2 ]] || die "expected two boot slots; found ${slot_count:-unknown}"
[[ "$snapshot_status" == none ]] || \
  die "snapshot update status must be none; found ${snapshot_status:-unknown}"
battery_soc_number=$(tr -d '[:space:]%' <<<"$battery_soc")
[[ "$battery_soc_number" =~ ^[0-9]+$ ]] || \
  die "unable to read battery state of charge"
(( battery_soc_number >= 50 )) || \
  die "battery must be at least 50%; found $battery_soc"

expected_stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
stock_images="$expected_stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
if [[ -f "$stock_images" ]]; then
  android_info=$(unzip -p "$stock_images" android-info.txt)
  expected_bootloader=$(sed -n 's/^require version-bootloader=//p' <<<"$android_info")
  expected_baseband=$(sed -n 's/^require version-baseband=//p' <<<"$android_info")
  [[ "$bootloader" == "$expected_bootloader" ]] || \
    die "bootloader mismatch: expected $expected_bootloader, found $bootloader"
  [[ "$baseband" == "$expected_baseband" ]] || \
    die "baseband mismatch: expected $expected_baseband, found $baseband"
else
  note "warning: extract the stock package to enable firmware-version checks"
fi

printf 'product: %s\n' "$product"
printf 'bootloader unlocked: %s\n' "$unlocked"
printf 'bootloader: %s\n' "$bootloader"
printf 'baseband: %s\n' "$baseband"
printf 'current slot: %s\n' "$current_slot"
printf 'fastboot userspace: %s\n' "$userspace"
printf 'snapshot update: %s\n' "$snapshot_status"
printf 'slot a successful/unbootable: %s/%s\n' "$slot_a_successful" "$slot_a_unbootable"
printf 'slot b successful/unbootable: %s/%s\n' "$slot_b_successful" "$slot_b_unbootable"
printf 'battery state of charge: %s\n' "$battery_soc"
printf 'battery voltage: %s\n' "$battery"
