#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  tinycap.sh --output WAV --endpoint ENDPOINT --rate HZ --format FORMAT \
    --channels N --period-size FRAMES --period-count N --duration SECONDS \
    [--soft-gain-db DB] [--dc-blocker on|off] [--force]

Required:
  --output WAV               Local destination; captured through a partial file.
  --endpoint ENDPOINT        pdm0, pdm1, pdm2, all, ultrasound,
                             ultrasound0, ultrasound1, or ultrasound2.
  --rate HZ                  48000, 96000, or 192000.
  --format FORMAT            s16, s24 (32-bit container), or s32.
  --channels N               pdm0/1/2=1, all=3, ultrasound=2,
                             ultrasound0/1/2=1.
  --period-size FRAMES       Ultrasound requires a whole 10 ms quantum
                             (rate / 100, or an integer multiple).
                             Try 1024 for 1ch or 512 for 3ch S32 otherwise.
  --period-count N           Ultrasound: use 4 initially. Other paths: try 8.
  --duration SECONDS         Positive whole-number capture duration.

Optional:
  --soft-gain-db DB          AoC capture gain, -40..30 (default: 0).
  --dc-blocker on|off        AoC DC blocker (default: off for raw sensing).
  --force                    Replace an existing local output after validation.
  --adb PATH                 adb binary (default: work/toolchains/platform-tools/adb).
  --serial SERIAL            Select a device without printing its identifier.
  --adb-server-port PORT     Existing ADB server port (default: 5038).
  -h, --help                 Show this text without contacting a device.

pdm0/pdm1/pdm2/all use PCM 0,8 -> EP1 -> INTERNAL_MIC_TX. The ultrasound
endpoints use PCM 0,12 -> EP5 -> INTERNAL_MIC_US_TX; `ultrasound` selects the
stock logical 0,1 pair while `ultrasound0/1/2` isolates one logical mic.
All capture-list, backend, raw-mode, source, gain, and DC settings are restored.
Routes, US Record Enable, and the supported MIC0..MIC2 controls are forced off
on every exit. The unsupported logical MIC3 control is never accessed.

Stock limits are 96 kHz maximum on PCM 0,8 and fixed 96 kHz/S32/stereo on the
ultrasound chain, so 192 kHz is a post-patch test case. `MIC Clock Rate` is a
read-only driver control and is printed before capture; this script cannot set
the PDM clock until the kernel/AoC driver exposes a setter.
USAGE
}

output=
endpoint=
rate=
format=
channels=
period_size=
period_count=
duration=
soft_gain_db=0
dc_blocker=off
force=false
ultrasound_endpoint=false

while (( $# > 0 )); do
  case "$1" in
    --output|--endpoint|--rate|--format|--channels|--period-size|--period-count|\
    --duration|--soft-gain-db|--dc-blocker|--adb|--serial|--adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --output) output=$value ;;
        --endpoint) endpoint=$value ;;
        --rate) rate=$value ;;
        --format) format=$value ;;
        --channels) channels=$value ;;
        --period-size) period_size=$value ;;
        --period-count) period_count=$value ;;
        --duration) duration=$value ;;
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      frankel_audio_die "unknown argument: $1 (use --help)"
      ;;
  esac
done

for required_name in output endpoint rate format channels period_size \
  period_count duration; do
  [[ -n ${!required_name} ]] || \
    frankel_audio_die "--${required_name//_/-} is required"
done

case "$endpoint" in
  pdm0)
    expected_channels=1
    capture_list=(0 -1 -1 -1)
    ;;
  pdm1)
    expected_channels=1
    capture_list=(1 -1 -1 -1)
    ;;
  pdm2)
    expected_channels=1
    capture_list=(2 -1 -1 -1)
    ;;
  all)
    expected_channels=3
    capture_list=(0 1 2 -1)
    ;;
  ultrasound)
    expected_channels=2
    capture_list=(0 1 -1 -1)
    ultrasound_endpoint=true
    ;;
  ultrasound0)
    expected_channels=1
    capture_list=(0 -1 -1 -1)
    ultrasound_endpoint=true
    ;;
  ultrasound1)
    expected_channels=1
    capture_list=(1 -1 -1 -1)
    ultrasound_endpoint=true
    ;;
  ultrasound2)
    expected_channels=1
    capture_list=(2 -1 -1 -1)
    ultrasound_endpoint=true
    ;;
  *)
    frankel_audio_die \
      "endpoint must be pdm0, pdm1, pdm2, all, ultrasound, ultrasound0, ultrasound1, or ultrasound2"
    ;;
