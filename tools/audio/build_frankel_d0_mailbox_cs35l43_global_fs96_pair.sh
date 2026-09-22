#!/usr/bin/env bash
# Build, but never flash, the D0-mailbox pair with the CS35L43 192 kHz fix.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_dir="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-d0-mailbox-real-progress-pair/trial-1"
module="$project_root/work/upstream/frankel-gki-15739706/modules/snd-soc-cs35l43.stock-global-fs96.ko"
module_patcher="$script_dir/patch_frankel_cs35l43_global_fs96.py"
trial_root="$project_root/work/audio-research/frankel/speaker-d0-mailbox-cs35l43-stock-global-fs96-pair"
output_dir=${1:-"$trial_root/trial-1"}

unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"
base_vkb="$base_dir/vendor_kernel_boot.img"
base_vbmeta="$base_dir/vbmeta.img"

readonly base_vkb_sha=ec2d28101a53226a4dbd45d5f0bc557e0762234ed9e9c1762449061b11958503
readonly base_vbmeta_sha=c889be3b0144cbe2d49b18b3120fed4b95f51415135abd06ca51396de4f693e3
readonly base_vkb_digest=35708da1fe9b49c67d822f8b3d23d342028f37691f50cacb9db91afecdd9189a
readonly stock_cs35_sha=8db0c2795f11585cb3d30382169606130e5f8aa9b6c001b6508b758b29ca99d3
readonly replacement_cs35_sha=fc631fc227ab2e7e8cfa2d664e97ac7cca4c14324fb2a39479fc8e79aa358a3a
readonly mailbox_alsa_sha=fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0
readonly raw_size=6760448
readonly partition_size=67108864
readonly avb_salt=c7cf7247dd978cb78301e952c737dc0bfce2d0b0f422785114cb20eec88f2b09b02c686cdc35246f59ee170d7693cb38761cc7b99f4c7a46b19c61902e004da9
readonly fingerprint=google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_sha() {
  local path=$1 expected=$2 observed
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
  observed=$(sha256sum -- "$path"); observed=${observed%% *}
  [[ "$observed" == "$expected" ]] || die "identity mismatch: $path ($observed)"
}

for command_name in awk cpio find grep install lz4 mktemp python3 sha256sum \
    sort stat touch truncate; do
  command -v "$command_name" >/dev/null || die "missing command: $command_name"
done
for path in "$unpack_bootimg" "$mkbootimg" "$avbtool" "$avb_key" \
    "$module_patcher"; do
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
done
require_sha "$base_vkb" "$base_vkb_sha"
require_sha "$base_vbmeta" "$base_vbmeta_sha"
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
lz4 -dc -- "$stage/final/unpacked/vendor_ramdisk00" > "$stage/ramdisk.cpio"
(
  cd -- "$stage/final/ramdisk-root"
  cpio --quiet -idm --no-absolute-filenames < "$stage/ramdisk.cpio"
)

cs35="$stage/final/ramdisk-root/lib/modules/snd-soc-cs35l43.ko"
alsa="$stage/final/ramdisk-root/lib/modules/aoc_alsa_dev_util.ko"
require_sha "$cs35" "$stock_cs35_sha"
require_sha "$alsa" "$mailbox_alsa_sha"
"$module_patcher" "$cs35" "$module"
require_sha "$module" "$replacement_cs35_sha"
install -m 0644 -- "$module" "$cs35"
require_sha "$cs35" "$replacement_cs35_sha"
require_sha "$alsa" "$mailbox_alsa_sha"

find "$stage/final/ramdisk-root" -exec touch -h -d @0 -- {} +
(
  cd -- "$stage/final/ramdisk-root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) > "$stage/ramdisk.patched.cpio"
lz4 -q -f -l -12 -- "$stage/ramdisk.patched.cpio" \
  "$stage/final/vendor_ramdisk00.cs35l43-global-fs96"

"$mkbootimg" --header_version 4 --pagesize 2048 --base 0 \
  --kernel_offset 0x10008000 --ramdisk_offset 0x11000000 \
  --tags_offset 0x10000100 --dtb_offset 0x11f00000 \
  --vendor_cmdline '' --board '' \
  --dtb "$stage/final/unpacked/dtb" \
  --vendor_bootconfig "$stage/final/unpacked/bootconfig" \
  --ramdisk_type platform --ramdisk_name '' \
  --vendor_ramdisk_fragment "$stage/final/vendor_ramdisk00.cs35l43-global-fs96" \
  --vendor_boot "$stage/final/vendor_kernel_boot.raw.img"
repacked_size=$(stat -c %s -- "$stage/final/vendor_kernel_boot.raw.img")
(( repacked_size <= raw_size )) || die "repacked raw image too large: $repacked_size"
truncate -s "$raw_size" -- "$stage/final/vendor_kernel_boot.raw.img"
cp --reflink=auto -- "$stage/final/vendor_kernel_boot.raw.img" \
  "$stage/final/vendor_kernel_boot.img"
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

python3 - "$base_vbmeta" "$stage/vbmeta.donor.img" \
    "$base_vkb_digest" "$new_digest" <<'PY'
import pathlib
import sys

source, output, old_hex, new_hex = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
old = bytes.fromhex(old_hex)
new = bytes.fromhex(new_hex)
if len(data) != 8192 or data.count(old) != 1:
    raise SystemExit("guarded base vendor_kernel_boot digest is not unique")
pathlib.Path(output).write_bytes(data.replace(old, new, 1))
PY
"$avbtool" make_vbmeta_image --output "$stage/final/vbmeta.img" \
  --padding_size 8192 --algorithm SHA256_RSA4096 --key "$avb_key" \
  --rollback_index 1780617600 --flags 0 \
  --include_descriptors_from_image "$stage/vbmeta.donor.img"
"$avbtool" info_image --image "$stage/final/vbmeta.img" \
  > "$stage/final/vbmeta.info"
grep -Fq "      Digest:                $new_digest" \
  "$stage/final/vbmeta.info" || die "new vbmeta lacks the new VKB digest"

cp --reflink=auto -- "$module" \
  "$stage/final/snd-soc-cs35l43.stock-global-fs96.ko"
cp --reflink=auto -- "$alsa" \
  "$stage/final/aoc_alsa_dev_util.d0-mailbox-real-progress.ko"
{
  printf 'variant=frankel-d0-mailbox-cs35l43-stock-global-fs96\n'
  printf 'base_variant=frankel-ep1-source0-192k-d0-mailbox-real-progress-trial-1\n'
  printf 'cs35l43_change=exact stock module one instruction: ultrasonic GLOBAL_FS 48000 to 96000; FSX2 amplifier path=192000\n'
  printf 'route=PCM Source Zero; High Rate PCM Source ASPRX1; Ultrasonic Mode In Band or Out of Band\n'
  printf 'preserved_aoc_alsa_dev_util_sha256=%s\n' "$mailbox_alsa_sha"
  printf 'replacement_cs35l43_sha256=%s\n' "$replacement_cs35_sha"
  printf 'new_vendor_kernel_boot_digest=%s\n' "$new_digest"
  (cd -- "$stage/final" && sha256sum -- \
    aoc_alsa_dev_util.d0-mailbox-real-progress.ko \
    snd-soc-cs35l43.stock-global-fs96.ko vendor_kernel_boot.img vbmeta.img)
} > "$stage/final/build-audit.txt"

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,100p' "$output_dir/build-audit.txt"
