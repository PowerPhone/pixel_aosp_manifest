#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_directory/common.sh"

usage() {
  cat <<'USAGE'
Usage: reset-routes.sh [--adb PATH] [--serial SERIAL] [--adb-server-port PORT]

Frankel-only recovery helper. It forces off only the tinyALSA research routes
and physical power controls managed by this directory:

  * both CS35L43 amp switches and ultrasonic modes
  * TDM_0_RX Mixer US
  * EP1/EP5 internal-mic routes and US Record Enable
  * supported MIC0 through MIC2 manual power controls

The unsupported logical MIC3 control is never accessed.

It does not restore rates, formats, source selectors, gains, or capture lists;
the normal play/capture wrappers snapshot and restore those. --help is dry and
does not start ADB or contact a device.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --adb|--serial|--adb-server-port)
      (( $# >= 2 )) || frankel_audio_die "missing value for $1"
      case "$1" in
        --adb) FRANKEL_AUDIO_ADB=$2 ;;
        --serial) FRANKEL_AUDIO_SERIAL=$2 ;;
        --adb-server-port) FRANKEL_AUDIO_ADB_SERVER_PORT=$2 ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) frankel_audio_die "unknown argument: $1 (use --help)" ;;
  esac
done

# No streaming utility is needed beyond the tinymix baseline checked by init.
# shellcheck disable=SC2119
frankel_audio_initialize_device

controls=(
  'Main AMP Enable Switch'
  'R Main AMP Enable Switch'
  'TDM_0_RX Mixer US'
  'Ultrasonic Mode'
  'R Ultrasonic Mode'
  'EP1 TX Mixer INTERNAL_MIC_TX'
  'EP5 TX Mixer INTERNAL_MIC_US_TX'
  'US Record Enable'
  MIC0
  MIC1
  MIC2
)
values=(
  0
  0
  0
  Disabled
  Disabled
  0
  0
  0
  0
  0
  0
)

failures=0
for ((index = 0; index < ${#controls[@]}; index++)); do
  frankel_audio_register_safe_control "${controls[index]}" "${values[index]}"
  if ! frankel_audio_tinymix_set "${controls[index]}" "${values[index]}"; then
    printf 'warning: failed to reset mixer control: %s\n' \
      "${controls[index]}" >&2
    failures=$((failures + 1))
  fi
done
(( failures == 0 )) || frankel_audio_die "$failures mixer control reset(s) failed"
frankel_audio_verify_safe_controls || \
  frankel_audio_die "route reset could not be verified"
frankel_audio_note "Frankel research amps, ultrasound routes, and mic power controls are off"
