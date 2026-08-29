#!/usr/bin/env bash

# Validate the Pixel 11 vendor_boot v4 container without interpreting or
# comparing the proprietary ramdisk payload. Callers must source common.sh
# first so die() is available.

cubs_vendor_boot_u32_le_at() {
  local -a byte=()
  read -r -a byte < <(od -An -tx1 -j "$2" -N 4 -v "$1")
  (( ${#byte[@]} == 4 )) || \
    die "short vendor_boot read from $1 at offset $2"
  printf '%u\n' "$((
    (16#${byte[3]} << 24) | (16#${byte[2]} << 16) |
    (16#${byte[1]} << 8) | 16#${byte[0]}
  ))"
}

cubs_vendor_boot_hex_at() {
  od -An -tx1 -j "$2" -N "$3" -v "$1" | tr -d ' \n'
}

cubs_vendor_boot_bytes_at() {
  cubs_vendor_boot_hex_at "$1" "$2" "$3" | xxd -r -p
}

cubs_vendor_boot_align_up() {
  local value=$1
  local alignment=$2
  printf '%u\n' "$(( ((value + alignment - 1) / alignment) * alignment ))"
}

cubs_vendor_boot_require_zero_range() {
  local path=$1
  local offset=$2
  local count=$3
  local description=$4
  local bytes
  (( count >= 0 )) || die "negative cubs vendor_boot $description range"
  bytes=$(cubs_vendor_boot_hex_at "$path" "$offset" "$count")
  (( ${#bytes} == count * 2 )) && [[ -z "${bytes//0/}" ]] || \
    die "cubs vendor_boot has nonzero or truncated $description bytes"
}

validate_cubs_vendor_boot_v4_layout() {
  local path=$1
  local original_size=$2
  local file_size magic header_version page_size vendor_ramdisk_size
  local header_size dtb_size table_size entry_count entry_size bootconfig_size
  local ramdisk_offset ramdisk_end dtb_offset dtb_end table_offset table_end
  local bootconfig_offset
  local payload_end expected_original_size entry_ramdisk_size
  local entry_ramdisk_offset entry_type name_hex board_id_hex
  local cmdline cmdline_hex cmdline_payload_hex token byte seen_nul=
  local remaining_cmdline
  local index
  local bootconfig_count=0 task_size_count=0 exact_task_size_count=0
  local task_assignment_count=0
  local expected_bootconfig
  local -a cmdline_tokens=()

  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || \
    die "cubs vendor_boot image is missing, empty, or unsafe: $path"
  [[ "$original_size" =~ ^[0-9]+$ ]] || \
    die "cubs vendor_boot AVB original size is malformed"
  file_size=$(stat -c '%s' "$path")
  (( original_size > 0 && original_size <= file_size )) || \
    die "cubs vendor_boot AVB original size is outside its image"

  magic=$(cubs_vendor_boot_hex_at "$path" 0 8)
  [[ "$magic" == 564e4452424f4f54 ]] || \
    die "cubs vendor_boot does not have VNDRBOOT magic"
  header_version=$(cubs_vendor_boot_u32_le_at "$path" 8)
  page_size=$(cubs_vendor_boot_u32_le_at "$path" 12)
  vendor_ramdisk_size=$(cubs_vendor_boot_u32_le_at "$path" 24)
  header_size=$(cubs_vendor_boot_u32_le_at "$path" 2096)
  dtb_size=$(cubs_vendor_boot_u32_le_at "$path" 2100)
  table_size=$(cubs_vendor_boot_u32_le_at "$path" 2112)
  entry_count=$(cubs_vendor_boot_u32_le_at "$path" 2116)
  entry_size=$(cubs_vendor_boot_u32_le_at "$path" 2120)
  bootconfig_size=$(cubs_vendor_boot_u32_le_at "$path" 2124)

  (( header_version == 4 && page_size == 2048 && header_size == 2128 && \
     original_size % page_size == 0 )) || \
    die "cubs vendor_boot does not use the canonical v4/2048-byte-page header"
  (( vendor_ramdisk_size > 0 && vendor_ramdisk_size <= original_size )) || \
    die "cubs vendor_boot has an empty or structurally impossible vendor ramdisk"
  (( dtb_size <= original_size )) || \
    die "cubs vendor_boot declares a structurally impossible DTB"
  (( entry_count == 1 && entry_size == 108 && table_size == entry_size )) || \
    die "cubs vendor_boot must have exactly one canonical v4 ramdisk-table entry"
  (( bootconfig_size > 0 && bootconfig_size <= original_size )) || \
    die "cubs vendor_boot has an empty or structurally impossible bootconfig"

  ramdisk_offset=$(cubs_vendor_boot_align_up "$header_size" "$page_size")
  ramdisk_end=$((ramdisk_offset + vendor_ramdisk_size))
  dtb_offset=$((
    ramdisk_offset +
    $(cubs_vendor_boot_align_up "$vendor_ramdisk_size" "$page_size")
  ))
  dtb_end=$((dtb_offset + dtb_size))
  table_offset=$((
    dtb_offset + $(cubs_vendor_boot_align_up "$dtb_size" "$page_size")
  ))
  table_end=$((table_offset + table_size))
  bootconfig_offset=$((
    table_offset + $(cubs_vendor_boot_align_up "$table_size" "$page_size")
  ))
  payload_end=$((bootconfig_offset + bootconfig_size))
  (( ramdisk_offset >= header_size && dtb_offset >= ramdisk_offset && \
     ramdisk_end <= dtb_offset && table_offset >= dtb_offset && \
     dtb_end <= table_offset && table_end <= original_size && \
     bootconfig_offset >= table_end && payload_end <= original_size )) || \
    die "cubs vendor_boot section layout escapes its AVB-authenticated payload"
  expected_original_size=$(cubs_vendor_boot_align_up "$payload_end" "$page_size")
  (( original_size == expected_original_size )) || \
    die "cubs vendor_boot AVB original size does not tightly bound its v4 payload"

  entry_ramdisk_size=$(cubs_vendor_boot_u32_le_at "$path" "$table_offset")
  entry_ramdisk_offset=$(cubs_vendor_boot_u32_le_at \
    "$path" "$((table_offset + 4))")
  entry_type=$(cubs_vendor_boot_u32_le_at "$path" "$((table_offset + 8))")
  (( entry_ramdisk_size == vendor_ramdisk_size && \
     entry_ramdisk_offset == 0 && entry_type == 1 )) || \
    die "cubs vendor_boot ramdisk table is not one complete platform fragment"
  name_hex=$(cubs_vendor_boot_hex_at "$path" "$((table_offset + 12))" 32)
  [[ "$name_hex" == "$(printf '00%.0s' {1..32})" ]] || \
    die "cubs vendor_boot platform fragment must have the canonical empty name"
  board_id_hex=$(cubs_vendor_boot_hex_at "$path" "$((table_offset + 44))" 64)
  [[ "$board_id_hex" == "$(printf '00%.0s' {1..64})" ]] || \
    die "cubs vendor_boot platform fragment must have the canonical all-zero board ID"

  cubs_vendor_boot_require_zero_range "$path" "$header_size" \
    "$((ramdisk_offset - header_size))" "header-alignment padding"
  cubs_vendor_boot_require_zero_range "$path" "$ramdisk_end" \
    "$((dtb_offset - ramdisk_end))" "ramdisk-alignment padding"
  cubs_vendor_boot_require_zero_range "$path" "$dtb_end" \
    "$((table_offset - dtb_end))" "DTB-alignment padding"
  cubs_vendor_boot_require_zero_range "$path" "$table_end" \
    "$((bootconfig_offset - table_end))" "ramdisk-table padding"

  expected_bootconfig=$'androidboot.load_modules_parallel=performance\nandroidboot.boot_devices=3c2d0000.ufs\n'
  (( bootconfig_size == ${#expected_bootconfig} )) || \
    die "cubs vendor_boot bootconfig length differs from the required Pixel boot configuration"
  cmp -s \
    <(cubs_vendor_boot_bytes_at "$path" "$bootconfig_offset" "$bootconfig_size") \
    <(printf '%s' "$expected_bootconfig") || \
    die "cubs vendor_boot bootconfig does not select the pinned module-loading and UFS boot-device policy"

  cmdline_hex=$(cubs_vendor_boot_hex_at "$path" 28 2048)
  (( ${#cmdline_hex} == 4096 )) || \
    die "cubs vendor_boot command-line field is truncated"
  cmdline_payload_hex=
  for ((index = 0; index < ${#cmdline_hex}; index += 2)); do
    byte=${cmdline_hex:index:2}
    if [[ -z "$seen_nul" ]]; then
      if [[ "$byte" == 00 ]]; then
        seen_nul=1
      else
        case "$byte" in
          2[0-9a-f]|[3-6][0-9a-f]|7[0-9a-e]) ;;
          *) die "cubs vendor_boot command line contains a non-printable byte" ;;
        esac
        cmdline_payload_hex+=$byte
      fi
    elif [[ "$byte" != 00 ]]; then
      die "cubs vendor_boot command-line field has noncanonical NUL padding"
    fi
  done
  [[ -n "$seen_nul" && -n "$cmdline_payload_hex" ]] || \
    die "cubs vendor_boot command-line field is empty or not NUL terminated"
  cmdline=$(printf '%s' "$cmdline_payload_hex" | xxd -r -p)
  [[ -n "$cmdline" ]] || die "cubs vendor_boot has an empty kernel command line"
  remaining_cmdline=$cmdline
  while [[ "$remaining_cmdline" == *android_arch_task_struct_size=* ]]; do
    ((task_assignment_count += 1))
    remaining_cmdline=${remaining_cmdline#*android_arch_task_struct_size=}
  done
  read -r -a cmdline_tokens <<<"$cmdline"
  for token in "${cmdline_tokens[@]}"; do
    [[ "$token" == bootconfig ]] && ((bootconfig_count += 1))
    if [[ "$token" == android_arch_task_struct_size=* ]]; then
      ((task_size_count += 1))
      [[ "$token" == android_arch_task_struct_size=784 ]] && \
        ((exact_task_size_count += 1))
    fi
  done
  (( bootconfig_count >= 1 && task_assignment_count == 1 && \
     task_size_count == 1 && \
     exact_task_size_count == 1 )) || \
    die "cubs vendor_boot command line lacks its required bootconfig or stock-kernel ABI token"

  cubs_vendor_boot_require_zero_range "$path" "$payload_end" \
    "$((original_size - payload_end))" "post-bootconfig alignment padding"
}
