#!/usr/bin/env bash
# Reproduce, but never promote, Frankel's failed vendor_boot cold-audio trial.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
matched_dir="$project_root/work/audio-research/frankel/host-timer-500us-ep3-192k-cold-audio/trial-1"
trial_root="$project_root/work/audio-research/frankel/host-timer-500us-ep3-192k-cold-audio-vendor-boot"
output_dir=${1:-"$trial_root/trial-1"}

base_vendor_boot="$project_root/work/vbmeta-debug/IMAGES/vendor_boot.img"
base_vbmeta="$matched_dir/vbmeta.img"
current_vendor_kernel_boot="$matched_dir/vendor_kernel_boot.img"
unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"

base_vendor_boot_sha=25428d668e370467ba28800f93d9c2a73e6850fec000c3760fc7dddaa3ce9728
base_vbmeta_sha=dab3766f1623aea013e996e7eb51d0a7def4736ac1367aa6844bfbcbee4a1a63
current_vendor_kernel_boot_sha=a6ddbcafa591a7797d7e442200e36f2be5596c9748ea44500a1a397afae1f957
base_ramdisk_sha=82e97f2636a09b944994dd0a08f98528ba962b1e87a47cb543cd914720b58b92
base_bootconfig_sha=b97da18db3594b008c1df4ba9ed9ffbdacda2948fdf1a1d297b2511ee8e215db
base_vendor_cmdline_sha=ee5dd6e5d3a6b44644462af00565e0177b61d95ef6c5ef2ae01e904239e34207
base_vendor_boot_descriptor_digest=2f4053c2dce73825d2cfe8559596ffbb9737b4043caf4ccd9d139b9008578a72
current_vendor_kernel_boot_descriptor_digest=5382bb0d9ec46cf49c50c9227dd8384a331d751e3e351b659a0871a7796810d5
avb_salt=c7cf7247dd978cb78301e952c737dc0bfce2d0b0f422785114cb20eec88f2b09b02c686cdc35246f59ee170d7693cb38761cc7b99f4c7a46b19c61902e004da9
vendor_boot_fingerprint=google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys
bootconfig_entry=androidboot.init_rc=/system/etc/init/hw/init.rc
guarded_raw_size=24332288

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

for tool in "$unpack_bootimg" "$mkbootimg" "$avbtool" "$avb_key"; do
  require_file "$tool"
done
for command_name in awk cmp cp grep mv python3 sed sha256sum stat; do
  command -v "$command_name" >/dev/null || die "missing command: $command_name"
done
require_sha256 "$base_vendor_boot" "$base_vendor_boot_sha"
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
  "$stage/candidate-unpacked"
"$unpack_bootimg" --boot_img "$base_vendor_boot" \
  --out "$stage/final/unpacked-base" > "$stage/final/vendor_boot.base.unpack.txt"
require_sha256 \
  "$stage/final/unpacked-base/vendor_ramdisk00" "$base_ramdisk_sha"
require_sha256 "$stage/final/unpacked-base/bootconfig" "$base_bootconfig_sha"
[[ ! -e "$stage/final/unpacked-base/dtb" ]] || \
  die "matched vendor_boot unexpectedly contains a DTB"
[[ $(stat -c %s -- "$stage/final/unpacked-base/bootconfig") == 77 ]] || \
  die "unexpected base bootconfig size"
grep -Fqx 'androidboot.load_modules_parallel=true' \
  "$stage/final/unpacked-base/bootconfig" || die "missing base parallel-load bootconfig"
grep -Fqx 'androidboot.boot_devices=3c400000.ufs' \
  "$stage/final/unpacked-base/bootconfig" || die "missing base boot-device bootconfig"
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

build_raw_vendor_boot() {
  local bootconfig=$1 output=$2
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
    --vendor_ramdisk_fragment \
      "$stage/final/unpacked-base/vendor_ramdisk00" \
    --vendor_boot "$output"
}

