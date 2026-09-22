#!/usr/bin/env bash
# Reproduce, but never promote, Frankel's failed bootconfig cold-audio trial.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
aosp_dir="$project_root/work/aosp"
host_bin="$aosp_dir/out_pixel/frankel/host/linux-x86/bin"
base_dir="$project_root/work/audio-research/frankel/host-timer-500us-ep3-192k/trial-1"
trial_root="$project_root/work/audio-research/frankel/host-timer-500us-ep3-192k-cold-audio"
output_dir=${1:-"$trial_root/trial-1"}

base_vkb="$base_dir/vendor_kernel_boot.img"
base_vbmeta="$base_dir/vbmeta.img"
ep3_patcher="$script_dir/patch_frankel_ep3_capture_192k.py"
timer_patcher="$script_dir/patch_frankel_aoc_host_timer_500us.py"
unpack_bootimg="$host_bin/unpack_bootimg"
mkbootimg="$host_bin/mkbootimg"
avbtool="$host_bin/avbtool"
avb_key="$aosp_dir/external/avb/test/data/testkey_rsa4096.pem"

base_vkb_sha=f9cb3b89abaa72fe0885bab2bba2bc967653e966e217907a0ee929901388b86e
base_vbmeta_sha=ab2eaeafb935677e1d932e6322026aca786e100975fddc1856b990c815f1b207
base_ramdisk_sha=9759e09be087cd7304b736a0f8cb7d3edbfdc6e40418bb05fd6be189cbf1278d
base_dtb_sha=e26fc7e716d503b1b6f1c0d33611cdd1c657c541eb789bf362b9c53a5676f225
base_module_sha=859124cfa142bb375348a5210ad9175060c656279cae9eaeee9ad196d9ef4eb4
base_vkb_descriptor_digest=e0c0be7886a1263b65b4a3b33c320daade74baec1b57412579bbde637f3efbeb
avb_salt=c7cf7247dd978cb78301e952c737dc0bfce2d0b0f422785114cb20eec88f2b09b02c686cdc35246f59ee170d7693cb38761cc7b99f4c7a46b19c61902e004da9
vkb_fingerprint=google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys
bootconfig_entry=androidboot.init_rc=/system/etc/init/hw/init.rc
guarded_raw_size=6760448

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

for tool in \
  "$unpack_bootimg" "$mkbootimg" "$avbtool" "$avb_key" \
  "$ep3_patcher" "$timer_patcher"; do
  require_file "$tool"
done
for command_name in \
  awk cmp cpio diff find grep lz4 mv python3 sed sha256sum sort stat touch \
  truncate; do
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

mkdir -p -- \
  "$stage/final/unpacked" "$stage/final/ramdisk-root" \
  "$stage/repacked-root"
"$unpack_bootimg" --boot_img "$base_vkb" \
  --out "$stage/final/unpacked" > "$stage/final/vendor_kernel_boot.unpack.txt"
require_sha256 "$stage/final/unpacked/vendor_ramdisk00" "$base_ramdisk_sha"
require_sha256 "$stage/final/unpacked/dtb" "$base_dtb_sha"
[[ ! -s "$stage/final/unpacked/bootconfig" ]] || \
  die "base vendor_kernel_boot unexpectedly has a bootconfig"

lz4 -dc -- "$stage/final/unpacked/vendor_ramdisk00" \
  > "$stage/vendor_ramdisk00.cpio"
(
  cd -- "$stage/final/ramdisk-root"
  cpio --quiet -idm --no-absolute-filenames < "$stage/vendor_ramdisk00.cpio"
)

module="$stage/final/ramdisk-root/lib/modules/aoc_alsa_dev_util.ko"
require_file "$module"
require_sha256 "$module" "$base_module_sha"
python3 "$timer_patcher" --check 500us "$module"
# The EP3 checker keys the complete preceding 1 ms artifact.  Revert only the
# timer in a disposable copy so both independent exact-state checkers can
# authenticate their respective layer without altering the candidate module.
module_1ms_probe="$stage/aoc_alsa_dev_util.host-timer-1ms-ep3-192k.probe.ko"
python3 "$timer_patcher" --set-state 1ms "$module" "$module_1ms_probe"
python3 "$timer_patcher" --check 1ms "$module_1ms_probe"
python3 "$ep3_patcher" --check patched "$module_1ms_probe"

