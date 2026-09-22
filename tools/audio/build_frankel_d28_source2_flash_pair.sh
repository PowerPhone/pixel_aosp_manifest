#!/usr/bin/env bash
# Turn the already-reviewed D28 SOURCE2 kernel trial into a current AVB flash pair.
# This builds only; it never talks to a device.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
source_dir="$project_root/work/audio-research/frankel/speaker-d28-source2-selective-trial"
root_base_dir="$project_root/work/audio-research/frankel/speaker-ep6-source5-d5-timer-trial"
trial_root="$project_root/work/audio-research/frankel/speaker-d28-source2-flash-pair"
output_dir=${1:-"$trial_root/trial-1"}

source_vkb="$source_dir/vendor_kernel_boot.img"
source_module="$source_dir/aoc_alsa_dev_util.ko"
base_vbmeta="$root_base_dir/vbmeta-powerphone.img"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"

readonly source_vkb_sha=908707d26986fb49a50864a4017af9141d79c88d784a161953e61af6b7afe6c0
readonly source_module_sha=c0946ae1d28518805e966937d3d02ea4b7f97d1f9a8afec92231dde051c84017
readonly old_root_vkb_digest=6d5aec60509a9f6fdfb0dd2aef05ce9e00752f2d36c3f83d9f2c83099b32b427
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

for command_name in awk cp grep mkdir mktemp mv python3 sed sha256sum truncate; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done
for path in "$base_vbmeta" "$avbtool" "$avb_key"; do
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
done
require_sha "$source_vkb" "$source_vkb_sha"
require_sha "$source_module" "$source_module_sha"
[[ ! -e "$output_dir" ]] || die "refusing to overwrite output: $output_dir"

mkdir -p -- "$trial_root"
stage=$(mktemp -d -- "$trial_root/.build.XXXXXX")
mkdir -p -- "$stage/final"

# Drop the older self-describing footer, retain the exact reviewed boot payload,
# then describe it with the salt and fingerprint used by this AOSP image set.
cp -f -- "$source_vkb" "$stage/final/vendor_kernel_boot.img"
truncate -s "$raw_size" -- "$stage/final/vendor_kernel_boot.img"
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
[[ "$new_digest" =~ ^[0-9a-f]{64}$ ]] || die "could not parse new VKB digest"

python3 - "$base_vbmeta" "$stage/vbmeta.descriptor-donor.img" \
  "$old_root_vkb_digest" "$new_digest" <<'PY'
import pathlib
import sys

source, output, old_hex, new_hex = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
old = bytes.fromhex(old_hex)
new = bytes.fromhex(new_hex)
if len(data) != 8192 or data.count(old) != 1:
    raise SystemExit("root vbmeta does not contain exactly one guarded VKB digest")
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
grep -Fq "      Digest:                $new_digest" \
  "$stage/final/vbmeta.info" || die "root vbmeta lacks new VKB digest"

cp -f -- "$source_module" "$stage/final/aoc_alsa_dev_util.source2.ko"
{
  printf 'variant=frankel-d28-source2-selective\n'
  printf 'source_command=0x1401\n'
  printf 'new_vendor_kernel_boot_digest=%s\n' "$new_digest"
  (
    cd -- "$stage/final"
    sha256sum -- vendor_kernel_boot.img vbmeta.img aoc_alsa_dev_util.source2.ko
  )
} > "$stage/final/build-audit.txt"

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,80p' "$output_dir/build-audit.txt"
