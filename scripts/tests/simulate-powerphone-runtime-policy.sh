#!/usr/bin/env bash
# The quoted fragments below are intentional literal source contracts.
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
runtime="$project_root/scripts/audio/frankel/powerphone-runtime.sh"
raw_wrapper="$project_root/scripts/audio/frankel/raw-pdm-capture.sh"
kernel_source="$project_root/tools/audio/kernel/frankel_pdm_alsa/frankel_pdm_alsa.c"
speaker_guard_source="$project_root/tools/audio/device/frankel_aoc_speaker_patch/frankel_aoc_speaker_patch.cpp"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function_body() {
  local name=$1
  sed -n "/^${name}() {\$/,/^}\$/p" "$runtime"
}

line_of() {
  local literal=$1
  local body=$2
  local line
  line=$(grep -n -F -m1 -- "$literal" <<<"$body" | cut -d: -f1) || return 1
  printf '%s\n' "$line"
}

assert_order() {
  local body=$1
  shift
  local previous=0 literal line
  for literal in "$@"; do
    line=$(line_of "$literal" "$body") || \
      fail "missing ordered runtime contract: $literal"
    (( line > previous )) || \
      fail "runtime contract is out of order: $literal"
    previous=$line
  done
}

[[ -x "$runtime" ]] || fail 'PowerPhone runtime broker is missing or not executable'

for property in \
  'vendor.powerphone.pdm.topology_ready' \
  'vendor.powerphone.pdm.ready' \
  'vendor.powerphone.aoc_speaker_192k.ready'; do
  [[ $(grep -Fc -- "=$property" "$runtime") -eq 1 ]] || \
    fail "missing or duplicate exact property constant: $property"
done

# Different audit epochs must not bypass mutation serialization. The local
# lock remains necessary because the PDM snapshot belongs to that epoch.
global_lock_line=$(grep -n -F -m1 \
  '.powerphone-runtime.global.lock' "$runtime" | cut -d: -f1)
epoch_lock_line=$(grep -n -F -m1 \
  '.powerphone-runtime.lock' "$runtime" | cut -d: -f1)
(( global_lock_line > 0 && epoch_lock_line > global_lock_line )) || \
  fail 'global lock is absent or acquired after the epoch-local lock'

# Clearing the data gate lets the HAL close its proxy. Polling must remain
# alive until closure is proven, or a blocked capture can be stranded forever.
pdm_deactivate_body=$(function_body powerphone_pdm_deactivate)
assert_order "$pdm_deactivate_body" \
  'powerphone_set_property "$POWERPHONE_PDM_PROPERTY" 0' \
  'powerphone_wait_card1_closed' \
  'powerphone_write_polling 0' \
  'powerphone_require_card1_closed' \
  'pdm-deactivate-check-idle' \
  'powerphone_clear_status_probe' \
  'powerphone_restore_mics_after_idle'

pdm_recovery_body=$(function_body powerphone_recover_pdm_activation)
assert_order "$pdm_recovery_body" \
  'powerphone_set_property "$POWERPHONE_PDM_PROPERTY" 0' \
  'powerphone_wait_card1_closed' \
  'powerphone_write_polling 0' \
  'powerphone_card1_closed_soft' \
  'powerphone_run_a32 revert' \
  'powerphone_clear_status_probe' \
  'powerphone_restore_mics_after_idle'

speaker_deactivate_body=$(function_body powerphone_speaker_deactivate)
assert_order "$speaker_deactivate_body" \
  'powerphone_set_property "$POWERPHONE_SPEAKER_PROPERTY" 0' \
  'powerphone_wait_speaker_closed' \
  'AoC memory was not changed'
if grep -Fq 'powerphone_run_speaker' <<<"$speaker_deactivate_body"; then
  fail 'unqualified speaker deactivation can still mutate AoC memory'
fi

