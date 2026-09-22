#!/usr/bin/env bash
# Capture actual Android UI effects without stopping or replacing either HAL.
set -euo pipefail
export LC_ALL=C
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_directory/common.sh"
output_dir= warm_primary=false
while (( $# )); do
  case "$1" in
    --output-dir|--warm-primary|--adb|--adb-server-port|--serial)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      case "$1" in
        --output-dir) output_dir=$2 ;;
        --warm-primary) warm_primary=$2 ;;
        --adb) FRANKEL_AUDIO_ADB=$2 ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$2 ;;
        --serial) FRANKEL_AUDIO_SERIAL=$2 ;;
      esac
      shift 2 ;;
    *) frankel_audio_die 'usage: framework-sound-effects-d10-reference.sh --output-dir NEWDIR [--warm-primary true|false] [ADB options]' ;;
  esac
done
[[ -n "$output_dir" ]] || frankel_audio_die '--output-dir required'
case "$warm_primary" in true|false) ;; *) frankel_audio_die 'warm-primary must be true or false' ;; esac
output_dir=$(realpath -m -- "$output_dir")
[[ ! -e "$output_dir" ]] || frankel_audio_die "output already exists: $output_dir"
mkdir -p -- "$output_dir"
frankel_audio_initialize_device tinycap chrt
for service in audioserver vendor.audio-hal-aidl vendor.audio-hal-powerphone; do
  value=$(frankel_audio_remote_exec getprop "init.svc.$service")
  printf '%s=%s\n' "$service" "$value" >> "$output_dir/services-before.txt"
  [[ "$value" == running ]] || frankel_audio_die "$service is not running"
done
[[ $(frankel_audio_remote_exec getprop vendor.powerphone.pdm.ready) == 1 ]] || frankel_audio_die 'D10 boot profile not ready'
frankel_audio_remote_exec am force-stop com.csr460.powerphone
frankel_audio_remote_exec input keyevent KEYCODE_WAKEUP
frankel_audio_remote_exec wm dismiss-keyguard
frankel_audio_arm_cleanup
trap frankel_audio_cleanup EXIT
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
frankel_audio_tinymix_set 'BUILDIN MIC ID CAPTURE LIST' 1 -1 -1 -1
frankel_audio_tinymix_set 'BUILDIN MIC ID CAPTURE LIST' 0 -1 -1 -1
prefix="$FRANKEL_AUDIO_REMOTE_DIRECTORY/frankel-ui-${BASHPID}"
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-before.txt"
frankel_audio_remote_exec dumpsys audio > "$output_dir/audio-before.txt"
start_time=$(frankel_audio_remote_exec date '+%m-%d %H:%M:%S.000')
capture_command=$(frankel_audio_remote_command /system/bin/chrt -f 3 \
  /system/bin/tinycap "${prefix}-capture.wav" -D 0 -d 10 -c 1 -r 192000 -b 16 -p 1920 -n 4 -T 20)
app_command=$(frankel_audio_remote_command am start -W -n com.csr460.powerphone/.SoundEffectsActivity \
  --ez warm_primary "$warm_primary" --ei click_count 8 --ei gap_ms 1000 --ei warmup_ms 1000)
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
tinymix -D 0 -- 'EP3 TX Mixer INTERNAL_MIC_TX' 1 || exit 2
date '+capture_begin %s.%N'
${capture_command} > '${prefix}-capture.log' 2>&1 &
cap_pid=\$!
sleep 2
kill -0 \$cap_pid || exit 2
date '+application_launch %s.%N'
${app_command} > '${prefix}-app-launch.log' 2>&1
app_status=\$?
wait \$cap_pid; capture_status=\$?; cap_pid=
date '+capture_end %s.%N'
echo app_status=\$app_status capture_status=\$capture_status
test \$app_status -eq 0 && test \$capture_status -eq 0
"
set +e
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=65 frankel_audio_adb shell "$remote_script" | tee "$output_dir/session.txt"
session_status=${PIPESTATUS[0]}
set -e
frankel_audio_cleanup
FRANKEL_AUDIO_CLEANUP_ARMED=false
for suffix in capture.wav capture.log app-launch.log; do
  frankel_audio_adb pull "${prefix}-${suffix}" "$output_dir/$suffix" >/dev/null || session_status=1
done
frankel_audio_remote_exec logcat -d -v threadtime -T "$start_time" > "$output_dir/logcat.txt"
frankel_audio_remote_exec dumpsys audio > "$output_dir/audio-after.txt"
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-after.txt"
printf 'warm_primary=%s session_status=%s acoustic_qualification=PENDING\n' "$warm_primary" "$session_status" | tee "$output_dir/measurement.txt"
exit "$session_status"
