#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

readonly capture_wrapper="$script_directory/d10-raw192-capture.sh"
readonly playback_wrapper="$script_directory/d0-speaker-192k.sh"
readonly route_reset_wrapper="$script_directory/reset-routes.sh"
readonly wideband_analyzer="$script_directory/../analyze-wideband.py"
readonly d10_capture_device=$FRANKEL_AUDIO_RAW192_CAPTURE_DEVICE
readonly d10_status_root="/proc/asound/card${FRANKEL_AUDIO_CARD}"
readonly d10_status_path="${d10_status_root}/pcm${d10_capture_device}c/sub0/status"
readonly d10_running_poll_seconds=0.25
readonly d10_running_timeout_seconds=900
readonly d0_prestage_timeout_seconds=900
readonly d0_go_timeout_seconds=1200
readonly -a self_loop_audio_services=(
  audioserver
  vendor.audio-hal-powerphone
  vendor.audio-hal-aidl
)

usage() {
  cat <<'USAGE'
Usage:
  d0-d10-self-loop-192k.sh --stimulus WAV --output WAV \
    --speaker earpiece|bottom --microphone raw192-pdm0|raw192-pdm1|raw192-pdm2 \
    --capture-duration SECONDS [--lead-seconds SECONDS] [--amp-gain RAW] \
    [--capture-period-size FRAMES] [--capture-period-count N] \
    [--mic-soft-gain-db DB] [--pilot-tone HZ] [--rt-priority N] \
    [--pcm-wait-ms MS] [--pipeline PIPELINE] [--player PLAYER] \
    [--codec-route high-rate|normal-asprx1|dual-asprx1] \
    [--asp-mode keep|on|bypass] \
    [--geometry GEOMETRY] [--start-threshold FRAMES] \
    [--player-bin PATH] [--use-boot-profile] \
    [--capture-first-diagnostic] \
    [--max-phase-step-outliers N] [--allow-xruns] \
    [--skip-live-patch-check] [--force] \
    [ADB options]

Required:
  --stimulus WAV             Local stereo S32_LE/192000 PCM WAV for D0.
  --output WAV               Local mono D10 capture destination.
  --speaker ENDPOINT         Exactly one physical speaker: earpiece or bottom.
  --microphone ENDPOINT      raw192-pdm0, raw192-pdm1, or raw192-pdm2.
  --capture-duration SECONDS Positive whole-number D10 capture duration.

Optional:
  --lead-seconds SECONDS     Quiet lead after D10 reaches RUNNING (default: 1).
  --amp-gain RAW             Both CS35L43 raw gains, 0..20 (default: 0).
  --capture-period-size N    D10 frames per period (default: 1920; multiple of 96).
  --capture-period-count N   D10 periods in the ALSA buffer (default: 4).
  --mic-soft-gain-db DB      AoC RAW capture gain, -40..30 (default: 0).
  --rt-priority N            Run D0 tinyplay as SCHED_FIFO 1..99, or 0 for
                             SCHED_OTHER (default: 0).
  --pcm-wait-ms MS           Pass a temporary ALSA no-progress wait to D0.
                             It is applied only after D10 is already running,
                             so D10 keeps its normal per-substream timeout.
                             On the HZ=250 vendor kernel, the driver's double
                             conversion makes 200 expire after about 52 ms;
                             omit this option for baseline qualification.
  --pipeline PIPELINE        Pass q48-s32, q192-s16, or q192-s32-2slot to D0
                             (default: q192-s32-2slot).
  --codec-route ROUTE        Pass high-rate, normal-asprx1, or dual-asprx1 to D0
                             (default: high-rate). Route comparisons remain
                             acoustic diagnostics, without proven bandwidth.
  --asp-mode MODE           Pass keep, on, or bypass to D0 (default: keep).
  --player PLAYER            Pass staged or tinyplay to D0 (default: staged).
  --geometry GEOMETRY        Pass 480x4, 768x2, 960x2, or 1920x2 to D0
                             (default: 1920x2).
  --start-threshold FRAMES   Pass the staged-player start threshold to D0
                             (default: 1920).
  --player-bin PATH          Remote tinyplay-compatible executable for D0.
  --use-boot-profile         Require and retain the boot-certified D10 profile.
  --capture-first-diagnostic Require the stimulus to outlast the complete D10
                             capture interval. D10 PCM must stop while D0 is
                             still active; this distinguishes overlap stalls
                             from D0 route teardown. D0 then finishes normally.
  --pilot-tone HZ            Analyze a known continuous pilot for phase steps.
  --max-phase-step-outliers N
                             Fail analysis above N; requires --pilot-tone.
  --skip-live-patch-check    Pass the explicit development-only bypass to the
                             D0 wrapper after a separately verified apply.
  --allow-xruns              Preserve a complete nonzero-xrun D0 run for a
                             physical-cadence diagnostic only.
  --force                    Replace the capture, logs, and analysis sidecars.
  --adb PATH                 adb binary (default: project platform-tools).
  --serial SERIAL            Select one ADB device.
  --adb-server-port PORT     Existing ADB server port (default: 5038).
  -h, --help                 Show this text without contacting a device.

This host orchestrator does not reproduce either path's mixer sequence. It
first starts d0-speaker-192k.sh in its local ready/go handshake mode. D0
pushes the stimulus and pre-stages all TDM/codec controls while EP1,
ultrasonic mode, and both amps remain off. Only after that child atomically
signals ready does this script start d10-raw192-capture.sh, wait up to 900
seconds for PCM 0,10 RUNNING, preserve the quiet lead, and release D0. It
continuously requires both children and D10 PCM to remain healthy, then waits
for the guarded D10 capture/revert/validation lifecycle before analysis.

Normally capture duration must cover the lead, stimulus, and at least a
one-second acoustic tail. With --capture-first-diagnostic, the stimulus must
instead exceed the complete capture duration by at least one second, so D10
PCM demonstrably stops before D0 cleanup begins. D0's push and non-powered
setup occur before capture starts.
The mixer wait control is a card-wide default copied into a substream during
`hw_params`. The orchestrator therefore makes D0 publish 10000 before D10
opens and permits a D0-only short stress value only after D10 is running.
The result is evidence for the combined speaker-air-microphone path only.

Sidecars are written separately as:
  OUTPUT.d10-capture.log
  OUTPUT.d0-playback.log
  OUTPUT.analysis.txt
  OUTPUT.spectrum.csv
USAGE
}

