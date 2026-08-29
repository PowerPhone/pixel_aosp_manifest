#!/usr/bin/env bash
set -euo pipefail

# Exact protocol mock for the direct physical-B preparation and its one-shot
# fastbootd-only trial. It rejects every mutation outside that narrow surface.

state_dir=${MOCK_STOCK_B_STATE_DIR:?set MOCK_STOCK_B_STATE_DIR}
log_file=${MOCK_STOCK_B_LOG:?set MOCK_STOCK_B_LOG}
serial=${MOCK_STOCK_B_SERIAL:-MOCK_CUBS_SERIAL}
mkdir -p "$state_dir"

die() {
  printf 'mock-stock-b-fastboot error: %s\n' "$*" >&2
  exit 1
}

read_state() {
  local key=$1 default=$2
  if [[ -f "$state_dir/$key" ]]; then
    sed -n '1p' "$state_dir/$key"
  else
    printf '%s\n' "$default"
  fi
}

write_state() {
  local key=$1 value=$2
  [[ "$key" =~ ^[a-z0-9_]+$ ]] || die "unsafe state key: $key"
  printf '%s\n' "$value" >"$state_dir/$key"
}

log_command() {
  printf '%s\n' "$*" >>"$log_file"
}

physical_partitions=(
  abl bl31 cap cpm dbc dbl
  dram_init_0 dram_init_1 dram_init_2 dram_init_3
  dram_init_4 dram_init_5 dram_init_6 dram_init_7
  dram_init_8 dram_init_9 dram_init_10 dram_init_11
  dram_phy gc gdmc gsa_bl1 gsa_fw tzsw modem
  boot init_boot dtbo vendor_boot vendor_kernel_boot pvmfw
  vbmeta_system vbmeta_vendor vbmeta
)

physical_base() {
  local candidate=$1 partition
  for partition in "${physical_partitions[@]}"; do
    [[ "$candidate" != "$partition" ]] || return 0
  done
  return 1
}

logical_base() {
  [[ "$1" =~ ^(system|system_dlkm|system_ext|product|vendor|vendor_dlkm)$ ]]
}

partition_base_and_slot() {
  local partition=$1
  case "$partition" in
    *_a) parsed_base=${partition%_a}; parsed_slot=a ;;
    *_b) parsed_base=${partition%_b}; parsed_slot=b ;;
    *) parsed_base=$partition; parsed_slot= ;;
  esac
}

if [[ ${1:-} == --version && $# -eq 1 ]]; then
  printf 'fastboot version 37.0.1-android-tools\n'
  exit 0
fi
if [[ ${1:-} == devices && $# -eq 1 ]]; then
  printf '%s\tfastboot\n' "$serial"
  exit 0
fi
if [[ ${1:-} == -s ]]; then
  [[ $# -ge 3 && $2 == "$serial" ]] || die "wrong or missing selected serial"
  shift 2
fi
[[ ${1:-} != --* ]] || die "fastboot options are forbidden in this workflow"

command_name=${1:-}
[[ -n "$command_name" ]] || die "missing command"
shift
mode=$(read_state mode bootloader)
current_slot=$(read_state current_slot a)

emit_getvar_response() {
  local variable=$1 value=$2 failure_reason=$3
  local alternate fault_mode fault_variable
  fault_variable=${MOCK_GETVAR_FAULT_VARIABLE:-}
  fault_mode=${MOCK_GETVAR_FAULT_MODE:-}

  if [[ "$variable" == "$fault_variable" ]]; then
    case "$fault_mode" in
      duplicate_value)
        [[ -n "$value" && -z "$failure_reason" ]] || \
          die "duplicate_value requires a value response"
        printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
        printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
        return
        ;;
      contradictory_value)
        [[ -n "$value" && -z "$failure_reason" ]] || \
          die "contradictory_value requires a value response"
        alternate=injected-contradiction
        [[ "$value" != yes ]] || alternate=no
        [[ "$value" != no ]] || alternate=yes
        printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
        printf '(bootloader) %s: %s\n' "$variable" "$alternate" >&2
        return
        ;;
      value_and_failed)
        [[ -n "$value" && -z "$failure_reason" ]] || \
          die "value_and_failed requires a value response"
        printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
        printf "getvar:%-48sFAILED (remote: 'Injected failure')\n" \
          "$variable" >&2
        return
        ;;
      nonzero_value)
        [[ -n "$value" && -z "$failure_reason" ]] || \
          die "nonzero_value requires a value response"
        printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
        exit 1
        ;;
      malformed_value)
        [[ -n "$value" && -z "$failure_reason" ]] || \
          die "malformed_value requires a value response"
        printf '(bootloader) injected-other-variable: %s\n' "$value" >&2
        return
        ;;
      wrong_value)
        [[ -n "$value" && -z "$failure_reason" ]] || \
          die "wrong_value requires a value response"
        printf '(bootloader) %s: no\n' "$variable" >&2
        return
        ;;
      is_logical_no)
        [[ "$variable" == is-logical:*_a && -n "$value" && \
           -z "$failure_reason" ]] || \
          die "is_logical_no requires an explicit A logical value response"
        printf '(bootloader) %s: no\n' "$variable" >&2
        return
        ;;
      absence_status_two)
        [[ -z "$value" && -n "$failure_reason" ]] || \
          die "absence_status_two requires an absent response"
        printf "getvar:%-48sFAILED (remote: '%s')\n" \
          "$variable" "$failure_reason" >&2
        exit 2
        ;;
      '') ;;
      *) die "unsupported getvar fault mode: $fault_mode" ;;
    esac
  fi

  if [[ -n "$failure_reason" ]]; then
    printf "getvar:%-48sFAILED (remote: '%s')\n" \
      "$variable" "$failure_reason" >&2
    if [[ ${MOCK_EXTRA_GETVAR_FAILURE:-0} == 1 ]]; then
      printf "getvar:%-48sFAILED (remote: 'Injected extra failure')\n" \
        unexpected >&2
    fi
    [[ ${MOCK_ABSENT_GETVAR_STATUS_ONE:-0} != 1 ]] || exit 1
  else
    printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
  fi
}

