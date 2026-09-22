#!/usr/bin/env bash
# Independent raw D10 reference for Java AudioTrack or native AAudio playback.
set -euo pipefail
export LC_ALL=C
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_directory/common.sh"

usage() {
  printf '%s\n' \
    'Usage: framework-playback-d10-reference.sh --output-dir DIR' \
    '  [--output-rate 48000|192000] [--output-api java|aaudio]' \
    '  [--output-address POWERPHONE_C0_D0_BOTTOM|POWERPHONE_C0_D0_EARPIECE]' \
    '  [--tone 4000|12000|12037|54283|66547] [--microphone 0|1|2]' \
    '  [--duration CAPTURE_SECONDS] [--play-seconds SECONDS] [--lead-seconds SECONDS]' \
    '  [--adb PATH] [--adb-server-port PORT] [--serial SERIAL]' \
    '' \
    'Runs StockPlaybackActivity: eight-second tone, application recording OFF.' \
    'An independent tinycap captures PCM0,D10 mono S16/192k, period1920x4.' \
    'Defaults: Java, ordinary speaker, output48000, tone12000, mic0, capture14s, lead2s.' \
    'The optional address selects the exact research BUS instead of ordinary speaker.' \
    'Never stops/restarts audio services or changes speaker controls/firmware.' \
    'Requires the already-running D10 boot profile and an idle capture route.' \
    'Preserves capture WAV, session/application/AoC logs, and acoustic analysis.' \
    'AAudio also pulls its full native report and requires its run ID to match the launch log.' \
    'At4000/12000/12037Hz, requires full duration and zero measured phase/dropout/clipping events.' \
    'At54283/66547Hz, qualifies intended-tone contrast only; airborne origin/duration/jitter remain unqualified.' \
    'FRANKEL_AUDIO_PEAK_LEVEL sets app amplitude (default0.08; app permits0..0.25).'
}

output_dir= output_rate=48000 output_api=java output_address= tone=12000 microphone=0 duration=14 lead=2 play_seconds=8
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --output-dir|--output-rate|--output-api|--output-address|--tone|--microphone|--duration|--play-seconds|--lead-seconds|--adb|--adb-server-port|--serial)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      case "$1" in
        --output-dir) output_dir=$2 ;; --output-rate) output_rate=$2 ;;
        --output-api) output_api=$2 ;; --output-address) output_address=$2 ;;
        --tone) tone=$2 ;;
        --microphone) microphone=$2 ;; --duration) duration=$2 ;; --play-seconds) play_seconds=$2 ;;
        --lead-seconds) lead=$2 ;; --adb) FRANKEL_AUDIO_ADB=$2 ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$2 ;;
        --serial) FRANKEL_AUDIO_SERIAL=$2 ;;
      esac
      shift 2 ;;
    *) frankel_audio_die "unknown argument: $1" ;;
  esac
done
[[ -n "$output_dir" ]] || frankel_audio_die '--output-dir is required'
case "$output_rate" in 48000|192000) ;; *) frankel_audio_die 'output rate must be 48000 or 192000' ;; esac
case "$output_api" in java|aaudio) ;; *) frankel_audio_die 'output API must be java or aaudio' ;; esac
case "$output_address" in ''|POWERPHONE_C0_D0_BOTTOM|POWERPHONE_C0_D0_EARPIECE) ;; *) frankel_audio_die 'unknown output BUS address' ;; esac
case "$tone" in 4000|12000|12037|54283|66547) ;; *) frankel_audio_die 'tone must be 4000, 12000, 12037, 54283, or 66547 Hz' ;; esac
(( tone * 2 < output_rate )) || frankel_audio_die 'tone must be strictly below the output sample-rate Nyquist limit'
case "$microphone" in 0|1|2) ;; *) frankel_audio_die 'microphone must be 0, 1, or 2' ;; esac
frankel_audio_require_positive_integer duration "$duration"
frankel_audio_require_integer lead-seconds "$lead"
frankel_audio_require_positive_integer play-seconds "$play_seconds"
(( play_seconds >= 5 && play_seconds <= 120 && duration >= lead + play_seconds + 4 )) || frankel_audio_die 'capture needs lead + playback + four seconds for launch and idle tail; playback range5..120s'
output_dir=$(realpath -m -- "$output_dir")
[[ ! -e "$output_dir" ]] || frankel_audio_die "output directory already exists: $output_dir"
mkdir -p -- "$output_dir"
frankel_audio_initialize_device tinycap chrt

