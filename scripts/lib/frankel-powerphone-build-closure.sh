#!/usr/bin/env bash

# Validate that the opt-in Frankel D10 PowerPhone selection reached both the
# product output and target-files, or that an opt-out build contains none of
# its installable payload. This file is sourced by attest-device-build.sh.

frankel_powerphone_require_plain_file() {
  local path=$1 description=$2
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || {
    printf 'error: %s is missing, empty, or unsafe: %s\n' \
      "$description" "$path" >&2
    return 1
  }
}

frankel_powerphone_target_entry_count() {
  local target_files=$1 entry=$2
  unzip -Z1 "$target_files" | grep -Fxc -- "$entry" || true
}

frankel_powerphone_compare_target_entry() {
  local target_files=$1 entry=$2 reference=$3 description=$4
  if ! unzip -p "$target_files" "$entry" | cmp -s -- "$reference" -; then
    printf 'error: %s differs from its selected source\n' "$description" >&2
    return 1
  fi
}

frankel_powerphone_require_target_count() {
  local target_files=$1 entry=$2 expected=$3 description=$4 actual
  actual=$(frankel_powerphone_target_entry_count "$target_files" "$entry") || \
    return 1
  [[ "$actual" == "$expected" ]] || {
    printf 'error: %s target-files entry count is %s, expected %s\n' \
      "$description" "$actual" "$expected" >&2
    return 1
  }
}

frankel_powerphone_require_audioserver_restart_policy() {
  local path=$1 expected=$2 rejected=$3 description=$4
  local expected_count rejected_count hook_count
  frankel_powerphone_require_plain_file "$path" "$description" || return 1
  expected_count=$(grep -Fxc -- "$expected" "$path" || true)
  rejected_count=$(grep -Fxc -- "$rejected" "$path" || true)
  hook_count=$(grep -Ec \
    '^[[:space:]]*onrestart[[:space:]].*audioserver([[:space:]]|$)' \
    "$path" || true)
  [[ "$expected_count" == 1 && "$rejected_count" == 0 && "$hook_count" == 1 ]] || {
    printf 'error: %s does not contain exactly the selected audioserver restart policy\n' \
      "$description" >&2
    return 1
  }
}

