#!/usr/bin/env bash
# Host-side, boot-volatile activation broker for the integrated Frankel
# PowerPhone research image. Nothing in this file runs automatically at boot.
# Remote Android-shell snippets and the awk program are intentionally quoted
# against host expansion.
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

readonly POWERPHONE_EXPECTED_DEVICE=frankel
readonly POWERPHONE_EXPECTED_BUILD_ID=CP2A.260805.005
readonly POWERPHONE_EXPECTED_INCREMENTAL=pixel_aosp17_r1
readonly POWERPHONE_EXPECTED_RELEASE=17
readonly POWERPHONE_EXPECTED_SDK=37
readonly POWERPHONE_EXPECTED_PRODUCT_FINGERPRINT='google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys'
readonly POWERPHONE_EXPECTED_SYSTEM_FINGERPRINT='Android/generic_system/generic:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys'
readonly POWERPHONE_EXPECTED_KERNEL='6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k'
readonly POWERPHONE_EXPECTED_CARD0=googleaocsndcar
readonly POWERPHONE_EXPECTED_CARD1=FrankelPDM
readonly POWERPHONE_MODULE=frankel_pdm_alsa
readonly POWERPHONE_MODULE_PATH=/vendor_dlkm/lib/modules/frankel_pdm_alsa.ko
readonly POWERPHONE_PARAMETER_DIRECTORY=/sys/module/frankel_pdm_alsa/parameters
readonly POWERPHONE_TOPOLOGY_PROPERTY=vendor.powerphone.pdm.topology_ready
readonly POWERPHONE_PDM_PROPERTY=vendor.powerphone.pdm.ready
readonly POWERPHONE_SPEAKER_PROPERTY=vendor.powerphone.aoc_speaker_192k.ready
readonly POWERPHONE_SPEAKER_GUARD=/data/local/tmp/frankel_aoc_speaker_patch
readonly POWERPHONE_LOADER_SERVICE=vendor.powerphone-pdm-loader
readonly POWERPHONE_HAL_SERVICE=vendor.audio-hal-powerphone
readonly POWERPHONE_A32_CONTROLLERS=0,2,3
readonly POWERPHONE_PCM_CLOSE_WAIT_SECONDS=10
readonly -a POWERPHONE_MIC_CONTROLS=(MIC0 MIC1 MIC2)

usage() {
  cat <<'USAGE'
Usage:
  powerphone-runtime.sh ACTION --output-dir DIRECTORY [options]

Read-only actions:
  status                 Check PDM and speaker independently; report both.
  pdm-status             Check only the integrated raw-PDM path.
  speaker-status         Check only the speaker gate and transient native
                         PCM ownership guard; do not inspect AoC memory.

Mutating actions (also require --ack-hardware-write):
  pdm-activate           Journal/power MIC0/MIC1/MIC2, apply PDM0/PDM2/PDM3,
                         prove status-only AP access, then enable data polling.
  pdm-deactivate         Set ready=0 first, prove all card-1 PCMs closed,
                         stop polling, revert A32, then power all mic rails off.
  speaker-activate       Fail closed: integrated speaker certification is not
                         qualified; use the native-only manual runbook.
  speaker-deactivate     Clear speaker-ready, use the transient native guard
                         to prove PCM 0,28 closed, then fail closed without
                         changing AoC memory.

Required:
  --output-dir DIRECTORY  Explicit host audit directory. Reuse the same
                          directory to deactivate a PDM activation because it
                          contains the guarded A32 snapshot.

Options:
  --ack-hardware-write    Required for every activate/deactivate action.
  --adb PATH              adb binary (default: work/toolchains/platform-tools/adb).
  --serial SERIAL         Select one ADB device without logging its identifier.
  --adb-server-port PORT  Existing ADB server port (default: 5038).
  --aoc-counter INTEGER   Optional AoC diagnostic transaction counter.
  -h, --help              Show this help without contacting a device.

The script is locked to the reviewed Frankel AOSP 17 userdebug/vendor/kernel
combination. It calls `adb root`, then uses `su 0` for property-service,
sysfs, and AoC operations so writes run in the userdebug-only `su` SELinux
domain. Every property write is read back. No action enables either path at
boot, and a successful transaction is not acoustic/Nyquist hardware proof.
USAGE
}

action=${1:-}
if [[ "$action" == -h || "$action" == --help ]]; then
  usage
  exit 0
fi
[[ -n "$action" ]] || {
  usage >&2
  exit 64
}
shift

case "$action" in
  status|pdm-status|speaker-status|pdm-activate|pdm-deactivate|\
  speaker-activate|speaker-deactivate) ;;
  *)
    printf 'error: unknown action: %s\n' "$action" >&2
    usage >&2
    exit 64
    ;;
esac

output_directory=
ack_hardware_write=false
aoc_counter=
FRANKEL_AUDIO_ADB_SERVER_PORT=5038

while (( $# > 0 )); do
  case "$1" in
    --output-dir|--adb|--serial|--adb-server-port|--aoc-counter)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --output-dir) output_directory=$value ;;
        --adb) FRANKEL_AUDIO_ADB=$value ;;
        --serial) FRANKEL_AUDIO_SERIAL=$value ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$value ;;
        --aoc-counter) aoc_counter=$value ;;
      esac
      ;;
    --ack-hardware-write)
      ack_hardware_write=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) frankel_audio_die "unknown argument: $1 (use --help)" ;;
  esac
done

[[ -n "$output_directory" ]] || frankel_audio_die '--output-dir is required'
frankel_audio_require_positive_integer adb-server-port \
  "$FRANKEL_AUDIO_ADB_SERVER_PORT"
(( FRANKEL_AUDIO_ADB_SERVER_PORT <= 65535 )) || \
  frankel_audio_die 'ADB server port must not exceed 65535'
