#!/usr/bin/env bash
# Literal source-contract fragments intentionally retain shell metacharacters.
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source_dir="$project_root/tools/audio/device/frankel_powerphone_d10_bootstrap"
vendor_rc="$source_dir/frankel_powerphone_d10_bootstrap.rc"
system_gate="$source_dir/frankel_powerphone_audioserver_gate.rc"
source_file="$source_dir/frankel_powerphone_d10_bootstrap.cpp"
patch_source="$project_root/tools/audio/device/frankel_aoc_d10_patch/frankel_aoc_d10_patch.cpp"
speaker_patch_source="$project_root/tools/audio/device/frankel_aoc_speaker_patch/frankel_aoc_speaker_patch.cpp"
speaker_patch_model="$project_root/tools/audio/device/frankel_aoc_speaker_patch/patch_model.cpp"
speaker_patch_model_header="$project_root/tools/audio/device/frankel_aoc_speaker_patch/patch_model.h"
audio_kernel_builder="$project_root/scripts/audio/build-frankel-kernel.sh"
diag_source="$project_root/tools/audio/device/frankel_aoc_diag/frankel_aoc_diag.cpp"
sanitizer="$project_root/scripts/sanitize-generated-vendor-frankel.sh"
build_closure="$project_root/scripts/lib/frankel-powerphone-build-closure.sh"
policy="$source_dir/sepolicy/frankel_powerphone_d10_bootstrap.te"
property_contexts="$source_dir/sepolicy/property_contexts"
blueprint="$source_dir/Android.bp"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

action_commands() {
  local path=$1 trigger=$2
  awk -v trigger="$trigger" '
    $0 == trigger { in_action = 1; next }
    in_action && /^on / { exit }
    in_action && /^[[:space:]]+(setprop|stop|wait_for_prop|exec_start|start)[[:space:]]/ {
      sub(/^[[:space:]]+/, "")
      print
    }
  ' "$path"
}

# Vendor init may define and start the vendor service and arm the boot-local
# latch, but it must neither consume private platform service state nor write
# either certifier property.
if grep -Eq 'init\.svc\.audioserver|^[[:space:]]*(start|stop) audioserver|^[[:space:]]*setprop vendor\.powerphone\.(pdm\.ready|aoc_speaker_192k\.ready)' \
    "$vendor_rc"; then
  fail 'vendor RC crosses the init/property Treble boundary'
fi

grep -Fq 'system_ext_specific: true' "$blueprint" || \
  fail 'audioserver gate is not installed in system_ext'
grep -Fq 'frankel_powerphone_audioserver_gate' "$blueprint" || \
  fail 'bootstrap does not require the system-side gate'
transaction_trigger='on property:vendor.powerphone.bootstrap.attempted=0 && property:vendor.powerphone.bootstrap.phase=armed && property:vendor.powerphone.bootstrap.watchdog_expired=0 && property:init.svc.vendor.powerphone-bootstrap-watchdog=running && property:init.svc.aocd=running && property:init.svc.vendor.audio-hal-aidl=running && property:init.svc.audioserver=stopped'
attempt1_trigger='on property:vendor.powerphone.bootstrap.phase=attempt1 && property:init.svc.vendor.powerphone-d10-bootstrap=stopped'
attempt2_trigger='on property:vendor.powerphone.bootstrap.phase=attempt2 && property:init.svc.vendor.powerphone-d10-bootstrap-retry-1=stopped'
attempt3_trigger='on property:vendor.powerphone.bootstrap.phase=attempt3 && property:init.svc.vendor.powerphone-d10-bootstrap-retry-2=stopped'
release_trigger='on property:vendor.powerphone.bootstrap.phase=finalizing && property:init.svc.vendor.powerphone-d10-bootstrap-finalize=stopped'
watchdog_trigger='on property:vendor.powerphone.bootstrap.watchdog_expired=1 && property:vendor.powerphone.bootstrap.attempted=0 && property:vendor.powerphone.bootstrap.phase=armed'
watchdog_stopped_trigger='on property:init.svc.vendor.powerphone-bootstrap-watchdog=stopped && property:vendor.powerphone.bootstrap.attempted=0 && property:vendor.powerphone.bootstrap.watchdog_expired=0 && property:vendor.powerphone.bootstrap.phase=armed'
for trigger in \
  'on early-init' \
  "$transaction_trigger" \
  "$attempt1_trigger" \
  "$attempt2_trigger" \
  "$attempt3_trigger" \
  "$release_trigger" \
  "$watchdog_trigger" \
  "$watchdog_stopped_trigger"; do
  [[ $(grep -Fxc -- "$trigger" "$system_gate") -eq 1 ]] || \
    fail "missing or duplicate system-side gate trigger: $trigger"