# Fail before changing anything unless the parsed header fields reconstruct
# the exact raw bytes authenticated by the matched vendor_boot image.
build_raw_vendor_boot \
  "$stage/final/unpacked-base/bootconfig" \
  "$stage/base-reconstructed.raw.img"
[[ $(stat -c %s -- "$stage/base-reconstructed.raw.img") == "$guarded_raw_size" ]] || \
  die "base reconstruction changed the guarded raw size"
cmp -n "$guarded_raw_size" -- \
  "$base_vendor_boot" "$stage/base-reconstructed.raw.img" || \
  die "base vendor_boot reconstruction is not byte-exact"

cp -f -- "$stage/final/unpacked-base/bootconfig" \
  "$stage/final/bootconfig.cold-audio"
printf '%s\n' "$bootconfig_entry" >> "$stage/final/bootconfig.cold-audio"
[[ $(grep -Fxc "$bootconfig_entry" "$stage/final/bootconfig.cold-audio") == 1 ]] || \
  die "cold-audio bootconfig selector is not unique"
[[ $(stat -c %s -- "$stage/final/bootconfig.cold-audio") == 125 ]] || \
  die "unexpected cold-audio bootconfig size"

build_raw_vendor_boot \
  "$stage/final/bootconfig.cold-audio" \
  "$stage/final/vendor_boot.raw.img"
raw_size=$(stat -c %s -- "$stage/final/vendor_boot.raw.img")
[[ "$raw_size" == "$guarded_raw_size" ]] || \
  die "candidate vendor_boot changed guarded raw size: $raw_size"
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

python3 - \
  "$base_vbmeta" "$stage/vbmeta.descriptor-donor.img" \
  "$base_vendor_boot_descriptor_digest" "$new_vendor_boot_digest" \
  "$current_vendor_kernel_boot_descriptor_digest" <<'PY'
import pathlib
import sys

source, output, old_hex, new_hex, retained_vkb_hex = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
old = bytes.fromhex(old_hex)
new = bytes.fromhex(new_hex)
retained_vkb = bytes.fromhex(retained_vkb_hex)
if len(data) != 8192 or len(old) != 32 or len(new) != 32 or len(retained_vkb) != 32:
    raise SystemExit("unexpected guarded vbmeta/digest size")
if data.count(old) != 1:
    raise SystemExit("base vendor_boot digest is not unique in vbmeta")
if data.count(retained_vkb) != 1:
    raise SystemExit("current vendor_kernel_boot digest is not unique in vbmeta")
result = data.replace(old, new, 1)
if result.count(retained_vkb) != 1:
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
grep -Fq '      Image Size:            24332288 bytes' \
  "$stage/final/vbmeta.info" || die "root vbmeta changed vendor_boot image size"
grep -Fq "      Digest:                $new_vendor_boot_digest" \
  "$stage/final/vbmeta.info" || die "vbmeta lacks the new vendor_boot digest"
grep -Fq "      Digest:                $current_vendor_kernel_boot_descriptor_digest" \
  "$stage/final/vbmeta.info" || die "vbmeta no longer matches current vendor_kernel_boot"

# Re-unpack the signed candidate.  This is the important partition-level
# proof missing from the failed vendor_kernel_boot experiment.
"$unpack_bootimg" --boot_img "$stage/final/vendor_boot.img" \
  --out "$stage/candidate-unpacked" \
  > "$stage/final/vendor_boot.candidate.unpack.txt"
cmp -s -- \
  "$stage/final/bootconfig.cold-audio" \
  "$stage/candidate-unpacked/bootconfig" || \
  die "signed candidate lost the cold-audio bootconfig"
