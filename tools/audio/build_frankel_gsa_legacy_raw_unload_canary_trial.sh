#!/usr/bin/env bash
# Build, but never flash, the Frankel raw-mailbox GSA-unload canary pair.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_dir="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-d0-mailbox-real-progress-pair/trial-1"
trial_root="$project_root/work/audio-research/frankel/gsa-legacy-raw-unload-canary"
output_dir=${1:-"$trial_root/trial-1"}
base_vkb="$base_dir/vendor_kernel_boot.img"
base_vbmeta="$base_dir/vbmeta.img"
core_patcher="$script_dir/patch_frankel_aoc_gsa_legacy_raw_unload_canary.py"
gsa_patcher="$script_dir/patch_frankel_gsa_legacy_raw_unload.py"
reference="$script_dir/aoc_gsa_legacy_raw_unload_canary.S"
unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"
clang="$aosp_dir/prebuilts/clang/host/linux-x86/clang-r596125/bin/clang"

readonly base_vkb_sha=ec2d28101a53226a4dbd45d5f0bc557e0762234ed9e9c1762449061b11958503
readonly base_vbmeta_sha=c889be3b0144cbe2d49b18b3120fed4b95f51415135abd06ca51396de4f693e3
readonly base_vkb_digest=35708da1fe9b49c67d822f8b3d23d342028f37691f50cacb9db91afecdd9189a
readonly core_base_sha=f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c
readonly gsa_base_sha=ae9ea9662c1eb7e30832235aef54c385b40521291a896fac4eb89c73945922e4
readonly raw_size=6760448
readonly partition_size=67108864
readonly avb_salt=c7cf7247dd978cb78301e952c737dc0bfce2d0b0f422785114cb20eec88f2b09b02c686cdc35246f59ee170d7693cb38761cc7b99f4c7a46b19c61902e004da9
readonly fingerprint=google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_sha() {
  local path=$1 expected=$2 observed
  [[ -f "$path" && ! -L "$path" ]] || die "missing/unsafe file: $path"
  observed=$(sha256sum -- "$path"); observed=${observed%% *}
  [[ "$observed" == "$expected" ]] || die "identity mismatch: $path ($observed)"
}

for command_name in cpio find install lz4 mktemp python3 sha256sum sort stat touch truncate; do
  command -v "$command_name" >/dev/null || die "missing command: $command_name"
done
for path in "$unpack_bootimg" "$mkbootimg" "$avbtool" "$avb_key" "$clang" \
  "$core_patcher" "$gsa_patcher" "$reference"; do
  [[ -f "$path" && ! -L "$path" ]] || die "missing/unsafe input: $path"
done
require_sha "$base_vkb" "$base_vkb_sha"
require_sha "$base_vbmeta" "$base_vbmeta_sha"
[[ ! -e "$output_dir" ]] || die "refusing to overwrite: $output_dir"

mkdir -p -- "$trial_root"
stage=$(mktemp -d -- "$trial_root/.build.XXXXXX")
cleanup() {
  if [[ -n ${stage:-} && -d "$stage" && "$stage" == "$trial_root"/.build.* ]]; then
    rm -r -- "$stage"
  fi
}
trap cleanup EXIT
mkdir -p -- "$stage/final/unpacked" "$stage/final/ramdisk-root"
"$unpack_bootimg" --boot_img "$base_vkb" --out "$stage/final/unpacked" >/dev/null
lz4 -dc -- "$stage/final/unpacked/vendor_ramdisk00" > "$stage/ramdisk.cpio"
(
  cd -- "$stage/final/ramdisk-root"
  cpio --quiet -idm --no-absolute-filenames < "$stage/ramdisk.cpio"
)

core="$stage/final/ramdisk-root/lib/modules/aoc_core.ko"
gsa="$stage/final/ramdisk-root/lib/modules/gsa.ko"
require_sha "$core" "$core_base_sha"
require_sha "$gsa" "$gsa_base_sha"
python3 "$core_patcher" "$core" "$stage/aoc_core.canary.ko"
python3 "$gsa_patcher" "$gsa" "$stage/gsa.raw-unload.ko"
install -m 0644 -- "$stage/aoc_core.canary.ko" "$core"
install -m 0644 -- "$stage/gsa.raw-unload.ko" "$gsa"
python3 "$core_patcher" "$core" --check patched
python3 "$gsa_patcher" "$gsa" --check patched
find "$stage/final/ramdisk-root" -exec touch -h -d @0 -- {} +

