#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_directory/common.sh"
readonly aocx_service=aocx.IAocx/default
readonly speaker_tag=1936945259 # Big-endian character tag 'sspk'.
readonly decoder="$frankel_audio_project_root/tools/audio/decode_aocx_service_reply.py"

usage() {
  cat <<'USAGE'
Usage: aocx-speaker-tap.sh --output-directory NEW_HOST_DIRECTORY
         [--permissive-capture] [--timeout-seconds N]
         [--adb PATH] [--serial SERIAL] [--adb-server-port PORT]
         -- PLAYBACK_COMMAND [ARGUMENTS...]

Record the stock core-2 sspk.0 speaker tap around an existing playback command.
Requires booted Frankel CP2A.260805.005, root ADB, running stock aocxd, and
idle/disconnected AoCx buffers and sspk tap. Only tapout20 IO is enabled;
the tap has no injection binding. Playback owns its own audio/mixer lifecycle.
The timeout is 180 seconds by default. Pass ADB selection to the playback
command too if it does not inherit FRANKEL_AUDIO_* variables.

--permissive-capture temporarily permits aocxd to create diagnostic WAV files,
then restores the original SELinux state in cleanup. Without it, an enforcing
policy must already allow the capture destination.

The stock recorder's single-buffer help is incorrect: capture start accepts
a prefix and opens files for every buffer. Other buffers remain IO-disabled.
The relevant result is captures/sspk_tapout20.wav. Its 48kHz header may be
stale on the experimental 192kHz path; this script does not rewrite samples,
headers, or report a rate/bandwidth qualification.
USAGE
}

output_directory=
permissive_capture=false
playback_timeout=180
while (($#)); do
  case "$1" in
    --output-directory|--timeout-seconds|--adb|--serial|--adb-server-port)
      (($# >= 2)) || frankel_audio_die "missing value for $1"
      case "$1" in
        --output-directory) output_directory=$2 ;;
        --timeout-seconds) playback_timeout=$2 ;;
        --adb) FRANKEL_AUDIO_ADB=$2 ;;
        --serial) FRANKEL_AUDIO_SERIAL=$2 ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$2 ;;
      esac
      shift 2 ;;
    --permissive-capture) permissive_capture=true; shift ;;
    --) shift; break ;;
    -h|--help) usage; exit 0 ;;
    *) frankel_audio_die "unknown option: $1" ;;
  esac
