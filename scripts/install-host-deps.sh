#!/usr/bin/env bash
set -euo pipefail

installer_source=${BASH_SOURCE[0]}
case "$installer_source" in
  */*) installer_directory=${installer_source%/*} ;;
  *) installer_directory=. ;;
esac
project_root=$(builtin cd -- "$installer_directory/.." && builtin pwd -P)
unset installer_source installer_directory
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=../config/release.env
source "$project_root/config/release.env"
# shellcheck source=../config/recovery.env
source "$project_root/config/recovery.env"
# shellcheck source=lib/host-toolchain.sh
source "$project_root/scripts/lib/host-toolchain.sh"

# Ubuntu packages required by AOSP 17, adevtool, image inspection, and packaging.
# AOSP supplies its own JDK, Python, Make, Clang, Ninja, and most Android image
# utilities as prebuilts; host packages below cover the remaining dependencies.
packages=(
  android-sdk-libsparse-utils
  bison
  brotli
  build-essential
  ca-certificates
  ccache
  curl
  device-tree-compiler
  diffutils
  e2fsprogs
  erofs-utils
  f2fs-tools
  flex
  fontconfig
  git-core
  git-lfs
  gnupg
  gperf
  jq
  lib32z1-dev
  libc6-dev-i386
  libgl1-mesa-dev
  libx11-dev
  libxml2-utils
  lz4
  openssh-client
  openssl
  pkgconf
  protobuf-compiler
  python3-protobuf
  repo
  rsync
  shellcheck
  unzip
  util-linux
  x11proto-core-dev
  xsltproc
  xxd
  zip
  zlib1g-dev
  zstd
  xz-utils
  7zip
)

sudo apt-get update
sudo apt-get install -y --no-install-recommends "${packages[@]}"

# Keep adevtool's newer Node requirement independent of the distribution. Both
# the archive and version are immutable inputs recorded in release.env.
toolchain_download_dir="$project_root/downloads/toolchains"
node_version_dir="$project_root/work/toolchains/node-v$NODE_VERSION-linux-x64"
node_link="$project_root/work/toolchains/node"
node_archive="$toolchain_download_dir/$NODE_FILENAME"
for local_directory in \
  "$project_root/downloads" \
  "$toolchain_download_dir" \
  "$project_root/work" \
  "$project_root/work/toolchains"; do
  [[ ! -L "$local_directory" ]] || {
    printf 'error: workspace directory must not be a symbolic link: %s\n' \
      "$local_directory" >&2
    exit 1
  }
  mkdir -p "$local_directory"
  [[ -d "$local_directory" && ! -L "$local_directory" ]] || {
    printf 'error: workspace path is not a real directory: %s\n' \
      "$local_directory" >&2
    exit 1
  }
done

# Lock the already validated real directory itself. Directory-FD flock has no
# stale lockfile or symlink-following path and is released automatically on exit.
exec {toolchain_lock_fd}<"$project_root/work/toolchains"
/usr/bin/flock -x "$toolchain_lock_fd"
locked_toolchain_dir=$(
  /usr/bin/readlink -f -- "/proc/self/fd/$toolchain_lock_fd"
)
[[ "$locked_toolchain_dir" == "$project_root/work/toolchains" ]] || {
  printf 'error: toolchain lock does not refer to the workspace directory\n' >&2
  exit 1
}
unset locked_toolchain_dir

host_toolchain_reconcile_version_directory "$node_version_dir" Node.js

temporary_node_root=
temporary_platform_root=
cleanup() {
  if [[ -n "$temporary_node_root" && -d "$temporary_node_root" && \
        ! -L "$temporary_node_root" && \
        "$temporary_node_root" == "$project_root/work/toolchains"/.node.* ]]; then
    rm -rf -- "$temporary_node_root"
  fi
  if [[ -n "$temporary_platform_root" && -d "$temporary_platform_root" && \
        ! -L "$temporary_platform_root" && \
        "$temporary_platform_root" == \
          "$project_root/work/toolchains"/.platform-tools.* ]]; then
    rm -rf -- "$temporary_platform_root"
  fi
}
trap cleanup EXIT

if [[ -e "$node_archive" || -L "$node_archive" ]]; then
  [[ -f "$node_archive" && ! -L "$node_archive" ]] || {
    printf 'error: Node.js archive is not a regular file: %s\n' \
      "$node_archive" >&2
    exit 1
  }
  printf '%s  %s\n' "$NODE_SHA256" "$node_archive" | sha256sum --check
else
  [[ ! -e "$node_archive.part" && ! -L "$node_archive.part" ]] || {
    printf 'error: unsafe pre-existing partial download: %s\n' \
      "$node_archive.part" >&2
    exit 1
  }
  curl --fail --location --retry 5 --retry-all-errors \
    --output "$node_archive.part" "$NODE_URL"
  printf '%s  %s\n' "$NODE_SHA256" "$node_archive.part" | sha256sum --check
  [[ ! -e "$node_archive" && ! -L "$node_archive" ]] || {
    printf 'error: Node.js archive appeared concurrently: %s\n' \
      "$node_archive" >&2
    exit 1
  }
  mv -- "$node_archive.part" "$node_archive"
fi

# adevtool carries a Yarn v1 lockfile. Install classic Yarn from a
# checksum-pinned tarball into the local Node prefix to prevent both registry
# drift and lockfile migration by Yarn Berry.
yarn_archive="$toolchain_download_dir/$YARN_FILENAME"
if [[ -e "$yarn_archive" || -L "$yarn_archive" ]]; then
  [[ -f "$yarn_archive" && ! -L "$yarn_archive" ]] || {
    printf 'error: Yarn archive is not a regular file: %s\n' \
      "$yarn_archive" >&2
    exit 1
  }
  printf '%s  %s\n' "$YARN_SHA256" "$yarn_archive" | sha256sum --check
else
  [[ ! -e "$yarn_archive.part" && ! -L "$yarn_archive.part" ]] || {
    printf 'error: unsafe pre-existing partial download: %s\n' \
      "$yarn_archive.part" >&2
    exit 1
  }
  curl --fail --location --retry 5 --retry-all-errors \
    --output "$yarn_archive.part" "$YARN_URL"
  printf '%s  %s\n' "$YARN_SHA256" "$yarn_archive.part" | sha256sum --check
  [[ ! -e "$yarn_archive" && ! -L "$yarn_archive" ]] || {
    printf 'error: Yarn archive appeared concurrently: %s\n' \
      "$yarn_archive" >&2
    exit 1
  }
  mv -- "$yarn_archive.part" "$yarn_archive"
fi
host_toolchain_validate_archive "$yarn_archive" package "$YARN_SHA256"

# Never execute a reused tool before proving it equivalent to fresh extraction
# of the pinned archives. The root package metadata and node_modules tree are the
# only Node paths omitted, and the Yarn verifier closes that entire overlay.
node_archive_root=${node_version_dir##*/}
node_and_yarn_valid=false
if [[ -e "$node_version_dir" || -L "$node_version_dir" ]]; then
  [[ -d "$node_version_dir" && ! -L "$node_version_dir" ]] || {
    printf 'error: Node.js version path is not a real directory: %s\n' \
      "$node_version_dir" >&2
    exit 1
  }
  if host_toolchain_verify_node \
      "$node_archive" "$node_archive_root" "$NODE_SHA256" \
      "$node_version_dir" "$project_root/work/toolchains" \
      >/dev/null 2>&1 && \
     host_toolchain_verify_yarn \
      "$yarn_archive" package "$YARN_SHA256" "$node_version_dir" \
      "$YARN_VERSION" "$YARN_URL" "$project_root/work/toolchains" \
      >/dev/null 2>&1; then
    node_and_yarn_valid=true
  fi
