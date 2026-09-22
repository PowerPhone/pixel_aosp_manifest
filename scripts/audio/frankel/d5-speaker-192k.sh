#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

readonly d5_playback_device=5
readonly d5_frontend_channels=2
readonly d5_frontend_sample_bytes=4
readonly d5_ring_bytes=32768
readonly d5_vendor_build_id=CP2A.260805.005
readonly d5_live_profile=experimental-enum7-q192-tdm12288-192-2xs32-dma-source5
readonly d5_staged_player=/vendor/bin/frankel_aoc_staged_play
# shellcheck disable=SC2154 # Defined by sourced common.sh.
readonly d5_live_patcher="$frankel_audio_project_root/tools/audio/patch_frankel_aoc_live_speaker_192k.py"

readonly -a d5_audio_services=(
  audioserver
  vendor.audio-hal-powerphone
  vendor.audio-hal-aidl
)
declare -A d5_initial_service_states=()
d5_services_snapshotted=false
d5_services_stopped=false
d5_route_setup_started=false
d5_restart_count=
d5_coredump_count=

usage() {
  cat <<'USAGE'
Usage:
  d5-speaker-192k.sh --file WAV --endpoint ENDPOINT
    [--period-size FRAMES] [--period-count N] [--amp-gain RAW]
    [--skip-live-patch-check] [ADB options]

Required:
  --file WAV                 Local 192 kHz, stereo, S32_LE PCM WAV.
  --endpoint ENDPOINT        earpiece or bottom (one amplifier only).

Optional:
  --period-size FRAMES       Frames per period (default: 192).
  --period-count N           Periods in the ALSA buffer (default: 20).
  --amp-gain RAW             Both CS35L43 raw Amp Gain controls, 0..20
                             (default: 0).
  --skip-live-patch-check    Deliberately skip the guarded AoC profile
                             readback for an isolated development trial.
  --adb PATH                 adb binary (default: project platform-tools).
  --serial SERIAL            Select one ADB device.
  --adb-server-port PORT     Existing ADB server port (default: 5038).
  -h, --help                 Show this text without contacting a device.

This is a Frankel-only direct tinyALSA research wrapper. It opens PCM 0,5
(EP6/source 5) as 192000 Hz, two-channel S32_LE and configures TDM_0_RX as a
two-channel/two-slot S32_LE backend. The default 192x20 frontend buffer is
30,720 bytes, below the observed 32,768-byte audio_playback5 ring. Playback
uses FIFO/90 and prefills the entire ring; 1 ms mailbox periods replenish it
without the intermittent xruns observed with 10 ms periods.

The wrapper records the initial state of audioserver, vendor.audio-hal-aidl,
and vendor.audio-hal-powerphone, stops all three before touching the route,
and restarts only services which it found running. Mixer cleanup and verified
amp/route hard-off precede service restart. It refuses a busy TDM0 route.

Unless --skip-live-patch-check is given, the named live speaker profile must
already be uniformly patched. That profile's configureMixer guard must target
source bitmap bit 5; a source-14/PCM0,D28 profile is not sufficient. The
running kernel must also expose 192 kHz on EP6 and provide working D5 period
real-mailbox progress.
USAGE
}

file=
endpoint=
period_size=192
period_count=20
amp_gain=0
skip_live_patch_check=false

while (( $# > 0 )); do
  case "$1" in
    --file|--endpoint|--period-size|--period-count|--amp-gain|--adb|--serial|\
    --adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --file) file=$value ;;
        --endpoint) endpoint=$value ;;
        --period-size) period_size=$value ;;
        --period-count) period_count=$value ;;
        --amp-gain) amp_gain=$value ;;
        --adb) FRANKEL_AUDIO_ADB=$value ;;
        --serial) FRANKEL_AUDIO_SERIAL=$value ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$value ;;
      esac
      ;;
    --skip-live-patch-check)
      skip_live_patch_check=true
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