case "$command_name" in
  getvar)
    [[ $# -eq 1 ]] || die "malformed getvar"
    variable=$1
    value=
    failure_reason=
    case "$variable" in
      product) value=cubs ;;
      version-bootloader) value=spacecraft-17.4-15938155 ;;
      version-baseband) value=a900a-MP_260716-260716-M-15880348 ;;
      unlocked) value=yes ;;
      slot-count) value=2 ;;
      current-slot) value=$current_slot ;;
      snapshot-update-status) value=none ;;
      battery-soc) value=100% ;;
      is-userspace)
        if [[ "$mode" == fastbootd ]]; then value=yes; else value=no; fi
        ;;
      slot-successful:a)
        [[ "$mode" == bootloader ]] || \
          die "slot-successful must not be queried inside fastbootd"
        value=yes
        ;;
      slot-successful:b)
        [[ "$mode" == bootloader ]] || \
          die "slot-successful must not be queried inside fastbootd"
        value=$(read_state slot_b_successful no)
        ;;
      slot-unbootable:a) value=no ;;
      slot-unbootable:b) value=$(read_state slot_b_unbootable yes) ;;
      has-slot:*)
        partition=${variable#has-slot:}
        if physical_base "$partition"; then
          value=yes
        elif logical_base "$partition"; then
          [[ "$mode" == fastbootd ]] || \
            die "logical base has-slot must only be queried inside fastbootd"
          value=no
        elif [[ "$partition" == super ]]; then
          [[ "$mode" == fastbootd ]] || \
            die "super has-slot must only be queried inside fastbootd"
          value=no
        fi
        ;;
      is-logical:*)
        partition=${variable#is-logical:}
        partition_base_and_slot "$partition"
        if [[ "$mode" == fastbootd && "$parsed_slot" == a ]] && \
             logical_base "$parsed_base"; then
          value=yes
        elif [[ -n "$parsed_slot" ]] && physical_base "$parsed_base"; then
          value=no
        elif [[ "$mode" == fastbootd ]] && \
             logical_base "$parsed_base"; then
          failure_reason='Partition not found'
        fi
        ;;
      partition-size:*)
        partition=${variable#partition-size:}
        partition_base_and_slot "$partition"
        if [[ -n "$parsed_slot" ]] && physical_base "$parsed_base"; then
          if [[ "$mode" == fastbootd ]]; then
            write_state fastbootd_physical_size_probe "$partition"
            die "physical partition-size must not be queried inside fastbootd"
          fi
          value=$(read_state "size_${parsed_base}_${parsed_slot}" '')
        elif [[ "$mode" == fastbootd && "$parsed_slot" == a ]] && \
               logical_base "$parsed_base"; then
          value=$(read_state "size_${parsed_base}_${parsed_slot}" '')
        elif [[ "$mode" == fastbootd ]] && \
             logical_base "$parsed_base"; then
          failure_reason='Could not open partition'
        fi
        ;;
    esac
    emit_getvar_response "$variable" "$value" "$failure_reason"
    ;;
  flash)
    [[ $# -eq 2 ]] || die "malformed flash"
    partition=$1
    image=$2
    partition_base_and_slot "$partition"
    [[ "$mode" == bootloader && "$current_slot" == a ]] || \
      die "physical-B flash requires current A bootloader fastboot"
    [[ "$parsed_slot" == b ]] || die "flash is not an explicit slot-B target"
    physical_base "$parsed_base" || die "flash outside physical-B allowlist"
    [[ -f "$image" && ! -L "$image" && -s "$image" ]] || \
      die "unsafe mock source image"
    [[ $(basename -- "$image") == "$parsed_base.img" ]] || \
      die "source basename does not match target partition"
    count=$(read_state flash_count 0)
    [[ "$count" =~ ^[0-9]+$ && "$count" -lt 34 ]] || \
      die "too many physical-B flash commands"
    [[ "$parsed_base" == "${physical_partitions[$count]}" ]] || \
      die "physical-B flash is out of canonical order"
    [[ ! -e "$state_dir/flashed_$parsed_base" ]] || \
      die "duplicate physical-B flash"
    write_state "flashed_$parsed_base" yes
    write_state flash_count "$((count + 1))"
    if [[ "$parsed_base" == vendor_boot ]]; then
      cp -- "$image" "$state_dir/vendor_boot_bytes"
    fi
    log_command "flash $partition"
    ;;
  fetch)
    [[ $# -eq 2 && $1 == vendor_boot_b ]] || \
      die "only vendor_boot_b fetch is allowed"
    [[ "$mode" == bootloader && $(read_state flash_count 0) == 34 ]] || \
      die "vendor_boot_b fetch occurred at the wrong transaction stage"
    destination=$2
    source="$state_dir/vendor_boot_bytes"
    [[ -f "$source" && ! -e "$destination" && ! -L "$destination" ]] || \
      die "unsafe vendor_boot_b fetch input or destination"
    cp -- "$source" "$destination"
    if [[ "$current_slot" == a ]]; then
      write_state vendor_boot_fetched yes
      log_command 'fetch vendor_boot_b'
    else
      count=$(read_state post_activation_fetch_count 0)
      write_state post_activation_fetch_count "$((count + 1))"
    fi
    ;;
  set_active)
    [[ $# -eq 1 ]] || die "malformed slot selection"
    case "$1" in
      b)
        [[ "$mode" == bootloader && "$current_slot" == a && \
           $(read_state flash_count 0) == 34 && \
           $(read_state vendor_boot_fetched no) == yes ]] || \
          die "slot B was selected before the exact preparation completed"
        write_state current_slot b
        write_state slot_b_successful no
        write_state slot_b_unbootable no
        log_command 'set_active b'
        ;;
      a)
        [[ "$mode" == bootloader && "$current_slot" == b ]] || \
          die "conservative trial abort did not start from B bootloader"
        write_state current_slot a
        log_command 'set_active a'
        [[ "${MOCK_FAIL_AFTER_SET_ACTIVE_A:-0}" != 1 ]] || \
          die "injected host failure after set_active a took effect"
        ;;
      *) die "slot selection outside exact direct-workflow allowlist" ;;
    esac
    ;;
  reboot)
    [[ $# -eq 1 ]] || die "malformed reboot"
    case "$1" in
      fastboot)
        [[ "$mode" == bootloader && "$current_slot" == b ]] || \
          die "fastbootd trial did not start from prepared current B"
        [[ "${MOCK_FAIL_BEFORE_REBOOT_FASTBOOT:-0}" != 1 ]] || \
          die "injected host failure before entering fastbootd"
        write_state mode fastbootd
        log_command 'reboot fastboot'
        [[ "${MOCK_FAIL_AFTER_REBOOT_FASTBOOT:-0}" != 1 ]] || \
          die "injected USB failure after entering fastbootd"
        ;;
      bootloader)
        [[ "$mode" == fastbootd && "$current_slot" == b ]] || \
          die "bootloader return did not start from B fastbootd"
        write_state mode bootloader
        log_command 'reboot bootloader'
        [[ "${MOCK_FAIL_AFTER_REBOOT_BOOTLOADER:-0}" != 1 ]] || \
          die "injected USB failure after returning to bootloader"
        ;;
      *) die "forbidden reboot target: $1" ;;
    esac
    ;;
  update|flashall|erase|resize-logical-partition)
    die "forbidden mutating command: $command_name"
    ;;
  *) die "unsupported command: $command_name" ;;
esac
