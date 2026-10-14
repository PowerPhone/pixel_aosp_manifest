#!/usr/bin/env bash
# Cubs-only volatile mixer experiment. No firmware patches or rate qualification.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
adb_bin="$project_root/work/toolchains/platform-tools-37.0.1/platform-tools/adb"
port=5038 serial= output= rate=48000 mic=0 duration=3
while (($#)); do
  case "$1" in
    --adb|--adb-server-port|--serial|--output-dir|--rate|--mic|--duration)
      (($# >= 2)) || exit 2
      case "$1" in
        --adb) adb_bin=$2;; --adb-server-port) port=$2;; --serial) serial=$2;;
        --output-dir) output=$2;; --rate) rate=$2;; --mic) mic=$2;; --duration) duration=$2;;
      esac
      shift 2;;
    -h|--help)
      echo 'Usage: direct-mic-capture.sh --output-dir NEW [--rate 48000|96000|192000] [--mic 0|1|2|all] [--duration 3] [--adb PATH] [--adb-server-port 5038] [--serial SERIAL]'
      echo 'Requires existing root ADB. --mic all requires the exact RAW3 firmware marker and192k/S16/D10; mono requests are rejected under RAW3. Stops/restores framework services; retains failed attempts. No microphone-clock reads while capturing. A successful WAV is not bandwidth proof. Existing duration tolerance remains0.25s; known startup deficits are reported as failures, not trimmed or hidden.'
      exit 0;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ -n "$output" && ! -e "$output" && "$port" =~ ^[0-9]+$ && "$duration" =~ ^[0-9]+$ ]] || exit 2
[[ "$rate" =~ ^(48000|96000|192000)$ && "$mic" =~ ^([012]|all)$ ]] || exit 2
capture_channels=1
if [[ "$mic" = all ]]; then
  [[ "$rate" = 192000 ]] || { echo 'RAW3_REQUIRES_RATE_192000' >&2; exit 2; }
  capture_channels=3
fi
((duration >= 1 && duration <= 120)) || exit 2
[[ -x "$adb_bin" ]] || exit 2
mkdir -p -- "$output"
output=$(cd -- "$output" && pwd -P)
adb=("$adb_bin" -P "$port")
[[ -z "$serial" ]] || adb+=(-s "$serial")
remote=/data/local/tmp/cubs-mic-$(date +%s)-$$
printf 'rate=%s\nlogical_mic=%s\nchannels=%s\nduration=%s\nremote=%s\n' "$rate" "$mic" "$capture_channels" "$duration" "$remote" > "$output/parameters.txt"
set +e
timeout "$((duration + 180))" "${adb[@]}" shell sh -s -- "$rate" "$mic" "$duration" "$remote" <<'DEVICE' 2>&1 | tee "$output/session.txt"
set -eu
rate=$1 mic=$2 duration=$3 run=$4
[ "$(id -u)" = 0 ] && [ "$(getprop ro.product.device)" = cubs ] && [ "$(getprop sys.boot_completed)" = 1 ] || exit 2
[ -x /system/bin/tinycap ] && [ -x /system/bin/tinymix ] || exit 2
grep -q '^00-10:.*capture 1' /proc/asound/pcm || exit 2
mkdir "$run"
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
snapshot_ready=0 logcat_pid=
phase=service-quiescence
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
    log -p i -t PowerPhoneCubs "CAPTURE_CLEANUP_END run=$run status=$evidence_exit phase=$phase"
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
  # Finalize explicitly on every branch; do not depend on nested EXIT traps.
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
# Android's audioserver=stopped trigger restarts the HAL for VTS. Let that
# queued trigger finish, then stop the HAL last and require stable quiescence.
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
  [ "$mic:$rate" = all:192000 ] || { echo 'RAW3_PROFILE_REQUIRES_MIC_ALL_RATE_192000'; exit 2; }
  capture_channels=3 capture_channel_enum=Three
elif [ "$mic" = all ]; then
  echo 'MIC_ALL_REQUIRES_VERIFIED_RAW3_PROFILE'; exit 2
fi
echo "CAPTURE_PROFILE channels=$capture_channels logical_mic=$mic format=S16_LE pcm=10"
if [ "$research_profile_seen" = 1 ] || [ -e /dev/powerphone-cubs-mono192 ]; then
  research_profile_seen=1
  [ "$rate" = 192000 ] || { echo 'MONO192_PROFILE_REQUIRES_CAPTURE_RATE_192000'; exit 2; }