[[ -n "$file" ]] || frankel_audio_die "--file is required"
[[ -n "$endpoint" ]] || frankel_audio_die "--endpoint is required"
[[ -f "$file" ]] || frankel_audio_die "WAV file not found: $file"
file=$(realpath -- "$file")
case "$endpoint" in
  earpiece|bottom) ;;
  *) frankel_audio_die "endpoint must be earpiece or bottom; simultaneous amps are unsafe" ;;
esac
frankel_audio_require_positive_integer period-size "$period_size"
frankel_audio_require_positive_integer period-count "$period_count"
frankel_audio_validate_period_geometry \
  "$d5_frontend_channels" "$d5_frontend_sample_bytes" \
  "$period_size" "$period_count"
d5_buffer_bytes=$((period_size * period_count *
  d5_frontend_channels * d5_frontend_sample_bytes))
(( d5_buffer_bytes <= d5_ring_bytes )) || \
  frankel_audio_die \
    "D5 buffer is ${d5_buffer_bytes}B; the observed audio_playback5 ring is ${d5_ring_bytes}B"
if (( period_size % 192 != 0 )); then
  frankel_audio_note \
    "period-size $period_size is not aligned to the live profile's 192-frame AoC quantum"
fi
[[ "$amp_gain" =~ ^[0-9]+$ ]] || \
  frankel_audio_die "raw amp gain must be a non-negative integer"
(( amp_gain <= 20 )) || \
  frankel_audio_die "raw amp gain must be between 0 and 20"

"$script_directory/generate-signal.py" inspect "$file" \
  --expect-rate 192000 --expect-channels 2 --expect-bits 32

d5_get_service_state() {
  frankel_audio_remote_exec getprop "init.svc.$1"
}

d5_snapshot_services() {
  local service state
  for service in "${d5_audio_services[@]}"; do
    state=$(d5_get_service_state "$service")
    case "$state" in
      running|stopped) ;;
      *)
        frankel_audio_die \
          "cannot take ownership of $service from state '${state:-unset}'"
        ;;
    esac
    d5_initial_service_states["$service"]=$state
  done
  d5_services_snapshotted=true
}

d5_require_services_stopped() {
  local attempt service all_stopped
  for ((attempt = 0; attempt < 30; attempt++)); do
    all_stopped=true
    for service in "${d5_audio_services[@]}"; do
      if [[ "$(d5_get_service_state "$service")" != stopped ]]; then
        all_stopped=false
        frankel_audio_remote_exec stop "$service" >/dev/null 2>&1 || true
      fi
    done
    [[ "$all_stopped" == true ]] && return 0
    frankel_audio_remote_exec sleep 0.1
  done
  return 1
}

d5_services_are_stopped() {
  local service
  for service in "${d5_audio_services[@]}"; do
    [[ "$(d5_get_service_state "$service")" == stopped ]] || return 1
  done
}

d5_stop_services() {
  # Stopping audioserver runs stock init actions which can immediately restart
  # the primary HAL. Stop both HALs afterward, then poll/reassert all states.
  frankel_audio_remote_exec stop audioserver
  frankel_audio_remote_exec stop vendor.audio-hal-powerphone
  frankel_audio_remote_exec stop vendor.audio-hal-aidl
  d5_require_services_stopped || \
    frankel_audio_die "audio services did not all reach stopped state"
  d5_services_stopped=true
}

d5_wait_service_running() {
  local service=$1
  local attempt
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ "$(d5_get_service_state "$service")" == running ]] && return 0
    frankel_audio_remote_exec sleep 0.1
  done
  return 1
}

