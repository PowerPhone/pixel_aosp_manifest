#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

readonly d0_playback_device=0
readonly d0_frontend_channels=2
readonly d0_frontend_sample_bytes=4
readonly d0_ring_bytes=15360
readonly d0_buffer_bytes_max=98304
readonly d0_default_go_timeout_seconds=1200
readonly d0_default_staged_player_bin=/vendor/bin/frankel_aoc_staged_play
readonly d0_default_tinyplay_bin=/system/bin/tinyplay
readonly d0_digital_pcm_volume=817
readonly d0_q48_start_threshold=1440
readonly d0_q192_start_threshold=1920
readonly d0_default_rw_efault_retries=32
readonly d0_default_rw_efault_sleep_us=1000
readonly d0_vendor_build_id=CP2A.260805.005
# shellcheck disable=SC2154 # Defined by sourced common.sh.
readonly d0_live_patcher="$frankel_audio_project_root/tools/audio/patch_frankel_aoc_live_speaker_192k.py"

readonly -a d0_audio_services=(
  audioserver
  vendor.audio-hal-powerphone
  vendor.audio-hal-aidl
)
declare -A d0_initial_service_states=()
d0_services_snapshotted=false
d0_services_stopped=false
d0_route_setup_started=false
d0_restart_count=
d0_coredump_count=
d0_ready_file_created=false
d0_ready_partial=

