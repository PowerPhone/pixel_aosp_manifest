# shellcheck shell=bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)

for command_name in chmod cp find grep head mkdir mktemp mv rm sed sha256sum \
    sort tail; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'error: missing test command: %s\n' "$command_name" >&2
    exit 1
  }
done

scratch_parent="$project_root/work/frankel-bundle-integrity-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -n ${scratch_dir:-} && -d "$scratch_dir" && \
        ! -L "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

mock_fastboot="$scratch_dir/fastboot-same-version"
mock_invocations="$scratch_dir/fastboot-invocations"
# These are literal source lines for the generated mock executable.
# shellcheck disable=SC2016
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'printf "invoked\\n" >>"${MOCK_FASTBOOT_INVOCATIONS:?}"'
  printf '%s\n' 'if [[ ${1:-} == --version ]]; then'
  printf '%s\n' '  printf "fastboot version 37.0.1-altered\\n"'
  printf '%s\n' 'fi'
} > "$mock_fastboot"
chmod 0755 "$mock_fastboot"

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
done

make_bundle() {
  local bundle=$1 name
  rm -rf -- "$bundle"
  mkdir "$bundle"
  cp "$project_root/scripts/flash-frankel.sh" "$bundle/flash-all.sh"
  chmod 0755 "$bundle/flash-all.sh"
  printf 'device\n' > "$bundle/bundle-kind"
  printf 'bundle_schema=pixel-aosp-flash-bundle-v2\n' > \
    "$bundle/BUNDLE_INFO.txt"
  printf 'format=pixel-aosp-device-build-attestation-v1\n' > \
    "$bundle/BUILD_ATTESTATION.txt"
  printf 'require board=frankel\n' > "$bundle/android-info.txt"
  printf 'version 1\n' > "$bundle/fastboot-info.txt"
  for name in "${image_files[@]}"; do
    printf 'mock %s\n' "$name" > "$bundle/$name"
  done
  (
    cd "$bundle"
    sha256sum bundle-kind BUNDLE_INFO.txt BUILD_ATTESTATION.txt \
      android-info.txt fastboot-info.txt flash-all.sh "${image_files[@]}" \
      > SHA256SUMS
  )
}

expect_pre_fastboot_failure() {
  local label=$1 expected_message=$2 bundle=$3 output
  rm -f -- "$mock_invocations"
  output="$scratch_dir/$label.output"
  if MOCK_FASTBOOT_INVOCATIONS="$mock_invocations" \
      FASTBOOT="$mock_fastboot" \
      FRANKEL_FLASH_CONFIRM=FLASH_FRANKEL_A_ERASE_USERDATA \
      "$bundle/flash-all.sh" >"$output" 2>&1; then
    printf 'error: %s unexpectedly succeeded\n' "$label" >&2
    exit 1
  fi
  grep -Fq -- "$expected_message" "$output" || {
    printf 'error: %s failed for the wrong reason\n' "$label" >&2
    sed -n '1,20p' "$output" >&2
    exit 1
  }
  [[ ! -e "$mock_invocations" ]] || {
    printf 'error: %s invoked fastboot before failing\n' "$label" >&2
    exit 1
  }
}

bundle="$scratch_dir/bundle"
make_bundle "$bundle"
expect_pre_fastboot_failure valid_bundle_rejects_altered_fastboot \
  'fastboot does not match the pinned Platform-Tools binary digest' "$bundle"

make_bundle "$bundle"
printf 'corruption\n' >> "$bundle/system.img"
expect_pre_fastboot_failure changed_image \
  'bundle checksum verification failed' "$bundle"

make_bundle "$bundle"
rm "$bundle/SHA256SUMS"
expect_pre_fastboot_failure missing_manifest \
  'missing or unsafe bundle checksum manifest' "$bundle"

make_bundle "$bundle"
head -n -1 "$bundle/SHA256SUMS" > "$bundle/SHA256SUMS.new"
mv "$bundle/SHA256SUMS.new" "$bundle/SHA256SUMS"
expect_pre_fastboot_failure missing_manifest_entry \
  'SHA256SUMS does not cover the exact 42-file bundle allowlist' "$bundle"

make_bundle "$bundle"
first_manifest_line=$(head -n 1 "$bundle/SHA256SUMS")
head -n -1 "$bundle/SHA256SUMS" > "$bundle/SHA256SUMS.new"
printf '%s\n' "$first_manifest_line" >> "$bundle/SHA256SUMS.new"
mv "$bundle/SHA256SUMS.new" "$bundle/SHA256SUMS"
expect_pre_fastboot_failure duplicate_manifest_entry \
  'duplicate file in SHA256SUMS' "$bundle"

make_bundle "$bundle"
sed '1s/  bundle-kind$/  unexpected-file/' "$bundle/SHA256SUMS" > \
  "$bundle/SHA256SUMS.new"
mv "$bundle/SHA256SUMS.new" "$bundle/SHA256SUMS"
expect_pre_fastboot_failure unexpected_manifest_entry \
  'unexpected file in SHA256SUMS' "$bundle"

make_bundle "$bundle"
sed '1s/  bundle-kind$/  ..\/bundle-kind/' "$bundle/SHA256SUMS" > \
  "$bundle/SHA256SUMS.new"
mv "$bundle/SHA256SUMS.new" "$bundle/SHA256SUMS"
expect_pre_fastboot_failure unsafe_manifest_entry \
  'malformed or unsafe SHA256SUMS entry' "$bundle"

make_bundle "$bundle"
printf 'unexpected\n' > "$bundle/extra-file"
expect_pre_fastboot_failure unexpected_directory_entry \
  'bundle directory does not match the exact reviewed file allowlist' "$bundle"

printf 'Frankel bundle integrity simulation passed\n'