declare -A service_states=()
for service in audioserver vendor.audio-hal-aidl vendor.audio-hal-powerphone; do
  service_states[$service]=$(frankel_audio_remote_exec getprop "init.svc.$service")
  [[ ${service_states[$service]} == running ]] || frankel_audio_die "$service is not running; framework playback needs the existing services"
  printf '%s=%s\n' "$service" "${service_states[$service]}" >> "$output_dir/services-before.txt"
done
[[ $(frankel_audio_remote_exec getprop vendor.powerphone.pdm.ready) == 1 ]] || \
  frankel_audio_die 'the existing D10 boot profile is not ready'

# End only a prior instance of this test application, including its optional
# AudioRecord. Do this before taking ownership of any capture control.
frankel_audio_remote_exec am force-stop com.csr460.powerphone
frankel_audio_remote_exec input keyevent KEYCODE_WAKEUP
frankel_audio_remote_exec wm dismiss-keyguard

logcat_pid=
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ -n "$logcat_pid" ]]; then
    kill "$logcat_pid" 2>/dev/null
    wait "$logcat_pid" 2>/dev/null
  fi
  # The remote trap has already stopped/waited its own tinycap process.
  # Only our EP3 capture route and captured mixer snapshots are changed.
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

remote_prefix="$FRANKEL_AUDIO_REMOTE_DIRECTORY/frankel-framework-d10-${BASHPID}"
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-before.txt"
start_time=$(frankel_audio_remote_exec date '+%m-%d %H:%M:%S.000')
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=$((duration + 45)) frankel_audio_adb shell \
  logcat -v threadtime -T 1 'AOC:*' 'aoc:*' 'aocd:*' 'PowerPhoneStock:*' \
  'AudioTrack:*' 'AudioFlinger:*' 'AHAL_Powerphone:*' '*:S' > "$output_dir/aoc-app-live.log" 2>&1 &
logcat_pid=$!
capture_command=$(frankel_audio_remote_command /system/bin/chrt -f 3 \
  /system/bin/tinycap "${remote_prefix}-capture.wav" -D 0 -d 10 -c 1 \
  -r 192000 -b 16 -p 1920 -n 4 -T "$duration")
app_arguments=(am start -W -n com.csr460.powerphone/.StockPlaybackActivity
  --ei tone_hz "$tone" --ei output_rate "$output_rate" --es output_api "$output_api"
  --ez record_reference false --ez research_reference false)
if [[ -n "$output_address" ]]; then
  app_arguments+=(--es output_address "$output_address")
fi
app_arguments+=(--ef peak_level "${FRANKEL_AUDIO_PEAK_LEVEL:-0.08}")
app_arguments+=(--ei duration_seconds "$play_seconds")
app_command=$(frankel_audio_remote_command "${app_arguments[@]}")
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
sleep ${lead}
kill -0 \$cap_pid || exit 2
date '+application_launch %s.%N'
${app_command} > '${remote_prefix}-app-launch.log' 2>&1
app_launch_status=\$?
sleep $((play_seconds + 2))
wait \$cap_pid; capture_status=\$?; cap_pid=
date '+capture_end %s.%N'
echo app_launch_status=\$app_launch_status capture_status=\$capture_status
test \$app_launch_status -eq 0 && test \$capture_status -eq 0
"
set +e
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=$((duration + 45)) frankel_audio_adb shell \
  "$remote_script" | tee "$output_dir/session.txt"
session_status=${PIPESTATUS[0]}
set -e
kill "$logcat_pid" 2>/dev/null || true
wait "$logcat_pid" 2>/dev/null || true
logcat_pid=
# Restore capture controls only after tinycap and the eight-second app tone
# have finished. Keep all framework services and speaker controls untouched.
frankel_audio_cleanup
FRANKEL_AUDIO_CLEANUP_ARMED=false
for suffix in capture.wav capture.log app-launch.log; do
  frankel_audio_adb pull "${remote_prefix}-${suffix}" "$output_dir/$suffix" >/dev/null || true
