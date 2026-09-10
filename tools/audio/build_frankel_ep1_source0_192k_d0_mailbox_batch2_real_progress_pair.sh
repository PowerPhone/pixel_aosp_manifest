#!/usr/bin/env bash
# Build, but never flash, the D0 real-mailbox/two-period-batch experiment.
# Root vbmeta is omitted unless FRANKEL_ROOT_IMAGE_SET explicitly names a
# complete, internally verified current image bundle.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_dir="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-d0-mailbox-real-progress-pair/trial-1"
trial_root="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-d0-mailbox-batch2-real-progress-pair"
output_dir=${1:-"$trial_root/trial-1"}

base_vkb="$base_dir/vendor_kernel_boot.img"
patcher="$script_dir/patch_frankel_aoc_ep1_d0_mailbox_batch2_real_progress.py"
unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"
vbmeta_builder="$script_dir/make_frankel_experimental_vbmeta.sh"
root_image_set=${FRANKEL_ROOT_IMAGE_SET:-}

readonly base_vkb_sha=ec2d28101a53226a4dbd45d5f0bc557e0762234ed9e9c1762449061b11958503
readonly base_module_sha=fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0
readonly patched_module_sha=3a37fab7d6f47e36edd0c852919457267586d0c4d948356e67c7b46ba5ec51e5
readonly fixed_core_sha=f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c
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
  realpath rm sed sha256sum sort stat touch truncate; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done
for path in "$patcher" "$unpack_bootimg" "$mkbootimg" "$avbtool" "$avb_key" \
    "$vbmeta_builder"; do
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
done
require_sha "$base_vkb" "$base_vkb_sha"
[[ ! -e "$output_dir" ]] || die "refusing to overwrite output: $output_dir"

mkdir -p -- "$trial_root"
stage=$(mktemp -d -- "$trial_root/.build.XXXXXX")
cleanup() {
  if [[ -n ${stage:-} && -d "$stage" && "$stage" == "$trial_root"/.build.* ]]; then
    rm -r -- "$stage"
  fi
}
trap cleanup EXIT

mkdir -p -- "$stage/final/unpacked" "$stage/final/ramdisk-root"
"$unpack_bootimg" --boot_img "$base_vkb" --out "$stage/final/unpacked" \
  > "$stage/final/vendor_kernel_boot.unpack.txt"
lz4 -dc -- "$stage/final/unpacked/vendor_ramdisk00" > "$stage/vendor_ramdisk.cpio"
(
  cd -- "$stage/final/ramdisk-root"
  cpio --quiet -idm --no-absolute-filenames < "$stage/vendor_ramdisk.cpio"
)

module="$stage/final/ramdisk-root/lib/modules/aoc_alsa_dev_util.ko"
core_module="$stage/final/ramdisk-root/lib/modules/aoc_core.ko"
candidate="$stage/aoc_alsa_dev_util.ep1-source0-192k-d0-mailbox-batch2-real-progress.ko"
require_sha "$module" "$base_module_sha"
require_sha "$core_module" "$fixed_core_sha"
python3 "$patcher" "$module" "$candidate"
require_sha "$candidate" "$patched_module_sha"
install -m 0644 -- "$candidate" "$module"
python3 "$patcher" "$module" --check d0-mailbox-batch2-real-progress
find "$stage/final/ramdisk-root" -exec touch -h -d @0 -- {} +

