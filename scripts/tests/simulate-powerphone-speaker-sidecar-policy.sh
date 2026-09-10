#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
speaker_patch="$project_root/patches/hardware-interfaces/0002-add-powerphone-192k-speaker-output.patch"
qualified_capture_patch="$project_root/patches/hardware-interfaces/0003-use-qualified-frankel-d10-capture.patch"
readiness_fix_patch="$project_root/patches/hardware-interfaces/0005-keep-readiness-writes-in-certifier-domains.patch"
qualified_output_patch="$project_root/patches/hardware-interfaces/0006-use-qualified-d0-single-amp-output.patch"
direct_high_rate_patch="$project_root/patches/hardware-interfaces/0007-use-direct-cs35l43-high-rate-route.patch"
output_probe_patch="$project_root/patches/hardware-interfaces/0017-split-powerphone-output-probe-ports.patch"
fifo90_patch="$project_root/patches/hardware-interfaces/0018-require-qualified-fifo90-playback.patch"
pcm_open_wait_patch="$project_root/patches/hardware-interfaces/0020-scope-d0-pcm-open-wait.patch"
native_q192_patch="$project_root/patches/hardware-interfaces/0021-use-qualified-native-q192-speaker-path.patch"
d0_wrapper="$project_root/scripts/audio/frankel/d0-speaker-192k.sh"
d0_common="$project_root/scripts/audio/frankel/common.sh"
loader_policy="$project_root/tools/audio/device/frankel_pdm_loader/sepolicy/powerphone_pdm_loader.te"
property_contexts="$project_root/tools/audio/device/frankel_pdm_loader/sepolicy/property_contexts"
loader_source="$project_root/tools/audio/device/frankel_pdm_loader/powerphone_pdm_loader.cpp"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

added_count() {
  local literal=$1
  grep -Fc -- "+$literal" "$speaker_patch"
}

[[ -f "$speaker_patch" ]] || fail "missing speaker sidecar patch"
[[ -f "$qualified_output_patch" ]] || fail "missing qualified D0 output patch"
[[ -f "$direct_high_rate_patch" ]] || fail "missing direct CS35L43 high-rate route patch"
[[ -f "$output_probe_patch" ]] || fail "missing split output-probe port patch"
[[ -f "$fifo90_patch" ]] || fail "missing qualified FIFO/90 playback patch"
[[ -f "$pcm_open_wait_patch" ]] || fail "missing scoped D0 PCM-open wait patch"
[[ -x "$d0_wrapper" ]] || fail "missing executable D0 speaker wrapper"
[[ -f "$d0_common" ]] || fail "missing D0 mixer ownership helper"

# Keep every existing pipeline while adding one unambiguous native-q192
# source-0 backend. The two-slot suffix is intentional: a shorter q192-s32
# name could be confused with the separate four-S32 experiment.
pipeline_selector=$(sed -n '/^d0_select_pipeline() {$/,/^}$/p' "$d0_wrapper")
[[ -n "$pipeline_selector" ]] || fail "D0 wrapper has no pipeline selector"
for selector in q48-s32 q192-s16 q192-s32-2slot; do
  [[ $(grep -Fxc "    ${selector})" <<<"$pipeline_selector") -eq 1 ]] || \
    fail "D0 wrapper lacks one exact $selector pipeline arm"