fi
phase=pcm-owner-check
# No other process may retain a PCM while this script owns microphone routing.
set +e
timeout 10 ls -ld /proc/[0-9]*/fd/* > "$run/pcm-owner-scan.txt" 2> "$run/pcm-owner-scan-errors.txt"
owner_scan_status=$?
set -e
# ls may report a disappeared process/FD as status 1 during this read-only scan.
[ "$owner_scan_status" -le 1 ] || { echo "PCM_OWNER_SCAN_FAILED=$owner_scan_status"; exit 2; }
if grep -E ' -> /dev/snd/pcmC0D[0-9]+[pc]($| )' "$run/pcm-owner-scan.txt"; then
  echo 'PCM_STILL_OPEN'; exit 2
fi
cat /proc/asound/pcm > "$run/pcm-inventory.txt"
phase=mixer-snapshot
# Snapshot only named controls: specifically do not query the MIC Clock Rate getter.
for name in 'EP3 TX Mixer INTERNAL_MIC_TX' 'BUILTIN MIC Process Mode' 'Audio Capture Mic Source' 'Mic Spatial Module Enable' 'MIC DC Blocker' 'MIC Record Soft Gain (dB)' 'BUILDIN MIC ID CAPTURE LIST' 'INTERNAL_MIC_TX Sample Rate' 'INTERNAL_MIC_TX Format' 'INTERNAL_MIC_TX Chan'; do
  value=$(mixget "$name") || exit 2
  printf '%s\t%s\n' "$name" "$value" >> "$run/mixer-snapshot.tsv"
done
[ "$(mixget 'EP3 TX Mixer INTERNAL_MIC_TX')" = Off ] || exit 2
snapshot_ready=1
phase=mixer-configuration
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
mixset 'INTERNAL_MIC_TX Sample Rate' "SR_$((rate / 1000))K"
mixset 'INTERNAL_MIC_TX Format' S16_LE
mixset 'INTERNAL_MIC_TX Chan' "$capture_channel_enum"
timeout 10 dmesg > "$run/dmesg-before.txt" 2> "$run/dmesg-before-errors.txt" || true
# Passive Android logger only: never open/compete for /dev/acd-debug. Four
# rotating16-MiB files bound disk use while preserving the capture/cleanup span.
logcat -b all -v threadtime -T 1 -f "$run/logcat-live.txt" -r 16384 -n 3 '*:V' > "$run/logcat-live-stdout.txt" 2> "$run/logcat-live-errors.txt" &
logcat_pid=$!
sleep .1
kill -0 "$logcat_pid" 2>/dev/null || { echo 'LOGCAT_START_FAILED'; cat "$run/logcat-live-errors.txt"; exit 1; }
log -p i -t PowerPhoneCubs "CAPTURE_BEGIN run=$run rate=$rate mic=$mic channels=$capture_channels duration=$duration"
mixset 'EP3 TX Mixer INTERNAL_MIC_TX' 1
echo "CAPTURE_START rate=$rate logical_mic=$mic channels=$capture_channels period=$((rate / 100)) count=4"
phase=pcm-capture
set +e
timeout "$((duration + 8))" /system/bin/tinycap "$run/capture.wav" -D 0 -d 10 -c "$capture_channels" -r "$rate" -b 16 -p "$((rate / 100))" -n 4 -T "$duration" > "$run/tinycap.txt" 2>&1
capture_status=$?
set -e
cat "$run/tinycap.txt"
echo "CAPTURE_EXIT=$capture_status"
[ "$capture_status" = 0 ] || exit "$capture_status"
[ -s "$run/capture.wav" ] || exit 1
if grep -Ei 'cannot|unable|failed|error|overrun|underrun' "$run/tinycap.txt"; then exit 1; fi
DEVICE
statuses=("${PIPESTATUS[@]}")
set -e
pull_status=0
timeout 45 "${adb[@]}" pull -Z "$remote/." "$output/" > "$output/pull.txt" 2>&1 || pull_status=$?
printf 'remote_status=%s\nlogger_status=%s\npull_status=%s\n' "${statuses[0]}" "${statuses[1]}" "$pull_status" > "$output/transport-status.txt"
((statuses[0] == 0 && statuses[1] == 0 && pull_status == 0)) || exit 1
python3 - "$output/capture.wav" "$rate" "$duration" "$capture_channels" <<'PY'
import json, sys, wave
with wave.open(sys.argv[1], 'rb') as w:
    data = dict(rate=w.getframerate(), channels=w.getnchannels(), bits=8*w.getsampwidth(), frames=w.getnframes())
data['seconds'] = data['frames']/data['rate']
data['requested_seconds'] = int(sys.argv[3])
data['duration_deficit_seconds'] = data['requested_seconds']-data['seconds']
print(json.dumps(data))
if data['rate'] != int(sys.argv[2]) or data['channels'] != int(sys.argv[4]) or data['bits'] != 16 or abs(data['seconds']-int(sys.argv[3])) > .25:
    raise SystemExit('CAPTURE_FORMAT_OR_DURATION_FAILURE')
print('TRANSPORT_ONLY_COMPLETE: no acoustic bandwidth qualification inferred.')
PY
