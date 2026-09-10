#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
manifest_root=$(cd -- "$script_dir/../../../.." && pwd)
update_lock=false
if [[ "${1:-}" == --update-lock ]]; then
  update_lock=true
  shift
fi
if [[ $# -ne 0 ]]; then
  printf 'usage: %s [--update-lock]\n' "$0" >&2
  exit 2
fi
# shellcheck source=scripts/lib/frankel-pdm-provenance.sh
source "$manifest_root/scripts/lib/frankel-pdm-provenance.sh"
artifacts=${FRANKEL_GKI_ARTIFACTS:-"$manifest_root/work/upstream/frankel-gki-15739706"}
ddk_workspace=${FRANKEL_DDK_WORKSPACE:-"$artifacts/ddk-workspace"}
package_dir="$ddk_workspace/probes/frankel_pdm_alsa"
output_dir="$artifacts/modules"
target='//probes/frankel_pdm_alsa:frankel_pdm_alsa'
expected_release='6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k'

manifest_root=$(realpath -e -- "$manifest_root")
artifacts=$(realpath -e -- "$artifacts")
ddk_workspace=$(realpath -e -- "$ddk_workspace")
[[ "$artifacts" == "$manifest_root/work/upstream/frankel-gki-15739706" &&
   "$ddk_workspace" == "$artifacts/ddk-workspace" ]] || {
  printf 'the provenance-bound Frankel PDM build requires the repository DDK paths\n' >&2
  exit 2
}
frankel_pdm_provenance_validate_ddk "$manifest_root"
if [[ "$update_lock" == false ]]; then
  frankel_pdm_provenance_validate_lock "$manifest_root"
fi

required_files=(
  "$artifacts/Module.symvers"
  "$artifacts/kernel_aarch64_ddk_headers_archive.tar.gz"
  "$artifacts/kernel_aarch64_filegroup_decl.tar.gz"
  "$ddk_workspace/tools/bazel"
  "$script_dir/allowed-imports.txt"
)
for required_file in "${required_files[@]}"; do
  if [[ ! -e "$required_file" ]]; then
    printf 'missing required DDK input: %s\n' "$required_file" >&2
    exit 2
  fi
done

if rg -n '\b(writeb|writew|writel|writeq|iowrite(8|16|32|64)|memcpy_toio|memset_io|regmap_write)\s*\(' \
    "$script_dir/frankel_pdm_alsa.c"; then
  printf 'forbidden MMIO-write call appears in module source\n' >&2
  exit 3
fi
if rg -n '(^|[^[:xdigit:]])(0x)?(824d|b4d|384d)[[:xdigit:]]*' \
    "$script_dir/frankel_pdm_alsa.c"; then
  printf 'clock/source/gate address appears in module source\n' >&2
  exit 4
fi

mkdir -p "$package_dir" "$output_dir"
install -m 0644 "$script_dir/BUILD.bazel" "$package_dir/BUILD.bazel"
install -m 0644 "$script_dir/frankel_pdm_alsa.c" \
  "$package_dir/frankel_pdm_alsa.c"

(
  cd "$ddk_workspace"
  tools/bazel build "$target"
)

bazel_output="$ddk_workspace/bazel-bin/probes/frankel_pdm_alsa/frankel_pdm_alsa"
install -m 0644 "$bazel_output/frankel_pdm_alsa.ko" \
  "$output_dir/frankel_pdm_alsa.ko"
install -m 0644 "$bazel_output/unstripped/frankel_pdm_alsa.ko" \
  "$output_dir/frankel_pdm_alsa.unstripped.ko"

actual_release=$(modinfo -F vermagic "$output_dir/frankel_pdm_alsa.ko")
if [[ "$actual_release" != "$expected_release "* ]]; then
  printf 'unexpected vermagic: %s\n' "$actual_release" >&2
  exit 5
fi

imports_file=$(mktemp)
expected_file=$(mktemp)
trap 'rm -f "$imports_file" "$expected_file"' EXIT
readelf -Ws "$output_dir/frankel_pdm_alsa.unstripped.ko" |
  awk '$7 == "UND" && $8 != "" { print $8 }' | sort -u >"$imports_file"
sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
  "$script_dir/allowed-imports.txt" | sort -u >"$expected_file"
if ! diff -u "$expected_file" "$imports_file"; then
  printf 'undefined-import allowlist mismatch\n' >&2
  exit 6
fi
if grep -Eiq '(^|_)(write[blqw]|iowrite|memcpy_toio|memset_io|clk_|dma_|request_irq|request_mem_region)' \
    "$imports_file"; then
  printf 'forbidden hardware-mutating import found\n' >&2
  exit 7
fi

while read -r crc symbol; do
  expected_crc=$(awk -v name="$symbol" '$2 == name { print $1; exit }' \
    "$artifacts/Module.symvers")
  if [[ -z "$expected_crc" || "${expected_crc,,}" != "${crc,,}" ]]; then
    printf 'symbol CRC mismatch: %s module=%s target=%s\n' \
      "$symbol" "$crc" "${expected_crc:-missing}" >&2
    exit 8
  fi
done < <(modprobe --show-modversions "$output_dir/frankel_pdm_alsa.ko")

if [[ "$update_lock" == true ]]; then
  frankel_pdm_provenance_write_lock "$manifest_root"
else
  frankel_pdm_provenance_validate_lock "$manifest_root"
fi

printf 'Built; declared audits passed: %s\n' "$output_dir/frankel_pdm_alsa.ko"
printf 'Vermagic: %s\n' "$actual_release"
printf 'Undefined imports match: %s\n' "$script_dir/allowed-imports.txt"
printf 'Provenance lock: %s (%s)\n' \
  "$frankel_pdm_provenance_lock_relative_path" \
  "$([[ "$update_lock" == true ]] && printf updated || printf verified)"