done
q48_arm=${pipeline_selector#*'    q48-s32)'}
q48_arm=${q48_arm%%'    q192-s16)'*}
q192_s16_arm=${pipeline_selector#*'    q192-s16)'}
q192_s16_arm=${q192_s16_arm%%'    q192-s32-2slot)'*}
q192_s32_arm=${pipeline_selector#*'    q192-s32-2slot)'}
q192_s32_arm=${q192_s32_arm%%'    *)'*}
for contract in \
  'd0_live_profile=experimental-enum7-early-q48-tdm24576-192-4xs32-source0' \
  'd0_backend_format=S32_LE' \
  'd0_backend_channel_enum=Four' \
  'd0_backend_channel_count=4' \
  'd0_backend_slot_enum=Four' \
  'd0_backend_slot_count=4' \
  'd0_backend_bclk_hz=24576000'; do
  grep -Fq "$contract" <<<"$q48_arm" || \
    fail "q48-s32 wrapper contract is incomplete: $contract"
done
for contract in \
  'd0_live_profile=experimental-enum7-q192-tdm12288-192-4xs16-dma-source0' \
  'd0_backend_format=S16_LE' \
  'd0_backend_channel_enum=Four' \
  'd0_backend_channel_count=4' \
  'd0_backend_slot_enum=Four' \
  'd0_backend_slot_count=4' \
  'd0_backend_bclk_hz=12288000'; do
  grep -Fq "$contract" <<<"$q192_s16_arm" || \
    fail "q192-s16 wrapper contract is incomplete: $contract"
done
for contract in \
  'd0_live_profile=experimental-enum7-q192-tdm12288-192-2xs32-dma-source0' \
  'd0_backend_format=S32_LE' \
  'd0_backend_channel_enum=Two' \
  'd0_backend_channel_count=2' \
  'd0_backend_slot_enum=Two' \
  'd0_backend_slot_count=2' \
  'd0_backend_bclk_hz=12288000'; do
  grep -Fq "$contract" <<<"$q192_s32_arm" || \
    fail "q192-s32-2slot wrapper contract is incomplete: $contract"
done

[[ $(grep -Fc \
  "'TDM_0_RX Chan' \"\$d0_backend_channel_enum\"" "$d0_wrapper") -eq 2 ]] || \
  fail "D0 wrapper does not program and verify the selected backend channel count"
[[ $(grep -Fc \
  "'TDM_0_RX nSlot' \"\$d0_backend_slot_enum\"" "$d0_wrapper") -eq 2 ]] || \
  fail "D0 wrapper does not program and verify the selected backend slot count"
if grep -Eq "'TDM_0_RX (Chan|nSlot)' Four" "$d0_wrapper"; then
  fail "D0 wrapper still hard-codes the four-slot backend"
fi
grep -Fq "readonly d0_playback_device=0" "$d0_wrapper" || \
  fail "D0 wrapper no longer selects PCM0,D0"
grep -Fq "readonly d0_frontend_channels=2" "$d0_wrapper" || \
  fail "D0 wrapper lost its stereo frontend"
grep -Fq "readonly d0_frontend_sample_bytes=4" "$d0_wrapper" || \
  fail "D0 wrapper lost its S32 frontend"
grep -Fq "geometry=1920x2" "$d0_wrapper" || \
  fail "D0 wrapper lost its default 1920x2 frontend geometry"
grep -Fq \
  '    d0_period_size=960' \
  "$d0_wrapper" || \
  fail "D0 wrapper lost its 960x2 frontend geometry"
grep -Fq 'readonly d0_q192_start_threshold=1920' "$d0_wrapper" || \
  fail "native q192 two-slot path lost its qualified one-period threshold"
grep -Fq 'q192-s32-2slot:1920x2:1920' "$d0_wrapper" || \
  fail "native q192 qualification gate is not bound to 1920x2/1920"
grep -Fq 'readonly d0_digital_pcm_volume=817' "$d0_wrapper" || \
  fail "D0 wrapper lost the stock physical-route digital PCM volume"
for volume_mapping in \
  "earpiece) d0_digital_pcm_volume_control='Digital PCM Volume'" \
  "bottom) d0_digital_pcm_volume_control='R Digital PCM Volume'"; do
  grep -Fq "$volume_mapping" "$d0_wrapper" || \
    fail "D0 wrapper lost selected-only codec volume mapping: $volume_mapping"
done
[[ $(grep -Fc '"$d0_digital_pcm_volume_control" "$d0_digital_pcm_volume"' \
     "$d0_wrapper") -eq 2 ]] || \
  fail "D0 wrapper must set and verify exactly one endpoint-selected volume"
for retry_contract in \
  'staged_retry_events' \
  'retry_event_count == playback_efault_retries' \
  'retry_event_offset == d0_period_bytes' \
  'playback_efault_retries > d0_default_rw_efault_retries'; do
  grep -Fq "$retry_contract" "$d0_wrapper" || \
    fail "native q192 wrapper lost bounded first-period EFAULT policy: $retry_contract"
done
if grep -Fq 'q192-s32-2slot requires the 480x4' "$d0_wrapper"; then
  fail "native q192 two-slot path incorrectly rejects 960x2"
fi

amp_off_line=$(grep -nF -m1 \
  "frankel_audio_require_control_zero 'Main AMP Enable Switch'" \
  "$d0_wrapper" | cut -d: -f1)
backend_set_line=$(grep -nF -m1 \
  "frankel_audio_snapshot_and_set_scalar 'TDM_0_RX Sample Rate' SR_192K" \
  "$d0_wrapper" | cut -d: -f1)
backend_verify_line=$(grep -nF -m1 \
  "frankel_audio_require_control_value 'TDM_0_RX Sample Rate' SR_192K" \
  "$d0_wrapper" | cut -d: -f1)
amp_enable_line=$(grep -nF -m1 \
  "frankel_audio_tinymix_set 'Main AMP Enable Switch' 1" \
  "$d0_wrapper" | cut -d: -f1)
final_ep1_line=$(grep -nF -m1 \
  "  'TDM_0_RX Mixer EP1' 1 \\" "$d0_wrapper" | cut -d: -f1)
volume_set_line=$(grep -nF \
  '"$d0_digital_pcm_volume_control" "$d0_digital_pcm_volume"' \
  "$d0_wrapper" | head -n 1 | cut -d: -f1)
volume_verify_line=$(grep -nF \
  '"$d0_digital_pcm_volume_control" "$d0_digital_pcm_volume"' \
  "$d0_wrapper" | tail -n 1 | cut -d: -f1)
[[ "$amp_off_line" =~ ^[0-9]+$ && "$backend_set_line" =~ ^[0-9]+$ && \
   "$backend_verify_line" =~ ^[0-9]+$ && "$amp_enable_line" =~ ^[0-9]+$ && \
   "$final_ep1_line" =~ ^[0-9]+$ && "$volume_set_line" =~ ^[0-9]+$ && \
   "$volume_verify_line" =~ ^[0-9]+$ ]] || \
  fail "D0 wrapper route-order markers are missing"
(( amp_off_line < backend_set_line && backend_set_line < volume_set_line && \
   volume_set_line < backend_verify_line && \
   backend_verify_line < volume_verify_line && \
   volume_verify_line < amp_enable_line && amp_enable_line < final_ep1_line )) || \
  fail "D0 backend must be programmed and verified while amps/EP1 are off"

safe_cleanup_line=$(grep -nF -m1 \
  'for ((index = 0; index < ${#FRANKEL_AUDIO_SAFE_NAMES[@]}; index++)); do' \
  "$d0_common" | cut -d: -f1)
snapshot_cleanup_line=$(grep -nF -m1 \
  'for ((index = ${#FRANKEL_AUDIO_SNAPSHOT_NAMES[@]} - 1; index >= 0; index--)); do' \
  "$d0_common" | cut -d: -f1)
[[ "$safe_cleanup_line" =~ ^[0-9]+$ && \
   "$snapshot_cleanup_line" =~ ^[0-9]+$ ]] || \
  fail "D0 cleanup ordering markers are missing"
(( safe_cleanup_line < snapshot_cleanup_line )) || \
  fail "selected codec volume could restore before amp/EP1 hard-off"

# AudioPolicy still converts AIDL device addresses through the legacy
# char[32] ABI. Guard every address literal carried anywhere in this patch
# stack, including intermediate profiles, so one overlength BUS port cannot
# make conversion discard the entire module again.
mapfile -t all_address_literals < <(
  grep -hoE 'POWERPHONE_(CARD_[0-9]+|C[0-9]+)_[A-Z0-9_]+' \
    "$project_root"/patches/hardware-interfaces/*.patch | sort -u
)
(( ${#all_address_literals[@]} > 0 )) || fail "PowerPhone patch stack has no address literals"
for endpoint_address in "${all_address_literals[@]}"; do
  [[ ${#endpoint_address} -le 31 ]] || \
    fail "patch-stack address exceeds the 31-character legacy audio-device limit: $endpoint_address"
done

# The three internal physical research routes must remain policy-neutral and
# independently addressable. A built-in speaker/earpiece/safe type would enter
# normal media, ring, or call strategy selection and could race the stock HAL.
[[ $(grep -Ec '^\+ +AudioDeviceType::OUT_BUS, kPlaybackCard, kPlaybackDevice, PCM_OUT,' \
     "$speaker_patch") -eq 3 ]] || \
  fail "speaker endpoints are not exactly three OUT_BUS ports"
if grep -Eq '^\+.*AudioDeviceType::OUT_(SPEAKER|SPEAKER_EARPIECE|SPEAKER_SAFE)' \
    "$speaker_patch"; then
  fail "speaker patch adds a policy-selected built-in output type"
fi
if grep -Fq '+    deviceExt.flags = ' "$speaker_patch" || \
    grep -Fq '+AudioPortDeviceExt::FLAG_INDEX_DEFAULT_DEVICE' "$speaker_patch"; then
  fail "speaker patch marks a research endpoint as a default device"
fi
for endpoint_address in \
  POWERPHONE_C0_D28_EARPIECE \
  POWERPHONE_C0_D28_BOTTOM \
  POWERPHONE_C0_D28_BOTH; do
  [[ ${#endpoint_address} -le 31 ]] || \
    fail "historical sidecar address exceeds the 31-character legacy audio-device limit: $endpoint_address"
  [[ $(grep -Fc -- "$endpoint_address" "$speaker_patch") -eq 1 ]] || \
    fail "missing or duplicate exact endpoint address: $endpoint_address"
done

# The final cumulative patch moves output to the proven D0 stereo frontend
# and removes the simultaneous-amplifier endpoint that watchdogs FF1.
for endpoint_address in \
  POWERPHONE_C0_D0_EARPIECE \
  POWERPHONE_C0_D0_BOTTOM; do
  [[ ${#endpoint_address} -le 31 ]] || \
    fail "qualified address exceeds the 31-character legacy audio-device limit: $endpoint_address"
  [[ $(grep -Fc -- "+        {\"PowerPhone" "$qualified_output_patch") -ge 2 ]] || \
    fail "qualified output patch lacks replacement endpoint declarations"
  grep -Fq -- "$endpoint_address" "$qualified_output_patch" || \
    fail "missing qualified D0 endpoint: $endpoint_address"
done
for endpoint_address in \
  POWERPHONE_C0_D10_MIC0 \
  POWERPHONE_C0_D10_MIC1 \
  POWERPHONE_C0_D10_MIC2; do
  [[ ${#endpoint_address} -le 31 ]] || \
    fail "qualified address exceeds the 31-character legacy audio-device limit: $endpoint_address"
  grep -Fq -- "$endpoint_address" "$qualified_capture_patch" || \
    fail "missing qualified D10 endpoint: $endpoint_address"
done
grep -Fq -- '-        {"PowerPhone both speakers 192k"' "$qualified_output_patch" || \
  fail "final patch does not remove simultaneous-amplifier endpoint"
grep -Fq -- '-    BOTH,' "$qualified_output_patch" || \
  fail "final patch does not remove BOTH enum"
grep -Fq -- '+constexpr int32_t kPlaybackDevice = 0;' "$qualified_output_patch" || \
  fail "final patch does not select PCM0,D0"
grep -Fq -- '+                !snapshotAndSetEnum(std::string(prefix) + "PCM Source", "Zero") ||' \
  "$direct_high_rate_patch" || fail 'qualified output does not silence the normal-rate DAC path'
grep -Fq -- '+                !enumMatches(std::string(prefix) + "PCM Source", "Zero") ||' \
  "$direct_high_rate_patch" || fail 'qualified output does not verify the silent normal-rate path'
[[ $(grep -Fc -- 'High Rate PCM Source", "ASPRX1"' "$direct_high_rate_patch") -ge 2 ]] || \
  fail 'qualified output lost its 192 kHz high-rate DAC selector'
grep -Fq -- '+            !setValue("TDM_0_RX Mixer EP1", 1)) {' "$direct_high_rate_patch" || \
  fail 'qualified output does not enable the proven EP1/source-0 route'
grep -Fq -- '+            !valueMatches("TDM_0_RX Mixer US", 0)' "$direct_high_rate_patch" || \
  fail 'qualified output does not prove the legacy US route remains off'
grep -Fq -- '-    onrestart restart audioserver' "$direct_high_rate_patch" || \
  fail 'optional sidecar can bypass the boot gate by restarting audioserver'

# Capture research ports follow the same policy-neutral rule. They remain
# discoverable for an explicitly addressed app, but no ordinary recording
# strategy can select them while their data-path gate is false.
[[ $(grep -Ec '^\+ +AudioDeviceType::IN_BUS, kCaptureCard, [023], PCM_IN,' \
     "$speaker_patch") -eq 3 ]] || \
  fail "capture endpoints are not exactly three IN_BUS ports"
if grep -Eq '^\+.*AudioDeviceType::IN_(MICROPHONE|MICROPHONE_BACK)' \
    "$speaker_patch"; then
  fail "speaker extension leaves a policy-selected built-in capture type"
fi
for endpoint_address in \
  POWERPHONE_CARD_1_DEV_0_PDM0 \
  POWERPHONE_CARD_1_DEV_2_PDM2 \
  POWERPHONE_CARD_1_DEV_3_PDM3; do
  [[ $(grep -Fc -- "$endpoint_address" "$speaker_patch") -eq 1 ]] || \
    fail "missing or duplicate exact capture address: $endpoint_address"
done

# The cumulative profile is PCM0,D0 S32/stereo/192 kHz, 1920x2. The original
# patch still supplies the normal mix-port contract.
grep -Eq '^\+ +AudioChannelLayout::INDEX_MASK_2\)' "$qualified_output_patch" || \
  fail "qualified output profile lost the stereo index mask"
grep -Fq -- '+constexpr size_t kPlaybackAlsaPeriodFrames = 1920;' \
  "$native_q192_patch" || fail "qualified output lost 1920-frame periods"
grep -Eq '^\+ +outputMixPort\.flags = AudioIoFlags::make<AudioIoFlags::Tag::output>\(0\);' \
  "$speaker_patch" || fail "output mix port is no longer a normal flags=0 port"
grep -Eq '^\+ +outputMixPort\.profiles = \{outputProfile\};' "$speaker_patch" || \
  fail "output mix port lost the exact output profile"

# Address-distinguished attached BUS outputs are probed separately by
# AudioPolicy. They must not resolve to one already-open mix-port config.
grep -Fq -- '-    AudioPort outputMixPort;' "$output_probe_patch" || \
  fail "final patch does not remove the single shared output mix port"
grep -Fq -- '     for (int32_t devicePortId : outputDevicePortIds) {' \
  "$output_probe_patch" || fail "output mix ports are not created per fixed BUS sink"
grep -Fq -- '+        outputMixPort.id = config->nextPortId++;' \
  "$output_probe_patch" || fail "per-sink output mix ports do not receive distinct IDs"
grep -Fq -- '+        outputMixPort.flags = AudioIoFlags::make<AudioIoFlags::Tag::output>(0);' \
  "$output_probe_patch" || fail "per-sink output mix port is not a normal mixer"
grep -Fq -- '+        outputMixPort.profiles = {outputProfile};' \
  "$output_probe_patch" || fail "per-sink output mix port lost the exact profile"
grep -Fq -- '         route.sourcePortIds = {outputMixPort.id};' \
  "$output_probe_patch" || fail "per-sink output route lost its dedicated mix-port source"

# PCM0,D0 was stable for 60 seconds only with the producer at FIFO/90. The
# HAL must establish that exact policy before touching the playback route and
# must not silently fall back to the SCHED_OTHER policy which recovered EPIPE.
grep -Fq -- '+constexpr int kPlaybackRtPriority = 90;' "$fifo90_patch" || \
  fail "qualified playback RT priority is not fixed at 90"
grep -Fq -- '+        schedulerParameters.sched_priority = kPlaybackRtPriority;' \
  "$fifo90_patch" || fail "playback worker does not request the qualified priority"
grep -Fq -- \
  '+        if (sched_setscheduler(0, SCHED_FIFO | SCHED_RESET_ON_FORK,' \
  "$fifo90_patch" || fail "playback worker does not request reset-on-fork FIFO scheduling"
grep -Fq -- '+            return ::android::PERMISSION_DENIED;' "$fifo90_patch" || \
  fail "playback scheduling failure is not fail-closed"
grep -Fq -- '-    rlimit rtprio 10 10' "$fifo90_patch" || \
  fail "FIFO/90 patch does not replace the insufficient RT limit"
grep -Fq -- '+    rlimit rtprio 90 90' "$fifo90_patch" || \
  fail "PowerPhone service RT limit is not 90"
if grep -Eq '^\+.*(clock_nanosleep|nanosleep|usleep).*playback' "$fifo90_patch"; then
  fail "FIFO/90 fix introduces an unqualified software playback pacer"
fi

# A cold-boot bottom-first run proved that the vendor driver's card-wide wait
# must be 200 when PCM0,D0 copies it during hw_params. The sidecar must restore
# the prior card default as soon as pcm_open returns, including every setup or
# open failure; it must also keep EP1 as the final mixer write before open.
grep -Fq -- '+constexpr int kPlaybackPcmOpenWaitMs = 200;' "$pcm_open_wait_patch" || \
  fail "D0 PCM-open wait is not fixed to the live-stable value"
grep -Fq -- \
  '+constexpr char kPcmStreamWaitControl[] = "PCM Stream Wait Time in MSec";' \
  "$pcm_open_wait_patch" || fail "D0 patch does not name the vendor wait control"
grep -Fq -- '+        if (!setPcmOpenWait()) {' "$pcm_open_wait_patch" || \
  fail "D0 route does not arm its scoped wait before PCM open"
grep -Fq -- '         if (!setFinalRouteValue("TDM_0_RX Mixer EP1", 1)) {' \
  "$pcm_open_wait_patch" || fail "D0 wait patch does not retain final EP1 activation"
grep -Fq -- '+                mPlaybackRoute != nullptr && mPlaybackRoute->restorePcmOpenWait();' \
  "$pcm_open_wait_patch" || fail "D0 open does not immediately restore the card wait"
grep -Fq -- '+        if (!restorePcmOpenWait()) {' "$pcm_open_wait_patch" || \
  fail "D0 cleanup does not retry the wait restore on every error path"
wait_arm_line=$(grep -nF -- '+        if (!setPcmOpenWait()) {' \
  "$pcm_open_wait_patch" | cut -d: -f1)
final_ep1_line=$(grep -nF -- \
  '         if (!setFinalRouteValue("TDM_0_RX Mixer EP1", 1)) {' \
  "$pcm_open_wait_patch" | cut -d: -f1)
pcm_open_line=$(grep -nF -- \
  '             POWERPHONE_LEGACY_PCM_FORMAT_S32_LE, &openResult);' \
  "$pcm_open_wait_patch" | cut -d: -f1)
wait_restore_line=$(grep -nF -- \
  '+                mPlaybackRoute != nullptr && mPlaybackRoute->restorePcmOpenWait();' \
  "$pcm_open_wait_patch" | cut -d: -f1)
[[ "$wait_arm_line" =~ ^[0-9]+$ && "$final_ep1_line" =~ ^[0-9]+$ && \
   "$pcm_open_line" =~ ^[0-9]+$ && "$wait_restore_line" =~ ^[0-9]+$ ]] || \
  fail "D0 wait/open ordering markers are missing or duplicated"
(( wait_arm_line < final_ep1_line && final_ep1_line < pcm_open_line && \
   pcm_open_line < wait_restore_line )) || \
  fail "D0 wait must precede final EP1/open and restore immediately after open"
if grep -Eq '^\+.*(clock_nanosleep|nanosleep|usleep).*PcmOpenWait' "$pcm_open_wait_patch"; then
  fail "D0 wait-control fix adds software pacing"
fi

# This wait qualifies stable q48/source-0 transfer only. On hardware, a WAV
# declaring 960,000 frames/5 seconds took 19.98 seconds between D0 SOURCE_ON
# and SOURCE_OFF: exactly 48 kHz consumption. Do not encode the scoped wait as
# proof of a physical 192 kHz output clock or ultrasonic bandwidth.
if grep -Eiq '^\+.*(proves?|qualif(y|ies|ied)).*(physical )?192[ -]?k(hz)?' \
    "$pcm_open_wait_patch"; then
  fail "D0 wait-control patch overclaims physical 192 kHz qualification"
fi

# VINTF module registration must never depend on a research endpoint becoming
# ready. The independently owned volatile readiness flags are initialized by
# their confined certifiers rather than vendor init.
# Construction must remain available for APM's inert STANDBY probe; start and
# transfer must independently fail before any PCM opens or continues.
if grep -Fq '+    disabled' "$speaker_patch" || \
    grep -Eq '^\+on property:vendor\.powerphone\..*ready=' "$speaker_patch"; then
  fail "IModule registration is still readiness-gated"
fi
for reset in \
  '    setprop vendor.powerphone.pdm.ready 0' \
  '    setprop vendor.powerphone.aoc_speaker_192k.ready 0'; do
  [[ $(added_count "$reset") -eq 1 ]] || fail "missing historical reset input: $reset"
  [[ $(grep -Fc -- "-$reset" "$readiness_fix_patch") -eq 1 ]] || \
    fail "vendor-init readiness write is not removed by the final patch: $reset"
done
[[ $(grep -Fc 'GetBoolProperty(kCaptureReadyProperty, false)' "$speaker_patch") \
     -ge 2 ]] || fail "capture start/transfer is not independently gated"
[[ $(grep -Fc 'GetBoolProperty(kSpeakerReadyProperty, false)' "$speaker_patch") \
     -ge 3 ]] || fail "speaker start/post-open/transfer is not independently gated"
if sed -n '/ModulePowerphone::createInputStream/,/createStreamInstance<StreamInPowerphone>/p' \
    "$speaker_patch" | grep -Fq 'GetBoolProperty'; then
  fail "APM input stream-construction probe is readiness-gated"
fi
if sed -n '/ModulePowerphone::createOutputStream/,/createStreamInstance<StreamOutPowerphone>/p' \
    "$speaker_patch" | grep -Fq 'GetBoolProperty'; then
  fail "APM's inert stream-construction probe is readiness-gated"
fi
grep -Fq 'StreamAlsa does not open a PCM until its FMQ start' "$speaker_patch" || \
  fail "inert APM-probe contract is not documented in source"
grep -Fqx \
  'vendor.powerphone.aoc_speaker_192k.ready u:object_r:vendor_powerphone_aoc_speaker_prop:s0 exact bool' \
  "$property_contexts" || fail "speaker readiness property lacks an exact Boolean label"
grep -Fqx \
  'vendor.powerphone.pdm.topology_ready u:object_r:vendor_powerphone_pdm_topology_prop:s0 exact bool' \
  "$property_contexts" || fail "PDM topology property lacks an exact Boolean label"
for read_rule in \
  'get_prop(hal_audio_default, vendor_powerphone_pdm_prop)' \
  'get_prop(hal_audio_default, vendor_powerphone_aoc_speaker_prop)'; do
  grep -Fqx "$read_rule" "$loader_policy" || \
    fail "audio HAL lacks readiness-property read rule: $read_rule"
done
grep -Fqx \
  'set_prop(powerphone_pdm_loader, vendor_powerphone_pdm_topology_prop)' \
  "$loader_policy" || fail "PDM loader lost ownership of its topology flag"
if grep -Fqx 'set_prop(powerphone_pdm_loader, vendor_powerphone_pdm_prop)' \
    "$loader_policy"; then
  fail "inert PDM topology loader can assert data readiness"
fi
grep -Fq 'vendor.powerphone.pdm.topology_ready' "$loader_source" || \
  fail "PDM loader does not publish the topology-only property"
if grep -Fq 'vendor.powerphone.pdm.ready' "$loader_source"; then
  fail "PDM loader source can publish the data-ready property"
fi
if grep -Eq '^set_prop\(powerphone_pdm_loader, .*speaker' "$loader_policy"; then
  fail "PDM loader can set the independently certified speaker property"
fi

# Lock the essential route-ownership and cleanup controls. This is a static
# regression check; hardware qualification must still prove the AoC patch and
# the physical acoustic bandwidth.
for control in \
  'TDM_0_RX Mixer US' \
  'Main AMP Enable Switch' \
  'R Main AMP Enable Switch' \
  'Ultrasonic Mode' \
  'R Ultrasonic Mode' \
  'TDM_0_RX Mixer RAW' \
  'TDM_0_RX Mixer EP2'; do
  grep -Fq -- "$control" "$speaker_patch" || \
    fail "speaker route controller lost required control: $control"
done
grep -Eq '^\+ +StreamAlsa::standby\(\);' "$speaker_patch" || \
  fail "PCM-open failure path does not close ALSA before route cleanup"
grep -Eq '^\+ +const ::android::status_t status = StreamAlsa::standby\(\);' \
  "$speaker_patch" || \
  fail "standby no longer closes PCM before route cleanup"
grep -Eq '^\+ +proxy_write_with_retries\(' "$speaker_patch" || \
  fail "speaker transfer lost period-bounded writes"
for ownership_guard in \
  'mPlaybackRoute->verifyOwnership()' \
  'mOwnershipLost = true' \
  'conflictingRoutesAreIdle()' \
  'expectedStateMatches()' \
  'speaker state changed while opening PCM' \
  'refusing speaker resume' \
  'Never tear the route down while its PCM proxy is still open' \
  'skipping speaker hard-off after ownership loss'; do
  grep -Fq -- "$ownership_guard" "$speaker_patch" || \
    fail "speaker path lost cross-HAL ownership guard: $ownership_guard"
done
[[ $(grep -Fc 'setValueBestEffort("Main AMP Enable Switch", 0)' \
     "$speaker_patch") -eq 1 ]] || fail "main-amp cleanup is missing or duplicated"
if grep -Fq 'setValueBestEffort("Main AMP Enable Switch", 0) &&' \
    "$speaker_patch"; then
  fail "hard-off cleanup still short-circuits after the first failure"
fi

printf 'PowerPhone speaker sidecar policy checks passed\n'
