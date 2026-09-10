#!/usr/bin/env bash
# Build, but never flash, the Frankel EP1/source-0 ring-prefill VKB/vbmeta pair.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_dir="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-pair/trial-1"
trial_root="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-prefill-pair"
output_dir=${1:-"$trial_root/trial-1"}

base_vkb="$base_dir/vendor_kernel_boot.img"
base_vbmeta="$base_dir/vbmeta.img"
patcher="$script_dir/patch_frankel_aoc_ep1_d0_ring_prefill.py"
unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"

readonly base_vkb_sha=f572f467c767f6e17f8657d1ebcd9b5d3e54c0ce7735584d444ef8428f95408a
readonly base_vbmeta_sha=da84e4b1bc0ad409d37a8ebad3feaff33107318ca1ca5037eb040fd211a5bb47
readonly base_module_sha=d0278904c384a61d9d25a44236a3e4a36c087be077b2bd6f0b971ab74b2b3cf8
readonly patched_module_sha=99bde9252fff1ade24b49e66a9f0938d6e70e2d0c41768f73be582bdb0483105
readonly old_root_vkb_digest=fbb373fab36270e08465ec5c8703d74f79ac06a3f3317a77996e49a27b5fb065
readonly expected_new_vkb_digest=09109d2e254c8be853188a19c1e7788108e617ed27dc1afc76f30c7e77598db6
readonly expected_vkb_sha=c54a94b2458e3d2eda59d526b45cc300130fa906b13832a44b18fcec343f0200
readonly expected_vbmeta_sha=7275dcf028be4adad41f2e08538abc398cf1400d6aab0a4aacca033316ed5c90
readonly raw_size=6760448
readonly partition_size=67108864
readonly avb_salt=c7cf7247dd978cb78301e952c737dc0bfce2d0b0f422785114cb20eec88f2b09b02c686cdc35246f59ee170d7693cb38761cc7b99f4c7a46b19c61902e004da9
readonly fingerprint=google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_sha() {
  local path=$1 expected=$2 observed
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
  observed=$(sha256sum -- "$path")
  observed=${observed%% *}
  [[ "$observed" == "$expected" ]] || die "unexpected input $path: $observed"
}

for command_name in awk cp cpio find grep install lz4 mkdir mktemp mv python3 \
  rm sed sha256sum sort stat touch truncate; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done
for path in "$patcher" "$unpack_bootimg" "$mkbootimg" "$avbtool" "$avb_key"; do
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
done
require_sha "$base_vkb" "$base_vkb_sha"
require_sha "$base_vbmeta" "$base_vbmeta_sha"
[[ ! -e "$output_dir" ]] || die "refusing to overwrite output: $output_dir"

mkdir -p -- "$trial_root"
stage=$(mktemp -d -- "$trial_root/.build.XXXXXX")
mkdir -p -- "$stage/final/unpacked" "$stage/final/ramdisk-root"
"$unpack_bootimg" --boot_img "$base_vkb" --out "$stage/final/unpacked" \
  > "$stage/final/vendor_kernel_boot.unpack.txt"
lz4 -dc -- "$stage/final/unpacked/vendor_ramdisk00" > "$stage/vendor_ramdisk.cpio"
(
  cd -- "$stage/final/ramdisk-root"
  cpio --quiet -idm --no-absolute-filenames < "$stage/vendor_ramdisk.cpio"
)

module="$stage/final/ramdisk-root/lib/modules/aoc_alsa_dev_util.ko"
require_sha "$module" "$base_module_sha"
python3 "$patcher" "$module" "$stage/aoc_alsa_dev_util.ep1-source0-192k-prefill.ko"
require_sha "$stage/aoc_alsa_dev_util.ep1-source0-192k-prefill.ko" "$patched_module_sha"
install -m 0644 -- "$stage/aoc_alsa_dev_util.ep1-source0-192k-prefill.ko" "$module"
python3 "$patcher" --check patched "$module"
# GNU cpio preserves directory mtimes from extraction, but extracting files
# necessarily changes their parent directories.  Normalize every archive
# member so an exact base produces an exact candidate on every run.
find "$stage/final/ramdisk-root" -exec touch -h -d @0 -- {} +