frankel_powerphone_gate_action_commands() {
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

frankel_powerphone_require_sidecar_boot_lifecycle() {
  local path=$1 description=$2 observed
  local transaction_trigger a32prep_trigger warm_success_trigger
  local warm_failure_trigger attempt1_trigger attempt2_trigger attempt3_trigger
  local release_trigger watchdog_trigger watchdog_stopped_trigger
  local expected_transaction expected_release expected_watchdog
  frankel_powerphone_require_plain_file "$path" "$description" || return 1

  if grep -Eq '^[[:space:]]*exec_start[[:space:]]' "$path"; then
    printf 'error: %s synchronously blocks init during PowerPhone certification\n' \
      "$description" >&2
    return 1
  fi
  if grep -Fq \
      'wait_for_prop init.svc.vendor.audio-hal-powerphone running' "$path"; then
    printf 'error: %s adds an unbounded wait after synchronous sidecar start\n' \
      "$description" >&2
    return 1
  fi

  transaction_trigger='on property:vendor.powerphone.bootstrap.attempted=0 && property:vendor.powerphone.bootstrap.phase=armed && property:vendor.powerphone.bootstrap.watchdog_expired=0 && property:init.svc.vendor.powerphone-bootstrap-watchdog=running && property:init.svc.aocd=running && property:init.svc.vendor.audio-hal-aidl=running && property:init.svc.audioserver=stopped'
  a32prep_trigger='on property:vendor.powerphone.bootstrap.phase=a32prep && property:init.svc.vendor.powerphone-a32-prep=stopped'
  warm_success_trigger='on property:vendor.powerphone.bootstrap.phase=warming && property:init.svc.vendor.powerphone-audio-warmup=stopped && property:init.svc.vendor.powerphone-a32-prep=stopped && property:init.svc.audioserver=running'
  warm_failure_trigger='on property:vendor.powerphone.bootstrap.phase=warming && property:init.svc.vendor.powerphone-audio-warmup=stopped && property:init.svc.vendor.powerphone-a32-prep=stopped && property:init.svc.audioserver=stopped'
  attempt1_trigger='on property:vendor.powerphone.bootstrap.phase=attempt1 && property:init.svc.vendor.powerphone-d10-bootstrap=stopped'
  attempt2_trigger='on property:vendor.powerphone.bootstrap.phase=attempt2 && property:init.svc.vendor.powerphone-d10-bootstrap-retry-1=stopped'
  attempt3_trigger='on property:vendor.powerphone.bootstrap.phase=attempt3 && property:init.svc.vendor.powerphone-d10-bootstrap-retry-2=stopped'
  release_trigger='on property:vendor.powerphone.bootstrap.phase=finalizing && property:init.svc.vendor.powerphone-d10-bootstrap-finalize=stopped'
  watchdog_trigger='on property:vendor.powerphone.bootstrap.watchdog_expired=1 && property:vendor.powerphone.bootstrap.attempted=0 && property:vendor.powerphone.bootstrap.phase=armed'
  watchdog_stopped_trigger='on property:init.svc.vendor.powerphone-bootstrap-watchdog=stopped && property:vendor.powerphone.bootstrap.attempted=0 && property:vendor.powerphone.bootstrap.watchdog_expired=0 && property:vendor.powerphone.bootstrap.phase=armed'

  [[ $(grep -Ec '^on property:' "$path") == 10 ]] || {
    printf 'error: %s does not contain the exact ten-action asynchronous state machine\n' \
      "$description" >&2
    return 1
  }

  expected_transaction=$'setprop vendor.powerphone.bootstrap.attempted 1\nstop vendor.powerphone-bootstrap-watchdog\nstop audioserver\nwait_for_prop init.svc.audioserver stopped\nstop vendor.audio-hal-powerphone\nwait_for_prop init.svc.vendor.audio-hal-powerphone stopped\nsetprop vendor.powerphone.bootstrap.phase a32prep\nstart vendor.powerphone-a32-prep'
  observed=$(frankel_powerphone_gate_action_commands "$path" "$transaction_trigger")
  [[ "$observed" == "$expected_transaction" ]] || {
    printf 'error: %s does not asynchronously launch A32 preparation after reaping audio services\n' \
      "$description" >&2
    return 1
  }
  observed=$(frankel_powerphone_gate_action_commands "$path" "$a32prep_trigger")
  [[ "$observed" == $'setprop vendor.powerphone.bootstrap.phase warming\nstart vendor.powerphone-audio-warmup\nstart vendor.audio-hal-powerphone\nstart audioserver' ]] || {
    printf 'error: %s does not launch the qualified paired audio warm-up\n' \
      "$description" >&2
    return 1
  }
  observed=$(frankel_powerphone_gate_action_commands "$path" "$warm_success_trigger")
  [[ "$observed" == $'setprop vendor.powerphone.bootstrap.phase attempt1\nstart vendor.powerphone-d10-bootstrap' ]] || {
    printf 'error: %s does not launch attempt 1 from a completed live warm-up\n' \
      "$description" >&2
    return 1
  }
  observed=$(frankel_powerphone_gate_action_commands "$path" "$warm_failure_trigger")
  [[ "$observed" == $'setprop vendor.powerphone.bootstrap.phase finalizing\nstart vendor.powerphone-d10-bootstrap-finalize' ]] || {
    printf 'error: %s does not fail open when audioserver dies during warm-up\n' \
      "$description" >&2
    return 1
  }
  observed=$(frankel_powerphone_gate_action_commands "$path" "$attempt1_trigger")
  [[ "$observed" == $'setprop vendor.powerphone.bootstrap.phase attempt2\nstart vendor.powerphone-d10-bootstrap-retry-1' ]] || {
    printf 'error: %s has an invalid attempt 1 completion transition\n' "$description" >&2
    return 1
  }
  observed=$(frankel_powerphone_gate_action_commands "$path" "$attempt2_trigger")
  [[ "$observed" == $'setprop vendor.powerphone.bootstrap.phase attempt3\nstart vendor.powerphone-d10-bootstrap-retry-2' ]] || {
    printf 'error: %s has an invalid attempt 2 completion transition\n' "$description" >&2
    return 1
  }
  observed=$(frankel_powerphone_gate_action_commands "$path" "$attempt3_trigger")
  [[ "$observed" == $'setprop vendor.powerphone.bootstrap.phase finalizing\nstart vendor.powerphone-d10-bootstrap-finalize' ]] || {
    printf 'error: %s has an invalid attempt 3 completion transition\n' "$description" >&2
    return 1
  }

  expected_release=$'setprop vendor.powerphone.bootstrap.phase releasing\nstop audioserver\nwait_for_prop init.svc.audioserver stopped\nstop vendor.audio-hal-powerphone\nwait_for_prop init.svc.vendor.audio-hal-powerphone stopped\nstart vendor.audio-hal-powerphone\nstart audioserver\nsetprop vendor.powerphone.bootstrap.phase complete'
  observed=$(frankel_powerphone_gate_action_commands "$path" "$release_trigger")
  [[ "$observed" == "$expected_release" ]] || {
    printf 'error: %s does not release a fresh sidecar/audioserver pair after finalization\n' \
      "$description" >&2
    return 1
  }

  expected_watchdog=$'setprop vendor.powerphone.bootstrap.attempted 1\nstop audioserver\nwait_for_prop init.svc.audioserver stopped\nstop vendor.audio-hal-powerphone\nwait_for_prop init.svc.vendor.audio-hal-powerphone stopped\nsetprop vendor.powerphone.bootstrap.phase finalizing\nstart vendor.powerphone-d10-bootstrap-finalize'
  for trigger in "$watchdog_trigger" "$watchdog_stopped_trigger"; do
    observed=$(frankel_powerphone_gate_action_commands "$path" "$trigger")
    [[ "$observed" == "$expected_watchdog" ]] || {
      printf 'error: %s has an invalid asynchronous watchdog fail-open transition\n' \
        "$description" >&2
      return 1
    }
  done
}

frankel_powerphone_validate_build_closure() {
  local selection=$1 cs35_selection=$2 source_dir=$3 generated_dir=$4 product_out=$5 target_files=$6
  local generated_patch generated_speaker_patch generated_bootstrap generated_staged_player bootstrap_source_rc bootstrap_source_gate
  local hal_source_dir hal_source_rc hal_source_vintf
  local installed_patch installed_speaker_patch installed_bootstrap installed_staged_player installed_bootstrap_rc installed_gate
  local installed_hal installed_hal_rc installed_hal_vintf modules_load
  local patch_target speaker_patch_target bootstrap_target staged_player_target bootstrap_rc_target gate_target
  local hal_target hal_rc_target hal_vintf_target modules_load_target
  local legacy_module_target legacy_loader_target legacy_loader_rc_target
  local stock_audio_hal_source_rc parser_source_rc
  local stock_audio_hal_installed_rc parser_installed_rc
  local stock_audio_hal_rc_target parser_rc_target
  local expected_audio_restart_line rejected_audio_restart_line
  local stale_path
  local cs35_input cs35_installed cs35_target cs35_expected cs35_observed

  FRANKEL_POWERPHONE_SELECTION=$selection
  FRANKEL_POWERPHONE_D10_PATCH_SHA256=absent
  FRANKEL_POWERPHONE_SPEAKER_PATCH_SHA256=absent
  FRANKEL_POWERPHONE_D10_BOOTSTRAP_SHA256=absent
  FRANKEL_POWERPHONE_STAGED_PLAYER_SHA256=absent
  FRANKEL_POWERPHONE_AUDIO_HAL_SHA256=absent
  FRANKEL_POWERPHONE_CS35L43_SELECTION=$cs35_selection
  FRANKEL_POWERPHONE_CS35L43_SHA256=absent
  # Retain explicit retired fields until all downstream readers have migrated.
  FRANKEL_POWERPHONE_PDM_MODULE_SHA256=absent
  FRANKEL_POWERPHONE_PDM_LOADER_SHA256=absent
  case "$selection" in
    true|false) ;;
    *)
      printf 'error: invalid PowerPhone sidecar selection: %s\n' "$selection" >&2
      return 1
      ;;
  esac
  case "$cs35_selection" in
    true) cs35_expected=fc631fc227ab2e7e8cfa2d664e97ac7cca4c14324fb2a39479fc8e79aa358a3a ;;
    false) cs35_expected=8db0c2795f11585cb3d30382169606130e5f8aa9b6c001b6508b758b29ca99d3 ;;
    *)
      printf 'error: invalid PowerPhone CS35L43 selection: %s\n' "$cs35_selection" >&2
      return 1
      ;;
  esac
  if [[ "$selection" == true ]]; then
    expected_audio_restart_line='    onrestart restart --only-if-running audioserver'
    rejected_audio_restart_line='    onrestart restart audioserver'
  else
    expected_audio_restart_line='    onrestart restart audioserver'
    rejected_audio_restart_line='    onrestart restart --only-if-running audioserver'
  fi

  cs35_input="$generated_dir/stock-kernel/snd-soc-cs35l43.ko"
  cs35_installed="$product_out/vendor_kernel_ramdisk/lib/modules/snd-soc-cs35l43.ko"
  cs35_target='VENDOR_KERNEL_BOOT/RAMDISK/lib/modules/snd-soc-cs35l43.ko'
  frankel_powerphone_require_plain_file "$cs35_input" \
    'selected Frankel CS35L43 input' || return 1
  frankel_powerphone_require_plain_file "$cs35_installed" \
    'installed Frankel CS35L43 module' || return 1
  cs35_observed=$(sha256sum -- "$cs35_input"); cs35_observed=${cs35_observed%% *}
  [[ "$cs35_observed" == "$cs35_expected" ]] || {
    printf 'error: selected Frankel CS35L43 hash is %s, expected %s\n' \
      "$cs35_observed" "$cs35_expected" >&2
    return 1
  }
  cmp -s -- "$cs35_input" "$cs35_installed" || {
    printf 'error: installed Frankel CS35L43 differs from selected input\n' >&2
    return 1
  }
  frankel_powerphone_require_target_count "$target_files" "$cs35_target" 1 \
    'selected Frankel CS35L43 module' || return 1
  frankel_powerphone_compare_target_entry "$target_files" "$cs35_target" \
    "$cs35_input" 'target-files Frankel CS35L43 module' || return 1
  FRANKEL_POWERPHONE_CS35L43_SHA256=$cs35_observed

  generated_patch="$generated_dir/powerphone-d10-patch"
  generated_speaker_patch="$generated_dir/powerphone-speaker-patch"
  generated_bootstrap="$generated_dir/powerphone-d10-bootstrap"
  generated_staged_player="$generated_dir/powerphone-staged-play"
  bootstrap_source_rc="$generated_bootstrap/frankel_powerphone_d10_bootstrap.rc"
  bootstrap_source_gate="$generated_bootstrap/frankel_powerphone_audioserver_gate.rc"
  hal_source_dir="$source_dir/hardware/interfaces/audio/aidl/default/powerphone"
  hal_source_rc="$hal_source_dir/android.hardware.audio.service-aidl.powerphone.rc"
  hal_source_vintf="$hal_source_dir/android.hardware.audio.service-aidl.powerphone.xml"
  installed_patch="$product_out/vendor/bin/frankel_aoc_d10_patch"
  installed_speaker_patch="$product_out/vendor/bin/frankel_aoc_speaker_patch"
  installed_bootstrap="$product_out/vendor/bin/frankel_powerphone_d10_bootstrap"
  installed_staged_player="$product_out/vendor/bin/frankel_aoc_staged_play"
  installed_bootstrap_rc="$product_out/vendor/etc/init/frankel_powerphone_d10_bootstrap.rc"
  installed_gate="$product_out/system_ext/etc/init/frankel_powerphone_audioserver_gate.rc"
  installed_hal="$product_out/vendor/bin/hw/android.hardware.audio.service-aidl.powerphone"
  installed_hal_rc="$product_out/vendor/etc/init/android.hardware.audio.service-aidl.powerphone.rc"
  installed_hal_vintf="$product_out/vendor/etc/vintf/manifest/android.hardware.audio.service-aidl.powerphone.xml"
  stock_audio_hal_source_rc="$generated_dir/proprietary/vendor/etc/init/android.hardware.audio.service-aidl.aoc.rc"
  parser_source_rc="$generated_dir/proprietary/system_ext/etc/init/vendor.google.whitechapel.audio.hal.parserservice.rc"
  stock_audio_hal_installed_rc="$product_out/vendor/etc/init/android.hardware.audio.service-aidl.aoc.rc"
  parser_installed_rc="$product_out/system_ext/etc/init/vendor.google.whitechapel.audio.hal.parserservice.rc"
  modules_load="$product_out/vendor_dlkm/lib/modules/modules.load"

  patch_target='VENDOR/bin/frankel_aoc_d10_patch'
  speaker_patch_target='VENDOR/bin/frankel_aoc_speaker_patch'
  bootstrap_target='VENDOR/bin/frankel_powerphone_d10_bootstrap'
  staged_player_target='VENDOR/bin/frankel_aoc_staged_play'
  bootstrap_rc_target='VENDOR/etc/init/frankel_powerphone_d10_bootstrap.rc'
  gate_target='SYSTEM_EXT/etc/init/frankel_powerphone_audioserver_gate.rc'
  hal_target='VENDOR/bin/hw/android.hardware.audio.service-aidl.powerphone'
  hal_rc_target='VENDOR/etc/init/android.hardware.audio.service-aidl.powerphone.rc'
  hal_vintf_target='VENDOR/etc/vintf/manifest/android.hardware.audio.service-aidl.powerphone.xml'
  stock_audio_hal_rc_target='VENDOR/etc/init/android.hardware.audio.service-aidl.aoc.rc'
  parser_rc_target='SYSTEM_EXT/etc/init/vendor.google.whitechapel.audio.hal.parserservice.rc'
  modules_load_target='VENDOR_DLKM/lib/modules/modules.load'
  legacy_module_target='VENDOR_DLKM/lib/modules/frankel_pdm_alsa.ko'
  legacy_loader_target='VENDOR/bin/powerphone_pdm_loader'
  legacy_loader_rc_target='VENDOR/etc/init/powerphone_pdm_loader.rc'

  frankel_powerphone_require_audioserver_restart_policy \
    "$stock_audio_hal_source_rc" "$expected_audio_restart_line" \
    "$rejected_audio_restart_line" 'generated stock AoC audio HAL RC' || return 1
  frankel_powerphone_require_audioserver_restart_policy \
    "$parser_source_rc" "$expected_audio_restart_line" \
    "$rejected_audio_restart_line" 'generated Whitechapel audio parser RC' || return 1
  frankel_powerphone_require_audioserver_restart_policy \
    "$stock_audio_hal_installed_rc" "$expected_audio_restart_line" \
    "$rejected_audio_restart_line" 'installed stock AoC audio HAL RC' || return 1
  frankel_powerphone_require_audioserver_restart_policy \
    "$parser_installed_rc" "$expected_audio_restart_line" \
    "$rejected_audio_restart_line" 'installed Whitechapel audio parser RC' || return 1
  cmp -s -- "$stock_audio_hal_source_rc" "$stock_audio_hal_installed_rc" || {
    printf 'error: installed stock AoC audio HAL RC differs from generated source\n' >&2
    return 1
  }
  cmp -s -- "$parser_source_rc" "$parser_installed_rc" || {
    printf 'error: installed Whitechapel audio parser RC differs from generated source\n' >&2
    return 1
  }
  frankel_powerphone_require_target_count \
    "$target_files" "$stock_audio_hal_rc_target" 1 'stock AoC audio HAL RC' || return 1
  frankel_powerphone_require_target_count \
    "$target_files" "$parser_rc_target" 1 'Whitechapel audio parser RC' || return 1
  frankel_powerphone_compare_target_entry \
    "$target_files" "$stock_audio_hal_rc_target" "$stock_audio_hal_source_rc" \
    'target-files stock AoC audio HAL RC' || return 1
  frankel_powerphone_compare_target_entry \
    "$target_files" "$parser_rc_target" "$parser_source_rc" \
    'target-files Whitechapel audio parser RC' || return 1

  frankel_powerphone_require_plain_file \
    "$modules_load" 'Frankel vendor-DLKM modules.load' || return 1
  frankel_powerphone_require_target_count "$target_files" \
    "$modules_load_target" 1 'Frankel vendor-DLKM modules.load' || return 1
  frankel_powerphone_compare_target_entry "$target_files" \
    "$modules_load_target" "$modules_load" \
    'target-files Frankel vendor-DLKM modules.load' || return 1
  if grep -Fxq -- 'frankel_pdm_alsa.ko' "$modules_load" || \
      unzip -p "$target_files" "$modules_load_target" | \
        grep -Fxq -- 'frankel_pdm_alsa.ko'; then
    printf 'error: retired Frankel PDM module appears in modules.load\n' >&2
    return 1
  fi
  frankel_powerphone_require_target_count \
    "$target_files" "$legacy_module_target" 0 'retired Frankel PDM module' || return 1
  frankel_powerphone_require_target_count \
    "$target_files" "$legacy_loader_target" 0 'retired PowerPhone PDM loader' || return 1
  frankel_powerphone_require_target_count \
    "$target_files" "$legacy_loader_rc_target" 0 'retired PowerPhone PDM loader RC' || return 1

  for stale_path in \
    "$generated_dir/stock-kernel/frankel_pdm_alsa.ko" \
    "$generated_dir/powerphone-pdm-loader" \
    "$product_out/vendor_dlkm/lib/modules/frankel_pdm_alsa.ko" \
    "$product_out/vendor/bin/powerphone_pdm_loader" \
    "$product_out/vendor/etc/init/powerphone_pdm_loader.rc"; do
    [[ ! -e "$stale_path" && ! -L "$stale_path" ]] || {
      printf 'error: retired card-1 PowerPhone payload remains: %s\n' \
        "$stale_path" >&2
      return 1
    }
  done

  if [[ "$selection" == true ]]; then
    for stale_path in "$generated_patch" "$generated_speaker_patch" \
      "$generated_bootstrap" "$generated_staged_player"; do
      [[ -d "$stale_path" && ! -L "$stale_path" ]] || {
        printf 'error: generated PowerPhone D10 source is missing or unsafe: %s\n' \
          "$stale_path" >&2
        return 1
      }
    done
    frankel_powerphone_require_plain_file \
      "$bootstrap_source_rc" 'generated PowerPhone D10 bootstrap RC' || return 1
    frankel_powerphone_require_plain_file \
      "$bootstrap_source_gate" 'generated PowerPhone audioserver gate RC' || return 1
    frankel_powerphone_require_plain_file \
      "$installed_patch" 'installed PowerPhone D10 patch helper' || return 1
    frankel_powerphone_require_plain_file \
      "$installed_speaker_patch" 'installed PowerPhone speaker patch helper' || return 1
    frankel_powerphone_require_plain_file \
      "$installed_bootstrap" 'installed PowerPhone D10 bootstrap' || return 1
    frankel_powerphone_require_plain_file \
      "$installed_staged_player" 'installed PowerPhone staged D0 player' || return 1
    frankel_powerphone_require_plain_file \
      "$installed_bootstrap_rc" 'installed PowerPhone D10 bootstrap RC' || return 1
    frankel_powerphone_require_plain_file \
      "$installed_gate" 'installed PowerPhone audioserver gate RC' || return 1
    frankel_powerphone_require_sidecar_boot_lifecycle \
      "$bootstrap_source_gate" 'generated PowerPhone audioserver gate RC' || return 1
    frankel_powerphone_require_sidecar_boot_lifecycle \
      "$installed_gate" 'installed PowerPhone audioserver gate RC' || return 1
    frankel_powerphone_require_plain_file \
      "$hal_source_rc" 'PowerPhone audio HAL source RC' || return 1
    frankel_powerphone_require_plain_file \
      "$hal_source_vintf" 'PowerPhone audio HAL source VINTF fragment' || return 1
    frankel_powerphone_require_plain_file \
      "$installed_hal" 'installed PowerPhone audio HAL' || return 1
    frankel_powerphone_require_plain_file \
      "$installed_hal_rc" 'installed PowerPhone audio HAL RC' || return 1
    frankel_powerphone_require_plain_file \
      "$installed_hal_vintf" 'installed PowerPhone audio HAL VINTF fragment' || return 1
    cmp -s -- "$bootstrap_source_rc" "$installed_bootstrap_rc" || {
      printf 'error: installed PowerPhone D10 bootstrap RC differs from source\n' >&2
      return 1
    }
    cmp -s -- "$bootstrap_source_gate" "$installed_gate" || {
      printf 'error: installed PowerPhone audioserver gate RC differs from source\n' >&2
      return 1
    }
    cmp -s -- "$hal_source_rc" "$installed_hal_rc" || {
      printf 'error: installed PowerPhone audio HAL RC differs from source\n' >&2
      return 1
    }
    if ! {
      printf '%s\n' \
        '<!--' \
        '    Input:' \
        '        hardware/interfaces/audio/aidl/default/powerphone/android.hardware.audio.service-aidl.powerphone.xml' \
        '-->'
      cat -- "$hal_source_vintf"
    } | cmp -s -- "$installed_hal_vintf" -; then
      printf 'error: installed PowerPhone audio HAL VINTF is not the exact build-normalized source\n' >&2
      return 1
    fi
    frankel_powerphone_require_target_count \
      "$target_files" "$patch_target" 1 'PowerPhone D10 patch helper' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$speaker_patch_target" 1 'PowerPhone speaker patch helper' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$bootstrap_target" 1 'PowerPhone D10 bootstrap' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$staged_player_target" 1 \
      'PowerPhone staged D0 player' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$bootstrap_rc_target" 1 'PowerPhone D10 bootstrap RC' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$gate_target" 1 'PowerPhone audioserver gate RC' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$hal_target" 1 'PowerPhone audio HAL' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$hal_rc_target" 1 'PowerPhone audio HAL RC' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$hal_vintf_target" 1 'PowerPhone audio HAL VINTF fragment' || return 1
    frankel_powerphone_compare_target_entry \
      "$target_files" "$patch_target" "$installed_patch" \
      'target-files PowerPhone D10 patch helper' || return 1
    frankel_powerphone_compare_target_entry \
      "$target_files" "$speaker_patch_target" "$installed_speaker_patch" \
      'target-files PowerPhone speaker patch helper' || return 1
    frankel_powerphone_compare_target_entry \
      "$target_files" "$bootstrap_target" "$installed_bootstrap" \
      'target-files PowerPhone D10 bootstrap' || return 1
    frankel_powerphone_compare_target_entry \
      "$target_files" "$staged_player_target" "$installed_staged_player" \
      'target-files PowerPhone staged D0 player' || return 1
    frankel_powerphone_compare_target_entry \
      "$target_files" "$bootstrap_rc_target" "$bootstrap_source_rc" \
      'target-files PowerPhone D10 bootstrap RC' || return 1
    frankel_powerphone_compare_target_entry \
      "$target_files" "$gate_target" "$bootstrap_source_gate" \
      'target-files PowerPhone audioserver gate RC' || return 1
    frankel_powerphone_compare_target_entry \
      "$target_files" "$hal_target" "$installed_hal" \
      'target-files PowerPhone audio HAL' || return 1
    frankel_powerphone_compare_target_entry \
      "$target_files" "$hal_rc_target" "$hal_source_rc" \
      'target-files PowerPhone audio HAL RC' || return 1
    frankel_powerphone_compare_target_entry \
      "$target_files" "$hal_vintf_target" "$installed_hal_vintf" \
      'target-files PowerPhone audio HAL VINTF fragment' || return 1
    FRANKEL_POWERPHONE_D10_PATCH_SHA256=$(sha256sum -- "$installed_patch")
    FRANKEL_POWERPHONE_D10_PATCH_SHA256=${FRANKEL_POWERPHONE_D10_PATCH_SHA256%% *}
    FRANKEL_POWERPHONE_SPEAKER_PATCH_SHA256=$(sha256sum -- "$installed_speaker_patch")
    FRANKEL_POWERPHONE_SPEAKER_PATCH_SHA256=${FRANKEL_POWERPHONE_SPEAKER_PATCH_SHA256%% *}
    FRANKEL_POWERPHONE_D10_BOOTSTRAP_SHA256=$(sha256sum -- "$installed_bootstrap")
    FRANKEL_POWERPHONE_D10_BOOTSTRAP_SHA256=${FRANKEL_POWERPHONE_D10_BOOTSTRAP_SHA256%% *}
    FRANKEL_POWERPHONE_STAGED_PLAYER_SHA256=$(sha256sum -- "$installed_staged_player")
    FRANKEL_POWERPHONE_STAGED_PLAYER_SHA256=${FRANKEL_POWERPHONE_STAGED_PLAYER_SHA256%% *}
    FRANKEL_POWERPHONE_AUDIO_HAL_SHA256=$(sha256sum -- "$installed_hal")
    FRANKEL_POWERPHONE_AUDIO_HAL_SHA256=${FRANKEL_POWERPHONE_AUDIO_HAL_SHA256%% *}
  else
    for stale_path in \
      "$generated_patch" "$generated_speaker_patch" "$generated_bootstrap" \
      "$generated_staged_player" \
      "$installed_patch" "$installed_speaker_patch" "$installed_bootstrap" "$installed_bootstrap_rc" \
      "$installed_staged_player" \
      "$installed_gate" \
      "$installed_hal" "$installed_hal_rc" "$installed_hal_vintf"; do
      [[ ! -e "$stale_path" && ! -L "$stale_path" ]] || {
        printf 'error: disabled PowerPhone build retains stale payload: %s\n' \
          "$stale_path" >&2
        return 1
      }
    done
    frankel_powerphone_require_target_count \
      "$target_files" "$patch_target" 0 'disabled PowerPhone D10 patch helper' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$speaker_patch_target" 0 'disabled PowerPhone speaker patch helper' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$bootstrap_target" 0 'disabled PowerPhone D10 bootstrap' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$staged_player_target" 0 \
      'disabled PowerPhone staged D0 player' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$bootstrap_rc_target" 0 'disabled PowerPhone D10 bootstrap RC' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$gate_target" 0 'disabled PowerPhone audioserver gate RC' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$hal_target" 0 'disabled PowerPhone audio HAL' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$hal_rc_target" 0 'disabled PowerPhone audio HAL RC' || return 1
    frankel_powerphone_require_target_count \
      "$target_files" "$hal_vintf_target" 0 'disabled PowerPhone audio HAL VINTF fragment' || return 1
  fi

  export FRANKEL_POWERPHONE_SELECTION \
    FRANKEL_POWERPHONE_CS35L43_SELECTION \
    FRANKEL_POWERPHONE_CS35L43_SHA256 \
    FRANKEL_POWERPHONE_D10_PATCH_SHA256 \
    FRANKEL_POWERPHONE_SPEAKER_PATCH_SHA256 \
    FRANKEL_POWERPHONE_D10_BOOTSTRAP_SHA256 \
    FRANKEL_POWERPHONE_STAGED_PLAYER_SHA256 \
    FRANKEL_POWERPHONE_AUDIO_HAL_SHA256 \
    FRANKEL_POWERPHONE_PDM_MODULE_SHA256 \
    FRANKEL_POWERPHONE_PDM_LOADER_SHA256
}