usage() {
  cat <<'USAGE'
Usage:
  d0-speaker-192k.sh --file WAV [--endpoint ENDPOINT] [--amp-gain RAW]
    [--pipeline q48-s32|q192-s16|q192-s32-2slot]
    [--codec-route high-rate|normal-asprx1|dual-asprx1]
    [--asp-mode keep|on|bypass]
    [--player staged|tinyplay] [--player-bin PATH]
    [--geometry 480x4|768x2|960x2|1920x2] [--start-threshold FRAMES]
    [--rt-priority PRIORITY] [--pcm-wait-ms MILLISECONDS]
    [--ready-file PATH --go-file PATH] [--go-timeout SECONDS]
    [--allow-xruns] [--skip-live-patch-check]
    [--services-already-stopped] [ADB options]

Required:
  --file WAV                 Local 192 kHz, stereo, S32_LE PCM WAV.

Optional:
  --endpoint ENDPOINT        none, earpiece, or bottom (default: none).
                             'none' keeps both physical amps off and qualifies
                             only the D0/AoC transport. A physical endpoint
                             temporarily receives its stock-route Digital PCM
                             Volume value 817; the inactive side is untouched.
  --amp-gain RAW             Both CS35L43 raw Amp Gain controls, 0..20
                             (default: 0).
  --codec-route ROUTE        high-rate selects PCM Zero, High Rate ASPRX1,
                             and ultrasonic In Band (default). normal-asprx1
                             selects PCM ASPRX1, High Rate Zero, and ultrasonic
                             Disabled to compare the normal 192 kHz amp input.
                             dual-asprx1 feeds both inputs with In Band enabled
                             to diagnose DAPM power routing; use low gain.
                             These route comparisons have no demonstrated
                             acoustic response or bandwidth qualification.
  --asp-mode MODE           keep preserves the AoC speaker ASP mode (default).
                             on selects ASP_ON; bypass selects ASP_BYPASS.
                             An explicit setting is restored during cleanup.
  --pipeline PIPELINE        q48-s32 uses 48-frame AoC jobs and a 24.576 MHz
                             four-S32 backend; q192-s16 uses native 192-frame
                             jobs and a 12.288 MHz four-S16 backend;
                             q192-s32-2slot uses native 192-frame jobs and a
                             12.288 MHz two-S32 backend. All keep the physical
                             backend declaration at 192 kHz. The
                             transport-tested default is q192-s32-2slot.
  --player PLAYER            staged uses frankel_aoc_staged_play for the
                             transport-tested q48-s32 path and guarded native
                             q192 two-slot diagnostics (default: staged).
                             tinyplay retains the older diagnostic path.
  --player-bin PATH          Remote executable. Defaults to
                             /vendor/bin/frankel_aoc_staged_play for staged
                             or /system/bin/tinyplay for tinyplay.
  --geometry GEOMETRY        480x4 (3,840-byte periods), 768x2 (6,144-byte
                             periods), 960x2 (7,680-byte periods), or 1920x2
                             (15,360-byte periods). The default is 1920x2,
                             the transport-tested native-q192 geometry.
  --start-threshold FRAMES   Staged-player ALSA start threshold. The native
                             q192 1920x2 qualification value is 1920 frames.
                             The first complete physical-ring period triggers
                             START. The legacy q48 480x4 default is 1440.
                             Only valid with --player staged.
  --rt-priority PRIORITY     Run the selected player SCHED_FIFO at 1..99, or
                             0 for normal scheduling (default: 90).
  --pcm-wait-ms MILLISECONDS Temporarily set the ALSA no-progress wait to
                             1..10000 ms, then restore it during cleanup.
                             Unset by default. This vendor driver converts
                             milliseconds to jiffies before ALSA converts the
                             value a second time: on Frankel's HZ=250 kernel,
                             200 therefore expires after about 52 ms. Treat it
                             only as an aggressive stall diagnostic.
  --skip-live-patch-check    Deliberately skip the guarded AoC profile
                             readback for an isolated development trial.
  --allow-xruns              Keep a complete staged diagnostic run even when
                             the helper reports xruns; never for qualification.
  --services-already-stopped Require, but do not stop or restart, the three
                             audio services. Used when a parent owns them.
  --ready-file PATH          Paired host-side pre-stage handshake marker.
  --go-file PATH             Paired host-side release marker. When both are
                             supplied, keep EP1, ultrasonic mode, and both
                             amps off until PATH appears.
  --go-timeout SECONDS       Bounded wait for --go-file after readiness
                             (default: 1200; only valid with the pair).
  --adb PATH                 adb binary (default: project platform-tools).
  --serial SERIAL            Select one ADB device.
  --adb-server-port PORT     Existing ADB server port (default: 5038).
  -h, --help                 Show this text without contacting a device.

This Frankel PCM 0,0 hardware wrapper routes EP1 / AoC Source 0 to TDM_0_RX
and opens the frontend as 192000 Hz, stereo S32_LE. The transport-tested
native-q192 path uses frankel_aoc_staged_play with a 1920x2 buffer and submits
one complete 15,360-byte physical-ring quantum per raw WRITEI call. ALSA starts
at 1920 frames; the one-period-lag D0 progress implementation provides the
reporting cushion needed to enqueue the following period without claiming
progress ahead of the real AoC counter. It requires the helper to
report the complete WAV payload and zero xruns. Only a bounded retry event at
the first physical-period boundary is accepted.
The legacy q48 and tinyplay modes remain deliberate comparison paths.
Both supported geometries keep each userspace period at or below the observed
15,360-byte audio_playback0 Down ring. The pipeline option selects a coherent
physical backend and its matching guarded AoC profile without changing the
frontend.

The pipeline-selected live profile must already be uniformly applied after
the current AoC/device boot. The
wrapper checks it before and after playback but does not write AoC code. Apply
the selected profile separately, with every playback PCM closed, using:
  python3 tools/audio/patch_frankel_aoc_live_speaker_192k.py apply \
    --profile PROFILE_FROM_THIS_WRAPPER

The running vendor_kernel_boot must also contain the EP1 192 kHz DAI mask,
the global zero-write-pointer reset fix, and the D0 one-period-lag progress
mode. The transport-tested kernel retains real mailbox progress plus the 1 ms
real-counter poll and reports max(previous, actual minus one physical period).
It has no prefill, availability bypass, or synthetic counter. A bounded
transient EFAULT is permitted only while the second period waits at the first
15,360-byte boundary; any later-offset retry is terminal. Its exact module
SHA-256 is
37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6.
This wrapper cannot prove those image bytes. A physical-speaker run also
requires the
exact-stock CS35L43 GLOBAL_FS96 patch for the default high-rate route: normal
PCM Source stays at Zero, High Rate PCM Source receives ASPRX1, and In Band
mode supplies the x2 192 kHz amp path. The normal-asprx1 comparison uses the
driver's 192 kHz GLOBAL_FS entry with ultrasonic mode Disabled. It verifies a
complete zero-xrun staged-player run (or rejects
tinyplay's otherwise-zero exit-status error text in diagnostic mode), but it
does not prove acoustic bandwidth.

The optional ready/go handshake lets an orchestrator push the WAV and finish
all non-powered TDM/codec setup before starting a simultaneous capture. The
ready marker is published atomically only after those settings are verified;
the wrapper then waits a bounded time for go before enabling ultrasonic mode,
EP1, and exactly one selected amp. Both marker paths are local, not on-device.
Because `PCM Stream Wait Time in MSec` is card-wide until each PCM copies it
during `hw_params`, coordinated mode publishes 10000 before readiness and
defers any requested short D0 value until after D10 is running. This prevents
a D0 stress setting from shortening D10's blocking-read timeout.

The wrapper snapshots audioserver and both audio HAL services, stops all of
them before profile/routing work, and restores only services found running.
On success, error, or signal it first forces both amps and EP1 off and verifies
that hard-off state. If hard-off cannot be proven, services remain stopped.
USAGE
}

file=
endpoint=none
amp_gain=0
pipeline=q192-s32-2slot
codec_route=high-rate
asp_mode=keep
player=staged
geometry=1920x2
start_threshold=
start_threshold_set=false
rt_priority=90
pcm_wait_ms=
pcm_wait_deferred=false
skip_live_patch_check=false
allow_xruns=false
services_already_stopped=false
player_bin=
ready_file=
go_file=
go_timeout_seconds=$d0_default_go_timeout_seconds
go_timeout_set=false

d0_select_pipeline() {
  case "$pipeline" in
    q48-s32)
      d0_live_profile=experimental-enum7-early-q48-tdm24576-192-4xs32-source0
      d0_backend_format=S32_LE
      d0_backend_channel_enum=Four
      d0_backend_channel_count=4
      d0_backend_slot_enum=Four
      d0_backend_slot_count=4
      d0_backend_bclk_hz=24576000
      ;;
    q192-s16)
      d0_live_profile=experimental-enum7-q192-tdm12288-192-4xs16-dma-source0
      d0_backend_format=S16_LE
      d0_backend_channel_enum=Four
      d0_backend_channel_count=4
      d0_backend_slot_enum=Four
      d0_backend_slot_count=4
      d0_backend_bclk_hz=12288000
      ;;
    q192-s32-2slot)
      d0_live_profile=experimental-enum7-q192-tdm12288-192-2xs32-dma-source0
      d0_backend_format=S32_LE
      d0_backend_channel_enum=Two
      d0_backend_channel_count=2
      d0_backend_slot_enum=Two
      d0_backend_slot_count=2
      d0_backend_bclk_hz=12288000
      ;;
    *)
      frankel_audio_die \
        "pipeline must be q48-s32, q192-s16, or q192-s32-2slot"
      ;;
  esac
}

