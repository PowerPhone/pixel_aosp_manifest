#!/usr/bin/env bash
# Build, but never flash, Frankel's EP3-192k + 500 us host-timer trial.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_dir="$project_root/work/audio-research/frankel/host-timer-1ms-ep3-192k/trial-1"
trial_root="$project_root/work/audio-research/frankel/host-timer-500us-ep3-192k"
output_dir=${1:-"$trial_root/trial-1"}

base_vkb="$base_dir/vendor_kernel_boot.img"
base_vbmeta="$base_dir/vbmeta.img"
ep3_patcher="$script_dir/patch_frankel_ep3_capture_192k.py"
timer_patcher="$script_dir/patch_frankel_aoc_host_timer_500us.py"
unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"

base_vkb_sha=3b62e4c8c77d03fc9f0c09beef018f5c5ba702cfbd6f0e2e8c9d5de83c1f6ce2
base_vbmeta_sha=64cfb1bed7a08b3339e9c5d1a1f6f706c34164fd9c072aafe7d25ae21f54d71b
base_module_sha=b546932830465a6edaf92648c5f14d207b04c93708d55bc6ec2a055bc49d4756
base_vkb_descriptor_digest=a63ad0e075da442c360652911baef2864ccf8d07b8c269b08b00257b066d348e
avb_salt=c7cf7247dd978cb78301e952c737dc0bfce2d0b0f422785114cb20eec88f2b09b02c686cdc35246f59ee170d7693cb38761cc7b99f4c7a46b19c61902e004da9
vkb_fingerprint=google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys

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

for tool in \
  "$unpack_bootimg" "$mkbootimg" "$avbtool" "$avb_key" \
  "$ep3_patcher" "$timer_patcher"; do
  require_file "$tool"
done
for command_name in awk cpio find grep lz4 mv python3 sha256sum sort stat truncate; do
  command -v "$command_name" >/dev/null || die "missing command: $command_name"
done
require_sha256 "$base_vkb" "$base_vkb_sha"
require_sha256 "$base_vbmeta" "$base_vbmeta_sha"
[[ ! -e "$output_dir" ]] || die "refusing to overwrite output: $output_dir"

mkdir -p -- "$trial_root"
stage=$(mktemp -d -- "$trial_root/.build.XXXXXX")
cleanup() {
  if [[ -n ${stage:-} && -d "$stage" ]]; then
    rm -rf -- "$stage"
  fi
}
trap cleanup EXIT

mkdir -p -- "$stage/final/unpacked" "$stage/final/ramdisk-root"
"$unpack_bootimg" --boot_img "$base_vkb" \
  --out "$stage/final/unpacked" > "$stage/final/vendor_kernel_boot.unpack.txt"
lz4 -dc -- "$stage/final/unpacked/vendor_ramdisk00" \
  > "$stage/vendor_ramdisk00.cpio"
(
  cd -- "$stage/final/ramdisk-root"
  cpio --quiet -idm --no-absolute-filenames < "$stage/vendor_ramdisk00.cpio"
)

base_module="$stage/final/ramdisk-root/lib/modules/aoc_alsa_dev_util.ko"
require_file "$base_module"
require_sha256 "$base_module" "$base_module_sha"
# The two independent exact-state checkers prove that this source contains
# both the EP3 192 kHz allowance and the qualified 1 ms timer.
python3 "$ep3_patcher" --check patched "$base_module"
python3 "$timer_patcher" --check 1ms "$base_module"
patched_module="$stage/aoc_alsa_dev_util.host-timer-500us-ep3-192k.ko"
python3 "$timer_patcher" "$base_module" "$patched_module"
python3 "$timer_patcher" --check 500us "$patched_module"
install -m 0644 -- "$patched_module" "$base_module"
touch -d @0 -- "$base_module"

