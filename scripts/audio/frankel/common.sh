# shellcheck shell=bash

# Shared, Frankel-only tinyALSA helpers.  This file is sourced by the playback,
# capture, and reset wrappers; it must never contact a device while sourced.

frankel_audio_common_source=${BASH_SOURCE[0]}
frankel_audio_directory=$(cd -- "${frankel_audio_common_source%/*}" && pwd -P)
frankel_audio_project_root=$(cd -- "$frankel_audio_directory/../../.." && pwd -P)
unset frankel_audio_common_source

readonly FRANKEL_AUDIO_CARD=0
# Frankel PCM hardware constraints observed through ALSA hw_params.
readonly FRANKEL_AUDIO_PERIOD_BYTES_MAX=15360
readonly FRANKEL_AUDIO_BUFFER_BYTES_MAX=98304
# The following constants are consumed by scripts that source this file.
# shellcheck disable=SC2034
readonly FRANKEL_AUDIO_PLAYBACK_DEVICE=28
# shellcheck disable=SC2034
readonly FRANKEL_AUDIO_PRIMARY_CAPTURE_DEVICE=8
# shellcheck disable=SC2034
readonly FRANKEL_AUDIO_RAW192_CAPTURE_DEVICE=10
# shellcheck disable=SC2034
readonly FRANKEL_AUDIO_ULTRASOUND_CAPTURE_DEVICE=12
# shellcheck disable=SC2034
readonly FRANKEL_AUDIO_REMOTE_DIRECTORY=/data/local/tmp

declare -ag FRANKEL_AUDIO_SNAPSHOT_NAMES=()
declare -ag FRANKEL_AUDIO_SNAPSHOT_MODES=()
declare -ag FRANKEL_AUDIO_SNAPSHOT_VALUES=()
declare -ag FRANKEL_AUDIO_SAFE_NAMES=()
declare -ag FRANKEL_AUDIO_SAFE_VALUES=()
declare -ag FRANKEL_AUDIO_REMOTE_TEMP_FILES=()
declare -ag FRANKEL_AUDIO_LOCAL_TEMP_FILES=()
FRANKEL_AUDIO_CLEANUP_ARMED=false
FRANKEL_AUDIO_CLEANUP_RUNNING=false

frankel_audio_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

frankel_audio_note() {
  printf '==> %s\n' "$*"
}

frankel_audio_require_integer() {
  local label=$1
  local value=$2
  [[ "$value" =~ ^[0-9]+$ ]] || \
    frankel_audio_die "$label must be a non-negative integer: $value"
}

frankel_audio_require_positive_integer() {
  local label=$1
  local value=$2
  frankel_audio_require_integer "$label" "$value"
  (( value > 0 )) || frankel_audio_die "$label must be greater than zero"
}

frankel_audio_rate_enum() {
  case "$1" in
    48000) printf '%s\n' SR_48K ;;
    96000) printf '%s\n' SR_96K ;;
    192000) printf '%s\n' SR_192K ;;
    *) frankel_audio_die "rate must be one of 48000, 96000, or 192000" ;;
  esac
}

frankel_audio_channel_enum() {
  case "$1" in
    1) printf '%s\n' One ;;
    2) printf '%s\n' Two ;;
    3) printf '%s\n' Three ;;
    4) printf '%s\n' Four ;;
    *) frankel_audio_die "channels must be between 1 and 4" ;;
  esac
}

frankel_audio_playback_format_enum() {
  case "$1" in
    s16) printf '%s\n' S16_LE ;;
    s24) printf '%s\n' S24_3LE ;;
    s32) printf '%s\n' S32_LE ;;
    *) frankel_audio_die "format must be s16, s24, or s32" ;;
  esac
}

frankel_audio_capture_format_enum() {
  case "$1" in
    s16) printf '%s\n' S16_LE ;;
    # tinycap's -b 24 selects S24_LE (24 significant bits in a 32-bit slot).
    s24) printf '%s\n' S24_LE ;;
    s32) printf '%s\n' S32_LE ;;
    *) frankel_audio_die "format must be s16, s24, or s32" ;;
  esac
}