stimulus=
output=
speaker=
microphone=
capture_duration=
lead_seconds=1
amp_gain=0
capture_period_size=1920
capture_period_count=4
mic_soft_gain_db=0
rt_priority=0
pilot_tone=
max_phase_step_outliers=
pcm_wait_ms=
player_bin=
pipeline=q192-s32-2slot
codec_route=high-rate
asp_mode=keep
player=staged
geometry=1920x2
start_threshold=1920
use_boot_profile=false
capture_first_diagnostic=false
skip_live_patch_check=false
allow_xruns=false
force=false

while (( $# > 0 )); do
  case "$1" in
    --stimulus|--output|--speaker|--microphone|--capture-duration|\
    --lead-seconds|--amp-gain|--capture-period-size|--capture-period-count|\
    --mic-soft-gain-db|--pilot-tone|--rt-priority|--pcm-wait-ms|--pipeline|--codec-route|--asp-mode|\
    --player|--geometry|--start-threshold|--player-bin|\
    --max-phase-step-outliers|--adb|--serial|--adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --stimulus) stimulus=$value ;;
        --output) output=$value ;;
        --speaker) speaker=$value ;;
        --microphone) microphone=$value ;;
        --capture-duration) capture_duration=$value ;;
        --lead-seconds) lead_seconds=$value ;;
        --amp-gain) amp_gain=$value ;;
        --capture-period-size) capture_period_size=$value ;;
        --capture-period-count) capture_period_count=$value ;;
        --mic-soft-gain-db) mic_soft_gain_db=$value ;;
        --pilot-tone) pilot_tone=$value ;;
        --rt-priority) rt_priority=$value ;;
        --pcm-wait-ms) pcm_wait_ms=$value ;;
        --pipeline) pipeline=$value ;;
        --codec-route) codec_route=$value ;;
        --asp-mode) asp_mode=$value ;;
        --player) player=$value ;;
        --geometry) geometry=$value ;;
        --start-threshold) start_threshold=$value ;;
        --player-bin) player_bin=$value ;;
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
    --skip-live-patch-check)
      skip_live_patch_check=true
      shift
      ;;
    --allow-xruns)
      allow_xruns=true
      shift
      ;;
    --use-boot-profile)
      use_boot_profile=true
      shift
      ;;
    --capture-first-diagnostic)
      capture_first_diagnostic=true
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

