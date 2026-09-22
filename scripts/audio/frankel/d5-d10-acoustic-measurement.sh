#!/usr/bin/env bash
# One owner for simultaneous D5 playback and the already-working D10 mic path.
set -euo pipefail
export LC_ALL=C
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_directory/common.sh"

usage() {
  printf '%s\n' \
    'Usage: d5-d10-acoustic-measurement.sh --stimulus WAV --output-dir DIR' \
    '  [--speaker bottom|earpiece] [--microphone 0|1|2] [--tone HZ]' \
    '  [--duration SECONDS] [--lead-seconds N] [--amp-gain N]' \
    '  [--adb PATH] [--adb-server-port PORT] [--serial SERIAL]' \
    '' \
    'Uses existing live/boot D5 and D10 profiles; does not change firmware.' \
    'All audio services stop once; both streams finish before services restore.' \
    'Capture, source, PCM logs, logcat, and spectrum are retained together.' \
    'Defaults: bottom, mic0, 12kHz analysis, capture 12s, quiet lead 2s, gain0.' \
    'Playback uses 192-frame x 20 periods, full-ring start, FIFO priority 90.' \
    'Overrides: FRANKEL_AUDIO_PLAYBACK_PERIOD_SIZE / _PERIOD_COUNT / _PRIORITY.' \
    'FRANKEL_AUDIO_DISABLE_AMPLIFIER=1 leaves the selected amp off for a control.'
}
stimulus= output_dir= speaker=bottom microphone=0 tone=12000 duration=12 lead=2 amp_gain=0
playback_period_size=${FRANKEL_AUDIO_PLAYBACK_PERIOD_SIZE:-192}
playback_period_count=${FRANKEL_AUDIO_PLAYBACK_PERIOD_COUNT:-20}
while (( $# )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --stimulus|--output-dir|--speaker|--microphone|--tone|--duration|--lead-seconds|--amp-gain|--adb|--adb-server-port|--serial)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      case "$1" in
        --stimulus) stimulus=$2 ;; --output-dir) output_dir=$2 ;;
        --speaker) speaker=$2 ;; --microphone) microphone=$2 ;;
        --tone) tone=$2 ;; --duration) duration=$2 ;; --lead-seconds) lead=$2 ;;
        --amp-gain) amp_gain=$2 ;; --adb) FRANKEL_AUDIO_ADB=$2 ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$2 ;;
        --serial) FRANKEL_AUDIO_SERIAL=$2 ;;
      esac
      shift 2 ;;
    *) frankel_audio_die "unknown argument: $1" ;;
  esac
done
[[ -f "$stimulus" && -n "$output_dir" ]] || frankel_audio_die '--stimulus and --output-dir required'
case "$speaker" in bottom|earpiece) ;; *) frankel_audio_die 'invalid speaker' ;; esac
case "$microphone" in 0|1|2) ;; *) frankel_audio_die 'invalid microphone' ;; esac
for parameter in duration lead tone amp_gain playback_period_size playback_period_count; do
  frankel_audio_require_integer "$parameter" "${!parameter}"
done
(( playback_period_size > 0 && playback_period_count > 0 && playback_period_size * playback_period_count * 8 <= 32768 )) || frankel_audio_die 'playback buffer must fit the 32768-byte physical ring'
playback_buffer_frames=$((playback_period_size * playback_period_count))
case "${FRANKEL_AUDIO_DISABLE_AMPLIFIER:-0}" in
  0) amplifier_enable=1 ;;
  1) amplifier_enable=0 ;;
  *) frankel_audio_die 'FRANKEL_AUDIO_DISABLE_AMPLIFIER must be 0 or 1' ;;
