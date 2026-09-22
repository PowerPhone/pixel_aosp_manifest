#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

readonly raw192_patcher="$frankel_audio_project_root/tools/audio/patch_frankel_aoc_live_d10_raw_192k.py"
readonly raw192_freshness_validator="$frankel_audio_project_root/tools/audio/validate_frankel_d10_raw192.py"
readonly raw192_route='EP3 TX Mixer INTERNAL_MIC_TX'

usage() {
  cat <<'USAGE'
Usage:
  d10-raw192-capture.sh --output WAV --endpoint ENDPOINT --duration SECONDS
    [--period-size FRAMES] [--period-count N] [--soft-gain-db DB]
    [--dc-blocker on|off] [--use-boot-profile] [--force] [ADB options]

Required:
  --output WAV               Local destination, committed after validation.
  --endpoint ENDPOINT        raw192-pdm0, raw192-pdm1, or raw192-pdm2.
  --duration SECONDS         Positive whole-number capture duration.

Optional:
  --period-size FRAMES       Frames per period (default: 1920; multiple of 96).
  --period-count N           Periods in the ALSA buffer (default: 4).
  --soft-gain-db DB          AoC RAW capture gain, -40..30 (default: 0).
  --dc-blocker off           Must remain off for the qualified RAW path.
  --use-boot-profile         Require and retain the boot-certified D10 profile
                             instead of applying and reverting it for this run;
                             freshness and AoC-generation checks remain active.
  --force                    Replace an existing output after validation.
  --adb PATH                 adb binary (default: project platform-tools).
  --serial SERIAL            Select one ADB device.
  --adb-server-port PORT     Existing ADB server port (default: 5038).
  -h, --help                 Show this text without contacting a device.

This wrapper owns the complete volatile-patch lifecycle. It requires stopped
audioserver, snapshots the strict RAW mixer state, proves all D8/D9/D10/D12
capture nodes closed, applies the exact CP2A.260805.005 F1 profile, captures
mono S16_LE/192000 through PCM 0,10 and EP3, then reverts the profile before
restoring the mixer snapshot. D8, D9, D12, and every multichannel capture are
forbidden while the profile is live. Exit and signal traps force EP3 off and
attempt the guarded revert before normal mixer cleanup. Apply and revert each
use the HD Mic gain command once to run the whole-F1-I-cache invalidator; the
wrapper snapshots and restores that otherwise unrelated gain control.

The running kernel must already admit 192 kHz on EP3 and use the qualified
0.5 ms audio-capture host timer. A WAV header and frame count are insufficient:
the post-capture validator rejects any interior aligned 96-sample block whose
second 48 S16 samples are all zero or repeat the first half.
USAGE
}

output=
endpoint=
duration=
period_size=1920
period_count=4
soft_gain_db=0
dc_blocker=off
force=false
use_boot_profile=false

while (( $# > 0 )); do
  case "$1" in
    --output|--endpoint|--duration|--period-size|--period-count|--soft-gain-db|\
    --dc-blocker|--adb|--serial|--adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --output) output=$value ;;
        --endpoint) endpoint=$value ;;
        --duration) duration=$value ;;
        --period-size) period_size=$value ;;
        --period-count) period_count=$value ;;
        --soft-gain-db) soft_gain_db=$value ;;
        --dc-blocker) dc_blocker=$value ;;
        --adb) FRANKEL_AUDIO_ADB=$value ;;
        --serial) FRANKEL_AUDIO_SERIAL=$value ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$value ;;
      esac
      ;;
    --force)
      force=true
      shift
      ;;
    --use-boot-profile)
      use_boot_profile=true
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

[[ -n "$output" ]] || frankel_audio_die "--output is required"
[[ -n "$endpoint" ]] || frankel_audio_die "--endpoint is required"
[[ -n "$duration" ]] || frankel_audio_die "--duration is required"
case "$endpoint" in
  raw192-pdm0) logical_mic=0 ;;
  raw192-pdm1) logical_mic=1 ;;
  raw192-pdm2) logical_mic=2 ;;
  *)
    frankel_audio_die \
      "endpoint must be raw192-pdm0, raw192-pdm1, or raw192-pdm2"
    ;;
