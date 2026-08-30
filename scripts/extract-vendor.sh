#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

"$script_dir/check-host.sh"

require_command git node sha256sum yarn

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
assert_inside_work "$source_dir"
require_file "$source_dir/build/envsetup.sh"
require_file "$project_root/manifests/resolved.xml"
require_file "$source_dir/vendor/adevtool/yarn.lock"
require_file "$source_dir/vendor/state/$DEVICE_CODENAME.json"

factory_image="$project_root/downloads/$FACTORY_IMAGE_FILENAME"
verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"

"$script_dir/apply-source-patches.sh"
"$script_dir/check-source.sh" --allow-patches

cd "$source_dir"
adevtool_dir=$(realpath -e -- "$source_dir/vendor/adevtool")
[[ "$adevtool_dir" == "$source_dir/vendor/adevtool" && \
   -d "$adevtool_dir" && ! -L "$source_dir/vendor/adevtool" ]] || \
  die "adevtool checkout is not the expected real directory: $adevtool_dir"

# A frozen install does not remove dependencies left behind by an earlier
# lockfile. Start from the one exact ignored dependency directory so the
# executed JavaScript closure is reconstructed solely from yarn.lock.
node_modules_dir="$adevtool_dir/node_modules"
[[ "$node_modules_dir" == "$source_dir/vendor/adevtool/node_modules" ]] || \
  die "refusing to clean an unexpected dependency path: $node_modules_dir"
git -C "$adevtool_dir" check-ignore --quiet -- node_modules || \
  die "adevtool node_modules is not ignored by the pinned checkout"
if [[ -e "$node_modules_dir" || -L "$node_modules_dir" ]]; then
  [[ -d "$node_modules_dir" && ! -L "$node_modules_dir" ]] || \
    die "adevtool node_modules is not a real directory: $node_modules_dir"
  note "removing the prior ignored adevtool dependency tree"
  rm -rf -- "$node_modules_dir"
fi
note "installing pinned adevtool JavaScript dependencies"
yarn --cwd "$adevtool_dir" install --frozen-lockfile --non-interactive

# adevtool builds its host-side Android extraction helpers through the platform
# build system, so ANDROID_BUILD_TOP must be established first.
# shellcheck disable=SC1091
source build/envsetup.sh
export ADEVTOOL_IMG_DOWNLOAD_DIR="$project_root/downloads"
vendor_root="$source_dir/vendor"
vendor_root_real=$(realpath -e -- "$vendor_root")
[[ "$vendor_root_real" == "$vendor_root" && -d "$vendor_root" && \
   ! -L "$vendor_root" ]] || \
  die "AOSP vendor root is not the expected real directory: $vendor_root"
# adevtool emits this path into generated Make variables. Keep it relative to
# ANDROID_BUILD_TOP so the generated module matches the upstream FileTreeSpec
# and remains portable instead of capturing this workspace's absolute path.
export ADEVTOOL_VENDOR_DIR_ROOT=vendor
export ADEVTOOL_CONFIG_DIR="$source_dir/vendor/adevtool/config"
export ADEVTOOL_SYSTEM_STATE_DIR="$source_dir/vendor/state"
# Never trust a caller-provided request to reuse possibly stale host helpers.
export ADEVTOOL_SKIP_DEP_BUILD=0

# adevtool's own cache key is only its committed repository HEAD. This checkout
# intentionally carries reviewed uncommitted patches in other AOSP projects,
# including tools/apksig, so that key cannot notice a changed host apksigner.
# Withdraw both the key and the two installed apksigner outputs. The subsequent
# incremental platform build then has to reconstruct them from the attested
# source closure instead of accepting a binary from an earlier extraction.
adevtool_out_dir="$source_dir/out_adevtool_deps"
if [[ -e "$adevtool_out_dir" || -L "$adevtool_out_dir" ]]; then
  adevtool_out_real=$(realpath -e -- "$adevtool_out_dir")
  [[ "$adevtool_out_real" == "$adevtool_out_dir" && \
     -d "$adevtool_out_dir" && ! -L "$adevtool_out_dir" ]] || \
    die "unsafe adevtool dependency output directory: $adevtool_out_dir"
  for stale_host_output in \
    "$adevtool_out_dir/adevtool_revision" \
    "$adevtool_out_dir/host/linux-x86/bin/apksigner" \
    "$adevtool_out_dir/host/linux-x86/framework/apksigner.jar"; do
    if [[ -e "$stale_host_output" || -L "$stale_host_output" ]]; then
      [[ -f "$stale_host_output" && ! -L "$stale_host_output" ]] || \
        die "unsafe stale adevtool host output: $stale_host_output"
      rm -f -- "$stale_host_output"
    fi
  done
fi

unpack_concurrency=${ADEVTOOL_UNPACK_CONCURRENCY:-10}
download_concurrency=${ADEVTOOL_DOWNLOAD_CONCURRENCY:-20}
for concurrency in "$unpack_concurrency" "$download_concurrency"; do
  [[ "$concurrency" =~ ^[1-9][0-9]*$ ]] || \
    die "adevtool concurrency must be a positive integer"
  (( concurrency <= 64 )) || die "adevtool concurrency must not exceed 64"
done
export ADEVTOOL_UNPACK_CONCURRENCY=$unpack_concurrency
export ADEVTOOL_DOWNLOAD_CONCURRENCY=$download_concurrency

note "generating and verifying $DEVICE_CODENAME vendor support from $STOCK_BUILD_ID"
# Intentionally do not pass --noVerify or --updateSpec. A mismatch against the
# immutable upstream reference is a hard failure for a reproducible extraction.
vendor/adevtool/bin/run generate-all -d "$DEVICE_CODENAME"

generated_dir="$source_dir/vendor/google_devices/$DEVICE_CODENAME"
require_file "$generated_dir/$DEVICE_CODENAME.mk"
require_file "$generated_dir/BoardConfig.mk"
require_file "$generated_dir/stock-kernel/Image.lz4"
note "verified vendor module against the pinned adevtool specification"
"$script_dir/check-source.sh" --allow-patches
case "$DEVICE_CODENAME" in
  cubs) "$script_dir/sanitize-generated-vendor.sh" ;;
  frankel) "$script_dir/sanitize-generated-vendor-frankel.sh" ;;
  *) die "no generated-vendor sanitizer is implemented for $DEVICE_CODENAME" ;;
esac
"$script_dir/attest-generated-vendor.sh" create
note "AOSP-compatible vendor module: $generated_dir"
