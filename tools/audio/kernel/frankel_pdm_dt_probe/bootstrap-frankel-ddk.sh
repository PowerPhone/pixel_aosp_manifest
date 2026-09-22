#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
manifest_root=$(cd -- "$script_dir/../../../.." && pwd)
artifacts=${FRANKEL_GKI_ARTIFACTS:-"$manifest_root/work/upstream/frankel-gki-15739706"}
ddk_workspace=${FRANKEL_DDK_WORKSPACE:-"$artifacts/ddk-workspace"}
build_id=15739706
build_target=kernel_aarch64
base_url="https://ci.android.com/builds/submitted/$build_id/$build_target/latest/raw"
url_format='https://ci.android.com/builds/submitted/{build_id}/{build_target}/latest/raw/{filename}'

mkdir -p "$artifacts" "$ddk_workspace"

if [[ ! -f "$artifacts/init_ddk.zip" ]]; then
  curl -L --fail --show-error \
    --output "$artifacts/init_ddk.zip" "$base_url/init_ddk.zip"
fi

if [[ ! -d "$ddk_workspace/.repo" ]]; then
  (
    cd "$ddk_workspace"
    repo init \
      -u https://android.googlesource.com/kernel/manifest \
      -b common-android15-6.6-sp \
      -m default.xml \
      --depth=1 \
      --partial-clone \
      --no-clone-bundle \
      --no-tags
  )
fi

# Generate kleaf.xml and download the complete prebuilt set, but do not sync
# against the kernel manifest's duplicate DDK project paths.
python3 "$artifacts/init_ddk.zip" \
  --build_id "$build_id" \
  --build_target "$build_target" \
  --url_fmt "$url_format" \
  --ddk_workspace "$ddk_workspace" \
  --kleaf_repo "$ddk_workspace/kleaf" \
  --prebuilts_dir "$artifacts" \
  --nosync

install -m 0644 "$script_dir/frankel-ddk-only.xml" \
  "$ddk_workspace/.repo/manifests/frankel-ddk-only.xml"
(
  cd "$ddk_workspace"
  repo init -m frankel-ddk-only.xml --no-clone-bundle --no-tags
  repo sync -c
)

# Re-run after sync so MODULE.bazel contains exact local-path overrides.
python3 "$artifacts/init_ddk.zip" \
  --ddk_workspace "$ddk_workspace" \
  --kleaf_repo "$ddk_workspace/kleaf" \
  --prebuilts_dir "$artifacts"

printf 'Frankel DDK workspace ready: %s\n' "$ddk_workspace"
