#!/usr/bin/env bash
# Passive boot timing observer. Never roots, reboots, or changes the phone.
set -euo pipefail
export LC_ALL=C
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

usage() {
  printf '%s\n' \
    'Usage: observe-boot-readiness.sh --output-dir NEW_DIR [options]' \
    '  --timeout-seconds 180|240  Observation deadline, including USB absence (default180).' \
    '  --interval-ms 100|250     Remote polling delay (default250; plus sampling cost).' \
    '  --after-boot-id UUID      Ignore completion of this old boot when armed before reboot.' \
    '  --adb PATH --adb-server-port PORT --serial SERIAL' \
    '' \
    'Defaults use FRANKEL_AUDIO_ADB / _ADB_SERVER_PORT (5038) / _SERIAL.' \
    'ANDROID_SERIAL is also accepted. Explicit serial is recommended during flashing.' \
    'Launch after USB disconnect, or supply the old /proc/sys/kernel/random/boot_id.' \
    'Writes samples.tsv, connections.tsv, and passive final logcat/dmesg snapshots.' \
    'No adb root, waits on init, PCM/mixer/diagnostic commands, or device file writes.' \
    'Root ADB exposes private readiness properties/counters; missing values remain NA.' \
    'Shell can finish on the public bridge alone; this is labeled PUBLIC_BRIDGE_ONLY,' \
    'not interpreted as independent verification of the hidden vendor properties.' \
    'Manual adb-root/reboot USB loss is tolerated. Samples before ADB exists are unavailable.' \
    'Exit0 means final ready properties observed, NOT acoustic qualification; exit2 means' \
    'deadline/final readiness failure. Final snapshots add at most30s after observation.'
}

output_dir= after_boot_id= interval_ms=250 observation_seconds=180
FRANKEL_AUDIO_ADB=${FRANKEL_AUDIO_ADB:-"$frankel_audio_project_root/work/toolchains/platform-tools/adb"}
FRANKEL_AUDIO_ADB_SERVER_PORT=${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}
FRANKEL_AUDIO_SERIAL=${FRANKEL_AUDIO_SERIAL:-${ANDROID_SERIAL:-}}
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --output-dir|--timeout-seconds|--interval-ms|--after-boot-id|--adb|--adb-server-port|--serial)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      case "$1" in
        --output-dir) output_dir=$2 ;; --timeout-seconds) observation_seconds=$2 ;;
        --interval-ms) interval_ms=$2 ;; --after-boot-id) after_boot_id=$2 ;;
        --adb) FRANKEL_AUDIO_ADB=$2 ;; --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$2 ;;
        --serial) FRANKEL_AUDIO_SERIAL=$2 ;;
      esac
      shift 2 ;;
    *) frankel_audio_die "unknown argument: $1" ;;
  esac
done
[[ -n "$output_dir" ]] || frankel_audio_die '--output-dir is required'
case "$observation_seconds" in 180|240) ;; *) frankel_audio_die 'timeout must be180 or240 seconds' ;; esac
case "$interval_ms" in 100) interval_seconds=0.100 ;; 250) interval_seconds=0.250 ;;
  *) frankel_audio_die 'interval must be100 or250 milliseconds' ;; esac
[[ -z "$after_boot_id" || "$after_boot_id" =~ ^[0-9a-fA-F-]{36}$ ]] || frankel_audio_die 'invalid prior boot UUID'
after_boot_id=${after_boot_id,,}
frankel_audio_require_positive_integer adb-server-port "$FRANKEL_AUDIO_ADB_SERVER_PORT"
(( FRANKEL_AUDIO_ADB_SERVER_PORT <= 65535 )) || frankel_audio_die 'invalid ADB port'
[[ -x "$FRANKEL_AUDIO_ADB" ]] || frankel_audio_die "adb is not executable: $FRANKEL_AUDIO_ADB"
for utility in timeout date awk tail realpath; do
  command -v "$utility" >/dev/null || frankel_audio_die "missing host command: $utility"