frankel_audio_format_bits() {
  case "$1" in
    s16) printf '%s\n' 16 ;;
    s24) printf '%s\n' 24 ;;
    s32) printf '%s\n' 32 ;;
    *) frankel_audio_die "format must be s16, s24, or s32" ;;
  esac
}

frankel_audio_capture_wav_bits() {
  case "$1" in
    s16) printf '%s\n' 16 ;;
    # tinycap writes S24_LE in a four-byte container and labels the WAV 32-bit.
    s24|s32) printf '%s\n' 32 ;;
    *) frankel_audio_die "format must be s16, s24, or s32" ;;
  esac
}

frankel_audio_playback_sample_bytes() {
  case "$1" in
    s16) printf '%s\n' 2 ;;
    s24) printf '%s\n' 3 ;;
    s32) printf '%s\n' 4 ;;
    *) frankel_audio_die "format must be s16, s24, or s32" ;;
  esac
}

frankel_audio_capture_sample_bytes() {
  case "$1" in
    s16) printf '%s\n' 2 ;;
    # tinycap maps -b 24 to S24_LE in a four-byte container.
    s24|s32) printf '%s\n' 4 ;;
    *) frankel_audio_die "format must be s16, s24, or s32" ;;
  esac
}

frankel_audio_validate_period_geometry() {
  local channels=$1
  local sample_bytes=$2
  local period_size=$3
  local period_count=$4
  local frame_bytes max_period_frames period_bytes max_period_count buffer_bytes

  frame_bytes=$((channels * sample_bytes))
  max_period_frames=$((FRANKEL_AUDIO_PERIOD_BYTES_MAX / frame_bytes))
  (( period_size <= max_period_frames )) || \
    frankel_audio_die \
      "period-size $period_size exceeds $max_period_frames frames for ${channels}ch/${sample_bytes}-byte samples (${FRANKEL_AUDIO_PERIOD_BYTES_MAX}-byte period limit)"
  period_bytes=$((period_size * frame_bytes))
  max_period_count=$((FRANKEL_AUDIO_BUFFER_BYTES_MAX / period_bytes))
  (( period_count <= max_period_count )) || \
    frankel_audio_die \
      "period-count $period_count exceeds $max_period_count at period-size $period_size (${FRANKEL_AUDIO_BUFFER_BYTES_MAX}-byte buffer limit)"
  buffer_bytes=$((period_bytes * period_count))
  frankel_audio_note \
    "PCM geometry: period=${period_bytes}B, buffer=${buffer_bytes}B (limits ${FRANKEL_AUDIO_PERIOD_BYTES_MAX}B/${FRANKEL_AUDIO_BUFFER_BYTES_MAX}B)"
}