done
for service in \
  'service vendor.powerphone-d10-bootstrap ' \
  'service vendor.powerphone-d10-bootstrap-retry-1 ' \
  'service vendor.powerphone-d10-bootstrap-retry-2 ' \
  'service vendor.powerphone-d10-bootstrap-finalize ' \
  'service vendor.powerphone-bootstrap-watchdog '; do
  [[ $(grep -Fc -- "$service" "$vendor_rc") -eq 1 ]] || \
    fail "missing or duplicate bounded bootstrap service: $service"
done
transaction_commands=$(action_commands "$system_gate" "$transaction_trigger")
expected_transaction_commands=$'setprop vendor.powerphone.bootstrap.attempted 1\nstop vendor.powerphone-bootstrap-watchdog\nstop audioserver\nwait_for_prop init.svc.audioserver stopped\nstop vendor.audio-hal-powerphone\nwait_for_prop init.svc.vendor.audio-hal-powerphone stopped\nsetprop vendor.powerphone.bootstrap.phase attempt1\nstart vendor.powerphone-d10-bootstrap'
[[ "$transaction_commands" == "$expected_transaction_commands" ]] || \
  fail 'gate does not launch the first certification attempt asynchronously'
[[ $(grep -Ec '^on property:' "$system_gate") -eq 7 ]] || \
  fail 'gate contains an unreviewed property trigger'

[[ $(action_commands "$system_gate" "$attempt1_trigger") == \
  $'setprop vendor.powerphone.bootstrap.phase attempt2\nstart vendor.powerphone-d10-bootstrap-retry-1' ]] || \
  fail 'attempt 1 completion does not publish phase then asynchronously launch attempt 2'
[[ $(action_commands "$system_gate" "$attempt2_trigger") == \
  $'setprop vendor.powerphone.bootstrap.phase attempt3\nstart vendor.powerphone-d10-bootstrap-retry-2' ]] || \
  fail 'attempt 2 completion does not publish phase then asynchronously launch attempt 3'
[[ $(action_commands "$system_gate" "$attempt3_trigger") == \
  $'setprop vendor.powerphone.bootstrap.phase finalizing\nstart vendor.powerphone-d10-bootstrap-finalize' ]] || \
  fail 'attempt 3 completion does not publish phase then asynchronously launch the finalizer'

release_commands=$(action_commands "$system_gate" "$release_trigger")
expected_release_commands=$'setprop vendor.powerphone.bootstrap.phase releasing\nstop audioserver\nwait_for_prop init.svc.audioserver stopped\nstop vendor.audio-hal-powerphone\nwait_for_prop init.svc.vendor.audio-hal-powerphone stopped\nstart vendor.audio-hal-powerphone\nstart audioserver\nsetprop vendor.powerphone.bootstrap.phase complete'
[[ "$release_commands" == "$expected_release_commands" ]] || \
  fail 'finalizer completion does not atomically reset audio lifetimes and release boot'

watchdog_commands=$(action_commands "$system_gate" "$watchdog_trigger")
expected_watchdog_commands=$'setprop vendor.powerphone.bootstrap.attempted 1\nstop audioserver\nwait_for_prop init.svc.audioserver stopped\nstop vendor.audio-hal-powerphone\nwait_for_prop init.svc.vendor.audio-hal-powerphone stopped\nsetprop vendor.powerphone.bootstrap.phase finalizing\nstart vendor.powerphone-d10-bootstrap-finalize'
[[ "$watchdog_commands" == "$expected_watchdog_commands" ]] || \
  fail 'watchdog does not asynchronously launch certificate-aware fail-open'
watchdog_stopped_commands=$(action_commands "$system_gate" "$watchdog_stopped_trigger")
[[ "$watchdog_stopped_commands" == "$expected_watchdog_commands" ]] || \
  fail 'unexpected watchdog exit does not asynchronously launch fail-open'

# Main, release, and two watchdog launch paths reap both services. Only the
# finalizer completion action creates one fresh sidecar/audioserver pair.
[[ $(grep -Fxc '    stop vendor.audio-hal-powerphone' "$system_gate") -eq 4 ]] || \
  fail 'gate does not stop the PowerPhone sidecar at every transaction boundary'
[[ $(grep -Fxc '    wait_for_prop init.svc.vendor.audio-hal-powerphone stopped' \
     "$system_gate") -eq 4 ]] || \
  fail 'gate does not reap the PowerPhone sidecar at every transaction boundary'
[[ $(grep -Fxc '    start vendor.audio-hal-powerphone' "$system_gate") -eq 1 ]] || \
  fail 'gate must start exactly one fresh PowerPhone sidecar at final release'
if grep -Fq 'wait_for_prop init.svc.vendor.audio-hal-powerphone running' \
    "$system_gate"; then
  fail 'gate adds an unbounded wait after synchronous init service start'
fi
[[ $(grep -Fxc '    stop audioserver' "$system_gate") -eq 5 ]] || \
  fail 'gate must stop audioserver at early-init and every transaction boundary'
