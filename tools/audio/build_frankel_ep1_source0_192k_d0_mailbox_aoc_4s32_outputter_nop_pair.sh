#!/usr/bin/env bash
# Build, but never flash, a combined cold-AoC/vendor + proven mailbox VKB set.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_bundle="$project_root/artifacts/frankel/powerphone"
mailbox_dir="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-d0-mailbox-real-progress-pair/trial-1"
trial_root="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-d0-mailbox-firmware-4s32-a32-outputter-nop-pair"
output_dir=${1:-"$trial_root/trial-1"}

base_vendor="$base_bundle/vendor.img"
base_vkb="$mailbox_dir/vendor_kernel_boot.img"
base_vbmeta="$mailbox_dir/vbmeta.img"
patcher="$script_dir/patch_frankel_aoc_firmware_speaker_192k.py"
avbtool="$host_bin/avbtool"
unpack_bootimg="$host_bin/unpack_bootimg"
e2fsck="$host_bin/e2fsck"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"

readonly base_vendor_sha=da40c3f99af0b563f227c31943af4117ce867d3b05467f1b4d82228e8e7863cb
readonly base_vkb_sha=ec2d28101a53226a4dbd45d5f0bc557e0762234ed9e9c1762449061b11958503
readonly base_vbmeta_sha=c889be3b0144cbe2d49b18b3120fed4b95f51415135abd06ca51396de4f693e3
readonly stock_aoc_sha=ac6d7d86e6aa78379bfa3db5eaea4dadebf8113dc8f46aab52d55f3987064abd
readonly patched_aoc_sha=fc7ff0c927c1d11b3f3e9d186ab1687baee1bab33c804ab1a4a4fe58699d5779
readonly mailbox_alsa_sha=fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0
readonly fixed_core_sha=f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c
readonly base_vendor_root_digest=9ebe9af31c072466ac0f93368c28f303d47a1222240d1d5e1d4bd0543081cb6f
readonly mailbox_vkb_digest=35708da1fe9b49c67d822f8b3d23d342028f37691f50cacb9db91afecdd9189a
readonly vendor_partition_size=1039167488
readonly vendor_original_size=1022685184
readonly vendor_salt=dcd48d5711cff33e8b2a6825a28ec51b763a71060eaabe97d0a0203ac1eaf08b
readonly fingerprint=google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_sha() {
  local path=$1 expected=$2 observed
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
  observed=$(sha256sum -- "$path")
  observed=${observed%% *}
  [[ "$observed" == "$expected" ]] || die "unexpected input $path: $observed"
}

for command_name in awk cmp cp cpio debugfs grep lz4 mkdir mktemp mv \
  python3 rm sha256sum stat; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done
for path in "$patcher" "$avbtool" "$unpack_bootimg" "$e2fsck" "$avb_key"; do
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
done
require_sha "$base_vendor" "$base_vendor_sha"
require_sha "$base_vkb" "$base_vkb_sha"
require_sha "$base_vbmeta" "$base_vbmeta_sha"
[[ ! -e "$output_dir" ]] || die "refusing to overwrite output: $output_dir"

mkdir -p -- "$trial_root"
stage=$(mktemp -d -- "$trial_root/.build.XXXXXX")
mkdir -p -- "$stage/final/unpacked-vkb" "$stage/final/vkb-ramdisk-root"

# Keep the hardware-qualified mailbox-only VKB byte-for-byte unchanged.
cp --reflink=auto -- "$base_vkb" "$stage/final/vendor_kernel_boot.img"
require_sha "$stage/final/vendor_kernel_boot.img" "$base_vkb_sha"
"$unpack_bootimg" --boot_img "$stage/final/vendor_kernel_boot.img" \
  --out "$stage/final/unpacked-vkb" > "$stage/final/vendor_kernel_boot.unpack.txt"
lz4 -dc -- "$stage/final/unpacked-vkb/vendor_ramdisk00" > "$stage/vkb-ramdisk.cpio"
(
  cd -- "$stage/final/vkb-ramdisk-root"
  cpio --quiet -idm --no-absolute-filenames < "$stage/vkb-ramdisk.cpio"
)
require_sha "$stage/final/vkb-ramdisk-root/lib/modules/aoc_alsa_dev_util.ko" "$mailbox_alsa_sha"
require_sha "$stage/final/vkb-ramdisk-root/lib/modules/aoc_core.ko" "$fixed_core_sha"
cp -f -- "$stage/final/vkb-ramdisk-root/lib/modules/aoc_alsa_dev_util.ko" \
  "$stage/final/aoc_alsa_dev_util.ep1-source0-192k-d0-mailbox-real-progress.ko"

# Start from the exact installed PowerPhone vendor image.  Strip only its AVB
# tail, mutate six unique ext4 data blocks in place, then regenerate the
# original hashtree/FEC/footer geometry.
cp --reflink=auto -- "$base_vendor" "$stage/final/vendor.img"
"$avbtool" erase_footer --image "$stage/final/vendor.img"
[[ $(stat -c %s -- "$stage/final/vendor.img") == "$vendor_original_size" ]] || \
  die "unexpected stripped vendor size"