# Frankel omits pcm0p/sub0/status while the PCM is closed. Both strict and
# retrying host guards must delegate closure to the same native certifier;
# shell path/readlink guesses are not a complete process-owner proof.
speaker_require_closed_body=$(function_body powerphone_require_speaker_closed)
speaker_soft_closed_body=$(function_body powerphone_speaker_closed_soft)
for body in "$speaker_require_closed_body" "$speaker_soft_closed_body"; do
  grep -Fq '"$POWERPHONE_SPEAKER_GUARD"' <<<"$body" || \
    fail 'speaker closure does not require the transient native certifier'
  grep -Fq 'check-playback-closed' <<<"$body" || \
    fail 'speaker closure does not invoke the read-only native ownership proof'
  if grep -Fq '/proc/asound/card0/pcm28p/sub0/status' <<<"$body"; then
    fail 'speaker closure still treats the optional proc status file as mandatory'
  fi
done

speaker_fd_scan_body=$(sed -n \
  '/^bool CheckNoPlaybackFileDescriptor(/,/^}/p' "$speaker_guard_source")
assert_order "$speaker_fd_scan_body" \
  'getuid() != 0 || geteuid() != 0' \
  'opendir("/proc")' \
  'opendir(fd_directory_path.c_str())' \
  'fstatat(dirfd(descriptors.get())' \
  'descriptor_status.st_rdev == playback_device'
grep -Fq 'error_number == ENOENT' <<<"$speaker_fd_scan_body" || \
  fail 'native fd scan does not explicitly isolate vanished procfs races'
grep -Fq 'ValidatePlaybackPcmInventory' "$speaker_guard_source" || \
  fail 'native speaker guard lacks exact ALSA inventory validation'
grep -Fq 'major(status.st_rdev) != kPlaybackDeviceMajor' \
  "$speaker_guard_source" || \
  fail 'native speaker guard lacks exact character-device identity validation'
speaker_closed_body=$(sed -n \
  '/^bool CheckPlaybackClosed(/,/^}/p' "$speaker_guard_source")
assert_order "$speaker_closed_body" \
  'CheckPlaybackIdentity(&before, error)' \
  'CheckPlaybackStatus(error)' \
  'CheckNoPlaybackFileDescriptor(before.character_device, error)' \
  'CheckPlaybackIdentity(&after, error)'
speaker_run_body=$(sed -n '/^int Run(/,/^}/p' "$speaker_guard_source")
assert_order "$speaker_run_body" \
  'action_text == "check-playback-closed"' \
  'CheckTarget(false, error) || !CheckPlaybackClosed(error)' \
  'Generation generation{}' \
  'Preflight(allow_incomplete_boot, &generation, error)'
