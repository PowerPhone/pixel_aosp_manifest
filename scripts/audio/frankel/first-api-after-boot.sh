#!/usr/bin/env bash
# Real first-launch qualification: no adb root, mixer writes, or service changes.
set -euo pipefail
export LC_ALL=C
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_directory/common.sh"

usage() {
  printf '%s\n' \
    'Usage: first-api-after-boot.sh --output-dir NEW --after-boot-id OLD_UUID' \
    '  [--adb PATH] [--adb-server-port PORT] [--serial SERIAL]' \
    'Waits up to 240 seconds for a DIFFERENT boot UUID, boot_completed=1,' \
    'sys.powerphone.audio_boot=ready, and stopped boot animation.' \
    'A completed new boot reporting audio_boot=failed terminates immediately,' \
    'with phase-failure.txt and qualification.json; no API activity is launched.' \
    'Immediately launches installed StockPlaybackActivity: ordinary-speaker' \
    'AAudio 192 kHz, 20 kHz tone, 5 seconds, amplitude 0.02; simultaneous' \
    'Java AudioRecord 192 kHz on research D10 MIC0, with quiet lead and tail.' \
    'Never roots, grants permissions, changes volume/mixers, or stops services.' \
    'Requires the installed APK and existing microphone permission.' \
    'Retains launch timestamps, passive logs, fresh native report and original WAV.' \
    'API transport PASS is not an acoustic-bandwidth or jitter qualification.'
}

output_dir= old_boot_id=
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --output-dir|--after-boot-id|--adb|--adb-server-port|--serial)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      case "$1" in
        --output-dir) output_dir=$2 ;; --after-boot-id) old_boot_id=$2 ;;
        --adb) FRANKEL_AUDIO_ADB=$2 ;; --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$2 ;;
        --serial) FRANKEL_AUDIO_SERIAL=$2 ;;
      esac
      shift 2 ;;
    *) frankel_audio_die "unknown argument: $1" ;;
  esac