if [[ -n "$aoc_counter" ]]; then
  [[ "$aoc_counter" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || \
    frankel_audio_die "aoc-counter is not an integer: $aoc_counter"
fi
case "$action" in
  *-activate|*-deactivate)
    [[ "$ack_hardware_write" == true ]] || \
      frankel_audio_die "$action requires --ack-hardware-write"
    ;;
esac

for host_utility in flock python3 realpath sleep sort tee timeout; do
  command -v "$host_utility" >/dev/null 2>&1 || \
    frankel_audio_die "required host command not found: $host_utility"
done

a32_helper="$frankel_audio_project_root/tools/audio/frankel_a32_raw_pdm.py"
[[ -x "$a32_helper" ]] || frankel_audio_die "A32 helper is not executable: $a32_helper"

output_directory=$(realpath -m -- "$output_directory")
global_lock_directory="$frankel_audio_project_root/work/audio-research/frankel"
mkdir -p -- "$global_lock_directory"
exec 8>"$global_lock_directory/.powerphone-runtime.global.lock"
flock -n 8 || frankel_audio_die \
  'another PowerPhone runtime operation is active in this checkout'
mkdir -p -- "$output_directory/runs"
exec 9>"$output_directory/.powerphone-runtime.lock"
flock -n 9 || frankel_audio_die \
  "another PowerPhone runtime operation owns $output_directory"

run_timestamp=$(date -u +%Y%m%dT%H%M%SZ)
run_directory="$output_directory/runs/${run_timestamp}-${action}-${BASHPID}"
[[ ! -e "$run_directory" ]] || \
  frankel_audio_die "refusing to reuse audit run directory: $run_directory"
mkdir -p -- "$run_directory"
run_log="$run_directory/transaction.log"
exec 3>&1 4>&2
exec > >(tee -a "$run_log") 2>&1
transaction_tee_pid=$!
transaction_log_open=true

pdm_snapshot="$output_directory/pdm-a32-0-2-3.json"
pdm_mic_snapshot="$output_directory/pdm-mic-scalars.json"
cleanup_mode=none

powerphone_remote_su() {
  frankel_audio_remote_exec su 0 "$@"
}

powerphone_getprop() {
  frankel_audio_remote_exec /system/bin/getprop "$1"
}

powerphone_require_equal() {
  local label=$1
  local expected=$2
  local actual=$3
  [[ "$actual" == "$expected" ]] || \
    frankel_audio_die "$label: expected '$expected', got '$actual'"
}

powerphone_close_transaction_log() {
  [[ "$transaction_log_open" == true ]] || return 0
  transaction_log_open=false

  # Stop writing to the process substitution before joining it. A failed tee
  # means the transaction no longer has complete host audit evidence.
  exec 1>&3 2>&4
  local tee_status=0
  wait "$transaction_tee_pid" || tee_status=$?
  exec 3>&- 4>&-
  if (( tee_status != 0 )); then
    printf 'error: transaction log writer failed with status %s: %s\n' \
      "$tee_status" "$run_log" >&2
    return 1
  fi
}

powerphone_require_property_boolean() {
  local property=$1
  local value
  value=$(powerphone_getprop "$property") || \
    frankel_audio_die "cannot read property $property"
  case "$value" in
    0|1) printf '%s\n' "$value" ;;
    *) frankel_audio_die "$property is not exact Boolean 0/1: '$value'" ;;
  esac
}

powerphone_set_property() {
  local property=$1
  local expected=$2
  local actual
  printf 'property: requesting %s=%s through su domain\n' "$property" "$expected"
  powerphone_remote_su /system/bin/setprop "$property" "$expected" || return 1
  actual=$(powerphone_getprop "$property") || return 1
  if [[ "$actual" != "$expected" ]]; then
    printf 'error: %s readback is %q, expected %s\n' \
      "$property" "$actual" "$expected" >&2
    return 1
  fi
  printf 'property: verified %s=%s\n' "$property" "$expected"
}

powerphone_read_mic_state() {
  local control=$1
  local value
  value=$(powerphone_remote_su /system/bin/tinymix -D 0 -v -- "$control") || \
    return 1
  case "$value" in
    0|Off) printf '0\n' ;;
    1|On) printf '1\n' ;;
    *)
      printf 'error: %s is not an exact scalar Boolean: %q\n' \
        "$control" "$value" >&2
      return 1
      ;;
  esac
}

