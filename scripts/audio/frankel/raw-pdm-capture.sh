#!/usr/bin/env bash
# Shell snippets below are intentionally single-quoted for expansion by the
# remote Android shell, not by this host shell.
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

readonly RAW_PDM_CARD=1
readonly RAW_PDM_RATE=192000
readonly RAW_PDM_CHANNELS=1
readonly RAW_PDM_BITS=32
readonly RAW_PDM_PERIOD_SIZE=19200
readonly RAW_PDM_PERIOD_COUNT=4
readonly RAW_PDM_A32_TIMEOUT_SECONDS=900
readonly RAW_PDM_EXPECTED_VENDOR_BUILD=CP2A.260805.005
readonly RAW_PDM_MODULE_NAME=frankel_pdm_alsa
readonly RAW_PDM_PARAMETER_DIRECTORY=/sys/module/frankel_pdm_alsa/parameters

usage() {
  cat <<'USAGE'
Usage:
  raw-pdm-capture.sh --output WAV --controller PDM0|PDM2|PDM3 \
    --power MIC0|MIC1|MIC2 --ack-hardware-write \
    --ack-ap-permission-trial [options]

Required:
  --output WAV                  Local mono S32_LE/192000 capture destination.
  --controller PDM0|PDM2|PDM3  One physical controller; `all` is not supported.
  --power MIC0|MIC1|MIC2        One independent logical scalar power control.
  --ack-hardware-write          Acknowledge scalar-power and guarded A32 writes.
  --ack-ap-permission-trial     Acknowledge that the first AP FIFO access can
                                fault or hang this experimental device.

Additional safety gate:
  --ack-pdm0-permission-proven  Required for PDM2 or PDM3. It states that the
                                documented single-PDM0 AP trial already passed.

Capture options:
  --duration SECONDS            Whole seconds, 1..30 (default: 5).
  --decimator-order 1|3         CIC order (default: 3).
  --pdm-reverse-bytes 0|1       Consume payload bytes +3,+2,+1 (default: 0).
  --pdm-msb-first 0|1           Consume each payload byte MSB-first (default: 0).
  --pdm-invert 0|1              Invert each PDM bit (default: 0).
  --adb PATH                    adb binary (default: work/toolchains/platform-tools/adb).
  --serial SERIAL               Select one device without printing its identifier.
  --adb-server-port PORT        Existing ADB server port (default: 5038).
  -h, --help                    Show this text without contacting a device.

The physical controller and logical MIC scalar are deliberately independent:
their mapping is not yet known. The script refuses MIC3, the four-element
BUILDIN MIC POWER STATE, BUILDIN_MIC_POWER_INIT, and multi-controller capture.

The reviewed module path is fixed at:
  work/upstream/frankel-gki-15739706/modules/frankel_pdm_alsa.ko

It is loaded with one mask only, polling=0, and the selected calibration
parameters. The fixed tinycap geometry is mono S32_LE/192000, 100 ms periods,
four periods. After A32 apply it first performs one synchronous status-only AP
read, proves exact counter deltas and zero FIFO/data activity, then consumes
that one-shot proof to start destructive polling. On every handled exit the
order is: stop/reap tinycap, stop and
read back polling=0, collect stats/dmesg, guarded A32 revert, scalar power off,
rmmod, then pull/validate any completed WAV. If polling-off or A32 restoration
cannot be proven, dependent cleanup is withheld and the script reports manual
recovery instead of making a more dangerous out-of-order change.
USAGE
}

output=
controller=
power_control=
duration=5
decimator_order=3
pdm_reverse_bytes=0
pdm_msb_first=0
pdm_invert=0
ack_hardware_write=false
ack_ap_permission_trial=false
ack_pdm0_permission_proven=false

while (( $# > 0 )); do
  case "$1" in
    --output|--controller|--power|--duration|--decimator-order|\
    --pdm-reverse-bytes|--pdm-msb-first|--pdm-invert|--adb|--serial|\
    --adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --output) output=$value ;;
        --controller) controller=$value ;;
        --power) power_control=$value ;;
        --duration) duration=$value ;;
        --decimator-order) decimator_order=$value ;;
        --pdm-reverse-bytes) pdm_reverse_bytes=$value ;;
        --pdm-msb-first) pdm_msb_first=$value ;;
        --pdm-invert) pdm_invert=$value ;;
        --adb) FRANKEL_AUDIO_ADB=$value ;;
        --serial) FRANKEL_AUDIO_SERIAL=$value ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$value ;;
      esac
      ;;
    --ack-hardware-write)
      ack_hardware_write=true
      shift
      ;;
    --ack-ap-permission-trial)
      ack_ap_permission_trial=true
      shift
      ;;
    --ack-pdm0-permission-proven)
      ack_pdm0_permission_proven=true
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