# The base v4 vendor_kernel_boot has no spare page for a bootconfig.  Reorder
# the semantically unchanged cpio members before high-compression legacy LZ4;
# this creates enough room while retaining the guarded 6,760,448-byte AVB
# descriptor size.  Normalize cpio timestamps for deterministic output.
(
  cd -- "$stage/final/ramdisk-root"
  find . -exec touch -h -d @0 -- {} +
  {
    find . -type d -print0 | LC_ALL=C sort -z
    find . ! -type d -printf '%s %p\0' | \
      LC_ALL=C sort -z -n | sed -z 's/^[0-9]* //'
  } | cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) > "$stage/vendor_ramdisk00.cpio.repacked"
lz4 -q -f -l -12 -- "$stage/vendor_ramdisk00.cpio.repacked" \
  "$stage/final/vendor_ramdisk00.host-timer-500us-ep3-192k-cold-audio"

# Prove that compression-space recovery did not change any ramdisk payload.
(
  cd -- "$stage/repacked-root"
  cpio --quiet -idm --no-absolute-filenames \
    < "$stage/vendor_ramdisk00.cpio.repacked"
)
diff -qr --no-dereference \
  "$stage/final/ramdisk-root" "$stage/repacked-root" >/dev/null
require_sha256 \
  "$stage/repacked-root/lib/modules/aoc_alsa_dev_util.ko" "$base_module_sha"
python3 "$timer_patcher" --check 500us \
  "$stage/repacked-root/lib/modules/aoc_alsa_dev_util.ko"

printf '%s\n' "$bootconfig_entry" > "$stage/final/bootconfig.cold-audio"

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
  --vendor_bootconfig "$stage/final/bootconfig.cold-audio" \
  --ramdisk_type platform \
  --ramdisk_name '' \
  --vendor_ramdisk_fragment \
    "$stage/final/vendor_ramdisk00.host-timer-500us-ep3-192k-cold-audio" \
  --vendor_boot "$stage/final/vendor_kernel_boot.raw.img"

raw_unpadded_size=$(stat -c %s -- "$stage/final/vendor_kernel_boot.raw.img")
(( raw_unpadded_size <= guarded_raw_size )) || \
  die "reconstructed vendor_kernel_boot exceeds guarded raw size: $raw_unpadded_size"
truncate -s "$guarded_raw_size" -- "$stage/final/vendor_kernel_boot.raw.img"
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
grep -Fq '      Image Size:            6760448 bytes' \
  "$stage/final/vbmeta.info" || die "root vbmeta changed guarded image size"
grep -Fq "      Digest:                $new_vkb_digest" \
  "$stage/final/vbmeta.info" || die "vbmeta does not contain the new digest"

# Re-unpack the signed candidate and assert its only intentional boot-level
# behavioral input: the exact init selector.  Also recheck its DTB and module.
mkdir -p -- "$stage/candidate-unpacked" "$stage/candidate-root"
"$unpack_bootimg" --boot_img "$stage/final/vendor_kernel_boot.img" \
  --out "$stage/candidate-unpacked" > "$stage/candidate-unpack.txt"
cp -f -- "$stage/candidate-unpack.txt" \
  "$stage/final/vendor_kernel_boot.candidate.unpack.txt"
require_sha256 "$stage/candidate-unpacked/dtb" "$base_dtb_sha"
printf '%s\n' "$bootconfig_entry" > "$stage/expected-bootconfig"
cmp -s -- "$stage/expected-bootconfig" "$stage/candidate-unpacked/bootconfig" || \
  die "candidate bootconfig does not contain the exact cold-audio selector"
lz4 -dc -- "$stage/candidate-unpacked/vendor_ramdisk00" \
  > "$stage/candidate-ramdisk.cpio"
(
  cd -- "$stage/candidate-root"
  cpio --quiet -idm --no-absolute-filenames < "$stage/candidate-ramdisk.cpio"
)
diff -qr --no-dereference \
  "$stage/final/ramdisk-root" "$stage/candidate-root" >/dev/null