done
[[ -n "$output_dir" ]] || frankel_audio_die '--output-dir is required'
[[ "$old_boot_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || \
  frankel_audio_die '--after-boot-id must be the actual previous boot UUID'
old_boot_id=${old_boot_id,,}
FRANKEL_AUDIO_ADB=${FRANKEL_AUDIO_ADB:-"$frankel_audio_project_root/work/toolchains/platform-tools/adb"}
[[ -x "$FRANKEL_AUDIO_ADB" ]] || frankel_audio_die "adb is not executable: $FRANKEL_AUDIO_ADB"
for utility in timeout python3 rg; do command -v "$utility" >/dev/null || frankel_audio_die "missing $utility"; done
output_dir=$(realpath -m -- "$output_dir")
[[ ! -e "$output_dir" ]] || frankel_audio_die "output directory exists: $output_dir"
mkdir -p -- "$output_dir"
printf 'previous_boot_id=%s\nhost_start_epoch=%s\n' "$old_boot_id" "$(date +%s.%N)" > "$output_dir/session.txt"
# Do NOT use common.sh's initialize_device: it requires root and mixer access.
adb_command=(env "ADB_LIBUSB=${FRANKEL_AUDIO_ADB_LIBUSB:-1}" "$FRANKEL_AUDIO_ADB"
  -P "${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}")
[[ -z ${FRANKEL_AUDIO_SERIAL:-} ]] || adb_command+=(-s "$FRANKEL_AUDIO_SERIAL")
logcat_pid= logcat_since=1
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$logcat_pid" ]]; then
    kill "$logcat_pid" 2>/dev/null || true
    wait "$logcat_pid" 2>/dev/null || true
  fi
  printf 'script_exit_status=%s\nhost_end_epoch=%s\n' "$status" "$(date +%s.%N)" >> "$output_dir/session.txt"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
start_logcat() {
  timeout --signal=TERM --kill-after=2 360 "${adb_command[@]}" shell \
    "logcat -v threadtime -T '$logcat_since' 'PowerPhoneStock:*' 'AHAL_Powerphone:*' 'AudioFlinger:*' '*:E'" \
    >> "$output_dir/logcat-live.txt" 2>&1 &
  logcat_pid=$!
}

deadline=$((SECONDS + 240))
new_boot_id=
while (( SECONDS < deadline )); do
  # Read the UUID twice so properties cannot be accepted across a reboot.
  state=$(FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=3 frankel_audio_adb shell \
    'cat /proc/sys/kernel/random/boot_id; getprop sys.boot_completed; getprop sys.powerphone.audio_boot; getprop init.svc.bootanim; getprop ro.product.device; id -u; cat /proc/sys/kernel/random/boot_id' \
    2>> "$output_dir/adb-readiness-errors.txt" | tr -d '\r') || state=
  printf 'host_epoch=%s\n%s\n' "$(date +%s.%N)" "$state" >> "$output_dir/readiness.txt"
  mapfile -t fields <<< "$state"
  if (( ${#fields[@]} == 7 )) && [[ ${fields[0]} == "${fields[6]}" ]] && \
      [[ ${fields[0]} != "$old_boot_id" && ${fields[0]} =~ ^[0-9a-fA-F-]{36}$ ]]; then
    if [[ -n "$new_boot_id" && "$new_boot_id" != "${fields[0]}" ]]; then
      frankel_audio_die 'new boot rebooted again before qualification; preserve this failed attempt'
    fi
    new_boot_id=${fields[0]}
    if [[ -z "$logcat_pid" ]] || ! kill -0 "$logcat_pid" 2>/dev/null; then
      start_logcat
    fi
    if [[ ${fields[1]} == 1 && ${fields[2]} == failed && ${fields[3]} == stopped ]]; then
      {
        printf 'failure=public_audio_boot_bridge_failed\nboot_id=%s\nshell_uid=%s\n' "$new_boot_id" "${fields[5]}"
        printf 'sys.boot_completed=1\nsys.powerphone.audio_boot=failed\ninit.svc.bootanim=stopped\n'
        printf 'private_phase_and_flags=NOT_INFERRED_FROM_PUBLIC_BRIDGE\n'
        printf 'host_failure_epoch=%s\n' "$(date +%s.%N)"
        # Preserve any exposed failure phase. Empty private properties remain
        # NA; this read-only attempt never escalates shell permissions.
        FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=3 frankel_audio_adb shell '
          for key in vendor.powerphone.bootstrap.phase vendor.powerphone.pdm.ready vendor.powerphone.aoc_speaker_192k.ready; do
            value=$(getprop "$key")
            printf "%s=%s\n" "$key" "${value:-NA}"
          done
          date +device_failure_epoch=%s.%N
          printf "device_failure_uptime="; cat /proc/uptime
        ' || true
      } > "$output_dir/phase-failure.txt" 2>&1
      python3 - "$output_dir" "$new_boot_id" <<'PY'
import json,sys
from pathlib import Path
report={'api_transport_status':'NOT_RUN','boot_readiness_status':'FAIL',
        'boot_id':sys.argv[2],'failures':['public_audio_boot_bridge_failed'],
        'phase_evidence':'phase-failure.txt','private_readiness_status':'NOT_INDEPENDENTLY_VERIFIED',
        'acoustic_status':'NOT_RUN'}
(Path(sys.argv[1])/'qualification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
PY
      exit 2
    fi
    if [[ ${fields[1]} == 1 && ${fields[2]} == ready && ${fields[3]} == stopped ]]; then
      [[ ${fields[4]} == frankel ]] || frankel_audio_die "unexpected device: ${fields[4]}"
      [[ ${fields[5]} == 2000 ]] || frankel_audio_die "non-root first-launch qualification requires shell UID 2000, got ${fields[5]}"
      break
    fi
  fi
  sleep 1
done
(( SECONDS < deadline )) || frankel_audio_die '240-second deadline: no different, audio-ready boot'
printf 'qualified_boot_id=%s\nshell_uid=2000\nhost_ready_epoch=%s\n' \
  "$new_boot_id" "$(date +%s.%N)" >> "$output_dir/session.txt"

# Record device uptime and epoch BEFORE waking or dismissing the keyguard.
# These are the exact extras read by the existing StockPlaybackActivity.
launch_command=$(frankel_audio_remote_command am start -W -n com.csr460.powerphone/.StockPlaybackActivity \
  --es output_api aaudio --ei output_rate 192000 --ei tone_hz 20000 \
  --ei duration_seconds 5 --ef peak_level 0.02 \
  --ez record_reference true --ez research_reference true)
set +e
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=25 frankel_audio_adb shell "
test \"\$(cat /proc/sys/kernel/random/boot_id)\" = '$new_boot_id' || exit 2
date '+before_awake_epoch=%s.%N'
printf 'before_awake_uptime='; cat /proc/uptime
input keyevent KEYCODE_WAKEUP || exit 2
wm dismiss-keyguard || exit 2
date '+before_launch_epoch=%s.%N'
printf 'before_launch_uptime='; cat /proc/uptime
$launch_command
" > "$output_dir/launch.txt" 2>&1
launch_status=$?
set -e
printf 'launch_status=%s\n' "$launch_status" >> "$output_dir/session.txt"
cat "$output_dir/launch.txt"
# Reconnecting readers use -T 1; the final filtered archive fills any gap,
# and the qualifier accepts only this launch's new app PID and run ID.
finish_deadline=$((SECONDS + 40))
while (( SECONDS < finish_deadline )); do
  if rg -q 'PowerPhoneStock: STOCK_PLAYBACK_(COMPLETE|FAILED)' "$output_dir/logcat-live.txt"; then
    break
  fi
  if ! kill -0 "$logcat_pid" 2>/dev/null; then start_logcat; fi
  sleep 1
done
# Retain the quiet tail too: a later HAL idle failure must not be concealed.
sleep 4
kill "$logcat_pid" 2>/dev/null || true
wait "$logcat_pid" 2>/dev/null || true
logcat_pid=
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=8 frankel_audio_adb shell \
  "logcat -d -v threadtime 'PowerPhoneStock:*' 'AHAL_Powerphone:*' 'AudioFlinger:*' '*:E'" \
  > "$output_dir/logcat-archive.txt" 2>&1 || true
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=8 frankel_audio_adb shell \
  'cat /proc/sys/kernel/random/boot_id; getprop sys.boot_completed; getprop sys.powerphone.audio_boot; getprop init.svc.bootanim; id -u; date +%s.%N; cat /proc/uptime' \
  > "$output_dir/after-state.txt" 2>&1 || true

# Native report is a fixed filename, so its unique run ID MUST match this launch.
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=10 frankel_audio_adb pull \
  /sdcard/Android/data/com.csr460.powerphone/files/stock-aaudio-latest.txt \
  "$output_dir/native-report.txt" > "$output_dir/native-report-pull.txt" 2>&1 || true
reference_path=$(python3 - "$output_dir" <<'PY'
import re,sys
from decimal import Decimal
from pathlib import Path
p=Path(sys.argv[1]); launch=(p/'launch.txt').read_text(errors='replace')
at=re.search(r'^before_launch_epoch=([0-9.]+)$',launch,re.M)
if at:
    minimum=Decimal(at[1])*1000
    text=(p/'logcat-live.txt').read_text(errors='replace')+'\n'+(p/'logcat-archive.txt').read_text(errors='replace')
    paths={m[0] for m in re.findall(r'STOCK_REFERENCE_BEGIN file=(/storage/emulated/0/Android/data/com\.csr460\.powerphone/files/Music/research-reference-([0-9]+)\.wav) rate=192000',text) if Decimal(m[1])>=minimum}
    if len(paths)==1: print(paths.pop())
PY
)
if [[ -n "$reference_path" ]]; then
  printf '%s\n' "$reference_path" > "$output_dir/reference-device-path.txt"
  FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=10 frankel_audio_adb pull "$reference_path" \
    "$output_dir/capture.wav" > "$output_dir/reference-pull.txt" 2>&1 || true
fi

python3 - "$output_dir" "$new_boot_id" "$launch_status" <<'PY'
import json,re,sys,wave
from decimal import Decimal
from pathlib import Path
p=Path(sys.argv[1]); failures=[]
def require(ok, reason):
    if not ok: failures.append(reason)
def read(name):
    path=p/name
    return path.read_text(errors='replace') if path.exists() else ''
launch=read('launch.txt'); live=read('logcat-live.txt'); archived=read('logcat-archive.txt')
require(sys.argv[3]=='0' and 'Status: ok' in launch,'activity_launch_failed')
at=re.search(r'^before_launch_epoch=([0-9.]+)$',launch,re.M)
minimum=Decimal(at[1])*1000 if at else Decimal('Infinity')
require(at is not None,'missing_device_launch_epoch')
require('Invalid filter expression' not in live,'invalid_live_logcat_filter')
lines=list(dict.fromkeys((live+'\n'+archived).splitlines()))
begins=[]
for line in lines:
    m=re.search(r'\s(\d+)\s+\d+\s+I PowerPhoneStock: STOCK_AAUDIO_REPORT_BEGIN file=\S+ run_id=(\d+-\d+)',line)
    if m and Decimal(m[2].split('-')[0])>=minimum: begins.append((m[1],m[2]))
begins=list(dict.fromkeys(begins)); require(len(begins)==1,'fresh_native_begin_missing_or_ambiguous')
app=''
run_id=begins[0][1] if len(begins)==1 else None
if run_id:
    pid=begins[0][0]
    app='\n'.join(line for line in lines if re.search(r'\s'+pid+r'\s+\d+\s+[A-Z] PowerPhoneStock:',line))
    require('STOCK_PLAYBACK_BEGIN api=aaudio rate=192000 channels=2 encoding=PCM_FLOAT tone_hz=20000 peak=0.02 frames=960000 duration_seconds=5' in app,'wrong_playback_configuration')
    require('STOCK_PLAYBACK_COMPLETE api=aaudio' in app,'playback_complete_missing')
    require('STOCK_REFERENCE_TONE_START' in app and 'STOCK_REFERENCE_TONE_END' in app,'reference_tone_boundaries_missing')
    require('STOCK_PLAYBACK_FAILED' not in app and 'STOCK_REFERENCE_FAILED' not in app,'application_failure')
    require('STOCK_REFERENCE_BEGIN' in app and 'POWERPHONE_C0_D10_MIC0' in app,'research_microphone_missing')
(p/'app.txt').write_text(app+'\n')
native=read('native-report.txt')
require(run_id is not None and re.findall(r'^run_id=(\S+)$',native,re.M)==[run_id],'native_report_stale_or_missing')
for marker in ('output_rate=192000','tone_hz=20000','duration_seconds=5','output_address=null','native_report_state=RETURNED','AAUDIO_RUN_OK'):
    require(marker in native,'native_missing_'+marker)
require('AAUDIO_RUN_FAILED' not in native,'native_failure')
require('frames transferred/target: 960000 / 960000' in native,'native_incomplete_frame_transfer')
reference=read('reference-device-path.txt').strip()
completed=re.findall(r'STOCK_REFERENCE_COMPLETE file=(\S+) frames=(\d+) duration_seconds=([0-9.]+) route=([^\n]+)',app)
completed=list(dict.fromkeys(completed))
require(len(completed)==1,'fresh_reference_complete_missing_or_ambiguous')
wav_info=None
try:
    with wave.open(str(p/'capture.wav'),'rb') as wav:
        wav_info={'rate':wav.getframerate(),'channels':wav.getnchannels(),'sample_bytes':wav.getsampwidth(),'frames':wav.getnframes()}
        require((wav.getframerate(),wav.getnchannels(),wav.getsampwidth())==(192000,1,2),'reference_wav_format')
        require(wav.getnframes()>=192000*6.5,'reference_wav_too_short')
        if len(completed)==1:
            require(reference==completed[0][0] and wav.getnframes()==int(completed[0][1]),'reference_path_or_frames_mismatch')
            require('POWERPHONE_C0_D10_MIC0' in completed[0][3],'wrong_completed_reference_route')
except Exception as error: failures.append('reference_wav_unavailable:'+str(error))
after=read('after-state.txt').splitlines()
require(len(after)>=5 and after[:5]==[sys.argv[2],'1','ready','stopped','2000'],'boot_or_shell_readiness_changed')
errors=[line for line in live.splitlines() if re.search(r'AHAL_Powerphone.*(PCM ring write failed|playback integrity|ownership.*fault|refusing invalid playback burst)|AudioStreamOutSink.*Error while writing data to HAL',line)]
(p/'hal-errors.txt').write_text('\n'.join(errors)+'\n')
require(not errors,'live_hal_playback_failure')
report={'api_transport_status':'FAIL' if failures else 'PASS','failures':failures,'boot_id':sys.argv[2],'run_id':run_id,'reference_device_path':reference,'wav':wav_info,'acoustic_status':'NOT_QUALIFIED','limits':'This first-launch API check does not establish physical 192 kHz bandwidth, acoustic fidelity, or no jitter. Inspect the original recorded 20 kHz tone separately. No root, permission, volume, mixer, HAL or service changes were made by this harness.'}
(p/'qualification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
sys.exit(bool(failures))
PY
