#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"

"$script_dir/check-host.sh"

source_dir_input=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
[[ ! -L "$source_dir_input" ]] || \
  die "AOSP source directory must not be a symbolic link: $source_dir_input"
source_dir=$source_dir_input
source_dir=$(realpath -m -- "$source_dir")
assert_inside_work "$source_dir"
# android.googlesource.com rate-limits highly parallel partial clones. A modest
# default is faster in practice because it avoids HTTP 429 retry storms.
sync_jobs=${SYNC_JOBS:-4}
[[ "$sync_jobs" =~ ^[1-9][0-9]*$ ]] || \
  die "SYNC_JOBS must be a positive integer"
(( sync_jobs <= 64 )) || die "SYNC_JOBS must not exceed 64"

mkdir -p "$source_dir"
[[ -d "$source_dir" && ! -L "$source_dir" ]] || \
  die "AOSP source path is not a real directory: $source_dir"
cd "$source_dir"

repo init \
  --partial-clone \
  --clone-filter=blob:limit=10M \
  --no-clone-bundle \
  --repo-rev="$REPO_REVISION" \
  -u https://android.googlesource.com/platform/manifest \
  -b "$AOSP_REVISION"

repo_program="$source_dir/.repo/repo/repo"
[[ -f "$repo_program" && ! -L "$repo_program" && -x "$repo_program" ]] || \
  die "pinned Repo implementation is missing or unsafe: $repo_program"
actual_repo_revision=$(git -C "$source_dir/.repo/repo" \
  rev-parse --verify 'HEAD^{commit}')
[[ "$actual_repo_revision" == "$REPO_REVISION" ]] || \
  die "Repo implementation is $actual_repo_revision, expected $REPO_REVISION"

mkdir -p .repo/local_manifests
[[ -d .repo/local_manifests && ! -L .repo/local_manifests ]] || \
  die ".repo/local_manifests is not a real directory"
while IFS= read -r existing_manifest; do
  [[ "$existing_manifest" == cubs.xml ]] || {
    printf 'error: unexpected local manifest: .repo/local_manifests/%s\n' \
      "$existing_manifest" >&2
    printf 'remove or review it before syncing this locked source tree\n' >&2
    exit 1
  }
done < <(find .repo/local_manifests -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
[[ ! -L .repo/local_manifests/cubs.xml ]] || \
  die "cubs local manifest must not be a symbolic link"
install -m 0644 "$project_root/manifests/cubs.xml" .repo/local_manifests/cubs.xml

"$repo_program" sync \
  -c \
  --no-clone-bundle \
  --optimized-fetch \
  --prune \
  --retry-fetches=5 \
  -j"$sync_jobs"

temporary_manifest=$(mktemp "$project_root/work/.sync-manifest.XXXXXX.xml")
trap 'rm -f -- "$temporary_manifest"' EXIT
"$repo_program" manifest -r -o "$temporary_manifest"
xmllint --noout "$temporary_manifest"

resolved_manifest="$project_root/manifests/resolved.xml"
[[ ! -L "$resolved_manifest" ]] || \
  die "resolved source manifest must not be a symbolic link"
if [[ -f "$resolved_manifest" ]] && cmp -s "$resolved_manifest" "$temporary_manifest"; then
  printf 'resolved source lock matches the synced checkout\n'
elif [[ "${CUBS_UPDATE_SOURCE_LOCK:-}" == 1 ]]; then
  install -m 0644 "$temporary_manifest" "$resolved_manifest"
  printf 'updated source lock: %s\n' "$resolved_manifest"
else
  printf 'error: synced revisions differ from %s\n' "$resolved_manifest" >&2
  printf 'review the revision delta, then refresh intentionally with '\''CUBS_UPDATE_SOURCE_LOCK=1 %s'\''\n' \
    "$0" >&2
  exit 1
fi
"$project_root/scripts/check-source.sh"