[[ $(grep -Fxc '    wait_for_prop init.svc.audioserver stopped' \
     "$system_gate") -eq 4 ]] || \
  fail 'gate does not reap audioserver at every transaction boundary'
if grep -Eq '^[[:space:]]*exec_start[[:space:]]' "$system_gate"; then
  fail 'gate blocks init with synchronous service execution'
fi
if grep -Fqx 'on boot' "$system_gate"; then
  fail 'gate starts the synchronous transaction before AoC and the audio HAL are running'
fi
if grep -Fqx \
    'on property:init.svc.vendor.audio-hal-aidl=running && property:init.svc.audioserver=stopped' \
    "$system_gate"; then
  fail 'gate can block init before the late_start AoC firmware daemon runs'
fi
[[ $(grep -Fxc '    setprop vendor.powerphone.bootstrap.attempted 0' \
     "$vendor_rc") -eq 1 ]] || fail 'vendor post-fs-data does not arm the boot latch once'
[[ $(grep -Fxc \
     '    setprop persist.vendor.aoc.firmware.force_nominal_voltage 1' \
     "$vendor_rc") -eq 1 ]] || \
  fail 'vendor post-fs-data does not force AoC nominal voltage exactly once'
vnom_line=$(grep -n -F -m1 \
  'setprop persist.vendor.aoc.firmware.force_nominal_voltage 1' \
  "$vendor_rc" | cut -d: -f1)
watchdog_reset_line=$(grep -n -F -m1 \
  'setprop vendor.powerphone.bootstrap.watchdog_expired 0' \
  "$vendor_rc" | cut -d: -f1)
phase_arm_line=$(grep -n -F -m1 \
  'setprop vendor.powerphone.bootstrap.phase armed' \
  "$vendor_rc" | cut -d: -f1)
latch_arm_line=$(grep -n -F -m1 \
  'setprop vendor.powerphone.bootstrap.attempted 0' \
  "$vendor_rc" | cut -d: -f1)
(( vnom_line < watchdog_reset_line && watchdog_reset_line < phase_arm_line && \
   phase_arm_line < latch_arm_line )) || \
  fail 'vendor post-fs-data does not force VNOM before initializing and arming the boot gate'
[[ $(grep -Fxc '    start vendor.powerphone-bootstrap-watchdog' \
     "$vendor_rc") -eq 1 ]] || fail 'vendor post-fs-data does not start the bounded watchdog once'
grep -Fqx \
  'vendor.powerphone.bootstrap.attempted u:object_r:vendor_powerphone_bootstrap_attempted_prop:s0 exact bool' \
  "$property_contexts" || fail 'boot latch lacks an exact Boolean property label'
grep -Fqx \
  'vendor_internal_prop(vendor_powerphone_bootstrap_attempted_prop)' \
  "$policy" || fail 'boot latch is not a vendor-internal property'
grep -Fqx \
  'set_prop(vendor_init, vendor_powerphone_bootstrap_attempted_prop)' \
  "$policy" || fail 'vendor init cannot arm the boot latch'
grep -Fqx \
  'get_prop(frankel_powerphone_d10_bootstrap, vendor_powerphone_bootstrap_attempted_prop)' \
  "$policy" || fail 'confined watchdog cannot read the boot latch'
grep -Fqx \
  'vendor.powerphone.bootstrap.watchdog_expired u:object_r:vendor_powerphone_bootstrap_watchdog_prop:s0 exact bool' \
  "$property_contexts" || fail 'watchdog expiration lacks an exact Boolean property label'
grep -Fqx \
  'vendor_internal_prop(vendor_powerphone_bootstrap_watchdog_prop)' \
  "$policy" || fail 'watchdog expiration is not a vendor-internal property'
grep -Fqx \
  'set_prop(frankel_powerphone_d10_bootstrap, vendor_powerphone_bootstrap_watchdog_prop)' \
  "$policy" || fail 'confined watchdog cannot publish expiration'
grep -Fqx \
  'set_prop(vendor_init, vendor_powerphone_bootstrap_watchdog_prop)' \
  "$policy" || fail 'vendor init cannot clear watchdog expiration before re-arm'
grep -Fqx \
  'vendor.powerphone.bootstrap.phase u:object_r:vendor_powerphone_bootstrap_phase_prop:s0 exact enum armed attempt1 attempt2 attempt3 finalizing releasing complete' \
  "$property_contexts" || fail 'asynchronous bootstrap phase lacks an exact enum label'
grep -Fqx \
  'vendor_internal_prop(vendor_powerphone_bootstrap_phase_prop)' \
  "$policy" || fail 'asynchronous bootstrap phase is not vendor-internal'
grep -Fqx \
  'set_prop(vendor_init, vendor_powerphone_bootstrap_phase_prop)' \
  "$policy" || fail 'vendor/platform init cannot advance the asynchronous bootstrap phase'