esac
(( duration > lead + 2 && tone > 0 && tone < 96000 && amp_gain <= 20 )) || frankel_audio_die 'invalid duration, lead, tone, or gain'
stimulus=$(realpath -- "$stimulus")
output_dir=$(realpath -m -- "$output_dir")
[[ ! -e "$output_dir" ]] || frankel_audio_die "output directory already exists: $output_dir"
mkdir -p -- "$output_dir"
stimulus_info=$("$script_directory/generate-signal.py" inspect "$stimulus" --expect-rate 192000 --expect-channels 2 --expect-bits 32)
printf '%s\n' "$stimulus_info" | tee "$output_dir/stimulus.txt"
[[ "$stimulus_info" =~ duration=([0-9]+)\.([0-9]+) ]] || frankel_audio_die 'cannot determine stimulus duration'
stimulus_ceiling=${BASH_REMATCH[1]}
if [[ ${BASH_REMATCH[2]} =~ [1-9] ]]; then stimulus_ceiling=$((stimulus_ceiling + 1)); fi
(( duration >= lead + stimulus_ceiling + 1 )) || frankel_audio_die "capture must cover lead, complete stimulus, and one second tail (at least $((lead + stimulus_ceiling + 1)) seconds)"
cp -- "$stimulus" "$output_dir/stimulus.wav"
frankel_audio_initialize_device tinycap
declare -A service_states=()
services_owned=false
logcat_pid=
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ -n "$logcat_pid" ]]; then kill "$logcat_pid" 2>/dev/null; wait "$logcat_pid" 2>/dev/null; fi
  frankel_audio_cleanup
  # The remote EXIT trap kills/waits both stream processes before this point.
  if [[ "$services_owned" == true ]]; then
    for service in vendor.audio-hal-aidl vendor.audio-hal-powerphone audioserver; do
      if [[ ${service_states[$service]} == running ]]; then
        frankel_audio_remote_exec start "$service"
      fi
    done
  fi
  exit "$status"
}
for service in audioserver vendor.audio-hal-powerphone vendor.audio-hal-aidl; do
  service_states[$service]=$(frankel_audio_remote_exec getprop "init.svc.$service")
done
frankel_audio_arm_cleanup
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
services_owned=true
if [[ ${service_states[audioserver]} != stopped ]]; then
  frankel_audio_remote_exec stop audioserver
fi
frankel_audio_remote_exec stop vendor.audio-hal-powerphone
frankel_audio_remote_exec stop vendor.audio-hal-aidl
for service in audioserver vendor.audio-hal-powerphone vendor.audio-hal-aidl; do
  [[ $(frankel_audio_remote_exec getprop "init.svc.$service") == stopped ]] || frankel_audio_die "$service remains active"
done

for control in 'Main AMP Enable Switch' 'R Main AMP Enable Switch' 'TDM_0_RX Mixer EP6' 'EP3 TX Mixer INTERNAL_MIC_TX'; do
  frankel_audio_register_safe_control "$control" 0
  frankel_audio_require_control_zero "$control"
done
for source in EP1 EP2 EP3 EP4 EP5 EP7 EP8 IMSV NoHost1 RAW VOIP US; do
  frankel_audio_require_control_zero "TDM_0_RX Mixer $source"
done
for control in 'EP1 TX Mixer INTERNAL_MIC_TX' 'EP2 TX Mixer INTERNAL_MIC_TX' 'EP5 TX Mixer INTERNAL_MIC_TX' 'EP5 TX Mixer INTERNAL_MIC_US_TX' 'US Record Enable' MIC0 MIC1 MIC2; do
  frankel_audio_register_safe_control "$control" 0
  frankel_audio_require_control_zero "$control"
done
for prefix in '' 'R '; do
  frankel_audio_register_safe_control "${prefix}Ultrasonic Mode" Disabled
  frankel_audio_tinymix_set "${prefix}Ultrasonic Mode" Disabled
done
frankel_audio_snapshot_and_set_scalar 'AoC Speaker Mixer ASP Mode' ASP_BYPASS
for suffix in 'Sample Rate' Format Chan nSlot SlotFmt; do
  case "$suffix" in 'Sample Rate') value=SR_192K ;; Format|SlotFmt) value=S32_LE ;; *) value=Two ;; esac
  frankel_audio_snapshot_and_set_scalar "TDM_0_RX $suffix" "$value"
done
for prefix in '' 'R '; do
  for input in 'DSP RX1 Source' 'DSP RX2 Source' 'PCM Source'; do
    frankel_audio_snapshot_and_set_scalar "${prefix}${input}" ASPRX1
  done
  frankel_audio_snapshot_and_set_scalar "${prefix}High Rate PCM Source" Zero
  frankel_audio_snapshot_and_set_scalar "${prefix}Amp Gain" "$amp_gain"
done
if [[ "$speaker" == bottom ]]; then speaker_prefix='R '; else speaker_prefix=''; fi
frankel_audio_snapshot_and_set_scalar "${speaker_prefix}Digital PCM Volume" 817

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

