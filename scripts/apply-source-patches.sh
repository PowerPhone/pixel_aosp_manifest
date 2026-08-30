#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
assert_inside_work "$source_dir"
require_file "$source_dir/build/envsetup.sh"
base_revision_lock="$project_root/patches/BASE_REVISIONS"
require_file "$base_revision_lock"

check_only=false
if [[ "${1:-}" == --check-only ]]; then
  check_only=true
elif [[ $# -ne 0 ]]; then
  die "usage: $0 [--check-only]"
fi

(
  cd "$project_root/patches"
  sha256sum --check SHA256SUMS
)

temporary_index_dir=$(mktemp -d "$project_root/work/.patch-index.XXXXXX")
temporary_index="$temporary_index_dir/index"
cleanup() {
  rm -f -- "$temporary_index" "$temporary_index.lock"
  rmdir -- "$temporary_index_dir" 2>/dev/null || true
}
trap cleanup EXIT

apply_stack() {
  local repository=$1
  shift
  local patches=("$@")
  local actual_base expected_base patch project_path

  [[ -d "$repository/.git" || -f "$repository/.git" ]] || \
    die "source repository not found: $repository"
  project_path=${repository#"$source_dir"/}
  mapfile -t expected_base_matches < <(
    awk -v path="$project_path" '$1 == path {print $2}' "$base_revision_lock"
  )
  (( ${#expected_base_matches[@]} == 1 )) || \
    die "expected exactly one patch-base lock entry for $project_path"
  expected_base=${expected_base_matches[0]}
  [[ "$expected_base" =~ ^[0-9a-f]{40}$ ]] || \
    die "invalid patch-base revision for $project_path"
  actual_base=$(git -C "$repository" rev-parse --verify 'HEAD^{commit}')
  [[ "$actual_base" == "$expected_base" ]] || \
    die "$project_path is at $actual_base, expected patch base $expected_base"
  (( ${#patches[@]} > 0 )) || die "empty patch stack for $repository"
  for patch in "${patches[@]}"; do
    require_file "$patch"
  done

  stack_matches_worktree() {
    local expected_added=()
    local actual_untracked=()
    local index

    GIT_INDEX_FILE="$temporary_index" \
      git -C "$repository" diff --quiet --ignore-submodules -- || return 1
    mapfile -d '' -t expected_added < <(
      GIT_INDEX_FILE="$temporary_index" git -C "$repository" \
        diff --cached --name-only --diff-filter=A -z HEAD --
    )
    mapfile -d '' -t actual_untracked < <(
      git -C "$repository" ls-files --others --exclude-standard -z
    )
    (( ${#expected_added[@]} == ${#actual_untracked[@]} )) || return 1
    for index in "${!expected_added[@]}"; do
      [[ "${expected_added[$index]}" == "${actual_untracked[$index]}" ]] || return 1
    done
  }

  # Build the exact expected post-patch index from the pinned HEAD. Checking a
  # whole ordered stack is necessary because later patches can edit lines that
  # earlier patches introduced, making per-patch reverse checks ambiguous.
  rm -f -- "$temporary_index" "$temporary_index.lock"
  GIT_INDEX_FILE="$temporary_index" git -C "$repository" read-tree HEAD
  for patch in "${patches[@]}"; do
    GIT_INDEX_FILE="$temporary_index" \
      git -C "$repository" apply --cached "$patch" || \
      die "patch does not apply to pinned HEAD: $patch"
  done

  git -C "$repository" diff --cached --quiet --ignore-submodules -- || \
    die "source index is modified: $repository"

  if stack_matches_worktree; then
    note "verified patch stack: ${repository#"$source_dir/"} (${#patches[@]} patch(es))"
    return
  fi

  [[ "$check_only" == false ]] || \
    die "source does not match expected patch stack: $repository"

  git -C "$repository" diff --quiet --ignore-submodules -- || \
    die "source differs from both pinned HEAD and expected patch stack: $repository"
  for patch in "${patches[@]}"; do
    git -C "$repository" apply --check "$patch" || \
      die "patch does not apply cleanly: $patch"
    git -C "$repository" apply "$patch"
  done

  stack_matches_worktree || \
    die "applied source does not match expected patch stack: $repository"
  note "applied: ${repository#"$source_dir/"} (${#patches[@]} patch(es))"
}

apply_stack \
  "$source_dir/build/make" \
  "$project_root/patches/build/0001-per-product-build-id.patch" \
  "$project_root/patches/build/0002-align-soong-gsi-avb-policy.patch" \
  "$project_root/patches/build/0003-render-make-build-dates-in-utc.patch" \
  "$project_root/patches/build/0004-propagate-deterministic-dtbo-salt.patch" \
  "$project_root/patches/build/0005-track-dtbo-avb-identity-inputs.patch" \
  "$project_root/patches/build/0006-merge-vendor-ramdisk-staging.patch" \
  "$project_root/patches/build/0007-propagate-make-boot-salts.patch" \
  "$project_root/patches/build/0008-propagate-pvmfw-signing-metadata.patch"

apply_stack \
  "$source_dir/build/soong" \
  "$project_root/patches/build-soong/0001-render-build-props-in-utc.patch" \
  "$project_root/patches/build-soong/0002-disable-dexpreopt-check-for-prebuilt-standalone-jars.patch" \
  "$project_root/patches/build-soong/0003-propagate-deterministic-dtbo-salt.patch" \
  "$project_root/patches/build-soong/0004-propagate-deterministic-boot-salts.patch" \
  "$project_root/patches/build-soong/0005-select-adevtool-fbpack-unpacker.patch" \
  "$project_root/patches/build-soong/0006-merge-cpio-roots-before-archiving.patch"

# Framework resource-tooling and Pixel compatibility patches form one ordered
# stack. List every file explicitly so an unreviewed glob match can never enter
# a release build merely by appearing in the patches directory.
framework_patches=(
  "$project_root/patches/frameworks-base/0001-aapt2-stringified-configuration.patch"
  "$project_root/patches/frameworks-base/0002-aapt2-proto-adevtool-conversion.patch"
  "$project_root/patches/frameworks-base/0003-aapt2-brief-package-info.patch"
  "$project_root/patches/frameworks-base/0004-aapt2-proto-java-library.patch"
  "$project_root/patches/frameworks-base/0005-aapt2-brief-package-library.patch"
  "$project_root/patches/frameworks-base/0006-pixel-euicc-gservices-flags-provider.patch"
)
apply_stack "$source_dir/frameworks/base" "${framework_patches[@]}"

apply_stack \
  "$source_dir/frameworks/native" \
  "$project_root/patches/frameworks-native/0001-define-missing-feature-prebuilts.patch"

apply_stack \
  "$source_dir/system/core" \
  "$project_root/patches/system-core/0001-preserve-devnode-description-modes.patch"

sepolicy_patches=(
  "$project_root/patches/system-sepolicy/0001-support-extending-sepolicy-cils.patch"
)
apply_stack "$source_dir/system/sepolicy" "${sepolicy_patches[@]}"

apply_stack \
  "$source_dir/tools/apksig" \
  "$project_root/patches/apksig/0001-add-print-certs-command-for-adevtool.patch"

apply_stack \
  "$source_dir/vendor/adevtool" \
  "$project_root/patches/adevtool/0001-pristine-aosp-compatibility.patch" \
  "$project_root/patches/adevtool/0002-malibu-avb-chain-topology.patch" \
  "$project_root/patches/adevtool/0003-strict-aosp17-sepolicy.patch" \
  "$project_root/patches/adevtool/0004-malibu-firmware-avb-descriptors.patch" \
  "$project_root/patches/adevtool/0005-laguna-pristine-aosp-compatibility.patch"
apply_stack \
  "$source_dir/packages/apps/CarrierConfig2" \
  "$project_root/patches/carrierconfig2/0001-omit-grapheneos-test-apis.patch"