esac

frankel_audio_require_positive_integer duration "$duration"
frankel_audio_require_positive_integer period-size "$period_size"
frankel_audio_require_positive_integer period-count "$period_count"
(( period_size % 96 == 0 )) || \
  frankel_audio_die "period-size must be a multiple of the 96-frame AoC quantum"
frankel_audio_validate_period_geometry 1 2 "$period_size" "$period_count"
[[ "$soft_gain_db" =~ ^-?[0-9]+$ ]] || \
  frankel_audio_die "soft gain must be an integer"
(( soft_gain_db >= -40 && soft_gain_db <= 30 )) || \
  frankel_audio_die "soft gain must be between -40 and 30 dB"
case "$dc_blocker" in
  on) dc_blocker_value=1 ;;
  off) dc_blocker_value=0 ;;
  *) frankel_audio_die "DC blocker must be on or off" ;;
esac
[[ "$dc_blocker" == off ]] || \
  frankel_audio_die "D10 RAW 192 kHz currently requires --dc-blocker off"

[[ -f "$raw192_patcher" ]] || frankel_audio_die "patcher is missing: $raw192_patcher"
[[ -f "$raw192_freshness_validator" ]] || \
  frankel_audio_die "freshness validator is missing: $raw192_freshness_validator"
command -v python3 >/dev/null 2>&1 || \
  frankel_audio_die "required host command not found: python3"

