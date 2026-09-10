#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  self-loop-192k.sh --stimulus WAV --output WAV \
    --speaker earpiece|bottom --microphone pdm0|pdm1|pdm2|all \
    --duration SECONDS [--lead-seconds SECONDS] [--amp-gain RAW] \
    [--pilot-tone HZ] [--max-phase-step-outliers N] [--force]

Required:
  --stimulus WAV             192 kHz, S32_LE, four-channel test stimulus.
  --output WAV               Local microphone capture destination.
  --speaker ENDPOINT         One physical phone speaker: earpiece or bottom.
  --microphone ENDPOINT      One PDM electrical ID, or all three at once.
  --duration SECONDS         Capture length; at least lead + stimulus + 1 s.

Optional:
  --lead-seconds SECONDS     Quiet lead after capture reaches RUNNING (default: 1).
  --amp-gain RAW             Both CS35L43 raw gain controls, 0..20 (default: 0).
  --pilot-tone HZ            Analyze a known continuous pilot for phase steps.
  --max-phase-step-outliers N
                             Fail if any captured channel exceeds N; requires
                             --pilot-tone.
  --adb PATH                 adb binary (default: work/toolchains/platform-tools/adb).
  --serial SERIAL            Select one device.
  --adb-server-port PORT     Existing ADB server port (default: 5038).
  --force                    Replace capture and generated analysis sidecars.
  -h, --help                 Show this text without contacting a device.

This guarded sequence starts raw tinycap first, waits for PCM 0,8 to report
RUNNING, preserves a quiet lead, then invokes tinyplay on exactly one speaker.
It always uses 192000 Hz/S32, 512x8 playback periods, and conservative capture
geometry. It runs the wideband analyzer but never calls a self-loop result
proof of speaker-only or microphone-only bandwidth: both paths are in series.
USAGE
}

stimulus=
output=
speaker=
microphone=
duration=
lead_seconds=1
amp_gain=0
pilot_tone=
max_phase_step_outliers=
force=false

while (( $# > 0 )); do
  case "$1" in
    --stimulus|--output|--speaker|--microphone|--duration|--lead-seconds|\
    --amp-gain|--pilot-tone|--max-phase-step-outliers|--adb|--serial|\
    --adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --stimulus) stimulus=$value ;;
        --output) output=$value ;;
        --speaker) speaker=$value ;;
        --microphone) microphone=$value ;;
        --duration) duration=$value ;;
        --lead-seconds) lead_seconds=$value ;;
        --amp-gain) amp_gain=$value ;;
        --pilot-tone) pilot_tone=$value ;;
        --max-phase-step-outliers) max_phase_step_outliers=$value ;;
        --adb) FRANKEL_AUDIO_ADB=$value ;;
        --serial) FRANKEL_AUDIO_SERIAL=$value ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$value ;;
      esac
      ;;
    --force)
      force=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      frankel_audio_die "unknown argument: $1 (use --help)"
      ;;
  esac
done

for required_name in stimulus output speaker microphone duration; do
  [[ -n ${!required_name} ]] || \
    frankel_audio_die "--${required_name//_/-} is required"
done
[[ -f "$stimulus" ]] || frankel_audio_die "stimulus not found: $stimulus"
stimulus=$(realpath -- "$stimulus")
output=$(realpath -m -- "$output")
case "$speaker" in
  earpiece|bottom) ;;
  *) frankel_audio_die "speaker must be earpiece or bottom" ;;
esac
case "$microphone" in
  pdm0|pdm1|pdm2)
    capture_channels=1
    capture_period_size=1024
    ;;
  all)
    capture_channels=3
    capture_period_size=512
    ;;
  *) frankel_audio_die "microphone must be pdm0, pdm1, pdm2, or all" ;;
esac
for integer_name in duration lead_seconds amp_gain; do
  integer_value=${!integer_name}
  [[ "$integer_value" =~ ^[0-9]+$ ]] || \
    frankel_audio_die "--${integer_name//_/-} must be a non-negative whole number"
