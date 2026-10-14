#!/usr/bin/env bash
# Real Cubs acoustic probe with one owner for both routes. No firmware patches.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
adb_bin="$project_root/work/toolchains/platform-tools-37.0.1/platform-tools/adb"
port=5038 serial= output= wav= endpoint=bottom asp=bypass capture_rate=48000 mic=0 pcm=deep
capture_duration=5 max_playback_duration=2
while (($#)); do
  case "$1" in
    --adb|--adb-server-port|--serial|--output-dir|--wav|--endpoint|--asp|--capture-rate|--mic|--pcm|--capture-duration|--max-playback-duration)
      (($# >= 2)) || exit 2
      case "$1" in
        --adb) adb_bin=$2;; --adb-server-port) port=$2;; --serial) serial=$2;;
        --output-dir) output=$2;; --wav) wav=$2;; --endpoint) endpoint=$2;;
        --asp) asp=$2;; --capture-rate) capture_rate=$2;; --mic) mic=$2;; --pcm) pcm=$2;;
        --capture-duration) capture_duration=$2;; --max-playback-duration) max_playback_duration=$2;;
      esac
      shift 2;;
    -h|--help)
      echo 'Usage: duplex-baseline.sh --output-dir NEW --wav S32_STEREO_WAV [--endpoint bottom|top|stereo] [--pcm deep|primary|ultrasonic] [--asp bypass|stock] [--capture-rate 48000|96000|192000] [--mic 0|1|2|all] [--capture-duration 5..60] [--max-playback-duration 1..30] [ADB options]'
      echo 'Default5s capture/<=2s playback after1s quiet. Explicit long-run knobs require actualWAV <=capture_duration−3s. --mic all requires verified RAW3 marker and192k/three channels; mono requests rejected under RAW3. Deep D5 admits48/96/192k; primary only48k, ultrasonic only96k. Four-slot TDM default; marked direct192 can declare two. Duration tolerance0.25s unchanged; startup deficits fail without trimming. No active clock getter or inferred bandwidth qualification.'
      exit 0;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ -n "$output" && ! -e "$output" && -f "$wav" && -x "$adb_bin" && "$port" =~ ^[0-9]+$ ]] || exit 2
[[ "$capture_rate" =~ ^(48000|96000|192000)$ && "$mic" =~ ^([012]|all)$ ]] || exit 2
[[ "$capture_duration" =~ ^[1-9][0-9]*$ && "$max_playback_duration" =~ ^[1-9][0-9]*$ ]] || exit 2
((capture_duration >= 5 && capture_duration <= 60 && max_playback_duration >= 1 && max_playback_duration <= 30)) || exit 2
capture_channels=1
if [[ "$mic" = all ]]; then
  [[ "$capture_rate" = 192000 ]] || { echo 'RAW3_REQUIRES_CAPTURE_RATE_192000' >&2; exit 2; }
  capture_channels=3
