#!/usr/bin/env bash
# Cubs TAS25XX baseline/ultrasonic route probe; no firmware mutations.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
adb_bin="$project_root/work/toolchains/platform-tools-37.0.1/platform-tools/adb"
port=5038 serial= output= wav= endpoint=bottom pcm=deep asp=bypass
while (($#)); do
  case "$1" in
    --adb|--adb-server-port|--serial|--output-dir|--wav|--endpoint|--pcm|--asp)
      (($# >= 2)) || exit 2
      case "$1" in
        --adb) adb_bin=$2;; --adb-server-port) port=$2;; --serial) serial=$2;;
        --output-dir) output=$2;; --wav) wav=$2;; --endpoint) endpoint=$2;;
        --pcm) pcm=$2;; --asp) asp=$2;;
      esac
      shift 2;;
    -h|--help)
      echo 'Usage: direct-speaker-play.sh --output-dir NEW --wav S32_STEREO_WAV [--endpoint bottom|top|stereo] [--pcm deep|primary|ultrasonic] [--asp bypass|stock] [ADB options]'
      echo 'deep admits 48/96/192 kHz (higher rates need the admission kernel); primary requires48k, ultrasonic96k. Existing root ADB required. Four-slot TDM default; a marked direct192 prototype can declare two slots. PCM admission is not acoustic qualification.'
      exit 0;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ -n "$output" && ! -e "$output" && -f "$wav" && -x "$adb_bin" && "$port" =~ ^[0-9]+$ ]] || exit 2