for watchdog_contract in \
  '--watchdog-fail-open' \
  'kWatchdogAttempts = 600' \
  'Property(kBootstrapAttemptedProperty) == "1"' \
  'SetPropertyChecked(kWatchdogExpiredProperty, "1")' \
  'boot prerequisites did not converge within 60 seconds'; do
  grep -Fq -- "$watchdog_contract" "$source_file" || \
    fail "native watchdog lacks bounded fail-open contract: $watchdog_contract"
done
if grep -Fq 'Property(kBootstrapAttemptedProperty) != "0"' "$source_file"; then
  fail 'watchdog treats a missing or denied latch read as already claimed'
fi
for aocd_contract in \
  'service aocd /vendor/bin/aocd' \
  'class late_start' \
  'Frankel PowerPhone requires automatically started stock aocd'; do
  grep -Fq -- "$aocd_contract" "$sanitizer" || \
    fail "sanitizer does not bind the extracted aocd prerequisite: $aocd_contract"
done
for restart_rc in \
  'android.hardware.audio.service-aidl.aoc.rc' \
  'vendor.google.whitechapel.audio.hal.parserservice.rc'; do
  grep -Fq -- "$restart_rc" "$sanitizer" || \
    fail "sanitizer does not select the audioserver restart policy for $restart_rc"
done
for restart_policy_contract in \
  "powerphone_audioserver_restart_stock='    onrestart restart audioserver'" \
  "powerphone_audioserver_restart_guarded='    onrestart restart --only-if-running audioserver'" \
  'select_powerphone_audioserver_restart_policy()' \
  'audioserver restart policy does not match POWERPHONE_AUDIO_SIDECAR='; do
  grep -Fq -- "$restart_policy_contract" "$sanitizer" || \
    fail "sanitizer lacks reversible audioserver restart policy contract: $restart_policy_contract"
done
for closure_contract in \
  'frankel_powerphone_require_audioserver_restart_policy()' \
  'frankel_powerphone_require_sidecar_boot_lifecycle()' \
  'wait_for_prop init.svc.audioserver stopped' \
  'wait_for_prop init.svc.vendor.audio-hal-powerphone stopped' \
  "expected_audio_restart_line='    onrestart restart --only-if-running audioserver'" \
  "rejected_audio_restart_line='    onrestart restart audioserver'" \
  "stock_audio_hal_rc_target='VENDOR/etc/init/android.hardware.audio.service-aidl.aoc.rc'" \
  "parser_rc_target='SYSTEM_EXT/etc/init/vendor.google.whitechapel.audio.hal.parserservice.rc'"; do
  grep -Fq -- "$closure_contract" "$build_closure" || \
    fail "build closure lacks audioserver restart policy contract: $closure_contract"
done
# Execute the packaging-time semantic check against the canonical gate too;
# source/installed/target equality then carries this exact lifecycle into the
# shipped image.
# shellcheck source=scripts/lib/frankel-powerphone-build-closure.sh
source "$build_closure"
frankel_powerphone_require_sidecar_boot_lifecycle \
  "$system_gate" 'canonical PowerPhone audioserver gate RC' || \
  fail 'build closure rejected the canonical sidecar lifecycle'
[[ $(grep -Fxc '    start audioserver' "$system_gate") -eq 2 ]] || \
  fail 'gate must start audioserver only for qualified warm-up and final release'
if grep -Fq 'on property:init.svc.audioserver=running && property:vendor.powerphone.pdm.ready=0' \
    "$system_gate"; then
  fail 'continuous fail-closed audioserver stop defeats the bounded fallback'
fi
[[ $(grep -Fxc '    start vendor.powerphone-d10-bootstrap-finalize' \
     "$system_gate") -eq 4 ]] || \
  fail 'gate does not asynchronously run the finalizer after warm-up failure, attempts, and both watchdog exits'
grep -Fq -- '--finalize-fail-open' "$vendor_rc" || \
  fail 'vendor RC does not invoke native finalizer mode'
grep -Fq 'if (finalize_fail_open)' "$source_file" || \
  fail 'native bootstrap lacks certificate-aware finalizer mode'
grep -Fq 'certification succeeded; preserving PCM quarantine' "$source_file" || \
  fail 'successful finalizer does not preserve PCM quarantine'
grep -Fq 'if (errno == ENOENT)' "$source_file" || \
  fail 'fail-open finalizer does not accept a PCM absent before card creation'
grep -Fq 'PCM absent; no mode to restore:' "$source_file" || \
  fail 'fail-open finalizer does not report absent PCM nodes precisely'
grep -Fq 'refusing to restore non-character PCM path:' "$source_file" || \
  fail 'fail-open finalizer does not reject an unexpected path type'
for fail_open_contract in \
  'certification failed; revoked readiness and ' \
  'restored stock PCM modes'; do
  grep -Fq -- "$fail_open_contract" "$source_file" || \
    fail "fail-open finalizer lacks readiness revocation: $fail_open_contract"
