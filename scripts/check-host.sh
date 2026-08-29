#!/usr/bin/env bash
set -euo pipefail

check_host_source=${BASH_SOURCE[0]}
case "$check_host_source" in
  */*) check_host_directory=${check_host_source%/*} ;;
  *) check_host_directory=. ;;
esac
script_dir=$(builtin cd -- "$check_host_directory" && builtin pwd -P)
unset check_host_source check_host_directory
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=lib/host-toolchain.sh
source "$script_dir/lib/host-toolchain.sh"
# Keep unverified workspace candidates off PATH until their complete trees pass.
PIXEL_AOSP_DEFER_TOOLCHAIN_PATH=true
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"
unset PIXEL_AOSP_DEFER_TOOLCHAIN_PATH
# shellcheck source=../config/recovery.env disable=SC1091
source "$project_root/config/recovery.env"

[[ -x /usr/bin/python3 ]] || die "trusted Python bootstrap is missing: /usr/bin/python3"

required_commands=(
  adb
  brotli
  ccache
  curl
  fastboot
  findmnt
  flock
  git
  jq
  lz4
  node
  repo
  sha256sum
  unzip
  xxd
  yarn
  zip
  zstd
)

toolchain_dir="$project_root/work/toolchains"
[[ -d "$toolchain_dir" && ! -L "$toolchain_dir" ]] || \
  die "workspace toolchain root is not a real directory: $toolchain_dir"
exec {toolchain_lock_fd}<"$toolchain_dir"
/usr/bin/flock -s "$toolchain_lock_fd"
locked_toolchain_dir=$(
  /usr/bin/readlink -f -- "/proc/self/fd/$toolchain_lock_fd"
)
[[ "$locked_toolchain_dir" == "$toolchain_dir" ]] || \
  die "host-check lock does not refer to the workspace toolchain directory"
unset locked_toolchain_dir
node_version_dir="$toolchain_dir/node-v$NODE_VERSION-linux-x64"
node_archive="$project_root/downloads/toolchains/$NODE_FILENAME"
yarn_archive="$project_root/downloads/toolchains/$YARN_FILENAME"
host_toolchain_verify_node \
  "$node_archive" "${node_version_dir##*/}" "$NODE_SHA256" \
  "$node_version_dir" "$toolchain_dir"
host_toolchain_verify_yarn \
  "$yarn_archive" package "$YARN_SHA256" "$node_version_dir" \
  "$YARN_VERSION" "$YARN_URL" "$toolchain_dir"

platform_tools_archive="$project_root/downloads/toolchains/$PLATFORM_TOOLS_FILENAME"
platform_tools_version_dir="$toolchain_dir/platform-tools-$PLATFORM_TOOLS_VERSION"
platform_tools_dir="$platform_tools_version_dir/platform-tools"
host_toolchain_verify_zip_tree \
  "$platform_tools_archive" platform-tools "$PLATFORM_TOOLS_SHA256" \
  "$platform_tools_dir" "$toolchain_dir"
expected_adb="$platform_tools_dir/adb"
expected_fastboot="$platform_tools_dir/fastboot"
host_toolchain_verify_regular_sha256 \
  "$expected_adb" "$PLATFORM_TOOLS_ADB_SHA256" adb
host_toolchain_verify_regular_sha256 \
  "$expected_fastboot" "$PLATFORM_TOOLS_FASTBOOT_SHA256" fastboot

activate_workspace_toolchains
require_command "${required_commands[@]}"

case "$(uname -m)" in
  x86_64) ;;
  *) die "AOSP host must be x86_64; found $(uname -m)" ;;
esac

expected_node=$(/usr/bin/realpath -- "$node_version_dir/bin/node")
expected_yarn=$(
  /usr/bin/realpath -- "$node_version_dir/node_modules/yarn/bin/yarn.js"
)
expected_adb=$(/usr/bin/realpath -- "$expected_adb")
expected_fastboot=$(/usr/bin/realpath -- "$expected_fastboot")
[[ "$(/usr/bin/realpath -- "$(command -v node)")" == "$expected_node" ]] || \
  die "Node.js command does not resolve to the attested pinned distribution"
[[ "$(/usr/bin/realpath -- "$(command -v yarn)")" == "$expected_yarn" ]] || \
  die "Yarn command does not resolve to the attested pinned package"