(
  cd -- "$stage/final/ramdisk-root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) > "$stage/vendor_ramdisk.patched.cpio"
lz4 -q -f -l -12 -- "$stage/vendor_ramdisk.patched.cpio" \
  "$stage/final/vendor_ramdisk00.ep1-source0-192k-d0-mailbox-batch2-real-progress"

"$mkbootimg" \
  --header_version 4 --pagesize 2048 --base 0 \
  --kernel_offset 0x10008000 --ramdisk_offset 0x11000000 \
  --tags_offset 0x10000100 --dtb_offset 0x11f00000 \
  --vendor_cmdline '' --board '' \
  --dtb "$stage/final/unpacked/dtb" \
  --vendor_bootconfig "$stage/final/unpacked/bootconfig" \
  --ramdisk_type platform --ramdisk_name '' \
  --vendor_ramdisk_fragment \
    "$stage/final/vendor_ramdisk00.ep1-source0-192k-d0-mailbox-batch2-real-progress" \
  --vendor_boot "$stage/final/vendor_kernel_boot.raw.img"
repacked_size=$(stat -c %s -- "$stage/final/vendor_kernel_boot.raw.img")
(( repacked_size <= raw_size )) || die "repacked VKB is too large: $repacked_size"
truncate -s "$raw_size" -- "$stage/final/vendor_kernel_boot.raw.img"
cp -f -- "$stage/final/vendor_kernel_boot.raw.img" "$stage/final/vendor_kernel_boot.img"
"$avbtool" add_hash_footer \
  --image "$stage/final/vendor_kernel_boot.img" \
  --partition_size "$partition_size" --partition_name vendor_kernel_boot \
  --hash_algorithm sha256 --salt "$avb_salt" \
  --prop "com.android.build.vendor_kernel_boot.fingerprint:$fingerprint"
"$avbtool" verify_image --image "$stage/final/vendor_kernel_boot.img" >/dev/null
"$avbtool" info_image --image "$stage/final/vendor_kernel_boot.img" \
  > "$stage/final/vendor_kernel_boot.info"
new_digest=$(awk '/^[[:space:]]+Digest:/ {print $2; exit}' \
  "$stage/final/vendor_kernel_boot.info")
[[ "$new_digest" =~ ^[0-9a-f]{64}$ ]] || die "could not parse VKB digest"

if [[ -n "$root_image_set" ]]; then
  root_image_set=$(realpath -e -- "$root_image_set")
  "$vbmeta_builder" --image-set "$root_image_set" \
    --vendor-kernel-boot "$stage/final/vendor_kernel_boot.img" \
    --output "$stage/final/vbmeta.img" --avbtool "$avbtool" --key "$avb_key"
  printf 'paired_root_image_set=%s\n' "$root_image_set" \
    > "$stage/final/ROOT_IMAGE_SET.txt"
  "$avbtool" info_image --image "$root_image_set/vbmeta.img" \
    > "$stage/final/ROOT_VBMETA_SOURCE.info"
  vbmeta_mode=explicit-verified-root-image-set
else
  cat > "$stage/final/KERNEL_ONLY.txt" <<'EOF'
This experiment intentionally contains no vbmeta.img.

Flash vendor_kernel_boot.img alone, preserving the currently installed root
vbmeta. To deliberately build a matched pair, rerun with
FRANKEL_ROOT_IMAGE_SET=/absolute/path/to/a/complete/current/image/bundle.
EOF
  vbmeta_mode=kernel-only
fi

cp -f -- "$candidate" "$stage/final/$(basename -- "$candidate")"
{
  printf 'variant=frankel-ep1-source0-192k-d0-mailbox-batch2-real-progress\n'
  printf 'base_variant=frankel-ep1-source0-192k-d0-mailbox-real-progress\n'
  printf 'pcm_device=0\n'
  printf 'aoc_service=audio_playback0\n'
  printf 'progress_mode=D0 stock mailbox ISR; max two real AoC Rx periods per notification\n'
  printf 'position_source=real AoC Rx ring counter\n'
  printf 'synthetic_progress=none\n'
  printf 'host_timer=none\n'
  printf 'prefill_or_short_availability_bypass=none\n'
  printf 'period_delivery=existing deferred ordered WQ_HIGHPRI workqueue\n'
  printf 'mailbox_synchronous_period_elapsed=none\n'
  printf 'intended_tinyplay=stereo-S32-192000-p480-n4\n'
  printf 'expected_d0_ring_bytes=15360\n'
  printf 'aoc_core_sha256=%s\n' "$fixed_core_sha"
  printf 'aoc_alsa_dev_util_sha256=%s\n' "$patched_module_sha"
  printf 'new_vendor_kernel_boot_digest=%s\n' "$new_digest"
  printf 'root_vbmeta_mode=%s\n' "$vbmeta_mode"
  if [[ "$vbmeta_mode" == explicit-verified-root-image-set ]]; then
    printf 'root_image_set=%s\n' "$root_image_set"
    (cd -- "$stage/final"; sha256sum -- "$(basename -- "$candidate")" \
      vendor_kernel_boot.img vbmeta.img ROOT_IMAGE_SET.txt \
      ROOT_VBMETA_SOURCE.info)
  else
    (cd -- "$stage/final"; sha256sum -- "$(basename -- "$candidate")" \
      vendor_kernel_boot.img KERNEL_ONLY.txt)
  fi
} > "$stage/final/build-audit.txt"

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,100p' "$output_dir/build-audit.txt"
