#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
# shellcheck source=../lib/common.sh disable=SC1091
source "$project_root/scripts/lib/common.sh"
# shellcheck source=../lib/cubs-vendor-boot.sh disable=SC1091
source "$project_root/scripts/lib/cubs-vendor-boot.sh"

require_command cmp cp dd mkdir mktemp od rm stat tr truncate xxd

scratch_parent="$project_root/work/cubs-vendor-boot-layout-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

original_size=12288
table_offset=8192
bootconfig_offset=10240
payload_end=10324
valid="$scratch_dir/valid-vendor_boot.img"

write_u32_le() {
  local path=$1
  local offset=$2
  local value=$3
  local hex
  printf -v hex '%08x' "$value"
  printf '%s' "${hex:6:2}${hex:4:2}${hex:2:2}${hex:0:2}" | \
    xxd -r -p | dd of="$path" bs=1 seek="$offset" conv=notrunc status=none
}

write_text() {
  printf '%s' "$3" | \
    dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}

expect_failure() {
  local description=$1
  local path=$2
  local size=${3:-$original_size}
  local log="$scratch_dir/${description//[^a-zA-Z0-9]/-}.log"
  if (validate_cubs_vendor_boot_v4_layout "$path" "$size") \
      >"$log" 2>&1; then
    die "$description unexpectedly passed"
  fi
}

mutated_copy() {
  local name=$1
  mutated="$scratch_dir/$name.img"
  cp -- "$valid" "$mutated"
}

truncate -s "$original_size" "$valid"
write_text "$valid" 0 VNDRBOOT
write_u32_le "$valid" 8 4
write_u32_le "$valid" 12 2048
write_u32_le "$valid" 24 3000
write_text "$valid" 28 'android_arch_task_struct_size=784 bootconfig'
write_u32_le "$valid" 2096 2128
write_u32_le "$valid" 2100 0
write_u32_le "$valid" 2112 108
write_u32_le "$valid" 2116 1
write_u32_le "$valid" 2120 108
write_u32_le "$valid" 2124 84
write_u32_le "$valid" "$table_offset" 3000
write_u32_le "$valid" "$((table_offset + 4))" 0
write_u32_le "$valid" "$((table_offset + 8))" 1
write_text "$valid" "$bootconfig_offset" \
  $'androidboot.load_modules_parallel=performance\nandroidboot.boot_devices=3c2d0000.ufs\n'

validate_cubs_vendor_boot_v4_layout "$valid" "$original_size"

mutated_copy zero-ramdisk
write_u32_le "$mutated" 24 0
expect_failure zero-ramdisk "$mutated"

mutated_copy two-entries
write_u32_le "$mutated" 2116 2
expect_failure two-entries "$mutated"

mutated_copy wrong-table-size
write_u32_le "$mutated" 2112 216
expect_failure wrong-table-size "$mutated"

mutated_copy wrong-entry-size
write_u32_le "$mutated" 2120 112
expect_failure wrong-entry-size "$mutated"

mutated_copy partial-fragment
write_u32_le "$mutated" "$table_offset" 2048
expect_failure partial-fragment "$mutated"

mutated_copy shifted-fragment
write_u32_le "$mutated" "$((table_offset + 4))" 1
expect_failure shifted-fragment "$mutated"

mutated_copy recovery-fragment
write_u32_le "$mutated" "$((table_offset + 8))" 2
expect_failure recovery-fragment "$mutated"

mutated_copy named-fragment
write_text "$mutated" "$((table_offset + 12))" platform
expect_failure named-fragment "$mutated"

mutated_copy selected-board-id
write_u32_le "$mutated" "$((table_offset + 44))" 1
expect_failure selected-board-id "$mutated"

mutated_copy empty-bootconfig
write_u32_le "$mutated" 2124 0
expect_failure empty-bootconfig "$mutated"

mutated_copy escaping-bootconfig
write_u32_le "$mutated" 2124 4097
expect_failure escaping-bootconfig "$mutated"

mutated_copy changed-bootconfig
write_text "$mutated" "$bootconfig_offset" X
expect_failure changed-bootconfig "$mutated"

mutated_copy missing-bootconfig-token
dd if=/dev/zero of="$mutated" bs=1 seek=28 count=2048 \
  conv=notrunc status=none
write_text "$mutated" 28 android_arch_task_struct_size=784
expect_failure missing-bootconfig-token "$mutated"

mutated_copy missing-kernel-abi-token
dd if=/dev/zero of="$mutated" bs=1 seek=28 count=2048 \
  conv=notrunc status=none
write_text "$mutated" 28 bootconfig
expect_failure missing-kernel-abi-token "$mutated"

mutated_copy conflicting-kernel-abi-token
dd if=/dev/zero of="$mutated" bs=1 seek=28 count=2048 \
  conv=notrunc status=none
write_text "$mutated" 28 \
  'android_arch_task_struct_size=784 android_arch_task_struct_size=999 bootconfig'
expect_failure conflicting-kernel-abi-token "$mutated"

mutated_copy quoted-conflicting-kernel-abi-token
dd if=/dev/zero of="$mutated" bs=1 seek=28 count=2048 \
  conv=notrunc status=none
write_text "$mutated" 28 \
  'android_arch_task_struct_size=784 bootconfig "android_arch_task_struct_size=999"'
expect_failure quoted-conflicting-kernel-abi-token "$mutated"

mutated_copy embedded-command-line-record
dd if=/dev/zero of="$mutated" bs=1 seek=28 count=2048 \
  conv=notrunc status=none
write_text "$mutated" 28 \
  $'android_arch_task_struct_size=784 bootconfig\nandroid_arch_task_struct_size=999'
expect_failure embedded-command-line-record "$mutated"

mutated_copy trailing-command-line-record
dd if=/dev/zero of="$mutated" bs=1 seek=28 count=2048 \
  conv=notrunc status=none
write_text "$mutated" 28 \
  $'android_arch_task_struct_size=784 bootconfig\n'
expect_failure trailing-command-line-record "$mutated"

mutated_copy cross-nibble-terminator
dd if=/dev/zero of="$mutated" bs=1 seek=28 count=2048 \
  conv=notrunc status=none
write_text "$mutated" 28 \
  'bootconfig android_arch_task_struct_size=7840'
expect_failure cross-nibble-terminator "$mutated"

mutated_copy noncanonical-command-line-padding
write_text "$mutated" 128 X
expect_failure noncanonical-command-line-padding "$mutated"

mutated_copy nonzero-header-padding
write_text "$mutated" 2128 X
expect_failure nonzero-header-padding "$mutated"

mutated_copy nonzero-ramdisk-padding
write_text "$mutated" 7096 X
expect_failure nonzero-ramdisk-padding "$mutated"

mutated_copy nonzero-table-padding
write_text "$mutated" 8300 X
expect_failure nonzero-table-padding "$mutated"

mutated_copy nonzero-payload-padding
write_text "$mutated" "$payload_end" X
expect_failure nonzero-payload-padding "$mutated"

expect_failure unaligned-original-size "$valid" 12287

note "cubs vendor_boot v4 layout mutation tests passed"
