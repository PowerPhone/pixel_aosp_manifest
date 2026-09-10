#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
observer="$project_root/scripts/audio/frankel/observe-aoc-up-ring.sh"
parser="$project_root/scripts/audio/frankel/parse-aoc-services-up-ring.awk"
fixture="$project_root/scripts/tests/fixtures/frankel-aoc-services.txt"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ -x "$observer" ]] || fail 'AoC ring observer is missing or not executable'
[[ -r "$parser" ]] || fail 'AoC services parser is missing'
[[ -r "$fixture" ]] || fail 'AoC services fixture is missing'

expected='1 92160 92160 512 4294967040 768 768 0'
actual=$(awk -v target=ultrasonic_capture -f "$parser" "$fixture")
[[ "$actual" == "$expected" ]] || \
  fail "unexpected wraparound parse: $actual"

# Exact-name matching must not confuse a prefix service. This record also
# exercises capacity clamping and the explicit overflow bit.
expected='2 64 128 200 20 180 128 1'
actual=$(awk -v target=ultrasonic_capture_debug -f "$parser" "$fixture")
[[ "$actual" == "$expected" ]] || \
  fail "unexpected overflow parse: $actual"

if awk -v target=missing_service -f "$parser" "$fixture" \
    >/dev/null 2>&1; then
  fail 'missing service passed parsing'
fi

if printf '%s\n' \
    'Services : 1' \
    '0 : "ultrasonic_capture" mbox 6' \
    ' Up Size:1x92160B Tx:not-a-counter Rx:0' | \
    awk -v target=ultrasonic_capture -f "$parser" >/dev/null 2>&1; then
  fail 'malformed target Up ring passed parsing'
fi

# Help must remain dry even with an intentionally unusable ADB path.
FRANKEL_AUDIO_ADB=/definitely/not/adb "$observer" --help >/dev/null

if grep -Eq 'acd-factory_diag|CMD_DBG|tinymix|setprop|/sys/.+>' "$observer"; then
  fail 'observer contains a prohibited AoC/control/write path'
fi

printf 'Frankel AoC ring observer simulation: PASS\n'