(
  cd -- "$stage/final/ramdisk-root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) > "$stage/vendor_ramdisk.patched.cpio"
lz4 -q -f -l -12 -- "$stage/vendor_ramdisk.patched.cpio" \
  "$stage/final/vendor_ramdisk00.ep1-source0-192k-prefill"

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
  --vendor_ramdisk_fragment "$stage/final/vendor_ramdisk00.ep1-source0-192k-prefill" \
  --vendor_boot "$stage/final/vendor_kernel_boot.raw.img"
repacked_size=$(stat -c %s -- "$stage/final/vendor_kernel_boot.raw.img")
(( repacked_size <= raw_size )) || die "repacked VKB is too large: $repacked_size"
truncate -s "$raw_size" -- "$stage/final/vendor_kernel_boot.raw.img"
cp -f -- "$stage/final/vendor_kernel_boot.raw.img" \
  "$stage/final/vendor_kernel_boot.img"
"$avbtool" add_hash_footer \
  --image "$stage/final/vendor_kernel_boot.img" \
  --partition_size "$partition_size" \
  --partition_name vendor_kernel_boot \
  --hash_algorithm sha256 \
  --salt "$avb_salt" \
  --prop "com.android.build.vendor_kernel_boot.fingerprint:$fingerprint"
"$avbtool" info_image --image "$stage/final/vendor_kernel_boot.img" \
  > "$stage/final/vendor_kernel_boot.info"
new_digest=$(awk '/^[[:space:]]+Digest:/ {print $2; exit}' \
  "$stage/final/vendor_kernel_boot.info")
[[ "$new_digest" =~ ^[0-9a-f]{64}$ ]] || die "could not parse VKB digest"
[[ "$new_digest" == "$expected_new_vkb_digest" ]] || \
  die "unexpected rebuilt VKB digest: $new_digest"

python3 - "$base_vbmeta" "$stage/vbmeta.descriptor-donor.img" \
  "$old_root_vkb_digest" "$new_digest" <<'PY'
import pathlib
import sys

source, output, old_hex, new_hex = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
old = bytes.fromhex(old_hex)
new = bytes.fromhex(new_hex)
if len(data) != 8192 or data.count(old) != 1:
    raise SystemExit("root vbmeta does not contain one guarded VKB digest")
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
grep -Fq "      Digest:                $new_digest" "$stage/final/vbmeta.info" || \
  die "root vbmeta lacks new VKB digest"
require_sha "$stage/final/vendor_kernel_boot.img" "$expected_vkb_sha"
require_sha "$stage/final/vbmeta.img" "$expected_vbmeta_sha"

cp -f -- "$stage/aoc_alsa_dev_util.ep1-source0-192k-prefill.ko" \
  "$stage/final/aoc_alsa_dev_util.ep1-source0-192k-prefill.ko"
{
  printf 'variant=frankel-ep1-source0-192k-d0-ring-prefill\n'
  printf 'pcm_device=0\n'
  printf 'aoc_service=audio_playback0\n'
  printf 'aoc_source=0\n'
  printf 'requires_cpu_feature=atomics (LSE)\n'
  printf 'guard_scope=D0-all-short-availability-writes\n'
  printf 'module_base_sha256=%s\n' "$base_module_sha"
  printf '%s\n' 'module_patch=0xd970:510180f9497d5f882905001149fd0b88abffff35->62e70254c8f640b91f01007100e7025472170014'
  printf '%s\n' 'module_patch=0x13658:83070054->c6e8ff17'
  printf 'intended_tinyplay=stereo-S32-192000-p480-n4\n'
  printf 'expected_d0_ring_bytes=15360\n'
  printf 'new_vendor_kernel_boot_digest=%s\n' "$new_digest"
  (
    cd -- "$stage/final"
    sha256sum -- aoc_alsa_dev_util.ep1-source0-192k-prefill.ko \
      vendor_kernel_boot.img vbmeta.img
  )
} > "$stage/final/build-audit.txt"

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
[[ "$stage" == "$trial_root"/.build.* ]] || \
  die "refusing to clean unexpected staging path: $stage"
rm -r -- "$stage"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,100p' "$output_dir/build-audit.txt"