case "$endpoint" in bottom|top|stereo) ;; *) exit 2;; esac
case "$asp" in bypass|stock) ;; *) exit 2;; esac
case "$pcm" in deep) device=5 route=EP6;; primary) device=1 route=EP2;; ultrasonic) device=28 route=US;; *) exit 2;; esac
wav_parameters=$(python3 - "$wav" "$pcm" <<'PY'
import math, sys, wave
with wave.open(sys.argv[1], 'rb') as w:
    rates = {'deep': (48000, 96000, 192000), 'primary': (48000,), 'ultrasonic': (96000,)}[sys.argv[2]]
    if (w.getnchannels(), w.getsampwidth()) != (2, 4) or w.getframerate() not in rates:
        raise SystemExit('Require uncompressed stereo S32 at the route-specific rate.')
    duration = w.getnframes() / w.getframerate()
    if not .02 <= duration <= 10:
        raise SystemExit('This initial probe wrapper only admits .02..10 seconds.')
    print(w.getframerate(), math.ceil(duration))
PY
)
read -r expected_rate duration_ceiling <<< "$wav_parameters"
mkdir -p -- "$output"
output=$(cd -- "$output" && pwd -P)
adb=("$adb_bin" -P "$port")
[[ -z "$serial" ]] || adb+=(-s "$serial")
remote=/data/local/tmp/cubs-speaker-$(date +%s)-$$
printf 'wav=%s\nendpoint=%s\npcm=%s\nrate=%s\nasp=%s\nremote=%s\n' "$wav" "$endpoint" "$device" "$expected_rate" "$asp" "$remote" > "$output/parameters.txt"
# Transfer before stopping services or changing the mixer.
timeout 15 "${adb[@]}" shell "mkdir '$remote'"
timeout 60 "${adb[@]}" push -Z "$wav" "$remote/stimulus.wav" > "$output/push.txt" 2>&1
set +e
timeout "$((duration_ceiling + 180))" "${adb[@]}" shell sh -s -- "$expected_rate" "$device" "$route" "$endpoint" "$asp" "$remote" "$duration_ceiling" <<'DEVICE' 2>&1 | tee "$output/session.txt"
set -eu
rate=$1 device=$2 route=$3 endpoint=$4 asp=$5 run=$6 duration=$7
[ "$(id -u)" = 0 ] && [ "$(getprop ro.product.device)" = cubs ] && [ "$(getprop sys.boot_completed)" = 1 ] || exit 2
[ -x /system/bin/tinyplay ] && [ -x /system/bin/tinymix ] || exit 2
pcm_id=$(printf '00-%02d:' "$device")
grep -q "^$pcm_id.*playback 1" /proc/asound/pcm || exit 2
generation() {
  cat /proc/sys/kernel/random/boot_id &&
  cat /sys/devices/platform/a800000.aoc/restart_count &&
  cat /sys/devices/platform/a800000.aoc/coredump_count
}
initial_generation=$(generation) || exit 2
printf '%s\n' "$initial_generation" > "$run/generation-before.txt"
audio_state=$(getprop init.svc.audioserver)
hal_state=$(getprop init.svc.vendor.audio-hal-aidl)
replacement_state=$(getprop init.svc.vendor.audio-hal-powerphone-cubs)
case "$audio_state" in running|stopped) ;; *) echo 'UNKNOWN_AUDIOSERVER_STATE'; exit 2;; esac
case "$hal_state" in ''|running|stopped) ;; *) echo 'UNKNOWN_PROPRIETARY_HAL_STATE'; exit 2;; esac
case "$replacement_state" in ''|running|stopped) ;; *) echo 'UNKNOWN_REPLACEMENT_HAL_STATE'; exit 2;; esac
snapshot_ready=0 phase=service-quiescence
research_profile_seen=0
[ -z "$replacement_state" ] || research_profile_seen=1
[ ! -e /dev/powerphone-cubs-mono192 ] || research_profile_seen=1
mixget() { timeout 8 /system/bin/tinymix -D 0 -v -- "$1"; }
mixset() { timeout 8 /system/bin/tinymix -D 0 -- "$@"; }
mixrestore() {
  mixrestore_name=$1 mixrestore_value=$2
  mixrestore_actual=$(mixget "$mixrestore_name") || return 1
  [ "$mixrestore_actual" != "$mixrestore_value" ] || return 0
  case "$mixrestore_value" in On) mixrestore_value=1;; Off) mixrestore_value=0;; esac
  mixset "$mixrestore_name" "$mixrestore_value"
}
hold_research_services_stopped() {
  [ "$(getprop init.svc.audioserver)" = stopped ] || stop audioserver
  hold_wait=0
  while [ "$(getprop init.svc.audioserver)" != stopped ]; do
    hold_wait=$((hold_wait + 1)); [ "$hold_wait" -lt 100 ] || return 1
    sleep .1
  done
  # Platform audioserver-stop actions can queue HAL starts. Stop the old
  # owner first and the replacement last, then require stable quiescence.
  sleep .3
  hold_i=0 hold_stable=0
  while [ "$hold_stable" -lt 5 ]; do
    hold_audio=$(getprop init.svc.audioserver)
    hold_hal=$(getprop init.svc.vendor.audio-hal-aidl)
    hold_replacement=$(getprop init.svc.vendor.audio-hal-powerphone-cubs)
    if [ "$hold_audio" = stopped ] &&
       { [ -z "$hold_hal" ] || [ "$hold_hal" = stopped ]; } &&
       { [ -z "$hold_replacement" ] || [ "$hold_replacement" = stopped ]; }; then
      hold_stable=$((hold_stable + 1))
    else
      hold_stable=0
      [ "$hold_audio" = stopped ] || stop audioserver
      [ -z "$hold_hal" ] || [ "$hold_hal" = stopped ] || stop vendor.audio-hal-aidl
      [ -z "$hold_replacement" ] || [ "$hold_replacement" = stopped ] || stop vendor.audio-hal-powerphone-cubs
    fi
    hold_i=$((hold_i + 1)); [ "$hold_i" -lt 100 ] || return 1
    sleep .1
  done
}
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  set +e
  echo "EXIT_PHASE=$phase EXIT_STATUS=$status audioserver=$(getprop init.svc.audioserver) hal=$(getprop init.svc.vendor.audio-hal-aidl) replacement=$(getprop init.svc.vendor.audio-hal-powerphone-cubs)"
  [ -z "$(getprop init.svc.vendor.audio-hal-powerphone-cubs)" ] || research_profile_seen=1
  [ ! -e /dev/powerphone-cubs-mono192 ] || research_profile_seen=1
  if [ "$research_profile_seen" = 1 ]; then
    hold_research_services_stopped || { echo 'RESEARCH_SERVICE_QUARANTINE_FAILED'; exit 3; }
  fi
  final_generation=$(generation)
  generation_status=$?
  printf '%s\n' "$final_generation" > "$run/generation-after.txt"
  if [ "$generation_status" != 0 ] || [ "$initial_generation" != "$final_generation" ]; then
    echo 'CLEANUP_UNSAFE_GENERATION: leaving services stopped; do not replay stale mixer state.'
    exit 3
  fi
  restore_status=0
  if [ "$snapshot_ready" = 1 ]; then
    mixrestore 'TAS25XX ASI Switch' Off || restore_status=1
    mixrestore "TDM_0_RX Mixer $route" Off || restore_status=1
    while IFS="$(printf '\t')" read -r name value; do
      mixrestore "$name" "$value" || restore_status=1
    done < "$run/mixer-snapshot.tsv"
    while IFS="$(printf '\t')" read -r name value; do
      actual=$(mixget "$name") || restore_status=1
      [ "$actual" = "$value" ] || { echo "RESTORE_MISMATCH $name expected=$value actual=$actual"; restore_status=1; }
    done < "$run/mixer-snapshot.tsv"
  fi
  if [ "$restore_status" = 0 ]; then
    if [ "$research_profile_seen" = 1 ] || [ -e /dev/powerphone-cubs-mono192 ]; then
      hold_research_services_stopped || { echo 'RESEARCH_SERVICE_QUARANTINE_FAILED'; exit 3; }
      echo 'ORDINARY_AUDIO_HELD_STOPPED=1 REBOOT_REQUIRED=1'
    else
      [ "$hal_state" != running ] || start vendor.audio-hal-aidl
      [ "$audio_state" != running ] || start audioserver
    fi
    echo 'CLEANUP_RESTORED=1'
  else
    echo 'CLEANUP_FAILED: leaving services stopped.'
    status=3
  fi
  printf '%s\n' "$status" > "$run/status.txt"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