(
  cd -- "$stage/final/ramdisk-root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) > "$stage/vendor_ramdisk00.cpio.patched"
lz4 -q -f -l -12 -- "$stage/vendor_ramdisk00.cpio.patched" \
  "$stage/final/vendor_ramdisk00.host-timer-500us-ep3-192k"

"$mkbootimg" \
  --header_version 4 \
  --pagesize 2048 \
  --base 0 \
  --kernel_offset 0x10008000 \
  --ramdisk_offset 0x11000000 \
  --tags_offset 0x10000100 \
  --dtb_offset 0x11f00000 \
  --vendor_cmdline '' \
  --board '' \
  --dtb "$stage/final/unpacked/dtb" \
  --vendor_bootconfig "$stage/final/unpacked/bootconfig" \
  --ramdisk_type platform \
  --ramdisk_name '' \
  --vendor_ramdisk_fragment "$stage/final/vendor_ramdisk00.host-timer-500us-ep3-192k" \
  --vendor_boot "$stage/final/vendor_kernel_boot.raw.img"

raw_size=$(stat -c %s -- "$stage/final/vendor_kernel_boot.raw.img")
(( raw_size <= 6760448 )) || \
  die "reconstructed vendor_kernel_boot exceeds guarded raw size: $raw_size"
truncate -s 6760448 -- "$stage/final/vendor_kernel_boot.raw.img"
cp -f -- "$stage/final/vendor_kernel_boot.raw.img" \
  "$stage/final/vendor_kernel_boot.img"
"$avbtool" add_hash_footer \
  --image "$stage/final/vendor_kernel_boot.img" \
  --partition_size 67108864 \
  --partition_name vendor_kernel_boot \
  --hash_algorithm sha256 \
  --salt "$avb_salt" \
  --prop "com.android.build.vendor_kernel_boot.fingerprint:$vkb_fingerprint"
"$avbtool" info_image --image "$stage/final/vendor_kernel_boot.img" \
  > "$stage/final/vendor_kernel_boot.info"
"$avbtool" verify_image --image "$stage/final/vendor_kernel_boot.img" >/dev/null

new_vkb_digest=$(awk '/^[[:space:]]+Digest:/ {print $2; exit}' \
  "$stage/final/vendor_kernel_boot.info")
[[ "$new_vkb_digest" =~ ^[0-9a-f]{64}$ ]] || \
  die "failed to parse new vendor_kernel_boot digest"

python3 - \
  "$base_vbmeta" "$stage/vbmeta.descriptor-donor.img" \
  "$base_vkb_descriptor_digest" "$new_vkb_digest" <<'PY'
import pathlib
import sys

source, output, old_hex, new_hex = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
old = bytes.fromhex(old_hex)
new = bytes.fromhex(new_hex)
if len(data) != 8192 or len(old) != 32 or len(new) != 32:
    raise SystemExit("unexpected guarded vbmeta/digest size")
if data.count(old) != 1:
    raise SystemExit("base vendor_kernel_boot digest is not unique in vbmeta")
pathlib.Path(output).write_bytes(data.replace(old, new, 1))
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
grep -Fq "      Digest:                $new_vkb_digest" \
  "$stage/final/vbmeta.info" || die "vbmeta does not contain the new digest"

cp -f -- "$patched_module" \
  "$stage/final/aoc_alsa_dev_util.host-timer-500us-ep3-192k.ko"
{
  printf 'variant=frankel-powerphone-aoc-host-timer-500us-ep3-192k\n'
  printf 'base_variant=frankel-powerphone-aoc-host-timer-1ms-ep3-192k\n'
  printf 'base_vendor_kernel_boot_sha256=%s\n' "$base_vkb_sha"
  printf 'base_vbmeta_sha256=%s\n' "$base_vbmeta_sha"
  printf 'base_aoc_alsa_dev_util_sha256=%s\n' "$base_module_sha"
  printf 'host_timer_interval_ns=500000\n'
  printf 'host_timer_low_instruction=08249452\n'
  printf 'host_timer_high_instruction=e800a072\n'
  printf 'ep3_rate_mask_file_offset=0x40300\n'
  printf 'ep3_rate_mask=fe1f0000\n'
  printf 'new_vendor_kernel_boot_descriptor_digest=%s\n' "$new_vkb_digest"
  (
    cd -- "$stage/final"
    sha256sum -- \
      aoc_alsa_dev_util.host-timer-500us-ep3-192k.ko \
      vendor_kernel_boot.raw.img vendor_kernel_boot.img vbmeta.img
  )
} > "$stage/final/build-audit.txt"

cat > "$stage/final/FLASHING.txt" <<'EOF'
NOT FLASHED BY THIS BUILDER.

This experimental pair retains EP3's 192 kHz DAI mask and changes the AoC PCM
host hrtimer from 1 ms to 500 us.  With bootloader fastboot on slot A, flash:

  fastboot flash vendor_kernel_boot vendor_kernel_boot.img
  fastboot flash vbmeta vbmeta.img

Flash both files together because root vbmeta contains the exact
vendor_kernel_boot digest.  The preceding 1 ms candidate remains untouched at
work/audio-research/frankel/host-timer-1ms-ep3-192k/trial-1/.
EOF

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,180p' "$output_dir/build-audit.txt"