done
output_dir=$(realpath -m -- "$output_dir")
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || frankel_audio_die "output already exists: $output_dir"
mkdir -p -- "$output_dir"
printf '%s\n' $'event\tdevice_epoch_seconds\tuptime_seconds\tboot_id\tuid\tsys.boot_completed\tsys.powerphone.audio_boot\tbootstrap.phase\tpdm.ready\tspeaker.ready\taudioserver\tprimary_hal\tresearch_hal\tbootanim\tservice.bootanim.exit\taoc.restart_count\taoc.coredump_count\treadiness_scope' > "$output_dir/samples.tsv"
printf '%s\n' $'host_epoch_seconds\tevent\tstatus' > "$output_dir/connections.tsv"
printf 'timeout_seconds=%s\ninterval_ms=%s\nafter_boot_id=%s\nadb_server_port=%s\n' \
  "$observation_seconds" "$interval_ms" "$after_boot_id" "$FRANKEL_AUDIO_ADB_SERVER_PORT" > "$output_dir/observer.txt"

# One property snapshot per sample avoids spawning a dozen getprop clients.
# Missing/private properties are NA, never interpreted as false or ready.
remote_script=$(printf '%s\n' '
interval=$1
after_boot_id=$2
budget=$3
device=$(getprop ro.product.device)
[ "$device" = frankel ] || { echo "refusing target $device" >&2; exit 3; }
boot_id=$(cat /proc/sys/kernel/random/boot_id) || exit 3
uid=$(id -u)
read -r begin_uptime unused < /proc/uptime || exit 3
deadline=$(( ${begin_uptime%%.*} + budget ))
while :; do
  read -r uptime unused < /proc/uptime || exit 3
  [ "${uptime%%.*}" -lt "$deadline" ] || exit 4
  epoch=$(date +%s.%N)
  restarts=NA
  coredumps=NA
  # Even a shell access/stat probe produces an SELinux denial on these
  # counters. Do not probe their existence or permissions unless already root.
  if [ "$uid" = 0 ]; then
    if [ -r /sys/devices/platform/9000000.aoc/restart_count ]; then
      read -r restarts < /sys/devices/platform/9000000.aoc/restart_count || restarts=NA
    fi
    if [ -r /sys/devices/platform/9000000.aoc/coredump_count ]; then
      read -r coredumps < /sys/devices/platform/9000000.aoc/coredump_count || coredumps=NA
    fi
  fi
  row=$(getprop | awk -F "[][]" -v epoch="$epoch" -v up="$uptime" \
    -v boot="$boot_id" -v uid="$uid" -v restarts="$restarts" -v coredumps="$coredumps" \
    -v old="$after_boot_id" '\''
    { p[$2]=$4 }
    function value(name) { return p[name] == "" ? "NA" : p[name] }
    END {
      finished = boot != old && p["sys.boot_completed"] == "1" &&
        (p["sys.powerphone.audio_boot"] == "ready" || p["sys.powerphone.audio_boot"] == "failed") &&
        p["init.svc.bootanim"] == "stopped"
      private_visible = p["vendor.powerphone.bootstrap.phase"] != "" &&
        p["vendor.powerphone.pdm.ready"] != "" &&
        p["vendor.powerphone.aoc_speaker_192k.ready"] != "" &&
        p["init.svc.vendor.audio-hal-aidl"] != "" &&
        p["init.svc.vendor.audio-hal-powerphone"] != ""
      public_only = uid == "2000" && !private_visible
      scope = public_only ? "PUBLIC_BRIDGE_ONLY" : (private_visible ? "PRIVATE_FLAGS_VISIBLE" : "PRIVATE_FLAGS_UNAVAILABLE")
      ready = p["sys.powerphone.audio_boot"] == "ready" &&
        p["vendor.powerphone.bootstrap.phase"] == "complete" &&
        p["vendor.powerphone.pdm.ready"] == "1" &&
        p["vendor.powerphone.aoc_speaker_192k.ready"] == "1" &&
        p["init.svc.audioserver"] == "running" &&
        p["init.svc.vendor.audio-hal-aidl"] == "running" &&
        p["init.svc.vendor.audio-hal-powerphone"] == "running"
      event = "SAMPLE"
      if (finished) {
        if (p["sys.powerphone.audio_boot"] == "failed") event = "COMPLETE_FAILED"
        else if (public_only) event = "COMPLETE_PUBLIC_READY"
        else event = ready ? "COMPLETE_READY" : "COMPLETE_NOT_READY"
      }
      printf "%s\t%s\t%s\t%s\t%s", event,epoch,up,boot,uid
      count=split("sys.boot_completed sys.powerphone.audio_boot vendor.powerphone.bootstrap.phase vendor.powerphone.pdm.ready vendor.powerphone.aoc_speaker_192k.ready init.svc.audioserver init.svc.vendor.audio-hal-aidl init.svc.vendor.audio-hal-powerphone init.svc.bootanim service.bootanim.exit",keys," ")
      for (i=1;i<=count;i++) printf "\t%s",value(keys[i])
      printf "\t%s\t%s\t%s\n",restarts,coredumps,scope
    }'\'') || exit 3
  printf "%s\n" "$row" || exit 3
  case "$row" in
    COMPLETE_READY*|COMPLETE_PUBLIC_READY*) exit 0 ;;
    COMPLETE_NOT_READY*|COMPLETE_FAILED*) exit 2 ;;
  esac
  sleep "$interval"
