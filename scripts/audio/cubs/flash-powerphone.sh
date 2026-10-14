#!/usr/bin/env bash
# Standalone PowerPhone OS flasher; copied into the separate bundle as flash-all.sh.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
serial= bundle= platform_tools= flash=0 reboot=0 wipe=0 grow=0
[[ ! -f "$here/bundle-kind" ]] || bundle=$here
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' \
    'Usage: flash-all.sh --serial SERIAL [--bundle-dir DIR] [--platform-tools DIR] [--flash] [--grow-logical] [--reboot] [--wipe-userdata]' \
    'Default: local plan only, no device access. --flash authorizes the exact 14-image current-slot OS closure.' \
    '--reboot waits for exact Cubs ADB arrival, not boot/audio qualification.' \
    '--grow-logical permits current-slot logical growth to exact image bytes only; never shrink/delete or touch inactive logicals.' \
    '--wipe-userdata additionally erases userdata AND encryption metadata for ALL slots. Default preserves both.' \
    'Never flashes bootloader, radio/modem, pvmfw, a super image, inactive-slot images or slot-selection state.'
}
while (($#)); do
  case "$1" in
    --serial|--bundle-dir|--platform-tools)
      (($# >= 2)) || { usage; exit 2; }
      case "$1" in --serial) serial=$2;; --bundle-dir) bundle=$2;; --platform-tools) platform_tools=$2;; esac
      shift 2;;
    --flash) flash=1; shift;;
    --reboot) reboot=1; shift;;
    --grow-logical) grow=1; shift;;
    --wipe-userdata) wipe=1; shift;;
    -h|--help) usage; exit 0;;
    *) usage; die "unknown argument: $1";;
  esac
