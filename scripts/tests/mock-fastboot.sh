#!/usr/bin/env bash
set -euo pipefail

# Shared host-only fastboot protocol mock for flash/restore simulations. It
# models the current-selector fastbootd cache and rejects every physical-B or
# non-allowlisted mutation.

state_dir=${MOCK_FASTBOOT_STATE_DIR:?set MOCK_FASTBOOT_STATE_DIR}
log_file=${MOCK_FASTBOOT_LOG:?set MOCK_FASTBOOT_LOG}
serial=${MOCK_FASTBOOT_SERIAL:-MOCK_CUBS_SERIAL}
mkdir -p "$state_dir"

die() {
  printf 'mock-fastboot error: %s\n' "$*" >&2
  exit 1
}

read_state() {
  local key=$1
  local default=$2
  local path="$state_dir/$key"
  if [[ -f "$path" ]]; then
    sed -n '1p' "$path"
  else
    printf '%s\n' "$default"
  fi
}

write_state() {
  local key=$1
  local value=$2
  [[ "$key" =~ ^[a-z0-9_]+$ ]] || die "unsafe state key: $key"
  printf '%s\n' "$value" >"$state_dir/$key"
}

log_mutation() {
  local mutation_count fail_after
  printf '%s\n' "$*" >>"$log_file"
  mutation_count=$(read_state mutation_count 0)
  [[ "$mutation_count" =~ ^[0-9]+$ ]] || die "invalid mutation counter"
  mutation_count=$((mutation_count + 1))
  write_state mutation_count "$mutation_count"
  fail_after=${MOCK_FAIL_AFTER_MUTATION:-}
  if [[ -n "$fail_after" ]]; then
    [[ "$fail_after" =~ ^[1-9][0-9]*$ ]] || \
      die "invalid MOCK_FAIL_AFTER_MUTATION"
    if (( mutation_count == fail_after )); then
      die "injected failure after mutation $mutation_count"
    fi
  fi
}

if [[ ${1:-} == --version ]]; then
  printf 'fastboot version 37.0.1-android-tools\n'
  exit 0
fi
if [[ ${1:-} == devices && $# -eq 1 ]]; then
  printf '%s\tfastboot\n' "$serial"
  exit 0
fi

if [[ ${1:-} == -s ]]; then
  [[ $# -ge 3 ]] || die "missing selected serial or command"
  [[ $2 == "$serial" ]] || die "unexpected selected serial: $2"
  shift 2
fi

disable_verity=
disable_verification=
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --disable-verity)
      disable_verity=1
      ;;
    --disable-verification)
      disable_verification=1
      ;;
    --slot|--slot=*)
      die "slot override is forbidden in the reviewed workflow"
      ;;
    *)
      die "unexpected option: $1"
      ;;
  esac
  shift
done

mode=$(read_state mode bootloader)
current_slot=$(read_state current_slot b)
compound_selected_slot=

logical_base() {
  case "$1" in
    system|system_dlkm|system_ext|product|vendor|vendor_dlkm) return 0 ;;
    *) return 1 ;;
  esac
}

physical_base() {
  case "$1" in
    abl|bl31|cap|cpm|dbc|dbl|dram_init_0|dram_init_1|dram_init_2|\
    dram_init_3|dram_init_4|dram_init_5|dram_init_6|dram_init_7|\
    dram_init_8|dram_init_9|dram_init_10|dram_init_11|dram_phy|gc|gdmc|\
    gsa_bl1|gsa_fw|tzsw|modem|\
    boot|init_boot|dtbo|vendor_boot|vendor_kernel_boot|pvmfw|\
    vbmeta_system|vbmeta_vendor|vbmeta) return 0 ;;
    *) return 1 ;;
  esac
}

firmware_base() {
  case "$1" in
    abl|bl31|cap|cpm|dbc|dbl|dram_init_0|dram_init_1|dram_init_2|\
    dram_init_3|dram_init_4|dram_init_5|dram_init_6|dram_init_7|\
    dram_init_8|dram_init_9|dram_init_10|dram_init_11|dram_phy|gc|gdmc|\
    gsa_bl1|gsa_fw|tzsw|modem) return 0 ;;
    *) return 1 ;;
  esac
}