esac

rate_enum=$(frankel_audio_rate_enum "$rate")
format_enum=$(frankel_audio_capture_format_enum "$format")
bits=$(frankel_audio_format_bits "$format")
wav_bits=$(frankel_audio_capture_wav_bits "$format")
sample_bytes=$(frankel_audio_capture_sample_bytes "$format")
channel_enum=$(frankel_audio_channel_enum "$channels")
frankel_audio_require_positive_integer channels "$channels"
(( channels == expected_channels )) || \
  frankel_audio_die "$endpoint requires exactly $expected_channels channel(s)"
frankel_audio_require_positive_integer period-size "$period_size"
frankel_audio_require_positive_integer period-count "$period_count"
frankel_audio_validate_period_geometry \
  "$channels" "$sample_bytes" "$period_size" "$period_count"
frankel_audio_require_positive_integer duration "$duration"
[[ "$soft_gain_db" =~ ^-?[0-9]+$ ]] || \
  frankel_audio_die "soft gain must be an integer"
(( soft_gain_db >= -40 && soft_gain_db <= 30 )) || \
  frankel_audio_die "soft gain must be between -40 and 30 dB"
case "$dc_blocker" in
  on) dc_blocker_value=1 ;;
  off) dc_blocker_value=0 ;;
  *) frankel_audio_die "DC blocker must be on or off" ;;
esac
if [[ "$ultrasound_endpoint" == true && "$format" != s32 ]]; then
  frankel_audio_die "the Frankel ultrasound firmware path requires --format s32"
fi
if [[ "$ultrasound_endpoint" == true ]]; then
  ultrasound_period_size=$((rate / 100))
  (( period_size % ultrasound_period_size == 0 )) || \
    frankel_audio_die \
      "ultrasound period-size must be a multiple of $ultrasound_period_size frames (10 ms at ${rate} Hz)"
fi

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
frankel_audio_arm_cleanup
frankel_audio_register_local_temp "$partial_output"

frankel_audio_register_safe_control 'EP1 TX Mixer INTERNAL_MIC_TX' 0
frankel_audio_register_safe_control 'EP5 TX Mixer INTERNAL_MIC_US_TX' 0
frankel_audio_register_safe_control 'US Record Enable' 0
frankel_audio_register_safe_control MIC0 0
frankel_audio_register_safe_control MIC1 0
frankel_audio_register_safe_control MIC2 0

frankel_audio_require_control_zero 'EP1 TX Mixer INTERNAL_MIC_TX'
frankel_audio_require_control_zero 'EP5 TX Mixer INTERNAL_MIC_US_TX'
frankel_audio_require_control_zero 'US Record Enable'
for microphone in MIC0 MIC1 MIC2; do
  frankel_audio_require_control_zero "$microphone"
done
if [[ "$ultrasound_endpoint" == true ]]; then
  capture_mixer=EP5
  other_capture_sources=(BT_TX INCALL_TX INTERNAL_MIC_TX TDM_0_TX TDM_1_TX USB_TX)
else
  capture_mixer=EP1
  other_capture_sources=(BT_TX INCALL_TX TDM_0_TX TDM_1_TX USB_TX)
fi
for active_source in "${other_capture_sources[@]}"; do
  frankel_audio_require_control_zero "$capture_mixer TX Mixer $active_source"
done

pdm_clock=$(frankel_audio_tinymix_get 'MIC Clock Rate')
frankel_audio_note \
  "idle MIC Clock Rate reports ${pdm_clock} Hz (read-only in the current driver)"

