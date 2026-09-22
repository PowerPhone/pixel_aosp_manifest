#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

usage() {
  cat <<'USAGE'
Usage:
  capture-alsa-192k.sh --device hw:CARD,DEVICE --output WAV \
    --duration SECONDS [--channels 1|2] [--period-size FRAMES] \
    [--buffer-size FRAMES] [--expected-usb-id VID:PID] [--force]

Required:
  --device DEVICE           Exact ALSA hardware PCM, for example hw:UMC202HD,0.
                            plughw/default and numeric card aliases are refused.
  --output WAV              Destination 192 kHz/S32_LE PCM WAV.
  --duration SECONDS        Whole seconds, 3..600.

Optional:
  --channels N              One or two input channels (default: 2).
  --period-size FRAMES      ALSA period in frames (default: 1024).
  --buffer-size FRAMES      ALSA buffer in frames (default: 8192).
  --expected-usb-id VID:PID Capture-card USB identity (default: 1397:0507,
                            Behringer UMC202HD).
  --force                   Replace WAV and its three sidecar reports.
  -h, --help                Show this text without opening an ALSA device.

The script always opens the literal `hw:` PCM at 192000 Hz, S32_LE, with
arecord's fatal-error mode. It snapshots the live /proc/asound hw_params while
the stream is running and refuses a rate, format, channel, period, or buffer
mismatch. It also rejects XRUN/error text, an inexact frame count, a wrong USB
identity, and silent ALSA plug/resampler aliases. USB forwarding is deliberately
outside this script.
USAGE
}

device=
output=
duration=
channels=2
period_size=1024
buffer_size=8192
expected_usb_id=1397:0507
force=false

while (( $# > 0 )); do
  case "$1" in
    --device|--output|--duration|--channels|--period-size|--buffer-size|\
    --expected-usb-id)
      (( $# >= 2 )) || die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --device) device=$value ;;
        --output) output=$value ;;
        --duration) duration=$value ;;
        --channels) channels=$value ;;
        --period-size) period_size=$value ;;
        --buffer-size) buffer_size=$value ;;
        --expected-usb-id) expected_usb_id=${value,,} ;;
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
      die "unknown argument: $1 (use --help)"
      ;;
  esac
done

[[ -n "$device" ]] || die "--device is required"
[[ -n "$output" ]] || die "--output is required"
[[ -n "$duration" ]] || die "--duration is required"
[[ "$device" =~ ^hw:([A-Za-z_][A-Za-z0-9_-]*),([0-9]+)$ ]] || \
  die "--device must be a symbolic, literal hardware PCM such as hw:UMC202HD,0"