done
for node in pcmC0D8c pcmC0D9c pcmC0D12c pcmC0D31p; do
  grep -Fq "/dev/snd/$node" "$source_file" || \
    fail "native fail-open does not cover /dev/snd/$node"
done
if grep -Eq '^[[:space:]]*chmod 0660 /dev/snd/' "$system_gate"; then
  fail 'unconditional init chmod would undo quarantine after success'
fi
grep -Fq 'both profiles were already certified by an earlier attempt' "$source_file" || \
  fail 'retry invocations do not preserve an existing certification'
if grep -Eq '^on .*property:sys\.boot_completed' "$system_gate" ||
    grep -Fq 'Property("sys.boot_completed")' "$source_file"; then
  fail 'bootstrap reintroduced the circular sys.boot_completed prerequisite'
fi

# The native patch helper must remain boot-complete gated for all standalone
# actions. Only bootstrap apply gets the explicit, parser-restricted exception.
grep -Fq '!allow_incomplete_boot &&' "$patch_source" || \
  fail 'patch helper no longer preserves its standalone boot guard'
grep -Fq '!GetPropertyExact("sys.boot_completed", "1", error)' "$patch_source" || \
  fail 'patch helper no longer requires standalone boot completion'
grep -Fq 'std::string_view(argv[2]) == "--allow-incomplete-boot"' "$patch_source" || \
  fail 'patch helper does not parse the early-boot exception explicitly'
grep -Fq 'if (argc == 3 && (!allow_incomplete_boot || action != "apply"))' \
  "$patch_source" || \
  fail 'patch helper does not restrict the early-boot exception to apply'
[[ $(grep -Fc '"--allow-incomplete-boot"' "$source_file") -eq 2 ]] || \
  fail 'bootstrap must pass the early-boot exception on both apply exec paths'
grep -Fq 'execl(helper, helper, action, "--allow-incomplete-boot",' \
  "$source_file" || \
  fail 'bootstrap apply does not pass the explicit early-boot exception'
grep -Fq 'RunPatchHelper(kSpeakerPatchHelper, "apply", true)' "$source_file" || \
  fail 'bootstrap does not apply the speaker profile before D10'
grep -Fq 'RunPatchHelper(kD10PatchHelper, "apply")' "$source_file" || \
  fail 'bootstrap does not apply the D10 profile'
grep -Fq 'option == "--allow-incomplete-boot"' \
  "$speaker_patch_source" || fail 'speaker helper lacks early-boot apply parser'
for skip_contract in \
  'option == "--skip-zero-validation"' \
  '(allow_incomplete_boot || skip_zero_validation) && action != "apply"' \
  '!skip_zero_validation &&' \
  '!RequireZeroAllocation(transport, generation, allocation, error)' \
  'RunPatchHelper(kSpeakerPatchHelper, "apply", true)' \
  '"--skip-zero-validation", nullptr' \
  'zero-validation bypass is restricted to speaker apply'; do
  grep -Fq -- "$skip_contract" "$speaker_patch_source" "$source_file" || \
    fail "boot path lacks bounded zero-validation bypass: $skip_contract"
done
[[ $(grep -Fc '"--skip-zero-validation"' "$source_file") -eq 1 ]] || \
  fail 'bootstrap must pass zero-validation bypass only to speaker apply'
# A dump owns one debug descriptor across command submission and correlated
# acknowledgement. It drains only already-available messages, parses after
# every new chunk, and uses a longer deadline only when the exact requested
# address/length never arrives. This removes fixed quiet-period latency while
# tolerating the observed >100 ms separation between acknowledgement and line.
for transport_source in "$patch_source" "$speaker_patch_source"; do
  transport_name=$(basename -- "$(dirname -- "$transport_source")")
  for reader_contract in \
    'kDebugDrainTimeout = std::chrono::milliseconds(10)' \
    'kDumpDebugTimeout = std::chrono::seconds(2)' \
    'bool DrainDebugNow(int fd, std::string* error)' \
    'bool ReadDumpDebug(int fd, uint32_t address' \
    'ParseMemoryDump(*output, address, size, bytes, &parse_error)' \
    'PauseBeforeRetry(deadline)' \
    'output->erase(0, output->size() - kMaximumDebugOutput)' \
    'UniqueFd debug_fd(open(kDebugDevice, O_RDONLY | O_CLOEXEC | O_NONBLOCK))' \
    'ReadDumpDebug(debug_fd.get(), address, size, bytes, &debug, error)'; do
    grep -Fq -- "$reader_contract" "$transport_source" || \
      fail "$transport_name lacks bounded early-return dump reader: $reader_contract"
  done
  if grep -Fq 'ReadDebug(' "$transport_source"; then
    fail "$transport_name reintroduced fixed quiet-period dump latency"
  fi
done