(
  cd -- "$stage/final/ramdisk-root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) > "$stage/ramdisk.patched.cpio"
lz4 -q -f -l -12 -- "$stage/ramdisk.patched.cpio" \
  "$stage/final/vendor_ramdisk00.gsa-legacy-raw-unload-canary"

"$mkbootimg" --header_version 4 --pagesize 2048 --base 0 \
  --kernel_offset 0x10008000 --ramdisk_offset 0x11000000 \
  --tags_offset 0x10000100 --dtb_offset 0x11f00000 \
  --vendor_cmdline '' --board '' \
  --dtb "$stage/final/unpacked/dtb" \
  --vendor_bootconfig "$stage/final/unpacked/bootconfig" \
  --ramdisk_type platform --ramdisk_name '' \
  --vendor_ramdisk_fragment "$stage/final/vendor_ramdisk00.gsa-legacy-raw-unload-canary" \
  --vendor_boot "$stage/final/vendor_kernel_boot.raw.img"
size=$(stat -c %s -- "$stage/final/vendor_kernel_boot.raw.img")
(( size <= raw_size )) || die "repacked raw image too large: $size"
truncate -s "$raw_size" -- "$stage/final/vendor_kernel_boot.raw.img"
cp -f -- "$stage/final/vendor_kernel_boot.raw.img" "$stage/final/vendor_kernel_boot.img"
"$avbtool" add_hash_footer --image "$stage/final/vendor_kernel_boot.img" \
  --partition_size "$partition_size" --partition_name vendor_kernel_boot \
  --hash_algorithm sha256 --salt "$avb_salt" \
  --prop "com.android.build.vendor_kernel_boot.fingerprint:$fingerprint"
"$avbtool" verify_image --image "$stage/final/vendor_kernel_boot.img" >/dev/null
"$avbtool" info_image --image "$stage/final/vendor_kernel_boot.img" \
  > "$stage/final/vendor_kernel_boot.info"
new_digest=$(awk '/^[[:space:]]+Digest:/ {print $2; exit}' \
  "$stage/final/vendor_kernel_boot.info")
[[ "$new_digest" =~ ^[0-9a-f]{64}$ ]] || die "could not parse new VKB digest"

python3 - "$base_vbmeta" "$stage/vbmeta.donor.img" "$base_vkb_digest" "$new_digest" <<'PY'
import pathlib, sys
source, output, old_hex, new_hex = sys.argv[1:]
data = pathlib.Path(source).read_bytes(); old = bytes.fromhex(old_hex); new = bytes.fromhex(new_hex)
if len(data) != 8192 or data.count(old) != 1:
    raise SystemExit("guarded base vbmeta digest not unique")
pathlib.Path(output).write_bytes(data.replace(old, new, 1))
PY
"$avbtool" make_vbmeta_image --output "$stage/final/vbmeta.img" \
  --padding_size 8192 --algorithm SHA256_RSA4096 --key "$avb_key" \
  --rollback_index 1780617600 --flags 0 \
  --include_descriptors_from_image "$stage/vbmeta.donor.img"
"$avbtool" info_image --image "$stage/final/vbmeta.img" > "$stage/final/vbmeta.info"
grep -Fq "      Digest:                $new_digest" "$stage/final/vbmeta.info" || \
  die "new vbmeta lacks new VKB digest"

cp -f -- "$stage/aoc_core.canary.ko" "$stage/final/aoc_core.canary.ko"
cp -f -- "$stage/gsa.raw-unload.ko" "$stage/final/gsa.raw-unload.ko"
"$clang" --target=aarch64-linux-gnu -c "$reference" \
  -o "$stage/final/aoc_gsa_legacy_raw_unload_canary.o"
{
  printf 'experiment=legacy_raw_gsa_mailbox_cmd_92_then_body_canary_then_normal_trusty_start\n'
  printf 'risk=nonboot_or_asynchronous_serror; hardware_canary_only\n'
  printf 'base_variant=proven_d0_mailbox_real_progress_trial_1\n'
  printf 'base_vendor_kernel_boot_sha256=%s\n' "$base_vkb_sha"
  printf 'base_vbmeta_sha256=%s\n' "$base_vbmeta_sha"
  printf 'body_canary=dram+0x00ceb665/runtime_f1_0x4027c8a5:53->00_with_readback\n'
  printf 'new_vendor_kernel_boot_digest=%s\n' "$new_digest"
  printf 'rollback_vendor_kernel_boot=%s\n' "$base_vkb"
  printf 'rollback_vbmeta=%s\n' "$base_vbmeta"
  (cd -- "$stage/final"; sha256sum -- aoc_core.canary.ko gsa.raw-unload.ko \
    vendor_kernel_boot.img vbmeta.img)
} > "$stage/final/build-audit.txt"

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,100p' "$output_dir/build-audit.txt"