[ "$(getprop init.svc.audioserver)" = stopped ] || stop audioserver
i=0
while [ "$(getprop init.svc.audioserver)" != stopped ]; do
  i=$((i + 1)); [ "$i" -lt 100 ] || { echo 'AUDIOSERVER_STOP_TIMEOUT'; exit 2; }; sleep .1
done
sleep .3
i=0 stable=0
while [ "$stable" -lt 5 ]; do
  audio_now=$(getprop init.svc.audioserver)
  hal_now=$(getprop init.svc.vendor.audio-hal-aidl)
  replacement_now=$(getprop init.svc.vendor.audio-hal-powerphone-cubs)
  if [ "$audio_now" = stopped ] &&
     { [ -z "$hal_now" ] || [ "$hal_now" = stopped ]; } &&
     { [ -z "$replacement_now" ] || [ "$replacement_now" = stopped ]; }; then
    stable=$((stable + 1))
  else
    stable=0
    echo "QUIESCE_RETRY audioserver=$audio_now hal=$hal_now replacement=$replacement_now"
    [ "$audio_now" = stopped ] || stop audioserver
    [ -z "$hal_now" ] || [ "$hal_now" = stopped ] || stop vendor.audio-hal-aidl
    [ -z "$replacement_now" ] || [ "$replacement_now" = stopped ] || stop vendor.audio-hal-powerphone-cubs
  fi
  i=$((i + 1)); [ "$i" -lt 100 ] || { echo 'HAL_STOP_TIMEOUT'; exit 2; }; sleep .1
done
echo 'SERVICES_QUIESCENT=1'
echo 'DIRECT_OWNERSHIP: audioserver stopped; proprietary/replacement HAL stopped or absent'
if [ -e /dev/powerphone-cubs-direct96 ] && [ -e /dev/powerphone-cubs-direct192 ]; then
  research_profile_seen=1
  echo 'CONFLICTING_DIRECT96_AND_DIRECT192_MARKERS'; exit 2
fi
if [ -e /dev/powerphone-cubs-direct96 ]; then
  research_profile_seen=1
  [ "$device:$rate:$asp" = 5:96000:bypass ] || {
    echo 'DIRECT96_PROFILE_REQUIRES_D5_RATE_96000_ASP_BYPASS'; exit 2;
  }
elif [ -e /dev/powerphone-cubs-direct192 ]; then
  research_profile_seen=1
  [ "$device:$rate:$asp" = 5:192000:bypass ] || {
    echo 'DIRECT192_PROFILE_REQUIRES_D5_RATE_192000_ASP_BYPASS'; exit 2;
  }
fi
tdm_slots=4 tdm_slot_source=normal-default
if [ -e /dev/powerphone-cubs-direct96 ] || [ -e /dev/powerphone-cubs-direct192 ]; then
  tdm_slot_source=legacy-direct-default
  if [ -e /dev/powerphone-cubs-tdm-slots ] || [ -L /dev/powerphone-cubs-tdm-slots ]; then
    [ -f /dev/powerphone-cubs-tdm-slots ] || { echo 'INVALID_DIRECT_TDM_SLOT_FILE'; exit 2; }
    tdm_slots=$(cat /dev/powerphone-cubs-tdm-slots) || { echo 'DIRECT_TDM_SLOT_READ_FAILED'; exit 2; }
    tdm_slot_source=direct-manifest-marker
  fi
  case "$tdm_slots" in 2|4) ;; *) echo "INVALID_DIRECT_TDM_SLOTS=$tdm_slots"; exit 2;; esac
  if [ "$tdm_slots" = 2 ]; then
    [ -e /dev/powerphone-cubs-direct192 ] && [ "$device:$rate:$asp" = 5:192000:bypass ] || {
      echo 'TWO_SLOTS_REQUIRE_DIRECT192_D5_RATE_192000_ASP_BYPASS'; exit 2;
    }
  fi