done
(( duration > 0 )) || frankel_audio_die "--duration must be greater than zero"
(( lead_seconds >= 1 && lead_seconds <= 10 )) || \
  frankel_audio_die "--lead-seconds must be between 1 and 10"
(( amp_gain <= 20 )) || frankel_audio_die "--amp-gain must be between 0 and 20"
if [[ -n "$pilot_tone" ]]; then
  [[ "$pilot_tone" =~ ^[0-9]+$ ]] || \
    frankel_audio_die "--pilot-tone must be a positive whole number"
  (( pilot_tone > 0 && pilot_tone < 96000 )) || \
    frankel_audio_die "--pilot-tone must be below the 96 kHz Nyquist limit"
fi
if [[ -n "$max_phase_step_outliers" ]]; then
  [[ "$max_phase_step_outliers" =~ ^[0-9]+$ ]] || \
    frankel_audio_die "--max-phase-step-outliers must be non-negative"
  [[ -n "$pilot_tone" ]] || \
    frankel_audio_die "--max-phase-step-outliers requires --pilot-tone"
fi

stimulus_info=$("$script_directory/generate-signal.py" inspect "$stimulus" \
  --expect-rate 192000 --expect-channels 4 --expect-bits 32)
printf '%s\n' "$stimulus_info"
[[ "$stimulus_info" =~ duration=([0-9]+\.[0-9]+) ]] || \
  frankel_audio_die "stimulus inspection did not report duration"
stimulus_seconds=${BASH_REMATCH[1]}
python3 - "$duration" "$lead_seconds" "$stimulus_seconds" <<'PY' || \
  frankel_audio_die "capture must last at least lead + stimulus + 1 second"
import sys

capture, lead, stimulus = map(float, sys.argv[1:])
raise SystemExit(0 if capture >= lead + stimulus + 1.0 else 1)
PY

analysis_output="${output}.analysis.txt"
spectrum_output="${output}.spectrum.csv"
run_log="${output}.self-loop.log"
for destination in "$output" "$analysis_output" "$spectrum_output" "$run_log"; do
  if [[ -e "$destination" && "$force" != true ]]; then
    frankel_audio_die "output exists (use --force): $destination"
  fi
