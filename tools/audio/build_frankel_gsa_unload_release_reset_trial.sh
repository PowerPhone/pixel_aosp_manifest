#!/usr/bin/env bash
# Build (but never flash) the bounded Frankel GSA unload/release-reset trial.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
trial_root="$project_root/work/audio-research/frankel/gsa-unload-release-reset-canary"
output_dir=${1:-"$trial_root/trial-1"}
base_dir="$project_root/work/audio-research/frankel/non-gsa-trial"
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_vkb="$base_dir/vendor_kernel_boot.current-bootable.img"
base_vbmeta="$base_dir/vbmeta.current-bootable.img"
patcher="$script_dir/patch_frankel_aoc_gsa_unload_release_reset_canary.py"
avbtool="$host_bin/avbtool"
mkbootimg="$host_bin/mkbootimg"
unpack_bootimg="$host_bin/unpack_bootimg"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"
clang="$aosp_dir/prebuilts/clang/host/linux-x86/clang-r596125/bin/clang"
reference_assembly="$script_dir/aoc_gsa_unload_release_reset_canary.S"

base_vkb_sha=7e91081ccedca980722f2684a8a53470bbfad520c77857eaaa5bf248fea94999
base_vbmeta_sha=890c6937d6baf62d653bd441a4860e9315b62fc9ac927d9971f59e2ab70316b3
stock_module_sha=23acc08d0539657e72a0bc506abf6cef9950b90b192c51fd0dd9bf2177e4f2ad
base_vkb_digest=d5a4dacae397694f76d647731c7fde9e487f9c4f0fffe18573497334a1a55460
avb_salt=c7cf7247dd978cb78301e952c737dc0bfce2d0b0f422785114cb20eec88f2b09b02c686cdc35246f59ee170d7693cb38761cc7b99f4c7a46b19c61902e004da9
vkb_fingerprint=google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_sha256() {
  local path=$1 expected=$2 observed
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe file: $path"
  observed=$(sha256sum -- "$path")
  observed=${observed%% *}
  [[ "$observed" == "$expected" ]] || \
    die "identity mismatch for $path: $observed (expected $expected)"
}

for tool in \
  "$avbtool" "$mkbootimg" "$unpack_bootimg" "$patcher" \
  "$clang" "$reference_assembly"; do
  [[ -f "$tool" && ! -L "$tool" ]] || die "missing or unsafe tool: $tool"
done
for command_name in cpio lz4 python3 sha256sum truncate; do
  command -v "$command_name" >/dev/null || die "missing command: $command_name"
done
[[ ! -e "$output_dir" ]] || die "refusing to overwrite output: $output_dir"
require_sha256 "$base_vkb" "$base_vkb_sha"
require_sha256 "$base_vbmeta" "$base_vbmeta_sha"

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
  --out "$stage/final/unpacked" >/dev/null
lz4 -dc -- "$stage/final/unpacked/vendor_ramdisk00" \
  > "$stage/vendor_ramdisk00.cpio"
(
  cd -- "$stage/final/ramdisk-root"
  cpio --quiet -idm --no-absolute-filenames < "$stage/vendor_ramdisk00.cpio"
)

stock_module="$stage/final/ramdisk-root/lib/modules/aoc_core.ko"
require_sha256 "$stock_module" "$stock_module_sha"
python3 "$patcher" --check stock "$stock_module"
patched_module="$stage/aoc_core.gsa-unload-release-reset-canary.ko"
python3 "$patcher" "$stock_module" "$patched_module"
python3 "$patcher" --check patched "$patched_module"
install -m 0644 -- "$patched_module" "$stock_module"
touch -d @0 -- "$stock_module"
python3 "$patcher" --check patched "$stock_module"

