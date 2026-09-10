#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=scripts/lib/frankel-powerphone-build-closure.sh
source "$project_root/scripts/lib/frankel-powerphone-build-closure.sh"

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
source_dir="$fixture/source"
generated="$source_dir/vendor/google_devices/frankel"
product="$fixture/product"
stage="$fixture/stage"
target_files="$fixture/frankel-target_files.zip"
cs35_input="$generated/stock-kernel/snd-soc-cs35l43.ko"
cs35_installed="$product/vendor_kernel_ramdisk/lib/modules/snd-soc-cs35l43.ko"
cs35_target="$stage/VENDOR_KERNEL_BOOT/RAMDISK/lib/modules/snd-soc-cs35l43.ko"
cs35_stock_fixture="$fixture/snd-soc-cs35l43-stock.fixture"
cs35_patched_fixture="$fixture/snd-soc-cs35l43-patched.fixture"
canonical_gate="$project_root/tools/audio/device/frankel_powerphone_d10_bootstrap/frankel_powerphone_audioserver_gate.rc"
stock_audio_source="$generated/proprietary/vendor/etc/init/android.hardware.audio.service-aidl.aoc.rc"
parser_source="$generated/proprietary/system_ext/etc/init/vendor.google.whitechapel.audio.hal.parserservice.rc"
stock_audio_installed="$product/vendor/etc/init/android.hardware.audio.service-aidl.aoc.rc"
parser_installed="$product/system_ext/etc/init/vendor.google.whitechapel.audio.hal.parserservice.rc"
stock_audio_target="$stage/VENDOR/etc/init/android.hardware.audio.service-aidl.aoc.rc"
parser_target="$stage/SYSTEM_EXT/etc/init/vendor.google.whitechapel.audio.hal.parserservice.rc"
readonly cs35_stock_sha256=8db0c2795f11585cb3d30382169606130e5f8aa9b6c001b6508b758b29ca99d3
readonly cs35_patched_sha256=fc631fc227ab2e7e8cfa2d664e97ac7cca4c14324fb2a39479fc8e79aa358a3a

# The proprietary CS35L43 module cannot be part of this source-only fixture.
# Substitute its two pinned identities only when the closure helper hashes the
# synthetic generated input. All other hashes use the host tool, while cmp and
# unzip still prove exact source -> installed -> target-files byte closure.
sha256sum() {
  local path
  if (( $# == 2 )) && [[ $1 == -- ]]; then
    path=$2
    if [[ $path == "$cs35_input" ]]; then
      if cmp -s -- "$path" "$cs35_stock_fixture"; then
        printf '%s  %s\n' "$cs35_stock_sha256" "$path"
        return 0
      fi
      if cmp -s -- "$path" "$cs35_patched_fixture"; then
        printf '%s  %s\n' "$cs35_patched_sha256" "$path"
        return 0
      fi
    fi
  fi
  command sha256sum "$@"
}

install_cs35_fixture() {
  local state=$1 source
  case "$state" in
    stock) source=$cs35_stock_fixture ;;
    patched) source=$cs35_patched_fixture ;;
    *)
      printf 'error: unknown CS35L43 fixture state: %s\n' "$state" >&2
      return 1
      ;;
  esac
  cp -- "$source" "$cs35_input"
  cp -- "$source" "$cs35_installed"
  cp -- "$source" "$cs35_target"
}

pack_target_files() {
  rm -f -- "$target_files"
  (cd "$stage" && zip -qr "$target_files" .)
}

expect_closure_failure() {
  local description=$1
  shift
  if frankel_powerphone_validate_build_closure "$@" >/dev/null 2>&1; then
    printf 'error: %s passed build-closure validation\n' "$description" >&2
    return 1
  fi
}