speaker_closure_branch=${speaker_run_body#*'action_text == "check-playback-closed"'}
speaker_closure_branch=${speaker_closure_branch%%'Generation generation{}'*}
if grep -Eq 'Preflight|FactoryDiag|ReadGeneration|ReadStates' \
    <<<"$speaker_closure_branch"; then
  fail 'read-only PCM closure action can reach AoC state/diagnostic access'
fi

# Publishing a ready bit is not the final proof. Recheck the live controller
# or AoC words while activation rollback is still armed.
pdm_activate_body=$(function_body powerphone_pdm_activate)
assert_order "$pdm_activate_body" \
  'powerphone_require_mic_states 0 0 0' \
  'powerphone_create_mic_snapshot' \
  'powerphone_power_mics_on' \
  'powerphone_update_mic_snapshot prepared powered' \
  'pdm-check-idle-after-mic-power' \
  'powerphone_run_a32 apply' \
  'powerphone_run_status_probe' \
  'pdm-check-active-after-status-probe' \
  'powerphone_write_polling 1' \
  'powerphone_set_property "$POWERPHONE_PDM_PROPERTY" 1'
pdm_activate_after_polling=${pdm_activate_body#*'powerphone_write_polling 1'}
[[ "$pdm_activate_after_polling" != "$pdm_activate_body" ]] || \
  fail 'PDM activation does not enable polling'
grep -Fq 'powerphone_require_boolean_parameter status_probe 0' \
  <<<"$pdm_activate_after_polling" || \
  fail 'PDM activation does not prove one-shot status token consumption'
pdm_activate_after_ready=${pdm_activate_body#*'powerphone_set_property "$POWERPHONE_PDM_PROPERTY" 1'}
[[ "$pdm_activate_after_ready" != "$pdm_activate_body" ]] || \
  fail 'PDM activation does not publish the exact readiness property'
assert_order "$pdm_activate_after_ready" \
  'powerphone_collect_state post' \
  'pdm-check-active-after-ready' \
  '"$POWERPHONE_PDM_PROPERTY final state"' \
  'cleanup_mode=none'

speaker_activate_body=$(function_body powerphone_speaker_activate)
grep -Fq 'integrated speaker activation is unqualified and disabled' \
  <<<"$speaker_activate_body" || \
  fail 'unqualified speaker activation is not explicitly fail-closed'
if grep -Fq 'powerphone_set_property "$POWERPHONE_SPEAKER_PROPERTY" 1' \
    "$runtime"; then
  fail 'host runtime can publish unqualified speaker readiness'
fi
if grep -Fq 'patch_frankel_aoc_live_speaker_192k.py' "$runtime"; then
  fail 'host runtime still invokes the weaker Python speaker writer'
fi

# Every state read is checked before it is written to the audit file, and the
# top-level tee is joined so an audit-writer error cannot report success.
collect_body=$(function_body powerphone_collect_state)
grep -Fq 'powerphone_collect_command' <<<"$collect_body" || \
  fail 'state collection does not use checked commands'
if grep -Fq '"$(powerphone_' <<<"$collect_body"; then
  fail 'state collection masks a PowerPhone read inside printf'
fi
close_log_body=$(function_body powerphone_close_transaction_log)
grep -Fq 'wait "$transaction_tee_pid"' <<<"$close_log_body" || \
  fail 'transaction log writer is not joined'

# The kernel permission proof is synchronous and status-only. It cannot call
# the FIFO-pop path or wake/start the poll worker, and polling consumes exactly
# one completed proof before publishing its request.
status_probe_body=$(sed -n \
  '/^static int status_probe_set(/,/^}/p' "$kernel_source")
grep -Fq 'controller->base + PDM_FIFO_STATUS_OFFSET' \
  <<<"$status_probe_body" || fail 'kernel status probe lacks the +0x10 status read'
if grep -Eq 'PDM_FIFO_DATA_OFFSET|poll_one_controller|wake_up|consume_fifo' \
    <<<"$status_probe_body"; then
  fail 'kernel status probe can reach FIFO data or polling-worker code'
fi
polling_body=$(sed -n '/^static int polling_set(/,/^}/p' "$kernel_source")
assert_order "$polling_body" \
  '!READ_ONCE(status_probe_completed)' \
  'WRITE_ONCE(status_probe_completed, false)' \
  'WRITE_ONCE(polling_requested, true)' \
  'wake_up_all(&polling_waitq)'

# The manual path must also prove status-only counter behavior before its first
# destructive polling transition.
raw_apply_line=$(grep -n -F -m1 \
  'raw_pdm_a32 apply --ack-hardware-write --ack-ap-consumer-ready' \
  "$raw_wrapper" | cut -d: -f1)
raw_probe_line=$(grep -n -F -m1 'raw_pdm_run_status_probe ||' \
  "$raw_wrapper" | cut -d: -f1)
(( raw_apply_line > 0 && raw_probe_line > raw_apply_line )) || \
  fail 'manual raw-PDM status proof is absent or precedes A32 apply'
# The exact remote printf includes a shell variable, so use the main-path
# status-token consumption check as the final ordering anchor.
raw_consume_line=$(grep -n -F \
  'raw_pdm_require_boolean_parameter status_probe 0' "$raw_wrapper" | \
  tail -n1 | cut -d: -f1)
(( raw_consume_line > raw_probe_line )) || \
  fail 'manual raw-PDM path does not prove status token consumption after probe'

grep -Fq 'status/probe counts are' "$raw_wrapper" || \
  fail 'manual status-only proof lacks exact fresh status/probe counts'
grep -Fq 'destructive/data counter' "$raw_wrapper" || \
  fail 'manual status-only proof lacks zero destructive/data counters'
grep -Fq 'status-read delta is not exactly one' "$runtime" || \
  fail 'integrated status-only proof lacks exact status delta checks'
grep -Fq 'changed during status-only probe' "$runtime" || \
  fail 'integrated status-only proof lacks unchanged data-counter checks'

printf 'PowerPhone runtime policy checks passed\n'
