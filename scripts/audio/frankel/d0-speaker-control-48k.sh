#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  d0-speaker-control-48k.sh --file WAV --endpoint bottom|earpiece \
    [--amp-gain RAW] [--asp-mode on|bypass] [--player tinyplay|staged] \
    [--pcm-device 0|1|5|23|28] [--player-bin PATH] \
    [--rate 48000|96000|192000] [--backend-rate 48000|96000|192000] \
    [--channels 2|3|4] [--access rw|mmap] [--period-size FRAMES] \
    [--period-count N] [--start-threshold FRAMES] [--codec-route normal|high-rate] \
    [--playback-timeout SECONDS] \
    [ADB options]

Play a two- to four-channel S16_LE or S32_LE WAV for a direct ALSA diagnostic.
The default is a 48 kHz positive-control trial. Explicit higher rates probe
the actual driver's acceptance; no resampling is performed by this script.
Successful writes do not qualify acoustic emission or bandwidth. The TDM
backend defaults to the frontend rate, four S32 channels in four S32 slots.
The selected amp receives normal PCM ASPRX1 with High Rate PCM Zero and
ultrasonic mode Disabled. Gain defaults to 6; ASP mode defaults to bypass.

Requires a booted Frankel with root ADB and audioserver plus both audio HAL
services already stopped. This script does not change service state. It
restores routing settings and forces both amps, EP1, and RAW off on exit.

Options:
  --file WAV                 Local 16- or 32-bit PCM WAV.
  --rate RATE                WAV/frontend rate (default: 48000).
  --backend-rate RATE        TDM rate (default: same as --rate).
  --endpoint ENDPOINT        bottom or earpiece.
  --amp-gain RAW             Selected amp gain, 0..20 (default: 6).
  --asp-mode MODE            on or bypass (default: bypass).
  --player PLAYER            tinyplay (960x4, default) or staged (1920x2,
                             start threshold 1920, bounded EFAULT retries).
  --pcm-device DEVICE        0=EP1 (default), 1=EP2 (primary), 5=EP6
                             (deep-buffer), 23=RAW, or 28=US (S32 only).
  --channels N               Frontend WAV channels, 2..4 (default: 2).
  --access MODE              Staged access rw (default) or mmap.
  --period-size FRAMES       Default 960 for tinyplay, 1920 for staged.
  --period-count N           Default 4 for tinyplay, 2 for staged.
  --start-threshold FRAMES   Staged start threshold (default: 1920).
  --codec-route ROUTE        normal selects PCM ASPRX1/High Rate Zero and
                             Disabled mode (default); high-rate selects PCM
                             Zero/High Rate ASPRX1 with In Band mode.
  --player-bin PATH          Override the selected remote playback binary.
  --playback-timeout SEC     On-device playback deadline (default: 45).
                             Enforced inside the remote cleanup shell.
  --adb PATH                 Project platform-tools/adb by default.
  --serial SERIAL            Select an ADB device.
  --adb-server-port PORT     Existing ADB server port (default: 5038).
  -h, --help                 Show usage without contacting a device.
USAGE
}

file=
endpoint=
amp_gain=6
asp_mode=bypass
player=tinyplay
pcm_device=0
player_bin=
rate=48000
backend_rate=
channels=2
access=rw
period_size=
period_count=
start_threshold=1920
codec_route=normal
playback_timeout=45
while (( $# > 0 )); do
  case "$1" in
    --file|--endpoint|--amp-gain|--asp-mode|--player|--player-bin|--pcm-device|--rate|--backend-rate|--channels|--access|--period-size|--period-count|--start-threshold|--codec-route|--playback-timeout|--adb|--serial|--adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --file) file=$value ;;
        --endpoint) endpoint=$value ;;
        --amp-gain) amp_gain=$value ;;
        --asp-mode) asp_mode=$value ;;
        --player) player=$value ;;
        --player-bin) player_bin=$value ;;
        --rate) rate=$value ;;
        --backend-rate) backend_rate=$value ;;
        --pcm-device) pcm_device=$value ;;
        --channels) channels=$value ;;
        --access) access=$value ;;
        --period-size) period_size=$value ;;
        --period-count) period_count=$value ;;
        --start-threshold) start_threshold=$value ;;
        --codec-route) codec_route=$value ;;
        --playback-timeout) playback_timeout=$value ;;
        --adb) FRANKEL_AUDIO_ADB=$value ;;
        --serial) FRANKEL_AUDIO_SERIAL=$value ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$value ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    *) frankel_audio_die "unknown argument: $1 (use --help)" ;;
  esac