(
  cd -- "$stage/final/ramdisk-root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) > "$stage/vendor_ramdisk00.cpio.patched"
lz4 -q -f -l -12 -- "$stage/vendor_ramdisk00.cpio.patched" \
  "$stage/final/vendor_ramdisk00.gsa-unload-release-reset-canary"

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
  --vendor_ramdisk_fragment \
    "$stage/final/vendor_ramdisk00.gsa-unload-release-reset-canary" \
  --vendor_boot "$stage/final/vendor_kernel_boot.raw.img"

raw_size=$(stat -c %s -- "$stage/final/vendor_kernel_boot.raw.img")
(( raw_size <= 6760448 )) || \
  die "reconstructed vendor_kernel_boot exceeds guarded raw size: $raw_size"
# Keep the AVB descriptor's guarded image-size field unchanged.  Padding after
# the header-described components is ignored by the vendor-boot parser.
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
"$avbtool" verify_image --image "$stage/final/vendor_kernel_boot.img" \
  >/dev/null

new_vkb_digest=$(awk '/^[[:space:]]+Digest:/ {print $2; exit}' \
  "$stage/final/vendor_kernel_boot.info")
[[ "$new_vkb_digest" =~ ^[0-9a-f]{64}$ ]] || \
  die "failed to read new vendor_kernel_boot digest"

# Create a descriptor donor by changing exactly the guarded 32-byte digest in
# the known-good top-level vbmeta.  avbtool then re-authenticates the complete
# descriptor set with the same AOSP test key and build parameters.
python3 - \
  "$base_vbmeta" "$stage/vbmeta.descriptor-donor.img" \
  "$base_vkb_digest" "$new_vkb_digest" <<'PY'
import pathlib
import sys

source, output, old_hex, new_hex = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
old = bytes.fromhex(old_hex)
new = bytes.fromhex(new_hex)
if len(data) != 8192 or len(old) != 32 or len(new) != 32:
    raise SystemExit("unexpected guarded vbmeta/digest size")
if data.count(old) != 1:
    raise SystemExit("guarded old vendor_kernel_boot digest is not unique")
patched = data.replace(old, new, 1)
changed = [index for index, pair in enumerate(zip(data, patched)) if pair[0] != pair[1]]
if not changed or max(changed) - min(changed) >= 32:
    raise SystemExit("vbmeta donor changed outside one digest field")
pathlib.Path(output).write_bytes(patched)
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

grep -Fq "Public key (sha1):        2597c218aae470a130f61162feaae70afd97f011" \
  "$stage/final/vbmeta.info" || die "unexpected top-level vbmeta signing key"
grep -Fq "      Digest:                $new_vkb_digest" \
  "$stage/final/vbmeta.info" || \
  die "top-level vbmeta does not contain the new vendor_kernel_boot digest"

cp -f -- "$patched_module" \
  "$stage/final/aoc_core.gsa-unload-release-reset-canary.ko"
"$clang" --target=aarch64-linux-gnu -c "$reference_assembly" \
  -o "$stage/final/aoc_gsa_unload_release_reset_canary.o"
python3 - \
  "$stage/final/aoc_core.gsa-unload-release-reset-canary.ko" \
  "$stage/final/aoc_gsa_unload_release_reset_canary.o" <<'PY'
import pathlib
import struct
import sys

def text_section(path):
    data = pathlib.Path(path).read_bytes()
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    headers = [
        struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize)
        for i in range(shnum)
    ]
    names_header = headers[shstrndx]
    names = data[names_header[4]:names_header[4] + names_header[5]]
    for header in headers:
        end = names.find(b"\0", header[0])
        if names[header[0]:end] == b".text":
            return data[header[4]:header[4] + header[5]]
    raise SystemExit(f"missing .text in {path}")

module_text = text_section(sys.argv[1])
reference_text = text_section(sys.argv[2])
for offset, size in ((0x934, 36), (0xA9C, 8), (0xAC8, 4), (0xAF0, 4)):
    if module_text[offset:offset + size] != reference_text[offset:offset + size]:
        raise SystemExit(f"reference assembly mismatch at .text+{offset:#x}")
PY
{
  printf 'base_vendor_kernel_boot_sha256=%s\n' "$base_vkb_sha"
  printf 'base_vbmeta_sha256=%s\n' "$base_vbmeta_sha"
  printf 'stock_aoc_core_sha256=%s\n' "$stock_module_sha"
  printf 'new_vendor_kernel_boot_descriptor_digest=%s\n' "$new_vkb_digest"
  printf 'reference_assembly_verified=true\n'
  (
    cd -- "$stage/final"
    sha256sum -- \
      aoc_core.gsa-unload-release-reset-canary.ko \
      vendor_ramdisk00.gsa-unload-release-reset-canary \
      vendor_kernel_boot.raw.img \
      vendor_kernel_boot.img \
      vbmeta.img
  )
} > "$stage/final/build-audit.txt"

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'built (not flashed): %s\n' "$output_dir"
cat -- "$output_dir/build-audit.txt"
