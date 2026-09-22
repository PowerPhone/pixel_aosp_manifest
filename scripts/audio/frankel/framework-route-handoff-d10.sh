#!/usr/bin/env bash
# Real BUS -> ordinary -> BUS -> ordinary regression. Never restarts audio HALs.
set -euo pipefail
export LC_ALL=C
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_directory/common.sh"
output_dir= microphone=0
while (( $# )); do
  case "$1" in
    -h|--help)
      printf '%s\n' 'Usage: framework-route-handoff-d10.sh --output-dir NEWDIR [--microphone 0|1|2] [--adb PATH] [--adb-server-port PORT] [--serial SERIAL]' \
        'Four Java AudioTrack5s tones at6s launch spacing: BUS bottom192k/12037Hz, ordinary48k/12000Hz, BUS earpiece192k/12037Hz, ordinary48k/12000Hz.' \
        'Independent32s raw D10 capture; force-stops only the test app before each segment.' \
        'Gates fresh per-segment completion and HAL integrity; acoustic segment qualification remains separate.'
      exit 0 ;;
    --output-dir|--microphone|--adb|--adb-server-port|--serial)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      case "$1" in
        --output-dir) output_dir=$2 ;; --microphone) microphone=$2 ;;
        --adb) FRANKEL_AUDIO_ADB=$2 ;; --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$2 ;;
        --serial) FRANKEL_AUDIO_SERIAL=$2 ;;
      esac
      shift 2 ;;
    *) frankel_audio_die "unknown argument: $1" ;;
  esac
done
[[ -n "$output_dir" ]] || frankel_audio_die '--output-dir is required'
case "$microphone" in 0|1|2) ;; *) frankel_audio_die 'microphone must be0,1,or2' ;; esac
output_dir=$(realpath -m -- "$output_dir")
[[ ! -e "$output_dir" ]] || frankel_audio_die "output directory already exists: $output_dir"
mkdir -p -- "$output_dir"
frankel_audio_initialize_device tinycap chrt
for service in audioserver vendor.audio-hal-aidl vendor.audio-hal-powerphone; do
  value=$(frankel_audio_remote_exec getprop "init.svc.$service")
  printf '%s=%s\n' "$service" "$value" >> "$output_dir/services-before.txt"
  [[ "$value" == running ]] || frankel_audio_die "$service is not running"
done
frankel_audio_remote_exec getprop ro.audio.flinger_standbytime_ms > "$output_dir/standby-property.txt"
[[ $(frankel_audio_remote_exec getprop vendor.powerphone.pdm.ready) == 1 ]] || frankel_audio_die 'D10 boot profile is not ready'
frankel_audio_remote_exec am force-stop com.csr460.powerphone
frankel_audio_remote_exec input keyevent KEYCODE_WAKEUP
frankel_audio_remote_exec wm dismiss-keyguard
logcat_pid=
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ -n "$logcat_pid" ]]; then kill "$logcat_pid" 2>/dev/null; wait "$logcat_pid" 2>/dev/null; fi
  frankel_audio_cleanup
  exit "$status"
}
frankel_audio_arm_cleanup
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for control in 'EP1 TX Mixer INTERNAL_MIC_TX' 'EP2 TX Mixer INTERNAL_MIC_TX' \
    'EP3 TX Mixer INTERNAL_MIC_TX' 'EP5 TX Mixer INTERNAL_MIC_TX' \
    'EP5 TX Mixer INTERNAL_MIC_US_TX' 'US Record Enable' MIC0 MIC1 MIC2; do
  frankel_audio_require_control_zero "$control"
done
frankel_audio_register_safe_control 'EP3 TX Mixer INTERNAL_MIC_TX' 0
frankel_audio_snapshot_and_set_scalar 'BUILTIN MIC Process Mode' Raw
frankel_audio_snapshot_and_set_scalar 'Audio Capture Mic Source' Builtin_MIC
frankel_audio_snapshot_and_set_scalar 'Mic Spatial Module Enable' 0
frankel_audio_snapshot_and_set_scalar 'MIC DC Blocker' 0
frankel_audio_snapshot_and_set_scalar 'MIC Record Soft Gain (dB)' 0
frankel_audio_snapshot_vector 'BUILDIN MIC ID CAPTURE LIST'
frankel_audio_snapshot_and_set_scalar 'INTERNAL_MIC_TX Sample Rate' SR_192K
frankel_audio_snapshot_and_set_scalar 'INTERNAL_MIC_TX Format' S16_LE
frankel_audio_snapshot_and_set_scalar 'INTERNAL_MIC_TX Chan' One
alternate=$((microphone == 0 ? 1 : 0))
frankel_audio_tinymix_set 'BUILDIN MIC ID CAPTURE LIST' "$alternate" -1 -1 -1
frankel_audio_tinymix_set 'BUILDIN MIC ID CAPTURE LIST' "$microphone" -1 -1 -1
run_id="handoff-$(date +%s)-${BASHPID}"
remote_prefix="$FRANKEL_AUDIO_REMOTE_DIRECTORY/$run_id"
printf '%s\n' "$run_id" > "$output_dir/run-id.txt"
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-before.txt"
start_time=$(frankel_audio_remote_exec date '+%m-%d %H:%M:%S.000')
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=80 frankel_audio_adb shell logcat -v threadtime -T 1 \
  'PowerPhoneHandoff:*' 'PowerPhoneStock:*' 'AOC:*' 'aoc:*' 'aocd:*' \
  'AHAL_Powerphone:*' 'AudioTrack:*' 'AudioFlinger:*' 'AudioStreamOutSink:*' \
  'StreamHalAidl:*' '*:E' > "$output_dir/aoc-app-live.log" 2>&1 &