fi
if [[ "$node_and_yarn_valid" != true ]]; then
  temporary_node_root=$(mktemp -d "$project_root/work/toolchains/.node.XXXXXX")
  host_toolchain_safe_extract \
    "$node_archive" "$node_archive_root" "$NODE_SHA256" \
    "$temporary_node_root"
  temporary_node_dir="$temporary_node_root/$node_archive_root"
  host_toolchain_verify_node \
    "$node_archive" "$node_archive_root" "$NODE_SHA256" \
    "$temporary_node_dir" "$project_root/work/toolchains"

  # Map the vetted Yarn package directly into the fresh Node tree. No package
  # manager, lifecycle hook, registry lookup, or existing executable is run.
  host_toolchain_stage_yarn \
    "$yarn_archive" package "$YARN_SHA256" "$temporary_node_dir" \
    "$YARN_VERSION" "$YARN_URL" "$project_root/work/toolchains"
  host_toolchain_verify_node \
    "$node_archive" "$node_archive_root" "$NODE_SHA256" \
    "$temporary_node_dir" "$project_root/work/toolchains"
  host_toolchain_verify_yarn \
    "$yarn_archive" package "$YARN_SHA256" "$temporary_node_dir" \
    "$YARN_VERSION" "$YARN_URL" "$project_root/work/toolchains"

  staged_yarn="$temporary_node_dir/node_modules/.bin/yarn"
  [[ "$(/usr/bin/env -i PATH=/usr/bin:/bin \
    "$temporary_node_dir/bin/node" --version)" == "v$NODE_VERSION" ]] || {
    printf 'error: staged Node.js version mismatch\n' >&2
    exit 1
  }
  [[ "$(/usr/bin/env -i PATH="$temporary_node_dir/bin:/usr/bin:/bin" \
    "$staged_yarn" --version)" == "$YARN_VERSION" ]] || {
    printf 'error: staged Yarn version mismatch\n' >&2
    exit 1
  }

  host_toolchain_publish_version_directory \
    "$temporary_node_dir" "$node_version_dir" Node.js
  rmdir "$temporary_node_root"
  temporary_node_root=