for required_name in stimulus output speaker microphone capture_duration; do
  [[ -n ${!required_name} ]] || \
    frankel_audio_die "--${required_name//_/-} is required"
done
[[ -f "$stimulus" ]] || frankel_audio_die "stimulus not found: $stimulus"
case "$speaker" in
  earpiece|bottom) ;;
  *) frankel_audio_die "speaker must be earpiece or bottom" ;;
esac
case "$microphone" in
  raw192-pdm0|raw192-pdm1|raw192-pdm2) ;;
  *)
    frankel_audio_die \
      "microphone must be raw192-pdm0, raw192-pdm1, or raw192-pdm2"
    ;;
esac
frankel_audio_require_positive_integer capture-duration "$capture_duration"
frankel_audio_require_positive_integer lead-seconds "$lead_seconds"
(( lead_seconds <= 30 )) || \
  frankel_audio_die "lead-seconds must be between 1 and 30"
frankel_audio_require_integer amp-gain "$amp_gain"
(( amp_gain <= 20 )) || frankel_audio_die "amp-gain must be between 0 and 20"
frankel_audio_require_positive_integer \
  capture-period-size "$capture_period_size"
frankel_audio_require_positive_integer \
  capture-period-count "$capture_period_count"
(( capture_period_size % 96 == 0 )) || \
  frankel_audio_die \
    "capture-period-size must be a multiple of the 96-frame AoC quantum"
frankel_audio_validate_period_geometry \
  1 2 "$capture_period_size" "$capture_period_count"
[[ "$mic_soft_gain_db" =~ ^-?[0-9]+$ ]] || \
  frankel_audio_die "mic-soft-gain-db must be an integer"
frankel_audio_require_integer rt-priority "$rt_priority"
(( rt_priority >= 0 && rt_priority <= 99 )) || \
  frankel_audio_die "rt-priority must be an integer from 0 through 99"
(( mic_soft_gain_db >= -40 && mic_soft_gain_db <= 30 )) || \
  frankel_audio_die "mic-soft-gain-db must be between -40 and 30"
if [[ -n "$pcm_wait_ms" ]]; then
  [[ "$pcm_wait_ms" =~ ^[1-9][0-9]*$ ]] || \
    frankel_audio_die "pcm-wait-ms must be an integer from 1 through 10000"
  (( pcm_wait_ms <= 10000 )) || \
    frankel_audio_die "pcm-wait-ms must be an integer from 1 through 10000"