[[ "$(/usr/bin/realpath -- "$(command -v adb)")" == "$expected_adb" ]] || \
  die "adb command does not resolve to the attested Platform-Tools tree"
[[ "$(/usr/bin/realpath -- "$(command -v fastboot)")" == \
   "$expected_fastboot" ]] || \
  die "fastboot command does not resolve to the attested Platform-Tools tree"
[[ "$(/usr/bin/env -i PATH=/usr/bin:/bin "$expected_node" --version)" == \
   "v$NODE_VERSION" ]] || die "Node.js must match pinned version $NODE_VERSION"
[[ "$(/usr/bin/env -i PATH="$node_version_dir/bin:/usr/bin:/bin" \
  "$(command -v yarn)" --version)" == "$YARN_VERSION" ]] || \
  die "Yarn must match pinned version $YARN_VERSION"

fastboot_version=$(
  /usr/bin/env -i PATH=/usr/bin:/bin "$expected_fastboot" --version | \
    /usr/bin/sed -nE 's/^fastboot version ([^-]+)-.*/\1/p'
)
adb_version=$(
  /usr/bin/env -i PATH=/usr/bin:/bin "$expected_adb" version | \
    /usr/bin/sed -nE 's/^Version ([^-]+)-.*/\1/p'
)
[[ "$fastboot_version" == "$PLATFORM_TOOLS_VERSION" ]] || \
  die "fastboot must match pinned Platform-Tools $PLATFORM_TOOLS_VERSION"
[[ "$adb_version" == "$PLATFORM_TOOLS_VERSION" ]] || \
  die "adb must match pinned Platform-Tools $PLATFORM_TOOLS_VERSION"
for tool_path in \
  "$(command -v node)" \
  "$(command -v yarn)" \
  "$(command -v adb)" \
  "$(command -v fastboot)"; do
  resolved_tool=$(/usr/bin/realpath -- "$tool_path")
  case "$resolved_tool" in
    "$project_root/work/toolchains/"*) ;;
    *) die "host tool is not from the pinned workspace toolchain: $resolved_tool" ;;
  esac
done

workspace_free_kib=$(df --output=avail -k "$project_root" | tail -n 1 | tr -d ' ')
minimum_free_kib=$((400 * 1024 * 1024))
(( workspace_free_kib >= minimum_free_kib )) || \
  die "at least 400 GiB free is required before source sync/build"
memory_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
minimum_memory_kib=$((64 * 1024 * 1024))
(( memory_kib >= minimum_memory_kib )) || \
  die "at least 64 GiB RAM is required for this full device build"
filesystem_type=$(findmnt -no FSTYPE -T "$project_root")
[[ "$filesystem_type" == ext4 ]] || \
  die "workspace must use native ext4; found $filesystem_type"

printf 'workspace: %s\n' "$project_root"
printf 'kernel: %s\n' "$(uname -srmo)"
printf 'free disk: %s\n' "$(df -h --output=avail "$project_root" | tail -n 1 | xargs)"
printf 'memory: %s\n' "$(free -h | awk '/^Mem:/ {print $2}')"
if [[ -d "$project_root/work/aosp/.repo" ]]; then
  repo_program="$project_root/work/aosp/.repo/repo/repo"
  [[ -f "$repo_program" && ! -L "$repo_program" && -x "$repo_program" ]] || \
    die "pinned Repo implementation is missing or unsafe: $repo_program"
  actual_repo_revision=$(git -C "$project_root/work/aosp/.repo/repo" \
    rev-parse --verify 'HEAD^{commit}')
  [[ "$actual_repo_revision" == "$REPO_REVISION" ]] || \
    die "Repo implementation is $actual_repo_revision, expected $REPO_REVISION"
  repo_summary=$(cd "$project_root/work/aosp" && \
    "$repo_program" version 2>/dev/null | \
    sed -n '/^repo version /p' | head -n 1)
else
  repo_summary="launcher $(command -v repo)"
fi
printf 'repo: %s\n' "$repo_summary"
printf 'fastboot: %s\n' "$(fastboot --version | sed -n '1p')"
printf 'node: %s\n' "$(node --version)"
printf 'yarn: %s\n' "$(yarn --version)"