card_id=${BASH_REMATCH[1]}
pcm_device=${BASH_REMATCH[2]}
[[ "$expected_usb_id" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || \
  die "--expected-usb-id must be four lowercase/uppercase hex digits, a colon, and four hex digits"

for integer_name in duration channels period_size buffer_size; do
  integer_value=${!integer_name}
  [[ "$integer_value" =~ ^[0-9]+$ ]] || \
    die "--${integer_name//_/-} must be a positive whole number"
  (( integer_value > 0 )) || \
    die "--${integer_name//_/-} must be greater than zero"
done
(( duration >= 3 && duration <= 600 )) || \
  die "--duration must be between 3 and 600 seconds"
(( channels == 1 || channels == 2 )) || \
  die "--channels must be 1 or 2"
(( buffer_size >= period_size * 2 )) || \
  die "--buffer-size must hold at least two periods"
(( buffer_size % period_size == 0 )) || \
  die "--buffer-size must be an integer multiple of --period-size"

for command_name in arecord date grep python3 realpath timeout; do
  command -v "$command_name" >/dev/null 2>&1 || \
    die "required host command not found: $command_name"
done
[[ -d /proc/asound ]] || \
  die "ALSA is unavailable in this WSL instance; the USB interface is not attached"

declare -a matching_card_numbers=()
shopt -s nullglob
for card_id_path in /proc/asound/card*/id; do
  current_card_id=$(<"$card_id_path")
  if [[ "$current_card_id" == "$card_id" ]]; then
    card_directory=${card_id_path%/id}
    card_number=${card_directory##*/card}
    matching_card_numbers+=("$card_number")
  fi
done
shopt -u nullglob
(( ${#matching_card_numbers[@]} == 1 )) || \
  die "expected exactly one ALSA card with id $card_id, found ${#matching_card_numbers[@]}"
card_number=${matching_card_numbers[0]}
card_directory=/proc/asound/card${card_number}

[[ -r "$card_directory/usbid" ]] || \
  die "ALSA card $card_id has no readable USB identity at $card_directory/usbid"
actual_usb_id=$(<"$card_directory/usbid")
actual_usb_id=${actual_usb_id,,}
[[ "$actual_usb_id" == "$expected_usb_id" ]] || \
  die "ALSA card $card_id is USB $actual_usb_id, expected $expected_usb_id"

pcm_directory="$card_directory/pcm${pcm_device}c/sub0"
[[ -d "$pcm_directory" && -r "$pcm_directory/hw_params" ]] || \
  die "$device does not resolve to capture substream $pcm_directory"

output=$(realpath -m -- "$output")
output_directory=${output%/*}
[[ "$output_directory" != "$output" ]] || output_directory=.
mkdir -p -- "$output_directory"
log_output="${output}.alsa.log"
params_output="${output}.hw-params"
manifest_output="${output}.capture.json"
for destination in "$output" "$log_output" "$params_output" "$manifest_output"; do
  if [[ -e "$destination" && "$force" != true ]]; then
    die "output exists (use --force): $destination"
  fi
done

partial_output="${output}.partial-${BASHPID}"
partial_log="${log_output}.partial-${BASHPID}"
partial_params="${params_output}.partial-${BASHPID}"
partial_manifest="${manifest_output}.partial-${BASHPID}"
for temporary in "$partial_output" "$partial_log" "$partial_params" \
  "$partial_manifest"; do
  [[ ! -e "$temporary" ]] || die "temporary path unexpectedly exists: $temporary"
done

capture_pid=
cleanup() {
  local original_status=$?
  trap - EXIT HUP INT TERM
  if [[ -n ${capture_pid:-} ]] && kill -0 "$capture_pid" 2>/dev/null; then
    kill -TERM "$capture_pid" 2>/dev/null || true
    wait "$capture_pid" 2>/dev/null || true
  fi
  if (( original_status != 0 )); then
    printf 'diagnostic partials, if created, remain beside %s with PID %s\n' \
      "$output" "$BASHPID" >&2
  fi
  exit "$original_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

arecord_version=$(arecord --version 2>&1 | head -n 1)
timeout_seconds=$((duration + 20))
note "capturing $device ($expected_usb_id) at 192000 Hz/S32_LE/${channels}ch, periods ${period_size}x$((buffer_size / period_size))"
start_ns=$(date +%s%N)
timeout --signal=INT --kill-after=5 "$timeout_seconds" \
  arecord --device="$device" --file-type=wav --format=S32_LE \
  --rate=192000 --channels="$channels" --duration="$duration" \
  --period-size="$period_size" --buffer-size="$buffer_size" \
  --disable-resample --disable-channels --disable-format --disable-softvol \
  --dump-hw-params --fatal-errors "$partial_output" \
  >"$partial_log" 2>&1 &
capture_pid=$!

params_observed=false
for (( attempt = 0; attempt < 200; attempt++ )); do
  if [[ -s "$pcm_directory/hw_params" ]] && \
     ! grep -qx 'closed' "$pcm_directory/hw_params"; then
    cp -- "$pcm_directory/hw_params" "$partial_params"
    params_observed=true
    break
  fi
  kill -0 "$capture_pid" 2>/dev/null || break
  sleep 0.01
done

set +e
wait "$capture_pid"
capture_status=$?
set -e
capture_pid=
end_ns=$(date +%s%N)
(( capture_status == 0 )) || \
  die "arecord exited with status $capture_status (see $partial_log)"
[[ "$params_observed" == true ]] || \
  die "the live ALSA hw_params window was never observed"

grep -Fqx 'access: RW_INTERLEAVED' "$partial_params" || \
  die "live hw_params did not report RW_INTERLEAVED access"
grep -Fqx 'format: S32_LE' "$partial_params" || \
  die "live hw_params did not report S32_LE"
grep -Fqx "channels: $channels" "$partial_params" || \
  die "live hw_params did not report $channels channels"
grep -Eq '^rate: 192000([[:space:]]|$)' "$partial_params" || \
  die "live hw_params did not report exactly 192000 Hz"
grep -Fqx "period_size: $period_size" "$partial_params" || \
  die "live hw_params did not report period_size $period_size"
grep -Fqx "buffer_size: $buffer_size" "$partial_params" || \
  die "live hw_params did not report buffer_size $buffer_size"
if grep -Eiq '(^|[^[:alpha:]])(xrun|overrun|underrun|broken pipe|suspend(ed)?|input/output error)([^[:alpha:]]|$)' \
  "$partial_log"; then
  die "arecord reported an XRUN or transport error (see $partial_log)"
fi

inspection_output=$("$script_directory/../frankel/generate-signal.py" inspect \
  "$partial_output" --expect-rate 192000 --expect-channels "$channels" \
  --expect-bits 32)
printf '%s\n' "$inspection_output"
[[ "$inspection_output" =~ frames=([0-9]+) ]] || \
  die "WAV inspection did not report a frame count"
captured_frames=${BASH_REMATCH[1]}
expected_frames=$((duration * 192000))
(( captured_frames == expected_frames )) || \
  die "captured $captured_frames frames, expected exactly $expected_frames"

elapsed_report=$(python3 - "$start_ns" "$end_ns" "$duration" <<'PY'
import sys

start_ns, end_ns, requested = map(int, sys.argv[1:])
elapsed = (end_ns - start_ns) / 1_000_000_000
if elapsed < requested - 0.25 or elapsed > requested + 5.0:
    raise SystemExit(
        f"wall time {elapsed:.6f}s is outside {requested - 0.25:.2f}..{requested + 5.0:.2f}s"
    )
print(f"{elapsed:.9f}")
PY
) || die "$elapsed_report"

python3 - "$partial_manifest" "$output" "$device" "$card_id" \
  "$card_number" "$pcm_device" "$actual_usb_id" "$duration" "$channels" \
  "$period_size" "$buffer_size" "$captured_frames" "$elapsed_report" \
  "$arecord_version" <<'PY'
import json
import pathlib
import sys

(
    destination,
    wav,
    device,
    card_id,
    card_number,
    pcm_device,
    usb_id,
    duration,
    channels,
    period_size,
    buffer_size,
    frames,
    elapsed,
    arecord_version,
) = sys.argv[1:]
report = {
    "alsa_card_id": card_id,
    "alsa_card_number_at_capture": int(card_number),
    "alsa_device": device,
    "alsa_pcm_device": int(pcm_device),
    "arecord_version": arecord_version,
    "buffer_size_frames": int(buffer_size),
    "channels": int(channels),
    "elapsed_wall_seconds": float(elapsed),
    "format": "S32_LE",
    "frames": int(frames),
    "period_size_frames": int(period_size),
    "requested_seconds": int(duration),
    "sample_rate_hz": 192000,
    "usb_id": usb_id,
    "wav": wav,
}
pathlib.Path(destination).write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

mv -f -- "$partial_output" "$output"
mv -f -- "$partial_log" "$log_output"
mv -f -- "$partial_params" "$params_output"
mv -f -- "$partial_manifest" "$manifest_output"
trap - EXIT HUP INT TERM
note "capture saved: $output"
note "exact live hw_params: $params_output"
note "XRUN/arecord log: $log_output"
note "capture manifest: $manifest_output (wall ${elapsed_report}s)"