while (( $# > 0 )); do
  case "$1" in
    --file|--endpoint|--amp-gain|--pipeline|--codec-route|--asp-mode|--player|--geometry|--start-threshold|--rt-priority|--pcm-wait-ms|--ready-file|--go-file|--go-timeout|\
    --player-bin|--adb|--serial|--adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --file) file=$value ;;
        --endpoint) endpoint=$value ;;
        --amp-gain) amp_gain=$value ;;
        --pipeline) pipeline=$value ;;
        --codec-route) codec_route=$value ;;
        --asp-mode) asp_mode=$value ;;
        --player) player=$value ;;
        --geometry) geometry=$value ;;
        --start-threshold)
          start_threshold=$value
          start_threshold_set=true
          ;;
        --rt-priority) rt_priority=$value ;;
        --pcm-wait-ms) pcm_wait_ms=$value ;;
        --ready-file) ready_file=$value ;;
        --go-file) go_file=$value ;;
        --go-timeout)
          go_timeout_seconds=$value
          go_timeout_set=true
          ;;
        --player-bin) player_bin=$value ;;
        --adb) FRANKEL_AUDIO_ADB=$value ;;
        --serial) FRANKEL_AUDIO_SERIAL=$value ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$value ;;
      esac
      ;;
    --skip-live-patch-check)
      skip_live_patch_check=true
      shift
      ;;
    --allow-xruns)
      allow_xruns=true
      shift
      ;;
    --services-already-stopped)
      services_already_stopped=true
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
[[ -f "$file" ]] || frankel_audio_die "WAV file not found: $file"
file=$(realpath -- "$file")
case "$endpoint" in
  none) d0_digital_pcm_volume_control= ;;
  earpiece) d0_digital_pcm_volume_control='Digital PCM Volume' ;;
  bottom) d0_digital_pcm_volume_control='R Digital PCM Volume' ;;
  *) frankel_audio_die "endpoint must be none, earpiece, or bottom; simultaneous amps are unsafe" ;;
esac
d0_select_pipeline
case "$codec_route" in
  high-rate)
    d0_pcm_source=Zero
    d0_high_rate_pcm_source=ASPRX1
    d0_ultrasonic_mode='In Band'
    ;;
  normal-asprx1)
    d0_pcm_source=ASPRX1
    d0_high_rate_pcm_source=Zero
    d0_ultrasonic_mode=Disabled
    ;;
  dual-asprx1)
    d0_pcm_source=ASPRX1
    d0_high_rate_pcm_source=ASPRX1
    d0_ultrasonic_mode='In Band'
    ;;
  *) frankel_audio_die "codec route must be high-rate, normal-asprx1, or dual-asprx1" ;;
esac
case "$asp_mode" in
  keep) d0_asp_mode_value= ;;
  on) d0_asp_mode_value=ASP_ON ;;
  bypass) d0_asp_mode_value=ASP_BYPASS ;;
  *) frankel_audio_die "ASP mode must be keep, on, or bypass" ;;
esac
case "$geometry" in
  480x4)
    d0_period_size=480
    d0_period_count=4
    ;;
  960x2)
    d0_period_size=960
    d0_period_count=2
    ;;
  768x2)
    d0_period_size=768
    d0_period_count=2
    ;;
  1920x2)
    d0_period_size=1920
    d0_period_count=2
    ;;
  *) frankel_audio_die "geometry must be 480x4, 768x2, 960x2, or 1920x2" ;;
esac
if [[ "$start_threshold_set" == false ]]; then
  case "$pipeline:$geometry" in
    q192-s32-2slot:*) start_threshold=$d0_q192_start_threshold ;;
    *) start_threshold=$d0_q48_start_threshold ;;
  esac
fi
case "$player" in
  staged)
    case "$pipeline:$geometry" in
      q48-s32:480x4|q192-s32-2slot:480x4|q192-s32-2slot:768x2|q192-s32-2slot:960x2|q192-s32-2slot:1920x2) ;;
      q48-s32:*)
        frankel_audio_die \
          "the staged q48-s32 player requires --geometry 480x4"
        ;;
      q192-s32-2slot:*)
        frankel_audio_die \
          "the staged q192-s32-2slot player requires --geometry 480x4, 768x2, 960x2, or 1920x2"
        ;;
      *)
        frankel_audio_die \
          "the staged player supports q48-s32 or q192-s32-2slot"
        ;;
    esac
    ;;
  tinyplay)
    [[ "$start_threshold_set" == false ]] || \
      frankel_audio_die "--start-threshold is only valid with --player staged"
    ;;
  *) frankel_audio_die "player must be staged or tinyplay" ;;
esac
if [[ -z "$player_bin" ]]; then
  case "$player" in
    staged) player_bin=$d0_default_staged_player_bin ;;
    tinyplay) player_bin=$d0_default_tinyplay_bin ;;
  esac
