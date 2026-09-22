#!/usr/bin/env bash
# Repack one Frankel vendor-kernel ramdisk; build only, never flash or attest.
set -euo pipefail
if (( $# != 3 )); then
  printf 'Usage: %s BASE_VENDOR_KERNEL_BOOT.img PREPARED_RAMDISK_DIR NEW_OUTPUT_DIR\n' "$0" >&2
  exit 2
fi
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_dir/../.." && pwd -P)
base_image=$(realpath -e -- "$1")
ramdisk_root=$(realpath -e -- "$2")
output_dir=$(realpath -m -- "$3")
host_bin="$project_root/work/aosp/out_pixel/frankel/host/linux-x86/bin"
[[ -f "$base_image" && -d "$ramdisk_root/lib/modules" && ! -e "$output_dir" ]] || {
  printf 'error: require a base image, prepared module ramdisk, and new output directory\n' >&2
  exit 2
}
mkdir -p -- "$output_dir/unpacked"
"$host_bin/unpack_bootimg" --boot_img "$base_image" --out "$output_dir/unpacked" \
  --format=mkbootimg --null > "$output_dir/mkbootimg-args.nul"
[[ -f "$output_dir/unpacked/vendor_ramdisk00" && \
   ! -e "$output_dir/unpacked/vendor_ramdisk01" ]] || {
  printf 'error: this Frankel packer requires exactly one vendor ramdisk fragment\n' >&2
  exit 2
}
(
  cd -- "$ramdisk_root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) | lz4 -q -f -l -12 - "$output_dir/unpacked/vendor_ramdisk00"
mapfile -d '' -t boot_arguments < "$output_dir/mkbootimg-args.nul"
"$host_bin/mkbootimg" "${boot_arguments[@]}" \
  --vendor_boot "$output_dir/vendor_kernel_boot.img"
# Normal image-format metadata, not a hash-verification or attestation pass.
# The experimental full flash runner already disables AVB enforcement.
"$host_bin/avbtool" add_hash_footer --image "$output_dir/vendor_kernel_boot.img" \
  --partition_name vendor_kernel_boot --partition_size 67108864
printf 'Built %s/vendor_kernel_boot.img; nothing was flashed.\n' "$output_dir"