powerphone_require_mic_states() {
  (( $# == ${#POWERPHONE_MIC_CONTROLS[@]} )) || return 1
  local -a mic_expected_states=("$@")
  local index actual
  for ((index = 0; index < ${#POWERPHONE_MIC_CONTROLS[@]}; index++)); do
    actual=$(powerphone_read_mic_state "${POWERPHONE_MIC_CONTROLS[index]}") || {
      printf 'error: cannot read scalar %s\n' \
        "${POWERPHONE_MIC_CONTROLS[index]}" >&2
      return 1
    }
    if [[ "$actual" != "${mic_expected_states[index]}" ]]; then
      printf 'error: scalar %s: expected %s, got %s\n' \
        "${POWERPHONE_MIC_CONTROLS[index]}" \
        "${mic_expected_states[index]}" "$actual" >&2
      return 1
    fi
  done
}

powerphone_set_mic_state() {
  local control=$1
  local expected=$2
  local actual
  printf 'microphone rail: requesting %s=%s\n' "$control" "$expected"
  powerphone_remote_su /system/bin/tinymix -D 0 -- "$control" "$expected" \
    >/dev/null || return 1
  actual=$(powerphone_read_mic_state "$control") || return 1
  if [[ "$actual" != "$expected" ]]; then
    printf 'error: scalar %s readback=%s, expected=%s\n' \
      "$control" "$actual" "$expected" >&2
    return 1
  fi
}

powerphone_power_mics_on() {
  local -a mic_expected_states=(0 0 0)
  local index
  for ((index = 0; index < ${#POWERPHONE_MIC_CONTROLS[@]}; index++)); do
    powerphone_set_mic_state "${POWERPHONE_MIC_CONTROLS[index]}" 1 || return 1
    mic_expected_states[index]=1
    powerphone_require_mic_states "${mic_expected_states[@]}" || return 1
  done
  printf '%s\n' \
    'microphone rail: MIC0/MIC1/MIC2 are all on; this does not establish logical-to-physical mapping'
}

powerphone_power_mics_off() {
  local index
  for ((index = ${#POWERPHONE_MIC_CONTROLS[@]} - 1; index >= 0; index--)); do
    powerphone_set_mic_state "${POWERPHONE_MIC_CONTROLS[index]}" 0 || return 1
  done
  powerphone_require_mic_states 0 0 0 || return 1
  printf 'microphone rail: MIC2/MIC1/MIC0 are all off\n'
}

powerphone_mic_snapshot_status() {
  if [[ ! -f "$pdm_mic_snapshot" ]]; then
    printf 'absent\n'
    return 0
  fi
  python3 - "$pdm_mic_snapshot" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    document = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    print(f"invalid:{error}")
    raise SystemExit(0)
if document.get("version") != 1:
    print("invalid:version")
elif document.get("controls") != {"MIC0": 0, "MIC1": 0, "MIC2": 0}:
    print("invalid:controls")
elif document.get("status") not in {"prepared", "powered", "reverted"}:
    print("invalid:status")
else:
    print(document["status"])
PY
}

powerphone_create_mic_snapshot() {
  python3 - "$pdm_mic_snapshot" <<'PY'
import datetime
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = {
    "version": 1,
    "status": "prepared",
    "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "controls": {"MIC0": 0, "MIC1": 0, "MIC2": 0},
    "note": (
        "All three logical scalars are powered together; this does not prove "
        "physical mapping."
    ),
}
try:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError as error:
    raise SystemExit(f"refusing to overwrite microphone snapshot: {path}") from error
with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
    json.dump(document, stream, indent=2, sort_keys=True)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
}

powerphone_update_mic_snapshot() {
  local expected=$1
  local replacement=$2
  python3 - "$pdm_mic_snapshot" "$expected" "$replacement" <<'PY'
import datetime
import json
import os
import pathlib
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
expected, replacement = sys.argv[2:]
allowed = {
    ("prepared", "powered"),
    ("prepared", "reverted"),
    ("powered", "reverted"),
}
if (expected, replacement) not in allowed:
    raise SystemExit(f"invalid microphone snapshot transition: {expected}->{replacement}")
document = json.loads(path.read_text(encoding="utf-8"))
if document.get("version") != 1 or document.get("controls") != {
    "MIC0": 0,
    "MIC1": 0,
    "MIC2": 0,
}:
    raise SystemExit("invalid microphone snapshot schema")
if document.get("status") != expected:
    raise SystemExit(
        f"microphone snapshot status is {document.get('status')!r}, expected {expected!r}"
    )
document["status"] = replacement
document[f"{replacement}_utc"] = datetime.datetime.now(
    datetime.timezone.utc
).isoformat()
descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(document, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}

powerphone_read_parameter() {
  powerphone_remote_su /system/bin/cat \
    "$POWERPHONE_PARAMETER_DIRECTORY/$1"
}

powerphone_normalize_boolean() {
  case "$1" in
    1|Y|y|yes|true) printf '1\n' ;;
    0|N|n|no|false) printf '0\n' ;;
    *) return 1 ;;
  esac
}

powerphone_require_boolean_parameter() {
  local name=$1
  local expected=$2
  local actual normalized
  actual=$(powerphone_read_parameter "$name") || \
    frankel_audio_die "cannot read module parameter $name"
  normalized=$(powerphone_normalize_boolean "$actual") || \
    frankel_audio_die "module parameter $name is not Boolean: '$actual'"
  powerphone_require_equal "module parameter $name" "$expected" "$normalized"
}

powerphone_require_integer_parameter() {
  local name=$1
  local expected=$2
  local actual
  actual=$(powerphone_read_parameter "$name") || \
    frankel_audio_die "cannot read module parameter $name"
  [[ "$actual" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || \
    frankel_audio_die "module parameter $name is not an integer: '$actual'"
  python3 - "$name" "$actual" "$expected" <<'PY' || exit 1
import sys

name, actual, expected = sys.argv[1:]
if int(actual, 0) != int(expected, 0):
    print(
        f"error: module parameter {name}: expected {expected}, got {actual}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

powerphone_validate_pcm_nodes() {
  local actual expected
  # The expansion must happen in the remote Android shell, not on the host.
  # shellcheck disable=SC2016
  actual=$(powerphone_remote_su /system/bin/sh -c \
    'for path in /dev/snd/pcmC1*; do test -e "$path" || continue; basename "$path"; done' | \
    sort) || frankel_audio_die 'cannot enumerate card-1 PCM nodes'
  expected=$'pcmC1D0c\npcmC1D2c\npcmC1D3c'
  powerphone_require_equal 'exact card-1 PCM node set' "$expected" "$actual"

  local device expected_name info
  for device in 0 2 3; do
    case "$device" in
      0) expected_name='Frankel raw PDM0' ;;
      2) expected_name='Frankel raw PDM2' ;;
      3) expected_name='Frankel raw PDM3' ;;
    esac
    info=$(powerphone_remote_su /system/bin/cat \
      "/proc/asound/card1/pcm${device}c/info") || \
      frankel_audio_die "cannot read card 1,$device capture identity"
    [[ "$info" == *"$expected_name"* ]] || \
      frankel_audio_die "card 1,$device is not '$expected_name'"
  done
}

powerphone_validate_card1_status_paths() {
  local actual expected
  actual=$(powerphone_remote_su /system/bin/find /proc/asound/card1 \
    -type f -name status | sort) || \
    frankel_audio_die 'cannot enumerate card-1 PCM status files'
  expected=$'/proc/asound/card1/pcm0c/sub0/status\n/proc/asound/card1/pcm2c/sub0/status\n/proc/asound/card1/pcm3c/sub0/status'
  powerphone_require_equal 'exact card-1 PCM status set' "$expected" "$actual"
}

powerphone_require_card1_closed() {
  powerphone_validate_card1_status_paths
  local device status
  for device in 0 2 3; do
    status=$(powerphone_remote_su /system/bin/cat \
      "/proc/asound/card1/pcm${device}c/sub0/status") || \
      frankel_audio_die "cannot read card 1,$device status"
    powerphone_require_equal "card 1,$device capture status" closed "$status"
  done
  printf 'guard: all exact card-1 PDM PCMs are closed\n'
}

powerphone_card1_closed_soft() {
  local actual expected device status
  actual=$(powerphone_remote_su /system/bin/find /proc/asound/card1 \
    -type f -name status 2>/dev/null | sort) || return 1
  expected=$'/proc/asound/card1/pcm0c/sub0/status\n/proc/asound/card1/pcm2c/sub0/status\n/proc/asound/card1/pcm3c/sub0/status'
  [[ "$actual" == "$expected" ]] || return 1
  for device in 0 2 3; do
    status=$(powerphone_remote_su /system/bin/cat \
      "/proc/asound/card1/pcm${device}c/sub0/status" 2>/dev/null) || return 1
    [[ "$status" == closed ]] || return 1
  done
}

powerphone_wait_card1_closed() {
  local deadline=$((SECONDS + POWERPHONE_PCM_CLOSE_WAIT_SECONDS))
  while ! powerphone_card1_closed_soft; do
    if (( SECONDS >= deadline )); then
      printf 'error: card-1 PDM PCMs did not all close within %s seconds\n' \
        "$POWERPHONE_PCM_CLOSE_WAIT_SECONDS" >&2
      return 1
    fi
    sleep 0.2
  done
  printf 'guard: all exact card-1 PDM PCMs are closed\n'
}

powerphone_require_speaker_closed() {
  powerphone_remote_su /system/bin/test -x "$POWERPHONE_SPEAKER_GUARD" || \
    frankel_audio_die \
      "native PCM ownership guard is absent or not executable: $POWERPHONE_SPEAKER_GUARD"
  powerphone_remote_su "$POWERPHONE_SPEAKER_GUARD" \
    check-playback-closed || \
    frankel_audio_die \
      'native inventory/node/root-fd proof cannot establish PCM 0,28 closure'
  printf '%s\n' \
    'guard: exact speaker PCM 0,28 inventory/node/root-fd closure is stable'
}

powerphone_speaker_closed_soft() {
  powerphone_remote_su /system/bin/test -x "$POWERPHONE_SPEAKER_GUARD" \
    >/dev/null 2>&1 || return 1
  powerphone_remote_su "$POWERPHONE_SPEAKER_GUARD" \
    check-playback-closed >/dev/null 2>&1
}

powerphone_wait_speaker_closed() {
  local deadline=$((SECONDS + POWERPHONE_PCM_CLOSE_WAIT_SECONDS))
  while ! powerphone_speaker_closed_soft; do
    if (( SECONDS >= deadline )); then
      printf 'error: native ownership proof did not establish PCM 0,28 closure within %s seconds\n' \
        "$POWERPHONE_PCM_CLOSE_WAIT_SECONDS" >&2
      return 1
    fi
    sleep 0.2
  done
  printf '%s\n' \
    'guard: exact speaker PCM 0,28 inventory/node/root-fd closure is stable'
}

powerphone_validate_integrated_image() {
  local actual loader_pids loader_exe modules_load_file modules_load_files
  local modules_load_matches='' su_domain grep_status
  powerphone_require_equal ro.product.device "$POWERPHONE_EXPECTED_DEVICE" \
    "$(powerphone_getprop ro.product.device)"
  powerphone_require_equal ro.build.id "$POWERPHONE_EXPECTED_BUILD_ID" \
    "$(powerphone_getprop ro.build.id)"
  powerphone_require_equal ro.vendor.build.id "$POWERPHONE_EXPECTED_BUILD_ID" \
    "$(powerphone_getprop ro.vendor.build.id)"
  powerphone_require_equal ro.build.type userdebug \
    "$(powerphone_getprop ro.build.type)"
  powerphone_require_equal ro.debuggable 1 \
    "$(powerphone_getprop ro.debuggable)"
  powerphone_require_equal ro.build.version.incremental \
    "$POWERPHONE_EXPECTED_INCREMENTAL" \
    "$(powerphone_getprop ro.build.version.incremental)"
  powerphone_require_equal ro.build.version.release \
    "$POWERPHONE_EXPECTED_RELEASE" \
    "$(powerphone_getprop ro.build.version.release)"
  powerphone_require_equal ro.build.version.sdk "$POWERPHONE_EXPECTED_SDK" \
    "$(powerphone_getprop ro.build.version.sdk)"
  powerphone_require_equal ro.product.build.fingerprint \
    "$POWERPHONE_EXPECTED_PRODUCT_FINGERPRINT" \
    "$(powerphone_getprop ro.product.build.fingerprint)"
  powerphone_require_equal ro.system.build.fingerprint \
    "$POWERPHONE_EXPECTED_SYSTEM_FINGERPRINT" \
    "$(powerphone_getprop ro.system.build.fingerprint)"
  powerphone_require_equal sys.boot_completed 1 \
    "$(powerphone_getprop sys.boot_completed)"
  powerphone_require_equal 'running kernel' "$POWERPHONE_EXPECTED_KERNEL" \
    "$(frankel_audio_remote_exec /system/bin/uname -r)"

  powerphone_require_equal 'root adbd shell UID' 0 \
    "$(frankel_audio_remote_exec /system/bin/id -u)"
  su_domain=$(powerphone_remote_su /system/bin/id -Z) || \
    frankel_audio_die 'cannot enter the userdebug su domain'
  powerphone_require_equal 'su SELinux domain' u:r:su:s0 "$su_domain"

  powerphone_require_equal 'AoC ALSA card 0 ID' "$POWERPHONE_EXPECTED_CARD0" \
    "$(powerphone_remote_su /system/bin/cat /proc/asound/card0/id)"
  powerphone_require_equal 'raw-PDM ALSA card 1 ID' "$POWERPHONE_EXPECTED_CARD1" \
    "$(powerphone_remote_su /system/bin/cat /proc/asound/card1/id)"
  powerphone_remote_su /system/bin/test -f "$POWERPHONE_MODULE_PATH" || \
    frankel_audio_die "integrated module file is absent: $POWERPHONE_MODULE_PATH"
  powerphone_remote_su /system/bin/test -d "/sys/module/$POWERPHONE_MODULE" || \
    frankel_audio_die "$POWERPHONE_MODULE is not resident"
  powerphone_require_equal 'module initstate' live \
    "$(powerphone_remote_su /system/bin/cat "/sys/module/$POWERPHONE_MODULE/initstate")"
  # This is an awk program; $1 is intentionally passed through literally.
  # shellcheck disable=SC2016
  actual=$(powerphone_remote_su /system/bin/awk \
    -v "name=$POWERPHONE_MODULE" '$1 == name { print $1 }' /proc/modules) || \
    frankel_audio_die 'cannot inspect /proc/modules'
  powerphone_require_equal '/proc/modules exact module record' \
    "$POWERPHONE_MODULE" "$actual"

  modules_load_files=$(powerphone_remote_su /system/bin/find \
    /vendor_dlkm/lib/modules -type f '(' -name '*modules.load' -o \
    -name 'modules.load*' ')' -print) || \
    frankel_audio_die 'cannot enumerate vendor-DLKM modules.load files'
  while IFS= read -r modules_load_file; do
    [[ -n "$modules_load_file" ]] || continue
    if powerphone_remote_su /system/bin/grep -F -x -q \
        "$POWERPHONE_MODULE.ko" "$modules_load_file"; then
      if [[ -n "$modules_load_matches" ]]; then
        modules_load_matches+=$'\n'
      fi
      modules_load_matches+=$modules_load_file
    else
      grep_status=$?
      (( grep_status == 1 )) || \
        frankel_audio_die \
          "cannot read vendor-DLKM module list: $modules_load_file"
    fi
  done <<<"$modules_load_files"
  [[ -z "$modules_load_matches" ]] || \
    frankel_audio_die \
      "$POWERPHONE_MODULE unexpectedly appears in modules.load: $modules_load_matches"

  powerphone_require_equal "init service $POWERPHONE_LOADER_SERVICE" running \
    "$(powerphone_getprop "init.svc.$POWERPHONE_LOADER_SERVICE")"
  loader_pids=$(powerphone_remote_su /system/bin/pidof powerphone_pdm_loader) || \
    frankel_audio_die 'cannot find resident PowerPhone PDM loader process'
  [[ "$loader_pids" =~ ^[0-9]+$ ]] || \
    frankel_audio_die "expected exactly one PDM loader PID, got '$loader_pids'"
  loader_exe=$(powerphone_remote_su /system/bin/readlink \
    "/proc/$loader_pids/exe") || frankel_audio_die 'cannot resolve PDM loader executable'
  powerphone_require_equal 'PDM loader executable' \
    /vendor/bin/powerphone_pdm_loader "$loader_exe"
  powerphone_require_equal "init service $POWERPHONE_HAL_SERVICE" running \
    "$(powerphone_getprop "init.svc.$POWERPHONE_HAL_SERVICE")"
  powerphone_require_equal "$POWERPHONE_TOPOLOGY_PROPERTY" 1 \
    "$(powerphone_require_property_boolean "$POWERPHONE_TOPOLOGY_PROPERTY")"
  powerphone_require_property_boolean "$POWERPHONE_PDM_PROPERTY" >/dev/null
  powerphone_require_property_boolean "$POWERPHONE_SPEAKER_PROPERTY" >/dev/null

  powerphone_require_boolean_parameter map_controllers 1
  powerphone_require_integer_parameter projection_ack 0x0ac0a000
  powerphone_require_integer_parameter controller_mask 0x0d
  powerphone_require_integer_parameter decimator_order 3
  powerphone_require_boolean_parameter pdm_msb_first 0
  powerphone_require_boolean_parameter pdm_reverse_bytes 0
  powerphone_require_boolean_parameter pdm_invert 0
  powerphone_validate_pcm_nodes
  printf 'guard: exact integrated Frankel image, loader, HAL, module, and ALSA topology passed\n'
}

powerphone_write_polling() {
  local expected=$1
  local actual normalized
  powerphone_remote_su /system/bin/sh -c \
    "printf $expected > $POWERPHONE_PARAMETER_DIRECTORY/polling_enabled" || \
    return 1
  actual=$(powerphone_read_parameter polling_enabled) || return 1
  normalized=$(powerphone_normalize_boolean "$actual") || return 1
  if [[ "$normalized" != "$expected" ]]; then
    printf 'error: polling_enabled readback is %q, expected %s\n' \
      "$actual" "$expected" >&2
    return 1
  fi
  printf 'polling: synchronously verified polling_enabled=%s\n' "$expected"
}

powerphone_clear_status_probe() {
  local actual normalized
  powerphone_remote_su /system/bin/sh -c \
    "printf 0 > $POWERPHONE_PARAMETER_DIRECTORY/status_probe" || return 1
  actual=$(powerphone_read_parameter status_probe) || return 1
  normalized=$(powerphone_normalize_boolean "$actual") || return 1
  if [[ "$normalized" != 0 ]]; then
    printf 'error: status_probe did not clear after guarded idle restoration\n' >&2
    return 1
  fi
  printf 'status probe: one-shot token is clear\n'
}

powerphone_run_status_probe() {
  local before_path="$run_directory/pdm-status-probe-before.txt"
  local after_path="$run_directory/pdm-status-probe-after.txt"
  powerphone_require_boolean_parameter polling_enabled 0
  powerphone_require_boolean_parameter status_probe 0
  powerphone_read_parameter stats >"$before_path" || return 1
  printf '%s\n' \
    'status probe: requesting one synchronous +0x10 read per selected controller; FIFO pop remains disabled'
  powerphone_remote_su /system/bin/sh -c \
    "printf 1 > $POWERPHONE_PARAMETER_DIRECTORY/status_probe" || return 1
  powerphone_require_boolean_parameter status_probe 1
  powerphone_require_boolean_parameter polling_enabled 0
  powerphone_read_parameter stats >"$after_path" || return 1
  python3 - "$before_path" "$after_path" <<'PY'
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


def load(path: str) -> dict[int, dict[str, int]]:
    result = {}
    for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        match = pattern.fullmatch(line)
        if match is None:
            raise SystemExit(f"malformed raw-PDM stats: {line!r}")
        fields = {
            name: int(value, 16 if name == "last_status" else 10)
            for name, value in match.groupdict().items()
            if name != "pdm"
        }
        result[int(match.group("pdm"))] = fields
    if set(result) != {0, 2, 3}:
        raise SystemExit(f"unexpected PDM stats set: {sorted(result)}")
    return result


before = load(sys.argv[1])
after = load(sys.argv[2])
unchanged = {
    "words",
    "bits",
    "frames",
    "delivered",
    "discarded",
    "periods",
    "overruns",
    "clips",
}
for pdm in (0, 2, 3):
    if after[pdm]["status"] != before[pdm]["status"] + 1:
        raise SystemExit(f"PDM{pdm} status-read delta is not exactly one")
    if after[pdm]["probe_reads"] != before[pdm]["probe_reads"] + 1:
        raise SystemExit(f"PDM{pdm} status-probe delta is not exactly one")
    if after[pdm]["empty"] - before[pdm]["empty"] not in {0, 1}:
        raise SystemExit(f"PDM{pdm} empty-status delta is invalid")
    for field in unchanged:
        if after[pdm][field] != before[pdm][field]:
            raise SystemExit(
                f"PDM{pdm} {field} changed during status-only probe: "
                f"{before[pdm][field]}->{after[pdm][field]}"
            )
print("status-only proof: each selected +0x10 read advanced once; FIFO/data counters unchanged")
PY
}

powerphone_run_a32() {
  local operation=$1
  local label=$2
  shift 2
  local -a command=(
    timeout --signal=TERM 300
    python3 "$a32_helper" "$operation"
    --controllers "$POWERPHONE_A32_CONTROLLERS"
    --snapshot "$pdm_snapshot"
    --adb "$FRANKEL_AUDIO_ADB"
    --adb-server-port "$FRANKEL_AUDIO_ADB_SERVER_PORT"
  )
  if [[ -n ${FRANKEL_AUDIO_SERIAL:-} ]]; then
    command+=(--serial "$FRANKEL_AUDIO_SERIAL")
  fi
  if [[ -n "$aoc_counter" ]]; then
    command+=(--counter "$aoc_counter")
  fi
  command+=("$@")
  printf 'A32: %s for controllers %s\n' "$operation" "$POWERPHONE_A32_CONTROLLERS"
  "${command[@]}" 2>&1 | tee "$run_directory/${label}.txt"
}

powerphone_pdm_snapshot_status() {
  if [[ ! -f "$pdm_snapshot" ]]; then
    printf 'absent\n'
    return 0
  fi
  python3 - "$pdm_snapshot" <<'PY'
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

powerphone_collect_command() {
  local key=$1
  shift
  local value
  value=$("$@") || {
    printf 'error: cannot collect audit field %s\n' "$key" >&2
    return 1
  }
  printf '%s=%s\n' "$key" "$value"
}

powerphone_collect_state() {
  local label=$1
  local path="$run_directory/${label}-state.txt"
  {
    powerphone_collect_command host_utc date -u +%Y-%m-%dT%H:%M:%SZ
    powerphone_collect_command device powerphone_getprop ro.product.device
    powerphone_collect_command build_id powerphone_getprop ro.build.id
    powerphone_collect_command vendor_build_id \
      powerphone_getprop ro.vendor.build.id
    powerphone_collect_command build_type powerphone_getprop ro.build.type
    powerphone_collect_command incremental \
      powerphone_getprop ro.build.version.incremental
    powerphone_collect_command kernel \
      frankel_audio_remote_exec /system/bin/uname -r
    powerphone_collect_command loader_service powerphone_getprop \
      "init.svc.$POWERPHONE_LOADER_SERVICE"
    powerphone_collect_command hal_service powerphone_getprop \
      "init.svc.$POWERPHONE_HAL_SERVICE"
    powerphone_collect_command topology_ready powerphone_getprop \
      "$POWERPHONE_TOPOLOGY_PROPERTY"
    powerphone_collect_command pdm_ready powerphone_getprop \
      "$POWERPHONE_PDM_PROPERTY"
    powerphone_collect_command speaker_ready powerphone_getprop \
      "$POWERPHONE_SPEAKER_PROPERTY"
    powerphone_collect_command card0_id powerphone_remote_su \
      /system/bin/cat /proc/asound/card0/id
    powerphone_collect_command card1_id powerphone_remote_su \
      /system/bin/cat /proc/asound/card1/id
    local parameter
    for parameter in map_controllers projection_ack controller_mask \
      decimator_order pdm_msb_first pdm_reverse_bytes pdm_invert \
      status_probe polling_enabled stats; do
      powerphone_collect_command "module_$parameter" \
        powerphone_read_parameter "$parameter"
    done
    local device direction status_path
    for device in 0 2 3; do
      direction=c
      status_path="/proc/asound/card1/pcm${device}${direction}/sub0/status"
      powerphone_collect_command "pcm1_${device}_capture" \
        powerphone_remote_su /system/bin/cat "$status_path"
    done
    local microphone
    for microphone in "${POWERPHONE_MIC_CONTROLS[@]}"; do
      powerphone_collect_command "scalar_$microphone" \
        powerphone_read_mic_state "$microphone"
    done
    powerphone_collect_command pcm0_28_proc_status powerphone_remote_su \
      /system/bin/sh -c \
      'p=/proc/asound/card0/pcm28p/sub0/status; if /system/bin/test -e "$p"; then /system/bin/cat "$p"; else /system/bin/printf "status-file-absent\n"; fi'
    powerphone_collect_command pdm_snapshot_status \
      powerphone_pdm_snapshot_status
    powerphone_collect_command pdm_mic_snapshot_status \
      powerphone_mic_snapshot_status
  } >"$path"
  powerphone_remote_su /system/bin/dmesg \
    >"$run_directory/${label}-dmesg.txt" || {
      printf 'error: cannot collect %s dmesg audit\n' "$label" >&2
      return 1
    }
  printf 'audit: %s\n' "$path"
}

powerphone_prepare_device() {
  FRANKEL_AUDIO_ADB=${FRANKEL_AUDIO_ADB:-\
"$frankel_audio_project_root/work/toolchains/platform-tools/adb"}
  [[ -x "$FRANKEL_AUDIO_ADB" ]] || \
    frankel_audio_die "adb is not executable: $FRANKEL_AUDIO_ADB"
  printf 'ADB: requesting root adbd for the reviewed userdebug image\n'
  frankel_audio_adb root
  frankel_audio_adb wait-for-device
  # No extra target utility is needed beyond common.sh's mandatory tinymix.
  # shellcheck disable=SC2119
  frankel_audio_initialize_device
  powerphone_validate_integrated_image
  powerphone_collect_state pre
}

powerphone_pdm_status() {
  local ready polling status_probe snapshot_status mic_snapshot_status
  ready=$(powerphone_require_property_boolean "$POWERPHONE_PDM_PROPERTY")
  polling=$(powerphone_read_parameter polling_enabled)
  polling=$(powerphone_normalize_boolean "$polling") || \
    frankel_audio_die 'polling_enabled is not Boolean'
  status_probe=$(powerphone_read_parameter status_probe)
  status_probe=$(powerphone_normalize_boolean "$status_probe") || \
    frankel_audio_die 'status_probe is not Boolean'
  snapshot_status=$(powerphone_pdm_snapshot_status)
  mic_snapshot_status=$(powerphone_mic_snapshot_status)
  printf 'PDM status: ready=%s polling=%s status_probe=%s snapshot=%s mic_snapshot=%s\n' \
    "$ready" "$polling" "$status_probe" "$snapshot_status" \
    "$mic_snapshot_status"
  if [[ "$ready" == 0 && "$polling" == 0 && "$status_probe" == 0 ]]; then
    case "$snapshot_status" in
      absent|prepared|rolled_back|reverted)
        powerphone_run_a32 check-idle pdm-status-check-idle || \
          frankel_audio_die \
            'PDM gates say inactive but guarded A32 idle proof failed'
        ;;
      *)
        frankel_audio_die \
          "PDM gates say inactive but snapshot state is $snapshot_status"
        ;;
    esac
    case "$mic_snapshot_status" in
      absent|reverted) ;;
      *)
        frankel_audio_die \
          "PDM controller is inactive but microphone snapshot is $mic_snapshot_status"
        ;;
    esac
    powerphone_require_mic_states 0 0 0 || \
      frankel_audio_die 'PDM controller is inactive but a microphone scalar is on'
    printf 'PDM status: coherently inactive\n'
  elif [[ "$ready" == 1 && "$polling" == 1 && "$status_probe" == 0 && \
          "$snapshot_status" == active && "$mic_snapshot_status" == powered ]]; then
    powerphone_run_a32 check-active pdm-status-check-active || \
      frankel_audio_die 'PDM gates say active but guarded A32 proof failed'
    powerphone_require_mic_states 1 1 1 || \
      frankel_audio_die 'PDM gates say active but a microphone scalar is not on'
    printf 'PDM status: coherently active (not acoustic proof)\n'
  else
    frankel_audio_die \
      "incoherent PDM state: ready=$ready polling=$polling status_probe=$status_probe snapshot=$snapshot_status mic_snapshot=$mic_snapshot_status"
  fi
}

powerphone_speaker_status() {
  local ready
  ready=$(powerphone_require_property_boolean "$POWERPHONE_SPEAKER_PROPERTY")
  powerphone_require_equal \
    'unqualified integrated speaker readiness must remain fail-closed' 0 "$ready"
  powerphone_require_speaker_closed
  printf 'speaker status: ready=%s pcm0,28-closure=native-verified\n' "$ready"
  printf '%s\n' \
    'speaker status: fail-closed/inert; AoC memory is deliberately not inspected here'
}

powerphone_pdm_activate() {
  local ready snapshot_status mic_snapshot_status
  ready=$(powerphone_require_property_boolean "$POWERPHONE_PDM_PROPERTY")
  powerphone_require_equal "$POWERPHONE_PDM_PROPERTY before activation" 0 "$ready"
  powerphone_require_boolean_parameter polling_enabled 0
  powerphone_require_boolean_parameter status_probe 0
  powerphone_require_card1_closed
  snapshot_status=$(powerphone_pdm_snapshot_status)
  powerphone_require_equal 'new PDM activation snapshot state' absent "$snapshot_status"
  mic_snapshot_status=$(powerphone_mic_snapshot_status)
  powerphone_require_equal 'new microphone snapshot state' absent \
    "$mic_snapshot_status"
  powerphone_require_mic_states 0 0 0 || \
    frankel_audio_die 'MIC0/MIC1/MIC2 must all be off before activation'
  powerphone_run_a32 check-idle pdm-check-idle || \
    frankel_audio_die 'guarded PDM idle preflight failed'
  powerphone_require_card1_closed

  cleanup_mode=pdm-activation
  powerphone_create_mic_snapshot || \
    frankel_audio_die 'cannot create write-ahead microphone scalar snapshot'
  powerphone_power_mics_on || \
    frankel_audio_die 'cannot power and prove all three microphone scalars'
  powerphone_update_mic_snapshot prepared powered || \
    frankel_audio_die 'cannot commit powered microphone snapshot state'
  powerphone_run_a32 check-idle pdm-check-idle-after-mic-power || \
    frankel_audio_die \
      'microphone scalar power changed A32 ownership/controller idle state'
  powerphone_require_card1_closed
  powerphone_run_a32 apply pdm-apply \
    --ack-hardware-write --ack-ap-consumer-ready || \
    frankel_audio_die 'coordinated PDM0/PDM2/PDM3 A32 apply failed'
  powerphone_run_a32 check-active pdm-check-active-before-polling || \
    frankel_audio_die 'A32 apply returned without exact active proof'
  powerphone_require_card1_closed
  powerphone_run_status_probe || \
    frankel_audio_die 'synchronous AP status-only permission probe failed'
  powerphone_run_a32 check-active pdm-check-active-after-status-probe || \
    frankel_audio_die 'A32 active proof failed after status-only AP probe'
  powerphone_require_card1_closed
  powerphone_write_polling 1 || \
    frankel_audio_die \
      'cannot consume the status proof and enable synchronous AP FIFO polling'
  powerphone_require_boolean_parameter status_probe 0
  powerphone_run_a32 check-active pdm-check-active-after-polling || \
    frankel_audio_die 'A32 active proof failed after polling enable'
  powerphone_require_card1_closed
  powerphone_require_mic_states 1 1 1 || \
    frankel_audio_die 'a microphone scalar changed before readiness publication'
  powerphone_set_property "$POWERPHONE_PDM_PROPERTY" 1 || \
    frankel_audio_die 'cannot publish PDM data readiness'

  powerphone_collect_state post
  powerphone_run_a32 check-active pdm-check-active-after-ready || \
    frankel_audio_die 'A32 active proof failed after publishing readiness'
  powerphone_require_equal "$POWERPHONE_PDM_PROPERTY final state" 1 \
    "$(powerphone_require_property_boolean "$POWERPHONE_PDM_PROPERTY")"
  powerphone_require_boolean_parameter polling_enabled 1
  powerphone_require_boolean_parameter status_probe 0
  powerphone_require_mic_states 1 1 1 || \
    frankel_audio_die 'a microphone scalar changed after readiness publication'
  powerphone_require_equal "$POWERPHONE_TOPOLOGY_PROPERTY final state" 1 \
    "$(powerphone_require_property_boolean "$POWERPHONE_TOPOLOGY_PROPERTY")"
  powerphone_require_equal "init service $POWERPHONE_LOADER_SERVICE final state" \
    running "$(powerphone_getprop "init.svc.$POWERPHONE_LOADER_SERVICE")"
  powerphone_require_equal "init service $POWERPHONE_HAL_SERVICE final state" \
    running "$(powerphone_getprop "init.svc.$POWERPHONE_HAL_SERVICE")"
  cleanup_mode=none
  printf 'PDM activation complete; this is runtime-state proof, not Nyquist proof.\n'
}

powerphone_restore_mics_after_idle() {
  local mic_snapshot_status
  mic_snapshot_status=$(powerphone_mic_snapshot_status)
  case "$mic_snapshot_status" in
    absent)
      powerphone_require_mic_states 0 0 0 || {
        printf '%s\n' \
          'error: no microphone snapshot exists but a scalar is on; refusing ownership guess' >&2
        return 1
      }
      ;;
    prepared|powered)
      powerphone_power_mics_off || return 1
      powerphone_update_mic_snapshot "$mic_snapshot_status" reverted || return 1
      ;;
    reverted)
      powerphone_require_mic_states 0 0 0 || return 1
      ;;
    *)
      printf 'error: unsafe microphone snapshot state %s\n' \
        "$mic_snapshot_status" >&2
      return 1
      ;;
  esac
}

powerphone_pdm_deactivate() {
  local snapshot_status mic_snapshot_status
  powerphone_set_property "$POWERPHONE_PDM_PROPERTY" 0 || \
    frankel_audio_die 'cannot clear PDM readiness; no ownership change attempted'
  powerphone_wait_card1_closed || \
    frankel_audio_die \
      'PDM readiness is zero, but capture PCM closure is unproven'
  powerphone_write_polling 0 || \
    frankel_audio_die 'cannot synchronously prove polling stopped; A32 was not reverted'
  powerphone_require_card1_closed
  mic_snapshot_status=$(powerphone_mic_snapshot_status)
  case "$mic_snapshot_status" in
    prepared|powered|reverted|absent) ;;
    *)
      frankel_audio_die \
        "unsafe microphone snapshot state '$mic_snapshot_status'; A32 was not reverted"
      ;;
  esac
  snapshot_status=$(powerphone_pdm_snapshot_status)
  case "$snapshot_status" in
    active)
      powerphone_run_a32 check-active pdm-deactivate-check-active || \
        frankel_audio_die 'A32 active state no longer matches its snapshot; refusing revert'
      powerphone_run_a32 revert pdm-revert \
        --ack-hardware-write --ack-polling-stopped || \
        frankel_audio_die 'guarded PDM A32 revert failed; readiness remains zero'
      ;;
    absent|prepared|rolled_back|reverted)
      printf 'PDM deactivation: snapshot=%s; proving idle without an A32 write\n' \
        "$snapshot_status"
      ;;
    *)
      frankel_audio_die \
        "unsafe PDM snapshot state '$snapshot_status'; readiness/polling remain zero"
      ;;
  esac
  powerphone_run_a32 check-idle pdm-deactivate-check-idle || \
    frankel_audio_die 'final guarded PDM idle proof failed'
  powerphone_clear_status_probe || \
    frankel_audio_die 'cannot clear consumed status-probe token after A32 idle proof'
  powerphone_restore_mics_after_idle || \
    frankel_audio_die 'A32 is idle but microphone scalar cleanup is unproven'
  powerphone_require_equal "$POWERPHONE_PDM_PROPERTY final state" 0 \
    "$(powerphone_require_property_boolean "$POWERPHONE_PDM_PROPERTY")"
  powerphone_require_boolean_parameter polling_enabled 0
  powerphone_require_boolean_parameter status_probe 0
  powerphone_require_mic_states 0 0 0 || \
    frankel_audio_die 'a microphone scalar remains on after deactivation'
  powerphone_collect_state post
  printf 'PDM deactivation complete; resident loader topology remains loaded and inert.\n'
}