require_sha256 \
  "$stage/candidate-root/lib/modules/aoc_alsa_dev_util.ko" "$base_module_sha"

cp -f -- "$module" \
  "$stage/final/aoc_alsa_dev_util.host-timer-500us-ep3-192k.ko"
base_ramdisk_size=$(stat -c %s -- "$stage/final/unpacked/vendor_ramdisk00")
repacked_ramdisk_size=$(stat -c %s -- \
  "$stage/final/vendor_ramdisk00.host-timer-500us-ep3-192k-cold-audio")
{
  printf 'variant=frankel-powerphone-aoc-host-timer-500us-ep3-192k-cold-audio\n'
  printf 'result=FAILED_REAL_HARDWARE_VENDOR_KERNEL_BOOT_BOOTCONFIG_NOT_CONSUMED\n'
  printf 'base_variant=frankel-powerphone-aoc-host-timer-500us-ep3-192k\n'
  printf 'base_vendor_kernel_boot_sha256=%s\n' "$base_vkb_sha"
  printf 'base_vbmeta_sha256=%s\n' "$base_vbmeta_sha"
  printf 'base_vendor_ramdisk_sha256=%s\n' "$base_ramdisk_sha"
  printf 'base_dtb_sha256=%s\n' "$base_dtb_sha"
  printf 'aoc_alsa_dev_util_sha256=%s\n' "$base_module_sha"
  printf 'host_timer_interval_ns=500000\n'
  printf 'ep3_rate_mask=fe1f0000\n'
  printf 'bootconfig=%s\n' "$bootconfig_entry"
  printf 'base_packed_ramdisk_size=%s\n' "$base_ramdisk_size"
  printf 'repacked_ramdisk_size=%s\n' "$repacked_ramdisk_size"
  printf 'vendor_kernel_boot_unpadded_size=%s\n' "$raw_unpadded_size"
  printf 'vendor_kernel_boot_guarded_raw_size=%s\n' "$guarded_raw_size"
  printf 'new_vendor_kernel_boot_descriptor_digest=%s\n' "$new_vkb_digest"
  (
    cd -- "$stage/final"
    sha256sum -- \
      aoc_alsa_dev_util.host-timer-500us-ep3-192k.ko \
      bootconfig.cold-audio \
      vendor_ramdisk00.host-timer-500us-ep3-192k-cold-audio \
      vendor_kernel_boot.raw.img vendor_kernel_boot.img vbmeta.img
  )
} > "$stage/final/build-audit.txt"

cat > "$stage/final/FLASHING.txt" <<'EOF'
FAILED REAL-HARDWARE TRIAL -- DO NOT FLASH OR PROMOTE.

Observed result
---------------
This image embeds androidboot.init_rc=/system/etc/init/hw/init.rc in the
vendor_kernel_boot bootconfig.  On real Frankel hardware it nevertheless
completed a normal framework boot with both audioserver and
vendor.audio-hal-aidl running.  The intended cold-audio condition was not
created.  Retain this pair only as a negative boot-chain experiment.

Rollback the failed trial
-------------------------
Re-enter bootloader fastboot and flash the preserved parent candidate:

  fastboot flash vendor_kernel_boot \
    ../../host-timer-500us-ep3-192k/trial-1/vendor_kernel_boot.img
  fastboot flash vbmeta \
    ../../host-timer-500us-ep3-192k/trial-1/vbmeta.img
  fastboot reboot

The builder never modifies the parent candidate.
EOF

cat > "$stage/final/DO_NOT_FLASH.txt" <<'EOF'
FAILED ON REAL FRANKEL HARDWARE.

Both audioserver and vendor.audio-hal-aidl ran and sys.boot_completed reached
1.  The vendor_kernel_boot bootconfig init selector did not produce a cold
audio boot.  Do not flash or promote this pair.  See FLASHING.txt only for the
rollback commands and docs/frankel-aoc-cold-patch-boot.md for the record.
EOF

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$stage/final" "$output_dir"
printf 'reproduced failed trial (do not flash): %s\n' "$output_dir"
sed -n '1,220p' "$output_dir/build-audit.txt"