fi
[[ "$player_bin" == /* ]] || \
  frankel_audio_die "--player-bin must be an absolute remote path"
if [[ "$pipeline" == q192-s32-2slot && "$geometry" != 1920x2 ]]; then
  frankel_audio_note \
    "WARNING: q192-s32-2slot geometry $geometry is experimental; only 1920x2 with start threshold 1920 is the duplex-safe qualified target"
fi
if [[ "$pipeline:$geometry" == q192-s32-2slot:1920x2 && \
      "$start_threshold" != "$d0_q192_start_threshold" ]]; then
  frankel_audio_note \
    "WARNING: native-q192 qualification requires --start-threshold $d0_q192_start_threshold; selected $start_threshold is experimental"
fi
d0_period_bytes=$((d0_period_size * d0_frontend_channels *
  d0_frontend_sample_bytes))
d0_buffer_frames=$((d0_period_size * d0_period_count))
d0_buffer_bytes=$((d0_buffer_frames * d0_frontend_channels *
  d0_frontend_sample_bytes))
[[ "$amp_gain" =~ ^[0-9]+$ ]] || \
  frankel_audio_die "raw amp gain must be a non-negative integer"
(( amp_gain <= 20 )) || \
  frankel_audio_die "raw amp gain must be between 0 and 20"
[[ "$rt_priority" =~ ^[0-9]+$ ]] || \
  frankel_audio_die "real-time priority must be a non-negative integer"
(( rt_priority <= 99 )) || \
  frankel_audio_die "real-time priority must be between 0 and 99"
if [[ "$player" == staged ]]; then
  [[ "$start_threshold" =~ ^[1-9][0-9]*$ ]] || \
    frankel_audio_die "start threshold must be a positive integer"
  (( start_threshold <= d0_buffer_frames )) || \
    frankel_audio_die \
      "start threshold $start_threshold exceeds the ${d0_buffer_frames}-frame ALSA buffer"
fi
if [[ -n "$pcm_wait_ms" ]]; then
  [[ "$pcm_wait_ms" =~ ^[1-9][0-9]*$ ]] || \
    frankel_audio_die "PCM wait time must be an integer from 1 through 10000 ms"
  (( pcm_wait_ms <= 10000 )) || \
    frankel_audio_die "PCM wait time must be an integer from 1 through 10000 ms"
fi
if [[ -n "$ready_file" || -n "$go_file" ]]; then
  [[ -n "$ready_file" && -n "$go_file" ]] || \
    frankel_audio_die "--ready-file and --go-file must be supplied together"
  frankel_audio_require_positive_integer go-timeout "$go_timeout_seconds"
  ready_file=$(realpath -m -- "$ready_file")
  go_file=$(realpath -m -- "$go_file")
  [[ "$ready_file" != "$go_file" ]] || \
    frankel_audio_die "--ready-file and --go-file must be different paths"
  ready_directory=${ready_file%/*}
  go_directory=${go_file%/*}
  [[ "$ready_directory" != "$ready_file" ]] || ready_directory=.
  [[ "$go_directory" != "$go_file" ]] || go_directory=.
  [[ -d "$ready_directory" && -w "$ready_directory" ]] || \
    frankel_audio_die "ready-file directory is not writable: $ready_directory"
  [[ -d "$go_directory" ]] || \
    frankel_audio_die "go-file directory does not exist: $go_directory"
  [[ ! -e "$ready_file" ]] || \
    frankel_audio_die "ready-file already exists: $ready_file"
  [[ ! -e "$go_file" ]] || \
    frankel_audio_die "go-file already exists: $go_file"
else
  [[ "$go_timeout_set" == false ]] || \
    frankel_audio_die "--go-timeout requires --ready-file and --go-file"
fi
(( d0_period_bytes <= d0_ring_bytes )) || \
  frankel_audio_die "D0 period exceeds the 15,360-byte physical Down ring"
(( d0_buffer_bytes <= d0_buffer_bytes_max )) || \
  frankel_audio_die "D0 ALSA buffer exceeds the advertised 98,304-byte limit"
frankel_audio_validate_period_geometry \
  "$d0_frontend_channels" "$d0_frontend_sample_bytes" \
  "$d0_period_size" "$d0_period_count"

wav_info=$("$script_directory/generate-signal.py" inspect "$file" \
  --expect-rate 192000 --expect-channels 2 --expect-bits 32)
printf '%s\n' "$wav_info"
[[ "$wav_info" =~ frames=([0-9]+) ]] || \
  frankel_audio_die "cannot parse validated WAV frame count"
d0_wav_frames=${BASH_REMATCH[1]}
d0_expected_bytes=$((d0_wav_frames * d0_frontend_channels *
  d0_frontend_sample_bytes))
(( d0_wav_frames > d0_buffer_frames )) || \
  frankel_audio_die \
    "WAV must exceed one ${d0_buffer_frames}-frame D0 buffer to test period progress"
if [[ "$player" == staged ]]; then
  (( d0_wav_frames % d0_period_size == 0 )) || \
    frankel_audio_die \
      "staged-player WAV must contain a whole number of ${d0_period_size}-frame writes"
fi

d0_get_service_state() {
  frankel_audio_remote_exec getprop "init.svc.$1"
}

d0_snapshot_services() {
  local service state
  for service in "${d0_audio_services[@]}"; do
    state=$(d0_get_service_state "$service")
    case "$state" in
      running|stopped) ;;
      *)
        frankel_audio_die \
          "cannot take ownership of $service from state '${state:-unset}'"
        ;;
    esac
    d0_initial_service_states["$service"]=$state
  done
  d0_services_snapshotted=true
}

d0_require_services_stopped() {
  local attempt service all_stopped
  for ((attempt = 0; attempt < 30; attempt++)); do
    all_stopped=true
    for service in "${d0_audio_services[@]}"; do
      if [[ "$(d0_get_service_state "$service")" != stopped ]]; then
        all_stopped=false
        frankel_audio_remote_exec stop "$service" >/dev/null 2>&1 || true
      fi
    done
    [[ "$all_stopped" == true ]] && return 0
    frankel_audio_remote_exec sleep 0.1
  done
  return 1
}

d0_services_are_stopped() {
  local service
  for service in "${d0_audio_services[@]}"; do
    [[ "$(d0_get_service_state "$service")" == stopped ]] || return 1
  done
}

d0_stop_services() {
  # Stopping audioserver can run init actions which restart a primary HAL.
  # Stop both HALs afterward and reassert all three states while polling.
  frankel_audio_remote_exec stop audioserver
  frankel_audio_remote_exec stop vendor.audio-hal-powerphone
  frankel_audio_remote_exec stop vendor.audio-hal-aidl
  d0_require_services_stopped || \
    frankel_audio_die "audio services did not all reach stopped state"
  d0_services_stopped=true
}

d0_wait_service_running() {
  local service=$1
  local attempt
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ "$(d0_get_service_state "$service")" == running ]] && return 0
    frankel_audio_remote_exec sleep 0.1
  done
  return 1
}

d0_restore_services() {
  [[ "$d0_services_snapshotted" == true && \
     "$d0_services_stopped" == true ]] || return 0
  local service
  for service in vendor.audio-hal-aidl vendor.audio-hal-powerphone; do
    if [[ ${d0_initial_service_states[$service]} == running ]]; then
      frankel_audio_remote_exec start "$service"
      d0_wait_service_running "$service" || {
        printf 'error: %s did not return to running state\n' "$service" >&2
        return 1
      }
    fi
  done
  service=audioserver
  if [[ ${d0_initial_service_states[$service]} == running ]]; then
    frankel_audio_remote_exec start "$service"
    d0_wait_service_running "$service" || {
      printf 'error: %s did not return to running state\n' "$service" >&2
      return 1
    }
  fi
  for service in "${d0_audio_services[@]}"; do
    if [[ "$(d0_get_service_state "$service")" != \
          "${d0_initial_service_states[$service]}" ]]; then
      printf 'error: %s did not return to its initial %s state\n' \
        "$service" "${d0_initial_service_states[$service]}" >&2
      return 1
    fi
  done
  d0_services_stopped=false
}

d0_profile_check() {
  if [[ "$skip_live_patch_check" == true ]]; then
    frankel_audio_note \
      "WARNING: skipping Source0 live-profile readback by explicit request"
    return 0
  fi
  local -a command=(
    python3 "$d0_live_patcher" check-patched
    --profile "$d0_live_profile"
    --adb "$FRANKEL_AUDIO_ADB"
    --adb-server-port "${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}"
  )
  if [[ -n ${FRANKEL_AUDIO_SERIAL:-} ]]; then
    command+=(--serial "$FRANKEL_AUDIO_SERIAL")
  fi
  d0_services_are_stopped || \
    frankel_audio_die "an audio service restarted before live-profile check"
  PYTHONUNBUFFERED=1 "${command[@]}"
}

d0_require_service_geometry() {
  local inventory header down
  inventory=$(frankel_audio_remote_exec \
    cat /sys/devices/platform/9000000.aoc/services)
  header=$(awk '/"audio_playback0"[[:space:]]+mbox/ {print; exit}' \
    <<<"$inventory")
  [[ "$header" =~ \"audio_playback0\"[[:space:]]+mbox[[:space:]]+4$ ]] || \
    frankel_audio_die \
      "audio_playback0 is missing or has unexpected mailbox metadata: ${header:-absent}"
  down=$(awk '
    /"audio_playback0"[[:space:]]+mbox/ { selected = 1; next }
    selected && /Down Size:/ { print; exit }
  ' <<<"$inventory")
  [[ "$down" =~ ^[[:space:]]*Down[[:space:]]+Size:1x15360B([[:space:]]|$) ]] || \
    frankel_audio_die \
      "audio_playback0 Down ring is not exactly 1x15360B: ${down:-absent}"
}

d0_read_aoc_counter() {
  local name=$1
  local value
  value=$(frankel_audio_remote_exec \
    cat "/sys/devices/platform/9000000.aoc/$name")
  [[ "$value" =~ ^[0-9]+$ ]] || \
    frankel_audio_die "malformed AoC $name counter: $value"
  printf '%s\n' "$value"
}

d0_snapshot_aoc_generation() {
  d0_restart_count=$(d0_read_aoc_counter restart_count)
  d0_coredump_count=$(d0_read_aoc_counter coredump_count)
}

d0_verify_aoc_generation() {
  local restart_count coredump_count
  restart_count=$(d0_read_aoc_counter restart_count)
  coredump_count=$(d0_read_aoc_counter coredump_count)
  [[ "$restart_count" == "$d0_restart_count" && \
     "$coredump_count" == "$d0_coredump_count" ]] || \
    frankel_audio_die \
      "AoC generation changed during D0 playback (restart ${d0_restart_count}->${restart_count}, coredump ${d0_coredump_count}->${coredump_count})"
}

d0_require_control_one() {
  local control=$1
  local actual
  actual=$(frankel_audio_tinymix_get "$control") || \
    frankel_audio_die "cannot read mixer control: $control"
  [[ "$actual" == 1 || "$actual" == On ]] || \
    frankel_audio_die \
      "$control did not enter the owned on state (got $actual)"
}

d0_cleanup_handshake() {
  [[ -n "$ready_file" ]] || return 0
  if [[ -n "$d0_ready_partial" ]]; then
    rm -f -- "$d0_ready_partial"
  fi
  if [[ "$d0_ready_file_created" == true ]]; then
    rm -f -- "$ready_file"
    d0_ready_file_created=false
  fi
}

d0_publish_ready_and_wait_for_go() {
  [[ -n "$ready_file" ]] || return 0
  local deadline
  d0_ready_partial="${ready_file}.partial-${BASHPID}"
  [[ ! -e "$d0_ready_partial" ]] || \
    frankel_audio_die \
      "ready-file temporary path already exists: $d0_ready_partial"
  printf 'pid=%s\nstate=staged-safe-off\n' "$BASHPID" >"$d0_ready_partial"
  mv -- "$d0_ready_partial" "$ready_file"
  d0_ready_partial=
  d0_ready_file_created=true
  frankel_audio_note \
    "D0 is pre-staged with EP1 and both amps off; waiting up to ${go_timeout_seconds}s for go"

  deadline=$((SECONDS + go_timeout_seconds))
  while (( SECONDS < deadline )); do
    if [[ -e "$go_file" ]]; then
      [[ -f "$go_file" ]] || \
        frankel_audio_die "go-file exists but is not a regular file: $go_file"
      d0_services_are_stopped || \
        frankel_audio_die "an audio service restarted while D0 was pre-staged"
      frankel_audio_note "received D0 go signal"
      return 0
    fi
    sleep 0.1
  done
  frankel_audio_die \
    "timed out after ${go_timeout_seconds}s waiting for go-file: $go_file"
}

d0_exit_handler() {
  local status=$?
  local cleanup_failed=false
  local hard_off_proven=true
  trap - EXIT HUP INT TERM
  set +e
  frankel_audio_cleanup || cleanup_failed=true
  if [[ "$d0_route_setup_started" == true ]]; then
    frankel_audio_verify_safe_controls || {
      cleanup_failed=true
      hard_off_proven=false
    }
  fi
  if [[ "$hard_off_proven" == true ]]; then
    d0_restore_services || cleanup_failed=true
  else
    printf '%s\n' \
      'error: leaving audio services stopped because speaker hard-off was not verified' >&2
  fi
  d0_cleanup_handshake || cleanup_failed=true
  if (( status == 0 )) && [[ "$cleanup_failed" == true ]]; then
    status=1
  fi
  exit "$status"
}

# No extra stock /system/bin utilities are required beyond tinymix here.
# shellcheck disable=SC2119
frankel_audio_initialize_device
frankel_audio_remote_exec test -x "$player_bin" || \
  frankel_audio_die "selected remote player is not executable: $player_bin"
vendor_build=$(frankel_audio_remote_exec getprop ro.vendor.build.id)
[[ "$vendor_build" == "$d0_vendor_build_id" ]] || \
  frankel_audio_die \
    "refusing unreviewed vendor build $vendor_build (expected $d0_vendor_build_id)"
for host_utility in awk date python3 realpath; do
  command -v "$host_utility" >/dev/null 2>&1 || \
    frankel_audio_die "required host command not found: $host_utility"
done
if [[ "$skip_live_patch_check" == false ]]; then
  [[ -f "$d0_live_patcher" ]] || \
    frankel_audio_die "live speaker patcher is missing: $d0_live_patcher"
fi

d0_snapshot_services
frankel_audio_arm_cleanup
trap d0_exit_handler EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$services_already_stopped" == true ]]; then
  d0_services_are_stopped || \
    frankel_audio_die \
      "--services-already-stopped requires all audio services stopped"
else
  d0_stop_services
fi

# Hard-off controls are registered before the first mixer mutation and are
# never restored to a potentially-on snapshot.
frankel_audio_register_safe_control 'Main AMP Enable Switch' 0
frankel_audio_register_safe_control 'R Main AMP Enable Switch' 0
frankel_audio_register_safe_control 'TDM_0_RX Mixer EP1' 0
frankel_audio_register_safe_control 'Ultrasonic Mode' Disabled
frankel_audio_register_safe_control 'R Ultrasonic Mode' Disabled
d0_route_setup_started=true

frankel_audio_require_control_zero 'Main AMP Enable Switch'
frankel_audio_require_control_zero 'R Main AMP Enable Switch'
frankel_audio_require_control_zero 'TDM_0_RX Mixer US'
frankel_audio_require_control_value 'Ultrasonic Mode' Disabled
frankel_audio_require_control_value 'R Ultrasonic Mode' Disabled
for active_source in EP1 EP2 EP3 EP4 EP5 EP6 EP7 EP8 IMSV NoHost1 RAW VOIP; do
  frankel_audio_require_control_zero "TDM_0_RX Mixer $active_source"
done

if [[ -n "$ready_file" ]]; then
  # This card-wide default is copied into each PCM's substream->wait_time
  # during hw_params.  In coordinated D0+D10 mode the parent opens D10 only
  # after our ready marker.  Snapshot now for fail-safe cleanup and explicitly
  # publish the stock-safe 10-second value before that marker; this remains
  # necessary after an interrupted experiment leaves a shorter global value.
  frankel_audio_snapshot_scalar 'PCM Stream Wait Time in MSec'
  frankel_audio_tinymix_set 'PCM Stream Wait Time in MSec' 10000
  frankel_audio_require_control_value \
    'PCM Stream Wait Time in MSec' 10000
  if [[ -n "$pcm_wait_ms" ]]; then
    # Apply D0's requested short timeout only after the parent has observed
    # D10 running and releases D0.
    pcm_wait_deferred=true
    frankel_audio_note \
      "set capture-safe ALSA wait to 10000 ms; will set D0 to ${pcm_wait_ms} ms after coordinated release"
  else
    frankel_audio_note "set capture-safe ALSA wait to 10000 ms for coordinated D10 open"
  fi
elif [[ -n "$pcm_wait_ms" ]]; then
  frankel_audio_snapshot_and_set_scalar \
    'PCM Stream Wait Time in MSec' "$pcm_wait_ms"
  frankel_audio_require_control_value \
    'PCM Stream Wait Time in MSec' "$pcm_wait_ms"
  frankel_audio_note \
    "temporarily set ALSA no-progress wait to ${pcm_wait_ms} ms"
fi

d0_profile_check
d0_require_service_geometry
d0_snapshot_aoc_generation

remote_file="$FRANKEL_AUDIO_REMOTE_DIRECTORY/frankel-d0-speaker-${BASHPID}.wav"
frankel_audio_register_remote_temp "$remote_file"
frankel_audio_note "pushing validated multi-buffer WAV to Frankel"
frankel_audio_adb push "$file" "$remote_file" >/dev/null
frankel_audio_remote_exec chmod 0644 "$remote_file"

# Keep route and amps off until every bus and codec setting is complete. D0
# remains stereo/S32 at the frontend; the selected pipeline supplies a
# coherent physical backend with its independently selected slot geometry.
if [[ -n "$d0_asp_mode_value" ]]; then
  frankel_audio_snapshot_and_set_scalar \
    'AoC Speaker Mixer ASP Mode' "$d0_asp_mode_value"
fi
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Sample Rate' SR_192K
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Format' "$d0_backend_format"
frankel_audio_snapshot_and_set_scalar \
  'TDM_0_RX Chan' "$d0_backend_channel_enum"
frankel_audio_snapshot_and_set_scalar \
  'TDM_0_RX nSlot' "$d0_backend_slot_enum"
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX SlotFmt' "$d0_backend_format"
for prefix in '' 'R '; do
  frankel_audio_snapshot_and_set_scalar "${prefix}DSP RX1 Source" ASPRX1
  frankel_audio_snapshot_and_set_scalar "${prefix}DSP RX2 Source" ASPRX1
  # High-rate mode doubles GLOBAL_FS96; normal-asprx1 uses GLOBAL_FS192.
  # The dual-input diagnostic also activates the normal-input DAPM path.
  frankel_audio_snapshot_and_set_scalar "${prefix}PCM Source" "$d0_pcm_source"
  frankel_audio_snapshot_and_set_scalar \
    "${prefix}High Rate PCM Source" "$d0_high_rate_pcm_source"
  frankel_audio_snapshot_and_set_scalar "${prefix}Amp Gain" "$amp_gain"
done
if [[ -n "$d0_digital_pcm_volume_control" ]]; then
  # Stock physical routes use 817. Own only the selected codec's volume while
  # both amps and EP1 are hard-off; cleanup restores it only after reasserting
  # those hard-off controls. The inactive codec volume is never read or written.
  frankel_audio_snapshot_and_set_scalar \
    "$d0_digital_pcm_volume_control" "$d0_digital_pcm_volume"
fi

# Prove every non-powered setting while no simultaneous D10 session exists.
# In coordinated mode this is the last mixer traffic before the parent starts
# capture; only the three activation classes below are touched after go.
if [[ -n "$d0_asp_mode_value" ]]; then
  frankel_audio_require_control_value \
    'AoC Speaker Mixer ASP Mode' "$d0_asp_mode_value"
fi
frankel_audio_require_control_value 'TDM_0_RX Sample Rate' SR_192K
frankel_audio_require_control_value 'TDM_0_RX Format' "$d0_backend_format"
frankel_audio_require_control_value \
  'TDM_0_RX Chan' "$d0_backend_channel_enum"
frankel_audio_require_control_value \
  'TDM_0_RX nSlot' "$d0_backend_slot_enum"
frankel_audio_require_control_value 'TDM_0_RX SlotFmt' "$d0_backend_format"
frankel_audio_require_control_zero 'TDM_0_RX Mixer EP1'
frankel_audio_require_control_zero 'TDM_0_RX Mixer US'
frankel_audio_require_control_value 'Ultrasonic Mode' Disabled
frankel_audio_require_control_value 'R Ultrasonic Mode' Disabled
frankel_audio_require_control_zero 'Main AMP Enable Switch'
frankel_audio_require_control_zero 'R Main AMP Enable Switch'
for prefix in '' 'R '; do
  frankel_audio_require_control_value "${prefix}DSP RX1 Source" ASPRX1
  frankel_audio_require_control_value "${prefix}DSP RX2 Source" ASPRX1
  frankel_audio_require_control_value "${prefix}PCM Source" "$d0_pcm_source"
  frankel_audio_require_control_value \
    "${prefix}High Rate PCM Source" "$d0_high_rate_pcm_source"
  frankel_audio_require_control_value "${prefix}Amp Gain" "$amp_gain"
done
if [[ -n "$d0_digital_pcm_volume_control" ]]; then
  frankel_audio_require_control_value \
    "$d0_digital_pcm_volume_control" "$d0_digital_pcm_volume"
fi
d0_services_are_stopped || \
  frankel_audio_die "an audio service restarted during D0 pre-stage setup"

d0_publish_ready_and_wait_for_go
if [[ "$pcm_wait_deferred" == true ]]; then
  frankel_audio_tinymix_set 'PCM Stream Wait Time in MSec' "$pcm_wait_ms"
  frankel_audio_require_control_value \
    'PCM Stream Wait Time in MSec' "$pcm_wait_ms"
  frankel_audio_note \
    "temporarily set ALSA no-progress wait to ${pcm_wait_ms} ms after coordinated release"
fi
d0_verify_aoc_generation

frankel_audio_tinymix_set 'Ultrasonic Mode' "$d0_ultrasonic_mode"
frankel_audio_tinymix_set 'R Ultrasonic Mode' "$d0_ultrasonic_mode"
case "$endpoint" in
  none)
    ;;
  earpiece)
    frankel_audio_tinymix_set 'Main AMP Enable Switch' 1
    ;;
  bottom)
    frankel_audio_tinymix_set 'R Main AMP Enable Switch' 1
    ;;
esac

d0_services_are_stopped || \
  frankel_audio_die "an audio service restarted before D0 route activation"
frankel_audio_note \
  "playing PCM 0,0: endpoint=$endpoint pipeline=$pipeline codec_route=$codec_route asp_mode=$asp_mode player=$player frontend=192000/s32/2ch backend=192000/${d0_backend_format,,}/${d0_backend_channel_count}ch/${d0_backend_slot_count}slot/${d0_backend_bclk_hz}Hz periods=${d0_period_size}x${d0_period_count} buffer=${d0_buffer_bytes}B rt=${rt_priority}"
# Bind EP1 and enter the selected player in one remote shell. The AoC OUTPUTTER arms when
# this control is raised; even the host round trip for a second adb invocation
# can otherwise leave an active source with no PCM producer long enough to
# trip its timer assertion. Every distinguishing bus/codec value was already
# verified above while the route was safely off, and cleanup verifies the
# powered controls hard-off.
set +e
declare -a playback_command
case "$player" in
  staged)
    playback_command=(
      "$player_bin"
      --card "$FRANKEL_AUDIO_CARD" --device "$d0_playback_device"
      --rate 192000 --channels "$d0_frontend_channels" --format s32
      --period-size "$d0_period_size" --period-count "$d0_period_count"
      --start-threshold "$start_threshold"
      --rw-efault-retries "$d0_default_rw_efault_retries"
      --rw-efault-sleep-us "$d0_default_rw_efault_sleep_us"
      --route-control 'TDM_0_RX Mixer EP1'
      --access rw
      "$remote_file"
    )
    ;;
  tinyplay)
    playback_command=(
      "$player_bin" "$remote_file"
      -D "$FRANKEL_AUDIO_CARD" -d "$d0_playback_device"
      -p "$d0_period_size" -n "$d0_period_count"
    )
    ;;
esac
if (( rt_priority > 0 )); then
  playback_command=(/system/bin/chrt -f "$rt_priority" "${playback_command[@]}")
fi
playback_start_ns=$(date +%s%N)
playback_output=$(frankel_audio_run_guarded_after_control \
  'TDM_0_RX Mixer EP1' 1 \
  "${playback_command[@]}" 2>&1)
playback_status=$?
playback_end_ns=$(date +%s%N)
playback_elapsed_ns=$((playback_end_ns - playback_start_ns))
set -e
printf '%s\n' "$playback_output"
printf 'playback_elapsed_ns=%s\n' "$playback_elapsed_ns"
if (( playback_status != 0 )); then
  if [[ "$allow_xruns" != true || "$player" != staged ||
        ! "$playback_output" =~ streamed=${d0_expected_bytes}[[:space:]]bytes[[:space:]]xruns=[1-9][0-9]* ]]; then
    frankel_audio_die "$player player/ADB exited with status $playback_status"
  fi
  frankel_audio_note \
    "retaining complete nonzero-xrun staged run by explicit diagnostic request"
fi
if [[ "$playback_output" =~ [Uu]nable|[Ee]rror|[Ff]ail|only[[:space:]]supports|Broken[[:space:]]pipe|I/O[[:space:]]error ]]; then
  frankel_audio_die "$player player reported a PCM error despite its process status"
fi
case "$player" in
  staged)
    staged_config="stage hw_params card=${FRANKEL_AUDIO_CARD} device=${d0_playback_device} rate=192000 channels=${d0_frontend_channels} format=s32 period_size=${d0_period_size} period_count=${d0_period_count} start_threshold=${start_threshold} access=rw"
    [[ "$playback_output" == *"$staged_config"* ]] || \
      frankel_audio_die \
        "staged player did not confirm the required PCM configuration"
    mapfile -t staged_summaries < <(
      awk '/^streamed=[0-9]+ bytes xruns=[0-9]+$/ { print }' \
        <<<"$playback_output"
    )
    (( ${#staged_summaries[@]} == 1 )) || \
      frankel_audio_die \
        "staged player did not emit exactly one transport summary"
    [[ "${staged_summaries[0]}" =~ ^streamed=([0-9]+)[[:space:]]bytes[[:space:]]xruns=([0-9]+)$ ]] || \
      frankel_audio_die "cannot parse staged-player transport summary"
    played_bytes=${BASH_REMATCH[1]}
    playback_xruns=${BASH_REMATCH[2]}
    (( played_bytes == d0_expected_bytes )) || \
      frankel_audio_die \
        "staged player wrote ${played_bytes}/${d0_expected_bytes} PCM bytes"
    if (( playback_xruns != 0 )) && [[ "$allow_xruns" != true ]]; then
      frankel_audio_die "staged player reported $playback_xruns xrun(s)"
    fi
    mapfile -t staged_retry_summaries < <(
      awk '/^rw_efault_retries=[0-9]+$/ { print }' <<<"$playback_output"
    )
    (( ${#staged_retry_summaries[@]} == 1 )) || \
      frankel_audio_die \
        "staged player did not emit exactly one raw-WRITEI retry summary"
    [[ "${staged_retry_summaries[0]}" =~ ^rw_efault_retries=([0-9]+)$ ]] || \
      frankel_audio_die "cannot parse staged-player raw-WRITEI retry summary"
    playback_efault_retries=${BASH_REMATCH[1]}
    if [[ "$pipeline:$geometry:$start_threshold" == \
          q192-s32-2slot:1920x2:1920 ]] && \
        (( playback_efault_retries > d0_default_rw_efault_retries )); then
      frankel_audio_die \
        "native-q192 qualification exceeded the bounded initial WRITEI EFAULT retry limit: $playback_efault_retries"
    fi
    mapfile -t staged_retry_events < <(
      awk '/^PCM RW write resumed after [0-9]+ EFAULT retries at [0-9]+ bytes$/ { print }' \
        <<<"$playback_output"
    )
    if [[ "$pipeline:$geometry:$start_threshold" == \
          q192-s32-2slot:1920x2:1920 ]]; then
      if (( playback_efault_retries == 0 )); then
        (( ${#staged_retry_events[@]} == 0 )) || \
          frankel_audio_die \
            "native-q192 player reported a retry event with a zero retry summary"
      else
        (( ${#staged_retry_events[@]} == 1 )) || \
          frankel_audio_die \
            "native-q192 qualification requires exactly one bounded first-boundary retry event"
        [[ "${staged_retry_events[0]}" =~ ^PCM[[:space:]]RW[[:space:]]write[[:space:]]resumed[[:space:]]after[[:space:]]([0-9]+)[[:space:]]EFAULT[[:space:]]retries[[:space:]]at[[:space:]]([0-9]+)[[:space:]]bytes$ ]] || \
          frankel_audio_die "cannot parse staged-player retry event"
        retry_event_count=${BASH_REMATCH[1]}
        retry_event_offset=${BASH_REMATCH[2]}
        (( retry_event_count == playback_efault_retries )) || \
          frankel_audio_die \
            "native-q192 retry event/summary count mismatch: $retry_event_count/$playback_efault_retries"
        (( retry_event_offset == d0_period_bytes )) || \
          frankel_audio_die \
            "native-q192 EFAULT resumed at byte $retry_event_offset; only the first $d0_period_bytes-byte boundary is qualified"
      fi
    fi
    ;;
  tinyplay)
    if [[ "$playback_output" != *"Playing sample: 2 ch, 192000 hz, 32 bit"* &&
          ! "$playback_output" =~ playing.*2[[:space:]]ch.*192000[[:space:]]hz.*32-bit ]]; then
      frankel_audio_die "tinyplay did not confirm the required frontend format"
    fi
    if [[ "$playback_output" =~ Played[[:space:]]+([0-9]+)[[:space:]]+bytes[[:space:]]+with[[:space:]]+([0-9]+)[[:space:]]+xrun\(s\)\.[[:space:]]+Remains[[:space:]]+([0-9]+)[[:space:]]+bytes\. ]]; then
      played_bytes=${BASH_REMATCH[1]}
      playback_xruns=${BASH_REMATCH[2]}
      remaining_bytes=${BASH_REMATCH[3]}
      (( played_bytes == d0_expected_bytes )) || \
        frankel_audio_die \
          "instrumented tinyplay wrote ${played_bytes}/${d0_expected_bytes} PCM bytes"
      (( playback_xruns == 0 )) || \
        frankel_audio_die \
          "instrumented tinyplay reported $playback_xruns xrun(s)"
      (( remaining_bytes == 0 )) || \
        frankel_audio_die \
          "instrumented tinyplay left $remaining_bytes PCM bytes unwritten"
    fi
    ;;
esac
d0_services_are_stopped || \
  frankel_audio_die "an audio service restarted during D0 playback"

frankel_audio_cleanup
frankel_audio_verify_safe_controls || \
  frankel_audio_die "D0 mixer cleanup could not be verified"
d0_verify_aoc_generation
d0_profile_check
d0_restore_services
d0_cleanup_handshake
# shellcheck disable=SC2034 # Consumed by common.sh's EXIT machinery.
FRANKEL_AUDIO_CLEANUP_ARMED=false
d0_route_setup_started=false
trap - EXIT HUP INT TERM
frankel_audio_note \
  "D0 playback complete; EP1 and both amps are off and owned services are restored"