fi
if [[ -n "$player_bin" ]]; then
  [[ "$player_bin" == /* ]] || \
    frankel_audio_die "player-bin must be an absolute remote path"
fi
if [[ -n ${FRANKEL_AUDIO_ADB_SERVER_PORT:-} ]]; then
  frankel_audio_require_positive_integer \
    adb-server-port "$FRANKEL_AUDIO_ADB_SERVER_PORT"
  (( FRANKEL_AUDIO_ADB_SERVER_PORT <= 65535 )) || \
    frankel_audio_die "adb-server-port must be at most 65535"
fi
if [[ -n "$pilot_tone" ]]; then
  frankel_audio_require_positive_integer pilot-tone "$pilot_tone"
  (( pilot_tone < 96000 )) || \
    frankel_audio_die "pilot-tone must be below the 96 kHz Nyquist limit"
fi
if [[ -n "$max_phase_step_outliers" ]]; then
  frankel_audio_require_integer \
    max-phase-step-outliers "$max_phase_step_outliers"
  [[ -n "$pilot_tone" ]] || \
    frankel_audio_die "max-phase-step-outliers requires --pilot-tone"
fi

for required_file in "$capture_wrapper" "$playback_wrapper" \
  "$route_reset_wrapper" "$wideband_analyzer"; do
  [[ -x "$required_file" ]] || \
    frankel_audio_die "required executable is missing: $required_file"
done
for host_utility in grep mktemp python3 realpath; do
  command -v "$host_utility" >/dev/null 2>&1 || \
    frankel_audio_die "required host command not found: $host_utility"
done

stimulus=$(realpath -- "$stimulus")
output=$(realpath -m -- "$output")
[[ "$output" != "$stimulus" ]] || \
  frankel_audio_die "capture output must not replace the stimulus"
stimulus_info=$("$script_directory/generate-signal.py" inspect "$stimulus" \
  --expect-rate 192000 --expect-channels 2 --expect-bits 32)
printf '%s\n' "$stimulus_info"
[[ "$stimulus_info" =~ duration=([0-9]+\.[0-9]+) ]] || \
  frankel_audio_die "stimulus inspection did not report duration"
stimulus_seconds=${BASH_REMATCH[1]}
python3 - "$capture_duration" "$lead_seconds" "$stimulus_seconds" \
  "$capture_first_diagnostic" <<'PY' || {
import sys

capture, lead, stimulus = map(float, sys.argv[1:4])
capture_first = sys.argv[4] == "true"
if capture_first:
    raise SystemExit(0 if stimulus >= capture + 1.0 else 1)
raise SystemExit(0 if capture >= lead + stimulus + 1.0 else 1)
PY
  if [[ "$capture_first_diagnostic" == true ]]; then
    frankel_audio_die \
      "capture-first diagnostic requires stimulus >= capture-duration + one second"
  fi
  frankel_audio_die \
    "capture-duration must cover lead + stimulus + at least one second"
}

output_directory=${output%/*}
[[ "$output_directory" != "$output" ]] || output_directory=.
mkdir -p -- "$output_directory"
capture_log="${output}.d10-capture.log"
playback_log="${output}.d0-playback.log"
analysis_output="${output}.analysis.txt"
spectrum_output="${output}.spectrum.csv"
for destination in "$output" "$capture_log" "$playback_log" \
  "$analysis_output" "$spectrum_output"; do
  if [[ -e "$destination" && "$force" != true ]]; then
    frankel_audio_die "output exists (use --force): $destination"
  fi
done

# Validate the one selected connection before starting either lifecycle.
# shellcheck disable=SC2119
frankel_audio_initialize_device
declare -a connection_options=(
  --adb "$FRANKEL_AUDIO_ADB"
  --adb-server-port "${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}"
)
if [[ -n ${FRANKEL_AUDIO_SERIAL:-} ]]; then
  connection_options+=(--serial "$FRANKEL_AUDIO_SERIAL")
fi
declare -a force_option=()
if [[ "$force" == true ]]; then
  force_option+=(--force)
fi

declare -A self_loop_initial_service_states=()
self_loop_services_owned=false

self_loop_service_state() {
  frankel_audio_remote_exec getprop "init.svc.$1"
}

self_loop_take_audio_services() {
  local service state attempt all_stopped
  for service in "${self_loop_audio_services[@]}"; do
    state=$(self_loop_service_state "$service")
    case "$state" in
      running|stopped) ;;
      *) frankel_audio_die "cannot take ownership of $service from state '${state:-unset}'" ;;
    esac
    self_loop_initial_service_states["$service"]=$state
  done
  self_loop_services_owned=true
  frankel_audio_remote_exec stop audioserver
  frankel_audio_remote_exec stop vendor.audio-hal-powerphone
  frankel_audio_remote_exec stop vendor.audio-hal-aidl
  for ((attempt = 0; attempt < 50; attempt++)); do
    all_stopped=true
    for service in "${self_loop_audio_services[@]}"; do
      if [[ "$(self_loop_service_state "$service")" != stopped ]]; then
        all_stopped=false
        frankel_audio_remote_exec stop "$service" >/dev/null 2>&1 || true
      fi
    done
    if [[ "$all_stopped" == true ]]; then
      return 0
    fi
    frankel_audio_remote_exec sleep 0.1
  done
  frankel_audio_die "audio services did not all reach stopped state"
}

self_loop_restore_audio_services() {
  [[ "$self_loop_services_owned" == true ]] || return 0
  local service attempt
  for service in vendor.audio-hal-aidl vendor.audio-hal-powerphone audioserver; do
    if [[ ${self_loop_initial_service_states[$service]} == running ]]; then
      frankel_audio_remote_exec start "$service"
      for ((attempt = 0; attempt < 50; attempt++)); do
        [[ "$(self_loop_service_state "$service")" == running ]] && break
        frankel_audio_remote_exec sleep 0.1
      done
      [[ "$(self_loop_service_state "$service")" == running ]] || return 1
    fi
  done
  self_loop_services_owned=false
}

d10_pcm_status() {
  FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=5 \
    frankel_audio_remote_exec cat "$d10_status_path" 2>/dev/null
}

d10_pcm_is_running() {
  # Frankel may omit the per-substream procfs tree even while D10 is open.
  # The preflight below rejects any pre-existing tinycap, and this parent owns
  # the only wrapper allowed to launch one, so its process lifetime is the
  # unambiguous fallback readiness signal.
  FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=5 \
    frankel_audio_remote_exec pidof tinycap >/dev/null 2>&1
}

if initial_d10_status=$(d10_pcm_status); then
  if grep -Fq 'state: RUNNING' <<<"$initial_d10_status"; then
    frankel_audio_die "PCM 0,10 is already RUNNING; stop the existing capture"
  fi
else
  # Frankel removes the per-substream procfs directory while this PCM is
  # closed.  The exact card/device inventory was already validated above, so
  # ENOENT here is the normal closed state; an extant but unreadable node is
  # still fatal.
  frankel_audio_remote_exec test ! -e "$d10_status_path" || \
    frankel_audio_die "PCM 0,10 status exists but cannot be read"
fi
if frankel_audio_remote_exec pidof tinycap >/dev/null 2>&1; then
  frankel_audio_die "a pre-existing tinycap process is active"
fi

capture_pid=
playback_pid=
quiet_lead_pid=
routes_reset=false
handshake_directory=
handshake_ready_file=
handshake_go_file=
handshake_go_partial=

stop_child() {
  local variable_name=$1
  local pid=${!variable_name:-}
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  printf -v "$variable_name" '%s' ''
}

self_loop_cleanup_handshake() {
  [[ -n "$handshake_directory" ]] || return 0
  rm -f -- "$handshake_ready_file" "$handshake_go_file" \
    "$handshake_go_partial"
  rmdir -- "$handshake_directory"
  handshake_directory=
  handshake_ready_file=
  handshake_go_file=
  handshake_go_partial=
}

self_loop_exit_handler() {
  local status=$?
  local cleanup_failed=false
  trap - EXIT HUP INT TERM
  set +e
  stop_child quiet_lead_pid
  # Silence the speaker first, then let D10 revert its volatile capture patch.
  stop_child playback_pid
  stop_child capture_pid
  if [[ "$routes_reset" != true ]]; then
    "$route_reset_wrapper" "${connection_options[@]}" \
      >/dev/null 2>&1 || cleanup_failed=true
  fi
  self_loop_cleanup_handshake || cleanup_failed=true
  self_loop_restore_audio_services || cleanup_failed=true
  if (( status == 0 )) && [[ "$cleanup_failed" == true ]]; then
    status=1
  fi
  if (( status != 0 )); then
    printf 'D0 log: %s\nD10 log: %s\n' \
      "$playback_log" "$capture_log" >&2
  fi
  exit "$status"
}

trap self_loop_exit_handler EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

self_loop_take_audio_services

handshake_directory=$(mktemp -d -- \
  "$output_directory/.d0-d10-handshake.XXXXXX")
handshake_ready_file="$handshake_directory/d0.ready"
handshake_go_file="$handshake_directory/d0.go"
handshake_go_partial="$handshake_directory/d0.go.partial-${BASHPID}"

declare -a playback_command=(
  "$playback_wrapper"
  --file "$stimulus"
  --endpoint "$speaker"
  --amp-gain "$amp_gain"
  --pipeline "$pipeline"
  --codec-route "$codec_route"
  --asp-mode "$asp_mode"
  --player "$player"
  --geometry "$geometry"
  --start-threshold "$start_threshold"
  --rt-priority "$rt_priority"
  --services-already-stopped
  --ready-file "$handshake_ready_file"
  --go-file "$handshake_go_file"
  --go-timeout "$d0_go_timeout_seconds"
  "${connection_options[@]}"
)
if [[ -n "$pcm_wait_ms" ]]; then
  playback_command+=(--pcm-wait-ms "$pcm_wait_ms")
fi
if [[ -n "$player_bin" ]]; then
  playback_command+=(--player-bin "$player_bin")
fi
if [[ "$skip_live_patch_check" == true ]]; then
  playback_command+=(--skip-live-patch-check)
fi
if [[ "$allow_xruns" == true ]]; then
  playback_command+=(--allow-xruns)
fi
{
  printf 'D0 192 kHz playback child:'
  printf ' %q' "${playback_command[@]}"
  printf '\n'
} >"$playback_log"
frankel_audio_note \
  "pre-staging guarded D0 playback: speaker=$speaker amp-gain=$amp_gain"
"${playback_command[@]}" >>"$playback_log" 2>&1 &
playback_pid=$!

d0_ready=false
d0_prestage_deadline=$((SECONDS + d0_prestage_timeout_seconds))
while (( SECONDS < d0_prestage_deadline )); do
  if [[ -f "$handshake_ready_file" ]]; then
    d0_ready=true
    break
  fi
  if [[ -e "$handshake_ready_file" ]]; then
    frankel_audio_die "D0 ready marker is not a regular file"
  fi
  if ! kill -0 "$playback_pid" 2>/dev/null; then
    set +e
    wait "$playback_pid"
    playback_status=$?
    set -e
    playback_pid=
    frankel_audio_die \
      "D0 wrapper exited with status $playback_status before pre-stage readiness (see $playback_log)"
  fi
  sleep "$d10_running_poll_seconds"
done
[[ "$d0_ready" == true ]] || \
  frankel_audio_die \
    "D0 did not finish its safe-off pre-stage within ${d0_prestage_timeout_seconds} seconds"
grep -Fxq 'state=staged-safe-off' "$handshake_ready_file" || \
  frankel_audio_die "D0 published a malformed ready marker"
kill -0 "$playback_pid" 2>/dev/null || \
  frankel_audio_die "D0 wrapper exited immediately after publishing readiness"
frankel_audio_note \
  "D0 pre-stage is ready and remains hard-off; starting D10"

declare -a capture_command=(
  "$capture_wrapper"
  --output "$output"
  --endpoint "$microphone"
  --duration "$capture_duration"
  --period-size "$capture_period_size"
  --period-count "$capture_period_count"
  --soft-gain-db "$mic_soft_gain_db"
  "${connection_options[@]}"
  "${force_option[@]}"
)
if [[ "$use_boot_profile" == true ]]; then
  capture_command+=(--use-boot-profile)
fi
{
  printf 'D10 RAW 192 kHz capture child:'
  printf ' %q' "${capture_command[@]}"
  printf '\n'
} >"$capture_log"
frankel_audio_note \
  "starting guarded D10 capture: microphone=$microphone duration=${capture_duration}s periods=${capture_period_size}x${capture_period_count}"
"${capture_command[@]}" >>"$capture_log" 2>&1 &
capture_pid=$!

d10_running=false
d10_running_deadline=$((SECONDS + d10_running_timeout_seconds))
while (( SECONDS < d10_running_deadline )); do
  if d10_pcm_is_running; then
    d10_running=true
    break
  fi
  if ! kill -0 "$playback_pid" 2>/dev/null; then
    set +e
    wait "$playback_pid"
    playback_status=$?
    set -e
    playback_pid=
    frankel_audio_die \
      "D0 wrapper exited with status $playback_status while waiting for D10 readiness"
  fi
  if ! kill -0 "$capture_pid" 2>/dev/null; then
    set +e
    wait "$capture_pid"
    capture_status=$?
    set -e
    capture_pid=
    frankel_audio_die \
      "D10 wrapper exited with status $capture_status before PCM 0,10 reached RUNNING"
  fi
  sleep "$d10_running_poll_seconds"
done
[[ "$d10_running" == true ]] || \
  frankel_audio_die \
    "PCM 0,10 did not reach RUNNING within ${d10_running_timeout_seconds} seconds"

frankel_audio_note \
  "PCM 0,10 is RUNNING; preserving ${lead_seconds}s quiet lead"
sleep "$lead_seconds" &
quiet_lead_pid=$!
while kill -0 "$quiet_lead_pid" 2>/dev/null; do
  kill -0 "$playback_pid" 2>/dev/null || \
    frankel_audio_die "D0 wrapper exited during the quiet lead"
  kill -0 "$capture_pid" 2>/dev/null || \
    frankel_audio_die "D10 wrapper exited during the quiet lead"
  d10_pcm_is_running || \
    frankel_audio_die "PCM 0,10 stopped during the quiet lead"
  sleep "$d10_running_poll_seconds"
done
wait "$quiet_lead_pid"
quiet_lead_pid=

[[ ! -e "$handshake_go_file" && ! -e "$handshake_go_partial" ]] || \
  frankel_audio_die "D0 go marker appeared before parent release"
printf 'pid=%s\nstate=go\n' "$BASHPID" >"$handshake_go_partial"
mv -- "$handshake_go_partial" "$handshake_go_file"
handshake_go_partial=
frankel_audio_note \
  "quiet lead is complete; released pre-staged D0 playback"

if [[ "$capture_first_diagnostic" == true ]]; then
  frankel_audio_note \
    "capture-first diagnostic active; D10 PCM must stop before D0 cleanup"
  d10_pcm_stopped_while_d0_active=false
  while kill -0 "$capture_pid" 2>/dev/null; do
    if [[ "$d10_pcm_stopped_while_d0_active" == false ]]; then
      kill -0 "$playback_pid" 2>/dev/null || \
        frankel_audio_die \
          "D0 ended before D10 PCM stopped; capture-first ordering was not proven"
      if ! d10_pcm_is_running; then
        d10_pcm_stopped_while_d0_active=true
        frankel_audio_note \
          "D10 PCM stopped while D0 remains active; waiting for guarded D10 cleanup"
      fi
    fi
    sleep "$d10_running_poll_seconds"
  done
  # If the wrapper exited between two polls, prove D0 is still alive at the
  # first observation after D10's PCM and child both stopped.
  if [[ "$d10_pcm_stopped_while_d0_active" == false ]]; then
    kill -0 "$playback_pid" 2>/dev/null || \
      frankel_audio_die \
        "D10 and D0 ended between polls; capture-first ordering was not proven"
    d10_pcm_stopped_while_d0_active=true
    frankel_audio_note \
      "D10 wrapper stopped while D0 remains active; capture-first ordering proven"
  fi
  set +e
  wait "$capture_pid"
  capture_status=$?
  set -e
  capture_pid=
  (( capture_status == 0 )) || \
    frankel_audio_die \
      "D10 capture wrapper failed with status $capture_status (see $capture_log)"
  frankel_audio_note \
    "guarded D10 capture is complete; waiting for D0 to finish normally"
  set +e
  wait "$playback_pid"
  playback_status=$?
  set -e
  playback_pid=
  (( playback_status == 0 )) || \
    frankel_audio_die \
      "D0 playback wrapper failed with status $playback_status (see $playback_log)"
else
  d10_stopped_during_playback=false
  d10_child_exited_during_playback=false
  d10_early_status=
  d10_running_misses=0
  while kill -0 "$playback_pid" 2>/dev/null; do
    if ! kill -0 "$capture_pid" 2>/dev/null; then
      set +e
      wait "$capture_pid"
      d10_early_status=$?
      set -e
      capture_pid=
      d10_child_exited_during_playback=true
      kill -TERM "$playback_pid" 2>/dev/null || true
      break
    fi
    if d10_pcm_is_running; then
      d10_running_misses=0
    else
      ((d10_running_misses += 1))
    fi
    if (( d10_running_misses >= 8 )); then
      d10_stopped_during_playback=true
      kill -TERM "$playback_pid" 2>/dev/null || true
      break
    fi
    sleep "$d10_running_poll_seconds"
  done
  set +e
  wait "$playback_pid"
  playback_status=$?
  set -e
  playback_pid=
  if [[ "$d10_child_exited_during_playback" == true ]]; then
    frankel_audio_die \
      "D10 wrapper exited with status $d10_early_status before D0 completed"
  fi
  if [[ "$d10_stopped_during_playback" == true ]]; then
    frankel_audio_die \
      "PCM 0,10 stopped or became unreadable before the D0 wrapper completed"
  fi
  (( playback_status == 0 )) || \
    frankel_audio_die \
      "D0 playback wrapper failed with status $playback_status (see $playback_log)"
  kill -0 "$capture_pid" 2>/dev/null || \
    frankel_audio_die "D10 wrapper exited before post-playback validation"
  d10_running=false
  for ((attempt = 0; attempt < 8; attempt++)); do
    if d10_pcm_is_running; then
      d10_running=true
      break
    fi
    sleep "$d10_running_poll_seconds"
  done
  [[ "$d10_running" == true ]] || \
    frankel_audio_die "PCM 0,10 was no longer RUNNING after D0 cleanup"

  frankel_audio_note "D0 is complete; waiting for guarded D10 capture cleanup"
  set +e
  wait "$capture_pid"
  capture_status=$?
  set -e
  capture_pid=
  (( capture_status == 0 )) || \
    frankel_audio_die \
      "D10 capture wrapper failed with status $capture_status (see $capture_log)"
fi

# Both child wrappers have completed their owned cleanup. The existing reset
# wrapper is an idempotent final hard-off check; no mixer sequence is copied
# into this orchestrator.
"$route_reset_wrapper" "${connection_options[@]}" >/dev/null
routes_reset=true
self_loop_cleanup_handshake
self_loop_restore_audio_services

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
frankel_audio_note "running combined-path wideband analysis"
python3 "$wideband_analyzer" "$output" "${analysis_options[@]}" \
  >"$analysis_output"

trap - EXIT HUP INT TERM
cat -- "$analysis_output"
frankel_audio_note "combined D0/D10 self-loop capture: $output"
frankel_audio_note "D0 playback log: $playback_log"
frankel_audio_note "D10 capture log: $capture_log"
frankel_audio_note "analysis: $analysis_output"
frankel_audio_note "spectrum: $spectrum_output"
