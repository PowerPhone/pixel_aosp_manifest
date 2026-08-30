#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
allow_patches=false
if [[ "${1:-}" == --allow-patches ]]; then
  allow_patches=true
elif [[ $# -ne 0 ]]; then
  die "usage: $0 [--allow-patches]"
fi

assert_inside_work "$source_dir"
require_file "$source_dir/.repo/manifest.xml"
require_file "$source_dir/.repo/repo/repo"
require_file "$project_root/manifests/resolved.xml"
require_command cmp xmllint
repo_program="$source_dir/.repo/repo/repo"
[[ -f "$repo_program" && ! -L "$repo_program" && -x "$repo_program" ]] || \
  die "pinned Repo implementation is missing or unsafe: $repo_program"

actual_repo_revision=$(git -C "$source_dir/.repo/repo" \
  rev-parse --verify 'HEAD^{commit}')
[[ "$actual_repo_revision" == "$REPO_REVISION" ]] || \
  die "Repo implementation is $actual_repo_revision, expected $REPO_REVISION"

temporary_manifest=$(mktemp "$project_root/work/.resolved-manifest.XXXXXX.xml")
trap 'rm -f -- "$temporary_manifest"' EXIT
(
  cd "$source_dir"
  "$repo_program" manifest -r -o "$temporary_manifest"
)
xmllint --noout "$temporary_manifest"
cmp -s "$project_root/manifests/resolved.xml" "$temporary_manifest" || \
  die "source revisions differ from manifests/resolved.xml"

mapfile -t dirty_projects < <(
  cd "$source_dir"
  # Variables in this command are intentionally expanded by repo forall's shell.
  # shellcheck disable=SC2016
  "$repo_program" forall -c '
    if ! git diff --quiet --ignore-submodules -- ||
       ! git diff --cached --quiet --ignore-submodules -- ||
       test -n "$(git ls-files --others --exclude-standard | head -n 1)"; then
      printf "%s\n" "$REPO_PATH"
    fi
  ' | sort -u
)

if [[ "$allow_patches" == true ]]; then
  allowed_dirty=(
    build/make
    build/soong
    frameworks/base
    frameworks/native
    packages/apps/CarrierConfig2
    system/core
    system/sepolicy
    tools/apksig
    vendor/adevtool
  )
  for dirty_project in "${dirty_projects[@]}"; do
    allowed=false
    for allowed_project in "${allowed_dirty[@]}"; do
      if [[ "$dirty_project" == "$allowed_project" ]]; then
        allowed=true
        break
      fi
    done
    [[ "$allowed" == true ]] || \
      die "unexpected source modification: $dirty_project"
  done
  # The allow-list limits which repositories may differ; this second check
  # proves that every tracked byte in those repositories matches the reviewed
  # ordered patch stack rather than accepting arbitrary local changes.
  "$script_dir/apply-source-patches.sh" --check-only
else
  (( ${#dirty_projects[@]} == 0 )) || \
    die "source is not pristine: ${dirty_projects[*]}"
fi

note "source manifest and worktrees verified"