done
output_directory=${output%/*}
[[ "$output_directory" != "$output" ]] || output_directory=.
mkdir -p -- "$output_directory"
partial_capture_log="${run_log}.capture-partial-${BASHPID}"
partial_playback_log="${run_log}.playback-partial-${BASHPID}"
partial_run_log="${run_log}.partial-${BASHPID}"
for temporary in "$partial_capture_log" "$partial_playback_log" \
  "$partial_run_log"; do
  [[ ! -e "$temporary" ]] || \
    frankel_audio_die "temporary path unexpectedly exists: $temporary"
done

declare -a connection_options=()
if [[ -n ${FRANKEL_AUDIO_ADB:-} ]]; then
  connection_options+=(--adb "$FRANKEL_AUDIO_ADB")
fi
if [[ -n ${FRANKEL_AUDIO_SERIAL:-} ]]; then
  connection_options+=(--serial "$FRANKEL_AUDIO_SERIAL")
fi
if [[ -n ${FRANKEL_AUDIO_ADB_SERVER_PORT:-} ]]; then
  connection_options+=(--adb-server-port "$FRANKEL_AUDIO_ADB_SERVER_PORT")
fi
declare -a force_option=()
if [[ "$force" == true ]]; then
  force_option+=(--force)
fi

capture_pid=
self_loop_armed=false
self_loop_cleanup() {
  local original_status=$?
  trap - EXIT HUP INT TERM
  if [[ -n ${capture_pid:-} ]] && kill -0 "$capture_pid" 2>/dev/null; then
    kill -TERM "$capture_pid" 2>/dev/null || true
    wait "$capture_pid" 2>/dev/null || true
  fi
  if [[ "$self_loop_armed" == true ]]; then
    "$script_directory/reset-routes.sh" "${connection_options[@]}" \
      >/dev/null 2>&1 || true
  fi
  if (( original_status != 0 )); then
    printf 'self-loop diagnostic logs, if created, remain beside %s\n' \
      "$run_log" >&2
  fi
  exit "$original_status"
}
trap self_loop_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# No extra target utility is needed beyond common.sh's mandatory tinymix.
# shellcheck disable=SC2119
frankel_audio_initialize_device
self_loop_armed=true
frankel_audio_note \
  "starting 192 kHz capture: speaker=$speaker microphone=$microphone"
"$script_directory/tinycap.sh" \
  --output "$output" --endpoint "$microphone" --rate 192000 --format s32 \
  --channels "$capture_channels" --period-size "$capture_period_size" \
  --period-count 8 --duration "$duration" --soft-gain-db 0 --dc-blocker off \
  "${connection_options[@]}" "${force_option[@]}" \
  >"$partial_capture_log" 2>&1 &
capture_pid=$!

capture_running=false
for (( attempt = 0; attempt < 200; attempt++ )); do
  if capture_status=$(frankel_audio_remote_exec \
      cat /proc/asound/card0/pcm8c/sub0/status 2>/dev/null) && \
     grep -Fq 'state: RUNNING' <<<"$capture_status"; then
    capture_running=true
    break
  fi
  kill -0 "$capture_pid" 2>/dev/null || break
  sleep 0.025
done
if [[ "$capture_running" != true ]]; then
  set +e
  wait "$capture_pid"
  capture_status_code=$?
  set -e
  capture_pid=
  frankel_audio_die \
    "PCM 0,8 did not reach RUNNING (capture wrapper status $capture_status_code; see $partial_capture_log)"
fi

frankel_audio_note "capture is RUNNING; preserving ${lead_seconds}s quiet lead"
sleep "$lead_seconds"
set +e
"$script_directory/tinyplay.sh" \
  --file "$stimulus" --endpoint "$speaker" --rate 192000 --format s32 \
  --channels 4 --period-size 512 --period-count 8 \
  --ultrasonic-mode in-band --high-rate-source direct --amp-gain "$amp_gain" \
  "${connection_options[@]}" >"$partial_playback_log" 2>&1
playback_status=$?
set -e
if (( playback_status != 0 )); then
  kill -TERM "$capture_pid" 2>/dev/null || true
  wait "$capture_pid" 2>/dev/null || true
  capture_pid=
  frankel_audio_die \
    "tinyplay failed with status $playback_status (see $partial_playback_log)"
fi

set +e
wait "$capture_pid"
capture_status_code=$?
set -e
capture_pid=
(( capture_status_code == 0 )) || \
  frankel_audio_die \
    "tinycap failed with status $capture_status_code (see $partial_capture_log)"

{
  printf 'Frankel 192 kHz self-loop: speaker=%s microphone=%s\n' \
    "$speaker" "$microphone"
  printf 'Combined-path evidence only; this cannot isolate either transducer.\n'
  printf '\n[tinycap]\n'
  cat -- "$partial_capture_log"
  printf '\n[tinyplay]\n'
  cat -- "$partial_playback_log"
} >"$partial_run_log"

declare -a analysis_options=(
  --expected-rate 192000
  --spectrum-csv "$spectrum_output"
)
if [[ -n "$pilot_tone" ]]; then
  analysis_options+=(--pilot-tone "$pilot_tone")
fi
if [[ -n "$max_phase_step_outliers" ]]; then
  analysis_options+=(--max-phase-step-outliers "$max_phase_step_outliers")
fi
"$script_directory/../analyze-wideband.py" "$output" \
  "${analysis_options[@]}" \
  >"$analysis_output"
mv -f -- "$partial_run_log" "$run_log"
rm -f -- "$partial_capture_log" "$partial_playback_log"
trap - EXIT HUP INT TERM
"$script_directory/reset-routes.sh" "${connection_options[@]}" >/dev/null
self_loop_armed=false
cat -- "$analysis_output"
frankel_audio_note "combined-path self-loop capture: $output"
frankel_audio_note "run log: $run_log"
frankel_audio_note "analysis: $analysis_output"
frankel_audio_note "spectrum: $spectrum_output"