require_sha256 "$stage/candidate-unpacked/vendor_ramdisk00" "$base_ramdisk_sha"
mapfile -t candidate_cmdline_matches < <(
  sed -n 's/^vendor command line args: //p' \
    "$stage/final/vendor_boot.candidate.unpack.txt"
)
(( ${#candidate_cmdline_matches[@]} == 1 )) || \
  die "failed to parse candidate vendor cmdline"
require_string_sha256 \
  "${candidate_cmdline_matches[0]}" "$base_vendor_cmdline_sha" \
  "candidate vendor cmdline"
require_sha256 \
  "$current_vendor_kernel_boot" "$current_vendor_kernel_boot_sha"

# Keep a self-contained rollback pair for the exact currently matched state.
cp -f -- "$base_vendor_boot" "$stage/final/rollback/vendor_boot.img"
cp -f -- "$base_vbmeta" "$stage/final/rollback/vbmeta.img"
require_sha256 \
  "$stage/final/rollback/vendor_boot.img" "$base_vendor_boot_sha"
require_sha256 "$stage/final/rollback/vbmeta.img" "$base_vbmeta_sha"

new_bootconfig_sha=$(sha256sum -- "$stage/final/bootconfig.cold-audio")
new_bootconfig_sha=${new_bootconfig_sha%% *}
{
  printf 'variant=frankel-powerphone-cold-audio-vendor-boot\n'
  printf 'status=FAILED_REAL_HARDWARE_PRIMARY_ONLY_INIT_GRAPH_UNBOOTABLE\n'
  printf 'base_vendor_boot_sha256=%s\n' "$base_vendor_boot_sha"
  printf 'base_vbmeta_sha256=%s\n' "$base_vbmeta_sha"
  printf 'retained_vendor_kernel_boot_sha256=%s\n' \
    "$current_vendor_kernel_boot_sha"
  printf 'base_vendor_ramdisk_sha256=%s\n' "$base_ramdisk_sha"
  printf 'base_vendor_cmdline_sha256=%s\n' "$base_vendor_cmdline_sha"
  printf 'base_bootconfig_sha256=%s\n' "$base_bootconfig_sha"
  printf 'new_bootconfig_sha256=%s\n' "$new_bootconfig_sha"
  printf 'bootconfig=%s\n' "$bootconfig_entry"
  printf 'vendor_boot_guarded_raw_size=%s\n' "$guarded_raw_size"
  printf 'base_vendor_boot_descriptor_digest=%s\n' \
    "$base_vendor_boot_descriptor_digest"
  printf 'new_vendor_boot_descriptor_digest=%s\n' "$new_vendor_boot_digest"
  printf 'retained_vendor_kernel_boot_descriptor_digest=%s\n' \
    "$current_vendor_kernel_boot_descriptor_digest"
  (
    cd -- "$stage/final"
    sha256sum -- bootconfig.cold-audio vendor_boot.raw.img \
      vendor_boot.img vbmeta.img rollback/vendor_boot.img rollback/vbmeta.img
  )
} > "$stage/final/build-audit.txt"

cat > "$stage/final/FLASHING.txt" <<'EOF'
FAILED REAL-HARDWARE TRIAL -- DO NOT FLASH OR PROMOTE.

The vendor_boot selector reached an unbootable primary-only init graph and the
device returned to bootloader fastboot without ADB.  Use only the
self-contained rollback pair:

  fastboot flash vendor_boot rollback/vendor_boot.img
  fastboot flash vbmeta rollback/vbmeta.img
  fastboot reboot

Rollback also leaves vendor_kernel_boot untouched.
EOF

cat > "$stage/final/DO_NOT_FLASH.txt" <<'EOF'
FAILED ON REAL FRANKEL HARDWARE.

The image returned to bootloader fastboot without ADB.  Selecting only the
stock primary init.rc skips the partition directories that define critical
services needed by that same primary script.  Do not flash or promote this
pair.  FLASHING.txt contains rollback commands only.
EOF

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'reproduced failed trial (do not flash): %s\n' "$output_dir"
sed -n '1,240p' "$output_dir/build-audit.txt"