done
[[ "$serial" =~ ^[[:alnum:]][[:alnum:]_.:-]*$ && -d "$bundle" ]] || { usage; exit 2; }
((flash || !(reboot || wipe || grow))) || die '--reboot/--wipe-userdata/--grow-logical require --flash'
bundle=$(cd -- "$bundle" && pwd -P)
physical=(boot init_boot dtbo vendor_boot vendor_kernel_boot vbmeta_system vbmeta_vendor vbmeta)
logical=(system system_dlkm product vendor_dlkm system_ext vendor)
require_file() { [[ -f "$1" && ! -L "$1" && -r "$1" && -s "$1" ]] || die "missing/unsafe/empty input: $1"; }
for name in bundle-kind COMPLETE firmware-requirements.txt image-sizes.tsv; do require_file "$bundle/$name"; done
[[ "$(<"$bundle/bundle-kind")" = cubs-powerphone-captured-v1 ]] || die 'not the explicit Cubs PowerPhone flavor'
requirement() {
  local key=$1
  awk -F= -v key="$key" '$1 == key && NF == 2 { print $2; count++ } END { if (count != 1) exit 1 }' "$bundle/firmware-requirements.txt"
}
[[ "$(requirement product)" = cubs ]] || die 'bundle product is not Cubs'
expected_bootloader=$(requirement bootloader) || die 'missing bootloader prerequisite'
expected_baseband=$(requirement baseband) || die 'missing baseband prerequisite'
[[ "$expected_bootloader" =~ ^[A-Za-z0-9_.:-]+$ && "$expected_baseband" =~ ^[A-Za-z0-9_.:-]+$ ]] || die 'malformed firmware prerequisites'
declare -A expanded_sizes=() initial_logical_sizes=()
for name in "${physical[@]}" "${logical[@]}"; do
  image="$bundle/$name.img"
  require_file "$image"
  recorded=$(awk -F '\t' -v name="$name" '$1 == name && NF == 2 { print $2; count++ } END { if (count != 1) exit 1 }' "$bundle/image-sizes.tsv") || die "missing unique size: $name"
  [[ "$recorded" =~ ^[1-9][0-9]*$ && "$(stat -c %s -- "$image")" = "$recorded" ]] || die "image size differs from assembly record: $name"
  # Raw captured/EROFS images are the selected closure. Refuse sparse inputs
  # instead of comparing their compressed size against a partition capacity.
  magic=$(od -An -N4 -tu4 -- "$image"); magic=${magic//[[:space:]]/}
  [[ "$magic" != 3978755898 ]] || die "sparse input is outside this captured-image flavor: $name"
  expanded_sizes[$name]=$recorded
done
[[ $(wc -l < "$bundle/image-sizes.tsv") -eq 14 ]] || die 'image-size list must contain exactly the 14 selected partitions'
if [[ -z "$platform_tools" && -f "$bundle/host-platform-tools-path.txt" ]]; then
  platform_tools=$(<"$bundle/host-platform-tools-path.txt")
fi
if [[ -z "$platform_tools" ]]; then
  platform_tools="$here/../../../work/toolchains/platform-tools-37.0.1/platform-tools"
fi
[[ -x "$platform_tools/adb" && -x "$platform_tools/fastboot" ]] || die 'pass --platform-tools with the WSL Linux platform-tools directory'
platform_tools=$(cd -- "$platform_tools" && pwd -P)
adb_bin="$platform_tools/adb"; fastboot_bin="$platform_tools/fastboot"
export ADB_LIBUSB=1 ADB_SERVER_PORT=5038 ANDROID_ADB_SERVER_PORT=5038
log="$bundle/flash-powerphone-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
[[ ! -e "$log" ]] || die 'log already exists'
exec > >(tee "$log") 2>&1
printf 'Cubs PowerPhone research OS bundle\nserial=%s\nbundle=%s\nlog=%s\n' "$serial" "$bundle" "$log"
printf 'Bootloader partitions: %s\nFastbootd partitions: %s\n' "${physical[*]}" "${logical[*]}"
printf 'Existing firmware required: bootloader=%s baseband=%s\n' "$expected_bootloader" "$expected_baseband"
printf 'Wipe userdata/encryption metadata: %s (0=preserve; 1=erase).\n' "$wipe"
printf 'Exact current-slot logical growth allowed: %s (0=refuse growth; 1=explicit opt-in).\n' "$grow"
printf 'No hashes, firmware/bootloader/radio updates, slot switches, logical shrink/delete, or automatic recovery.\n'
if ((flash == 0)); then
  printf 'PLAN ONLY: device identity, slot, unlock state, partition sizes and firmware have NOT been checked.\n'
  exit 0
fi
writes_started=0
trap 'code=$?; if ((code != 0)); then if ((writes_started)); then printf "FAILED_AFTER_WRITE_ATTEMPT exit=%s. Partial writes may exist; preserve the log and inspect before retrying.\n" "$code"; else printf "PREFLIGHT_FAILED_BEFORE_WRITES exit=%s. No image flash, logical resize or erase was attempted. USB mode transitions may have occurred.\n" "$code"; fi; printf "No automatic rollback/reboot.\n"; fi' EXIT
adb=("$adb_bin" -P 5038 -s "$serial")
fb=("$fastboot_bin" -s "$serial")
captured= target_slot= mode=
print_command() { printf '+ '; printf '%q ' "$@"; printf '\n'; }
run() { print_command "$@"; "$@"; }
capture() {
  print_command "$@" >&2
  local status=0
  captured=$("$@" 2>&1) || status=$?
  [[ -z "$captured" ]] || printf '%s\n' "$captured" >&2
  return "$status"
}
getvar() {
  local key=$1 duration=${2:-5}
  capture timeout "$duration" "${fb[@]}" getvar "$key" || return $?
  awk -v key="$key" '
    { sub(/\r$/, ""); sub(/^\(bootloader\)[[:space:]]*/, ""); sub(/^[[:space:]]*/, "") }
    index($0, key ":") == 1 {
      value=substr($0, length(key)+2); sub(/^[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value);
      print value; found++
    }
    END { if (found != 1) exit 1 }
  ' <<< "$captured"
}
fastboot_seen() {
  capture timeout "$1" "$fastboot_bin" devices || return $?
  awk -v serial="$serial" '$1 == serial && ($2 == "fastboot" || $2 == "fastbootd") { found=1 } END { exit !found }' <<< "$captured"
}
wait_connection() {
  local deadline=$((SECONDS + 60)) remaining limit
  while ((SECONDS < deadline)); do
    remaining=$((deadline - SECONDS)); limit=$((remaining < 2 ? remaining : 2))
    if fastboot_seen "$limit"; then
      remaining=$((deadline - SECONDS)); ((remaining > 0)) || break
      limit=$((remaining < 2 ? remaining : 2))
      if mode=$(getvar is-userspace "$limit") && [[ "$mode" = yes || "$mode" = no ]]; then return 0; fi
    fi
    remaining=$((deadline - SECONDS)); ((remaining > 0)) || break
    limit=$((remaining < 2 ? remaining : 2))
    if capture timeout "$limit" "${adb[@]}" get-state && [[ "${captured//$'\r'/}" = device ]]; then mode=adb; return 0; fi
    ((SECONDS < deadline)) && sleep 1
  done
  die "exact serial $serial not available within 60 seconds"
}
wait_fastboot() {
  local wanted=$1 deadline=$((SECONDS + 60)) remaining limit actual
  while ((SECONDS < deadline)); do
    remaining=$((deadline - SECONDS)); limit=$((remaining < 2 ? remaining : 2))
    if fastboot_seen "$limit"; then
      remaining=$((deadline - SECONDS)); ((remaining > 0)) || break
      limit=$((remaining < 2 ? remaining : 2))
      if actual=$(getvar is-userspace "$limit") && [[ "$actual" = "$wanted" ]]; then mode=$actual; return 0; fi
    fi
    ((SECONDS < deadline)) && sleep 1
  done
  die "serial $serial did not reach is-userspace=$wanted within 60 seconds"
}
guard_device() {
  local wanted=$1 product unlocked observed_slot actual
  product=$(getvar product) || die 'cannot read product'
  [[ "$product" = cubs ]] || die "wrong fastboot product: $product"
  unlocked=$(getvar unlocked) || die 'cannot read unlock state'
  [[ "$unlocked" = yes ]] || die "bootloader not explicitly unlocked: $unlocked"
  observed_slot=$(getvar current-slot) || die 'cannot read current slot'
  [[ "$observed_slot" = a || "$observed_slot" = b ]] || die "invalid current slot: $observed_slot"
  if [[ -z "$target_slot" ]]; then target_slot=$observed_slot; fi
  [[ "$observed_slot" = "$target_slot" ]] || die 'slot changed during transition'
  actual=$(getvar is-userspace) || die 'cannot read fastboot mode'
  [[ "$actual" = "$wanted" ]] || die "unexpected fastboot mode: $actual"
  printf 'GUARDED product=cubs unlocked=yes slot=%s is-userspace=%s\n' "$target_slot" "$actual"
}
request_mode() {
  local wanted=$1 status=0
  shift
  run "$@" || status=$?
  printf 'TRANSITION_REQUEST_EXIT=%s requested_is_userspace=%s\n' "$status" "$wanted"
  wait_fastboot "$wanted"
  guard_device "$wanted"
  printf 'TRANSITION_VERIFIED request_exit=%s serial=%s mode=%s\n' "$status" "$serial" "$wanted"
}
read_partition_capacity() {
  local name=$1 capacity
  capacity=$(getvar "partition-size:${name}_$target_slot") || die "cannot read capacity: $name"
  [[ "$capacity" =~ ^0x[0-9a-fA-F]{1,12}$ ]] || die "unexpected partition capacity: $name=$capacity"
  current_capacity=$((capacity))
}
partition_fits() {
  local name=$1
  read_partition_capacity "$name"
  ((expanded_sizes[$name] <= current_capacity)) || die "$name image exceeds physical partition; physical resizing is never allowed"
}
preflight_logical() {
  local name=$1 expected=${expanded_sizes[$1]}
  read_partition_capacity "$name"
  initial_logical_sizes[$name]=$current_capacity
  ((expected % 4096 == 0)) || die "$name image is not 4096-byte aligned"
  # fastboot do_flash resizes logical partitions to image_size unconditionally.
  # Reject the implicit-shrink case as well as never issuing a shrink ourselves.
  ((current_capacity <= expected)) || die "$name current bytes=$current_capacity exceed image bytes=$expected; ordinary fastboot flash would shrink it, which is not authorized"
  if ((current_capacity < expected && grow == 0)); then
    die "$name image bytes=$expected exceed current bytes=$current_capacity; rerun with --grow-logical to authorize exact current-slot growth"
  fi
  printf 'LOGICAL_PREFLIGHT partition=%s_%s current_bytes=%s image_bytes=%s growth_bytes=%s\n' \
    "$name" "$target_slot" "$current_capacity" "$expected" "$((expected - current_capacity))"
}
prepare_logical_flash() {
  local name=$1 expected=${expanded_sizes[$1]}
  guard_device yes
  [[ "$(getvar "is-logical:${name}_$target_slot")" = yes ]] || die "logical namespace changed: $name"
  read_partition_capacity "$name"
  ((current_capacity == initial_logical_sizes[$name])) || die "$name capacity changed since preflight; refusing an unplanned resize/flash"
  if ((current_capacity < expected)); then
    ((grow == 1)) || die "logical growth was not authorized: $name"
    printf 'GROW_LOGICAL partition=%s_%s from_bytes=%s exact_target_bytes=%s\n' "$name" "$target_slot" "$current_capacity" "$expected"
    writes_started=1
    run timeout 120 "${fb[@]}" resize-logical-partition "${name}_$target_slot" "$expected" || \
      die "exact growth of ${name}_$target_slot failed (possibly insufficient super/group space); no shrink/delete fallback is permitted"
    read_partition_capacity "$name"
  fi
  ((current_capacity == expected)) || die "$name did not reach the exact image capacity; refusing implicit fastboot resizing"
}
wait_android_adb() {
  local deadline=$((SECONDS + 60)) remaining limit product
  while ((SECONDS < deadline)); do
    remaining=$((deadline - SECONDS)); limit=$((remaining < 2 ? remaining : 2))
    if capture timeout "$limit" "${adb[@]}" get-state && [[ "${captured//$'\r'/}" = device ]]; then
      remaining=$((deadline - SECONDS)); ((remaining > 0)) || break
      limit=$((remaining < 2 ? remaining : 2))
      if capture timeout "$limit" "${adb[@]}" shell getprop ro.product.device; then
        product=${captured//$'\r'/}
        [[ "$product" != cubs ]] || return 0
        [[ -z "$product" ]] || die "unexpected product after reboot: $product"
      fi
    fi
    ((SECONDS < deadline)) && sleep 1
  done
  die 'flashed, but exact Cubs ADB arrival was not established within 60 seconds'
}
wait_connection
if [[ "$mode" = adb ]]; then
  capture timeout 5 "${adb[@]}" shell getprop ro.product.device || die 'cannot identify ADB product'
  [[ "${captured//$'\r'/}" = cubs ]] || die "wrong ADB product: $captured"
  request_mode no timeout 10 "${adb[@]}" reboot bootloader
elif [[ "$mode" = yes ]]; then
  guard_device yes
  request_mode no timeout 10 "${fb[@]}" reboot bootloader
else
  guard_device no
fi
[[ "$(getvar version-bootloader)" = "$expected_bootloader" ]] || die 'bootloader prerequisite differs; this runner never updates it'
[[ "$(getvar version-baseband)" = "$expected_baseband" ]] || die 'baseband prerequisite differs; this runner never updates it'
for name in "${physical[@]}"; do
  [[ "$(getvar "has-slot:$name")" = yes ]] || die "physical $name not confirmed slotted"
  partition_fits "$name"
done
# Preflight logical namespace/sizes before the FIRST image write, then return
# to the bootloader for physical images. No set_active or metadata pivot.
request_mode yes timeout 10 "${fb[@]}" reboot fastboot
for name in "${logical[@]}"; do
  [[ "$(getvar "is-logical:${name}_$target_slot")" = yes ]] || die "$name not confirmed current-slot logical"
  preflight_logical "$name"
done
snapshot_state=$(getvar snapshot-update-status) || die 'cannot exclude an active virtual-A/B snapshot update'
[[ "$snapshot_state" = none ]] || die "snapshot update active/unknown: $snapshot_state"
printf 'PREFLIGHT_COMPLETE: all identity, firmware, partition namespace/capacity and snapshot checks passed; no writes yet.\n'
request_mode no timeout 10 "${fb[@]}" reboot bootloader
for name in "${physical[@]}"; do
  writes_started=1
  if [[ "$name" = vbmeta ]]; then
    run timeout 180 "${fb[@]}" --disable-verity --disable-verification flash "${name}_$target_slot" "$bundle/$name.img"
  else
    run timeout 180 "${fb[@]}" flash "${name}_$target_slot" "$bundle/$name.img"
  fi
done
request_mode yes timeout 10 "${fb[@]}" reboot fastboot
for name in "${logical[@]}"; do
  prepare_logical_flash "$name"
  writes_started=1
  run timeout 600 "${fb[@]}" flash "${name}_$target_slot" "$bundle/$name.img"
done
if ((wipe)); then
  printf 'EXPLICIT DESTRUCTIVE WIPE: erasing all userdata and its encryption metadata; this is not recoverable without an external backup.\n'
  run timeout 600 "${fb[@]}" erase userdata
  run timeout 120 "${fb[@]}" erase metadata
  printf 'WIPED userdata and metadata. All-slot user data is erased; no automatic restoration is available.\n'
fi
printf 'FLASH_COMPLETE current_slot=%s; inactive-slot physical partitions and low-level firmware were not written.\n' "$target_slot"
printf 'Logical images occupy shared super storage: no claim that the other Android slot remains bootable.\n'
if ((reboot)); then
  status=0
  run timeout 10 "${fb[@]}" reboot || status=$?
  printf 'ANDROID_REBOOT_REQUEST_EXIT=%s; checking exact Cubs ADB arrival.\n' "$status"
  wait_android_adb
  printf 'ADB_ARRIVAL_VERIFIED. Boot completion, readiness, API/acoustic and ordinary-UI qualification remain separate.\n'
else
  printf 'Left in fastbootd. No automatic Android boot requested.\n'
fi
