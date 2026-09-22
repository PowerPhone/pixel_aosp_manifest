#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  tinyplay.sh --file WAV --endpoint ENDPOINT --rate HZ --format FORMAT \
    --channels N --period-size FRAMES --period-count N \
    --ultrasonic-mode MODE [--tdm-format FORMAT] [--slot-format FORMAT] \
    [--tdm-channels N] [--tdm-slots N] \
    [--high-rate-source SOURCE] [--amp-gain RAW]

Required:
  --file WAV                 Local PCM WAV to push and play.
  --endpoint ENDPOINT        earpiece or bottom (one amplifier only).
  --rate HZ                  48000, 96000, or 192000.
  --format FORMAT            s16, s24 (packed), or s32.
  --channels N               2, 3, or 4 (audio_ultrasonic PCM channels).
  --period-size FRAMES       Try 1024 for 2ch or 512 for 3/4ch S32.
  --period-count N           tinyplay period count; try 8 initially.
  --ultrasonic-mode MODE     disabled, in-band, or out-of-band.

Optional:
  --tdm-format FORMAT        TDM backend sample format: s16, s24, or s32
                             (default: same as --format).
  --slot-format FORMAT       Physical TDM slot format: s16 or s32 (default: s32).
  --tdm-channels N           TDM backend channels, 1..4 (default: 4).
  --tdm-slots N              Physical TDM slots, 1..4 (default: 4).
  --high-rate-source SOURCE  direct (ASPRX1, default) or dsp-fs2.
  --amp-gain RAW             Both CS35L43 raw Amp Gain controls, 0..20 (default: 0).
  --adb PATH                 adb binary (default: work/toolchains/platform-tools/adb).
  --serial SERIAL            Select a device without printing its identifier.
  --adb-server-port PORT     Existing ADB server port (default: 5038).
  -h, --help                 Show this text without contacting a device.

This is a Frankel-only direct tinyALSA test. The WAV header must match the
explicit rate, format, and channel arguments. The wrapper routes PCM 0,28 to
TDM_0_RX, enables only the requested physical amp(s), then disables both amps,
the ultrasound route, and codec ultrasonic modes on every normal/error/signal
exit. Stock Frankel exposes PCM 0,28 only as 96 kHz/S32; 48/192 are post-patch
test cases and should fail until the kernel/AoC constraints are changed.
USAGE
}

file=
endpoint=
rate=
format=
channels=
period_size=
period_count=
ultrasonic_mode=
high_rate_source=direct
amp_gain=0
slot_format=s32
tdm_format=
tdm_channels=4
tdm_slots=4

while (( $# > 0 )); do
  case "$1" in
    --file|--endpoint|--rate|--format|--channels|--period-size|--period-count|\
    --ultrasonic-mode|--tdm-format|--slot-format|--tdm-channels|--tdm-slots|\
    --high-rate-source|--amp-gain|--adb|--serial|\
    --adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --file) file=$value ;;
        --endpoint) endpoint=$value ;;
        --rate) rate=$value ;;
        --format) format=$value ;;
        --channels) channels=$value ;;
        --period-size) period_size=$value ;;
        --period-count) period_count=$value ;;
        --ultrasonic-mode) ultrasonic_mode=$value ;;
        --tdm-format) tdm_format=$value ;;
        --slot-format) slot_format=$value ;;
        --tdm-channels) tdm_channels=$value ;;
        --tdm-slots) tdm_slots=$value ;;
        --high-rate-source) high_rate_source=$value ;;
        --amp-gain) amp_gain=$value ;;
        --adb) FRANKEL_AUDIO_ADB=$value ;;
        --serial) FRANKEL_AUDIO_SERIAL=$value ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$value ;;
      esac
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

for required_name in file endpoint rate format channels period_size \
  period_count ultrasonic_mode; do
  [[ -n ${!required_name} ]] || \
    frankel_audio_die "--${required_name//_/-} is required"
done
[[ -f "$file" ]] || frankel_audio_die "WAV file not found: $file"
file=$(realpath -- "$file")

case "$endpoint" in
  earpiece|bottom) ;;
  *) frankel_audio_die "endpoint must be earpiece or bottom; simultaneous amps are unsafe" ;;
esac
rate_enum=$(frankel_audio_rate_enum "$rate")
[[ -n "$tdm_format" ]] || tdm_format=$format
tdm_format_enum=$(frankel_audio_playback_format_enum "$tdm_format")
bits=$(frankel_audio_format_bits "$format")
sample_bytes=$(frankel_audio_playback_sample_bytes "$format")
frankel_audio_require_positive_integer channels "$channels"
(( channels >= 2 && channels <= 4 )) || \
  frankel_audio_die "audio_ultrasonic playback requires 2, 3, or 4 channels"
frankel_audio_require_positive_integer tdm-channels "$tdm_channels"
frankel_audio_require_positive_integer tdm-slots "$tdm_slots"
(( tdm_channels <= 4 )) || frankel_audio_die "tdm-channels must be between 1 and 4"
(( tdm_slots <= 4 )) || frankel_audio_die "tdm-slots must be between 1 and 4"
(( tdm_slots >= tdm_channels )) || \
  frankel_audio_die "tdm-slots must be at least tdm-channels"
frankel_audio_require_positive_integer period-size "$period_size"
frankel_audio_require_positive_integer period-count "$period_count"
frankel_audio_validate_period_geometry \
  "$channels" "$sample_bytes" "$period_size" "$period_count"