mkdir -p \
  "$generated/powerphone-d10-patch" \
  "$generated/powerphone-speaker-patch" \
  "$generated/powerphone-d10-bootstrap" \
  "$generated/powerphone-staged-play" \
  "$generated/stock-kernel" \
  "$(dirname -- "$stock_audio_source")" \
  "$(dirname -- "$parser_source")" \
  "$source_dir/hardware/interfaces/audio/aidl/default/powerphone" \
  "$product/vendor_kernel_ramdisk/lib/modules" \
  "$product/vendor_dlkm/lib/modules" \
  "$product/vendor/bin/hw" \
  "$product/vendor/etc/init" \
  "$product/vendor/etc/vintf/manifest" \
  "$product/system_ext/etc/init" \
  "$stage/VENDOR_DLKM/lib/modules" \
  "$stage/VENDOR/bin/hw" \
  "$stage/VENDOR/etc/init" \
  "$stage/VENDOR/etc/vintf/manifest" \
  "$stage/VENDOR_KERNEL_BOOT/RAMDISK/lib/modules" \
  "$stage/SYSTEM_EXT/etc/init"

printf 'synthetic-stock-cs35l43-module\n' >"$cs35_stock_fixture"
printf 'synthetic-patched-cs35l43-module\n' >"$cs35_patched_fixture"
install_cs35_fixture patched
printf 'patch-source\n' >"$generated/powerphone-d10-patch/Android.bp"
printf 'speaker-patch-source\n' >"$generated/powerphone-speaker-patch/Android.bp"
printf 'bootstrap-source\n' >"$generated/powerphone-d10-bootstrap/Android.bp"
printf 'staged-player-source\n' >"$generated/powerphone-staged-play/Android.bp"
printf 'bootstrap-rc\n' \
  >"$generated/powerphone-d10-bootstrap/frankel_powerphone_d10_bootstrap.rc"
cp "$canonical_gate" \
  "$generated/powerphone-d10-bootstrap/frankel_powerphone_audioserver_gate.rc"
printf 'service stock-aoc\n    onrestart restart --only-if-running audioserver\n' \
  >"$stock_audio_source"
printf 'service whitechapel-parser\n    onrestart restart --only-if-running audioserver\n' \
  >"$parser_source"
printf 'hal-rc\n' \
  >"$source_dir/hardware/interfaces/audio/aidl/default/powerphone/android.hardware.audio.service-aidl.powerphone.rc"
printf 'hal-vintf\n' \
  >"$source_dir/hardware/interfaces/audio/aidl/default/powerphone/android.hardware.audio.service-aidl.powerphone.xml"
printf 'stock_module.ko\n' >"$product/vendor_dlkm/lib/modules/modules.load"
printf 'd10-patch-binary\n' >"$product/vendor/bin/frankel_aoc_d10_patch"
printf 'speaker-patch-binary\n' >"$product/vendor/bin/frankel_aoc_speaker_patch"
printf 'd10-bootstrap-binary\n' >"$product/vendor/bin/frankel_powerphone_d10_bootstrap"
printf 'staged-player-binary\n' >"$product/vendor/bin/frankel_aoc_staged_play"
cp "$generated/powerphone-d10-bootstrap/frankel_powerphone_d10_bootstrap.rc" \
  "$product/vendor/etc/init/frankel_powerphone_d10_bootstrap.rc"
cp "$generated/powerphone-d10-bootstrap/frankel_powerphone_audioserver_gate.rc" \
  "$product/system_ext/etc/init/frankel_powerphone_audioserver_gate.rc"
cp "$stock_audio_source" "$stock_audio_installed"
cp "$parser_source" "$parser_installed"
printf 'hal-binary\n' \
  >"$product/vendor/bin/hw/android.hardware.audio.service-aidl.powerphone"
cp "$source_dir/hardware/interfaces/audio/aidl/default/powerphone/android.hardware.audio.service-aidl.powerphone.rc" \
  "$product/vendor/etc/init/android.hardware.audio.service-aidl.powerphone.rc"
{
  printf '%s\n' \
    '<!--' \
    '    Input:' \
    '        hardware/interfaces/audio/aidl/default/powerphone/android.hardware.audio.service-aidl.powerphone.xml' \
    '-->'
  cat "$source_dir/hardware/interfaces/audio/aidl/default/powerphone/android.hardware.audio.service-aidl.powerphone.xml"
} >"$product/vendor/etc/vintf/manifest/android.hardware.audio.service-aidl.powerphone.xml"