partition_base_and_slot() {
  local partition=$1
  case "$partition" in
    *_a)
      parsed_base=${partition%_a}
      parsed_slot=a
      ;;
    *_b)
      parsed_base=${partition%_b}
      parsed_slot=b
      ;;
    *)
      parsed_base=$partition
      parsed_slot=
      ;;
  esac
}

selected_logical_namespace() {
  if [[ "$mode" == fastbootd ]]; then
    read_state daemon_namespace "$current_slot"
  else
    read_state "metadata_namespace_$current_slot" "$current_slot"
  fi
}

set_mock_present_response() {
  case "${MOCK_LOGICAL_PRESENT_RESPONSE:-exact}" in
    exact) value=yes ;;
    no) value=no ;;
    malformed) value=present ;;
    duplicate) getvar_failure=duplicate_yes ;;
    contradictory) getvar_failure=contradictory_boolean ;;
    yes_with_failed) getvar_failure=yes_with_failed ;;
    *) die "invalid MOCK_LOGICAL_PRESENT_RESPONSE" ;;
  esac
}

require_flash_transaction_state() {
  local expected=$1 transaction state
  [[ -n "${MOCK_RECOVERY_STATE_DIR:-}" ]] || return 0
  transaction="$MOCK_RECOVERY_STATE_DIR/slot-a-flash-transaction"
  [[ -f "$transaction" && ! -L "$transaction" ]] || \
    die "slot-A mutation has no transaction journal"
  state=$(sed -n 's/^state=//p' "$transaction")
  [[ "$state" =~ $expected ]] || \
    die "slot-A mutation is not journaled in an allowed state: ${state:-missing}"
}

logical_image_expanded_size() {
  local image=$1 magic block_size total_blocks
  magic=$(od -An -N4 -j0 -tu4 -- "$image" | tr -d '[:space:]')
  if [[ "$magic" == 3978755898 ]]; then
    block_size=$(od -An -N4 -j12 -tu4 -- "$image" | tr -d '[:space:]')
    total_blocks=$(od -An -N4 -j16 -tu4 -- "$image" | tr -d '[:space:]')
    printf '%s\n' "$((10#$block_size * 10#$total_blocks))"
  else
    stat -c '%s' "$image"
  fi
}