logcat_pid=$!
# Tags containing colons cannot be represented by logcat's tag:priority
# filter syntax. The global ERROR filter retains those primary-HAL faults.
# Reject an immediately dead live reader before launching any test audio.
sleep 0.1
kill -0 "$logcat_pid" 2>/dev/null || frankel_audio_die 'live logcat reader exited before capture'
capture_command=$(frankel_audio_remote_command /system/bin/chrt -f 3 /system/bin/tinycap \
  "${remote_prefix}-capture.wav" -D 0 -d 10 -c 1 -r 192000 -b 16 -p 1920 -n 4 -T 32)
app_base=$(frankel_audio_remote_command am start -W -n com.csr460.powerphone/.StockPlaybackActivity \
  --es output_api java --ez record_reference false --ez research_reference false \
  --ei duration_seconds 5 --ef peak_level "${FRANKEL_AUDIO_PEAK_LEVEL:-0.08}")
hard_off=$(frankel_audio_remote_cleanup_body)
remote_script="
cap_pid=
cleanup() {
  if test -n \"\$cap_pid\"; then kill \$cap_pid 2>/dev/null || :; wait \$cap_pid 2>/dev/null || :; fi
  ${hard_off}
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/system/bin/tinymix -D 0 -- 'EP3 TX Mixer INTERNAL_MIC_TX' 1 || exit 2
date '+capture_begin %s.%N'
${capture_command} > '${remote_prefix}-capture.log' 2>&1 &
cap_pid=\$!
sleep 2
status=0
for segment in 1 2 3 4; do
  kill -0 \$cap_pid || exit 2
  am force-stop com.csr460.powerphone
  case \$segment in
    1) rate=192000; tone=12037; address=POWERPHONE_C0_D0_BOTTOM ;;
    3) rate=192000; tone=12037; address=POWERPHONE_C0_D0_EARPIECE ;;
    *) rate=48000; tone=12000; address= ;;
  esac
  launch_ns=\$(date +%s%N)
  marker=\"run=${run_id} segment=\$segment rate=\$rate tone=\$tone address=\$address launch_ns=\$launch_ns\"
  echo \"segment_launch \$marker\"
  /system/bin/log -p i -t PowerPhoneHandoff \"BEGIN \$marker\"
  if test -n \"\$address\"; then
    ${app_base} --ei output_rate \$rate --ei tone_hz \$tone --es output_address \"\$address\" > '${remote_prefix}-launch-'\$segment'.log' 2>&1 || status=1
  else
    ${app_base} --ei output_rate \$rate --ei tone_hz \$tone > '${remote_prefix}-launch-'\$segment'.log' 2>&1 || status=1
  fi
  now_ns=\$(date +%s%N)
  # Android mksh arithmetic is32-bit on this build. Keep nanosecond anchors
  # as strings and subtract in awk; double precision here is sub-microsecond.
  remaining_seconds=\$(awk -v start=\"\$launch_ns\" -v now=\"\$now_ns\" 'BEGIN { d=6+(start-now)/1000000000; printf \"%.6f\", (d>0 ? d : 0) }') || exit 2
  sleep \"\$remaining_seconds\" || exit 2
done
wait \$cap_pid; capture_status=\$?; cap_pid=
date '+capture_end %s.%N'
/system/bin/log -p i -t PowerPhoneHandoff 'END run=${run_id}'
echo app_launch_status=\$status capture_status=\$capture_status
test \$status -eq 0 && test \$capture_status -eq 0
"
set +e
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=80 frankel_audio_adb shell "$remote_script" | tee "$output_dir/session.txt"
session_status=${PIPESTATUS[0]}
set -e
kill "$logcat_pid" 2>/dev/null || true
wait "$logcat_pid" 2>/dev/null || true
logcat_pid=
frankel_audio_cleanup
FRANKEL_AUDIO_CLEANUP_ARMED=false
for suffix in capture.wav capture.log launch-1.log launch-2.log launch-3.log launch-4.log; do
  frankel_audio_adb pull "${remote_prefix}-${suffix}" "$output_dir/$suffix" >/dev/null || session_status=1
done
frankel_audio_remote_exec logcat -d -v threadtime -T "$start_time" > "$output_dir/logcat.txt" || true
rg 'PowerPhoneHandoff|PowerPhoneStock' "$output_dir/aoc-app-live.log" > "$output_dir/app.log" || true
for service in audioserver vendor.audio-hal-aidl vendor.audio-hal-powerphone; do
  value=$(frankel_audio_remote_exec getprop "init.svc.$service")
  printf '%s=%s\n' "$service" "$value" >> "$output_dir/services-after.txt"
  [[ "$value" == running ]] || session_status=1
done
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-after.txt" || true
if ! python3 "$frankel_audio_project_root/tools/audio/qualify_frankel_route_handoff.py" "$output_dir"; then session_status=1; fi
[[ -s "$output_dir/capture.wav" ]] || session_status=1
printf 'run_id=%s session_status=%s acoustic_qualification=PENDING segment_count=4 capture_rate=192000 microphone=%s\n' \
  "$run_id" "$session_status" "$microphone" | tee "$output_dir/measurement.txt"
exit "$session_status"