# The qualified path retains the stock scheduler state. Validate the exact TCB
# identity and both priority fields, but never write either scheduler field.
for priority_contract in \
  'CheckUsfDefaultWorkerIdentity' \
  'RequireUsfDefaultWorkerStockPriority' \
  'const uint32_t current = ReadLe32(tcb, 0x2c);' \
  'const uint32_t base = ReadLe32(tcb, 0x4c);' \
  'current != kUsfDefaultWorkerStockPriority' \
  'base != kUsfDefaultWorkerStockPriority' \
  'no scheduler field was changed'; do
  grep -Fq -- "$priority_contract" "$speaker_patch_source" || \
    fail "speaker helper lacks stock-priority contract: $priority_contract"
done
if grep -Eq '401659(24|44)|[Pp]riority.?26|0x1a, 0x00, 0x00, 0x00' \
    "$speaker_patch_source" "$speaker_patch_model" \
    "$speaker_patch_model_header"; then
  fail 'speaker helper retains the stale UsfDefaultWorker priority mutation'
fi

# The stock signed firmware is modified only after boot. The allocator write is
# guarded by exact source/readback, the stock timer assertion and work pool,
# then synchronized through the exact five-second OUTPUTTER timer. Restoration
# is mandatory after every attempted callback write.
for allocator_contract in \
  '0x400a114c' \
  '{0x00, 0x28, 0x70, 0xd0}' \
  '{0x00, 0x28, 0x25, 0xd0}' \
  '0x4009e0cc' \
  '{0x8e, 0xfd, 0x90, 0xbb}'; do
  grep -Fq -- "$allocator_contract" "$speaker_patch_model" || \
    fail "speaker model lacks A32 allocator provenance: $allocator_contract"
done
for live_contract in \
  'EnsureA32AllocatorFallbackApplied' \
  'RequireA32RuntimeProfileApplied' \
  'transport->SetWord(kA32Core, allocator.address, allocator.after,' \
  'FlushA32InstructionCacheViaOutputter' \
  'RestoreA32OutputterCallback' \
  'kA32CacheCallbackWait = std::chrono::seconds(7)' \
  'callback_write_attempted' \
  're-synchronizing its instruction cache'; do
  grep -Fq -- "$live_contract" "$speaker_patch_source" || \
    fail "speaker helper lacks guarded live allocator contract: $live_contract"
done
for timer_contract in \
  'kA32WorkPoolPointerAddress = 0x40131094' \
  'kA32WorkPoolAddress = 0x40164110' \
  'kA32OutputterTimerPointerAddress = 0x4016df48' \
  'kA32OutputterTimerVtable = 0x4010a330' \
  'kA32OutputterWorker = 0x40165730' \
  'kA32OutputterCallback = 0x400a7a2d' \
  'kA32OutputterContext = 0x4016df08' \
  'kA32OutputterPeriodNs = UINT64_C(5000000000)' \
  'kA32WholeCacheInvalidator = 0x40091be9'; do
  grep -Fq -- "$timer_contract" "$speaker_patch_model_header" || \
    fail "speaker model lacks live A32 cache guard: $timer_contract"
done
for validator_contract in \
  'ValidateA32WorkPoolSnapshot' \
  'ValidateA32OutputterTimerSnapshot'; do
  grep -Fq -- "$validator_contract" "$speaker_patch_model" || \
    fail "speaker model lacks live A32 object validator: $validator_contract"
done
[[ $(grep -Fc 'transport->SetWord(kA32Core, allocator.address, allocator.after,' \
     "$speaker_patch_source") -eq 1 ]] || \
  fail 'speaker helper must write the A32 allocator word exactly once'
if grep -Fq 'install the exact cold-patched' "$speaker_patch_source"; then
  fail 'speaker helper still requires GSA-rejected cold firmware'
fi
for allocator_contract in \
  'RequireA32AllocatorFallbackApplied' \
  'run guarded live apply'; do
  grep -Fq -- "$allocator_contract" "$speaker_patch_source" || \
    fail "speaker helper lacks live allocator attestation: $allocator_contract"
done
grep -Fq 'firmware_profile=stock' \
  "$audio_kernel_builder" || \
  fail 'audio image builder does not default to stock signed AoC firmware'
grep -Fq 'd0_progress_mode=${POWERPHONE_D0_PROGRESS_MODE:-${AUDIO_D0_PROGRESS_MODE:-mailbox}}' \
  "$audio_kernel_builder" || \
  fail 'audio image builder does not default to real mailbox progress'

initial_f1_read_line=$(grep -n -F -m1 \
  '!ReadStates(&transport, generation, &states, error)' \
  "$speaker_patch_source" | cut -d: -f1)
allocator_apply_line=$(grep -n -F -m1 \
  '!EnsureA32AllocatorFallbackApplied(&transport, generation, error)' \
  "$speaker_patch_source" | cut -d: -f1)
transition_plan_line=$(grep -n -F -m1 \
  'if (!PlanTransition(action, states, &order, &already_complete, error))' \
  "$speaker_patch_source" | cut -d: -f1)