fi
case "$endpoint" in bottom|top|stereo) ;; *) exit 2;; esac
case "$asp" in bypass|stock) ;; *) exit 2;; esac
case "$pcm" in deep) device=5 route=EP6;; primary) device=1 route=EP2;; ultrasonic) device=28 route=US;; *) exit 2;; esac
wav_parameters=$(python3 - "$wav" "$pcm" "$capture_duration" "$max_playback_duration" <<'PY'
import math, sys, wave
with wave.open(sys.argv[1], 'rb') as w:
    rates = {'deep': (48000, 96000, 192000), 'primary': (48000,), 'ultrasonic': (96000,)}[sys.argv[2]]
    if (w.getnchannels(), w.getsampwidth()) != (2, 4) or w.getframerate() not in rates:
        raise SystemExit('Require uncompressed stereo S32 at the route-specific rate.')
    duration = w.getnframes()/w.getframerate()
    if not .02 <= duration <= min(int(sys.argv[4]), int(sys.argv[3])-3):
        raise SystemExit('Playback must be .02s..explicit limit (default2s, maximum30s), and leave at least3s in capture for startup/lead/tail.')
    print(w.getframerate(), math.ceil(duration), w.getnframes(), duration)
PY
)
read -r playback_rate playback_duration_ceiling playback_frames playback_duration <<< "$wav_parameters"
mkdir -p -- "$output"
output=$(cd -- "$output" && pwd -P)
adb=("$adb_bin" -P "$port")
[[ -z "$serial" ]] || adb+=(-s "$serial")
remote=/data/local/tmp/cubs-duplex-$(date +%s)-$$
printf 'wav=%s\nendpoint=%s\nplayback_pcm=%s\nplayback_rate=%s\ncapture_rate=%s\nlogical_mic=%s\ncapture_channels=%s\nasp=%s\nremote=%s\n' "$wav" "$endpoint" "$device" "$playback_rate" "$capture_rate" "$mic" "$capture_channels" "$asp" "$remote" > "$output/parameters.txt"
printf 'capture_duration=%s\nmax_playback_duration=%s\nplayback_frames=%s\nplayback_duration=%s\n' "$capture_duration" "$max_playback_duration" "$playback_frames" "$playback_duration" >> "$output/parameters.txt"
timeout 15 "${adb[@]}" shell "mkdir '$remote'"
# WSL/libusb compressed transfer stalled on the real 30-second probe;
# uncompressed transfer completed in 1.283 seconds. Preserve the same bytes.
timeout 60 "${adb[@]}" push -Z "$wav" "$remote/stimulus.wav" > "$output/push.txt" 2>&1
set +e
timeout "$((capture_duration + 175))" "${adb[@]}" shell sh -s -- "$playback_rate" "$device" "$route" "$endpoint" "$asp" "$capture_rate" "$mic" "$remote" "$capture_duration" "$playback_duration_ceiling" <<'DEVICE' 2>&1 | tee "$output/session.txt"
set -eu
rate=$1 device=$2 route=$3 endpoint=$4 asp=$5 capture_rate=$6 mic=$7 run=$8
capture_duration=$9 playback_duration_ceiling=${10}
[ "$(id -u)" = 0 ] && [ "$(getprop ro.product.device)" = cubs ] && [ "$(getprop sys.boot_completed)" = 1 ] || exit 2
[ -x /system/bin/tinyplay ] && [ -x /system/bin/tinycap ] && [ -x /system/bin/tinymix ] || exit 2
pcm_id=$(printf '00-%02d:' "$device")
grep -q "^$pcm_id.*playback 1" /proc/asound/pcm || exit 2
grep -q '^00-10:.*capture 1' /proc/asound/pcm || exit 2
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
snapshot_ready=0 phase=service-quiescence capture_pid= logcat_pid=
research_profile_seen=0
[ -z "$replacement_state" ] || research_profile_seen=1
[ ! -e /dev/powerphone-cubs-mono192 ] || research_profile_seen=1
[ ! -e /dev/powerphone-cubs-raw3-192 ] && [ ! -L /dev/powerphone-cubs-raw3-192 ] || research_profile_seen=1
mixget() { timeout 8 /system/bin/tinymix -D 0 -v -- "$1"; }
mixset() { timeout 8 /system/bin/tinymix -D 0 -- "$@"; }
mixrestore() {
  mixrestore_name=$1 mixrestore_value=$2
  mixrestore_actual=$(mixget "$mixrestore_name") || return 1
  [ "$mixrestore_actual" != "$mixrestore_value" ] || return 0
  case "$mixrestore_name" in
    'BUILDIN MIC ID CAPTURE LIST') mixset "$mixrestore_name" $mixrestore_value;;
    *) case "$mixrestore_value" in On) mixrestore_value=1;; Off) mixrestore_value=0;; esac
       mixset "$mixrestore_name" "$mixrestore_value";;
  esac
}
anchor() { date '+%s.%N'; cat /proc/uptime; }
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
finish_evidence() {
  evidence_exit=$1
  trap - EXIT
  set +e
  if [ -n "$logcat_pid" ]; then
    log -p i -t PowerPhoneCubs "DUPLEX_CLEANUP_END run=$run status=$evidence_exit phase=$phase"
  fi
  timeout 10 dmesg > "$run/dmesg-after.txt" 2> "$run/dmesg-after-errors.txt"
  dmesg_status=$?
  printf 'dmesg_status=%s\n' "$dmesg_status" > "$run/evidence-status.txt"
  if [ -n "$logcat_pid" ]; then
    if kill -0 "$logcat_pid" 2>/dev/null; then
      printf 'logger_alive_at_cleanup_end=1\n' >> "$run/evidence-status.txt"
      sleep .1
      kill "$logcat_pid" 2>/dev/null
    else
      printf 'logger_alive_at_cleanup_end=0\n' >> "$run/evidence-status.txt"
      [ "$evidence_exit" != 0 ] || evidence_exit=1
    fi
    wait "$logcat_pid"
    printf 'logger_wait_status=%s\n' "$?" >> "$run/evidence-status.txt"
    logcat_pid=
  fi
  printf '%s\n' "$evidence_exit" > "$run/status.txt"
  exit "$evidence_exit"
}
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  set +e
  # Explicit finalization also covers generation/quarantine failures.
  if [ -n "$capture_pid" ]; then kill "$capture_pid" 2>/dev/null; wait "$capture_pid"; capture_pid=; fi
  echo "EXIT_PHASE=$phase EXIT_STATUS=$status audioserver=$(getprop init.svc.audioserver) hal=$(getprop init.svc.vendor.audio-hal-aidl) replacement=$(getprop init.svc.vendor.audio-hal-powerphone-cubs)"
  [ -z "$(getprop init.svc.vendor.audio-hal-powerphone-cubs)" ] || research_profile_seen=1
  [ ! -e /dev/powerphone-cubs-mono192 ] || research_profile_seen=1
  [ ! -e /dev/powerphone-cubs-raw3-192 ] && [ ! -L /dev/powerphone-cubs-raw3-192 ] || research_profile_seen=1
  if [ "$research_profile_seen" = 1 ]; then
    hold_research_services_stopped || { echo 'RESEARCH_SERVICE_QUARANTINE_FAILED'; finish_evidence 3; }
  fi
  final_generation=$(generation)
  generation_status=$?
  printf '%s\n' "$final_generation" > "$run/generation-after.txt"
  if [ "$generation_status" != 0 ] || [ "$initial_generation" != "$final_generation" ]; then
    echo 'CLEANUP_UNSAFE_GENERATION: leaving services stopped; do not replay stale mixer state.'
    finish_evidence 3
  fi
  restore_status=0
  if [ "$snapshot_ready" = 1 ]; then
    mixrestore 'TAS25XX ASI Switch' Off || restore_status=1
    mixrestore "TDM_0_RX Mixer $route" Off || restore_status=1
    mixrestore 'EP3 TX Mixer INTERNAL_MIC_TX' Off || restore_status=1
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
      hold_research_services_stopped || { echo 'RESEARCH_SERVICE_QUARANTINE_FAILED'; finish_evidence 3; }
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
  finish_evidence "$status"
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
capture_channels=1 capture_channel_enum=One
if [ -e /dev/powerphone-cubs-raw3-192 ] || [ -L /dev/powerphone-cubs-raw3-192 ]; then
  research_profile_seen=1
  [ -f /dev/powerphone-cubs-raw3-192 ] || { echo 'INVALID_RAW3_MARKER_FILE'; exit 2; }
  raw3_profile=$(cat /dev/powerphone-cubs-raw3-192) || { echo 'RAW3_MARKER_READ_FAILED'; exit 2; }
  printf '%s\n' "$raw3_profile" > "$run/raw3-profile.txt"
  expected_raw3_profile=$(printf 'channels=3\nrate=192000\nformat=S16_LE\nlogical_mics=0,1,2\n')
  [ "$raw3_profile" = "$expected_raw3_profile" ] || { echo 'RAW3_MARKER_CONTENT_MISMATCH'; exit 2; }
  [ -e /dev/powerphone-cubs-mono192 ] || { echo 'RAW3_MISSING_RESEARCH_QUARANTINE'; exit 2; }
  [ "$(printf '%s\n' "$initial_generation" | tail -n 2)" = "$(printf '0\n0')" ] || {
    echo 'RAW3_REJECTED_AFTER_AOC_RESTART_OR_COREDUMP: marker may be stale; fresh boot required.'; exit 2;
  }
  [ "$mic:$capture_rate" = all:192000 ] || { echo 'RAW3_PROFILE_REQUIRES_MIC_ALL_RATE_192000'; exit 2; }
  capture_channels=3 capture_channel_enum=Three
