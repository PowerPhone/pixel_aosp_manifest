#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
manifest_root=$(cd -- "$script_dir/../../../.." && pwd -P)
gki_artifacts="$manifest_root/work/upstream/frankel-gki-15739706"
ddk_workspace="$gki_artifacts/ddk-workspace"
package_dir="$ddk_workspace/probes/frankel_d5_period_rt"
output_dir="$gki_artifacts/modules"
target='//probes/frankel_d5_period_rt:frankel_d5_period_rt'

[[ -x "$ddk_workspace/tools/bazel" ]] || {
  printf 'Missing prepared Frankel GKI DDK: %s\n' "$ddk_workspace" >&2
  exit 2
}
mkdir -p -- "$package_dir" "$output_dir"
install -m 0644 "$script_dir/BUILD.bazel" "$package_dir/BUILD.bazel"
install -m 0644 "$script_dir/frankel_d5_period_rt.c" "$package_dir/frankel_d5_period_rt.c"
(
  cd -- "$ddk_workspace"
  tools/bazel build "$target"
)
bazel_output="$ddk_workspace/bazel-bin/probes/frankel_d5_period_rt/frankel_d5_period_rt"
install -m 0644 "$bazel_output/frankel_d5_period_rt.ko" "$output_dir/frankel_d5_period_rt.ko"
install -m 0644 "$bazel_output/unstripped/frankel_d5_period_rt.ko" \
  "$output_dir/frankel_d5_period_rt.unstripped.ko"
symvers_path="$bazel_output/frankel_d5_period_rt_Module.symvers"
install -m 0644 "$symvers_path" "$output_dir/frankel_d5_period_rt.Module.symvers"
printf 'Built RT helper: %s\n' "$output_dir/frankel_d5_period_rt.ko"
printf 'Helper ABI versions (for the util import redirect): %s\n' "$symvers_path"