while (( $# > 0 )); do
command_name=$1
shift
case "$command_name" in
  getvar)
    (( $# >= 1 )) || die "malformed getvar"
    variable=$1
    shift
    value=
    getvar_status=0
    getvar_failure=
    case "$variable" in
      product) value=cubs ;;
      version-bootloader) value=spacecraft-17.4-15938155 ;;
      version-baseband) value=a900a-MP_260716-260716-M-15880348 ;;
      unlocked) value=yes ;;
      slot-count) value=2 ;;
      snapshot-update-status) value=none ;;
      battery-soc) value=100% ;;
      current-slot) value=$current_slot ;;
      is-userspace)
        if [[ "$mode" == fastbootd ]]; then value=yes; else value=no; fi
        ;;
      slot-successful:a) value=$(read_state slot_a_successful yes) ;;
      slot-successful:b) value=$(read_state slot_b_successful yes) ;;
      slot-unbootable:a) value=$(read_state slot_a_unbootable no) ;;
      slot-unbootable:b) value=$(read_state slot_b_unbootable no) ;;
      has-slot:*)
        partition=${variable#has-slot:}
        if firmware_base "$partition"; then
          write_state "proved_has_slot_$partition" yes
          value=yes
        elif logical_base "$partition"; then
          if [[ "$mode" == fastbootd ]]; then
            case "${MOCK_LOGICAL_HAS_SLOT_RESPONSE:-auto}" in
              auto)
                if [[ $(selected_logical_namespace) == b ]]; then
                  value=yes
                else
                  value=no
                fi
                ;;
              yes|no) value=$MOCK_LOGICAL_HAS_SLOT_RESPONSE ;;
              mixed)
                if [[ "$partition" == system ]]; then value=yes; else value=no; fi
                ;;
              duplicate) getvar_failure=duplicate_yes ;;
              contradictory) getvar_failure=contradictory_boolean ;;
              yes_with_failed) getvar_failure=yes_with_failed ;;
              malformed) value=present ;;
              *) die "invalid MOCK_LOGICAL_HAS_SLOT_RESPONSE" ;;
            esac
          else
            value=yes
          fi
        elif physical_base "$partition"; then
          value=yes
        elif [[ "$partition" == userdata || "$partition" == metadata ]]; then
          value=no
        fi
        ;;
      is-logical:*)
        partition=${variable#is-logical:}
        partition_base_and_slot "$partition"
        namespace=$(selected_logical_namespace)
        if [[ -n "$parsed_slot" ]] && physical_base "$parsed_base"; then
          value=no
        elif [[ "$mode" == fastbootd && -z "$parsed_slot" ]] && \
            logical_base "$parsed_base"; then
          case "${MOCK_UNSUFFIXED_LOGICAL_RESPONSE:-absent}" in
            absent)
              getvar_status=1
              getvar_failure=partition_not_found
              ;;
            present) value=yes ;;
            present_in_b)
              if [[ "$namespace" == b ]]; then
                value=yes
              else
                getvar_status=1
                getvar_failure=partition_not_found
              fi
              ;;
            no) value=no ;;
            *) die "invalid MOCK_UNSUFFIXED_LOGICAL_RESPONSE" ;;
          esac
        elif [[ "$mode" == fastbootd && \
                "${MOCK_NAMESPACE_MODE:-}" == both_absent && \
                -n "$parsed_slot" ]] && logical_base "$parsed_base"; then
          getvar_status=1
          getvar_failure=partition_not_found
        elif [[ "$mode" == fastbootd && \
                "${MOCK_NAMESPACE_MODE:-}" == both_present && \
                -n "$parsed_slot" ]] && logical_base "$parsed_base"; then
          set_mock_present_response
        elif [[ "$mode" == fastbootd && \
                "${MOCK_NAMESPACE_MODE:-}" == mixed && \
                -n "$parsed_slot" ]] && logical_base "$parsed_base" && \
            { [[ "$parsed_slot" == "$namespace" ]] || \
              [[ "$partition" == vendor_b ]]; }; then
          set_mock_present_response
        elif [[ "$mode" == fastbootd && \
                "${MOCK_NAMESPACE_MODE:-}" == incomplete && \
                "$partition" == vendor_dlkm_a ]]; then
          getvar_status=1
          getvar_failure=partition_not_found
        elif [[ "$mode" == fastbootd && -n "$parsed_slot" ]] && \
            logical_base "$parsed_base" && \
            [[ "$parsed_slot" == "$namespace" ]]; then
          set_mock_present_response
        else
          getvar_status=1
          getvar_failure=partition_not_found
        fi
        ;;
      partition-size:*)
        partition=${variable#partition-size:}
        partition_base_and_slot "$partition"
        if [[ "$partition" == userdata || "$partition" == metadata ]]; then
          value=0x4000000
        elif [[ "$mode" == fastbootd && -n "$parsed_slot" ]] && \
            logical_base "$parsed_base" && \
            [[ "$parsed_slot" == "$(selected_logical_namespace)" ]]; then
          value=$(read_state "size_${parsed_base}_${parsed_slot}" 0x200000)
          case "${MOCK_LOGICAL_SIZE_RESPONSE:-exact}" in
            exact) ;;
            duplicate) getvar_failure=duplicate_value ;;
            contradictory) getvar_failure=contradictory_size ;;
            malformed) value=0xnot_hex ;;
            unprefixed) value=${value#0x} ;;
            value_with_failed) getvar_failure=value_with_failed ;;
            nonzero_status) getvar_failure=value_nonzero_status ;;
            *) die "invalid MOCK_LOGICAL_SIZE_RESPONSE" ;;
          esac
        elif [[ "$mode" == fastbootd && -n "$parsed_slot" ]] && \
            physical_base "$parsed_base"; then
          # Real Platform-Tools 37 returns this exact remote failure with
          # status zero for physical partition sizes in cubs fastbootd.
          physical_probe_count=$(read_state \
            fastbootd_physical_size_probe_count 0)
          [[ "$physical_probe_count" =~ ^[0-9]+$ ]] || \
            die "invalid fastbootd physical-size probe counter"
          write_state fastbootd_physical_size_probe_count \
            "$((physical_probe_count + 1))"
          getvar_failure=could_not_open_partition
        elif [[ -n "$parsed_slot" ]] && firmware_base "$parsed_base"; then
          write_state "proved_size_${parsed_base}_${parsed_slot}" yes
          value=$(read_state "size_${parsed_base}_${parsed_slot}" 0x4000000)
        elif [[ -n "$parsed_slot" ]] && physical_base "$parsed_base"; then
          value=$(read_state "size_${parsed_base}_${parsed_slot}" 0x4000000)
        fi
        ;;
    esac
    if [[ "$getvar_failure" == duplicate_yes ]]; then
      printf '(bootloader) %s: yes\n' "$variable" >&2
      printf '(bootloader) %s: yes\n' "$variable" >&2
      exit 0
    elif [[ "$getvar_failure" == contradictory_boolean ]]; then
      printf '(bootloader) %s: yes\n' "$variable" >&2
      printf '(bootloader) %s: no\n' "$variable" >&2
      exit 0
    elif [[ "$getvar_failure" == yes_with_failed ]]; then
      printf '(bootloader) %s: yes\n' "$variable" >&2
      printf "getvar:%-42s FAILED (remote: 'mock contradictory response')\n" \
        "$variable" >&2
      exit 0
    elif [[ "$getvar_failure" == duplicate_value ]]; then
      printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
      printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
      exit 0
    elif [[ "$getvar_failure" == contradictory_size ]]; then
      printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
      printf '(bootloader) %s: 0x1234\n' "$variable" >&2
      exit 0
    elif [[ "$getvar_failure" == value_with_failed ]]; then
      printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
      printf "getvar:%-42s FAILED (remote: 'mock contradictory response')\n" \
        "$variable" >&2
      exit 0
    elif [[ "$getvar_failure" == value_nonzero_status ]]; then
      printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
      exit 7
    elif [[ "$getvar_failure" == could_not_open_partition ]]; then
      printf "getvar:%-42s FAILED (remote: 'Could not open partition')\n" \
        "$variable" >&2
      exit 0
    elif [[ "$getvar_failure" == partition_not_found ]]; then
      case "${MOCK_ABSENT_LOGICAL_RESPONSE:-exact}" in
        exact)
          printf "getvar:%-42s FAILED (remote: 'Partition not found')\n" \
            "$variable" >&2
          ;;
        generic)
          printf "getvar:%-42s FAILED (remote: 'mock absent logical')\n" \
            "$variable" >&2
          ;;
        duplicate)
          printf "getvar:%-42s FAILED (remote: 'Partition not found')\n" \
            "$variable" >&2
          printf "getvar:%-42s FAILED (remote: 'Partition not found')\n" \
            "$variable" >&2
          ;;
        no)
          printf '(bootloader) %s: no\n' "$variable" >&2
          exit 0
          ;;
        value_with_failed)
          printf '(bootloader) %s: no\n' "$variable" >&2
          printf "getvar:%-42s FAILED (remote: 'Partition not found')\n" \
            "$variable" >&2
          exit 0
          ;;
        empty)
          ;;
        *)
          die "invalid MOCK_ABSENT_LOGICAL_RESPONSE"
          ;;
      esac
      if [[ -n "${MOCK_ABSENT_LOGICAL_EXIT_STATUS:-}" ]]; then
        [[ "$MOCK_ABSENT_LOGICAL_EXIT_STATUS" =~ ^[0-9]+$ && \
           "$MOCK_ABSENT_LOGICAL_EXIT_STATUS" -le 125 ]] || \
          die "invalid MOCK_ABSENT_LOGICAL_EXIT_STATUS"
        exit "$MOCK_ABSENT_LOGICAL_EXIT_STATUS"
      fi
      if [[ "${MOCK_ABSENT_LOGICAL_STATUS_ZERO:-1}" == 1 ]]; then
        exit 0
      fi
      exit "$getvar_status"
    elif (( getvar_status == 0 )); then
      printf '(bootloader) %s: %s\n' "$variable" "$value" >&2
    else
      printf "FAILED (remote: 'mock getvar failure')\n" >&2
      exit 1
    fi
    ;;
  reboot)
    (( $# >= 1 )) || die "malformed reboot"
    reboot_target=$1
    shift
    case "$reboot_target" in
      fastboot)
        [[ "$mode" == bootloader ]] || die "fastbootd entry did not start in bootloader"
        require_flash_transaction_state \
          '^(enter_a_fastbootd_pending|logical_writes_pending)$'
        write_state mode fastbootd
        write_state fastboot_entry_slot "$current_slot"
        write_state daemon_namespace \
          "$(read_state "metadata_namespace_$current_slot" "$current_slot")"
        mode=fastbootd
        log_mutation 'reboot fastboot'
        ;;
      bootloader)
        [[ "$mode" == fastbootd ]] || die "bootloader return did not start in fastbootd"
        require_flash_transaction_state \
          '^(return_a_bootloader_pending|post_logicals_a_bootloader|activate_a_pending|awaiting_runtime|abort_return_bootloader_pending|aborted_for_restore)$'
        write_state mode bootloader
        mode=bootloader
        if [[ "${MOCK_DRIFT_PHYSICAL_B_AFTER_BOOTLOADER_RETURN:-}" == 1 ]]; then
          write_state size_boot_b 0x4100000
        fi
        log_mutation 'reboot bootloader'
        ;;
      *) die "forbidden reboot target: $reboot_target" ;;
    esac
    ;;
  fetch)
    (( $# >= 2 )) && [[ "$1" =~ ^vendor_boot_(a|b)$ ]] || \
      die "only explicit vendor_boot_a/b fetch is allowed"
    [[ "$mode" == bootloader ]] || die "vendor_boot fetch outside bootloader"
    fetch_slot=${1##*_}
    if [[ "$fetch_slot" == a && -n "${MOCK_VENDOR_BOOT_A_IMAGE:-}" ]]; then
      source_image=$MOCK_VENDOR_BOOT_A_IMAGE
    else
      source_image=${MOCK_VENDOR_BOOT_IMAGE:?set MOCK_VENDOR_BOOT_IMAGE for fetch}
    fi
    destination=$2
    shift 2
    [[ -f "$source_image" && ! -L "$source_image" && \
       ! -e "$destination" && ! -L "$destination" ]] || \
      die "unsafe vendor_boot fetch source or destination"
    cp -- "$source_image" "$destination"
    fetch_count=$(read_state vendor_boot_fetch_count 0)
    [[ "$fetch_count" =~ ^[0-9]+$ ]] || die "invalid vendor_boot fetch counter"
    write_state vendor_boot_fetch_count "$((fetch_count + 1))"
    fetch_count=$(read_state "vendor_boot_${fetch_slot}_fetch_count" 0)
    [[ "$fetch_count" =~ ^[0-9]+$ ]] || die "invalid per-slot fetch counter"
    write_state "vendor_boot_${fetch_slot}_fetch_count" \
      "$((fetch_count + 1))"
    ;;
  resize-logical-partition)
    (( $# >= 2 )) || die "malformed logical resize"
    [[ "$mode" == fastbootd ]] || die "logical resize outside fastbootd"
    require_flash_transaction_state '^logical_writes_pending$'
    partition=$1
    size=$2
    shift 2
    partition_base_and_slot "$partition"
    [[ "$parsed_slot" == a ]] || \
      die "logical resize is not an explicit slot-A target: $partition"
    namespace=$(selected_logical_namespace)
    [[ "$parsed_slot" == "$namespace" || \
       "$parsed_slot" == "$compound_selected_slot" ]] || \
      die "logical resize is outside the selected metadata namespace: $partition"
    logical_base "$parsed_base" || die "logical resize outside allowlist: $partition"
    [[ "$size" == 0 ]] || die "simulation permits only resize-to-zero preparation"
    write_state "size_${parsed_base}_${parsed_slot}" 0x0
    write_state metadata_namespace_a "$parsed_slot"
    write_state metadata_namespace_b "$parsed_slot"
    write_state daemon_namespace "$parsed_slot"
    write_state metadata_fanned_out yes
    log_mutation "resize $partition 0"
    ;;
  flash)
    (( $# >= 2 )) || die "malformed flash"
    partition=$1
    image=$2
    shift 2
    [[ -f "$image" && -s "$image" ]] || die "missing mock image: $image"
    partition_base_and_slot "$partition"
    [[ "$parsed_slot" == a ]] || die "flash is not explicit slot A: $partition"
    if logical_base "$parsed_base"; then
      [[ "$mode" == fastbootd ]] || die "logical flash outside fastbootd: $partition"
      require_flash_transaction_state '^logical_writes_pending$'
      [[ "$parsed_slot" == "$(selected_logical_namespace)" || \
         "$parsed_slot" == "$compound_selected_slot" ]] || \
        die "logical flash is outside the selected metadata namespace: $partition"
      [[ -z "$disable_verity" && -z "$disable_verification" ]] || \
        die "verification flags used on logical image"
      expanded_size=$(logical_image_expanded_size "$image")
      write_state "size_${parsed_base}_${parsed_slot}" \
        "$(printf '0x%x' "$expanded_size")"
      write_state metadata_namespace_a "$parsed_slot"
      write_state metadata_namespace_b "$parsed_slot"
      write_state daemon_namespace "$parsed_slot"
    elif physical_base "$parsed_base"; then
      [[ "$mode" == bootloader ]] || die "physical flash outside bootloader: $partition"
      require_flash_transaction_state '^post_logicals_a_bootloader$'
      if firmware_base "$parsed_base"; then
        write_state "flashed_${parsed_base}_a" yes
      fi
      if [[ "$parsed_base" != vbmeta ]]; then
        [[ -z "$disable_verity" && -z "$disable_verification" ]] || \
          die "verification flags used outside root vbmeta"
      fi
    else
      die "flash outside exact partition allowlist: $partition"
    fi
    if [[ -n "$disable_verity" || -n "$disable_verification" ]]; then
      log_mutation "flash $partition disable-verity disable-verification"
    else
      log_mutation "flash $partition"
    fi
    ;;
  erase)
    (( $# >= 1 )) || die "malformed erase"
    partition=$1
    shift
    case "$partition" in
      userdata|metadata)
        [[ "$mode" == bootloader ]] || die "$partition erase outside bootloader"
        require_flash_transaction_state '^post_logicals_a_bootloader$'
        ;;
      *) die "erase outside exact allowlist: $partition" ;;
    esac
    log_mutation "erase $partition"
    ;;
  set_active)
    (( $# >= 1 )) && [[ "$1" =~ ^(a|b)$ ]] || \
      die "invalid slot activation"
    activation_slot=$1
    shift
    [[ "$mode" =~ ^(bootloader|fastbootd)$ ]] || \
      die "slot activation outside fastboot transports"
    if [[ "$activation_slot" == a && "$mode" == bootloader ]]; then
      require_flash_transaction_state \
        '^(select_a_bootloader_pending|enter_a_fastbootd_pending|logical_writes_pending|return_a_bootloader_pending|post_logicals_a_bootloader|activate_a_pending)$'
    fi
    if [[ "$mode" == fastbootd ]]; then
      compound_selected_slot=$activation_slot
      write_state daemon_namespace "$activation_slot"
    fi
    case "$activation_slot" in
      a)
        if [[ -n "${MOCK_EXPECT_RECOVERY_HANDOFF:-}" ]]; then
          [[ -f "$MOCK_EXPECT_RECOVERY_HANDOFF/lifeboat-lineage" && \
             -f "$MOCK_EXPECT_RECOVERY_HANDOFF/flash-handoff" ]] || \
            die "restore invalidated lifeboat evidence before slot-A activation"
        fi
        write_state current_slot a
        current_slot=a
        if [[ "${MOCK_PRESERVE_SLOT_A_SUCCESSFUL:-}" != 1 ]]; then
          write_state slot_a_successful no
        fi
        write_state slot_a_unbootable no
        log_mutation 'set_active a'
        if [[ "${MOCK_FAIL_AFTER_SET_ACTIVE_A:-}" == 1 ]]; then
          die "injected host-visible failure after set_active A ACK"
        fi
        ;;
      b)
        [[ "${MOCK_ALLOW_SET_ACTIVE_B:-}" == 1 ]] || \
          die "slot-B activation is not allowed in this simulation"
        write_state current_slot b
        current_slot=b
        write_state slot_b_successful no
        write_state slot_b_unbootable no
        log_mutation 'set_active b'
        if [[ "${MOCK_FAIL_AFTER_SET_ACTIVE_B:-}" == 1 ]]; then
          die "injected host-visible failure after set_active B ACK"
        fi
        ;;
    esac
    ;;
  update|flashall)
    die "archive/aggregate update command is forbidden"
    ;;
  *)
    die "unexpected command: $command_name"
    ;;
esac
done
