#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
manifest_root=$(cd -- "$script_dir/../../../.." && pwd)
artifacts=${FRANKEL_GKI_ARTIFACTS:-"$manifest_root/work/upstream/frankel-gki-15739706"}
ddk_workspace=${FRANKEL_DDK_WORKSPACE:-"$artifacts/ddk-workspace"}
package_dir="$ddk_workspace/probes/frankel_pdm_dt_probe"
output_dir="$artifacts/modules"
target='//probes/frankel_pdm_dt_probe:frankel_pdm_dt_probe'
expected_release='6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k'

required_files=(
  "$artifacts/Module.symvers"
  "$artifacts/kernel_aarch64_ddk_headers_archive.tar.gz"
  "$artifacts/kernel_aarch64_filegroup_decl.tar.gz"
  "$ddk_workspace/tools/bazel"
)
for required_file in "${required_files[@]}"; do
  if [[ ! -e "$required_file" ]]; then
    printf 'missing required DDK input: %s\n' "$required_file" >&2
    printf 'run: %s/bootstrap-frankel-ddk.sh\n' "$script_dir" >&2
    exit 2
  fi
done

mkdir -p "$package_dir" "$output_dir"
install -m 0644 "$script_dir/BUILD.bazel" "$package_dir/BUILD.bazel"
install -m 0644 "$script_dir/frankel_pdm_dt_probe.c" \
  "$package_dir/frankel_pdm_dt_probe.c"

(
  cd "$ddk_workspace"
  tools/bazel build "$target"
)

bazel_output="$ddk_workspace/bazel-bin/probes/frankel_pdm_dt_probe/frankel_pdm_dt_probe"
install -m 0644 "$bazel_output/frankel_pdm_dt_probe.ko" \
  "$output_dir/frankel_pdm_dt_probe.ko"
install -m 0644 "$bazel_output/unstripped/frankel_pdm_dt_probe.ko" \
  "$output_dir/frankel_pdm_dt_probe.unstripped.ko"

actual_release=$(modinfo -F vermagic "$output_dir/frankel_pdm_dt_probe.ko")
if [[ "$actual_release" != "$expected_release "* ]]; then
  printf 'unexpected vermagic: %s\n' "$actual_release" >&2
  exit 3
fi

imports=$(readelf -Ws "$output_dir/frankel_pdm_dt_probe.unstripped.ko" |
  awk '$7 == "UND" { print $8 }' | sort -u)
if grep -Eiq '(^|_)(ioremap|iounmap|read[blqw]|write[blqw]|memcpy_(from|to)io|of_iomap|request_mem_region|request_irq|dma_|clk_|fifo)' <<<"$imports"; then
  printf 'forbidden hardware-access import found:\n%s\n' "$imports" >&2
  exit 4
fi

while read -r crc symbol; do
  expected_crc=$(awk -v name="$symbol" '$2 == name { print $1; exit }' \
    "$artifacts/Module.symvers")
  if [[ -z "$expected_crc" || "${expected_crc,,}" != "${crc,,}" ]]; then
    printf 'symbol CRC mismatch: %s module=%s target=%s\n' \
      "$symbol" "$crc" "${expected_crc:-missing}" >&2
    exit 5
  fi
done < <(modprobe --show-modversions "$output_dir/frankel_pdm_dt_probe.ko")

printf 'Built and audited: %s\n' "$output_dir/frankel_pdm_dt_probe.ko"
printf 'Vermagic: %s\n' "$actual_release"
printf 'Undefined imports:\n%s\n' "$imports"