cp "$product/vendor_dlkm/lib/modules/modules.load" \
  "$stage/VENDOR_DLKM/lib/modules/modules.load"
cp "$product/vendor/bin/frankel_aoc_d10_patch" \
  "$stage/VENDOR/bin/frankel_aoc_d10_patch"
cp "$product/vendor/bin/frankel_aoc_speaker_patch" \
  "$stage/VENDOR/bin/frankel_aoc_speaker_patch"
cp "$product/vendor/bin/frankel_powerphone_d10_bootstrap" \
  "$stage/VENDOR/bin/frankel_powerphone_d10_bootstrap"
cp "$product/vendor/bin/frankel_aoc_staged_play" \
  "$stage/VENDOR/bin/frankel_aoc_staged_play"
cp "$product/vendor/etc/init/frankel_powerphone_d10_bootstrap.rc" \
  "$stage/VENDOR/etc/init/frankel_powerphone_d10_bootstrap.rc"
cp "$product/system_ext/etc/init/frankel_powerphone_audioserver_gate.rc" \
  "$stage/SYSTEM_EXT/etc/init/frankel_powerphone_audioserver_gate.rc"
cp "$stock_audio_installed" "$stock_audio_target"
cp "$parser_installed" "$parser_target"
cp "$product/vendor/bin/hw/android.hardware.audio.service-aidl.powerphone" \
  "$stage/VENDOR/bin/hw/android.hardware.audio.service-aidl.powerphone"
cp "$product/vendor/etc/init/android.hardware.audio.service-aidl.powerphone.rc" \
  "$stage/VENDOR/etc/init/android.hardware.audio.service-aidl.powerphone.rc"
cp "$product/vendor/etc/vintf/manifest/android.hardware.audio.service-aidl.powerphone.xml" \
  "$stage/VENDOR/etc/vintf/manifest/android.hardware.audio.service-aidl.powerphone.xml"
pack_target_files

frankel_powerphone_validate_build_closure \
  true true "$source_dir" "$generated" "$product" "$target_files"
[[ "$FRANKEL_POWERPHONE_SELECTION" == true ]]
[[ "$FRANKEL_POWERPHONE_CS35L43_SELECTION" == true ]]
[[ "$FRANKEL_POWERPHONE_CS35L43_SHA256" == "$cs35_patched_sha256" ]]
[[ "$FRANKEL_POWERPHONE_D10_PATCH_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$FRANKEL_POWERPHONE_SPEAKER_PATCH_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$FRANKEL_POWERPHONE_D10_BOOTSTRAP_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$FRANKEL_POWERPHONE_STAGED_PLAYER_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$FRANKEL_POWERPHONE_AUDIO_HAL_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$FRANKEL_POWERPHONE_PDM_MODULE_SHA256" == absent ]]
[[ "$FRANKEL_POWERPHONE_PDM_LOADER_SHA256" == absent ]]

# Even if all three packaged copies agree byte-for-byte, a synchronous
# exec_start regression must fail the semantic closure before publication.
for gate_copy in \
  "$generated/powerphone-d10-bootstrap/frankel_powerphone_audioserver_gate.rc" \
  "$product/system_ext/etc/init/frankel_powerphone_audioserver_gate.rc" \
  "$stage/SYSTEM_EXT/etc/init/frankel_powerphone_audioserver_gate.rc"; do
  sed -i \
    's/^    start vendor\.powerphone-d10-bootstrap$/    exec_start vendor.powerphone-d10-bootstrap/' \
    "$gate_copy"
done
pack_target_files
expect_closure_failure 'synchronous init bootstrap transaction' \
  true true "$source_dir" "$generated" "$product" "$target_files"
cp "$canonical_gate" \
  "$generated/powerphone-d10-bootstrap/frankel_powerphone_audioserver_gate.rc"
cp "$canonical_gate" \
  "$product/system_ext/etc/init/frankel_powerphone_audioserver_gate.rc"
cp "$canonical_gate" \
  "$stage/SYSTEM_EXT/etc/init/frankel_powerphone_audioserver_gate.rc"
pack_target_files