done
frankel_audio_remote_exec logcat -d -v threadtime -T "$start_time" > "$output_dir/logcat.txt" || true
rg 'PowerPhoneStock|STOCK_PLAYBACK|STOCK_REFERENCE' "$output_dir/aoc-app-live.log" > "$output_dir/app.log" || true
if [[ "$output_api" == aaudio ]]; then
  # Collect the full report even when playback or native validation failed.
  # The app invalidates this fixed path before each launch and logs a unique
  # run ID. Never accept a previous run's saved success after an early abort.
  native_report_errors=()
  if ! frankel_audio_adb pull \
      /sdcard/Android/data/com.csr460.powerphone/files/stock-aaudio-latest.txt \
      "$output_dir/native-report.txt" > "$output_dir/native-report-pull.log" 2>&1; then
    native_report_errors+=(pull_failed)
  fi
  mapfile -t expected_run_ids < <(
    sed -nE 's/^.*STOCK_AAUDIO_REPORT_BEGIN file=[^[:space:]]+[[:space:]]+run_id=([0-9]+-[0-9]+)[[:space:]]*$/\1/p' \
      "$output_dir/aoc-app-live.log" "$output_dir/logcat.txt" | sort -u
  )
  report_run_ids=()
  if [[ -s "$output_dir/native-report.txt" ]]; then
    mapfile -t report_run_ids < <(
      sed -nE 's/^run_id=([0-9]+-[0-9]+)[[:space:]]*$/\1/p' "$output_dir/native-report.txt"
    )
    if ! rg -qx 'native_report_state=RETURNED' "$output_dir/native-report.txt"; then
      native_report_errors+=(native_not_returned)
    fi
    if ! rg -qx 'AAUDIO_RUN_OK' "$output_dir/native-report.txt" || \
        rg -q '^AAUDIO_RUN_FAILED' "$output_dir/native-report.txt"; then
      native_report_errors+=(native_validation_failed_or_incomplete)
    fi
  else
    native_report_errors+=(report_missing_or_empty)
  fi
  if (( ${#expected_run_ids[@]} != 1 )); then
    native_report_errors+=(launch_run_id_missing_or_ambiguous)
  elif (( ${#report_run_ids[@]} != 1 )) || [[ ${report_run_ids[0]} != "${expected_run_ids[0]}" ]]; then
    native_report_errors+=(saved_run_id_missing_or_mismatch)
  fi
  {
    printf 'launch_run_ids=%s\nsaved_run_ids=%s\n' \
      "${expected_run_ids[*]:-missing}" "${report_run_ids[*]:-missing}"
    if (( ${#native_report_errors[@]} != 0 )); then
      printf 'native_report_status=FAIL reasons=%s\n' "${native_report_errors[*]}"
    else
      printf 'native_report_status=PASS\n'
    fi
  } | tee "$output_dir/native-report-status.txt"
  if (( ${#native_report_errors[@]} != 0 )); then session_status=1; fi
fi
for service in audioserver vendor.audio-hal-aidl vendor.audio-hal-powerphone; do
  current_state=$(frankel_audio_remote_exec getprop "init.svc.$service")
  printf '%s=%s\n' "$service" "$current_state" >> "$output_dir/services-after.txt"
  [[ "$current_state" == "${service_states[$service]}" ]] || session_status=1
done
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-after.txt" || true
if ! rg -q 'STOCK_PLAYBACK_COMPLETE' "$output_dir/app.log" || \
    rg -q 'STOCK_PLAYBACK_FAILED|STOCK_REFERENCE_BEGIN' "$output_dir/app.log"; then
  session_status=1
fi
# A client can report success while a shared HAL drops writes or becomes stuck
# in ERROR after the tone. Include the recorded quiet tail in this check.
if rg --no-filename 'AHAL_Powerphone.*(PCM ring write failed|refusing invalid playback burst|playback integrity)|AudioStreamOutSink.*Error while writing data to HAL' \
    "$output_dir/aoc-app-live.log" "$output_dir/logcat.txt" > "$output_dir/hal-playback-errors.txt"; then
  session_status=1
fi
if [[ -s "$output_dir/capture.wav" ]]; then
  if ! python3 "$frankel_audio_project_root/tools/audio/analyze_frankel_playback_tone.py" \
      "$output_dir/capture.wav" --tone "$tone" --output-dir "$output_dir"; then
    session_status=1
  fi
else
  session_status=1
fi
# A clean prefix or a client-side success counter cannot qualify a full run.
# The low-frequency gate uses every sample between detected outer boundaries.
# Weak ultrasonic envelopes cannot support the same duration/phase claim.
if ! python3 "$frankel_audio_project_root/tools/audio/qualify_frankel_playback_measurement.py" \
    "$output_dir/tone-analysis.json" --tone "$tone" --play-seconds "$play_seconds"; then
  session_status=1
fi
printf 'output_api=%s output_rate=%s output_address=%s requested_tone_hz=%s requested_playback_seconds=%s reference_api=tinycap reference_rate=192000 microphone=%s session_status=%s\n' \
  "$output_api" "$output_rate" "${output_address:-ordinary-speaker}" "$tone" "$play_seconds" "$microphone" "$session_status" | tee "$output_dir/measurement.txt"
# Keep remote evidence as well, so an interrupted USB pull never discards it.
exit "$session_status"