powerphone_speaker_activate() {
  powerphone_require_equal \
    "$POWERPHONE_SPEAKER_PROPERTY before rejected activation" 0 \
    "$(powerphone_require_property_boolean "$POWERPHONE_SPEAKER_PROPERTY")"
  frankel_audio_die \
    'integrated speaker activation is unqualified and disabled; use the native-only first-live runbook'
}

powerphone_speaker_deactivate() {
  powerphone_set_property "$POWERPHONE_SPEAKER_PROPERTY" 0 || \
    frankel_audio_die 'cannot clear speaker readiness; no AoC write attempted'
  powerphone_wait_speaker_closed || \
    frankel_audio_die \
      'speaker readiness is zero, but PCM 0,28 closure is unproven; reboot before manual recovery'
  powerphone_require_equal "$POWERPHONE_SPEAKER_PROPERTY final state" 0 \
    "$(powerphone_require_property_boolean "$POWERPHONE_SPEAKER_PROPERTY")"
  powerphone_collect_state post
  frankel_audio_die \
    'speaker readiness is cleared and PCM is closed; AoC memory was not changed—use the native helper or reboot'
}

powerphone_recover_pdm_activation() {
  local snapshot_status
  printf 'recovery: fail-closing an interrupted PDM activation\n'
  if ! powerphone_set_property "$POWERPHONE_PDM_PROPERTY" 0; then
    printf 'recovery error: could not prove PDM readiness zero; refusing ownership changes\n' >&2
    return 1
  fi
  if ! powerphone_wait_card1_closed; then
    printf 'recovery error: card-1 PCM closure is unproven; polling remains active\n' \
      >&2
    return 1
  fi
  if ! powerphone_write_polling 0; then
    printf 'recovery error: polling stop is unproven; refusing A32 revert\n' >&2
    return 1
  fi
  if ! powerphone_card1_closed_soft; then
    printf 'recovery error: card-1 PCM reopened; refusing A32 revert\n' >&2
    return 1
  fi
  snapshot_status=$(powerphone_pdm_snapshot_status)
  case "$snapshot_status" in
    active)
      powerphone_run_a32 check-active recovery-pdm-check-active || return 1
      powerphone_run_a32 revert recovery-pdm-revert \
        --ack-hardware-write --ack-polling-stopped || return 1
      powerphone_run_a32 check-idle recovery-pdm-check-idle || return 1
      ;;
    absent|prepared|rolled_back|reverted)
      powerphone_run_a32 check-idle recovery-pdm-check-idle || return 1
      ;;
    *)
      printf 'recovery error: unsafe A32 snapshot state %s; reboot/manual audit required\n' \
        "$snapshot_status" >&2
      return 1
      ;;
  esac
  if ! powerphone_clear_status_probe; then
    printf 'recovery error: cannot clear status-probe token after A32 idle proof\n' \
      >&2
    return 1
  fi
  if ! powerphone_restore_mics_after_idle; then
    printf 'recovery error: microphone scalar cleanup is unproven\n' >&2
    return 1
  fi
  printf '%s\n' \
    'recovery: PDM path returned to guarded idle state with MIC0/MIC1/MIC2 off'
}

