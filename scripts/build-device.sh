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
out_dir=${DEVICE_OUT_DIR:-"$source_dir/out_pixel/$DEVICE_CODENAME"}
out_dir=$(realpath -m -- "$out_dir")
if [[ -n "${DEVICE_TARGET_FILES:-}" ]]; then
  [[ ! -L "$DEVICE_TARGET_FILES" ]] || \
    die "DEVICE_TARGET_FILES must not be a symbolic link"
  DEVICE_TARGET_FILES=$(realpath -m -- "$DEVICE_TARGET_FILES")
  export DEVICE_TARGET_FILES
elif [[ "$DEVICE_CODENAME" == cubs && -n "${CUBS_TARGET_FILES:-}" ]]; then
  [[ ! -L "$CUBS_TARGET_FILES" ]] || \
    die "CUBS_TARGET_FILES must not be a symbolic link"
  DEVICE_TARGET_FILES=$(realpath -m -- "$CUBS_TARGET_FILES")
  export DEVICE_TARGET_FILES
fi
assert_inside_work "$source_dir"
assert_inside_work "$out_dir"
case "$out_dir" in
  "$source_dir"/*) ;;
  *) die "DEVICE_OUT_DIR must be inside the AOSP source tree for Soong/Siso" ;;
esac
require_target_scoped_output "$source_dir" "$out_dir"
require_file "$source_dir/build/envsetup.sh"
require_file "$project_root/manifests/resolved.xml"
require_file "$source_dir/vendor/google_devices/$DEVICE_CODENAME/$DEVICE_CODENAME.mk"

"$script_dir/apply-source-patches.sh"
case "$DEVICE_CODENAME" in
  cubs) "$script_dir/sanitize-generated-vendor.sh" ;;
  frankel) "$script_dir/sanitize-generated-vendor-frankel.sh" ;;
  *) die "no generated-vendor sanitizer is implemented for $DEVICE_CODENAME" ;;
esac
"$script_dir/attest-generated-vendor.sh" verify
"$script_dir/check-source.sh" --allow-patches

logs_dir="$project_root/logs"
assert_inside_project "$logs_dir"
[[ ! -L "$logs_dir" ]] || die "logs directory must not be a symbolic link"
mkdir -p "$out_dir" "$logs_dir"
[[ -d "$logs_dir" && ! -L "$logs_dir" ]] || \
  die "logs path is not a real directory: $logs_dir"
build_log="$logs_dir/build-$DEVICE_CODENAME.log"
[[ ! -L "$build_log" && ( ! -e "$build_log" || -f "$build_log" ) ]] || \
  die "$DEVICE_CODENAME build log is not a safe regular file: $build_log"
cd "$source_dir"
# Siso's config repository flag is relative to the source execution root, and
# Soong requires output paths to remain below that root.
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
export USE_STOCK_KERNEL=true

# shellcheck disable=SC1091
source build/envsetup.sh
# Adevtool emits per-product release variables. Source them explicitly so this
# works without the downstream envsetup auto-discovery change.
# shellcheck disable=SC1090
source "vendor/google_devices/$DEVICE_CODENAME/cmds-for-envsetup.sh"
lunch "$DEVICE_PRODUCT_TARGET"

if [[ "$DEVICE_CODENAME" == cubs ]]; then
  AOSP_SOURCE_DIR="$source_dir" DEVICE_OUT_DIR="$out_dir" \
    "$script_dir/attest-build-output.sh" invalidate cubs
else
  AOSP_SOURCE_DIR="$source_dir" DEVICE_OUT_DIR="$out_dir" \
    "$script_dir/attest-device-build.sh" invalidate
fi
note "building $DEVICE_CODENAME userdebug target-files and boot images with $build_jobs jobs"
# Cubs uses BOARD_PREBUILT_DTBOIMAGE. AOSP creates the concrete dtbo.img edge
# but no legacy dtboimage phony target; vbmetaimage and target-files-package
# both depend on that concrete image and therefore build it fail-closed.
# The otatools archive packages its dependencies without installing them into
# host/bin, so request the image reconstructor and two VINTF checkers explicitly
# for completion and packaging validation. Oatdump is likewise a direct input
# to the Malibu semantic gate.
m -j"$build_jobs" \
  target-files-package \
  otatools-package \
  img_from_target_files \
  check_target_files_vintf \
  checkvintf \
  oatdump \
  bootimage \
  initbootimage \
  vendorbootimage \
  vendorkernelbootimage \
  vbmetaimage \
  2>&1 | tee "$build_log"

# Recheck both public and proprietary inputs at completion so a tree changed
# during the build cannot receive a successful marker merely because it was
# valid at startup.
"$script_dir/check-source.sh" --allow-patches
AOSP_SOURCE_DIR="$source_dir" \
  "$script_dir/attest-generated-vendor.sh" verify
product_out="$out_dir/target/product/$DEVICE_CODENAME"
require_file "$product_out/boot.img"
require_file "$product_out/vendor_boot.img"
require_file "$product_out/vendor_kernel_boot.img"
if [[ "$DEVICE_CODENAME" == cubs ]]; then
  AOSP_SOURCE_DIR="$source_dir" DEVICE_OUT_DIR="$out_dir" \
    "$script_dir/attest-build-output.sh" create cubs
else
  AOSP_SOURCE_DIR="$source_dir" DEVICE_OUT_DIR="$out_dir" \
    "$script_dir/attest-device-build.sh" create
fi
note "device output: $product_out"
