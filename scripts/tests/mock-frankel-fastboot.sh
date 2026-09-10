#!/usr/bin/env bash
set -euo pipefail

state_dir=${MOCK_FRANKEL_FASTBOOT_STATE_DIR:?set MOCK_FRANKEL_FASTBOOT_STATE_DIR}
log_file=${MOCK_FRANKEL_FASTBOOT_LOG:?set MOCK_FRANKEL_FASTBOOT_LOG}
serial=${MOCK_FRANKEL_FASTBOOT_SERIAL:-MOCK_FRANKEL_SERIAL}

die() {
  printf 'mock-frankel-fastboot error: %s\n' "$*" >&2
  exit 1
}

read_mode() {
  if [[ -f "$state_dir/mode" ]]; then
    sed -n '1p' "$state_dir/mode"
  else
    printf 'bootloader\n'
  fi
}

write_mode() {
  printf '%s\n' "$1" >"$state_dir/mode"
}

if [[ ${1:-} == --version && $# -eq 1 ]]; then
  printf 'fastboot version 37.0.1-test\n'
  exit 0
fi
if [[ ${1:-} == devices && $# -eq 1 ]]; then
  printf '%s\tfastboot\n' "$serial"
  exit 0
fi

[[ ${1:-} == -s && $# -ge 3 ]] || die 'missing selected serial or command'
[[ $2 == "$serial" ]] || die "unexpected selected serial: $2"
shift 2

if [[ ${1:-} == devices && $# -eq 1 ]]; then
  printf '%s\tfastboot\n' "$serial"
  exit 0
fi

slot=
disable_verity=false
disable_verification=false
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --slot=a) slot=a ;;
    --disable-verity) disable_verity=true ;;
    --disable-verification) disable_verification=true ;;
    *) die "unexpected option: $1" ;;
  esac
  shift
done

mode=$(read_mode)
case ${1:-} in
  getvar)
    [[ $# -eq 2 ]] || die 'malformed getvar'
    name=$2
    case "$name" in
      product) value=frankel ;;
      unlocked) value=yes ;;
      is-userspace)
        [[ "$mode" == fastbootd ]] && value=yes || value=no
        ;;
      slot-count) value=2 ;;
      current-slot) value=a ;;
      version-bootloader) value=deepspace-17.2-15372054 ;;
      version-baseband) value=g5400i-260317-260429-B-15308590 ;;
      snapshot-update-status) value=none ;;
      has-slot:*) value=yes ;;
      partition-size:*) value=0x40000000 ;;
      is-logical:*) value=yes ;;
      *) die "unexpected getvar: $name" ;;
    esac
    printf '(bootloader) %s: %s\n' "$name" "$value"
    ;;
  reboot)
    [[ $# -le 2 ]] || die 'malformed reboot'
    case ${2:-android} in
      bootloader) write_mode bootloader ;;
      fastboot) write_mode fastbootd ;;
      android) write_mode android ;;
      *) die "unexpected reboot target: ${2:-}" ;;
    esac
    printf 'reboot %s\n' "${2:-android}" >>"$log_file"
    ;;
  resize-logical-partition)
    [[ "$mode" == fastbootd && $# -eq 3 && $3 == 0 ]] || \
      die 'invalid logical resize'
    printf 'resize %s 0\n' "$2" >>"$log_file"
    ;;
  flash)
    [[ $# -eq 3 && $slot == a && -f $3 && -s $3 ]] || \
      die 'invalid slot-A flash'
    partition=$2
    if [[ "$partition" == vbmeta ]]; then
      [[ "$mode" == bootloader && "$disable_verity" == true && \
         "$disable_verification" == true ]] || \
        die 'root vbmeta requires both disable flags in bootloader fastboot'
    else
      [[ "$disable_verity" == false && "$disable_verification" == false ]] || \
        die 'disable flags used outside root vbmeta'
    fi
    printf 'flash %s disable-verity=%s disable-verification=%s\n' \
      "$partition" "$disable_verity" "$disable_verification" >>"$log_file"
    ;;
  erase)
    [[ "$mode" == bootloader && $# -eq 2 && $2 =~ ^(userdata|metadata)$ ]] || \
      die 'invalid erase'
    printf 'erase %s\n' "$2" >>"$log_file"
    ;;
  set_active)
    [[ "$mode" == bootloader && $# -eq 2 && $2 == a ]] || \
      die 'invalid slot activation'
    printf 'set_active a\n' >>"$log_file"
    ;;
  *) die "unexpected command: ${1:-<empty>}" ;;
esac