frankel_audio_remote_quote() {
  local value=$1
  [[ "$value" != *"'"* && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || \
    frankel_audio_die "unsupported character in remote command argument"
  printf "'%s'" "$value"
}

frankel_audio_remote_command() {
  local command='' argument quoted
  for argument in "$@"; do
    quoted=$(frankel_audio_remote_quote "$argument")
    if [[ -n "$command" ]]; then
      command+=" "
    fi
    command+="$quoted"
  done
  printf '%s\n' "$command"
}

frankel_audio_adb() {
  local -a command=(
    timeout --signal=TERM "${FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS:-20}"
    env
    "ADB_LIBUSB=${FRANKEL_AUDIO_ADB_LIBUSB:-1}"
    "$FRANKEL_AUDIO_ADB"
    -P "${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}"
  )
  if [[ -n ${FRANKEL_AUDIO_SERIAL:-} ]]; then
    command+=(-s "$FRANKEL_AUDIO_SERIAL")
  fi
  "${command[@]}" "$@"
}

frankel_audio_remote_exec() {
  local command
  command=$(frankel_audio_remote_command "$@")
  frankel_audio_adb shell "$command"
}

frankel_audio_tinymix_get() {
  frankel_audio_remote_exec /system/bin/tinymix -D "$FRANKEL_AUDIO_CARD" \
    -v -- "$1"
}

frankel_audio_tinymix_set() {
  local control=$1
  shift
  frankel_audio_remote_exec /system/bin/tinymix -D "$FRANKEL_AUDIO_CARD" \
    -- "$control" "$@" >/dev/null
}

frankel_audio_initialize_device() {
  FRANKEL_AUDIO_ADB=${FRANKEL_AUDIO_ADB:-\
"$frankel_audio_project_root/work/toolchains/platform-tools/adb"}
  [[ -x "$FRANKEL_AUDIO_ADB" ]] || \
    frankel_audio_die "adb is not executable: $FRANKEL_AUDIO_ADB"
  command -v timeout >/dev/null 2>&1 || \
    frankel_audio_die "required host command not found: timeout"

  local state device boot_completed uid utility
  state=$(frankel_audio_adb get-state 2>/dev/null) || \
    frankel_audio_die "no unambiguous ADB device is reachable"
  [[ "$state" == device ]] || frankel_audio_die "ADB target is not online"
  device=$(frankel_audio_remote_exec getprop ro.product.device)
  [[ "$device" == frankel ]] || \
    frankel_audio_die "refusing non-Frankel target (ro.product.device=$device)"
  boot_completed=$(frankel_audio_remote_exec getprop sys.boot_completed)
  [[ "$boot_completed" == 1 ]] || \
    frankel_audio_die "Frankel has not completed boot"
  uid=$(frankel_audio_remote_exec id -u)
  [[ "$uid" == 0 ]] || \
    frankel_audio_die "root ADB is required; run '$FRANKEL_AUDIO_ADB root' first"
  for utility in tinymix "$@"; do
    frankel_audio_remote_exec test -x "/system/bin/$utility" || \
      frankel_audio_die "/system/bin/$utility is unavailable"
  done
}

frankel_audio_arm_cleanup() {
  FRANKEL_AUDIO_CLEANUP_ARMED=true
  trap frankel_audio_exit_handler EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

frankel_audio_snapshot_scalar() {
  local control=$1
  local value
  value=$(frankel_audio_tinymix_get "$control") || \
    frankel_audio_die "cannot read mixer control: $control"
  # tinymix prints Boolean values as On/Off but accepts only numeric values
  # when setting a Boolean control. Store a setter-compatible snapshot.
  case "$value" in
    On) value=1 ;;
    Off) value=0 ;;
  esac
  FRANKEL_AUDIO_SNAPSHOT_NAMES+=("$control")
  FRANKEL_AUDIO_SNAPSHOT_MODES+=(scalar)
  FRANKEL_AUDIO_SNAPSHOT_VALUES+=("$value")
}

frankel_audio_snapshot_vector() {
  local control=$1
  local value
  value=$(frankel_audio_tinymix_get "$control") || \
    frankel_audio_die "cannot read mixer control: $control"
  [[ "$value" =~ ^-?[0-9]+([[:space:]]+-?[0-9]+)+$ ]] || \
    frankel_audio_die "unexpected vector value for $control: $value"
  FRANKEL_AUDIO_SNAPSHOT_NAMES+=("$control")
  FRANKEL_AUDIO_SNAPSHOT_MODES+=(vector)
  FRANKEL_AUDIO_SNAPSHOT_VALUES+=("$value")
}

frankel_audio_snapshot_and_set_scalar() {
  local control=$1
  local value=$2
  frankel_audio_snapshot_scalar "$control"
  frankel_audio_tinymix_set "$control" "$value"
}

frankel_audio_snapshot_and_set_vector() {
  local control=$1
  shift
  frankel_audio_snapshot_vector "$control"
  frankel_audio_tinymix_set "$control" "$@"
}

frankel_audio_register_safe_control() {
  FRANKEL_AUDIO_SAFE_NAMES+=("$1")
  FRANKEL_AUDIO_SAFE_VALUES+=("$2")
}

frankel_audio_register_remote_temp() {
  FRANKEL_AUDIO_REMOTE_TEMP_FILES+=("$1")
}

frankel_audio_register_local_temp() {
  FRANKEL_AUDIO_LOCAL_TEMP_FILES+=("$1")
}

frankel_audio_require_control_value() {
  local control=$1
  local expected=$2
  local actual
  actual=$(frankel_audio_tinymix_get "$control") || \
    frankel_audio_die "cannot read mixer control: $control"
  [[ "$actual" == "$expected" ]] || \
    frankel_audio_die "$control is already active ($actual); stop other audio first"
}

frankel_audio_require_control_zero() {
  local control=$1
  local actual
  actual=$(frankel_audio_tinymix_get "$control") || \
    frankel_audio_die "cannot read mixer control: $control"
  [[ "$actual" == 0 || "$actual" == Off ]] || \
    frankel_audio_die "$control is already active ($actual); stop other audio first"
}

frankel_audio_cleanup() {
  [[ "$FRANKEL_AUDIO_CLEANUP_ARMED" == true && \
     "$FRANKEL_AUDIO_CLEANUP_RUNNING" == false ]] || return 0
  FRANKEL_AUDIO_CLEANUP_RUNNING=true

  local index control value mode remote_file local_file remote_script='' remote_command
  for ((index = 0; index < ${#FRANKEL_AUDIO_SAFE_NAMES[@]}; index++)); do
    control=${FRANKEL_AUDIO_SAFE_NAMES[index]}
    value=${FRANKEL_AUDIO_SAFE_VALUES[index]}
    remote_command=$(frankel_audio_remote_command /system/bin/tinymix \
      -D "$FRANKEL_AUDIO_CARD" -- "$control" "$value")
    remote_script+="$remote_command >/dev/null 2>&1 || :; "
  done

  for ((index = ${#FRANKEL_AUDIO_SNAPSHOT_NAMES[@]} - 1; index >= 0; index--)); do
    control=${FRANKEL_AUDIO_SNAPSHOT_NAMES[index]}
    value=${FRANKEL_AUDIO_SNAPSHOT_VALUES[index]}
    mode=${FRANKEL_AUDIO_SNAPSHOT_MODES[index]}
    if [[ "$mode" == vector ]]; then
      local -a vector_values=()
      read -r -a vector_values <<<"$value"
      remote_command=$(frankel_audio_remote_command /system/bin/tinymix \
        -D "$FRANKEL_AUDIO_CARD" -- "$control" "${vector_values[@]}")
    else
      remote_command=$(frankel_audio_remote_command /system/bin/tinymix \
        -D "$FRANKEL_AUDIO_CARD" -- "$control" "$value")
    fi
    remote_script+="$remote_command >/dev/null 2>&1 || :; "
  done

  for remote_file in "${FRANKEL_AUDIO_REMOTE_TEMP_FILES[@]}"; do
    remote_command=$(frankel_audio_remote_command /system/bin/rm -f "$remote_file")
    remote_script+="$remote_command >/dev/null 2>&1 || :; "
  done
  if [[ -n "$remote_script" ]]; then
    FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=15 \
      frankel_audio_adb shell "$remote_script" >/dev/null 2>&1 || true
  fi
  for local_file in "${FRANKEL_AUDIO_LOCAL_TEMP_FILES[@]}"; do
    rm -f -- "$local_file" >/dev/null 2>&1 || true
  done
  FRANKEL_AUDIO_CLEANUP_RUNNING=false
}

frankel_audio_finish_cleanup() {
  frankel_audio_cleanup
  local verification_status=0
  frankel_audio_verify_safe_controls || verification_status=$?
  FRANKEL_AUDIO_CLEANUP_ARMED=false
  trap - EXIT HUP INT TERM
  (( verification_status == 0 )) || return "$verification_status"
}

frankel_audio_verify_safe_controls() {
  local verification_script='' remote_command output index
  local -a actual_values=()
  for ((index = 0; index < ${#FRANKEL_AUDIO_SAFE_NAMES[@]}; index++)); do
    remote_command=$(frankel_audio_remote_command /system/bin/tinymix \
      -D "$FRANKEL_AUDIO_CARD" -v -- "${FRANKEL_AUDIO_SAFE_NAMES[index]}")
    verification_script+="$remote_command || exit; "
  done
  if ! output=$(FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=15 \
      frankel_audio_adb shell "$verification_script"); then
    printf 'error: cleanup ran, but its final mixer state could not be read back\n' \
      >&2
    return 1
  fi
  mapfile -t actual_values <<<"$output"
  if (( ${#actual_values[@]} != ${#FRANKEL_AUDIO_SAFE_NAMES[@]} )); then
    printf 'error: cleanup read-back returned an unexpected control count\n' >&2
    return 1
  fi
  for ((index = 0; index < ${#FRANKEL_AUDIO_SAFE_NAMES[@]}; index++)); do
    local actual=${actual_values[index]}
    local expected=${FRANKEL_AUDIO_SAFE_VALUES[index]}
    if [[ "$expected" == 0 && ( "$actual" == 0 || "$actual" == Off ) ]]; then
      continue
    fi
    if [[ "$expected" == 1 && ( "$actual" == 1 || "$actual" == On ) ]]; then
      continue
    fi
    if [[ "$actual" != "$expected" ]]; then
      printf 'error: cleanup did not make %s safe (expected %s, got %s)\n' \
        "${FRANKEL_AUDIO_SAFE_NAMES[index]}" \
        "$expected" "$actual" >&2
      return 1
    fi
  done
}

frankel_audio_remote_cleanup_body() {
  local index control value command='' quoted_control quoted_value
  for ((index = 0; index < ${#FRANKEL_AUDIO_SAFE_NAMES[@]}; index++)); do
    control=${FRANKEL_AUDIO_SAFE_NAMES[index]}
    value=${FRANKEL_AUDIO_SAFE_VALUES[index]}
    quoted_control=$(frankel_audio_remote_quote "$control")
    quoted_value=$(frankel_audio_remote_quote "$value")
    command+="/system/bin/tinymix -D ${FRANKEL_AUDIO_CARD} -- ${quoted_control} ${quoted_value} >/dev/null 2>&1 || :; "
  done
  printf '%s\n' "$command"
}

frankel_audio_run_guarded() {
  local cleanup_body run_command script
  cleanup_body=$(frankel_audio_remote_cleanup_body)
  run_command=$(frankel_audio_remote_command "$@")
  script="cleanup() { ${cleanup_body} }; trap cleanup EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; ${run_command}; status=\$?; cleanup; trap - EXIT HUP INT TERM; exit \$status"
  FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=${FRANKEL_AUDIO_STREAM_TIMEOUT_SECONDS:-360} \
    frankel_audio_adb shell "$script"
}

# Raise a single mixer control and start the stream in the same remote shell
# transaction. Some AoC endpoints arm a watchdog as soon as their route is
# bound, so a second adb invocation between tinymix and tinyplay is too late.
frankel_audio_run_guarded_after_control() {
  local control=$1
  local value=$2
  shift 2
  local cleanup_body activate_command run_command script
  cleanup_body=$(frankel_audio_remote_cleanup_body)
  activate_command=$(frankel_audio_remote_command /system/bin/tinymix \
    -D "$FRANKEL_AUDIO_CARD" -- "$control" "$value")
  run_command=$(frankel_audio_remote_command "$@")
  script="cleanup() { ${cleanup_body} }; trap cleanup EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; ${activate_command} >/dev/null && ${run_command}; status=\$?; cleanup; trap - EXIT HUP INT TERM; exit \$status"
  FRANKEL_AUDIO_ADB_TIMEOUT_SECONDS=${FRANKEL_AUDIO_STREAM_TIMEOUT_SECONDS:-360} \
    frankel_audio_adb shell "$script"
}

# shellcheck disable=SC2317
frankel_audio_exit_handler() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  frankel_audio_cleanup
  exit "$status"
}
