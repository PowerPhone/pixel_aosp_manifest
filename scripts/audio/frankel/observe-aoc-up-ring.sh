#!/usr/bin/env bash
# Read-only host observer for one Frankel AoC service's Up ring.
# ADB-selection globals are consumed indirectly by sourced common helpers.
# shellcheck disable=SC2034
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

readonly FRANKEL_AOC_SERVICES_PATH=/sys/devices/platform/9000000.aoc/services
readonly FRANKEL_AOC_OBSERVER_EXPECTED_DEVICE=frankel
readonly FRANKEL_AOC_OBSERVER_EXPECTED_BUILD=CP2A.260805.005
readonly FRANKEL_AOC_OBSERVER_EXPECTED_BUILD_TYPE=userdebug
readonly FRANKEL_AOC_OBSERVER_EXPECTED_DEBUGGABLE=1
readonly FRANKEL_AOC_OBSERVER_PARSER="$script_directory/parse-aoc-services-up-ring.awk"

usage() {
  cat <<'USAGE'
Usage:
  observe-aoc-up-ring.sh [options]

Options:
  --service NAME            Exact AoC service name (default: ultrasonic_capture).
  --interval-ms INTEGER     Start-to-start polling interval (default: 25).
  --count INTEGER           Number of samples (default: 400).
  --adb PATH                adb binary (default: work/toolchains/platform-tools/adb).
  --serial SERIAL           Select one device without printing its identifier.
  --adb-server-port PORT    Existing ADB server port (default: 5038).
  -h, --help                Show this text without contacting a device.

TSV is written to stdout. Redirect it to retain an observation. Each row
contains host_time_ns, unsigned Tx/Rx delta, capacity, clamped availability,
and an overflow flag. Diagnostics are written to stderr.

This tool only reads:
  /sys/devices/platform/9000000.aoc/services

It does not open the AoC factory-diagnostic device, issue an AoC command,
change a mixer control, or write sysfs. It is locked to the reviewed Frankel
CP2A.260805.005 userdebug build and requires an already-root ADB shell.
USAGE
}

service=ultrasonic_capture
interval_ms=25
count=400
FRANKEL_AUDIO_ADB_SERVER_PORT=${FRANKEL_AUDIO_ADB_SERVER_PORT:-5038}

while (( $# > 0 )); do
  case "$1" in
    --service|--interval-ms|--count|--adb|--serial|--adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      option=$1
      value=$2
      shift 2
      case "$option" in
        --service) service=$value ;;
        --interval-ms) interval_ms=$value ;;
        --count) count=$value ;;
        --adb) FRANKEL_AUDIO_ADB=$value ;;
        --serial) FRANKEL_AUDIO_SERIAL=$value ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$value ;;
      esac
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) frankel_audio_die "unknown argument: $1 (use --help)" ;;
  esac
done

[[ "$service" =~ ^[A-Za-z0-9_.-]+$ ]] || \
  frankel_audio_die 'service must contain only letters, digits, dot, underscore, or hyphen'
frankel_audio_require_positive_integer interval-ms "$interval_ms"
(( interval_ms <= 60000 )) || \
  frankel_audio_die 'interval-ms must not exceed 60000'
frankel_audio_require_positive_integer count "$count"
(( count <= 1000000 )) || frankel_audio_die 'count must not exceed 1000000'
frankel_audio_require_positive_integer adb-server-port "$FRANKEL_AUDIO_ADB_SERVER_PORT"
(( FRANKEL_AUDIO_ADB_SERVER_PORT <= 65535 )) || \
  frankel_audio_die 'adb-server-port must not exceed 65535'

[[ -r "$FRANKEL_AOC_OBSERVER_PARSER" ]] || \
  frankel_audio_die "parser is unavailable: $FRANKEL_AOC_OBSERVER_PARSER"
for utility in awk date sleep; do
  command -v "$utility" >/dev/null 2>&1 || \
    frankel_audio_die "required host command not found: $utility"
done

frankel_audio_initialize_device cat

observer_require_property() {
  local property=$1
  local expected=$2
  local actual
  actual=$(frankel_audio_remote_exec getprop "$property") || \
    frankel_audio_die "cannot read $property"
  [[ "$actual" == "$expected" ]] || \
    frankel_audio_die \
      "refusing target with $property=$actual (expected $expected)"
}

observer_require_property ro.product.device "$FRANKEL_AOC_OBSERVER_EXPECTED_DEVICE"
observer_require_property ro.build.id "$FRANKEL_AOC_OBSERVER_EXPECTED_BUILD"
observer_require_property ro.vendor.build.id "$FRANKEL_AOC_OBSERVER_EXPECTED_BUILD"
observer_require_property ro.build.type "$FRANKEL_AOC_OBSERVER_EXPECTED_BUILD_TYPE"
observer_require_property ro.debuggable "$FRANKEL_AOC_OBSERVER_EXPECTED_DEBUGGABLE"
frankel_audio_remote_exec /system/bin/test -r "$FRANKEL_AOC_SERVICES_PATH" || \
  frankel_audio_die "AoC services attribute is not readable: $FRANKEL_AOC_SERVICES_PATH"

now_ns=$(date +%s%N)
[[ "$now_ns" =~ ^[0-9]+$ ]] || \
  frankel_audio_die 'host date does not support nanosecond epoch output'
start_ns=$now_ns
interval_ns=$((interval_ms * 1000000))

printf '# device=%s build=%s service=%s interval_ms=%s count=%s\n' \
  "$FRANKEL_AOC_OBSERVER_EXPECTED_DEVICE" \
  "$FRANKEL_AOC_OBSERVER_EXPECTED_BUILD" "$service" "$interval_ms" "$count"
printf '%s\n' \
  $'sample\thost_time_ns\telapsed_ns\tservice\tslots\tslot_bytes\tcapacity_bytes\ttx\trx\tdelta_bytes\tavailable_bytes\toverflow'

for ((sample = 1; sample <= count; sample++)); do
  deadline_ns=$((start_ns + (sample - 1) * interval_ns))
  now_ns=$(date +%s%N)
  if (( now_ns < deadline_ns )); then
    remaining_ns=$((deadline_ns - now_ns))
    printf -v sleep_duration '%d.%09d' \
      "$((remaining_ns / 1000000000))" "$((remaining_ns % 1000000000))"
    sleep "$sleep_duration"
  fi

  host_time_ns=$(date +%s%N)
  if ! services_snapshot=$(
      frankel_audio_remote_exec /system/bin/cat "$FRANKEL_AOC_SERVICES_PATH"
    ); then
    frankel_audio_die "sample $sample: cannot read AoC services attribute"
  fi
  if ! parsed=$(
      awk -v target="$service" -f "$FRANKEL_AOC_OBSERVER_PARSER" \
        <<<"$services_snapshot"
    ); then
    frankel_audio_die "sample $sample: invalid or unavailable Up-ring snapshot"
  fi
  read -r slots slot_bytes capacity tx rx delta available overflow <<<"$parsed"
  [[ -n ${overflow:-} ]] || \
    frankel_audio_die "sample $sample: parser returned an incomplete record"

  printf '%d\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sample" "$host_time_ns" "$((host_time_ns - start_ns))" "$service" \
    "$slots" "$slot_bytes" "$capacity" "$tx" "$rx" "$delta" \
    "$available" "$overflow"
done