buffer_rebase_line=$(grep -n -F -m1 \
  '!EnsureSpeakerBuffersRebased(&transport, generation, card.get(),' \
  "$speaker_patch_source" | cut -d: -f1)
h0_geometry_line=$(grep -n -F -m1 \
  '!TransitionH0Geometry(&transport, generation, true, error)' \
  "$speaker_patch_source" | cut -d: -f1)
f1_transition_line=$(grep -n -F -m1 \
  'for (const std::size_t index : order)' \
  "$speaker_patch_source" | cut -d: -f1)
first_ready_line=$(grep -n -F '!SetReady(true, error)' \
  "$speaker_patch_source" | tail -n 1 | cut -d: -f1)
(( initial_f1_read_line < transition_plan_line && \
   transition_plan_line < allocator_apply_line && \
   allocator_apply_line < buffer_rebase_line && \
   buffer_rebase_line < h0_geometry_line && \
   h0_geometry_line < f1_transition_line && \
   f1_transition_line < first_ready_line )) || \
  fail 'speaker helper does not preflight/plan, install A32/buffers/H0, then connect F1 and certify in order'

# The native helper must own the one-allocation, four-bank rebase and the H0
# rate/period-conditional geometry transaction. These happen before any
# reachable native-q192 F1 hook.
for buffer_contract in \
  'constexpr uint32_t kNativeBankBytes = 0xc00;' \
  'constexpr uint32_t kAllocationBytes = 0x3000;' \
  'constexpr uint32_t kDmaTxOffset = 0x1800;' \
  'AllocateSpeakerStorage' \
  'RequireZeroAllocation' \
  'CommitSpeakerBufferRebase' \
  'refusing a second 0x3000' \
  'rollback requires a cold AoC reset'; do
  grep -Fq -- "$buffer_contract" "$speaker_patch_source" || \
    fail "speaker helper lacks dynamic-bank contract: $buffer_contract"
done
for h0_contract in \
  'constexpr std::size_t kH0GeometryPatchCount = 6;' \
  '0x403f0c44' \
  '{0x0b, 0xe3, 0x30, 0xf3}' \
  '0x403f0c48' \
  '{0x90, 0xcc, 0x7e, 0x60}' \
  '0x403f0c4c' \
  '{0xa2, 0x24, 0x66, 0x7a}' \
  '0x403f0c50' \
  '{0x02, 0xe0, 0xff, 0x11}' \
  '0x403f0c54' \
  '{0x86, 0x3b, 0xe7, 0x00}' \
  '0x403ea940' \
  '{0xee, 0xe3, 0x3e, 0xcc}' \
  '{0x06, 0xc0, 0x18, 0xcc}' \
  'kH0StockGeometryWords' \
  '0x403ea948' \
  '{0x40, 0xbf, 0xbc, 0x93}' \
  '0x403ea954' \
  '{0xb4, 0x3e, 0x0e, 0x93}' \
  'DeepBuffer'; do
  grep -Fq -- "$h0_contract" "$speaker_patch_source" || \
    fail "speaker helper lacks conditional H0 native-q192 geometry: $h0_contract"
done
if grep -Fq '{0x48, 0xbe, 0xbc, 0x93}' "$speaker_patch_source" || \
   grep -Fq '{0xbc, 0x3d, 0x0e, 0x93}' "$speaker_patch_source"; then
  fail 'speaker helper retains unsafe unconditional H0 x4 shift words'
fi
h0_cave_line=$(grep -n -F -m1 \
  '"H0 AMixSPKR conditional geometry cave word 0"' \
  "$speaker_patch_source" | cut -d: -f1)
h0_hook_line=$(grep -n -F -m1 \
  '"H0 AMixSPKR enum-7/period-1 geometry hook"' \
  "$speaker_patch_source" | cut -d: -f1)
(( h0_cave_line < h0_hook_line )) || \
  fail 'speaker helper does not install the H0 cave before its live hook'

# Only the bootstrap/patch domain initializes and certifies readiness. PDM
# readiness has one additional fail-closed revocation if post-patch logical-lane
# materialization fails; speaker readiness still has only the initial and
# finalizer clears.
[[ $(grep -Fc 'SetPropertyChecked(kReadyProperty, "0")' "$source_file") -eq 3 ]] || \
  fail 'bootstrap must clear PDM readiness before attempts, during fail-open, and after failed PDM priming'
[[ $(grep -Fc 'SetPropertyChecked(kSpeakerReadyProperty, "0")' "$source_file") -eq 2 ]] || \
  fail 'bootstrap must clear speaker readiness both before attempts and during fail-open'
for rule in \
  'set_prop(frankel_powerphone_d10_bootstrap, vendor_powerphone_pdm_prop)' \
  'set_prop(frankel_powerphone_d10_bootstrap, vendor_powerphone_aoc_speaker_prop)'; do
  grep -Fqx -- "$rule" "$policy" || fail "missing property ownership rule: $rule"
done