remote_prefix="$FRANKEL_AUDIO_REMOTE_DIRECTORY/frankel-d5-d10-${BASHPID}"
# Uncompressed transfer avoids intermittent adb sync compression stalls on
# this WSL USB forwarding path; no content hashing is performed.
frankel_audio_adb push -Z "$stimulus" "${remote_prefix}-stimulus.wav" >/dev/null
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-before.txt"
start_time=$(frankel_audio_remote_exec date '+%m-%d %H:%M:%S.000')
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=$((duration + 45)) frankel_audio_adb shell logcat -v threadtime -T 1 'AOC:*' 'aoc:*' 'aocd:*' '*:S' > "$output_dir/aoc-live.log" 2>&1 &
logcat_pid=$!
capture_command=$(frankel_audio_remote_command /system/bin/tinycap "${remote_prefix}-capture.wav" -D 0 -d 10 -c 1 -r 192000 -b 16 -p 1920 -n 4 -T "$duration")
play_command=$(frankel_audio_remote_command /system/bin/chrt -f "${FRANKEL_AUDIO_PLAYBACK_PRIORITY:-90}" "${FRANKEL_AUDIO_STAGED_PLAYER:-/vendor/bin/frankel_aoc_staged_play}" --card 0 --device 5 --rate 192000 --channels 2 --format s32 --period-size "$playback_period_size" --period-count "$playback_period_count" --start-threshold "$playback_buffer_frames" --rw-efault-retries 32 --rw-efault-sleep-us 1000 --route-control 'TDM_0_RX Mixer EP6' --access rw "${remote_prefix}-stimulus.wav")
hard_off=$(frankel_audio_remote_cleanup_body)
remote_script="
cap_pid=; play_pid=; monitor_pid=
cleanup() {
  for stream_pid in \$play_pid \$cap_pid \$monitor_pid; do kill \$stream_pid 2>/dev/null || :; done
  wait 2>/dev/null || :
  ${hard_off}
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/system/bin/tinymix -D 0 -- 'EP3 TX Mixer INTERNAL_MIC_TX' 1 || exit 2
${capture_command} > '${remote_prefix}-capture.log' 2>&1 &
cap_pid=\$!
sleep ${lead}
kill -0 \$cap_pid || exit 2
/system/bin/tinymix -D 0 -- 'TDM_0_RX Mixer EP6' 1 || exit 2
/system/bin/tinymix -D 0 -- '${speaker_prefix}Main AMP Enable Switch' ${amplifier_enable} || exit 2
date '+playback_begin %s.%N'
${play_command} > '${remote_prefix}-playback.log' 2>&1 &
play_pid=\$!
(if test -r /proc/asound/card0/pcm5p/sub0/status; then while kill -0 \$play_pid 2>/dev/null; do date '+%s.%N'; cat /proc/asound/card0/pcm5p/sub0/status; sleep 0.2; done; else echo 'Verbose ALSA proc status unavailable in this kernel'; fi) > '${remote_prefix}-pcm-status.log' 2>&1 &
monitor_pid=\$!
wait \$play_pid; play_result=\$?; play_pid=
date '+playback_end %s.%N'
wait \$cap_pid; cap_result=\$?; cap_pid=
date '+capture_end %s.%N'
echo playback_status=\$play_result capture_status=\$cap_result
test \$play_result -eq 0 && test \$cap_result -eq 0
"
set +e
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=$((duration + 45)) frankel_audio_adb shell "$remote_script" | tee "$output_dir/session.txt"
session_status=${PIPESTATUS[0]}
set -e
kill "$logcat_pid" 2>/dev/null || true
wait "$logcat_pid" 2>/dev/null || true
logcat_pid=
for suffix in capture.wav capture.log playback.log pcm-status.log; do
  frankel_audio_adb pull "${remote_prefix}-${suffix}" "$output_dir/$suffix" >/dev/null || true
done
frankel_audio_remote_exec logcat -d -v threadtime -T "$start_time" > "$output_dir/logcat.txt" || true
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-after.txt" || true
printf 'speaker=%s microphone=%s requested_tone_hz=%s session_status=%s period_size=%s period_count=%s start_threshold=%s playback_priority=%s\n' "$speaker" "$microphone" "$tone" "$session_status" "$playback_period_size" "$playback_period_count" "$playback_buffer_frames" "${FRANKEL_AUDIO_PLAYBACK_PRIORITY:-90}" | tee "$output_dir/measurement.txt"
printf 'amplifier_enable=%s\n' "$amplifier_enable" | tee -a "$output_dir/measurement.txt"
# Remote artifacts deliberately survive an interrupted pull; local WAVs are never discarded.
if [[ -s "$output_dir/capture.wav" ]]; then
  python3 "$frankel_audio_project_root/tools/audio/analyze_frankel_playback_tone.py" "$output_dir/capture.wav" --tone "$tone" --output-dir "$output_dir" || true
fi
exit "$session_status"