done
')

started=$SECONDS
result=2
reason=timeout
printf 'Observing boot for at most %ss; output: %s\n' "$observation_seconds" "$output_dir"
while (( SECONDS - started < observation_seconds )); do
  remaining=$((observation_seconds - (SECONDS - started)))
  printf '%s\tconnect\t%s\n' "$(date +%s.%N)" "$remaining" >> "$output_dir/connections.tsv"
  # Bound both the host transport and remote loop, including disconnect cases.
  if FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=$remaining frankel_audio_adb shell -T \
      "sh -s -- '$interval_seconds' '$after_boot_id' '$remaining'" <<< "$remote_script" \
      >> "$output_dir/samples.tsv" 2>> "$output_dir/adb-stderr.txt"; then
    connection_status=0
  else
    connection_status=$?
  fi
  printf '%s\tdisconnect\t%s\n' "$(date +%s.%N)" "$connection_status" >> "$output_dir/connections.tsv"
  last_event=$(tail -n 1 "$output_dir/samples.tsv")
  case "$last_event" in
    COMPLETE_READY*) result=0; reason=complete_ready; break ;;
    COMPLETE_PUBLIC_READY*) result=0; reason=complete_public_bridge_ready_private_flags_unverified; break ;;
    COMPLETE_FAILED*) reason=public_bridge_failed; break ;;
    COMPLETE_NOT_READY*) reason=complete_not_ready; break ;;
  esac
  if (( connection_status == 3 )); then reason=remote_error; break; fi
  sleep 0.250
done

# No streaming log reader competes with initialization. Dump only afterward;
# permission/USB failures remain evidence, not reasons to root/restart anything.
for snapshot in logcat dmesg getprop; do
  case "$snapshot" in
    logcat) snapshot_command='logcat -b all -d -v threadtime' ;;
    dmesg) snapshot_command=dmesg ;;
    getprop) snapshot_command=getprop ;;
  esac
  snapshot_status=0
  FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=10 frankel_audio_adb shell "$snapshot_command" \
    > "$output_dir/$snapshot-after.txt" 2> "$output_dir/$snapshot-after.stderr.txt" || snapshot_status=$?
  printf '%s\tsnapshot_%s\t%s\n' "$(date +%s.%N)" "$snapshot" "$snapshot_status" >> "$output_dir/connections.tsv"
done
printf 'result=%s\nexit_status=%s\n' "$reason" "$result" >> "$output_dir/observer.txt"
printf 'Boot observation: %s; samples: %s/samples.tsv\n' "$reason" "$output_dir"
exit "$result"