case "$ultrasonic_mode" in
  disabled) codec_ultrasonic_mode=Disabled ;;
  in-band) codec_ultrasonic_mode='In Band' ;;
  out-of-band) codec_ultrasonic_mode='Out of Band' ;;
  *) frankel_audio_die "ultrasonic mode must be disabled, in-band, or out-of-band" ;;
esac
case "$high_rate_source" in
  direct) codec_high_rate_source=ASPRX1 ;;
  dsp-fs2) codec_high_rate_source='DSP FS2' ;;
  *) frankel_audio_die "high-rate source must be direct or dsp-fs2" ;;
esac
case "$slot_format" in
  s16) slot_format_enum=S16_LE ;;
  s32) slot_format_enum=S32_LE ;;
  *) frankel_audio_die "slot format must be s16 or s32" ;;
esac
tdm_channel_enum=$(frankel_audio_channel_enum "$tdm_channels")
tdm_slot_enum=$(frankel_audio_channel_enum "$tdm_slots")
[[ "$amp_gain" =~ ^[0-9]+$ ]] || \
  frankel_audio_die "raw amp gain must be a non-negative integer"
(( amp_gain <= 20 )) || \
  frankel_audio_die "raw amp gain must be between 0 and 20"

"$script_directory/generate-signal.py" inspect "$file" \
  --expect-rate "$rate" --expect-channels "$channels" --expect-bits "$bits"

frankel_audio_initialize_device tinyplay
frankel_audio_arm_cleanup

# Register hard-off cleanup before the first state-changing operation.  These
# controls are intentionally not restored to a possibly-on state.
frankel_audio_register_safe_control 'Main AMP Enable Switch' 0
frankel_audio_register_safe_control 'R Main AMP Enable Switch' 0
frankel_audio_register_safe_control 'TDM_0_RX Mixer US' 0
frankel_audio_register_safe_control 'Ultrasonic Mode' Disabled
frankel_audio_register_safe_control 'R Ultrasonic Mode' Disabled

frankel_audio_require_control_zero 'Main AMP Enable Switch'
frankel_audio_require_control_zero 'R Main AMP Enable Switch'
frankel_audio_require_control_zero 'TDM_0_RX Mixer US'
frankel_audio_require_control_value 'Ultrasonic Mode' Disabled
frankel_audio_require_control_value 'R Ultrasonic Mode' Disabled
for active_source in EP1 EP2 EP3 EP4 EP5 EP6 EP7 EP8 IMSV NoHost1 RAW VOIP; do
  frankel_audio_require_control_zero "TDM_0_RX Mixer $active_source"
done

remote_file="$FRANKEL_AUDIO_REMOTE_DIRECTORY/frankel-audio-play-${BASHPID}.wav"
frankel_audio_register_remote_temp "$remote_file"
frankel_audio_note "pushing validated WAV to Frankel"
frankel_audio_adb push "$file" "$remote_file" >/dev/null
frankel_audio_remote_exec chmod 0644 "$remote_file"

# Configure the AoC/TDM stream and both codecs while the route and amps remain
# off. TDM_0_RX Format is the DPCM backend format and can differ from the WAV
# and D28 front-end format; --slot-format independently selects physical slot
# packing. This distinction permits an S32-only D28 front end to feed a valid
# S16 backend when a four-slot, 12.288 MHz physical route is selected.
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Sample Rate' "$rate_enum"
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Format' "$tdm_format_enum"
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Chan' "$tdm_channel_enum"
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX nSlot' "$tdm_slot_enum"
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX SlotFmt' "$slot_format_enum"

for prefix in '' 'R '; do
  frankel_audio_snapshot_and_set_scalar "${prefix}DSP RX1 Source" ASPRX1
  frankel_audio_snapshot_and_set_scalar "${prefix}DSP RX2 Source" ASPRX1
  frankel_audio_snapshot_and_set_scalar "${prefix}PCM Source" ASPRX1
  frankel_audio_snapshot_and_set_scalar \
    "${prefix}High Rate PCM Source" "$codec_high_rate_source"
  frankel_audio_snapshot_and_set_scalar "${prefix}Amp Gain" "$amp_gain"
done

frankel_audio_tinymix_set 'Ultrasonic Mode' "$codec_ultrasonic_mode"
frankel_audio_tinymix_set 'R Ultrasonic Mode' "$codec_ultrasonic_mode"
frankel_audio_tinymix_set 'TDM_0_RX Mixer US' 1
case "$endpoint" in
  earpiece)
    frankel_audio_tinymix_set 'Main AMP Enable Switch' 1
    ;;
  bottom)
    frankel_audio_tinymix_set 'R Main AMP Enable Switch' 1
    ;;
esac

frankel_audio_note \
  "playing PCM 0,$FRANKEL_AUDIO_PLAYBACK_DEVICE: endpoint=$endpoint rate=$rate format=$format channels=$channels tdm=${tdm_format}/${tdm_channels}ch/${tdm_slots}x${slot_format} periods=${period_size}x${period_count}"
set +e
playback_output=$(frankel_audio_run_guarded /system/bin/tinyplay "$remote_file" \
  -D "$FRANKEL_AUDIO_CARD" -d "$FRANKEL_AUDIO_PLAYBACK_DEVICE" \
  -p "$period_size" -n "$period_count" 2>&1)
playback_status=$?
set -e
printf '%s\n' "$playback_output"
(( playback_status == 0 )) || \
  frankel_audio_die "tinyplay/ADB exited with status $playback_status"
if [[ "$playback_output" =~ [Uu]nable|[Ee]rror|only[[:space:]]supports ]]; then
  frankel_audio_die "tinyplay reported a PCM error"
fi

frankel_audio_finish_cleanup
frankel_audio_note "playback complete; both amps and the ultrasound route are off"