d5_restore_services() {
  [[ "$d5_services_snapshotted" == true && \
     "$d5_services_stopped" == true ]] || return 0
  local service
  # Make both declared audio modules available before AudioPolicy starts.
  for service in vendor.audio-hal-aidl vendor.audio-hal-powerphone; do
    if [[ ${d5_initial_service_states[$service]} == running ]]; then
      frankel_audio_remote_exec start "$service"
      d5_wait_service_running "$service" || {
        printf 'error: %s did not return to running state\n' "$service" >&2
        return 1
      }
    fi
  done
  service=audioserver
  if [[ ${d5_initial_service_states[$service]} == running ]]; then
    frankel_audio_remote_exec start "$service"
    d5_wait_service_running "$service" || {
      printf 'error: %s did not return to running state\n' "$service" >&2
      return 1
    }
  fi
  for service in "${d5_audio_services[@]}"; do
    if [[ "$(d5_get_service_state "$service")" != \
          "${d5_initial_service_states[$service]}" ]]; then
      printf 'error: %s did not return to its initial %s state\n' \
        "$service" "${d5_initial_service_states[$service]}" >&2
      return 1
    fi
  done
  d5_services_stopped=false
}

d5_profile_check() {
  [[ "$skip_live_patch_check" == false ]] || {
    frankel_audio_note \
      "WARNING: skipping Source5 live-profile readback by explicit request"
    return 0
  }
  local -a command=(
    python3 "$d5_live_patcher" check-patched
    --profile "$d5_live_profile"
    --adb "$FRANKEL_AUDIO_ADB"
    --adb-server-port "${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}"
  )
  if [[ -n ${FRANKEL_AUDIO_SERIAL:-} ]]; then
    command+=(--serial "$FRANKEL_AUDIO_SERIAL")
  fi
  d5_services_are_stopped || \
    frankel_audio_die "an audio service restarted before live-profile check"
  PYTHONUNBUFFERED=1 "${command[@]}"
}

d5_read_aoc_counter() {
  local name=$1
  local value
  value=$(frankel_audio_remote_exec \
    cat "/sys/devices/platform/9000000.aoc/$name")
  [[ "$value" =~ ^[0-9]+$ ]] || \
    frankel_audio_die "malformed AoC $name counter: $value"
  printf '%s\n' "$value"
}

d5_snapshot_aoc_generation() {
  d5_restart_count=$(d5_read_aoc_counter restart_count)
  d5_coredump_count=$(d5_read_aoc_counter coredump_count)
}

d5_verify_aoc_generation() {
  local restart_count coredump_count
  restart_count=$(d5_read_aoc_counter restart_count)
  coredump_count=$(d5_read_aoc_counter coredump_count)
  [[ "$restart_count" == "$d5_restart_count" && \
     "$coredump_count" == "$d5_coredump_count" ]] || \
    frankel_audio_die \
      "AoC generation changed during D5 playback (restart ${d5_restart_count}->${restart_count}, coredump ${d5_coredump_count}->${coredump_count})"
}

d5_require_control_one() {
  local control=$1
  local actual
  actual=$(frankel_audio_tinymix_get "$control") || \
    frankel_audio_die "cannot read mixer control: $control"
  [[ "$actual" == 1 || "$actual" == On ]] || \
    frankel_audio_die \
      "$control did not enter the owned on state (got $actual)"
}

d5_exit_handler() {
  local status=$?
  local cleanup_failed=false
  local hard_off_proven=true
  trap - EXIT HUP INT TERM
  set +e
  frankel_audio_cleanup || cleanup_failed=true
  if [[ "$d5_route_setup_started" == true ]]; then
    frankel_audio_verify_safe_controls || {
      cleanup_failed=true
      hard_off_proven=false
    }
  fi
  if [[ "$hard_off_proven" == true ]]; then
    d5_restore_services || cleanup_failed=true
  else
    printf '%s\n' \
      'error: leaving audio services stopped because speaker hard-off was not verified' >&2
  fi
  if (( status == 0 )) && [[ "$cleanup_failed" == true ]]; then
    status=1
  fi
  exit "$status"
}

frankel_audio_initialize_device tinyplay
vendor_build=$(frankel_audio_remote_exec getprop ro.vendor.build.id)
[[ "$vendor_build" == "$d5_vendor_build_id" ]] || \
  frankel_audio_die \
    "refusing unreviewed vendor build $vendor_build (expected $d5_vendor_build_id)"