fi

# Semantic checks are intentionally last: all candidate executables are now
# byte-for-byte members of the attested Node and Yarn trees.
local_yarn="$node_version_dir/node_modules/.bin/yarn"
[[ "$(env -i PATH=/usr/bin:/bin \
  "$node_version_dir/bin/node" --version)" == "v$NODE_VERSION" ]] || {
  printf 'error: installed Node.js version mismatch\n' >&2
  exit 1
}
[[ "$(env -i PATH="$node_version_dir/bin:/usr/bin:/bin" \
  "$local_yarn" --version)" == "$YARN_VERSION" ]] || {
  printf 'error: installed Yarn version mismatch\n' >&2
  exit 1
}
host_toolchain_replace_symlink_atomic "$node_archive_root" "$node_link" Node.js
export PATH="$node_link/node_modules/.bin:$node_link/bin:$PATH"

# Pin Google's current Platform-Tools rather than the older Debian builds. The
# SHA-1 is published in Google's SDK repository metadata; SHA-256 is recorded
# as an additional integrity check.
platform_tools_archive="$toolchain_download_dir/$PLATFORM_TOOLS_FILENAME"
platform_tools_version_dir="$project_root/work/toolchains/platform-tools-$PLATFORM_TOOLS_VERSION"
platform_tools_dir="$platform_tools_version_dir/platform-tools"
platform_tools_link="$project_root/work/toolchains/platform-tools"
host_toolchain_reconcile_version_directory \
  "$platform_tools_version_dir" Platform-Tools
if [[ -e "$platform_tools_archive" || -L "$platform_tools_archive" ]]; then
  [[ -f "$platform_tools_archive" && ! -L "$platform_tools_archive" ]] || {
    printf 'error: Platform-Tools archive is not a regular file: %s\n' \
      "$platform_tools_archive" >&2
    exit 1
  }
  printf '%s  %s\n' "$PLATFORM_TOOLS_SHA256" "$platform_tools_archive" | \
    sha256sum --check
  printf '%s  %s\n' "$PLATFORM_TOOLS_SHA1" "$platform_tools_archive" | \
    sha1sum --check
else
  [[ ! -e "$platform_tools_archive.part" && \
     ! -L "$platform_tools_archive.part" ]] || {
    printf 'error: unsafe pre-existing partial download: %s\n' \
      "$platform_tools_archive.part" >&2
    exit 1
  }
  curl --fail --location --retry 5 --retry-all-errors \
    --output "$platform_tools_archive.part" "$PLATFORM_TOOLS_URL"
  printf '%s  %s\n' "$PLATFORM_TOOLS_SHA256" "$platform_tools_archive.part" | \
    sha256sum --check
  printf '%s  %s\n' "$PLATFORM_TOOLS_SHA1" "$platform_tools_archive.part" | \
    sha1sum --check
  [[ ! -e "$platform_tools_archive" && ! -L "$platform_tools_archive" ]] || {
    printf 'error: Platform-Tools archive appeared concurrently: %s\n' \
      "$platform_tools_archive" >&2
    exit 1
  }
  mv -- "$platform_tools_archive.part" "$platform_tools_archive"