debugfs -R "dump /firmware/aoc.bin $stage/aoc.stock.bin" \
  "$stage/final/vendor.img" >/dev/null 2>&1
require_sha "$stage/aoc.stock.bin" "$stock_aoc_sha"
python3 "$patcher" "$stage/aoc.stock.bin" "$stage/aoc.patched.bin" \
  --profile source0-4s32-outputter-nop
require_sha "$stage/aoc.patched.bin" "$patched_aoc_sha"
python3 "$patcher" "$stage/aoc.patched.bin" \
  --profile source0-4s32-outputter-nop --check patched

# The Android ext4 image uses shared-block deduplication.  Replacing the whole
# firmware inode would need more free space than the image reserves.  The six
# affected firmware blocks are instead required to be allocated and owned by
# only that inode, then rewritten as complete 4 KiB blocks.  This preserves
# the inode, timestamps, mode and vendor_fw_file SELinux xattr.
python3 - "$stage/final/vendor.img" "$stage/aoc.stock.bin" \
  "$stage/aoc.patched.bin" "$stage/final/ext4-patch-audit.txt" <<'PY'
import pathlib
import re
import subprocess
import sys

image = pathlib.Path(sys.argv[1])
stock = pathlib.Path(sys.argv[2]).read_bytes()
patched = pathlib.Path(sys.argv[3]).read_bytes()
audit = pathlib.Path(sys.argv[4])
block_size = 4096
if len(stock) != len(patched):
    raise SystemExit("firmware sizes differ")