if [[ "$skip_live_patch_check" == false ]]; then
  [[ -f "$d5_live_patcher" ]] || \
    frankel_audio_die "live speaker patcher is missing: $d5_live_patcher"
  command -v python3 >/dev/null 2>&1 || \
    frankel_audio_die "required host command not found: python3"
fi

d5_snapshot_services
frankel_audio_arm_cleanup
trap d5_exit_handler EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
d5_stop_services

# Register hard-off cleanup before the first mixer mutation. These controls
# are never restored to a possibly-on snapshot.
frankel_audio_register_safe_control 'Main AMP Enable Switch' 0
frankel_audio_register_safe_control 'R Main AMP Enable Switch' 0
frankel_audio_register_safe_control 'TDM_0_RX Mixer EP6' 0
frankel_audio_register_safe_control 'Ultrasonic Mode' Disabled
frankel_audio_register_safe_control 'R Ultrasonic Mode' Disabled
d5_route_setup_started=true

frankel_audio_require_control_zero 'Main AMP Enable Switch'
frankel_audio_require_control_zero 'R Main AMP Enable Switch'
frankel_audio_require_control_zero 'TDM_0_RX Mixer US'
frankel_audio_require_control_value 'Ultrasonic Mode' Disabled
frankel_audio_require_control_value 'R Ultrasonic Mode' Disabled
for active_source in EP1 EP2 EP3 EP4 EP5 EP6 EP7 EP8 IMSV NoHost1 RAW VOIP; do
  frankel_audio_require_control_zero "TDM_0_RX Mixer $active_source"
done

d5_profile_check
d5_snapshot_aoc_generation

remote_file="$FRANKEL_AUDIO_REMOTE_DIRECTORY/frankel-d5-speaker-${BASHPID}.wav"
frankel_audio_register_remote_temp "$remote_file"
frankel_audio_note "pushing validated WAV to Frankel"
frankel_audio_adb push "$file" "$remote_file" >/dev/null
frankel_audio_remote_exec chmod 0644 "$remote_file"

# Keep the route and amps off until every bus and codec setting is complete.
# D5 remains stereo/S32 at the ALSA frontend. The native-q192 AoC profile
# drives the physical backend as two S32 slots at 12.288 MHz.
frankel_audio_snapshot_and_set_scalar 'AoC Speaker Mixer ASP Mode' ASP_BYPASS
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Sample Rate' SR_192K
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Format' S32_LE
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Chan' Two
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX nSlot' Two
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX SlotFmt' S32_LE
for prefix in '' 'R '; do
  frankel_audio_snapshot_and_set_scalar "${prefix}DSP RX1 Source" ASPRX1
  frankel_audio_snapshot_and_set_scalar "${prefix}DSP RX2 Source" ASPRX1
  frankel_audio_snapshot_and_set_scalar "${prefix}PCM Source" ASPRX1
  frankel_audio_snapshot_and_set_scalar \
    "${prefix}High Rate PCM Source" Zero
  frankel_audio_snapshot_and_set_scalar "${prefix}Amp Gain" "$amp_gain"
done
case "$endpoint" in
  earpiece) frankel_audio_snapshot_and_set_scalar 'Digital PCM Volume' 817 ;;
  bottom) frankel_audio_snapshot_and_set_scalar 'R Digital PCM Volume' 817 ;;
esac

frankel_audio_tinymix_set 'Ultrasonic Mode' Disabled
frankel_audio_tinymix_set 'R Ultrasonic Mode' Disabled
frankel_audio_tinymix_set 'TDM_0_RX Mixer EP6' 1
case "$endpoint" in
  earpiece)
    frankel_audio_tinymix_set 'Main AMP Enable Switch' 1
    ;;
  bottom)
    frankel_audio_tinymix_set 'R Main AMP Enable Switch' 1
    ;;
esac