frankel_audio_snapshot_and_set_scalar 'BUILTIN MIC Process Mode' Raw
frankel_audio_snapshot_and_set_scalar 'Audio Capture Mic Source' Builtin_MIC
frankel_audio_snapshot_and_set_scalar 'Mic Spatial Module Enable' 0
frankel_audio_snapshot_and_set_scalar 'MIC DC Blocker' "$dc_blocker_value"
frankel_audio_snapshot_and_set_scalar 'MIC Record Soft Gain (dB)' "$soft_gain_db"

if [[ "$ultrasound_endpoint" == true ]]; then
  pcm_device=$FRANKEL_AUDIO_ULTRASOUND_CAPTURE_DEVICE
  backend=INTERNAL_MIC_US_TX
  route='EP5 TX Mixer INTERNAL_MIC_US_TX'
  capture_list_control='BUILDIN US MIC ID CAPTURE LIST'
else
  pcm_device=$FRANKEL_AUDIO_PRIMARY_CAPTURE_DEVICE
  backend=INTERNAL_MIC_TX
  route='EP1 TX Mixer INTERNAL_MIC_TX'
  capture_list_control='BUILDIN MIC ID CAPTURE LIST'
fi

frankel_audio_snapshot_and_set_vector "$capture_list_control" "${capture_list[@]}"
frankel_audio_snapshot_and_set_scalar "$backend Sample Rate" "$rate_enum"
frankel_audio_snapshot_and_set_scalar "$backend Format" "$format_enum"
frankel_audio_snapshot_and_set_scalar "$backend Chan" "$channel_enum"
frankel_audio_tinymix_set "$route" 1

remote_output="$FRANKEL_AUDIO_REMOTE_DIRECTORY/frankel-audio-cap-${BASHPID}.wav"
frankel_audio_register_remote_temp "$remote_output"
FRANKEL_AUDIO_STREAM_TIMEOUT_SECONDS=$((duration + 30))
frankel_audio_note \
  "capturing PCM 0,$pcm_device: endpoint=$endpoint rate=$rate format=$format channels=$channels periods=${period_size}x${period_count} duration=${duration}s"
set +e
capture_output=$(frankel_audio_run_guarded /system/bin/tinycap "$remote_output" \
  -D "$FRANKEL_AUDIO_CARD" -d "$pcm_device" -c "$channels" -r "$rate" \
  -b "$bits" -p "$period_size" -n "$period_count" -T "$duration" 2>&1)
capture_status=$?
set -e
printf '%s\n' "$capture_output"
(( capture_status == 0 )) || \
  frankel_audio_die "tinycap/ADB exited with status $capture_status"
if [[ "$capture_output" =~ [Uu]nable|[Ee]rror|not[[:space:]]supported ]]; then
  frankel_audio_die "tinycap reported a PCM error"
fi

frankel_audio_note "pulling capture to a local partial file"
frankel_audio_adb pull "$remote_output" "$partial_output" >/dev/null
inspection_output=$("$script_directory/generate-signal.py" inspect "$partial_output" \
  --expect-rate "$rate" --expect-channels "$channels" --expect-bits "$wav_bits")
printf '%s\n' "$inspection_output"
[[ "$inspection_output" =~ frames=([0-9]+) ]] || \
  frankel_audio_die "WAV inspection did not report a frame count"
captured_frames=${BASH_REMATCH[1]}
expected_frames=$((rate * duration))
tinycap_buffer_frames=$((period_size * period_count))
maximum_frames=$((expected_frames + tinycap_buffer_frames))
if (( captured_frames < expected_frames || captured_frames > maximum_frames )); then
  failed_output="${output}.failed-capture-${BASHPID}"
  [[ ! -e "$failed_output" ]] || \
    frankel_audio_die "capture length is invalid and diagnostic path exists: $failed_output"
  mv -- "$partial_output" "$failed_output"
  frankel_audio_die \
    "captured $captured_frames frames; expected $expected_frames..$maximum_frames (partial preserved at $failed_output)"
fi

mv -f -- "$partial_output" "$output"
frankel_audio_finish_cleanup
frankel_audio_note "capture saved to $output; mic routes and power controls are off"
