#!/usr/bin/env bash
# Build, but never flash, Frankel's custom-primary cold-audio vendor_boot v2.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
product_out="$aosp_dir/out_pixel/frankel/target/product/frankel"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
matched_dir="$project_root/work/audio-research/frankel/host-timer-500us-ep3-192k-cold-audio/trial-1"
trial_root="$project_root/work/audio-research/frankel/host-timer-500us-ep3-192k-cold-audio-vendor-boot-v2"
output_dir=${1:-"$trial_root/trial-1"}

base_vendor_boot="$project_root/work/vbmeta-debug/IMAGES/vendor_boot.img"
base_init_boot="$project_root/work/vbmeta-debug/IMAGES/init_boot.img"
base_vbmeta="$matched_dir/vbmeta.img"
current_vendor_kernel_boot="$matched_dir/vendor_kernel_boot.img"
unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
host_init_verifier="$host_bin/host_init_verifier"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"

base_vendor_boot_sha=25428d668e370467ba28800f93d9c2a73e6850fec000c3760fc7dddaa3ce9728
base_init_boot_sha=b99772e728dda767f5ccdada7ae0d4e3c6f902ca9c852910e992407263f7b5a3
base_vbmeta_sha=dab3766f1623aea013e996e7eb51d0a7def4736ac1367aa6844bfbcbee4a1a63
current_vendor_kernel_boot_sha=a6ddbcafa591a7797d7e442200e36f2be5596c9748ea44500a1a397afae1f957
base_ramdisk_sha=82e97f2636a09b944994dd0a08f98528ba962b1e87a47cb543cd914720b58b92
base_bootconfig_sha=b97da18db3594b008c1df4ba9ed9ffbdacda2948fdf1a1d297b2511ee8e215db
base_vendor_cmdline_sha=ee5dd6e5d3a6b44644462af00565e0177b61d95ef6c5ef2ae01e904239e34207
base_bootimage_prop_sha=0e1ab8f7fb1c0cd73668f8fbe2f24ea7db99f8a68e6d59e8b9ce1bab4c5b8444
init_inventory_sha=2846cd08deb67b0d396d9c2a144c0f43990f343cd6106544ea3a543e9c27f057
init_inventory_content_sha=d6dd33b479c0cc502cb2e46405c7e5399623652f2fa5ae9942c9d4c95f9178dd
base_vendor_boot_descriptor_digest=2f4053c2dce73825d2cfe8559596ffbb9737b4043caf4ccd9d139b9008578a72
current_vendor_kernel_boot_descriptor_digest=5382bb0d9ec46cf49c50c9227dd8384a331d751e3e351b659a0871a7796810d5
avb_salt=c7cf7247dd978cb78301e952c737dc0bfce2d0b0f422785114cb20eec88f2b09b02c686cdc35246f59ee170d7693cb38761cc7b99f4c7a46b19c61902e004da9
vendor_boot_fingerprint=google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys
custom_init_path=/second_stage_resources/system/etc/ramdisk/build.prop
bootconfig_entry=androidboot.init_rc=$custom_init_path
base_raw_size=24332288

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" && ! -L "$1" ]] || die "missing or unsafe file: $1"
}

require_sha256() {
  local path=$1 expected=$2 observed
  observed=$(sha256sum -- "$path")
  observed=${observed%% *}
  [[ "$observed" == "$expected" ]] || \
    die "identity mismatch for $path: $observed (expected $expected)"
}

require_string_sha256() {
  local value=$1 expected=$2 label=$3 observed
  observed=$(printf '%s' "$value" | sha256sum)
  observed=${observed%% *}
  [[ "$observed" == "$expected" ]] || \
    die "identity mismatch for $label: $observed (expected $expected)"
}

for tool in \
  "$unpack_bootimg" "$mkbootimg" "$avbtool" "$host_init_verifier" \
  "$avb_key"; do
  require_file "$tool"
done
for command_name in \
  awk cmp cp cpio find grep lz4 mv python3 sed sha256sum sort stat; do
  command -v "$command_name" >/dev/null || die "missing command: $command_name"
done
require_sha256 "$base_vendor_boot" "$base_vendor_boot_sha"
require_sha256 "$base_init_boot" "$base_init_boot_sha"
require_sha256 "$base_vbmeta" "$base_vbmeta_sha"
require_sha256 \
  "$current_vendor_kernel_boot" "$current_vendor_kernel_boot_sha"
[[ ! -e "$output_dir" ]] || die "refusing to overwrite output: $output_dir"

