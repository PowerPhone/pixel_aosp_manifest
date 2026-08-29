#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

export BUILD_NUMBER="$AOSP_BUILD_NUMBER"
export BUILD_USERNAME="$AOSP_BUILD_USERNAME"
export BUILD_HOSTNAME="$AOSP_BUILD_HOSTNAME"
export BUILD_DATETIME="$AOSP_BUILD_DATETIME"
export TZ="$AOSP_BUILD_TIMEZONE"
export LC_ALL="$AOSP_BUILD_LOCALE"
export LANG="$AOSP_BUILD_LOCALE"
strict_aosp_build_environment

"$script_dir/check-host.sh"

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
build_jobs=${BUILD_JOBS:-$(nproc)}
[[ "$build_jobs" =~ ^[1-9][0-9]*$ ]] || \
  die "BUILD_JOBS must be a positive integer"
(( build_jobs <= 256 )) || die "BUILD_JOBS must not exceed 256"
source_dir=$(realpath -m -- "$source_dir")
out_dir=${AOSP_OUT_DIR:-"$source_dir/out_pixel/gsi"}
out_dir=$(realpath -m -- "$out_dir")
gsi_artifact_dir="$project_root/artifacts/gsi"
assert_inside_work "$source_dir"
assert_inside_work "$out_dir"
case "$out_dir" in
  "$source_dir"/*) ;;
  *) die "AOSP_OUT_DIR must be inside the AOSP source tree for Soong/Siso" ;;
esac
require_file "$source_dir/build/envsetup.sh"
require_file "$project_root/manifests/resolved.xml"

# The synced extraction projects participate in Soong graph validation. Apply
# the pinned host-tool compatibility stack before configuring any product; its
# runtime behavior is inert for the generic GSI target.
"$script_dir/apply-source-patches.sh"
"$script_dir/check-source.sh" --allow-patches

logs_dir="$project_root/logs"
assert_inside_project "$logs_dir"
[[ ! -L "$logs_dir" ]] || die "logs directory must not be a symbolic link"
mkdir -p "$out_dir" "$logs_dir"
[[ -d "$logs_dir" && ! -L "$logs_dir" ]] || \
  die "logs path is not a real directory: $logs_dir"
build_log="$logs_dir/build-gsi.log"
[[ ! -L "$build_log" && ( ! -e "$build_log" || -f "$build_log" ) ]] || \
  die "GSI build log is not a safe regular file: $build_log"
cd "$source_dir"
# Siso resolves its Starlark config repository relative to the source-tree
# execution root, while Soong rejects output paths that escape that root.
export OUT_DIR
OUT_DIR=$(realpath --relative-to="$source_dir" "$out_dir")
export USE_CCACHE=${USE_CCACHE:-1}
export CCACHE_EXEC=${CCACHE_EXEC:-/usr/bin/ccache}
export CCACHE_DIR=${CCACHE_DIR:-"$out_dir/ccache"}
export CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-50G}
CCACHE_DIR=$(realpath -m -- "$CCACHE_DIR")
export CCACHE_DIR
assert_inside_work "$CCACHE_DIR"
[[ ! -L "$CCACHE_DIR" ]] || \
  die "ccache directory must not be a symbolic link: $CCACHE_DIR"
mkdir -p "$CCACHE_DIR"
[[ -d "$CCACHE_DIR" && ! -L "$CCACHE_DIR" ]] || \
  die "ccache path is not a real directory: $CCACHE_DIR"
case "$USE_CCACHE" in
  0) ;;
  1)
    [[ -x /usr/bin/ccache && ! -L /usr/bin/ccache ]] || \
      die "the audited /usr/bin/ccache package executable is unavailable"
    CCACHE_EXEC=$(realpath -e -- "$CCACHE_EXEC")
    export CCACHE_EXEC
    [[ "$CCACHE_EXEC" == /usr/bin/ccache ]] || \
      die "CCACHE_EXEC must resolve to the audited /usr/bin/ccache executable"
    "$CCACHE_EXEC" -d "$CCACHE_DIR" -M "$CCACHE_MAXSIZE"
    note "ccache limit: $CCACHE_MAXSIZE ($CCACHE_DIR)"
    ;;
  *) die "USE_CCACHE must be 0 or 1" ;;
esac

# shellcheck disable=SC1091
source build/envsetup.sh
lunch gsi_arm64-aosp_current-userdebug

AOSP_SOURCE_DIR="$source_dir" AOSP_OUT_DIR="$out_dir" \
  "$script_dir/attest-build-output.sh" invalidate gsi
note "building AOSP $AOSP_REVISION gsi_arm64-aosp_current-userdebug with $build_jobs jobs"
m -j"$build_jobs" systemimage pvmfwimage vbmetaimage 2>&1 | \
  tee "$build_log"

# Re-prove the live source immediately after compilation. This closes the
# interval in which a concurrent source edit could otherwise receive a valid
# completion attestation merely because the checkout passed the startup gate.
"$script_dir/check-source.sh" --allow-patches

product_out="$out_dir/target/product/generic_arm64"
system_image="$product_out/system.img"
pvmfw_image="$product_out/pvmfw.img"
vbmeta_image="$product_out/vbmeta.img"
require_file "$system_image"
require_file "$pvmfw_image"
require_file "$vbmeta_image"
[[ ! -L "$gsi_artifact_dir" ]] || \
  die "GSI artifact directory must not be a symbolic link"
mkdir -p "$gsi_artifact_dir"
[[ -d "$gsi_artifact_dir" && ! -L "$gsi_artifact_dir" ]] || \
  die "GSI artifact path is not a real directory: $gsi_artifact_dir"
for staged_name in system.img pvmfw.img vbmeta.img SHA256SUMS; do
  [[ ! -L "$gsi_artifact_dir/$staged_name" && \
     ( ! -e "$gsi_artifact_dir/$staged_name" || \
       -f "$gsi_artifact_dir/$staged_name" ) ]] || \
    die "unsafe GSI artifact path: $gsi_artifact_dir/$staged_name"
done
# Withdraw any previously published checksum before refreshing raw images.
# package-gsi.sh publishes a complete manifest only after static validation.
rm -f -- "$gsi_artifact_dir/SHA256SUMS"
install -m 0644 "$system_image" "$gsi_artifact_dir/system.img"
install -m 0644 "$pvmfw_image" "$gsi_artifact_dir/pvmfw.img"
install -m 0644 "$vbmeta_image" "$gsi_artifact_dir/vbmeta.img"
AOSP_SOURCE_DIR="$source_dir" AOSP_OUT_DIR="$out_dir" \
GSI_ARTIFACT_DIR="$gsi_artifact_dir" \
  "$script_dir/attest-build-output.sh" create gsi
note "GSI artifacts: $gsi_artifact_dir"
