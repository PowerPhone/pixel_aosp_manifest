#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$test_dir/../.." && pwd -P)

for command_name in awk chmod cp find grep mkdir mktemp rm sed sha256sum sort tail; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'error: missing test command: %s\n' "$command_name" >&2
    exit 1
  }
done

scratch_parent="$project_root/work/frankel-vbmeta-flash-policy-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -n ${scratch_dir:-} && -d "$scratch_dir" && ! -L "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

bundle="$scratch_dir/bundle"
state_dir="$scratch_dir/state"
log_file="$scratch_dir/fastboot.log"
mock_fastboot="$test_dir/mock-frankel-fastboot.sh"
mkdir "$bundle" "$state_dir"
printf 'bootloader\n' >"$state_dir/mode"
: >"$log_file"

cp "$project_root/scripts/flash-frankel.sh" "$bundle/flash-all.sh"
chmod 0755 "$bundle/flash-all.sh"
mock_sha256=$(sha256sum "$mock_fastboot" | awk '{print $1}')
sed -i \
  "s/^expected_fastboot_sha256=.*/expected_fastboot_sha256=$mock_sha256/" \
  "$bundle/flash-all.sh"

firmware_partitions=(
  abl bl31 cap cpm dbc dbl
  dram_init_0 dram_init_1 dram_init_2 dram_init_3 dram_init_4
  dram_init_5 dram_init_6 dram_init_7 dram_init_8 dram_init_9
  dram_phy gc gdmc gsa_bl1 gsa_fw tzsw modem
)
static_partitions=(
  boot dtbo init_boot pvmfw vendor_boot vendor_kernel_boot vbmeta
)
logical_partitions=(
  system system_dlkm system_ext product vendor vendor_dlkm
)
image_files=()
for partition in \
    "${firmware_partitions[@]}" \
    "${static_partitions[@]}" \
    "${logical_partitions[@]}"; do
  image_files+=("$partition.img")
  printf 'mock %s\n' "$partition" >"$bundle/$partition.img"
done
printf 'device\n' >"$bundle/bundle-kind"
printf 'bundle_schema=pixel-aosp-flash-bundle-v2\n' >"$bundle/BUNDLE_INFO.txt"
printf 'format=pixel-aosp-device-build-attestation-v1\n' > \
  "$bundle/BUILD_ATTESTATION.txt"
printf 'require board=frankel\n' >"$bundle/android-info.txt"
printf 'version 1\n' >"$bundle/fastboot-info.txt"
(
  cd "$bundle"
  sha256sum bundle-kind BUNDLE_INFO.txt BUILD_ATTESTATION.txt \
    android-info.txt fastboot-info.txt flash-all.sh "${image_files[@]}" \
    >SHA256SUMS
)

MOCK_FRANKEL_FASTBOOT_STATE_DIR="$state_dir" \
MOCK_FRANKEL_FASTBOOT_LOG="$log_file" \
MOCK_FRANKEL_FASTBOOT_SERIAL=MOCK_FRANKEL_SERIAL \
FASTBOOT="$mock_fastboot" \
FRANKEL_FASTBOOT_SERIAL=MOCK_FRANKEL_SERIAL \
FRANKEL_FLASH_CONFIRM=FLASH_FRANKEL_A_ERASE_USERDATA \
FRANKEL_SKIP_REBOOT=1 \
  "$bundle/flash-all.sh" >/dev/null

[[ $(grep -Fxc \
    'flash vbmeta disable-verity=true disable-verification=true' \
    "$log_file") -eq 1 ]] || {
  printf 'error: root vbmeta was not flashed exactly once with both disable flags\n' >&2
  exit 1
}
[[ $(grep -Ec \
    '^flash (boot|dtbo|init_boot|pvmfw|vendor_boot|vendor_kernel_boot) disable-verity=false disable-verification=false$' \
    "$log_file") -eq 6 ]] || {
  printf 'error: static payload flash policy differs from the expected unflagged set\n' >&2
  exit 1
}
[[ $(grep '^flash ' "$log_file" | tail -n 1) == \
    'flash vbmeta disable-verity=true disable-verification=true' ]] || {
  printf 'error: root vbmeta is not the final image flash\n' >&2
  exit 1
}

printf 'Frankel root-vbmeta disable-flag flash simulation passed\n'
