#!/usr/bin/env bash
# Experimental, reversible three-microphone capture; root owns both PCMs.
set -euo pipefail
export LC_ALL=C
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_directory/common.sh"
if (( $# != 4 )); then
  echo "Usage: $0 REVIEWED_DELTA.json STIMULUS.wav NEW_OUTPUT_DIR bottom|earpiece" >&2
  echo 'FRANKEL_AUDIO_DURATION defaults to34s; lead2s; capture192k/S16/3ch/1920x4.' >&2
  echo 'Requires root ADB and boot-ready mono profile. Restores mono before restarting services.' >&2
  exit 64
fi
profile=$(realpath -e -- "$1")
stimulus=$(realpath -e -- "$2")
output_dir=$(realpath -m -- "$3")
speaker=$4
case "$speaker" in bottom) speaker_prefix='R ' ;; earpiece) speaker_prefix='' ;; *) exit 64 ;; esac
duration=${FRANKEL_AUDIO_DURATION:-34}
lead=${FRANKEL_AUDIO_LEAD:-2}
frankel_audio_require_positive_integer duration "$duration"
frankel_audio_require_positive_integer lead "$lead"
[[ ! -e "$output_dir" ]] || frankel_audio_die "output already exists: $output_dir"
mkdir -p "$output_dir"
cp -- "$profile" "$output_dir/profile.json"
cp -- "$stimulus" "$output_dir/stimulus.wav"
stimulus_info=$("$script_directory/generate-signal.py" inspect "$stimulus" --expect-rate 192000 --expect-channels 2 --expect-bits 32)
printf '%s\n' "$stimulus_info" > "$output_dir/stimulus.txt"
[[ "$stimulus_info" =~ duration=([0-9]+)\.([0-9]+) ]] || frankel_audio_die 'missing stimulus duration'
stimulus_ceiling=${BASH_REMATCH[1]}
if [[ ${BASH_REMATCH[2]} =~ [1-9] ]]; then stimulus_ceiling=$((stimulus_ceiling + 1)); fi
(( duration >= lead + stimulus_ceiling + 1 )) || frankel_audio_die 'capture must cover complete stimulus and quiet lead/tail'
frankel_audio_initialize_device tinycap chrt
[[ $(frankel_audio_remote_exec getprop vendor.powerphone.pdm.ready) == 1 ]] || frankel_audio_die 'boot mono capture profile not ready'
[[ $(frankel_audio_remote_exec getprop vendor.powerphone.aoc_speaker_192k.ready) == 1 ]] || frankel_audio_die 'boot speaker profile not ready'
# Transfer before stopping services or touching firmware. A host-side ADB
# transfer failure must not require an otherwise unnecessary firmware revert.
remote_prefix="$FRANKEL_AUDIO_REMOTE_DIRECTORY/frankel-three-mic-${BASHPID}"
frankel_audio_adb push -Z "$stimulus" "${remote_prefix}-stimulus.wav" > "$output_dir/adb-push.txt" 2>&1
patcher=(python3 "$frankel_audio_project_root/tools/audio/patch_frankel_d10_multichannel.py"
  --profile "$profile" --adb "$FRANKEL_AUDIO_ADB"
  --adb-server-port "${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}")
