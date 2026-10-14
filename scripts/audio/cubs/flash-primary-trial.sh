#!/usr/bin/env bash
# Narrow research-image flash runner. No userdata wipe, slot switch, or hashes.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
adb_bin="$repo/work/toolchains/platform-tools-37.0.1/platform-tools/adb"
fastboot_bin="$repo/work/toolchains/platform-tools-37.0.1/platform-tools/fastboot"
export ADB_LIBUSB=1 ADB_SERVER_PORT=5038 ANDROID_ADB_SERVER_PORT=5038
serial= image_dir= flash=0 reboot=0
usage() {
  printf '%s\n' \
    'Usage: bash scripts/audio/cubs/flash-primary-trial.sh --serial SERIAL --image-dir DIR [--flash] [--reboot]' \
    'Required images: vendor.img, system_ext.img. Optional: vendor_kernel_boot.img, vbmeta.img.' \
    'Without --flash: local plan only, no device queries or mode changes.' \
    '--flash permits current-slot writes; --reboot additionally boots Android afterward.' \
    'Experimental primary-HAL trial only, not a release flash-all; never wipes userdata.'
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --serial|--image-dir)
      (($# >= 2)) || { usage; exit 2; }
      case "$1" in --serial) serial=$2;; --image-dir) image_dir=$2;; esac
      shift 2;;
    --flash) flash=1; shift;;
    --reboot) reboot=1; shift;;
    -h|--help) usage; exit 0;;
    *) usage; die "unknown argument: $1";;
  esac
done
[[ "$serial" =~ ^[[:alnum:]][[:alnum:]_.:-]*$ && -d "$image_dir" ]] || { usage; exit 2; }
((reboot == 0 || flash == 1)) || die '--reboot requires --flash'
image_dir=$(cd -- "$image_dir" && pwd -P)
for name in vendor system_ext; do
  [[ -f "$image_dir/$name.img" && -r "$image_dir/$name.img" && -s "$image_dir/$name.img" ]] || die "missing/empty $name.img"
done
physical=()
for name in vendor_kernel_boot vbmeta; do
  if [[ -e "$image_dir/$name.img" || -L "$image_dir/$name.img" ]]; then
    [[ -f "$image_dir/$name.img" && -r "$image_dir/$name.img" && -s "$image_dir/$name.img" ]] || die "invalid optional $name.img"
    physical+=("$name")
  fi