# Read back every value that distinguishes this route from D28/US and from the
# stock four-S32-slot speaker backend before exposing a powered transducer to
# PCM data.
frankel_audio_require_control_value 'AoC Speaker Mixer ASP Mode' ASP_BYPASS
frankel_audio_require_control_value 'TDM_0_RX Sample Rate' SR_192K
frankel_audio_require_control_value 'TDM_0_RX Format' S32_LE
frankel_audio_require_control_value 'TDM_0_RX Chan' Two
frankel_audio_require_control_value 'TDM_0_RX nSlot' Two
frankel_audio_require_control_value 'TDM_0_RX SlotFmt' S32_LE
d5_require_control_one 'TDM_0_RX Mixer EP6'
frankel_audio_require_control_zero 'TDM_0_RX Mixer US'
frankel_audio_require_control_value 'Ultrasonic Mode' Disabled
frankel_audio_require_control_value 'R Ultrasonic Mode' Disabled
for prefix in '' 'R '; do
  frankel_audio_require_control_value "${prefix}DSP RX1 Source" ASPRX1
  frankel_audio_require_control_value "${prefix}DSP RX2 Source" ASPRX1
  frankel_audio_require_control_value "${prefix}PCM Source" ASPRX1
  frankel_audio_require_control_value \
    "${prefix}High Rate PCM Source" Zero
  frankel_audio_require_control_value "${prefix}Amp Gain" "$amp_gain"
done
case "$endpoint" in
  earpiece)
    d5_require_control_one 'Main AMP Enable Switch'
    frankel_audio_require_control_zero 'R Main AMP Enable Switch'
    ;;
  bottom)
    frankel_audio_require_control_zero 'Main AMP Enable Switch'
    d5_require_control_one 'R Main AMP Enable Switch'
    ;;
esac

# Detect a lazy service restart before opening D5. The remote stream trap still
# forces the amps and EP6 route off if tinyplay or the ADB session fails.
d5_services_are_stopped || \
  frankel_audio_die "an audio service restarted during D5 route setup"
frankel_audio_note \
  "playing PCM 0,5: endpoint=$endpoint frontend=192000/s32/2ch backend=192000/s32/2ch/2slot periods=${period_size}x${period_count}"
set +e
d5_playback_started_ns=$(date +%s%N)
playback_output=$(frankel_audio_run_guarded /system/bin/chrt -f 90 "$d5_staged_player" \
  --card "$FRANKEL_AUDIO_CARD" --device "$d5_playback_device" \
  --rate 192000 --channels "$d5_frontend_channels" --format s32 \
  --period-size "$period_size" --period-count "$period_count" \
  --start-threshold "$((period_size * period_count))" --rw-efault-retries 32 \
  --rw-efault-sleep-us 1000 --route-control 'TDM_0_RX Mixer EP6' \
  --access rw "$remote_file" 2>&1)
playback_status=$?
d5_playback_finished_ns=$(date +%s%N)
set -e
printf '%s\n' "$playback_output"
frankel_audio_note \
  "staged playback wall time: $((d5_playback_finished_ns - d5_playback_started_ns)) ns"
(( playback_status == 0 )) || \
  frankel_audio_die "staged player/ADB exited with status $playback_status"
if [[ "$playback_output" =~ [Uu]nable|[Ee]rror|only[[:space:]]supports ]]; then
  frankel_audio_die "staged player reported a PCM error"
fi
d5_services_are_stopped || \
  frankel_audio_die "an audio service restarted during D5 playback"

frankel_audio_cleanup
frankel_audio_verify_safe_controls || \
  frankel_audio_die "D5 mixer cleanup could not be verified"
d5_verify_aoc_generation
d5_profile_check
d5_restore_services
# shellcheck disable=SC2034 # Consumed by common.sh's EXIT machinery.
FRANKEL_AUDIO_CLEANUP_ARMED=false
d5_route_setup_started=false
trap - EXIT HUP INT TERM
frankel_audio_note \
  "D5 playback complete; EP6 and both amps are off and owned services are restored"