done
[[ -n "$output_directory" && $# -gt 0 ]] || { usage >&2; exit 2; }
frankel_audio_require_positive_integer timeout-seconds "$playback_timeout"
for utility in python3 setsid timeout awk rg; do
  command -v "$utility" >/dev/null || frankel_audio_die "missing host command: $utility"
done
[[ ! -e "$output_directory" ]] || frankel_audio_die "output directory must be new"
mkdir -p -- "$(dirname -- "$output_directory")"
mkdir -- "$output_directory"
output_directory=$(cd -- "$output_directory" && pwd -P)

operation=0
binder_reply_file=
remote_directory=
original_selinux=
restore_selinux=false
tap_owned=false
recording=false
io_started=false
playback_pid=
captures_pulled=false

binder_call() {
  local label=$1 raw decoded
  shift
  operation=$((operation + 1))
  raw="$output_directory/$(printf '%02d' "$operation")-$label.parcel.txt"
  decoded="${raw%.parcel.txt}.txt"
  binder_reply_file=$decoded
  frankel_audio_remote_exec service call "$aocx_service" "$@" >"$raw" || return
  python3 "$decoder" <"$raw" >"$decoded" || { cat "$decoded" >&2; return 1; }
  cat "$decoded"
}

cleanup() {
  local result=$? failed=0 current deadline
  trap - EXIT HUP INT TERM
  set +e
  if [[ -n "$playback_pid" ]]; then
    kill -TERM -- "-$playback_pid" 2>/dev/null
    deadline=$((SECONDS + 10))
    while kill -0 -- "-$playback_pid" 2>/dev/null && ((SECONDS < deadline)); do
      sleep 0.1
    done
    if kill -0 -- "-$playback_pid" 2>/dev/null; then
      kill -KILL -- "-$playback_pid" 2>/dev/null
      printf 'Playback ignored TERM for 10 seconds; forced termination may have interrupted its own route cleanup.\n' >&2
      failed=1
    fi
    # Do not block tap/SELinux restoration on an unkillable host child.
    if ! kill -0 "$playback_pid" 2>/dev/null; then
      wait "$playback_pid" 2>/dev/null
    fi
  fi
  if $recording; then
    binder_call cleanup-record-stop 24 i32 2 s16 capture s16 stop || failed=1
  fi
  if $io_started; then
    binder_call cleanup-io-stop 23 i32 20 || failed=1
  fi
  if $tap_owned; then
    binder_call cleanup-tap-disable 16 i32 2 i32 "$speaker_tag" i32 0 i32 0 || failed=1
    binder_call cleanup-unbind 21 i32 2 i32 "$speaker_tag" i32 0 i32 -1 i32 -1 || failed=1
    binder_call cleanup-tap-info 15 i32 2 i32 "$speaker_tag" i32 0 || failed=1
    binder_call cleanup-buffers 18 || failed=1
  fi
  if $restore_selinux; then
    frankel_audio_remote_exec setenforce 1 || failed=1
    current=$(frankel_audio_remote_exec getenforce)
    [[ "$current" == Enforcing ]] || failed=1
  fi
  if [[ -n "$remote_directory" ]] && ! $captures_pulled; then
    mkdir -p -- "$output_directory/captures"
    frankel_audio_adb pull "$remote_directory/." "$output_directory/captures/" || failed=1
  fi
  if ((failed)); then
    printf 'Cleanup incomplete; inspect %s and restore device state before another run.\n' "$output_directory" >&2
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

frankel_audio_initialize_device service getenforce setenforce mktemp
[[ $(frankel_audio_remote_exec getprop ro.vendor.build.id) == CP2A.260805.005 ]] ||
  frankel_audio_die "this wrapper is pinned to Frankel vendor CP2A.260805.005"
[[ $(frankel_audio_remote_exec getprop init.svc.aocxd) == running ]] ||
  frankel_audio_die "stock aocxd must already be running"
frankel_audio_remote_exec service check "$aocx_service" |
  rg -q 'found' || frankel_audio_die "AoCx Binder service is absent"

# No pre-existing processor/buffer work may be interrupted by the recorder's
# all-buffer parser. Validate both buffer lists before acquiring the tap.
for list_transaction in 18 19; do
  # Keep calls in this shell so the evidence sequence counter is retained.
  binder_call "initial-buffers-$list_transaction" "$list_transaction" >/dev/null
  awk '
    /^[[:space:]]*[0-9]+[[:space:]]+(tapout|inject)[0-9]+[[:space:]]/ {
      seen++; if ($3 != "-" || $4 != "-" || $5 != "0") exit 1
    }
    END { if (!seen) exit 1 }
  ' "$binder_reply_file" || frankel_audio_die "AoCx buffers are already connected/active or table is unknown"
done
binder_call initial-tap-info 15 i32 2 i32 "$speaker_tag" i32 0 >/dev/null
awk '
  $1 == "sspk.0" { seen++; if ($(NF-2) != "-" || $(NF-1) != "-" || $NF != "0") exit 1 }
  END { if (seen != 1) exit 1 }
' "$binder_reply_file" || frankel_audio_die "sspk.0 must be disabled and unbound"
original_selinux=$(frankel_audio_remote_exec getenforce)
printf 'original_selinux=%s\n' "$original_selinux" >"$output_directory/run.txt"
printf 'playback_command=' >>"$output_directory/run.txt"
printf '%q ' "$@" >>"$output_directory/run.txt"
printf '\n' >>"$output_directory/run.txt"
case "$original_selinux" in
  Enforcing)
    if $permissive_capture; then
      restore_selinux=true
      frankel_audio_remote_exec setenforce 0
    fi ;;
  Permissive|Disabled) ;;
  *) frankel_audio_die "unknown SELinux state: $original_selinux" ;;
esac
remote_directory=$(frankel_audio_remote_exec mktemp -d /data/vendor/audio/powerphone-sspk.XXXXXX)
[[ "$remote_directory" =~ ^/data/vendor/audio/powerphone-sspk\.[A-Za-z0-9]+$ ]] ||
  frankel_audio_die "unexpected remote capture directory"
printf 'remote_directory=%s\n' "$remote_directory" >>"$output_directory/run.txt"
tap_owned=true
binder_call bind 21 i32 2 i32 "$speaker_tag" i32 0 i32 20 i32 -1
binder_call tap-enable 16 i32 2 i32 "$speaker_tag" i32 0 i32 1
recording=true
binder_call record-start 24 i32 3 s16 capture s16 start s16 "$remote_directory/sspk"
if rg -iq 'error|failed|already enabled' "$binder_reply_file"; then
  frankel_audio_die "AoCx could not open capture files (see --permissive-capture)"
fi
io_started=true
binder_call io-start 22 i32 20
binder_call active-buffers 18
binder_call active-tap-info 15 i32 2 i32 "$speaker_tag" i32 0

export FRANKEL_AUDIO_ADB FRANKEL_AUDIO_SERIAL FRANKEL_AUDIO_ADB_SERVER_PORT
frankel_audio_note "Recording sspk.0; playback output goes to $output_directory/playback.log"
setsid timeout --signal=TERM --kill-after=10 "$playback_timeout" "$@" \
  >"$output_directory/playback.log" 2>&1 &
playback_pid=$!
playback_result=0
wait "$playback_pid" || playback_result=$?
playback_pid=
printf 'playback_exit_status=%s\n' "$playback_result" >>"$output_directory/run.txt"
sleep 1
binder_call record-stop 24 i32 2 s16 capture s16 stop
recording=false
binder_call io-stop 23 i32 20
io_started=false
mkdir -- "$output_directory/captures"
frankel_audio_adb pull "$remote_directory/." "$output_directory/captures/"
captures_pulled=true
[[ -s "$output_directory/captures/sspk_tapout20.wav" ]] ||
  frankel_audio_die "speaker tap produced no WAV file"
frankel_audio_note "Speaker tap: $output_directory/captures/sspk_tapout20.wav"
exit "$playback_result"