done

[[ -n "$file" && -f "$file" ]] || frankel_audio_die "--file must name a WAV"
frankel_audio_require_positive_integer playback-timeout "$playback_timeout"
file=$(realpath -- "$file")
case "$endpoint" in
  earpiece) codec_prefix= ;;
  bottom) codec_prefix='R ' ;;
  *) frankel_audio_die "--endpoint must be bottom or earpiece" ;;
esac
frankel_audio_require_integer amp-gain "$amp_gain"
(( amp_gain <= 20 )) || frankel_audio_die "amp-gain must be 0..20"
case "$asp_mode" in
  on) asp_mode_value=ASP_ON ;;
  bypass) asp_mode_value=ASP_BYPASS ;;
  *) frankel_audio_die "asp-mode must be on or bypass" ;;
esac
case "$player" in
  tinyplay)
    period_size=${period_size:-960}
    period_count=${period_count:-4}
    ;;
  staged)
    period_size=${period_size:-1920}
    period_count=${period_count:-2}
    ;;
  *) frankel_audio_die "player must be tinyplay or staged" ;;
esac
case "$pcm_device" in
  0) route_control='TDM_0_RX Mixer EP1' ;;
  1) route_control='TDM_0_RX Mixer EP2' ;;
  5) route_control='TDM_0_RX Mixer EP6' ;;
  23) route_control='TDM_0_RX Mixer RAW' ;;
  28) route_control='TDM_0_RX Mixer US' ;;
  *) frankel_audio_die "pcm-device must be 0, 1, 5, 23, or 28" ;;
esac
case "$channels" in
  2|3|4) ;;
  *) frankel_audio_die "channels must be 2, 3, or 4" ;;
esac
case "$access" in
  rw) ;;
  mmap) [[ "$player" == staged ]] || frankel_audio_die "mmap requires --player staged" ;;
  *) frankel_audio_die "access must be rw or mmap" ;;
esac
for geometry_name in period_size period_count start_threshold; do
  frankel_audio_require_positive_integer "${geometry_name//_/-}" "${!geometry_name}"
done
case "$codec_route" in
  normal) pcm_source=ASPRX1; high_rate_source=Zero; ultrasonic_mode=Disabled ;;
  high-rate) pcm_source=Zero; high_rate_source=ASPRX1; ultrasonic_mode='In Band' ;;
  *) frankel_audio_die "codec-route must be normal or high-rate" ;;
esac
case "$rate" in
  48000|96000|192000) ;;
  *) frankel_audio_die "rate must be 48000, 96000, or 192000" ;;
esac
backend_rate=${backend_rate:-$rate}
case "$backend_rate" in
  48000) backend_rate_value=SR_48K ;;
  96000) backend_rate_value=SR_96K ;;
  192000) backend_rate_value=SR_192K ;;
  *) frankel_audio_die "backend-rate must be 48000, 96000, or 192000" ;;
esac
file_info=$("$script_directory/generate-signal.py" inspect "$file" \
  --expect-rate "$rate" --expect-channels "$channels")
printf '%s\n' "$file_info"
case "$file_info" in
  *' bits=16 '*) pcm_format=s16 ;;
  *' bits=32 '*) pcm_format=s32 ;;
  *) frankel_audio_die "WAV must contain 16- or 32-bit PCM" ;;
esac
if [[ "$pcm_device" == 28 && "$pcm_format" != s32 ]]; then
  frankel_audio_die "D28 requires a 32-bit PCM WAV"
fi

frankel_audio_initialize_device tinyplay
for service in audioserver vendor.audio-hal-powerphone vendor.audio-hal-aidl; do
  service_state=$(frankel_audio_remote_exec getprop "init.svc.$service")
  [[ "$service_state" == stopped ]] || \
    frankel_audio_die "$service must already be stopped (state=$service_state)"
done
frankel_audio_arm_cleanup
frankel_audio_register_safe_control 'Main AMP Enable Switch' 0
frankel_audio_register_safe_control 'R Main AMP Enable Switch' 0
frankel_audio_register_safe_control 'TDM_0_RX Mixer EP1' 0
frankel_audio_register_safe_control 'TDM_0_RX Mixer RAW' 0
frankel_audio_register_safe_control "$route_control" 0
frankel_audio_register_safe_control 'Ultrasonic Mode' Disabled
frankel_audio_register_safe_control 'R Ultrasonic Mode' Disabled