[[ -z ${FRANKEL_AUDIO_SERIAL:-} ]] || patcher+=(--serial "$FRANKEL_AUDIO_SERIAL")
declare -A service_states=()
services_owned=false
delta_attempted=false
delta_applied=false
stream_transaction_started=false
generation_before=
logcat_pid=
read_generation() {
  local value
  value=$(frankel_audio_adb shell 'cat /proc/sys/kernel/random/boot_id && cat /sys/devices/platform/9000000.aoc/restart_count && cat /sys/devices/platform/9000000.aoc/coredump_count') || return 1
  [[ "$value" =~ ^[0-9a-f-]{36}$'\n'[0-9]+$'\n'[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}
require_same_generation() {
  local actual
  actual=$(read_generation) || { echo 'Cannot read complete AoC generation; no further restoration writes.' >&2; return 1; }
  [[ -n "$generation_before" && "$actual" == "$generation_before" ]] || {
    printf 'AoC generation changed; no further restoration writes.\n%s\n' "$actual" >&2
    return 1
  }
}
restore_strict_mono_controls() {
  # An unchanged HD Mic gain write is NOT harmless: it invokes firmware code
  # and affects the coherent dispatch cache line. Only read it here.
  local hd_gain command remote_script='' control value index
  hd_gain=$(frankel_audio_tinymix_get 'HD Mic gain (cB)') || return 1
  [[ "$hd_gain" == 0 ]] || { echo 'HD Mic gain is not the guarded zero value; refusing cleanup.' >&2; return 1; }
  local -a controls=(
    'INTERNAL_MIC_TX Chan' One
    'BUILTIN MIC Process Mode' Raw
    'Audio Capture Mic Source' Builtin_MIC
    'Mic Spatial Module Enable' 0
    'MIC DC Blocker' 0
    'MIC Record Soft Gain (dB)' 0
    'INTERNAL_MIC_TX Sample Rate' SR_192K
    'INTERNAL_MIC_TX Format' S16_LE
  )
  for ((index = 0; index < ${#controls[@]}; index += 2)); do
    control=${controls[index]}; value=${controls[index + 1]}
    command=$(frankel_audio_remote_command /system/bin/tinymix -D 0 -- "$control" "$value") || return 1
    remote_script+="$command >/dev/null || exit 2; "
  done
  command=$(frankel_audio_remote_command /system/bin/tinymix -D 0 -- 'BUILDIN MIC ID CAPTURE LIST' 0 -1 -1 -1) || return 1
  frankel_audio_adb shell "$remote_script $command >/dev/null || exit 2"
}
verify_original_snapshots() {
  local command remote_script='' values actual expected index control
  local -a actual_values=() actual_words=() expected_words=()
  (( ${#FRANKEL_AUDIO_SNAPSHOT_NAMES[@]} )) || return 0
  for control in "${FRANKEL_AUDIO_SNAPSHOT_NAMES[@]}"; do
    command=$(frankel_audio_remote_command /system/bin/tinymix -D 0 -v -- "$control") || return 1
    remote_script+="$command || exit 2; "
  done
  values=$(frankel_audio_adb shell "$remote_script") || return 1
  mapfile -t actual_values <<<"$values"
  (( ${#actual_values[@]} == ${#FRANKEL_AUDIO_SNAPSHOT_NAMES[@]} )) || return 1
  for ((index = 0; index < ${#actual_values[@]}; index++)); do
    actual=${actual_values[index]}; expected=${FRANKEL_AUDIO_SNAPSHOT_VALUES[index]}
    case "$actual" in On) actual=1 ;; Off) actual=0 ;; esac
    if [[ ${FRANKEL_AUDIO_SNAPSHOT_MODES[index]} == vector ]]; then
      read -r -a actual_words <<<"$actual"; read -r -a expected_words <<<"$expected"
      actual=${actual_words[*]}; expected=${expected_words[*]}
    fi
    [[ "$actual" == "$expected" ]] || {
      printf 'Snapshot restoration mismatch: %s expected=%s actual=%s\n' "${FRANKEL_AUDIO_SNAPSHOT_NAMES[index]}" "$expected" "$actual" >&2
      return 1
    }
  done
}
restore_owned_state() {
  local service attempt current command remote_script='' index
  require_same_generation || return 1
  if [[ "$stream_transaction_started" == true ]] && ! rg -q '^owned_streams_closed=1$' "$output_dir/session.txt"; then
    echo 'Owned stream closure was not acknowledged; keep services stopped and reboot.' >&2
    return 1
  fi
  # First silence only known-owned routes. Never restore broad microphone
  # settings into a different or unresponsive firmware generation.
  for ((index = 0; index < ${#FRANKEL_AUDIO_SAFE_NAMES[@]}; index++)); do
    command=$(frankel_audio_remote_command /system/bin/tinymix -D 0 -- "${FRANKEL_AUDIO_SAFE_NAMES[index]}" "${FRANKEL_AUDIO_SAFE_VALUES[index]}") || return 1
    remote_script+="$command >/dev/null || exit 2; "
  done
  if [[ -n "$remote_script" ]]; then
    frankel_audio_adb shell "$remote_script" || return 1
    frankel_audio_verify_safe_controls || return 1
  fi
  if [[ "$delta_applied" == true ]]; then
    "${patcher[@]}" check-multi-bytes > "$output_dir/patch-pre-revert-check.txt" 2>&1 || return 1
    require_same_generation || return 1
    restore_strict_mono_controls || return 1
    "${patcher[@]}" revert > "$output_dir/patch-revert.txt" 2>&1 || return 1
  elif [[ "$delta_attempted" == true ]]; then
    # A failed apply must have restored and verified mono. Do not guess at
    # partially patched bytes or modify controls to conceal an unknown state.
    "${patcher[@]}" check-mono > "$output_dir/patch-recovery-check.txt" 2>&1 || return 1
  elif (( ${#FRANKEL_AUDIO_SNAPSHOT_NAMES[@]} )); then
    "${patcher[@]}" check-mono-bytes > "$output_dir/patch-setup-recovery-check.txt" 2>&1 || return 1
  fi
  require_same_generation || return 1
  [[ $(frankel_audio_remote_exec getprop vendor.powerphone.pdm.ready) == 1 ]] || return 1
  [[ $(frankel_audio_remote_exec getprop vendor.powerphone.aoc_speaker_192k.ready) == 1 ]] || return 1
  frankel_audio_cleanup
  verify_original_snapshots || return 1
  if (( ${#FRANKEL_AUDIO_SAFE_NAMES[@]} )); then frankel_audio_verify_safe_controls || return 1; fi
  require_same_generation || return 1
  for service in vendor.audio-hal-aidl vendor.audio-hal-powerphone audioserver; do
    if [[ ${service_states[$service]} == running ]]; then
      frankel_audio_remote_exec start "$service" || return 1
      current=
      for ((attempt = 0; attempt < 20; attempt++)); do
        current=$(frankel_audio_remote_exec getprop "init.svc.$service") || return 1
        [[ "$current" != running ]] || break
        sleep 0.25
      done
      [[ "$current" == running ]] || { echo "Could not restore running service $service" >&2; return 1; }
    fi
  done
  require_same_generation || return 1
  read_generation > "$output_dir/generation-restored.txt"
}
cleanup() {
  local status=$? restore_status=0
  trap - EXIT HUP INT TERM
  set +e
  if [[ -n "$logcat_pid" ]]; then kill "$logcat_pid" 2>/dev/null; wait "$logcat_pid" 2>/dev/null; fi
  if [[ "$services_owned" == true ]]; then
    restore_owned_state > "$output_dir/cleanup.txt" 2>&1
    restore_status=$?
  fi
  FRANKEL_AUDIO_CLEANUP_ARMED=false
  if (( restore_status != 0 )); then
    echo 'Mono profile restoration failed: audio services remain stopped; reboot the phone.' >&2
    status=2
    # If a later start/read-back failed, do not leave only part of Android's
    # audio stack running. No mixer or firmware writes occur on this path.
    for service in audioserver vendor.audio-hal-powerphone vendor.audio-hal-aidl; do frankel_audio_remote_exec stop "$service" >/dev/null 2>&1; done
  fi
  printf 'script_exit=%s restore_status=%s\n' "$status" "$restore_status" >> "$output_dir/measurement.txt"
  exit "$status"
}
for service in audioserver vendor.audio-hal-powerphone vendor.audio-hal-aidl; do
  service_states[$service]=$(frankel_audio_remote_exec getprop "init.svc.$service")
  [[ ${service_states[$service]} == running || ${service_states[$service]} == stopped ]] || frankel_audio_die "unknown initial state of $service"
done
frankel_audio_arm_cleanup
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-original.txt"
generation_before=$(read_generation) || frankel_audio_die 'cannot read complete initial AoC generation'
printf '%s\n' "$generation_before" > "$output_dir/generation-before.txt"
services_owned=true
for service in audioserver vendor.audio-hal-powerphone vendor.audio-hal-aidl; do frankel_audio_remote_exec stop "$service"; done
for service in audioserver vendor.audio-hal-powerphone vendor.audio-hal-aidl; do
  [[ $(frankel_audio_remote_exec getprop "init.svc.$service") == stopped ]] || frankel_audio_die "$service still active"
done
for control in 'Main AMP Enable Switch' 'R Main AMP Enable Switch' 'TDM_0_RX Mixer EP6' 'EP3 TX Mixer INTERNAL_MIC_TX'; do
  frankel_audio_require_control_zero "$control"
  frankel_audio_register_safe_control "$control" 0
done
for source in EP1 EP2 EP3 EP4 EP5 EP7 EP8 IMSV NoHost1 RAW VOIP US; do
  frankel_audio_require_control_zero "TDM_0_RX Mixer $source"
done
for control in 'EP1 TX Mixer INTERNAL_MIC_TX' 'EP2 TX Mixer INTERNAL_MIC_TX' 'EP5 TX Mixer INTERNAL_MIC_TX' 'EP5 TX Mixer INTERNAL_MIC_US_TX' 'US Record Enable' MIC0 MIC1 MIC2; do
  frankel_audio_require_control_zero "$control"
  frankel_audio_register_safe_control "$control" 0
done
frankel_audio_snapshot_and_set_scalar 'AoC Speaker Mixer ASP Mode' ASP_BYPASS
for suffix in 'Sample Rate' Format Chan nSlot SlotFmt; do
  case "$suffix" in 'Sample Rate') value=SR_192K ;; Format|SlotFmt) value=S32_LE ;; *) value=Two ;; esac
  frankel_audio_snapshot_and_set_scalar "TDM_0_RX $suffix" "$value"
done
for prefix in '' 'R '; do
  frankel_audio_snapshot_and_set_scalar "${prefix}Ultrasonic Mode" Disabled
  for input in 'DSP RX1 Source' 'DSP RX2 Source' 'PCM Source'; do
    frankel_audio_snapshot_and_set_scalar "${prefix}${input}" ASPRX1
  done
  frankel_audio_snapshot_and_set_scalar "${prefix}High Rate PCM Source" Zero
done
# Retain the installed amplifier gain; record it rather than silently normalize it.
frankel_audio_tinymix_get "${speaker_prefix}Amp Gain" > "$output_dir/selected-amp-gain.txt"
frankel_audio_snapshot_and_set_scalar "${speaker_prefix}Digital PCM Volume" 817
frankel_audio_snapshot_and_set_scalar 'BUILTIN MIC Process Mode' Raw
frankel_audio_snapshot_and_set_scalar 'Audio Capture Mic Source' Builtin_MIC
frankel_audio_snapshot_and_set_scalar 'Mic Spatial Module Enable' 0
frankel_audio_snapshot_and_set_scalar 'MIC DC Blocker' 0
frankel_audio_snapshot_and_set_scalar 'MIC Record Soft Gain (dB)' 0
frankel_audio_snapshot_vector 'BUILDIN MIC ID CAPTURE LIST'
frankel_audio_snapshot_and_set_scalar 'INTERNAL_MIC_TX Sample Rate' SR_192K
frankel_audio_snapshot_and_set_scalar 'INTERNAL_MIC_TX Format' S16_LE
frankel_audio_snapshot_and_set_scalar 'INTERNAL_MIC_TX Chan' One
frankel_audio_tinymix_set 'BUILDIN MIC ID CAPTURE LIST' 0 -1 -1 -1
delta_attempted=true
"${patcher[@]}" apply > "$output_dir/patch-apply.txt" 2>&1
delta_applied=true
frankel_audio_tinymix_set 'INTERNAL_MIC_TX Chan' Three
frankel_audio_tinymix_set 'BUILDIN MIC ID CAPTURE LIST' 0 1 2 -1
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-configured.txt"
# Own the external timeout process directly, not a background shell-function
# wrapper whose adb child could survive our cleanup kill.
logger_command=(timeout --signal=TERM "$((duration + 50))" env "ADB_LIBUSB=${FRANKEL_AUDIO_ADB_LIBUSB:-1}" "$FRANKEL_AUDIO_ADB" -P "${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}")
[[ -z ${FRANKEL_AUDIO_SERIAL:-} ]] || logger_command+=(-s "$FRANKEL_AUDIO_SERIAL")
"${logger_command[@]}" shell logcat -v threadtime -T 1 'AOC:*' 'aoc:*' 'aocd:*' '*:S' > "$output_dir/aoc-live.log" 2>&1 &
logcat_pid=$!
capture_command=$(frankel_audio_remote_command /system/bin/chrt -f 3 /system/bin/tinycap "${remote_prefix}-capture.wav" -D 0 -d 10 -c 3 -r 192000 -b 16 -p 1920 -n 4 -T "$duration")
play_command=$(frankel_audio_remote_command /system/bin/chrt -f 90 /vendor/bin/frankel_aoc_staged_play --card 0 --device 5 --rate 192000 --channels 2 --format s32 --period-size 192 --period-count 20 --start-threshold 3840 --rw-efault-retries 32 --rw-efault-sleep-us 1000 --route-control 'TDM_0_RX Mixer EP6' --access rw "${remote_prefix}-stimulus.wav")
hard_off=$(frankel_audio_remote_cleanup_body)
remote_script="
cap_pid=; play_pid=
cleanup() {
  for stream_pid in \$play_pid \$cap_pid; do kill \$stream_pid 2>/dev/null || :; done
  wait 2>/dev/null || :
  echo owned_streams_closed=1
  ${hard_off}
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/system/bin/tinymix -D 0 -- 'EP3 TX Mixer INTERNAL_MIC_TX' 1 || exit 2
date '+capture_begin %s.%N'
${capture_command} > '${remote_prefix}-capture.log' 2>&1 &
cap_pid=\$!
sleep ${lead}
kill -0 \$cap_pid || exit 2
/system/bin/tinymix -D 0 -- 'TDM_0_RX Mixer EP6' 1 || exit 2
/system/bin/tinymix -D 0 -- '${speaker_prefix}Main AMP Enable Switch' 1 || exit 2
date '+playback_begin %s.%N'
${play_command} > '${remote_prefix}-playback.log' 2>&1 &
play_pid=\$!
wait \$play_pid; play_result=\$?; play_pid=
date '+playback_end %s.%N'
wait \$cap_pid; cap_result=\$?; cap_pid=
date '+capture_end %s.%N'
echo playback_status=\$play_result capture_status=\$cap_result
test \$play_result -eq 0 && test \$cap_result -eq 0
"
stream_transaction_started=true
set +e
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=$((duration + 45)) frankel_audio_adb shell "$remote_script" | tee "$output_dir/session.txt"
pipeline_status=("${PIPESTATUS[@]}")
session_status=${pipeline_status[0]}
(( pipeline_status[1] == 0 )) || session_status=2
set -e
if ! kill -0 "$logcat_pid" 2>/dev/null; then
  echo 'Live AoC logger exited before the hardware transaction completed.' >&2
  session_status=2
fi
kill "$logcat_pid" 2>/dev/null || true
wait "$logcat_pid" 2>/dev/null || true
logcat_pid=
for suffix in capture.wav capture.log playback.log; do
  frankel_audio_adb pull "${remote_prefix}-${suffix}" "$output_dir/$suffix" > "$output_dir/pull-${suffix}.txt" 2>&1 || session_status=2
done
# tinycap returns zero even for some PCM-open/read failures. Require the
# complete original PCM payload and intended playback byte count, not merely
# a successful process status or an optimistic WAV header. This is transport
# integrity only; the separate acoustic analyzer must qualify the waveform.
python3 - "$output_dir" "$duration" <<'PY' > "$output_dir/transport-integrity.txt" 2>&1 || session_status=2
import pathlib
import re
import sys
import wave

directory = pathlib.Path(sys.argv[1])
requested_seconds = int(sys.argv[2])
with wave.open(str(directory / "stimulus.wav"), "rb") as stimulus_wav:
    stimulus_frames = stimulus_wav.getnframes()
expected_playback_bytes = ((stimulus_frames + 191) // 192) * 192 * 8
with wave.open(str(directory / "capture.wav"), "rb") as capture:
    geometry = (capture.getframerate(), capture.getnchannels(), capture.getsampwidth())
    frames = capture.getnframes()
    payload_bytes = 0
    while block := capture.readframes(192000):
        payload_bytes += len(block)
if geometry != (192000, 3, 2):
    raise SystemExit(f"FAIL capture geometry: {geometry!r}, expected (192000, 3, 2)")
if payload_bytes != frames * 6:
    raise SystemExit(f"FAIL truncated capture payload: {payload_bytes} bytes for {frames} frames")
seconds = frames / 192000
print(f"capture_rate=192000 channels=3 bits=16 frames={frames} seconds={seconds:.6f} payload_bytes={payload_bytes}")
if not requested_seconds - 0.25 <= seconds <= requested_seconds + 0.25:
    raise SystemExit(f"FAIL capture duration {seconds:.6f} outside requested {requested_seconds}s +/- 0.25s")
playback_log = (directory / "playback.log").read_text()
matches = re.findall(r"^streamed=([0-9]+) bytes xruns=([0-9]+)$", playback_log, re.M)
if matches != [(str(expected_playback_bytes), "0")]:
    raise SystemExit(f"FAIL playback accounting: {matches!r}, expected {expected_playback_bytes} bytes and zero xruns")
session = (directory / "session.txt").read_text()
for marker in ("playback_status=0 capture_status=0", "owned_streams_closed=1"):
    if marker not in session.splitlines():
        raise SystemExit(f"FAIL missing completed-session marker: {marker}")
print(f"playback_bytes={expected_playback_bytes} xruns=0")
print("TRANSPORT_INTEGRITY_PASS acoustic_qualification_not_performed=true")
PY
generation_after=$(read_generation) || session_status=2
printf '%s\n' "$generation_after" > "$output_dir/generation-after.txt"
[[ "$generation_after" == "$generation_before" ]] || session_status=2
frankel_audio_remote_exec dmesg > "$output_dir/dmesg-after.txt" || true
frankel_audio_remote_exec /system/bin/tinymix -D 0 > "$output_dir/mixer-after.txt" || true
printf 'speaker=%s channels=3 logical_mics=0,1,2 rate=192000 format=S16_LE capture_periods=1920x4 capture_seconds=%s lead_seconds=%s session_status=%s\n' "$speaker" "$duration" "$lead" "$session_status" > "$output_dir/measurement.txt"
exit "$session_status"