fi
case "$tdm_slots" in 2) tdm_slot_enum=Two;; 4) tdm_slot_enum=Four;; esac
printf 'tdm_slots=%s\ntdm_slot_source=%s\n' "$tdm_slots" "$tdm_slot_source" > "$run/tdm-geometry.txt"
cat "$run/tdm-geometry.txt"
phase=pcm-owner-check
set +e
timeout 10 ls -ld /proc/[0-9]*/fd/* > "$run/pcm-owner-scan.txt" 2> "$run/pcm-owner-scan-errors.txt"
owner_scan_status=$?
set -e
[ "$owner_scan_status" -le 1 ] || { echo "PCM_OWNER_SCAN_FAILED=$owner_scan_status"; exit 2; }
if grep -E ' -> /dev/snd/pcmC0D[0-9]+[pc]($| )' "$run/pcm-owner-scan.txt"; then
  echo 'PCM_STILL_OPEN'; exit 2
fi
cat /proc/asound/pcm > "$run/pcm-inventory.txt"
phase=mixer-snapshot
for name in 'TAS25XX ASI Switch' "TDM_0_RX Mixer $route" 'TAS25XX CODEC PROFILE' 'AoC Speaker Mixer ASP Mode' 'TDM_0_RX Sample Rate' 'TDM_0_RX Format' 'TDM_0_RX Chan' 'TDM_0_RX nSlot' 'TDM_0_RX SlotFmt'; do
  value=$(mixget "$name") || exit 2
  printf '%s\t%s\n' "$name" "$value" >> "$run/mixer-snapshot.tsv"
done
[ "$(mixget 'TAS25XX ASI Switch')" = Off ] || { echo 'ASI_ALREADY_ACTIVE'; exit 2; }
[ "$(mixget "TDM_0_RX Mixer $route")" = Off ] || { echo 'ROUTE_ALREADY_ACTIVE'; exit 2; }
snapshot_ready=1
phase=mixer-configuration
mixset 'TAS25XX CODEC PROFILE' "music_17dB_$endpoint"
if [ "$asp" = bypass ]; then
  /system/bin/tinymix -D 0 -- 'AoC Speaker Mixer ASP Mode' > "$run/asp-enum.txt"
  grep -q ASP_BYPASS "$run/asp-enum.txt" || { echo 'ASP_BYPASS_NOT_ADVERTISED'; exit 2; }
  mixset 'AoC Speaker Mixer ASP Mode' ASP_BYPASS
fi
mixset 'TDM_0_RX Sample Rate' "SR_$((rate / 1000))K"
mixset 'TDM_0_RX Format' S32_LE
mixset 'TDM_0_RX Chan' "$tdm_slot_enum"
mixset 'TDM_0_RX nSlot' "$tdm_slot_enum"
mixset 'TDM_0_RX SlotFmt' S32_LE
mixset "TDM_0_RX Mixer $route" 1
mixset 'TAS25XX ASI Switch' 1
phase=pcm-playback
echo "PLAYBACK_START rate=$rate pcm=$device endpoint=$endpoint asp=$asp tdm_slots=$tdm_slots period=$((rate / 100)) count=4"
cat /proc/uptime > "$run/playback-uptime-before.txt"
set +e
timeout "$((duration + 8))" /system/bin/tinyplay "$run/stimulus.wav" -D 0 -d "$device" -p "$((rate / 100))" -n 4 > "$run/tinyplay.txt" 2>&1
play_status=$?
set -e
cat /proc/uptime > "$run/playback-uptime-after.txt"
cat "$run/tinyplay.txt"
echo "PLAYBACK_EXIT=$play_status"
[ "$play_status" = 0 ] || exit "$play_status"
if grep -Ei 'cannot|unable|failed|error|overrun|underrun' "$run/tinyplay.txt"; then exit 1; fi
echo 'PLAYBACK_COMMAND_COMPLETE: acoustic output and sustained bandwidth are not yet qualified.'
DEVICE
statuses=("${PIPESTATUS[@]}")
set -e
pull_status=0
timeout 60 "${adb[@]}" pull -Z "$remote/." "$output/" > "$output/pull.txt" 2>&1 || pull_status=$?
if [[ -f "$output/tdm-geometry.txt" ]]; then cat "$output/tdm-geometry.txt" >> "$output/parameters.txt"; fi
printf 'remote_status=%s\nlogger_status=%s\npull_status=%s\n' "${statuses[0]}" "${statuses[1]}" "$pull_status" > "$output/transport-status.txt"
((statuses[0] == 0 && statuses[1] == 0 && pull_status == 0)) || exit 1