frankel_audio_tinymix_set 'Main AMP Enable Switch' 0
frankel_audio_tinymix_set 'R Main AMP Enable Switch' 0
frankel_audio_tinymix_set 'TDM_0_RX Mixer EP1' 0
frankel_audio_tinymix_set 'TDM_0_RX Mixer RAW' 0
frankel_audio_tinymix_set "$route_control" 0
frankel_audio_tinymix_set 'Ultrasonic Mode' Disabled
frankel_audio_tinymix_set 'R Ultrasonic Mode' Disabled

remote_file="$FRANKEL_AUDIO_REMOTE_DIRECTORY/frankel-d0-control48-${BASHPID}.wav"
frankel_audio_register_remote_temp "$remote_file"
frankel_audio_adb push "$file" "$remote_file" >/dev/null
frankel_audio_remote_exec chmod 0644 "$remote_file"

frankel_audio_snapshot_and_set_scalar 'AoC Speaker Mixer ASP Mode' "$asp_mode_value"
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Sample Rate' "$backend_rate_value"
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Format' S32_LE
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Chan' Four
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX nSlot' Four
frankel_audio_snapshot_and_set_scalar 'TDM_0_RX SlotFmt' S32_LE
frankel_audio_snapshot_and_set_scalar "${codec_prefix}DSP RX1 Source" ASPRX1
frankel_audio_snapshot_and_set_scalar "${codec_prefix}DSP RX2 Source" ASPRX1
frankel_audio_snapshot_and_set_scalar "${codec_prefix}PCM Source" "$pcm_source"
frankel_audio_snapshot_and_set_scalar "${codec_prefix}High Rate PCM Source" "$high_rate_source"
frankel_audio_snapshot_and_set_scalar "${codec_prefix}Digital PCM Volume" 817
frankel_audio_snapshot_and_set_scalar "${codec_prefix}Amp Gain" "$amp_gain"
frankel_audio_tinymix_set "${codec_prefix}Ultrasonic Mode" "$ultrasonic_mode"
frankel_audio_tinymix_set "${codec_prefix}Main AMP Enable Switch" 1

declare -a playback_command
case "$player" in
  tinyplay)
    playback_command=("${player_bin:-/system/bin/tinyplay}" "$remote_file" -D 0 -d "$pcm_device" -p "$period_size" -n "$period_count")
    ;;
  staged)
    playback_command=(
      "${player_bin:-/vendor/bin/frankel_aoc_staged_play}"
      --card 0 --device "$pcm_device" --rate "$rate" --channels "$channels" --format "$pcm_format"
      --period-size "$period_size" --period-count "$period_count" --start-threshold "$start_threshold"
      --route-control "$route_control" --prepare-route bound
      --access "$access" --rw-efault-retries 64 --rw-efault-sleep-us 1000
      "$remote_file"
    )
    ;;
esac
# An outer host timeout can terminate ADB without killing a remote PCM owner.
# Keep this deadline inside the device shell that owns amplifier cleanup.
playback_command=(/system/bin/timeout -s KILL "$playback_timeout" "${playback_command[@]}")
frankel_audio_note "ALSA control: rate=$rate backend_rate=$backend_rate endpoint=$endpoint amp_gain=$amp_gain asp_mode=$asp_mode codec_route=$codec_route player=$player access=$access PCM=0,$pcm_device route=$route_control $pcm_format/${channels}ch periods=${period_size}x${period_count} threshold=$start_threshold timeout=${playback_timeout}s"
set +e
playback_output=$(frankel_audio_run_guarded_after_control \
  "$route_control" 1 \
  "${playback_command[@]}" 2>&1)
playback_status=$?
set -e
printf '%s\n' "$playback_output"
(( playback_status == 0 )) || \
  frankel_audio_die "$player/ADB exited with status $playback_status"
if [[ "$playback_output" =~ [Uu]nable|[Ee]rror|only[[:space:]]supports ]]; then
  frankel_audio_die "$player reported a PCM error"
fi
frankel_audio_finish_cleanup
frankel_audio_note "ALSA control complete; both amps and the selected route are off"
