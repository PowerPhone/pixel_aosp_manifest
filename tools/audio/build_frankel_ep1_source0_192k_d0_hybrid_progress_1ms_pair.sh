#!/usr/bin/env bash
# Build, but never flash, Frankel's EP1/source-0 D0 host-progress pair.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_dir="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-prefill-pair/trial-1"
progress_mode=${D0_PROGRESS_MODE:-hybrid}
case "$progress_mode" in
  hybrid)
    trial_root="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-d0-hybrid-progress-1ms-pair"
    artifact_stem=aoc_alsa_dev_util.ep1-source0-192k-prefill-d0-hybrid-1ms
    variant=frankel-ep1-source0-192k-d0-ring-prefill-d0-hybrid-progress-1ms
    progress_description='D0 hybrid mailbox plus host hrtimer'
    ;;
  pure-timer)
    trial_root="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-d0-pure-timer-1ms-pair"
    artifact_stem=aoc_alsa_dev_util.ep1-source0-192k-prefill-d0-pure-timer-1ms
    variant=frankel-ep1-source0-192k-d0-ring-prefill-d0-pure-timer-1ms
    progress_description='D0 pure host hrtimer; mailbox prvdata disconnected'
    ;;
  *)
    printf 'error: unsupported D0_PROGRESS_MODE: %s\n' "$progress_mode" >&2
    exit 2
    ;;
esac
output_dir=${1:-"$trial_root/trial-1"}

base_vkb="$base_dir/vendor_kernel_boot.img"
base_vbmeta="$base_dir/vbmeta.img"
patcher="$script_dir/patch_frankel_aoc_ep1_d0_hybrid_progress_1ms.py"
pure_timer_patcher="$script_dir/patch_frankel_aoc_ep1_d0_pure_timer_1ms.py"
unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"

readonly base_vkb_sha=c54a94b2458e3d2eda59d526b45cc300130fa906b13832a44b18fcec343f0200
readonly base_vbmeta_sha=7275dcf028be4adad41f2e08538abc398cf1400d6aab0a4aacca033316ed5c90
readonly base_module_sha=99bde9252fff1ade24b49e66a9f0938d6e70e2d0c41768f73be582bdb0483105
readonly hybrid_module_sha=a25094fcb9f1d01a883f2c9830b31a85ed161062de34f0de54f5bc15037e0c31
readonly pure_timer_module_sha=0b7150789ed60b53fff596a1239ecc6c968730d7d800f05ecb1128ce70057ebe
if [[ "$progress_mode" == pure-timer ]]; then
  readonly patched_module_sha=$pure_timer_module_sha
else
  readonly patched_module_sha=$hybrid_module_sha
fi
readonly old_root_vkb_digest=09109d2e254c8be853188a19c1e7788108e617ed27dc1afc76f30c7e77598db6
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
for path in "$patcher" "$pure_timer_patcher" "$unpack_bootimg" "$mkbootimg" "$avbtool" "$avb_key"; do
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
hybrid_candidate="$stage/aoc_alsa_dev_util.ep1-source0-192k-prefill-d0-hybrid-1ms.ko"
candidate="$stage/$artifact_stem.ko"
python3 "$patcher" "$module" "$hybrid_candidate"
if [[ "$progress_mode" == pure-timer ]]; then
  python3 "$pure_timer_patcher" "$hybrid_candidate" "$candidate"
else
  candidate=$hybrid_candidate
fi
require_sha "$candidate" "$patched_module_sha"
install -m 0644 -- "$candidate" "$module"
if [[ "$progress_mode" == pure-timer ]]; then
  python3 "$pure_timer_patcher" --check pure-timer "$module"
else
  python3 "$patcher" --check d0-hybrid-1ms "$module"
fi
find "$stage/final/ramdisk-root" -exec touch -h -d @0 -- {} +

(
  cd -- "$stage/final/ramdisk-root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) > "$stage/vendor_ramdisk.patched.cpio"
lz4 -q -f -l -12 -- "$stage/vendor_ramdisk.patched.cpio" \
  "$stage/final/vendor_ramdisk00.ep1-source0-192k-$progress_mode-1ms"

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
  --vendor_ramdisk_fragment "$stage/final/vendor_ramdisk00.ep1-source0-192k-$progress_mode-1ms" \
  --vendor_boot "$stage/final/vendor_kernel_boot.raw.img"
repacked_size=$(stat -c %s -- "$stage/final/vendor_kernel_boot.raw.img")
(( repacked_size <= raw_size )) || die "repacked VKB is too large: $repacked_size"
truncate -s "$raw_size" -- "$stage/final/vendor_kernel_boot.raw.img"
cp -f -- "$stage/final/vendor_kernel_boot.raw.img" "$stage/final/vendor_kernel_boot.img"
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

cp -f -- "$candidate" "$stage/final/$artifact_stem.ko"
{
  printf 'variant=%s\n' "$variant"
  printf 'base_variant=frankel-ep1-source0-192k-d0-ring-prefill\n'
  printf 'pcm_device=0\n'
  printf 'aoc_service=audio_playback0\n'
  printf 'aoc_source=0\n'
  printf 'progress_mode=%s\n' "$progress_description"
  printf 'host_timer_interval_ns=1000000\n'
  printf 'other_main_pcm_progress=stock mailbox selection\n'
  printf 'intended_tinyplay=stereo-S32-192000-p480-n4\n'
  printf 'expected_d0_ring_bytes=15360\n'
  printf 'old_vendor_kernel_boot_digest=%s\n' "$old_root_vkb_digest"
  printf 'new_vendor_kernel_boot_digest=%s\n' "$new_digest"
  (
    cd -- "$stage/final"
    sha256sum -- "$artifact_stem.ko" \
      vendor_kernel_boot.img vbmeta.img
  )
} > "$stage/final/build-audit.txt"

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
[[ "$stage" == "$trial_root"/.build.* ]] || die "refusing unexpected staging cleanup: $stage"
rm -r -- "$stage"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,100p' "$output_dir/build-audit.txt"
