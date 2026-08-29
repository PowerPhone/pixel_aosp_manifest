#!/usr/bin/env bash

# Shared helpers for project scripts. This file is sourced; callers enable their
# preferred shell options before loading it.

common_source=${BASH_SOURCE[0]}
case "$common_source" in
  */*) common_directory=${common_source%/*} ;;
  *) common_directory=. ;;
esac
project_root=$(builtin cd -- "$common_directory/../.." && builtin pwd -P)
unset common_source common_directory
# shellcheck source=../../config/release.env
source "$project_root/config/release.env"

workspace_node="$project_root/work/toolchains/node"
workspace_platform_tools="$project_root/work/toolchains/platform-tools"
activate_workspace_toolchains() {
  if [[ -x "$workspace_node/bin/node" ]]; then
    export PATH="$workspace_node/node_modules/.bin:$workspace_node/bin:$PATH"
  fi
  if [[ -x "$workspace_platform_tools/fastboot" ]]; then
    export PATH="$workspace_platform_tools:$PATH"
  fi
}

if [[ ${PIXEL_AOSP_DEFER_TOOLCHAIN_PATH:-false} != true ]]; then
  activate_workspace_toolchains
fi

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

require_command() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || \
      die "required command not found: $command_name"
  done
}

require_file() {
  [[ -f "$1" ]] || die "required file not found: $1"
}

# Remove caller-provided AOSP escape hatches before product configuration.
# Device makefiles may still declare a narrowly scoped compatibility setting;
# those declarations remain visible to the output-policy attestation.
strict_aosp_build_environment() {
  unset \
    ALLOW_MISSING_DEPENDENCIES \
    ALLOW_LOCAL_TIDY_TRUE \
    ALLOW_UNKNOWN_WARNING_OPTION \
    SOONG_ALLOW_MISSING_DEPENDENCIES \
    SELINUX_IGNORE_NEVERALLOWS \
    BUILD_BROKEN_PLUGIN_VALIDATION \
    BUILD_BROKEN_CLANG_PROPERTY \
    BUILD_BROKEN_CLANG_ASFLAGS \
    BUILD_BROKEN_CLANG_CFLAGS \
    BUILD_BROKEN_DEPFILE \
    BUILD_BROKEN_DUP_RULES \
    BUILD_BROKEN_DUP_SYSPROP \
    BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES \
    BUILD_BROKEN_ENFORCE_SYSPROP_OWNER \
    BUILD_BROKEN_INPUT_DIR_MODULES \
    BUILD_BROKEN_MISSING_REQUIRED_MODULES \
    BUILD_BROKEN_OUTSIDE_INCLUDE_DIRS \
    BUILD_BROKEN_PREBUILT_ELF_FILES \
    BUILD_BROKEN_TREBLE_SYSPROP_NEVERALLOW \
    BUILD_BROKEN_USES_NETWORK \
    BUILD_BROKEN_VENDOR_PROPERTY_NAMESPACE \
    BUILD_BROKEN_VINTF_PRODUCT_COPY_FILES \
    BUILD_BROKEN_INCORRECT_PARTITION_IMAGES \
    BUILD_BROKEN_DONT_CHECK_SYSTEMSDK \
    BUILD_BROKEN_NINJA_USES_ENV_VARS \
    BUILD_BROKEN_SRC_DIR_IS_WRITABLE \
    BUILD_BROKEN_SRC_DIR_RW_ALLOWLIST \
    BUILD_BROKEN_MISSING_OUTPUTS \
    BUILD_BROKEN_USES_BUILD_COPY_HEADERS \
    BUILD_BROKEN_USES_BUILD_EXECUTABLE \
    BUILD_BROKEN_USES_BUILD_FUZZ_TEST \
    BUILD_BROKEN_USES_BUILD_HEADER_LIBRARY \
    BUILD_BROKEN_USES_BUILD_HOST_EXECUTABLE \
    BUILD_BROKEN_USES_BUILD_HOST_JAVA_LIBRARY \
    BUILD_BROKEN_USES_BUILD_HOST_PREBUILT \
    BUILD_BROKEN_USES_BUILD_HOST_SHARED_LIBRARY \
    BUILD_BROKEN_USES_BUILD_HOST_STATIC_LIBRARY \
    BUILD_BROKEN_USES_BUILD_JAVA_LIBRARY \
    BUILD_BROKEN_USES_BUILD_MULTI_PREBUILT \
    BUILD_BROKEN_USES_BUILD_NATIVE_TEST \
    BUILD_BROKEN_USES_BUILD_NOTICE_FILE \
    BUILD_BROKEN_USES_BUILD_PACKAGE \
    BUILD_BROKEN_USES_BUILD_PHONY_PACKAGE \
    BUILD_BROKEN_USES_BUILD_PREBUILT \
    BUILD_BROKEN_USES_BUILD_RRO_PACKAGE \
    BUILD_BROKEN_USES_BUILD_SHARED_LIBRARY \
    BUILD_BROKEN_USES_BUILD_STATIC_JAVA_LIBRARY \
    BUILD_BROKEN_USES_BUILD_STATIC_LIBRARY \
    AUTO_PATTERN_INITIALIZE \
    AUTO_UNINITIALIZE \
    AUTO_ZERO_INITIALIZE \
    BUILD_DATETIME_FILE \
    CC_WRAPPER \
    CLANG_ANALYZER_CHECKS \
    CLANG_COVERAGE \
    CLANG_COVERAGE_CONTINUOUS_MODE \
    DISABLE_HOST_PIE \
    DISABLE_LLVM_DEVICE_BUILDS \
    DISABLE_LTO \
    EMMA_API_MAPPER \
    EMMA_INSTRUMENT \
    EMMA_INSTRUMENT_FRAMEWORK \
    EMMA_INSTRUMENT_STATIC \
    ENABLE_HIDDENAPI_FLAGS \
    FORCE_BUILD_LLVM_COMPONENTS \
    FORCE_BUILD_LLVM_DEBUG \
    FORCE_BUILD_LLVM_DISABLE_NDEBUG \
    FORCE_BUILD_SANITIZER_SHARED_OBJECTS \
    GCOV_COVERAGE \
    JAVA_COVERAGE_EXCLUDE_PATHS \
    JAVA_COVERAGE_PATHS \
    NATIVE_COVERAGE \
    NATIVE_COVERAGE_EXCLUDE_PATHS \
    NATIVE_COVERAGE_PATHS \
    SANITIZE_HOST \
    SANITIZE_TARGET \
    SANITIZE_TARGET_ARCH \
    SANITIZE_TARGET_DIAG \
    SANITIZE_TARGET_SYSTEM \
    SKIP_ABI_CHECKS \
    TARGET_BUILD_APPS \
    TARGET_BUILD_UNBUNDLED \
    TARGET_BUILD_UNBUNDLED_IMAGE \
    THINLTO_EMIT_INDEXES_AND_IMPORTS \
    THINLTO_USE_MLGO \
    UNSAFE_DISABLE_HIDDENAPI_FLAGS \
    USE_RBE \
    USE_REWRAPPER \
    USE_THINLTO_CACHE \
    WITHOUT_CHECK_API \
    WITH_DEXPREOPT \
    WITH_DEXPREOPT_ART_BOOT_IMG_ONLY \
    WITH_DEXPREOPT_BOOT_IMG_AND_SYSTEM_SERVER_ONLY \
    WITH_DEXPREOPT_DEBUG_INFO \
    WITH_TIDY \
    WITH_TIDY_CHECKS \
    WITH_TIDY_FLAGS
  export ALLOW_NINJA_ENV=false
}

verify_sha256() {
  local expected=$1
  local path=$2
  require_file "$path"
  printf '%s  %s\n' "$expected" "$path" | sha256sum --check --status || \
    die "SHA-256 mismatch: $path"
}

assert_inside_project() {
  local path
  path=$(realpath -m -- "$1")
  case "$path" in
    "$project_root"|"$project_root"/*) ;;
    *) die "path escapes project workspace: $path" ;;
  esac
}

assert_inside_work() {
  local path work_root
  [[ ! -L "$project_root/work" ]] || \
    die "ignored work root must not be a symbolic link: $project_root/work"
  path=$(realpath -m -- "$1")
  work_root=$(realpath -m -- "$project_root/work")
  [[ "$work_root" == "$project_root/work" ]] || \
    die "ignored work root resolves outside its canonical project path"
  case "$path" in
    "$work_root"/*) ;;
    *) die "path must remain in the ignored work directory: $path" ;;
  esac
}