[[ -n "$output" ]] || frankel_audio_die '--output is required'
[[ -n "$controller" ]] || frankel_audio_die '--controller is required'
[[ -n "$power_control" ]] || frankel_audio_die '--power is required'
[[ "$ack_hardware_write" == true ]] || \
  frankel_audio_die '--ack-hardware-write is required'
[[ "$ack_ap_permission_trial" == true ]] || \
  frankel_audio_die '--ack-ap-permission-trial is required'

case "$controller" in
  PDM0)
    controller_id=0
    controller_mask=0x1
    ;;
  PDM2)
    controller_id=2
    controller_mask=0x4
    ;;
  PDM3)
    controller_id=3
    controller_mask=0x8
    ;;
  *)
    frankel_audio_die '--controller must be exactly PDM0, PDM2, or PDM3; all is unsupported'
    ;;
esac
if [[ "$controller" != PDM0 && "$ack_pdm0_permission_proven" != true ]]; then
  frankel_audio_die \
    "$controller requires --ack-pdm0-permission-proven after the staged PDM0 trial"
fi

case "$power_control" in
  MIC0|MIC1|MIC2) ;;
  *)
    frankel_audio_die '--power must be exactly MIC0, MIC1, or MIC2; MIC3/vector power is unsafe'
    ;;
esac

frankel_audio_require_positive_integer duration "$duration"
(( duration <= 30 )) || frankel_audio_die 'duration must not exceed 30 seconds'
case "$decimator_order" in
  1|3) ;;
  *) frankel_audio_die '--decimator-order must be 1 or 3' ;;
esac
for boolean_name in pdm_reverse_bytes pdm_msb_first pdm_invert; do
  case "${!boolean_name}" in
    0|1) ;;
    *) frankel_audio_die "--${boolean_name//_/-} must be 0 or 1" ;;
  esac
done

FRANKEL_AUDIO_ADB_SERVER_PORT=${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}
frankel_audio_require_positive_integer adb-server-port "$FRANKEL_AUDIO_ADB_SERVER_PORT"
(( FRANKEL_AUDIO_ADB_SERVER_PORT <= 65535 )) || \
  frankel_audio_die 'ADB server port must not exceed 65535'

for host_utility in grep modinfo python3 realpath tee timeout; do
  command -v "$host_utility" >/dev/null 2>&1 || \
    frankel_audio_die "required host command not found: $host_utility"
done

module_path="$frankel_audio_project_root/work/upstream/frankel-gki-15739706/modules/frankel_pdm_alsa.ko"
a32_helper="$frankel_audio_project_root/tools/audio/frankel_a32_raw_pdm.py"
wav_inspector="$script_directory/generate-signal.py"
[[ -f "$module_path" ]] || frankel_audio_die "reviewed module is missing: $module_path"
[[ -x "$a32_helper" ]] || frankel_audio_die "A32 helper is not executable: $a32_helper"
[[ -x "$wav_inspector" ]] || frankel_audio_die "WAV inspector is not executable: $wav_inspector"
[[ "$(modinfo -F name "$module_path")" == "$RAW_PDM_MODULE_NAME" ]] || \
  frankel_audio_die 'reviewed module has an unexpected internal name'