elif [ "$mic" = all ]; then
  echo 'MIC_ALL_REQUIRES_VERIFIED_RAW3_PROFILE'; exit 2
fi
echo "CAPTURE_PROFILE channels=$capture_channels logical_mic=$mic format=S16_LE pcm=10"
if [ "$research_profile_seen" = 1 ] || [ -e /dev/powerphone-cubs-mono192 ]; then
  research_profile_seen=1
  [ "$capture_rate" = 192000 ] || { echo 'MONO192_PROFILE_REQUIRES_CAPTURE_RATE_192000'; exit 2; }
fi
phase=pcm-owner-check
set +e
timeout 10 ls -ld /proc/[0-9]*/fd/* > "$run/pcm-owner-scan.txt" 2> "$run/pcm-owner-scan-errors.txt"
owner_scan_status=$?
set -e
[ "$owner_scan_status" -le 1 ] || { echo "PCM_OWNER_SCAN_FAILED=$owner_scan_status"; exit 2; }
if grep -E ' -> /dev/snd/pcmC0D[0-9]+[pc]($| )' "$run/pcm-owner-scan.txt"; then echo 'PCM_STILL_OPEN'; exit 2; fi
cat /proc/asound/pcm > "$run/pcm-inventory.txt"
phase=mixer-snapshot
for name in 'TAS25XX ASI Switch' "TDM_0_RX Mixer $route" 'TAS25XX CODEC PROFILE' 'AoC Speaker Mixer ASP Mode' 'TDM_0_RX Sample Rate' 'TDM_0_RX Format' 'TDM_0_RX Chan' 'TDM_0_RX nSlot' 'TDM_0_RX SlotFmt' 'EP3 TX Mixer INTERNAL_MIC_TX' 'BUILTIN MIC Process Mode' 'Audio Capture Mic Source' 'Mic Spatial Module Enable' 'MIC DC Blocker' 'MIC Record Soft Gain (dB)' 'BUILDIN MIC ID CAPTURE LIST' 'INTERNAL_MIC_TX Sample Rate' 'INTERNAL_MIC_TX Format' 'INTERNAL_MIC_TX Chan'; do
  value=$(mixget "$name") || exit 2
  printf '%s\t%s\n' "$name" "$value" >> "$run/mixer-snapshot.tsv"
done
[ "$(mixget 'TAS25XX ASI Switch')" = Off ] || { echo 'ASI_ALREADY_ACTIVE'; exit 2; }
[ "$(mixget "TDM_0_RX Mixer $route")" = Off ] || { echo 'PLAYBACK_ROUTE_ALREADY_ACTIVE'; exit 2; }
[ "$(mixget 'EP3 TX Mixer INTERNAL_MIC_TX')" = Off ] || { echo 'CAPTURE_ROUTE_ALREADY_ACTIVE'; exit 2; }
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
mixset 'BUILTIN MIC Process Mode' Raw
mixset 'Audio Capture Mic Source' Builtin_MIC
mixset 'Mic Spatial Module Enable' 0
mixset 'MIC DC Blocker' 0
mixset 'MIC Record Soft Gain (dB)' 0
if [ "$mic" = all ]; then
  mixset 'BUILDIN MIC ID CAPTURE LIST' 0 1 2 -1
else
  mixset 'BUILDIN MIC ID CAPTURE LIST' "$mic" -1 -1 -1
fi
mixset 'INTERNAL_MIC_TX Sample Rate' "SR_$((capture_rate / 1000))K"
mixset 'INTERNAL_MIC_TX Format' S16_LE
mixset 'INTERNAL_MIC_TX Chan' "$capture_channel_enum"
timeout 10 dmesg > "$run/dmesg-before.txt" 2> "$run/dmesg-before-errors.txt" || true
logcat -b all -v threadtime -T 1 -f "$run/logcat-live.txt" -r 16384 -n 3 '*:V' > "$run/logcat-live-stdout.txt" 2> "$run/logcat-live-errors.txt" &
logcat_pid=$!
sleep .1
kill -0 "$logcat_pid" 2>/dev/null || { echo 'LOGCAT_START_FAILED'; cat "$run/logcat-live-errors.txt"; exit 1; }
log -p i -t PowerPhoneCubs "DUPLEX_BEGIN run=$run playback_rate=$rate capture_rate=$capture_rate mic=$mic capture_channels=$capture_channels endpoint=$endpoint tdm_slots=$tdm_slots capture_duration=$capture_duration playback_duration_ceiling=$playback_duration_ceiling"
mixset 'EP3 TX Mixer INTERNAL_MIC_TX' 1
phase=duplex-capture
anchor > "$run/capture-launch-anchor.txt"
timeout "$((capture_duration + 8))" /system/bin/tinycap "$run/capture.wav" -D 0 -d 10 -c "$capture_channels" -r "$capture_rate" -b 16 -p "$((capture_rate / 100))" -n 4 -T "$capture_duration" > "$run/tinycap.txt" 2>&1 &
capture_pid=$!
i=0
if [ -r /proc/asound/card0/pcm10c/sub0/status ]; then
  readiness_source=alsa-proc-running
else
  readiness_source=capture-file-growth-pcm-status-unavailable
fi
echo "CAPTURE_READINESS_SOURCE=$readiness_source"
while :; do
  kill -0 "$capture_pid" 2>/dev/null || { echo 'CAPTURE_DIED_BEFORE_RUNNING'; cat "$run/tinycap.txt"; exit 1; }
  if [ "$readiness_source" = alsa-proc-running ]; then
    grep -q '^state: RUNNING' /proc/asound/card0/pcm10c/sub0/status && break
  else
    capture_bytes=$(stat -c %s "$run/capture.wav" 2>/dev/null || echo 0)
    if [ "$capture_bytes" -gt 44 ]; then
      echo "CAPTURE_DATA_READY_BYTES=$capture_bytes"
      break
    fi
  fi
  i=$((i + 1)); [ "$i" -lt 100 ] || { echo 'CAPTURE_START_TIMEOUT'; exit 1; }; sleep .02
done
anchor > "$run/capture-running-anchor.txt"
sleep 1
mixset "TDM_0_RX Mixer $route" 1
mixset 'TAS25XX ASI Switch' 1
phase=duplex-playback
anchor > "$run/playback-launch-anchor.txt"
set +e
timeout "$((playback_duration_ceiling + 8))" /system/bin/tinyplay "$run/stimulus.wav" -D 0 -d "$device" -p "$((rate / 100))" -n 4 > "$run/tinyplay.txt" 2>&1
play_status=$?
anchor > "$run/playback-end-anchor.txt"
# Release only the speaker route immediately; D10 keeps its quiet tail.
# Never replay mixer commands into a different firmware generation.
speaker_stop_status=0
playback_generation=$(generation)
playback_generation_status=$?
if [ "$playback_generation_status" != 0 ] || [ "$playback_generation" != "$initial_generation" ]; then
  echo 'SPEAKER_STOP_UNSAFE_GENERATION: skipping stale mixer writes.'
  speaker_stop_status=3
else
  mixrestore 'TAS25XX ASI Switch' Off || speaker_stop_status=1
  mixrestore "TDM_0_RX Mixer $route" Off || speaker_stop_status=1
fi
printf '%s\n' "$speaker_stop_status" > "$run/speaker-stop-status.txt"
anchor > "$run/speaker-stop-anchor.txt"
wait "$capture_pid"
capture_status=$?
capture_pid=
set -e
anchor > "$run/capture-end-anchor.txt"
cat "$run/tinyplay.txt" "$run/tinycap.txt"
printf 'playback_status=%s\ncapture_status=%s\nspeaker_stop_status=%s\n' "$play_status" "$capture_status" "$speaker_stop_status" > "$run/pcm-status.txt"
timeout 10 dmesg > "$run/dmesg-capture-end.txt" 2> "$run/dmesg-capture-end-errors.txt" || true
[ "$play_status:$capture_status:$speaker_stop_status" = 0:0:0 ] || exit 1
if grep -Ei 'cannot|unable|failed|error|overrun|underrun' "$run/tinyplay.txt" "$run/tinycap.txt"; then exit 1; fi
[ -s "$run/capture.wav" ] || exit 1
echo 'DUPLEX_COMMANDS_COMPLETE: analyze the actual full capture; no acoustic PASS is inferred.'
DEVICE
statuses=("${PIPESTATUS[@]}")
set -e
pull_status=0
timeout 60 "${adb[@]}" pull -Z "$remote/." "$output/" > "$output/pull.txt" 2>&1 || pull_status=$?
if [[ -f "$output/tdm-geometry.txt" ]]; then cat "$output/tdm-geometry.txt" >> "$output/parameters.txt"; fi
printf 'remote_status=%s\nlogger_status=%s\npull_status=%s\n' "${statuses[0]}" "${statuses[1]}" "$pull_status" > "$output/transport-status.txt"
((statuses[0] == 0 && statuses[1] == 0 && pull_status == 0)) || exit 1
python3 - "$output/capture.wav" "$capture_rate" "$capture_channels" "$capture_duration" <<'PY'
import json, sys, wave
with wave.open(sys.argv[1], 'rb') as w:
    d = dict(rate=w.getframerate(), channels=w.getnchannels(), bits=8*w.getsampwidth(), frames=w.getnframes())
d['seconds'] = d['frames']/d['rate']
d['requested_seconds'] = int(sys.argv[4])
d['duration_deficit_seconds'] = d['requested_seconds']-d['seconds']
print(json.dumps(d))
if d['rate'] != int(sys.argv[2]) or d['channels'] != int(sys.argv[3]) or d['bits'] != 16 or abs(d['seconds']-d['requested_seconds']) > .25:
    raise SystemExit('CAPTURE_FORMAT_OR_DURATION_FAILURE: preserve this actual failed experiment, not a rate qualification.')
PY
