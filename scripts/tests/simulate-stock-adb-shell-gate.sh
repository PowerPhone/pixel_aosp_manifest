#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
helper="$project_root/scripts/lib/stock-adb-shell.sh"
mock_adb="$test_dir/mock-adb.sh"
scratch_dir=$(mktemp -d)
trap 'rm -rf -- "$scratch_dir"' EXIT

mkdir -p "$scratch_dir/state"
printf 'android\n' >"$scratch_dir/state/mode"
: >"$scratch_dir/adb-mutations.log"

run_helper() (
  local shell_mode=$1 command_log=$2
  die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
  }
  # shellcheck source=../lib/stock-adb-shell.sh disable=SC1091
  source "$helper"
  MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
  MOCK_ADB_LOG="$scratch_dir/adb-mutations.log" \
  MOCK_ADB_COMMAND_LOG="$command_log" \
  MOCK_ADB_SERIAL=MOCK_CUBS_SERIAL \
  MOCK_ADB_STOCK_SHELL_MODE="$shell_mode" \
    cubs_require_normal_stock_adb_shell "$mock_adb" MOCK_CUBS_SERIAL
)

normal_log="$scratch_dir/normal.commands"
: >"$normal_log"
run_helper normal "$normal_log"
[[ $(<"$normal_log") == 'shell -T -x true' ]] || {
  printf 'error: normal-shell gate issued an unexpected command\n' >&2
  exit 1
}

tradein_log="$scratch_dir/tradein.commands"
: >"$tradein_log"
if run_helper tradein "$tradein_log" \
    >"$scratch_dir/tradein.out" 2>"$scratch_dir/tradein.err"; then
  printf 'error: Trade-In Mode passed the normal-shell gate\n' >&2
  exit 1
fi
grep -Fq 'restricted Trade-In Mode foyer' "$scratch_dir/tradein.err"
grep -Fq 'finish Setup Wizard' "$scratch_dir/tradein.err"
grep -Fq 'then enable normal USB debugging' "$scratch_dir/tradein.err"
[[ $(<"$tradein_log") == $'shell -T -x true\nshell tradeinmode getstatus' ]] || {
  printf 'error: Trade-In Mode diagnostic was not the exact read-only pair\n' >&2
  exit 1
}

closed_log="$scratch_dir/closed.commands"
: >"$closed_log"
if run_helper closed "$closed_log" \
    >"$scratch_dir/closed.out" 2>"$scratch_dir/closed.err"; then
  printf 'error: an unavailable normal shell passed its gate\n' >&2
  exit 1
fi
grep -Fq 'cannot open a normal shell' "$scratch_dir/closed.err"
grep -Fq 'finish Setup Wizard' "$scratch_dir/closed.err"
grep -Fq 'then enable normal USB debugging' "$scratch_dir/closed.err"
[[ $(<"$closed_log") == $'shell -T -x true\nshell tradeinmode getstatus' ]] || {
  printf 'error: closed-shell diagnostic was not the exact read-only pair\n' >&2
  exit 1
}

if grep -Eq '(^|[[:space:]])evaluate($|[[:space:]])' \
    "$normal_log" "$tradein_log" "$closed_log"; then
  printf 'error: stock-ADB gate invoked the destructive Trade-In action\n' >&2
  exit 1
fi

# Exercise the current stock-Android restore finalizer in an isolated project
# copy. Patch only the copy's ADB digest to the host mock, so the action cannot
# select the real USB transport. It must stop at the shared guard before
# publishing recovery evidence or reaching any reboot command. The retired
# Android/two-slot-lpdump stock-A attestation action is deliberately not used.
fixture="$scratch_dir/project"
mkdir -p "$fixture/config/targets/cubs" "$fixture/scripts/lib" \
  "$fixture/.cache"
cp -- "$project_root/config/release.env" "$fixture/config/release.env"
cp -- "$project_root/config/targets/cubs/release.env" \
  "$fixture/config/targets/cubs/release.env"
cp -- "$project_root/config/recovery.env" "$fixture/config/recovery.env"
cp -- "$project_root/scripts/restore-stock.sh" \
  "$fixture/scripts/restore-stock.sh"
cp -- "$project_root/scripts/lib/common.sh" "$fixture/scripts/lib/common.sh"
cp -- "$project_root/scripts/lib/target-profile.sh" \
  "$fixture/scripts/lib/target-profile.sh"
cp -- "$project_root/scripts/lib/recovery-handoff.sh" \
  "$fixture/scripts/lib/recovery-handoff.sh"
cp -- "$helper" "$fixture/scripts/lib/stock-adb-shell.sh"
mock_sha=$(sha256sum "$mock_adb" | awk '{print $1}')
sed -i \
  "s/^PLATFORM_TOOLS_ADB_SHA256=.*/PLATFORM_TOOLS_ADB_SHA256=$mock_sha/" \
  "$fixture/config/release.env"

run_production_gate() {
  local script=$1 command_log=$2 recovery_dir=$3
  shift 3
  MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
  MOCK_ADB_LOG="$scratch_dir/adb-mutations.log" \
  MOCK_ADB_COMMAND_LOG="$command_log" \
  MOCK_ADB_SERIAL=MOCK_CUBS_SERIAL \
  MOCK_ADB_STOCK_SHELL_MODE=tradein \
  ADB="$mock_adb" \
  CUBS_RECOVERY_STATE_DIR="$recovery_dir" \
  PIXEL_TARGET=cubs \
    "$script" "$@"
}

restore_log="$scratch_dir/restore.commands"
: >"$restore_log"
mkdir -p "$fixture/.cache/restore"
printf '%s\n' \
  'schema=cubs-stock-restore-v2' \
  'state=awaiting_stock_android' \
  'active-restore-sentinel=unchanged' \
  >"$fixture/.cache/restore/stock-restore-transaction"
chmod 0600 "$fixture/.cache/restore/stock-restore-transaction"
restore_receipt_sha=$(sha256sum \
  "$fixture/.cache/restore/stock-restore-transaction" | awk '{print $1}')
if CUBS_ALLOW_STOCK_RESTORE_FINALIZE=1 \
    CUBS_RESTORE_CONFIRM=FINALIZE_EXACT_STOCK_A_RESTORE_AFTER_SUCCESSFUL_ANDROID_BOOT \
    run_production_gate "$fixture/scripts/restore-stock.sh" \
      "$restore_log" "$fixture/.cache/restore" finalize-stock-android \
      >"$scratch_dir/restore.out" 2>"$scratch_dir/restore.err"; then
  printf 'error: stock-restore finalizer accepted Trade-In Mode\n' >&2
  exit 1
fi
grep -Fq 'restricted Trade-In Mode foyer' "$scratch_dir/restore.err"
[[ $(<"$restore_log") == $'shell -T -x true\nshell tradeinmode getstatus' ]]
[[ $(sha256sum "$fixture/.cache/restore/stock-restore-transaction" | \
      awk '{print $1}') == "$restore_receipt_sha" ]]

[[ ! -s "$scratch_dir/adb-mutations.log" ]] || {
  printf 'error: stock-ADB shell simulation reached a device mutation\n' >&2
  exit 1
}
if grep -Eq '(^|[[:space:]])evaluate($|[[:space:]])' \
    "$restore_log"; then
  printf 'error: a production preflight invoked the destructive Trade-In action\n' >&2
  exit 1
fi

printf 'stock ADB normal-shell and Trade-In Mode gates passed\n'