# Lock per-index capture-list ownership and the complete early-boot policy
# needed by stdio_to_kmsg and the speaker helper's AoC generation guard.
if grep -Fq 'mixer_ctl_set_array(control' "$source_file"; then
  fail 'bootstrap reintroduced the packed-array ABI bug'
fi
[[ $(grep -Fc 'mixer_ctl_set_value(control, index, wanted[index])' "$source_file") -eq 1 ]] || \
  fail 'capture list is not programmed element-by-element'
[[ $(grep -Fc 'mixer_ctl_get_value(control, index)' "$source_file") -eq 1 ]] || \
  fail 'capture list is not verified element-by-element'
grep -Fq 'for (const int logical_mic : {1, 2, 0})' "$source_file" || \
  fail 'bootstrap does not materialize every logical microphone after D10 activation'
d10_apply_line=$(grep -n -F -m1 '!RunPatchHelper(kD10PatchHelper, "apply")' \
  "$source_file" | cut -d: -f1)
pdm_prime_line=$(grep -n -F -m1 'if (!PrimePatchedCaptureLists())' \
  "$source_file" | cut -d: -f1)
(( d10_apply_line < pdm_prime_line )) || \
  fail 'bootstrap materializes logical microphones before the D10 patch is live'
grep -Eq 'w_file_perms getattr ioctl' "$policy" || \
  fail 'stdio_to_kmsg policy lacks getattr/ioctl'
grep -Fqx \
  'allow frankel_powerphone_d10_bootstrap sysfs_aoc:dir search;' \
  "$policy" || fail 'speaker helper cannot traverse the stock AoC sysfs node'
grep -Fqx \
  'allow frankel_powerphone_d10_bootstrap sysfs_aoc_dumpstate:file { open read };' \
  "$policy" || fail 'speaker helper cannot read the stock AoC generation counters'

# Keep both boot-critical profile helpers on the reviewed bounded factory_diag
# transport. A zero-byte nonblocking read means that Frankel's response is
# still pending, while a positive short write may have already acted on a
# packet prefix and must never be continued or resent.
for transport_source in "$patch_source" "$speaker_patch_source"; do
  transport_name=$(basename -- "$(dirname -- "$transport_source")")
  for transport_contract in \
    'constexpr auto kFactoryWriteTimeout = std::chrono::seconds(2);' \
    'constexpr auto kFactoryResponseTimeout = std::chrono::seconds(5);' \
    'constexpr auto kFactoryRetryDelay = std::chrono::milliseconds(1);' \
    'Clock::now() + kFactoryWriteTimeout' \
    'O_WRONLY | O_CLOEXEC | O_NONBLOCK' \
    'IsRetryableIoError(open_error)' \
    'IsRetryableIoError(write_error)' \
    'short factory_diag packet write; refusing to continue it' \
    'Clock::now() + kFactoryResponseTimeout' \
    'PauseBeforeRetry(deadline)' \
    'expected_length = static_cast<std::size_t>((*response)[2])' \
    'timed out waiting for factory_diag response' \
    'timed out assembling factory_diag response'; do
    grep -Fq -- "$transport_contract" "$transport_source" || \
      fail "$transport_name lacks factory_diag transport contract: $transport_contract"
  done
  if grep -Fq '*expected_length = static_cast' "$transport_source"; then
    fail "$transport_name writes through a disengaged response-length optional"
  fi
  if grep -Fq 'factory_diag closed before a complete response' \
      "$transport_source"; then
    fail "$transport_name treats a pending zero-byte factory_diag read as EOF"
  fi
  if grep -Fq 'open(kFactoryDiag, O_WRONLY | O_CLOEXEC);' \
      "$transport_source"; then
    fail "$transport_name reintroduced a blocking factory_diag writer"
  fi
  [[ $(grep -Fc 'O_WRONLY | O_CLOEXEC | O_NONBLOCK' "$transport_source") -eq 1 ]] || \
    fail "$transport_name must have exactly one nonblocking factory_diag writer"
done

# Every native factory_diag client must serialize on the lock created and
# labeled by the PowerPhone post-fs-data integration. A local-tmp lock cannot
# protect the global response/debug streams from a boot-profile helper.
shared_transaction_lock='/data/vendor/powerphone/.aoc-patch.lock'
for transport_source in \
  "$diag_source" "$patch_source" "$speaker_patch_source"; do
  transport_name=$(basename -- "$(dirname -- "$transport_source")")
  [[ $(grep -Fc -- "\"$shared_transaction_lock\"" "$transport_source") -eq 1 ]] || \
    fail "$transport_name does not use exactly one shared PowerPhone transaction lock"
done
if grep -Fq '/data/local/tmp/.frankel-aoc-speaker-patch.lock' "$diag_source"; then
  fail 'generic AoC diagnostic transport reintroduced its non-shared lock'
fi

printf 'Frankel PowerPhone D10 bootstrap policy checks passed\n'