fi
platform_tools_valid=false
if [[ -e "$platform_tools_version_dir" || -L "$platform_tools_version_dir" ]]; then
  [[ -d "$platform_tools_version_dir" && \
     ! -L "$platform_tools_version_dir" ]] || {
    printf 'error: Platform-Tools version path is not a real directory: %s\n' \
      "$platform_tools_version_dir" >&2
    exit 1
  }
fi
if host_toolchain_verify_zip_tree \
      "$platform_tools_archive" platform-tools "$PLATFORM_TOOLS_SHA256" \
      "$platform_tools_dir" "$project_root/work/toolchains" \
      >/dev/null 2>&1 && \
   host_toolchain_verify_regular_sha256 \
      "$platform_tools_dir/adb" "$PLATFORM_TOOLS_ADB_SHA256" adb \
      >/dev/null 2>&1 && \
   host_toolchain_verify_regular_sha256 \
      "$platform_tools_dir/fastboot" "$PLATFORM_TOOLS_FASTBOOT_SHA256" fastboot \
      >/dev/null 2>&1 && \
   /usr/bin/env -i PATH=/usr/bin:/bin "$platform_tools_dir/adb" version | \
      /usr/bin/grep -Fq "Version $PLATFORM_TOOLS_VERSION-" && \
   /usr/bin/env -i PATH=/usr/bin:/bin \
      "$platform_tools_dir/fastboot" --version | \
      /usr/bin/grep -Fq "fastboot version $PLATFORM_TOOLS_VERSION-"; then
  platform_tools_valid=true
fi
if [[ "$platform_tools_valid" != true ]]; then
  temporary_platform_root=$(mktemp -d "$project_root/work/toolchains/.platform-tools.XXXXXX")
  host_toolchain_safe_extract_zip \
    "$platform_tools_archive" platform-tools "$PLATFORM_TOOLS_SHA256" \
    "$temporary_platform_root"
  temporary_platform_dir="$temporary_platform_root/platform-tools"
  host_toolchain_verify_regular_sha256 \
    "$temporary_platform_dir/adb" "$PLATFORM_TOOLS_ADB_SHA256" \
    "extracted adb"
  host_toolchain_verify_regular_sha256 \
    "$temporary_platform_dir/fastboot" "$PLATFORM_TOOLS_FASTBOOT_SHA256" \
    "extracted fastboot"
  host_toolchain_verify_zip_tree \
    "$platform_tools_archive" platform-tools "$PLATFORM_TOOLS_SHA256" \
    "$temporary_platform_dir" "$project_root/work/toolchains"
  /usr/bin/env -i PATH=/usr/bin:/bin "$temporary_platform_dir/adb" version | \
    /usr/bin/grep -Fq "Version $PLATFORM_TOOLS_VERSION-" || {
      printf 'error: extracted adb version mismatch\n' >&2
      exit 1
    }
  /usr/bin/env -i PATH=/usr/bin:/bin \
    "$temporary_platform_dir/fastboot" --version | \
    /usr/bin/grep -Fq "fastboot version $PLATFORM_TOOLS_VERSION-" || {
      printf 'error: extracted fastboot version mismatch\n' >&2
      exit 1
    }
  temporary_platform_version_dir="$temporary_platform_root/version"
  mkdir "$temporary_platform_version_dir"
  mv -- "$temporary_platform_dir" \
    "$temporary_platform_version_dir/platform-tools"
  host_toolchain_publish_version_directory \
    "$temporary_platform_version_dir" "$platform_tools_version_dir" \
    Platform-Tools
  rmdir "$temporary_platform_root"
  temporary_platform_root=
fi
host_toolchain_replace_symlink_atomic \
  "$platform_tools_dir" "$platform_tools_link" Platform-Tools
export PATH="$platform_tools_link:$PATH"

printf 'node: %s\n' "$(node --version)"
printf 'yarn: %s\n' "$(yarn --version)"
printf 'repo: %s\n' "$(repo version | sed -n '1p')"
printf 'fastboot: %s\n' "$(fastboot --version | sed -n '1p')"