output=$(realpath -m -- "$output")
output_directory=${output%/*}
[[ "$output_directory" != "$output" ]] || output_directory=.
mkdir -p -- "$output_directory"
if [[ -e "$output" && "$force" != true ]]; then
  frankel_audio_die "output exists (use --force): $output"
fi
partial_output="${output}.partial-${BASHPID}"
[[ ! -e "$partial_output" ]] || \
  frankel_audio_die "partial output unexpectedly exists: $partial_output"

frankel_audio_initialize_device tinycap
if [[ "$use_boot_profile" == true ]]; then
  [[ "$(frankel_audio_remote_exec getprop vendor.powerphone.pdm.ready)" == 1 ]] || \
    frankel_audio_die \
      "--use-boot-profile requires vendor.powerphone.pdm.ready=1"
  raw192_boot_restart_count=$(frankel_audio_remote_exec \
    cat /sys/devices/platform/9000000.aoc/restart_count)
  raw192_boot_coredump_count=$(frankel_audio_remote_exec \
    cat /sys/devices/platform/9000000.aoc/coredump_count)
  [[ "$raw192_boot_restart_count" =~ ^[0-9]+$ && \
     "$raw192_boot_coredump_count" =~ ^[0-9]+$ ]] || \
    frankel_audio_die "cannot establish the boot-certified AoC generation"
fi
if [[ "$(frankel_audio_remote_exec getprop init.svc.audioserver)" != stopped ]]; then
  frankel_audio_remote_exec stop audioserver
fi
[[ "$(frankel_audio_remote_exec getprop init.svc.audioserver)" == stopped ]] || \
  frankel_audio_die "audioserver must be stopped before a D10 RAW 192 kHz session"

raw192_select_logical_mic() {
  local expected actual
  expected="$logical_mic -1 -1 -1"
  frankel_audio_tinymix_set \
    'BUILDIN MIC ID CAPTURE LIST' "$logical_mic" -1 -1 -1
  actual=$(frankel_audio_tinymix_get 'BUILDIN MIC ID CAPTURE LIST') || \
    frankel_audio_die "cannot read back D10 logical microphone selection"
  [[ "$actual" == "$expected" ]] || \
    frankel_audio_die \
      "D10 logical microphone selection did not stick (expected $expected, got $actual)"
}

raw192_reinitialize_logical_mic() {
  local alternate actual
  # Force an actual AoC control transition even when the requested lane was
  # already selected during patch preflight.  All capture routes are still
  # off here.  Keep one valid PDM bit selected throughout: firmware asserts
  # that the PDM mask is nonzero, so an all--1 neutral vector is not safe.
  if (( logical_mic == 0 )); then
    alternate=1
  else
    alternate=0
  fi
  frankel_audio_tinymix_set \
    'BUILDIN MIC ID CAPTURE LIST' "$alternate" -1 -1 -1
  actual=$(frankel_audio_tinymix_get 'BUILDIN MIC ID CAPTURE LIST') || \
    frankel_audio_die "cannot read back alternate D10 microphone selection"
  [[ "$actual" == "$alternate -1 -1 -1" ]] || \
    frankel_audio_die \
      "D10 alternate microphone selection did not stick (got $actual)"
  raw192_select_logical_mic
}

raw192_patcher_command() {
  local action=$1
  local -a command=(
    python3 "$raw192_patcher" "$action"
    --minimal-traffic
    --adb "$FRANKEL_AUDIO_ADB"
    --adb-server-port "${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}"
  )
  if [[ -n ${FRANKEL_AUDIO_SERIAL:-} ]]; then
    command+=(--serial "$FRANKEL_AUDIO_SERIAL")
  fi
  # AudioFlinger is a lazy binder service.  Stop it if it actually returned,
  # but do not send a redundant `stop` while it is already stopped: the
  # platform audioserver.rc handles that transition by starting the stock AoC
  # HAL, whose initialization republishes default mixer values and would erase
  # the strict single-microphone selection prepared below.
  if [[ "$(frankel_audio_remote_exec getprop init.svc.audioserver)" != stopped ]]; then
    frankel_audio_remote_exec stop audioserver
  fi
  [[ "$(frankel_audio_remote_exec getprop init.svc.audioserver)" == stopped ]] || \
    frankel_audio_die "could not stop audioserver before D10 $action"
  # If AudioFlinger really did return, stopping it can make the stock HAL
  # republish mixer_paths.xml's 0/1/2/-1 default.  Reapply the owned selection
  # after the final stop in either case, then let the patcher independently
  # verify the complete strict state before it reads or mutates F1.
  raw192_select_logical_mic
  PYTHONUNBUFFERED=1 "${command[@]}"
}

raw192_patch_transaction_started=false

raw192_force_capture_off() {
  frankel_audio_tinymix_set "$raw192_route" 0
  frankel_audio_tinymix_set 'US Record Enable' 0
  for microphone in MIC0 MIC1 MIC2; do
    frankel_audio_tinymix_set "$microphone" 0
  done
}

raw192_exit_handler() {
  local status=$?
  local cleanup_failed=false
  trap - EXIT HUP INT TERM
  set +e
  if [[ "$raw192_patch_transaction_started" == true ]]; then
    raw192_force_capture_off || cleanup_failed=true
    raw192_patcher_command revert || cleanup_failed=true
    raw192_patch_transaction_started=false
  fi
  frankel_audio_cleanup || cleanup_failed=true
  if (( status == 0 )) && [[ "$cleanup_failed" == true ]]; then
    status=1
  fi
  exit "$status"
}

frankel_audio_arm_cleanup
trap raw192_exit_handler EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
frankel_audio_register_local_temp "$partial_output"

for safe_route in \
  'EP1 TX Mixer INTERNAL_MIC_TX' \
  'EP2 TX Mixer INTERNAL_MIC_TX' \
  'EP3 TX Mixer INTERNAL_MIC_TX' \
  'EP5 TX Mixer INTERNAL_MIC_TX' \
  'EP5 TX Mixer INTERNAL_MIC_US_TX'; do
  frankel_audio_register_safe_control "$safe_route" 0
  frankel_audio_require_control_zero "$safe_route"
done
frankel_audio_register_safe_control 'US Record Enable' 0
frankel_audio_require_control_zero 'US Record Enable'
for microphone in MIC0 MIC1 MIC2; do
  frankel_audio_register_safe_control "$microphone" 0
  frankel_audio_require_control_zero "$microphone"
done

frankel_audio_snapshot_and_set_scalar 'BUILTIN MIC Process Mode' Raw
frankel_audio_snapshot_and_set_scalar 'Audio Capture Mic Source' Builtin_MIC
frankel_audio_snapshot_and_set_scalar 'Mic Spatial Module Enable' 0
frankel_audio_snapshot_and_set_scalar 'MIC DC Blocker' "$dc_blocker_value"
frankel_audio_snapshot_and_set_scalar 'MIC Record Soft Gain (dB)' "$soft_gain_db"
# The patcher temporarily redirects this command's reviewed function pointer
# to the whole-F1-I-cache invalidator.  Keep its payload at the proven value;
# common cleanup restores the user's original control after the final revert.
frankel_audio_snapshot_and_set_scalar 'HD Mic gain (cB)' 0
# Snapshot this before geometry so reverse-order cleanup restores the capture
# list last.  Restoring transport geometry can republish the stock multi-mic
# default and would otherwise overwrite the caller's original list.
frankel_audio_snapshot_vector 'BUILDIN MIC ID CAPTURE LIST'
# frankel_audio_tinymix_set always emits `tinymix --`, so the three -1 vector
# elements cannot be misparsed as options.
frankel_audio_snapshot_and_set_scalar \
  'INTERNAL_MIC_TX Sample Rate' SR_192K
frankel_audio_snapshot_and_set_scalar 'INTERNAL_MIC_TX Format' S16_LE
frankel_audio_snapshot_and_set_scalar 'INTERNAL_MIC_TX Chan' One
# Changing the INTERNAL_MIC_TX geometry makes AoC republish its default
# 0/1/2 capture list.  Select the single physical PDM ID only after those
# controls have settled, otherwise the patch preflight observes the reset
# list instead of the requested microphone.
raw192_select_logical_mic

# A standalone qualification run owns apply/revert. An integrated image has
# already certified this reboot-local profile before starting AudioFlinger;
# in that mode verify it in place and leave it available to the AIDL HAL.
if [[ "$use_boot_profile" == true ]]; then
  frankel_audio_note \
    "using the boot-certified D10 profile without another diagnostic transaction"
else
  # The apply action performs the same strict stock-profile preflight before
  # its first write. Mark ownership first so our exit trap reverts a partial
  # apply after a signal or host-side failure.
  raw192_patch_transaction_started=true
  raw192_patcher_command apply
fi

# The selected PdmV3 lane latches its clock/output cadence when AoC processes
# this control.  In standalone mode the first selection above necessarily ran
# while F1 still contained the stock 96 kHz code; republish it after the live
# profile is active so logical microphones 1 and 2 do not retain that cached
# half-rate state.  This is also harmless (and explicit) for a boot-certified
# profile.  Pixel 10 hardware qualification showed 2,304,000 fresh frames in
# 12 seconds for logical mic 1 only when this post-patch selection occurred.
raw192_reinitialize_logical_mic

frankel_audio_tinymix_set "$raw192_route" 1
remote_output="$FRANKEL_AUDIO_REMOTE_DIRECTORY/frankel-d10-raw192-${BASHPID}.wav"
frankel_audio_register_remote_temp "$remote_output"
FRANKEL_AUDIO_STREAM_TIMEOUT_SECONDS=$((duration + 30))
frankel_audio_note \
  "capturing PCM 0,$FRANKEL_AUDIO_RAW192_CAPTURE_DEVICE: endpoint=$endpoint rate=192000 format=s16 channels=1 periods=${period_size}x${period_count} duration=${duration}s"
set +e
capture_output=$(frankel_audio_run_guarded /system/bin/tinycap "$remote_output" \
  -D "$FRANKEL_AUDIO_CARD" -d "$FRANKEL_AUDIO_RAW192_CAPTURE_DEVICE" \
  -c 1 -r 192000 -b 16 -p "$period_size" -n "$period_count" \
  -T "$duration" 2>&1)
capture_status=$?
set -e
printf '%s\n' "$capture_output"
(( capture_status == 0 )) || \
  frankel_audio_die "tinycap/ADB exited with status $capture_status"
if [[ "$capture_output" =~ [Uu]nable|[Ee]rror|not[[:space:]]supported ]]; then
  frankel_audio_die "tinycap reported a PCM error"
fi

# The remote guarded trap has already forced EP3 off.  Remove the enum-7 and
# shared-PDM edits before any host-side pull or analysis can prolong exposure.
raw192_force_capture_off
if [[ "$use_boot_profile" == true ]]; then
  [[ "$(frankel_audio_remote_exec getprop vendor.powerphone.pdm.ready)" == 1 ]] || \
    frankel_audio_die "boot-certified D10 readiness was lost during capture"
  [[ "$(frankel_audio_remote_exec cat \
      /sys/devices/platform/9000000.aoc/restart_count)" == \
      "$raw192_boot_restart_count" && \
     "$(frankel_audio_remote_exec cat \
      /sys/devices/platform/9000000.aoc/coredump_count)" == \
      "$raw192_boot_coredump_count" ]] || \
    frankel_audio_die "AoC generation changed during boot-profile capture"
else
  raw192_patcher_command revert
  raw192_patch_transaction_started=false
fi

frankel_audio_note "pulling capture to a local partial file"
frankel_audio_adb pull "$remote_output" "$partial_output" >/dev/null
inspection_output=$("$script_directory/generate-signal.py" inspect "$partial_output" \
  --expect-rate 192000 --expect-channels 1 --expect-bits 16)
printf '%s\n' "$inspection_output"
[[ "$inspection_output" =~ frames=([0-9]+) ]] || \
  frankel_audio_die "WAV inspection did not report a frame count"
captured_frames=${BASH_REMATCH[1]}
expected_frames=$((192000 * duration))
buffer_frames=$((period_size * period_count))
# tinycap -T stops on a userspace time check and may finish with the two
# pipeline buffers immediately preceding the boundary still uncommitted.  The
# block-level replay validator below is authoritative for transport freshness.
minimum_slack_frames=$((buffer_frames * 2))
minimum_frames=$((expected_frames > minimum_slack_frames ? expected_frames - minimum_slack_frames : 1))
maximum_frames=$((expected_frames + buffer_frames))
if (( captured_frames < minimum_frames || captured_frames > maximum_frames )); then
  failed_output="${output}.failed-capture-${BASHPID}"
  [[ ! -e "$failed_output" ]] || \
    frankel_audio_die "capture diagnostic path exists: $failed_output"
  mv -- "$partial_output" "$failed_output"
  frankel_audio_die \
    "captured $captured_frames frames; expected $minimum_frames..$maximum_frames (preserved at $failed_output)"
fi

set +e
freshness_output=$(python3 "$raw192_freshness_validator" "$partial_output" 2>&1)
freshness_status=$?
set -e
printf '%s\n' "$freshness_output"
if (( freshness_status != 0 )); then
  failed_output="${output}.failed-freshness-${BASHPID}"
  [[ ! -e "$failed_output" ]] || \
    frankel_audio_die "freshness diagnostic path exists: $failed_output"
  mv -- "$partial_output" "$failed_output"
  frankel_audio_die \
    "D10 block freshness failed (capture preserved at $failed_output)"
fi

mv -f -- "$partial_output" "$output"
frankel_audio_finish_cleanup
raw192_patch_transaction_started=false
trap - EXIT HUP INT TERM
if [[ "$use_boot_profile" == true ]]; then
  frankel_audio_note \
    "capture saved to $output; boot-certified F1 profile is retained and microphone routes are off"
else
  frankel_audio_note \
    "capture saved to $output; F1 profile is stock and microphone routes are off"
fi