mkdir -p -- "$trial_root"
stage=$(mktemp -d -- "$trial_root/.build.XXXXXX")
cleanup() {
  if [[ -n ${stage:-} && -d "$stage" ]]; then
    rm -rf -- "$stage"
  fi
}
trap cleanup EXIT

mkdir -p -- \
  "$stage/final/unpacked-base" "$stage/final/rollback" \
  "$stage/init-boot-unpacked" "$stage/candidate-unpacked" \
  "$stage/overlay-root/system/etc/ramdisk"
"$unpack_bootimg" --boot_img "$base_vendor_boot" \
  --out "$stage/final/unpacked-base" > "$stage/final/vendor_boot.base.unpack.txt"
require_sha256 \
  "$stage/final/unpacked-base/vendor_ramdisk00" "$base_ramdisk_sha"
require_sha256 "$stage/final/unpacked-base/bootconfig" "$base_bootconfig_sha"
[[ ! -e "$stage/final/unpacked-base/dtb" ]] || \
  die "matched vendor_boot unexpectedly contains a DTB"
! grep -Fq 'androidboot.init_rc=' "$stage/final/unpacked-base/bootconfig" || \
  die "base vendor_boot already selects an alternate init rc"

mapfile -t vendor_cmdline_matches < <(
  sed -n 's/^vendor command line args: //p' \
    "$stage/final/vendor_boot.base.unpack.txt"
)
(( ${#vendor_cmdline_matches[@]} == 1 )) || \
  die "failed to parse exactly one vendor cmdline"
vendor_cmdline=${vendor_cmdline_matches[0]}
require_string_sha256 \
  "$vendor_cmdline" "$base_vendor_cmdline_sha" "base vendor cmdline"

# The generic init_boot ramdisk normally supplies bootimage identity properties
# through system/etc/ramdisk/build.prop.  The v2 carrier deliberately overlays
# that path, so translate its exact properties into an early-init setprop
# action instead of silently losing them.
"$unpack_bootimg" --boot_img "$base_init_boot" \
  --out "$stage/init-boot-unpacked" > "$stage/init_boot.unpack.txt"
lz4 -dc -- "$stage/init-boot-unpacked/ramdisk" > "$stage/init_boot.cpio"
cpio --quiet -i --to-stdout system/etc/ramdisk/build.prop \
  < "$stage/init_boot.cpio" > "$stage/bootimage-build.prop"
require_sha256 "$stage/bootimage-build.prop" "$base_bootimage_prop_sha"

# Reproduce the exact normal LoadBootScripts inventory from this matched
# Frankel build.  The two forbidden service files must be present in the input
# and are the only paths removed from the active import list.
{
  printf '/system/etc/init/hw/init.rc\n'
  find "$product_out/system/etc/init" -maxdepth 1 -type f \
    -printf '/system/etc/init/%f\n' | LC_ALL=C sort
  find "$product_out/system_ext/etc/init" -maxdepth 1 -type f \
    -printf '/system_ext/etc/init/%f\n' | LC_ALL=C sort
  find "$product_out/vendor/etc/init" -maxdepth 1 -type f \
    -printf '/vendor/etc/init/%f\n' | LC_ALL=C sort
  if [[ -d "$product_out/vendor/odm/etc/init" ]]; then
    find "$product_out/vendor/odm/etc/init" -maxdepth 1 -type f \
      -printf '/odm/etc/init/%f\n' | LC_ALL=C sort
  fi
  if [[ -d "$product_out/product/etc/init" ]]; then
    find "$product_out/product/etc/init" -maxdepth 1 -type f \
      -printf '/product/etc/init/%f\n' | LC_ALL=C sort
  fi
} > "$stage/final/init-import-inventory.txt"
require_sha256 "$stage/final/init-import-inventory.txt" "$init_inventory_sha"
[[ $(wc -l < "$stage/final/init-import-inventory.txt") == 196 ]] || \
  die "unexpected full init inventory count"

inventory_content_digest=$(
  while IFS= read -r device_path; do
    host_path="$product_out$device_path"
    if [[ "$device_path" == /odm/* ]]; then
      host_path="$product_out/vendor$device_path"
    fi
    require_file "$host_path"
    digest=$(sha256sum -- "$host_path")
    printf '%s  %s\n' "${digest%% *}" "$device_path"
  done < "$stage/final/init-import-inventory.txt" | sha256sum
)
inventory_content_digest=${inventory_content_digest%% *}
[[ "$inventory_content_digest" == "$init_inventory_content_sha" ]] || \
  die "init inventory content changed: $inventory_content_digest"

forbidden_system=/system/etc/init/audioserver.rc
forbidden_vendor=/vendor/etc/init/android.hardware.audio.service-aidl.aoc.rc
[[ $(grep -Fxc "$forbidden_system" \
  "$stage/final/init-import-inventory.txt") == 1 ]] || \
  die "audioserver rc is not unique in the full inventory"
[[ $(grep -Fxc "$forbidden_vendor" \
  "$stage/final/init-import-inventory.txt") == 1 ]] || \
  die "vendor audio HAL rc is not unique in the full inventory"
grep -Fvx -e "$forbidden_system" -e "$forbidden_vendor" \
  "$stage/final/init-import-inventory.txt" \
  > "$stage/final/init-imports-active.txt"
[[ $(wc -l < "$stage/final/init-imports-active.txt") == 194 ]] || \
  die "active init import list did not remove exactly two files"

custom_init="$stage/final/powerphone-cold-audio-primary.rc"
{
  printf '# Frankel cold-audio primary, generated from CP2A.260805.005.\n'
  printf '# This file is also carried as ramdisk build.prop.  Tabs after\n'
  printf '# import keep Android property loading inert while init tokenizes\n'
  printf '# them as normal import directives.\n\n'
  printf 'on early-init\n'
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    [[ "$line" == *=* ]] || die "malformed guarded bootimage property: $line"
    key=${line%%=*}
    value=${line#*=}
    [[ "$key" =~ ^[a-zA-Z0-9_.-]+$ ]] || \
      die "unsafe guarded bootimage property name: $key"
    [[ "$value" != *'"'* && "$value" != *\\* ]] || \
      die "unsafe guarded bootimage property value for $key"
    printf '    setprop %s "%s"\n' "$key" "$value"
  done < "$stage/bootimage-build.prop"
  printf '\n'
  while IFS= read -r device_path; do
    printf 'import\t%s\n' "$device_path"
  done < "$stage/final/init-imports-active.txt"
} > "$custom_init"

# As a property file, every non-comment line is ignored: there is no '=' and
# the import separator is a tab rather than the literal "import " recognized
# by LoadProperties().  As init rc, the same tabs are ordinary whitespace.
! grep -Fq '=' "$custom_init" || die "custom init/property carrier contains '='"
! grep -q '^import ' "$custom_init" || \
  die "custom carrier has a space-form property import"
[[ $(grep -c $'^import\t' "$custom_init") == 194 ]] || \
  die "custom primary does not contain all active imports"
! grep -Fq "$forbidden_system" "$custom_init" || \
  die "custom primary still imports audioserver.rc"
! grep -Fq "$forbidden_vendor" "$custom_init" || \
  die "custom primary still imports vendor audio HAL rc"

# Validate the custom polyglot's init grammar.  HostImportParser deliberately
# validates import syntax without following device-absolute paths.
passwd_args=()
for passwd in \
  "$product_out/system/etc/passwd" \
  "$product_out/system_ext/etc/passwd" \
  "$product_out/vendor/etc/passwd" \
  "$product_out/vendor/odm/etc/passwd" \
  "$product_out/product/etc/passwd"; do
  [[ -f "$passwd" ]] && passwd_args+=( -p "$passwd" )
done
"$host_init_verifier" "${passwd_args[@]}" "$custom_init" \
  > "$stage/final/host-init-verifier.custom.log" 2>&1
"$host_init_verifier" "${passwd_args[@]}" \
  "$product_out/system/etc/init/hw/init.rc" \
  > "$stage/final/host-init-verifier.primary.log" 2>&1

# Append a second newc archive rather than extracting/repacking the base.  The
# kernel initramfs parser resets after TRAILER!!! and continues with the next
# newc member, so the later vendor fragment entry overlays init_boot's file
# while every original ramdisk inode (including device nodes) stays byte-exact.
cp -f -- "$custom_init" \
  "$stage/overlay-root/system/etc/ramdisk/build.prop"
chmod 0644 "$stage/overlay-root/system/etc/ramdisk/build.prop"
find "$stage/overlay-root" -exec touch -h -d @0 -- {} +
(
  cd -- "$stage/overlay-root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) > "$stage/overlay.cpio"
lz4 -dc -- "$stage/final/unpacked-base/vendor_ramdisk00" \
  > "$stage/base-vendor-ramdisk.cpio"
cp -f -- "$stage/base-vendor-ramdisk.cpio" "$stage/combined-vendor-ramdisk.cpio"
cat "$stage/overlay.cpio" >> "$stage/combined-vendor-ramdisk.cpio"
base_cpio_size=$(stat -c %s -- "$stage/base-vendor-ramdisk.cpio")
cmp -n "$base_cpio_size" -- \
  "$stage/base-vendor-ramdisk.cpio" "$stage/combined-vendor-ramdisk.cpio" || \
  die "combined ramdisk changed the byte-exact base prefix"
lz4 -q -f -l -12 -- "$stage/combined-vendor-ramdisk.cpio" \
  "$stage/final/vendor_ramdisk00.cold-audio-v2"

cp -f -- "$stage/final/unpacked-base/bootconfig" \
  "$stage/final/bootconfig.cold-audio-v2"
printf '%s\n' "$bootconfig_entry" >> "$stage/final/bootconfig.cold-audio-v2"
[[ $(grep -Fxc "$bootconfig_entry" \
  "$stage/final/bootconfig.cold-audio-v2") == 1 ]] || \
  die "cold-audio v2 bootconfig selector is not unique"

build_raw_vendor_boot() {
  local ramdisk=$1 bootconfig=$2 output=$3
  "$mkbootimg" \
    --header_version 4 \
    --pagesize 2048 \
    --base 0 \
    --kernel_offset 0x10008000 \
    --ramdisk_offset 0x11000000 \
    --tags_offset 0x10000100 \
    --dtb_offset 0x11f00000 \
    --vendor_cmdline "$vendor_cmdline" \
    --board '' \
    --vendor_bootconfig "$bootconfig" \
    --ramdisk_type platform \
    --ramdisk_name '' \
    --vendor_ramdisk_fragment "$ramdisk" \
    --vendor_boot "$output"
}

# First prove the parsed base image reconstructs byte-for-byte.
build_raw_vendor_boot \
  "$stage/final/unpacked-base/vendor_ramdisk00" \
  "$stage/final/unpacked-base/bootconfig" \
  "$stage/base-reconstructed.raw.img"
[[ $(stat -c %s -- "$stage/base-reconstructed.raw.img") == "$base_raw_size" ]] || \
  die "base reconstruction changed raw size"
cmp -n "$base_raw_size" -- \
  "$base_vendor_boot" "$stage/base-reconstructed.raw.img" || \
  die "base vendor_boot reconstruction is not byte-exact"

build_raw_vendor_boot \
  "$stage/final/vendor_ramdisk00.cold-audio-v2" \
  "$stage/final/bootconfig.cold-audio-v2" \
  "$stage/final/vendor_boot.raw.img"
new_raw_size=$(stat -c %s -- "$stage/final/vendor_boot.raw.img")
(( new_raw_size > 0 && new_raw_size < 67108864 )) || \
  die "invalid candidate vendor_boot raw size: $new_raw_size"
cp -f -- "$stage/final/vendor_boot.raw.img" "$stage/final/vendor_boot.img"
"$avbtool" add_hash_footer \
  --image "$stage/final/vendor_boot.img" \
  --partition_size 67108864 \
  --partition_name vendor_boot \
  --hash_algorithm sha256 \
  --salt "$avb_salt" \
  --prop "com.android.build.vendor_boot.fingerprint:$vendor_boot_fingerprint"
"$avbtool" info_image --image "$stage/final/vendor_boot.img" \
  > "$stage/final/vendor_boot.info"
"$avbtool" verify_image --image "$stage/final/vendor_boot.img" >/dev/null

new_vendor_boot_digest=$(awk '/^[[:space:]]+Digest:/ {print $2; exit}' \
  "$stage/final/vendor_boot.info")
[[ "$new_vendor_boot_digest" =~ ^[0-9a-f]{64}$ ]] || \
  die "failed to parse new vendor_boot digest"

# Update the one vendor_boot descriptor's digest and, if the extra ramdisk
# page changed it, Image Size.  Keep the current vendor_kernel_boot descriptor
# byte-for-byte represented in the donor.
python3 - \
  "$base_vbmeta" "$stage/vbmeta.descriptor-donor.img" \
  "$base_vendor_boot_descriptor_digest" "$new_vendor_boot_digest" \
  "$base_raw_size" "$new_raw_size" \
  "$current_vendor_kernel_boot_descriptor_digest" <<'PY'
import pathlib
import struct
import sys

source, output, old_hex, new_hex, old_size_s, new_size_s, retained_hex = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
old = bytes.fromhex(old_hex)
new = bytes.fromhex(new_hex)
retained = bytes.fromhex(retained_hex)
old_size = struct.pack(">Q", int(old_size_s))
new_size = struct.pack(">Q", int(new_size_s))
if len(data) != 8192 or data.count(old) != 1 or data.count(retained) != 1:
    raise SystemExit("unexpected guarded root-vbmeta identity")
digest_offset = data.index(old)
window_start = max(0, digest_offset - 256)
size_offsets = []
cursor = window_start
while True:
    cursor = data.find(old_size, cursor, digest_offset)
    if cursor < 0:
        break
    size_offsets.append(cursor)
    cursor += 1
if len(size_offsets) != 1:
    raise SystemExit(f"vendor_boot size field not unique near digest: {size_offsets}")
result = bytearray(data)
result[size_offsets[0]:size_offsets[0] + 8] = new_size
result[digest_offset:digest_offset + 32] = new
if bytes(result).count(retained) != 1:
    raise SystemExit("vendor_kernel_boot descriptor changed unexpectedly")
pathlib.Path(output).write_bytes(result)
PY

"$avbtool" make_vbmeta_image \
  --output "$stage/final/vbmeta.img" \
  --padding_size 8192 \
  --algorithm SHA256_RSA4096 \
  --key "$avb_key" \
  --rollback_index 1780617600 \
  --flags 0 \
  --include_descriptors_from_image "$stage/vbmeta.descriptor-donor.img"
"$avbtool" info_image --image "$stage/final/vbmeta.img" \
  > "$stage/final/vbmeta.info"
grep -Fq 'Public key (sha1):        2597c218aae470a130f61162feaae70afd97f011' \
  "$stage/final/vbmeta.info" || die "unexpected vbmeta signing key"
grep -Fq "      Image Size:            $new_raw_size bytes" \
  "$stage/final/vbmeta.info" || die "root vbmeta has wrong vendor_boot size"
grep -Fq "      Digest:                $new_vendor_boot_digest" \
  "$stage/final/vbmeta.info" || die "vbmeta lacks new vendor_boot digest"
grep -Fq "      Digest:                $current_vendor_kernel_boot_descriptor_digest" \
  "$stage/final/vbmeta.info" || die "vbmeta no longer matches current vendor_kernel_boot"

"$unpack_bootimg" --boot_img "$stage/final/vendor_boot.img" \
  --out "$stage/candidate-unpacked" \
  > "$stage/final/vendor_boot.candidate.unpack.txt"
cmp -s -- \
  "$stage/final/bootconfig.cold-audio-v2" \
  "$stage/candidate-unpacked/bootconfig" || \
  die "signed candidate lost the v2 init selector"
require_sha256 \
  "$stage/candidate-unpacked/vendor_ramdisk00" \
  "$(sha256sum "$stage/final/vendor_ramdisk00.cold-audio-v2" | awk '{print $1}')"
lz4 -dc -- "$stage/candidate-unpacked/vendor_ramdisk00" \
  > "$stage/candidate-vendor-ramdisk.cpio"
cmp -s -- \
  "$stage/combined-vendor-ramdisk.cpio" \
  "$stage/candidate-vendor-ramdisk.cpio" || \
  die "signed candidate changed the concatenated ramdisk"
require_sha256 \
  "$current_vendor_kernel_boot" "$current_vendor_kernel_boot_sha"

cp -f -- "$base_vendor_boot" "$stage/final/rollback/vendor_boot.img"
cp -f -- "$base_vbmeta" "$stage/final/rollback/vbmeta.img"
require_sha256 \
  "$stage/final/rollback/vendor_boot.img" "$base_vendor_boot_sha"
require_sha256 "$stage/final/rollback/vbmeta.img" "$base_vbmeta_sha"

new_bootconfig_sha=$(sha256sum -- "$stage/final/bootconfig.cold-audio-v2")
new_bootconfig_sha=${new_bootconfig_sha%% *}
custom_init_sha=$(sha256sum -- "$custom_init")
custom_init_sha=${custom_init_sha%% *}
new_ramdisk_sha=$(sha256sum -- "$stage/final/vendor_ramdisk00.cold-audio-v2")
new_ramdisk_sha=${new_ramdisk_sha%% *}
{
  printf 'variant=frankel-powerphone-cold-audio-vendor-boot-v2\n'
  printf 'status=READY_FOR_REAL_DEVICE_TRIAL_NOT_YET_VERIFIED\n'
  printf 'design=second_stage_resource_custom_primary_with_two_rc_omissions\n'
  printf 'base_vendor_boot_sha256=%s\n' "$base_vendor_boot_sha"
  printf 'base_vbmeta_sha256=%s\n' "$base_vbmeta_sha"
  printf 'retained_vendor_kernel_boot_sha256=%s\n' \
    "$current_vendor_kernel_boot_sha"
  printf 'custom_primary_device_path=%s\n' "$custom_init_path"
  printf 'custom_primary_sha256=%s\n' "$custom_init_sha"
  printf 'active_init_import_count=194\n'
  printf 'omitted_init_rc=%s\n' "$forbidden_system"
  printf 'omitted_init_rc=%s\n' "$forbidden_vendor"
  printf 'new_vendor_ramdisk_sha256=%s\n' "$new_ramdisk_sha"
  printf 'new_bootconfig_sha256=%s\n' "$new_bootconfig_sha"
  printf 'bootconfig=%s\n' "$bootconfig_entry"
  printf 'base_vendor_boot_raw_size=%s\n' "$base_raw_size"
  printf 'new_vendor_boot_raw_size=%s\n' "$new_raw_size"
  printf 'new_vendor_boot_descriptor_digest=%s\n' "$new_vendor_boot_digest"
  printf 'retained_vendor_kernel_boot_descriptor_digest=%s\n' \
    "$current_vendor_kernel_boot_descriptor_digest"
  (
    cd -- "$stage/final"
    sha256sum -- powerphone-cold-audio-primary.rc \
      init-import-inventory.txt init-imports-active.txt \
      bootconfig.cold-audio-v2 vendor_ramdisk00.cold-audio-v2 \
      vendor_boot.raw.img vendor_boot.img vbmeta.img \
      rollback/vendor_boot.img rollback/vbmeta.img
  )
} > "$stage/final/build-audit.txt"

cat > "$stage/final/FLASHING.txt" <<'EOF'
NOT FLASHED OR DEVICE-VERIFIED BY THIS BUILDER.

V2 uses vendor_boot's effective bootconfig and a custom primary init rc copied
by first-stage init into /second_stage_resources.  It imports the exact normal
Frankel init inventory except the two files that define audioserver and
vendor.audio-hal-aidl.  It leaves the currently matched vendor_kernel_boot
untouched.

While vendor_kernel_boot still has SHA-256
a6ddbcafa591a7797d7e442200e36f2be5596c9748ea44500a1a397afae1f957,
flash from this directory:

  fastboot flash vendor_boot vendor_boot.img
  fastboot flash vbmeta vbmeta.img
  fastboot reboot

Wait for full ADB boot, then fail closed unless every check passes:

  adb wait-for-device
  adb root
  adb wait-for-device
  test "$(adb shell getprop ro.boot.init_rc | tr -d '\r')" = \
    /second_stage_resources/system/etc/ramdisk/build.prop
  adb shell grep -Fx \
    androidboot.init_rc=/second_stage_resources/system/etc/ramdisk/build.prop \
    /proc/bootconfig
  test "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1
  test -z "$(adb shell getprop init.svc.audioserver | tr -d '\r')"
  test -z "$(adb shell getprop init.svc.vendor.audio-hal-aidl | tr -d '\r')"
  test -z "$(adb shell getprop ro.boottime.audioserver | tr -d '\r')"
  test -z "$(adb shell getprop ro.boottime.vendor.audio-hal-aidl | tr -d '\r')"
  test -z "$(adb shell pidof audioserver | tr -d '\r')"
  test -z "$(adb shell pidof android.hardware.audio.service-aidl.aoc | tr -d '\r')"

Any failure is a hard stop: do not patch AoC.  Roll back from bootloader
fastboot with the self-contained exact prior pair:

  fastboot flash vendor_boot rollback/vendor_boot.img
  fastboot flash vbmeta rollback/vbmeta.img
  fastboot reboot

Rollback also leaves vendor_kernel_boot untouched.
EOF

cat > "$stage/final/READY_FOR_DEVICE_TRIAL.txt" <<'EOF'
OFFLINE ARTIFACT AND INIT-SYNTAX CHECKS PASSED; REAL DEVICE NOT YET VERIFIED.

Use FLASHING.txt.  V2 preserves the normal init graph and omits exactly the
audioserver and vendor.audio-hal-aidl definition files.
EOF

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,260p' "$output_dir/build-audit.txt"