changed_offsets = [i for i, (a, b) in enumerate(zip(stock, patched)) if a != b]
logical_blocks = sorted({offset // block_size for offset in changed_offsets})
if len(logical_blocks) != 6:
    raise SystemExit(f"expected six changed firmware blocks, got {logical_blocks}")

stat = subprocess.check_output(
    ["debugfs", "-R", "stat /firmware/aoc.bin", str(image)],
    stderr=subprocess.DEVNULL,
    text=True,
)
match = re.search(r"^Inode:\s+(\d+)", stat, re.MULTILINE)
if not match:
    raise SystemExit("could not resolve firmware inode")
inode = int(match.group(1))

rows = []
with image.open("r+b", buffering=0) as stream:
    for logical in logical_blocks:
        mapped = subprocess.check_output(
            ["debugfs", "-R", f"bmap /firmware/aoc.bin {logical}", str(image)],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if not mapped.isdigit() or int(mapped) == 0:
            raise SystemExit(f"logical block {logical} is not allocated: {mapped!r}")
        physical = int(mapped)
        owners = subprocess.check_output(
            ["debugfs", "-R", f"icheck {physical}", str(image)],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        owner_rows = re.findall(r"^(\d+)\s+(\d+)\s*$", owners, re.MULTILINE)
        if owner_rows != [(str(physical), str(inode))]:
            raise SystemExit(
                f"physical block {physical} is not uniquely owned by inode {inode}: "
                f"{owner_rows}"
            )
        start = logical * block_size
        expected = stock[start : start + block_size]
        replacement = patched[start : start + block_size]
        stream.seek(physical * block_size)
        actual = stream.read(len(expected))
        if actual != expected:
            raise SystemExit(
                f"filesystem block mismatch at logical {logical}, physical {physical}"
            )
        stream.seek(physical * block_size)
        if stream.write(replacement) != len(replacement):
            raise SystemExit("short image write")
        rows.append((logical, physical))

audit.write_text(
    "aoc_path=/firmware/aoc.bin\n"
    f"aoc_inode={inode}\n"
    f"changed_byte_count={len(changed_offsets)}\n"
    f"changed_ext4_block_count={len(rows)}\n"
    + "".join(
        f"logical_block_{logical}=physical_block_{physical}\n"
        for logical, physical in rows
    ),
    encoding="utf-8",
)
PY

debugfs -R "dump /firmware/aoc.bin $stage/final/aoc.bin.patched" \
  "$stage/final/vendor.img" >/dev/null 2>&1
cmp -- "$stage/aoc.patched.bin" "$stage/final/aoc.bin.patched"
require_sha "$stage/final/aoc.bin.patched" "$patched_aoc_sha"
python3 "$patcher" "$stage/final/aoc.bin.patched" \
  --profile source0-4s32-outputter-nop --check patched
"$e2fsck" -fn "$stage/final/vendor.img" > "$stage/final/vendor.e2fsck.txt" 2>&1

"$avbtool" add_hashtree_footer \
  --image "$stage/final/vendor.img" \
  --partition_size "$vendor_partition_size" --partition_name vendor \
  --hash_algorithm sha256 --salt "$vendor_salt" \
  --prop 'com.android.build.vendor.os_version:17' \
  --prop "com.android.build.vendor.fingerprint:$fingerprint" \
  --prop 'com.android.build.vendor.security_patch:2026-06-05'
"$avbtool" info_image --image "$stage/final/vendor.img" \
  > "$stage/final/vendor.info"
"$avbtool" verify_image --image "$stage/final/vendor.img" \
  > "$stage/final/vendor.avb-verify.txt"
new_vendor_root_digest=$(awk \
  '/^[[:space:]]+Root Digest:/ {print $3; exit}' "$stage/final/vendor.info")
[[ "$new_vendor_root_digest" =~ ^[0-9a-f]{64}$ ]] || \
  die "could not parse new vendor root digest"

# The mailbox trial's root vbmeta already authenticates its proven VKB and
# the installed bundle's old vendor root.  Replace exactly that one root
# digest in a descriptor donor and re-sign the unchanged full descriptor set.
python3 - "$base_vbmeta" "$stage/vbmeta.descriptor-donor.img" \
  "$base_vendor_root_digest" "$new_vendor_root_digest" <<'PY'
import pathlib
import sys

source, output, old_hex, new_hex = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
old = bytes.fromhex(old_hex)
new = bytes.fromhex(new_hex)
if len(data) != 8192 or data.count(old) != 1:
    raise SystemExit("root vbmeta does not contain one guarded vendor root digest")
pathlib.Path(output).write_bytes(data.replace(old, new, 1))
PY
"$avbtool" make_vbmeta_image \
  --output "$stage/final/vbmeta.img" --padding_size 8192 \
  --algorithm SHA256_RSA4096 --key "$avb_key" \
  --rollback_index 1780617600 --flags 0 \
  --include_descriptors_from_image "$stage/vbmeta.descriptor-donor.img"
"$avbtool" info_image --image "$stage/final/vbmeta.img" \
  > "$stage/final/vbmeta.info"
"$avbtool" verify_image --image "$stage/final/vbmeta.img" \
  > "$stage/final/vbmeta.avb-verify.txt"
grep -Fq "      Root Digest:           $new_vendor_root_digest" \
  "$stage/final/vbmeta.info" || die "root vbmeta lacks new vendor root"
grep -Fq "      Digest:                $mailbox_vkb_digest" \
  "$stage/final/vbmeta.info" || die "root vbmeta lost mailbox VKB digest"

{
  printf 'variant=frankel-ep1-source0-192k-d0-mailbox-firmware-4s32-a32-outputter-nop\n'
  printf 'base_vendor=artifacts/frankel/powerphone/vendor.img\n'
  printf 'base_vendor_sha256=%s\n' "$base_vendor_sha"
  printf 'base_vendor_root_digest=%s\n' "$base_vendor_root_digest"
  printf 'new_vendor_root_digest=%s\n' "$new_vendor_root_digest"
  printf 'aoc_firmware_path=/firmware/aoc.bin\n'
  printf 'aoc_stock_sha256=%s\n' "$stock_aoc_sha"
  printf 'aoc_patched_sha256=%s\n' "$patched_aoc_sha"
  printf 'f1_profile=source0-4s32\n'
  printf 'f1_patch_word_count=31\n'
  printf 'a32_usf_timer_runtime_address=0x4009e0ce\n'
  printf 'a32_usf_timer_file_offset=0x00b0de8e\n'
  printf 'a32_usf_timer_patch=90bb_to_00bf\n'
  printf 'aoc_container_signature=invalidated-by-intent\n'
  printf 'secure_loader_acceptance=unverified-and-expected-risk\n'
  printf 'vendor_kernel_boot=byte-identical-proven-mailbox-trial-1\n'
  printf 'vendor_kernel_boot_sha256=%s\n' "$base_vkb_sha"
  printf 'vendor_kernel_boot_digest=%s\n' "$mailbox_vkb_digest"
  printf 'aoc_core_sha256=%s\n' "$fixed_core_sha"
  printf 'aoc_alsa_dev_util_sha256=%s\n' "$mailbox_alsa_sha"
  printf 'flash_status=not-flashed\n'
  cat "$stage/final/ext4-patch-audit.txt"
  (cd -- "$stage/final"; sha256sum -- aoc.bin.patched \
    aoc_alsa_dev_util.ep1-source0-192k-d0-mailbox-real-progress.ko \
    vendor.img vendor_kernel_boot.img vbmeta.img)
} > "$stage/final/build-audit.txt"

cat > "$stage/final/FLASHING.txt" <<'EOF'
EXPERIMENTAL AND NOT FLASHED BY THIS BUILDER.

This image intentionally invalidates the OEM-internal signature of
/vendor/firmware/aoc.bin.  The secure AoC loader may reject it before Android
boots.  Keep the stock PowerPhone vendor.img and vbmeta.img ready for rollback.

The logical vendor image normally requires userspace fastboot (fastbootd).
Flash vendor.img there.  Flash vendor_kernel_boot.img and vbmeta.img from
bootloader fastboot, then reboot.  All three files are one AVB-consistent set.
EOF

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
[[ "$stage" == "$trial_root"/.build.* ]] || die "refusing unexpected staging cleanup: $stage"
rm -r -- "$stage"
printf 'built (not flashed): %s\n' "$output_dir"
sed -n '1,120p' "$output_dir/build-audit.txt"
