#!/usr/bin/env bash
# Build, but never flash, the exact Frankel AoC ALSA 1 ms host-timer trial.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_dir="$project_root/artifacts/frankel/device"
trial_root="$project_root/work/audio-research/frankel/host-timer-1ms"
output_dir=${1:-"$trial_root/trial-1"}

base_vkb="$base_dir/vendor_kernel_boot.img"
# This is the exact pre-trial live root descriptor set.  The published bundle
# currently carries byte-identical vendor_kernel_boot payload, but a different
# vbmeta for other partitions and is not a safe partial-flash anchor.
base_vbmeta="$project_root/work/audio-research/frankel/build-output/vbmeta.img"
patcher="$script_dir/patch_frankel_aoc_host_timer_1ms.py"
unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"

base_vkb_sha=6b52a9d04cd4c3979144cc01054300f5babc6f37670e290cd92087a6198849a7
base_vbmeta_sha=ac23a27a328b0625b4cc5720cfa4d3ea488bc31bafcb0906c0b032b42fed22a2
base_module_sha=e2ed0cad956634993290a807c9bcbd3d77352b2d31a16c3d8697de12f620671d
base_vkb_descriptor_digest=409a2dade73c14f9896941d16867fb5e1966e793057fa1eeab7d7c78130b40f9
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

for tool in "$unpack_bootimg" "$mkbootimg" "$avbtool" "$avb_key" "$patcher"; do
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
python3 "$patcher" --check stock "$base_module"
patched_module="$stage/aoc_alsa_dev_util.host-timer-1ms.ko"
python3 "$patcher" "$base_module" "$patched_module"
python3 "$patcher" --check fast "$patched_module"
install -m 0644 -- "$patched_module" "$base_module"
touch -d @0 -- "$base_module"

(
  cd -- "$stage/final/ramdisk-root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) > "$stage/vendor_ramdisk00.cpio.patched"
lz4 -q -f -l -12 -- "$stage/vendor_ramdisk00.cpio.patched" \
  "$stage/final/vendor_ramdisk00.host-timer-1ms"

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
  --vendor_ramdisk_fragment "$stage/final/vendor_ramdisk00.host-timer-1ms" \
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

cp -f -- "$patched_module" "$stage/final/aoc_alsa_dev_util.host-timer-1ms.ko"
{
  printf 'variant=frankel-powerphone-aoc-host-timer-1ms\n'
  printf 'base_vendor_kernel_boot_sha256=%s\n' "$base_vkb_sha"
  printf 'base_vbmeta_sha256=%s\n' "$base_vbmeta_sha"
  printf 'base_aoc_alsa_dev_util_sha256=%s\n' "$base_module_sha"
  printf 'new_vendor_kernel_boot_descriptor_digest=%s\n' "$new_vkb_digest"
  (
    cd -- "$stage/final"
    sha256sum -- \
      aoc_alsa_dev_util.host-timer-1ms.ko \
      vendor_kernel_boot.raw.img vendor_kernel_boot.img vbmeta.img
  )
} > "$stage/final/build-audit.txt"

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,120p' "$output_dir/build-audit.txt"