done
[[ -x "$adb_bin" && -x "$fastboot_bin" ]] || die 'WSL platform-tools37.0.1 missing'
log="$image_dir/flash-primary-trial-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
[[ ! -e "$log" ]] || die 'log destination already exists'
exec > >(tee "$log") 2>&1
printf 'Cubs experimental primary trial; serial=%s\nimage_dir=%s\nlog=%s\n' "$serial" "$image_dir" "$log"
printf 'Logical images: vendor.img, system_ext.img (current slot, fastbootd).\n'
if ((${#physical[@]})); then printf 'Optional bootloader images: %s\n' "${physical[*]}"; fi
printf 'No other partitions, userdata erase, slot changes, or hashes are performed.\n'
if ((flash == 0)); then
  printf 'PLAN ONLY: device identity, unlock state and slot have NOT been checked. Add --flash to proceed.\n'
  exit 0
fi
trap 'code=$?; if ((code != 0)); then printf "FAILED exit=%s; preserve this log. No failure-triggered rollback or extra reboot was attempted.\n" "$code"; fi' EXIT
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
  die "exact serial $serial did not become available within60 seconds"
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
  die "serial $serial did not reach is-userspace=$wanted within60 seconds"
}
guard_device() {
  local wanted=$1 product unlocked observed_slot actual
  product=$(getvar product) || die 'cannot read fastboot product'
  [[ "$product" = cubs ]] || die "wrong fastboot product: $product"
  unlocked=$(getvar unlocked) || die 'cannot read unlock state'
  [[ "$unlocked" = yes ]] || die "bootloader is not explicitly unlocked: $unlocked"
  observed_slot=$(getvar current-slot) || die 'cannot read active slot'
  [[ "$observed_slot" = a || "$observed_slot" = b ]] || die "invalid active slot: $observed_slot"
  if [[ -z "$target_slot" ]]; then target_slot=$observed_slot; fi
  [[ "$observed_slot" = "$target_slot" ]] || die 'active slot changed across USB/mode transition'
  actual=$(getvar is-userspace) || die 'cannot read fastboot mode'
  [[ "$actual" = "$wanted" ]] || die "unexpected fastboot mode: $actual"
  printf 'GUARDED product=cubs unlocked=yes slot=%s is-userspace=%s\n' "$target_slot" "$actual"
}
request_fastboot_mode() {
  local wanted=$1 status=0
  shift
  # USB disconnect/re-enumeration can time out after the request was accepted.
  # Never infer success from this exit status alone in either direction.
  run "$@" || status=$?
  printf 'TRANSITION_REQUEST_EXIT=%s requested_is_userspace=%s\n' "$status" "$wanted"
  wait_fastboot "$wanted"
  guard_device "$wanted"
  printf 'TRANSITION_VERIFIED request_exit=%s exact_serial=%s is_userspace=%s\n' "$status" "$serial" "$wanted"
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
        if [[ "$product" = cubs ]]; then return 0; fi
        [[ -z "$product" ]] || die "unexpected ADB product after reboot: $product"
      fi
    fi
    ((SECONDS < deadline)) && sleep 1
  done
  die 'images flashed, but exact Cubs ADB arrival was not established within60 seconds; inspect device before continuing'
}

wait_connection
if [[ "$mode" = adb ]]; then
  capture timeout 5 "${adb[@]}" shell getprop ro.product.device || die 'cannot identify ADB product'
  [[ "${captured//$'\r'/}" = cubs ]] || die "wrong ADB product: $captured"
  request_fastboot_mode no timeout 10 "${adb[@]}" reboot bootloader
elif [[ "$mode" = yes ]]; then
  guard_device yes
  request_fastboot_mode no timeout 10 "${fb[@]}" reboot bootloader
else
  guard_device no
fi
for name in "${physical[@]}"; do
  [[ "$(getvar "has-slot:$name")" = yes ]] || die "physical partition $name is not confirmed slotted"
  if [[ "$name" = vbmeta ]]; then
    run timeout 180 "${fb[@]}" --disable-verity --disable-verification flash "vbmeta_$target_slot" "$image_dir/vbmeta.img"
  else
    run timeout 180 "${fb[@]}" flash "vendor_kernel_boot_$target_slot" "$image_dir/vendor_kernel_boot.img"
  fi
done
request_fastboot_mode yes timeout 10 "${fb[@]}" reboot fastboot
for name in vendor system_ext; do
  [[ "$(getvar "is-logical:${name}_$target_slot")" = yes ]] || die "${name}_$target_slot is not confirmed logical"
  run timeout 600 "${fb[@]}" flash "${name}_$target_slot" "$image_dir/$name.img"
done
printf 'FLASH_COMPLETE slot=%s. No bootloader, radio, boot, init_boot, system, userdata or unrelated partition was written.\n' "$target_slot"
if ((reboot)); then
  reboot_status=0
  run timeout 10 "${fb[@]}" reboot || reboot_status=$?
  printf 'ANDROID_REBOOT_REQUEST_EXIT=%s; checking exact-device ADB arrival.\n' "$reboot_status"
  wait_android_adb
  printf 'ADB_ARRIVAL_VERIFIED product=cubs serial=%s request_exit=%s.\n' "$serial" "$reboot_status"
  printf 'sys.boot_completed, boot readiness and audio qualification remain separate real-device checks.\n'
else
  printf 'Device deliberately left in fastbootd; use --reboot when a final Android reboot is wanted.\n'
fi
