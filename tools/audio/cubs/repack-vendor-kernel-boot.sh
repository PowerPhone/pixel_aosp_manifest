#!/usr/bin/env bash
# Build-only Cubs/Malibu ramdisk repack. Never flashes or verifies hashes.
set -euo pipefail
if (( $# != 3 )); then
  printf 'Usage: %s LIVE_BASE.img PREPARED_RAMDISK_DIR NEW_OUTPUT_DIR\n' "$0" >&2
  exit 2
fi
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_dir/../../.." && pwd -P)
base_image=$(realpath -e -- "$1")
ramdisk_root=$(realpath -e -- "$2")
output_dir=$(realpath -m -- "$3")
host_bin="$project_root/work/aosp/out_pixel/cubs/host/linux-x86/bin"
[[ -f "$base_image" && -d "$ramdisk_root/lib/modules" && ! -e "$output_dir" ]] || {
  printf 'error: require base image, prepared module ramdisk, and new output directory\n' >&2
  exit 2
}
[[ $(stat -c %s -- "$base_image") == 67108864 ]] || {
  printf 'error: expected the backed-up 64-MiB Cubs vendor_kernel_boot partition\n' >&2
  exit 2
}
for tool in unpack_bootimg mkbootimg avbtool; do
  [[ -x "$host_bin/$tool" ]] || { printf 'error: missing %s\n' "$host_bin/$tool" >&2; exit 2; }
done
mkdir -p -- "$output_dir/unpacked"
"$host_bin/unpack_bootimg" --boot_img "$base_image" --out "$output_dir/unpacked" \
  --format=mkbootimg --null > "$output_dir/mkbootimg-args.nul"
[[ -f "$output_dir/unpacked/vendor_ramdisk00" && \
   ! -e "$output_dir/unpacked/vendor_ramdisk01" ]] || {
  printf 'error: this packer requires exactly one vendor ramdisk fragment\n' >&2
  exit 2
}
# Structural target guards, not attestation: check v4/one fragment and every
# root compatible in the unmodified concatenated DTBs (Malibu uses google,mbu).
python3 - "$base_image" "$output_dir/unpacked/dtb" <<'PY'
import struct
import sys
from pathlib import Path

base = Path(sys.argv[1]).read_bytes()
assert base[:8] == b'VNDRBOOT', 'not a vendor boot image'
assert struct.unpack_from('<I', base, 8)[0] == 4, 'expected header version4'
assert struct.unpack_from('<I', base, 2116)[0] == 1, 'expected one ramdisk fragment'
dtbs = Path(sys.argv[2]).read_bytes()
cursor = 0
count = 0
while cursor < len(dtbs):
    h = struct.unpack_from('>10I', dtbs, cursor)
    assert h[0] == 0xd00dfeed and h[1] >= 40, 'bad concatenated DTB header'
    assert cursor + h[1] <= len(dtbs), 'truncated DTB'
    strings = dtbs[cursor + h[3]:cursor + h[3] + h[8]]
    p, end = cursor + h[2], cursor + h[2] + h[9]
    depth = 0
    root_compatible = None
    while p < end:
        token = struct.unpack_from('>I', dtbs, p)[0]
        p += 4
        if token == 1:
            zero = dtbs.index(0, p, end)
            p = cursor + ((zero + 4 - cursor) & ~3)
            depth += 1
        elif token == 2:
            depth -= 1
        elif token == 3:
            size, name_at = struct.unpack_from('>II', dtbs, p)
            p += 8
            name = strings[name_at:strings.index(0, name_at)]
            if depth == 1 and name == b'compatible':
                root_compatible = dtbs[p:p + size].rstrip(b'\0').split(b'\0')
            p = cursor + ((p + size + 3 - cursor) & ~3)
        elif token == 4:
            pass
        elif token == 9:
            break
        else:
            raise ValueError(f'bad FDT token{token}')
    assert root_compatible == [b'google,mbu'], f'not Malibu: {root_compatible!r}'
    cursor += h[1]
    count += 1
assert count > 0 and cursor == len(dtbs), 'trailing DTB data'
print(f'Guarded v4, one ramdisk fragment, {count} unchanged Malibu DTBs.')
PY
(
  cd -- "$ramdisk_root"
  find . -print0 | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 --reproducible
) | lz4 -q -f -l -12 - "$output_dir/unpacked/vendor_ramdisk00"
mapfile -d '' -t boot_arguments < "$output_dir/mkbootimg-args.nul"
"$host_bin/mkbootimg" "${boot_arguments[@]}" \
  --vendor_boot "$output_dir/vendor_kernel_boot.img"
# Add normal AVB image-format metadata; this is not a verification pass and
# does not claim that the modified image matches existing signed vbmeta.
"$host_bin/avbtool" add_hash_footer --image "$output_dir/vendor_kernel_boot.img" \
  --partition_name vendor_kernel_boot --partition_size 67108864
printf 'Built %s/vendor_kernel_boot.img; nothing was flashed.\n' "$output_dir"
