#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"

require_pixel_target frankel "the Frankel real-hardware runtime validator"
(( $# == 0 )) || die "usage: [FRANKEL_ADB_SERIAL=<serial>] scripts/validate-frankel-runtime.sh"

if [[ -n ${FRANKEL_ADB_SERIAL:-} && -n ${ANDROID_SERIAL:-} && \
      "$FRANKEL_ADB_SERIAL" != "$ANDROID_SERIAL" ]]; then
  die "FRANKEL_ADB_SERIAL and ANDROID_SERIAL select different devices"
fi

require_command awk date grep mkdir mktemp mv realpath rm sed sha256sum timeout tr

adb_bin=${ADB:-"$workspace_platform_tools/adb"}
[[ "$adb_bin" == /* ]] || adb_bin="$project_root/$adb_bin"
[[ -f "$adb_bin" && ! -L "$adb_bin" && -x "$adb_bin" ]] || \
  die "adb is not a safe executable: $adb_bin"
adb_bin=$(realpath -e -- "$adb_bin")
[[ $(sha256sum "$adb_bin" | awk '{print $1}') == \
   "$PLATFORM_TOOLS_ADB_SHA256" ]] || \
  die "adb does not match the pinned Platform-Tools binary"
adb_version_output=$($adb_bin version 2>&1)
[[ "$adb_version_output" == *"Version $PLATFORM_TOOLS_VERSION-"* ]] || \
  die "this audit requires adb $PLATFORM_TOOLS_VERSION"

timeout_seconds=${FRANKEL_ADB_TIMEOUT_SECONDS:-30}
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || \
  die "FRANKEL_ADB_TIMEOUT_SECONDS must be a positive integer"
(( timeout_seconds <= 180 )) || \
  die "FRANKEL_ADB_TIMEOUT_SECONDS must not exceed 180"
timeout_command=(timeout --foreground --signal=TERM "${timeout_seconds}s")

device_serial=${FRANKEL_ADB_SERIAL:-${ANDROID_SERIAL:-}}
if [[ -z "$device_serial" ]]; then
  devices_output=$("${timeout_command[@]}" "$adb_bin" devices 2>/dev/null) || \
    die "unable to enumerate ADB transports"
  mapfile -t usable_devices < <(
    awk '$2 == "device" {print $1}' <<<"$devices_output"
  )
  (( ${#usable_devices[@]} == 1 )) || \
    die "set FRANKEL_ADB_SERIAL unless exactly one device-state ADB transport exists"
  device_serial=${usable_devices[0]}
fi
[[ "$device_serial" =~ ^[[:alnum:]_.:-]+$ ]] || \
  die "selected ADB serial contains unsupported characters"
adb_command=("$adb_bin" -s "$device_serial")

adb_capture() {
  local output status
  if output=$("${timeout_command[@]}" "${adb_command[@]}" "$@" 2>&1); then
    status=0
  else
    status=$?
  fi
  output=${output//$'\r'/}
  output=${output//"$device_serial"/'<redacted>'}
  printf '%s' "$output"
  return "$status"
}

adb_shell() {
  adb_capture shell "$@"
}

adb_prop() {
  adb_shell getprop "$1"
}

logs_dir="$project_root/logs"
assert_inside_project "$logs_dir"
[[ ! -L "$logs_dir" ]] || die "logs directory must not be a symbolic link"
mkdir -p "$logs_dir"
[[ -d "$logs_dir" && ! -L "$logs_dir" ]] || \
  die "logs path is not a safe directory"
umask 077
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
report="$logs_dir/runtime-validation-frankel-$timestamp-${BASHPID}.txt"
report_tmp=$(mktemp "$logs_dir/.runtime-validation-frankel.XXXXXX")
trap 'rm -f -- "$report_tmp"' EXIT
pass_count=0
failure_count=0

record() {
  printf '%s\n' "$*" >>"$report_tmp"
}

pass() {
  ((pass_count += 1))
  record "PASS $*"
}

fail() {
  ((failure_count += 1))
  record "FAIL $*"
}

check_equal() {
  local label=$1 actual=$2 expected=$3
  if [[ "$actual" == "$expected" ]]; then
    pass "$label=$actual"
  else
    fail "$label expected=$expected actual=${actual:-<empty>}"
  fi
}

check_contains() {
  local label=$1 actual=$2 expected=$3
  if [[ "$actual" == *"$expected"* ]]; then
    pass "$label contains $expected"
  else
    fail "$label lacks $expected: ${actual:-<empty>}"
  fi
}

adb_capture wait-for-device >/dev/null || die "Frankel did not become available over ADB"
root_output=$(adb_capture root) || die "adb root failed: $root_output"
[[ "$root_output" != *"cannot run as root"* ]] || \
  die "the attached build does not permit adb root"
adb_capture wait-for-device >/dev/null || \
  die "Frankel did not return after restarting adbd as root"

record "Pixel 10 Frankel real-hardware runtime validation"
record "timestamp_utc=$timestamp"
record "selected_device=<redacted>"
record "adb_version=$PLATFORM_TOOLS_VERSION"
record "expected_build_id=$STOCK_BUILD_ID"
record "expected_framework_spl=$AOSP_SECURITY_PATCH"
record ""

check_equal sys.boot_completed "$(adb_prop sys.boot_completed)" 1
check_equal ro.product.device "$(adb_prop ro.product.device)" "$DEVICE_CODENAME"
check_equal ro.product.vendor.device "$(adb_prop ro.product.vendor.device)" "$DEVICE_CODENAME"
check_equal ro.board.platform "$(adb_prop ro.board.platform)" "$DEVICE_PLATFORM"
check_equal ro.boot.hardware.platform "$(adb_prop ro.boot.hardware.platform)" "$DEVICE_PLATFORM"
check_equal ro.build.id "$(adb_prop ro.build.id)" "$STOCK_BUILD_ID"
check_equal ro.build.type "$(adb_prop ro.build.type)" userdebug
check_equal ro.debuggable "$(adb_prop ro.debuggable)" 1
check_equal ro.build.version.release "$(adb_prop ro.build.version.release)" 17
check_equal ro.build.version.sdk "$(adb_prop ro.build.version.sdk)" 37
check_equal ro.build.version.security_patch \
  "$(adb_prop ro.build.version.security_patch)" "$AOSP_SECURITY_PATCH"
check_equal ro.vendor.build.security_patch \
  "$(adb_prop ro.vendor.build.security_patch)" "$AOSP_SECURITY_PATCH"
check_equal ro.boot.slot_suffix "$(adb_prop ro.boot.slot_suffix)" _a
check_equal ro.boot.vbmeta.device_state \
  "$(adb_prop ro.boot.vbmeta.device_state)" unlocked
check_equal ro.boot.flash.locked "$(adb_prop ro.boot.flash.locked)" 0
check_equal ro.boot.verifiedbootstate \
  "$(adb_prop ro.boot.verifiedbootstate)" orange
check_equal ro.boot.veritymode "$(adb_prop ro.boot.veritymode)" enforcing
check_equal adb_root_uid "$(adb_shell id -u)" 0
check_equal selinux "$(adb_shell getenforce)" Enforcing

verification_output=$(adb_shell avbctl get-verification 2>&1 || true)
verity_output=$(adb_shell avbctl get-verity 2>&1 || true)
check_contains avbctl_verification "$verification_output" "verification is enabled"
check_contains avbctl_verity "$verity_output" "verity is enabled"

for service in servicemanager vndservicemanager surfaceflinger zygote \
    netd vold audioserver cameraserver; do
  check_equal "init.svc.$service" "$(adb_prop "init.svc.$service")" running
done

wifi_capability_features=(
  android.hardware.wifi.aware
  android.hardware.wifi.rtt
)
wifi_capability_services=(
  wifiaware
  wifirtt
)
for index in "${!wifi_capability_features[@]}"; do
  feature=${wifi_capability_features[$index]}
  service=${wifi_capability_services[$index]}
  check_equal "package_feature.$feature" \
    "$(adb_shell pm has-feature "$feature" 2>&1 || true)" true
  service_output=$(adb_shell service check "$service" 2>&1 || true)
  check_contains "framework_service.$service" "$service_output" found
done

gservices_provider_package=org.pixelaosp.gservicesflags
gservices_provider_path=$(adb_shell pm path "$gservices_provider_package" 2>&1 || true)
check_contains gservices_provider_path "$gservices_provider_path" \
  "package:/system_ext/priv-app/PixelAospGservicesFlagsProvider/PixelAospGservicesFlagsProvider.apk"
gservices_provider_dump=$(adb_shell dumpsys package "$gservices_provider_package" 2>&1 || true)
check_contains gservices_provider_authority "$gservices_provider_dump" \
  com.google.android.gsf.gservices
check_contains gservices_provider_permission "$gservices_provider_dump" \
  com.google.android.providers.gsf.permission.READ_GSERVICES
euicc_package_dump=$(adb_shell dumpsys package com.google.euiccpixel 2>&1 || true)
check_contains euicc_read_gservices_grant "$euicc_package_dump" \
  "com.google.android.providers.gsf.permission.READ_GSERVICES: granted=true"

crash_log=$(adb_shell logcat -b crash -d -v brief 2>&1 || true)
for process in \
  com.google.euiccpixel \
  com.google.android.modem.pms \
  com.google.android.euicc \
  com.google.android.apps.camera.services; do
  if grep -Fq "Process: $process" <<<"$crash_log"; then
    fail "boot_crash.$process present"
  else
    pass "boot_crash.$process absent"
  fi
done
main_log=$(adb_shell logcat -b main -b system -d -v brief 2>&1 || true)
if grep -Fq \
    'caller is not the privileged Pixel eUICC support app' <<<"$main_log"; then
  fail "gservices_provider unauthorized-query rejection present"
else
  pass "gservices_provider unauthorized-query rejection absent"
fi

mounts_text=$(adb_shell cat /proc/mounts) || \
  die "unable to read the Frankel mount table"
verity_partitions=(system system_dlkm system_ext product vendor vendor_dlkm)
verity_mount_points=(/ /system_dlkm /system_ext /product /vendor /vendor_dlkm)
for index in "${!verity_partitions[@]}"; do
  partition=${verity_partitions[$index]}
  mount_point=${verity_mount_points[$index]}
  verity_name="${partition}-verity"
  dm_table=$(adb_shell dmctl table "$verity_name" 2>&1 || true)
  check_contains "dmctl.$verity_name" "$dm_table" verity
  verity_device=$(
    adb_shell readlink -f "/dev/block/mapper/$verity_name" 2>&1 || true
  )
  if [[ "$verity_device" =~ ^/dev/block/dm-[0-9]+$ ]]; then
    pass "mapper.$verity_name=$verity_device"
  else
    fail "mapper.$verity_name is invalid: ${verity_device:-<empty>}"
  fi

  # The positional fields belong to awk, not this shell.
  # shellcheck disable=SC2016
  mount_record=$(awk -v "mount_point=$mount_point" \
    '$2 == mount_point {print $1 " " $4}' <<<"$mounts_text")
  mount_source=${mount_record%% *}
  check_equal "mount.$mount_point.source" "$mount_source" "$verity_device"
  mount_options=${mount_record#* }
  if [[ ",$mount_options," == *,ro,* ]]; then
    pass "mount.$mount_point is read-only"
  else
    fail "mount.$mount_point is not read-only: ${mount_record:-<empty>}"
  fi
done

if (( failure_count == 0 )); then
  result=PASS
else
  result=FAIL
fi
{
  printf '\nresult=%s\n' "$result"
  printf 'passes=%d\n' "$pass_count"
  printf 'failures=%d\n' "$failure_count"
} >>"$report_tmp"
[[ ! -e "$report" && ! -L "$report" ]] || \
  die "runtime report destination already exists"
mv -- "$report_tmp" "$report"
trap - EXIT
chmod 0600 "$report"
cat "$report"
note "runtime report: $report"
(( failure_count == 0 )) || exit 1