# shellcheck disable=SC2317
powerphone_exit_handler() {
  local status=$?
  local recovery_status=0
  local log_status=0
  trap - EXIT HUP INT TERM
  set +e
  if (( status != 0 )); then
    case "$cleanup_mode" in
      pdm-activation)
        powerphone_recover_pdm_activation \
          >>"$run_directory/recovery.txt" 2>&1 || recovery_status=1
        ;;
    esac
    if (( recovery_status != 0 )); then
      printf 'recovery is incomplete; inspect %s and reboot before reuse\n' \
        "$run_directory/recovery.txt" >&2
    fi
  fi
  powerphone_close_transaction_log || log_status=1
  if (( status == 0 && log_status != 0 )); then
    status=1
  fi
  exit "$status"
}

trap powerphone_exit_handler EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'PowerPhone runtime action: %s\n' "$action"
printf 'audit directory: %s\n' "$run_directory"
powerphone_prepare_device

case "$action" in
  status)
    pdm_status=0
    speaker_status=0
    if ( powerphone_pdm_status ); then
      printf 'combined status: PDM PASS\n'
    else
      pdm_status=1
      printf 'combined status: PDM FAIL\n' >&2
    fi
    if ( powerphone_speaker_status ); then
      printf 'combined status: speaker PASS\n'
    else
      speaker_status=1
      printf 'combined status: speaker FAIL\n' >&2
    fi
    powerphone_collect_state post
    (( pdm_status == 0 && speaker_status == 0 )) || exit 1
    ;;
  pdm-status)
    powerphone_pdm_status
    powerphone_collect_state post
    ;;
  speaker-status)
    powerphone_speaker_status
    powerphone_collect_state post
    ;;
  pdm-activate) powerphone_pdm_activate ;;
  pdm-deactivate) powerphone_pdm_deactivate ;;
  speaker-activate) powerphone_speaker_activate ;;
  speaker-deactivate) powerphone_speaker_deactivate ;;
esac

printf 'PowerPhone runtime action %s finished successfully.\n' "$action"
powerphone_close_transaction_log || exit 1
trap - EXIT HUP INT TERM
