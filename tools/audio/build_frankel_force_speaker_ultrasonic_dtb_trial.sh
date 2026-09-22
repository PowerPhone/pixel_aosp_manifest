#!/usr/bin/env bash
# Build, but never flash, a Frankel vendor-kernel boot pair whose first AoC
# boot receives kAOCForceSpeakerUltrasonic=1 from the device tree.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_dir="$project_root/work/audio-research/frankel/speaker-ep6-source5-d5-timer-trial"
trial_root="$project_root/work/audio-research/frankel/force-speaker-ultrasonic-dtb-trial"
output_dir=${1:-"$trial_root/candidate"}

base_vkb="$base_dir/vendor_kernel_boot.img"
base_vbmeta="$base_dir/vbmeta-powerphone.img"
unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"

readonly raw_partition_payload_size=6760448
readonly partition_size=67108864
readonly avb_salt=c7cf7247dd978cb78301e952c737dc0bfce2d0b0f422785114cb20eec88f2b09b02c686cdc35246f59ee170d7693cb38761cc7b99f4c7a46b19c61902e004da9
readonly vkb_fingerprint=google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for path in "$base_vkb" "$base_vbmeta" "$unpack_bootimg" "$mkbootimg" \
  "$avbtool" "$avb_key"; do
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
done
for command_name in awk cp dd fdtget fdtput grep mkdir mktemp mv python3 \
  sed sha256sum stat truncate; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done
[[ ! -e "$output_dir" ]] || die "refusing to overwrite output: $output_dir"

mkdir -p -- "$trial_root"
stage=$(mktemp -d -- "$trial_root/.build.XXXXXX")
mkdir -p -- "$stage/final/unpacked"

"$unpack_bootimg" --boot_img "$base_vkb" \
  --out "$stage/final/unpacked" > "$stage/final/vendor_kernel_boot.unpack.txt"

# Frankel's vendor-kernel boot image contains two concatenated, unpadded FDTs.
# Parse their guarded totalsizes rather than assuming a board variant, then set
# the same AoC boot-data property in both candidates.
python3 - "$stage/final/unpacked/dtb" "$stage/dtb-layout.txt" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_bytes()
offset = 0
rows = []
while offset < len(source):
    if source[offset:offset + 4] != b"\xd0\x0d\xfe\xed":
        raise SystemExit(f"invalid FDT magic at 0x{offset:x}")
    size = int.from_bytes(source[offset + 4:offset + 8], "big")
    if size < 40 or offset + size > len(source):
        raise SystemExit(f"invalid FDT totalsize {size} at 0x{offset:x}")
    rows.append((offset, size))
    offset += size
if offset != len(source) or len(rows) != 2:
    raise SystemExit(f"expected exactly two packed FDTs, got {rows}")
pathlib.Path(sys.argv[2]).write_text(
    "".join(f"{offset} {size}\n" for offset, size in rows),
    encoding="ascii",
)
PY

patched_dtb="$stage/final/dtb.force-speaker-ultrasonic"
index=0
while read -r offset size; do
  fragment="$stage/dtb.$index"
  dd if="$stage/final/unpacked/dtb" of="$fragment" bs=1 \
    skip="$offset" count="$size" status=none
  [[ $(fdtget "$fragment" /aoc@9000000 compatible) == google,aoc ]] || \
    die "FDT $index has no reviewed /aoc@9000000 node"
  fdtput -t i "$fragment" /aoc@9000000 force-speaker-ultrasonic 1
  [[ $(fdtget -t i "$fragment" /aoc@9000000 force-speaker-ultrasonic) == 1 ]] || \
    die "FDT $index did not retain force-speaker-ultrasonic=1"
  if (( index == 0 )); then
    cp -f -- "$fragment" "$patched_dtb"
  else
    dd if="$fragment" of="$patched_dtb" bs=1 oflag=append conv=notrunc status=none
  fi
  index=$((index + 1))
done < "$stage/dtb-layout.txt"
(( index == 2 )) || die "did not patch both Frankel FDTs"

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
  --dtb "$patched_dtb" \
  --vendor_bootconfig "$stage/final/unpacked/bootconfig" \
  --ramdisk_type platform \
  --ramdisk_name '' \
  --vendor_ramdisk_fragment "$stage/final/unpacked/vendor_ramdisk00" \
  --vendor_boot "$stage/final/vendor_kernel_boot.raw.img"

raw_size=$(stat -c %s -- "$stage/final/vendor_kernel_boot.raw.img")
(( raw_size <= raw_partition_payload_size )) || \
  die "repacked image is too large: $raw_size"
truncate -s "$raw_partition_payload_size" -- \
  "$stage/final/vendor_kernel_boot.raw.img"
cp -f -- "$stage/final/vendor_kernel_boot.raw.img" \
  "$stage/final/vendor_kernel_boot.img"
"$avbtool" add_hash_footer \
  --image "$stage/final/vendor_kernel_boot.img" \
  --partition_size "$partition_size" \
  --partition_name vendor_kernel_boot \
  --hash_algorithm sha256 \
  --salt "$avb_salt" \
  --prop "com.android.build.vendor_kernel_boot.fingerprint:$vkb_fingerprint"
"$avbtool" info_image --image "$base_vkb" > "$stage/base-vkb.info"
"$avbtool" info_image --image "$stage/final/vendor_kernel_boot.img" \
  > "$stage/final/vendor_kernel_boot.info"
old_digest=$(awk '/^[[:space:]]+Digest:/ {print $2; exit}' "$stage/base-vkb.info")
new_digest=$(awk '/^[[:space:]]+Digest:/ {print $2; exit}' \
  "$stage/final/vendor_kernel_boot.info")
[[ "$old_digest" =~ ^[0-9a-f]{64}$ && "$new_digest" =~ ^[0-9a-f]{64}$ ]] || \
  die "could not parse vendor_kernel_boot AVB digests"

python3 - "$base_vbmeta" "$stage/vbmeta.descriptor-donor.img" \
  "$old_digest" "$new_digest" <<'PY'
import pathlib
import sys

source, output, old_hex, new_hex = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
old = bytes.fromhex(old_hex)
new = bytes.fromhex(new_hex)
if len(data) != 8192 or data.count(old) != 1:
    raise SystemExit("root vbmeta does not contain one guarded old digest")
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
  "$stage/final/vbmeta.info" || die "root vbmeta lacks the new VKB digest"

{
  printf 'variant=frankel-force-speaker-ultrasonic-dtb\n'
  printf 'base=%s\n' "$base_dir"
  printf 'fdt_count=2\n'
  printf 'property=/aoc@9000000/force-speaker-ultrasonic=1\n'
  printf 'old_vendor_kernel_boot_digest=%s\n' "$old_digest"
  printf 'new_vendor_kernel_boot_digest=%s\n' "$new_digest"
  (
    cd -- "$stage/final"
    sha256sum -- vendor_kernel_boot.img vbmeta.img
  )
} > "$stage/final/build-audit.txt"

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,80p' "$output_dir/build-audit.txt"