printf 'stale-patch-helper\n' >"$product/vendor/bin/frankel_aoc_d10_patch"
expect_closure_failure 'stale installed D10 helper' \
  true true "$source_dir" "$generated" "$product" "$target_files"
printf 'd10-patch-binary\n' >"$product/vendor/bin/frankel_aoc_d10_patch"

printf 'mismatched-installed-cs35l43\n' >"$cs35_installed"
expect_closure_failure 'mismatched installed CS35L43 module' \
  true true "$source_dir" "$generated" "$product" "$target_files"
cp -- "$cs35_input" "$cs35_installed"

printf 'mismatched-target-cs35l43\n' >"$cs35_target"
pack_target_files
expect_closure_failure 'mismatched target-files CS35L43 module' \
  true true "$source_dir" "$generated" "$product" "$target_files"
cp -- "$cs35_input" "$cs35_target"
pack_target_files

expect_closure_failure 'patched CS35L43 module selected as stock' \
  true false "$source_dir" "$generated" "$product" "$target_files"

rm -rf -- "$generated/powerphone-d10-patch" \
  "$generated/powerphone-speaker-patch" "$generated/powerphone-d10-bootstrap" \
  "$generated/powerphone-staged-play"
rm -f -- \
  "$product/vendor/bin/frankel_aoc_d10_patch" \
  "$product/vendor/bin/frankel_aoc_speaker_patch" \
  "$product/vendor/bin/frankel_powerphone_d10_bootstrap" \
  "$product/vendor/bin/frankel_aoc_staged_play" \
  "$product/vendor/etc/init/frankel_powerphone_d10_bootstrap.rc" \
  "$product/system_ext/etc/init/frankel_powerphone_audioserver_gate.rc" \
  "$product/vendor/bin/hw/android.hardware.audio.service-aidl.powerphone" \
  "$product/vendor/etc/init/android.hardware.audio.service-aidl.powerphone.rc" \
  "$product/vendor/etc/vintf/manifest/android.hardware.audio.service-aidl.powerphone.xml"
rm -rf -- "$stage"
mkdir -p \
  "$stage/VENDOR_DLKM/lib/modules" \
  "$stage/VENDOR_KERNEL_BOOT/RAMDISK/lib/modules" \
  "$(dirname -- "$stock_audio_target")" \
  "$(dirname -- "$parser_target")"
cp "$product/vendor_dlkm/lib/modules/modules.load" \
  "$stage/VENDOR_DLKM/lib/modules/modules.load"
install_cs35_fixture stock
printf 'service stock-aoc\n    onrestart restart audioserver\n' \
  >"$stock_audio_source"
printf 'service whitechapel-parser\n    onrestart restart audioserver\n' \
  >"$parser_source"
cp "$stock_audio_source" "$stock_audio_installed"
cp "$parser_source" "$parser_installed"
cp "$stock_audio_installed" "$stock_audio_target"
cp "$parser_installed" "$parser_target"
pack_target_files
frankel_powerphone_validate_build_closure \
  false false "$source_dir" "$generated" "$product" "$target_files"
[[ "$FRANKEL_POWERPHONE_SELECTION" == false ]]
[[ "$FRANKEL_POWERPHONE_CS35L43_SELECTION" == false ]]
[[ "$FRANKEL_POWERPHONE_CS35L43_SHA256" == "$cs35_stock_sha256" ]]
[[ "$FRANKEL_POWERPHONE_D10_PATCH_SHA256" == absent ]]
[[ "$FRANKEL_POWERPHONE_SPEAKER_PATCH_SHA256" == absent ]]
[[ "$FRANKEL_POWERPHONE_D10_BOOTSTRAP_SHA256" == absent ]]
[[ "$FRANKEL_POWERPHONE_STAGED_PLAYER_SHA256" == absent ]]
[[ "$FRANKEL_POWERPHONE_AUDIO_HAL_SHA256" == absent ]]

expect_closure_failure 'stock CS35L43 module selected as patched' \
  false true "$source_dir" "$generated" "$product" "$target_files"

printf 'Frankel PowerPhone D10 build-closure simulation: PASS\n'