output=$(realpath -m -- "$output")
output_directory=${output%/*}
[[ "$output_directory" != "$output" ]] || output_directory=.
mkdir -p -- "$output_directory"
case "$output" in
  *.wav) artifact_prefix=${output%.wav} ;;
  *) artifact_prefix=$output ;;
esac
partial_output="${output}.partial-${BASHPID}"
failed_output="${output}.failed-capture-${BASHPID}.wav"
stats_path="${artifact_prefix}.raw-pdm-stats.txt"
status_probe_path="${artifact_prefix}.raw-pdm-status-probe.txt"
dmesg_path="${artifact_prefix}.raw-pdm-dmesg.txt"
tinycap_log_path="${artifact_prefix}.raw-pdm-tinycap.txt"
a32_log_path="${artifact_prefix}.raw-pdm-a32.txt"
a32_snapshot_path="${artifact_prefix}.raw-pdm-a32.json"

for local_path in "$output" "$partial_output" "$stats_path" \
  "$status_probe_path" "$dmesg_path" \
  "$tinycap_log_path" "$a32_log_path" "$a32_snapshot_path"; do
  [[ ! -e "$local_path" ]] || \
    frankel_audio_die "refusing to overwrite an existing trial artifact: $local_path"
done

remote_tag="frankel-raw-pdm-${BASHPID}"
remote_module="$FRANKEL_AUDIO_REMOTE_DIRECTORY/${remote_tag}.ko"
remote_output="$FRANKEL_AUDIO_REMOTE_DIRECTORY/${remote_tag}.wav"
remote_capture_pid="$FRANKEL_AUDIO_REMOTE_DIRECTORY/${remote_tag}.tinycap.pid"

cleanup_armed=false
cleanup_running=false
cleanup_complete=false
power_may_be_on=false
capture_may_be_running=false
diagnostics_collected=false

raw_pdm_note_error() {
  printf 'cleanup error: %s\n' "$*" >&2
}

raw_pdm_read_module_parameter() {
  frankel_audio_remote_exec /system/bin/cat \
    "$RAW_PDM_PARAMETER_DIRECTORY/$1"
}

raw_pdm_normalize_boolean() {
  case "$1" in
    1|Y|y|yes|true) printf '1\n' ;;
    0|N|n|no|false) printf '0\n' ;;
    *) return 1 ;;
  esac
}

raw_pdm_require_boolean_parameter() {
  local name=$1
  local expected=$2
  local actual normalized
  actual=$(raw_pdm_read_module_parameter "$name") || \
    frankel_audio_die "cannot read module parameter $name"
  normalized=$(raw_pdm_normalize_boolean "$actual") || \
    frankel_audio_die "module parameter $name has an invalid Boolean value: $actual"
  [[ "$normalized" == "$expected" ]] || \
    frankel_audio_die "module parameter $name: expected $expected, got $actual"
}

raw_pdm_require_integer_parameter() {
  local name=$1
  local expected=$2
  local actual
  actual=$(raw_pdm_read_module_parameter "$name") || \
    frankel_audio_die "cannot read module parameter $name"
  [[ "$actual" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || \
    frankel_audio_die "module parameter $name is not an integer: $actual"
  (( actual == expected )) || \
    frankel_audio_die "module parameter $name: expected $expected, got $actual"
}

raw_pdm_power_is_off() {
  local value
  value=$(frankel_audio_tinymix_get "$1") || return 1
  [[ "$value" == 0 || "$value" == Off ]]
}

raw_pdm_power_is_on() {
  local value
  value=$(frankel_audio_tinymix_get "$1") || return 1
  [[ "$value" == 1 || "$value" == On ]]
}

raw_pdm_selected_pcm_is_closed() {
  local device_path status_path status owners
  device_path="/dev/snd/pcmC1D${controller_id}c"
  status_path="/proc/asound/card1/pcm${controller_id}c/sub0/status"
  if ! frankel_audio_remote_exec /system/bin/test -d \
      "/sys/module/$RAW_PDM_MODULE_NAME" >/dev/null 2>&1; then
    return 0
  fi
  frankel_audio_remote_exec /system/bin/test -c "$device_path" || return 1
  if frankel_audio_remote_exec /system/bin/test -f "$status_path"; then
    status=$(frankel_audio_remote_exec /system/bin/cat "$status_path") || return 1
    [[ "$status" == closed ]] || return 1
  fi
  # Frankel does not materialize card-1 substream status files while closed.
  # Root lsof on the exact character node is authoritative in that case and
  # also rejects an owner if a status file happens to report stale data.
  owners=$(frankel_audio_remote_exec /system/bin/lsof "$device_path") || return 1
  [[ -z "$owners" ]]
}

raw_pdm_write_boolean_parameter() {
  local name=$1
  local value=$2
  case "$name" in
    polling_enabled|status_probe) ;;
    *) frankel_audio_die "unsupported writable module parameter: $name" ;;
  esac
  case "$value" in
    0|1) ;;
    *) frankel_audio_die "module parameter write is not Boolean: $value" ;;
  esac
  # The name and value are closed allowlists and the directory is constant.
  # Send one complete adb-shell program so redirection is performed remotely;
  # passing sh -c through remote_exec would split its script argument.
  frankel_audio_adb shell \
    "/system/bin/echo $value > $RAW_PDM_PARAMETER_DIRECTORY/$name"
}

raw_pdm_snapshot_status() {
  [[ -f "$a32_snapshot_path" ]] || {
    printf 'absent\n'
    return 0
  }
  python3 - "$a32_snapshot_path" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    document = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    print(f"invalid:{error}")
else:
    print(document.get("status", "missing"))
PY
}

raw_pdm_a32() {
  local operation=$1
  shift
  local -a command=(
    timeout --signal=TERM "$RAW_PDM_A32_TIMEOUT_SECONDS"
    python3 "$a32_helper" "$operation"
    --controllers "$controller_id"
    --snapshot "$a32_snapshot_path"
    --adb "$FRANKEL_AUDIO_ADB"
    --adb-server-port "$FRANKEL_AUDIO_ADB_SERVER_PORT"
  )
  if [[ -n ${FRANKEL_AUDIO_SERIAL:-} ]]; then
    command+=(--serial "$FRANKEL_AUDIO_SERIAL")
  fi
  command+=("$@")
  frankel_audio_note "A32 $operation for $controller"
  "${command[@]}" 2>&1 | tee -a "$a32_log_path"
}

raw_pdm_stop_capture() {
  local quoted_pid quoted_output stop_script
  [[ "$capture_may_be_running" == true ]] || return 0
  quoted_pid=$(frankel_audio_remote_quote "$remote_capture_pid")
  quoted_output=$(frankel_audio_remote_quote "$remote_output")
  stop_script="pid_file=$quoted_pid; expected_output=$quoted_output; "
  stop_script+='if [ -f "$pid_file" ]; then '
  stop_script+='pid=$(/system/bin/cat "$pid_file" 2>/dev/null); '
  stop_script+='case "$pid" in ""|*[!0-9]*) exit 70;; esac; '
  stop_script+='if /system/bin/test -d "/proc/$pid"; then '
  stop_script+='cmdline=$(/system/bin/tr "\000" " " < "/proc/$pid/cmdline" 2>/dev/null); '
  stop_script+='case "$cmdline" in *"$expected_output"*) ;; *) exit 71;; esac; '
  stop_script+='/system/bin/kill -TERM "$pid" 2>/dev/null || :; attempt=0; '
  stop_script+='while /system/bin/kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do '
  stop_script+='/system/bin/sleep 0.05; attempt=$((attempt + 1)); done; '
  stop_script+='if /system/bin/kill -0 "$pid" 2>/dev/null; then '
  stop_script+='/system/bin/kill -KILL "$pid" 2>/dev/null || :; /system/bin/sleep 0.1; fi; '
  stop_script+='if /system/bin/kill -0 "$pid" 2>/dev/null; then exit 72; fi; fi; '
  stop_script+='/system/bin/rm -f "$pid_file"; fi'
  if ! FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=15 \
      frankel_audio_adb shell "$stop_script" >/dev/null 2>&1; then
    raw_pdm_note_error 'could not prove that the tracked tinycap process stopped'
    return 1
  fi
  if ! raw_pdm_selected_pcm_is_closed; then
    raw_pdm_note_error \
      "card1 PDM${controller_id} capture is not closed after the stop attempt"
    return 1
  fi
  capture_may_be_running=false
  return 0
}

raw_pdm_stop_polling() {
  local actual
  if ! frankel_audio_remote_exec /system/bin/test -d \
      "/sys/module/$RAW_PDM_MODULE_NAME" >/dev/null 2>&1; then
    return 0
  fi
  if ! raw_pdm_write_boolean_parameter polling_enabled 0 >/dev/null; then
    raw_pdm_note_error 'synchronous polling-off write failed'
    return 1
  fi
  actual=$(raw_pdm_read_module_parameter polling_enabled 2>/dev/null) || {
    raw_pdm_note_error 'cannot read polling_enabled after the stop write'
    return 1
  }
  [[ "$actual" == 0 ]] || {
    raw_pdm_note_error "polling_enabled remains $actual; refusing A32 revert"
    return 1
  }
  return 0
}

raw_pdm_run_status_probe() {
  raw_pdm_require_boolean_parameter polling_enabled 0
  raw_pdm_require_boolean_parameter status_probe 0
  frankel_audio_note \
    'performing one synchronous AP FIFO-status permission probe (no FIFO pop)'
  raw_pdm_write_boolean_parameter status_probe 1
  raw_pdm_require_boolean_parameter status_probe 1
  raw_pdm_require_boolean_parameter polling_enabled 0
  raw_pdm_read_module_parameter stats >"$status_probe_path"
  python3 - "$status_probe_path" "$controller_id" <<'PY'
import pathlib
import re
import sys

pattern = re.compile(
    r"^pdm(?P<pdm>\d+) status=(?P<status>\d+) "
    r"probe_reads=(?P<probe_reads>\d+) empty=(?P<empty>\d+) "
    r"words=(?P<words>\d+) bits=(?P<bits>\d+) frames=(?P<frames>\d+) "
    r"delivered=(?P<delivered>\d+) discarded=(?P<discarded>\d+) "
    r"periods=(?P<periods>\d+) overruns=(?P<overruns>\d+) "
    r"clips=(?P<clips>\d+) last_status=0x(?P<last_status>[0-9a-fA-F]{8})$"
)
stats = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    match = pattern.fullmatch(line)
    if match is None:
        raise SystemExit(f"malformed raw-PDM stats: {line!r}")
    stats[int(match.group("pdm"))] = {
        name: int(value, 16 if name == "last_status" else 10)
        for name, value in match.groupdict().items()
        if name != "pdm"
    }
if set(stats) != {0, 2, 3}:
    raise SystemExit(f"unexpected PDM stats set: {sorted(stats)}")
selected = int(sys.argv[2])
data_fields = (
    "words",
    "bits",
    "frames",
    "delivered",
    "discarded",
    "periods",
    "overruns",
    "clips",
)
for pdm, fields in stats.items():
    expected_probe = 1 if pdm == selected else 0
    if fields["status"] != expected_probe or fields["probe_reads"] != expected_probe:
        raise SystemExit(
            f"PDM{pdm} status/probe counts are "
            f"{fields['status']}/{fields['probe_reads']}, expected {expected_probe}/{expected_probe}"
        )
    if fields["empty"] not in ({0, 1} if pdm == selected else {0}):
        raise SystemExit(f"PDM{pdm} empty count is invalid: {fields['empty']}")
    for field in data_fields:
        if fields[field] != 0:
            raise SystemExit(f"PDM{pdm} destructive/data counter {field} is nonzero")
    if pdm != selected and fields["last_status"] != 0:
        raise SystemExit(f"unselected PDM{pdm} last_status changed")
print("status-only proof: selected status/probe counts=1; every FIFO/data counter=0")
PY
}

raw_pdm_collect_diagnostics() {
  [[ "$diagnostics_collected" == false ]] || return 0
  local status=0
  if frankel_audio_remote_exec /system/bin/test -d \
      "/sys/module/$RAW_PDM_MODULE_NAME" >/dev/null 2>&1; then
    if ! raw_pdm_read_module_parameter stats >"$stats_path"; then
      raw_pdm_note_error "could not collect module stats at $stats_path"
      status=1
    fi
  else
    printf 'module was not loaded when cleanup collected diagnostics\n' \
      >"$stats_path"
  fi
  if ! frankel_audio_remote_exec /system/bin/dmesg >"$dmesg_path"; then
    raw_pdm_note_error "could not collect dmesg at $dmesg_path"
    status=1
  fi
  diagnostics_collected=true
  return "$status"
}

raw_pdm_revert_a32() {
  local snapshot_status
  snapshot_status=$(raw_pdm_snapshot_status)
  case "$snapshot_status" in
    absent|rolled_back|reverted)
      return 0
      ;;
    active)
      if ! raw_pdm_a32 revert --ack-hardware-write --ack-polling-stopped; then
        raw_pdm_note_error 'guarded A32 revert failed'
        return 1
      fi
      [[ "$(raw_pdm_snapshot_status)" == reverted ]] || {
        raw_pdm_note_error 'A32 helper returned without a reverted snapshot'
        return 1
      }
      return 0
      ;;
    prepared|applying|rollback_failed|revert_failed|invalid:*|missing)
      raw_pdm_note_error \
        "A32 snapshot is $snapshot_status; refusing dependent power/module cleanup"
      return 1
      ;;
    *)
      raw_pdm_note_error "unrecognized A32 snapshot status: $snapshot_status"
      return 1
      ;;
  esac
}

raw_pdm_power_off() {
  [[ "$power_may_be_on" == true ]] || return 0
  if ! frankel_audio_tinymix_set "$power_control" 0; then
    raw_pdm_note_error "failed to turn off scalar $power_control"
    return 1
  fi
  if ! raw_pdm_power_is_off "$power_control"; then
    raw_pdm_note_error "scalar $power_control did not read back off"
    return 1
  fi
  power_may_be_on=false
  return 0
}

raw_pdm_unload_module() {
  if ! frankel_audio_remote_exec /system/bin/test -d \
      "/sys/module/$RAW_PDM_MODULE_NAME" >/dev/null 2>&1; then
    return 0
  fi
  if ! frankel_audio_remote_exec /system/bin/rmmod "$RAW_PDM_MODULE_NAME"; then
    raw_pdm_note_error "rmmod $RAW_PDM_MODULE_NAME failed"
    return 1
  fi
  if frankel_audio_remote_exec /system/bin/test -d \
      "/sys/module/$RAW_PDM_MODULE_NAME" >/dev/null 2>&1; then
    raw_pdm_note_error "$RAW_PDM_MODULE_NAME remains loaded after rmmod"
    return 1
  fi
  return 0
}

raw_pdm_cleanup_core() {
  [[ "$cleanup_complete" == false ]] || return 0
  [[ "$cleanup_running" == false ]] || return 1
  cleanup_running=true
  set +e
  local status=0
  local capture_status=0

  raw_pdm_stop_capture || capture_status=1
  if ! raw_pdm_stop_polling; then
    status=1
    raw_pdm_collect_diagnostics || status=1
    raw_pdm_note_error \
      'polling-off is unproven; A32 ownership, power, and module state were left intact'
    cleanup_running=false
    set -e
    return "$status"
  fi
  raw_pdm_collect_diagnostics || status=1
  if (( capture_status != 0 )); then
    raw_pdm_note_error \
      'tinycap stop/reap is unproven; A32 ownership, power, and module state were left intact after polling-off'
    cleanup_running=false
    set -e
    return 1
  fi
  if ! raw_pdm_revert_a32; then
    status=1
    raw_pdm_note_error \
      'A32 idle restoration is unproven; scalar power and module state were left intact'
    cleanup_running=false
    set -e
    return "$status"
  fi
  if ! raw_pdm_power_off; then
    status=1
    raw_pdm_note_error \
      'scalar power-off is unproven; the raw module was left loaded'
    cleanup_running=false
    set -e
    return "$status"
  fi
  raw_pdm_unload_module || status=1
  if (( status == 0 )); then
    cleanup_complete=true
  fi
  cleanup_running=false
  set -e
  return "$status"
}

raw_pdm_remove_remote_files() {
  frankel_audio_remote_exec /system/bin/rm -f \
    "$remote_capture_pid" "$remote_output" "$remote_module" \
    >/dev/null 2>&1 || true
}

raw_pdm_preserve_failed_capture() {
  [[ ! -e "$failed_output" ]] || return 0
  if frankel_audio_remote_exec /system/bin/test -s "$remote_output" \
      >/dev/null 2>&1; then
    if frankel_audio_adb pull "$remote_output" "$failed_output" >/dev/null 2>&1; then
      "$wav_inspector" inspect "$failed_output" \
        --expect-rate "$RAW_PDM_RATE" \
        --expect-channels "$RAW_PDM_CHANNELS" \
        --expect-bits "$RAW_PDM_BITS" >/dev/null 2>&1 || true
      printf 'diagnostic: preserved failed capture at %s\n' "$failed_output" >&2
    fi
  fi
}

# shellcheck disable=SC2317
raw_pdm_exit_handler() {
  local status=$?
  local cleanup_status=0
  trap - EXIT HUP INT TERM
  set +e
  if [[ "$cleanup_armed" == true ]]; then
    raw_pdm_cleanup_core || cleanup_status=$?
    if [[ "$cleanup_complete" == true ]]; then
      raw_pdm_preserve_failed_capture
      raw_pdm_remove_remote_files
    fi
  fi
  rm -f -- "$partial_output" >/dev/null 2>&1 || true
  if (( status == 0 && cleanup_status != 0 )); then
    status=$cleanup_status
  fi
  exit "$status"
}

frankel_audio_initialize_device tinycap insmod rmmod dmesg lsof

vendor_build=$(frankel_audio_remote_exec getprop ro.vendor.build.id)
[[ "$vendor_build" == "$RAW_PDM_EXPECTED_VENDOR_BUILD" ]] || \
  frankel_audio_die \
    "refusing unreviewed vendor build (expected $RAW_PDM_EXPECTED_VENDOR_BUILD, got $vendor_build)"
build_type=$(frankel_audio_remote_exec getprop ro.build.type)
[[ "$build_type" == userdebug ]] || \
  frankel_audio_die "Frankel userdebug is required (ro.build.type=$build_type)"
kernel_release=$(frankel_audio_remote_exec uname -r)
module_vermagic=$(modinfo -F vermagic "$module_path")
module_release=${module_vermagic%% *}
[[ "$kernel_release" == "$module_release" ]] || \
  frankel_audio_die \
    "module/running kernel mismatch (module=$module_release, running=$kernel_release)"

card0_id=$(frankel_audio_remote_exec /system/bin/cat /proc/asound/card0/id)
[[ -n "$card0_id" && "$card0_id" != FrankelPDM ]] || \
  frankel_audio_die "AoC card0 is not ready (id=$card0_id)"
frankel_audio_remote_exec /system/bin/test ! -e /proc/asound/card1 || \
  frankel_audio_die 'ALSA card1 is already occupied'
frankel_audio_remote_exec /system/bin/test ! -d "/sys/module/$RAW_PDM_MODULE_NAME" || \
  frankel_audio_die "$RAW_PDM_MODULE_NAME is already loaded"
for microphone in MIC0 MIC1 MIC2; do
  raw_pdm_power_is_off "$microphone" || \
    frankel_audio_die "$microphone is already powered; restore all three scalar controls first"
done

printf 'trial: controller=%s device=%s mask=%s logical_power=%s\n' \
  "$controller" "$controller_id" "$controller_mask" "$power_control"
printf 'trial: mono S32_LE/%s periods=%sx%s duration=%ss\n' \
  "$RAW_PDM_RATE" "$RAW_PDM_PERIOD_SIZE" "$RAW_PDM_PERIOD_COUNT" "$duration"
printf 'trial: decimator_order=%s reverse_bytes=%s msb_first=%s invert=%s\n' \
  "$decimator_order" "$pdm_reverse_bytes" "$pdm_msb_first" "$pdm_invert"
printf 'trial: card0_id=%s kernel=%s vendor_build=%s\n' \
  "$card0_id" "$kernel_release" "$vendor_build"

cleanup_armed=true
trap raw_pdm_exit_handler EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

frankel_audio_note "pushing reviewed $RAW_PDM_MODULE_NAME module"
frankel_audio_adb push "$module_path" "$remote_module" >/dev/null

frankel_audio_note "loading $controller mapping with polling disabled"
frankel_audio_remote_exec /system/bin/insmod "$remote_module" \
  map_controllers=1 projection_ack=0x0ac0a000 \
  "controller_mask=$controller_mask" "decimator_order=$decimator_order" \
  "pdm_reverse_bytes=$pdm_reverse_bytes" "pdm_msb_first=$pdm_msb_first" \
  "pdm_invert=$pdm_invert"

[[ "$(frankel_audio_remote_exec /system/bin/cat /proc/asound/card1/id)" == FrankelPDM ]] || \
  frankel_audio_die 'raw module did not register ALSA card1 as FrankelPDM'
frankel_audio_remote_exec /system/bin/test -c \
  "/dev/snd/pcmC${RAW_PDM_CARD}D${controller_id}c" || \
  frankel_audio_die "selected capture node pcmC1D${controller_id}c is missing"
raw_pdm_selected_pcm_is_closed || \
  frankel_audio_die "selected PDM${controller_id} PCM is not closed before A32 apply"
raw_pdm_require_boolean_parameter map_controllers 1
raw_pdm_require_integer_parameter projection_ack 0x0ac0a000
raw_pdm_require_integer_parameter controller_mask "$controller_mask"
raw_pdm_require_integer_parameter decimator_order "$decimator_order"
raw_pdm_require_boolean_parameter pdm_reverse_bytes "$pdm_reverse_bytes"
raw_pdm_require_boolean_parameter pdm_msb_first "$pdm_msb_first"
raw_pdm_require_boolean_parameter pdm_invert "$pdm_invert"
raw_pdm_require_boolean_parameter status_probe 0
raw_pdm_require_boolean_parameter polling_enabled 0

power_may_be_on=true
frankel_audio_note "powering independent logical scalar $power_control"
frankel_audio_tinymix_set "$power_control" 1
raw_pdm_power_is_on "$power_control" || \
  frankel_audio_die "$power_control did not read back on"
for microphone in MIC0 MIC1 MIC2; do
  if [[ "$microphone" != "$power_control" ]]; then
    raw_pdm_power_is_off "$microphone" || \
      frankel_audio_die "unselected scalar $microphone changed state"
  fi
done

# The write-capable apply performs the authoritative idle/ownership snapshot
# after the module is loaded and the selected scalar rail is powered.  Avoid
# two duplicate full factory-diag sweeps on this intentionally direct path.
raw_pdm_a32 apply --ack-hardware-write --ack-ap-consumer-ready \
  --skip-reset-pulse
raw_pdm_run_status_probe || \
  frankel_audio_die 'synchronous AP status-only permission probe failed'
raw_pdm_a32 check-active

frankel_audio_note \
  'enabling AP FIFO polling after the guarded A32 apply and status-only proof'
raw_pdm_write_boolean_parameter polling_enabled 1
raw_pdm_require_boolean_parameter polling_enabled 1
raw_pdm_require_boolean_parameter status_probe 0

capture_command=$(frankel_audio_remote_command /system/bin/tinycap \
  "$remote_output" -D "$RAW_PDM_CARD" -d "$controller_id" \
  -c "$RAW_PDM_CHANNELS" -r "$RAW_PDM_RATE" -b "$RAW_PDM_BITS" \
  -p "$RAW_PDM_PERIOD_SIZE" -n "$RAW_PDM_PERIOD_COUNT" -T "$duration")
quoted_capture_pid=$(frankel_audio_remote_quote "$remote_capture_pid")
capture_script='capture_pid=""; '
capture_script+='stop_capture() { status=$1; if [ -n "$capture_pid" ]; then '
capture_script+='/system/bin/kill -TERM "$capture_pid" 2>/dev/null || :; '
capture_script+='wait "$capture_pid" 2>/dev/null || :; fi; '
capture_script+="/system/bin/rm -f $quoted_capture_pid; exit \"\$status\"; }; "
capture_script+="trap 'stop_capture 129' HUP; trap 'stop_capture 130' INT; trap 'stop_capture 143' TERM; "
capture_script+="$capture_command & capture_pid=\$!; "
capture_script+="printf '%s\\n' \"\$capture_pid\" > $quoted_capture_pid; "
capture_script+='wait "$capture_pid"; status=$?; capture_pid=""; '
capture_script+="/system/bin/rm -f $quoted_capture_pid; exit \"\$status\""

capture_may_be_running=true
frankel_audio_note \
  "capturing card 1,${controller_id}: $controller with logical $power_control"
set +e
FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=$((duration + 30)) \
  frankel_audio_adb shell "$capture_script" \
  >"$tinycap_log_path" 2>&1
capture_status=$?
set -e
cat -- "$tinycap_log_path"
(( capture_status == 0 )) || \
  frankel_audio_die "tinycap/ADB exited with status $capture_status"
if grep -Eiq 'unable|error|not[[:space:]]+supported|overrun|xrun' \
    "$tinycap_log_path"; then
  frankel_audio_die 'tinycap reported a PCM error or overrun'
fi

# Normal completion uses the same mandatory core cleanup as the failure trap.
raw_pdm_cleanup_core || \
  frankel_audio_die 'mandatory cleanup is incomplete; inspect cleanup errors before recovery'

frankel_audio_note 'pulling capture only after A32 revert, scalar-off, and rmmod'
frankel_audio_adb pull "$remote_output" "$partial_output" >/dev/null
inspection_output=$("$wav_inspector" inspect "$partial_output" \
  --expect-rate "$RAW_PDM_RATE" \
  --expect-channels "$RAW_PDM_CHANNELS" \
  --expect-bits "$RAW_PDM_BITS")
printf '%s\n' "$inspection_output"
[[ "$inspection_output" =~ frames=([0-9]+) ]] || \
  frankel_audio_die 'WAV inspection did not report a frame count'
captured_frames=${BASH_REMATCH[1]}
expected_frames=$((RAW_PDM_RATE * duration))
maximum_frames=$((expected_frames + RAW_PDM_PERIOD_SIZE * RAW_PDM_PERIOD_COUNT))
if (( captured_frames < expected_frames || captured_frames > maximum_frames )); then
  mv -- "$partial_output" "$failed_output"
  frankel_audio_die \
    "captured $captured_frames frames; expected $expected_frames..$maximum_frames (preserved at $failed_output)"
fi

selected_stats=$(grep -E "^pdm${controller_id}[[:space:]]" "$stats_path") || \
  frankel_audio_die "stats do not contain selected PDM${controller_id}"
[[ "$selected_stats" =~ words=([0-9]+) ]] || \
  frankel_audio_die 'selected stats do not report FIFO words'
fifo_words=${BASH_REMATCH[1]}
(( fifo_words > 0 )) || frankel_audio_die 'selected controller produced no FIFO words'
[[ "$selected_stats" =~ delivered=([0-9]+) ]] || \
  frankel_audio_die 'selected stats do not report delivered frames'
delivered_frames=${BASH_REMATCH[1]}
(( delivered_frames >= expected_frames )) || \
  frankel_audio_die \
    "selected controller delivered only $delivered_frames frames; expected at least $expected_frames"
[[ "$selected_stats" =~ overruns=([0-9]+) ]] || \
  frankel_audio_die 'selected stats do not report overruns'
(( BASH_REMATCH[1] == 0 )) || \
  frankel_audio_die "ALSA/module stats report ${BASH_REMATCH[1]} overrun(s)"

mv -- "$partial_output" "$output"
raw_pdm_remove_remote_files
cleanup_armed=false
trap - EXIT HUP INT TERM

frankel_audio_note "capture saved to $output"
frankel_audio_note "stats: $stats_path"
frankel_audio_note "dmesg: $dmesg_path"
frankel_audio_note "A32 audit snapshot: $a32_snapshot_path"
frankel_audio_note \
  "$power_control is off, A32 is reverted, polling is off, and $RAW_PDM_MODULE_NAME is unloaded"
