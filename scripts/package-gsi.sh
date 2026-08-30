#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
# shellcheck source=../config/recovery.env disable=SC1091
source "$project_root/config/recovery.env"

require_pixel_target cubs "the recovery-anchored GSI packager"

require_command awk find grep install mktemp realpath rm sed sha256sum sort unzip

artifacts_root=$(realpath -m -- "$project_root/artifacts")
gsi_dir=${GSI_ARTIFACT_DIR:-"$artifacts_root/gsi"}
gsi_dir=$(realpath -m -- "$gsi_dir")
case "$gsi_dir" in
  "$artifacts_root"/*) ;;
  *) die "GSI artifact directory must remain below $artifacts_root" ;;
esac
source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
out_dir=${AOSP_OUT_DIR:-"$source_dir/out_pixel/gsi"}
out_dir=$(realpath -m -- "$out_dir")
assert_inside_work "$source_dir"
assert_inside_work "$out_dir"
AOSP_SOURCE_DIR="$source_dir" AOSP_OUT_DIR="$out_dir" \
GSI_ARTIFACT_DIR="$gsi_dir" \
  "$script_dir/attest-build-output.sh" verify gsi
build_attestation="$out_dir/build-completion-gsi.attestation"
require_file "$build_attestation"
[[ ! -L "$build_attestation" ]] || die "unsafe GSI build attestation"
build_attestation_sha256=$(sha256sum "$build_attestation" | awk '{print $1}')
[[ -f "$script_dir/flash-a.sh" && ! -L "$script_dir/flash-a.sh" && \
   -x "$script_dir/flash-a.sh" ]] || \
  die "reviewed standalone flash runner is missing or unsafe"
runner_policy_sha256=$(
  sed -n 's/^expected_recovery_policy_sha256=//p' \
    "$script_dir/flash-a.sh"
)
[[ $(grep -c '^expected_recovery_policy_sha256=' \
      "$script_dir/flash-a.sh") -eq 1 && \
   "$runner_policy_sha256" == "$CUBS_RECOVERY_POLICY_SHA256" ]] || \
  die "standalone flash runner does not match the current recovery policy"
image_files=(system.img pvmfw.img vbmeta.img)
for image_name in "${image_files[@]}"; do
  require_file "$gsi_dir/$image_name"
  [[ -s "$gsi_dir/$image_name" ]] || die "empty GSI image: $image_name"
done

avbtool="$out_dir/host/linux-x86/bin/avbtool"
[[ -x "$avbtool" ]] || die "built avbtool not found: $avbtool"
"$avbtool" info_image --image "$gsi_dir/vbmeta.img" >/dev/null || \
  die "GSI vbmeta image failed AVB validation"

# A flash bundle records the exact stock firmware requirements independently
# of the generated system. It includes the built pvmfw image but never copies
# a radio, modem, or bootloader image.
factory_image="$project_root/downloads/$FACTORY_IMAGE_FILENAME"
verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"
"$script_dir/extract-stock.sh"
stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
stock_images="$stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
require_file "$stock_images"

staging_parent="$project_root/work/packaging"
mkdir -p "$staging_parent"
staging_dir=$(mktemp -d "$staging_parent/.gsi-bundle.XXXXXX")
cleanup() {
  if [[ -n "${staging_dir:-}" && -d "$staging_dir" && \
        "$staging_dir" == "$staging_parent"/.gsi-bundle.* ]]; then
    rm -rf -- "$staging_dir"
  fi
}
trap cleanup EXIT

for image_name in "${image_files[@]}"; do
  install -m 0644 "$gsi_dir/$image_name" "$staging_dir/$image_name"
done
install -m 0644 "$build_attestation" "$staging_dir/BUILD_ATTESTATION.txt"
stock_android_info=$(unzip -p "$stock_images" android-info.txt) || \
  die "stock image package has no android-info.txt"
stock_board_requirement=$(sed -n 's/^require board=//p' <<<"$stock_android_info")
[[ "|$stock_board_requirement|" == *"|$DEVICE_CODENAME|"* ]] || \
  die "stock package board requirement does not include $DEVICE_CODENAME"
stock_bootloader_requirement=$(
  sed -n 's/^require version-bootloader=//p' <<<"$stock_android_info"
)
stock_baseband_requirement=$(
  sed -n 's/^require version-baseband=//p' <<<"$stock_android_info"
)
[[ $(grep -c '^require version-bootloader=' <<<"$stock_android_info") -eq 1 ]] || \
  die "stock package must have exactly one bootloader requirement"
[[ $(grep -c '^require version-baseband=' <<<"$stock_android_info") -eq 1 ]] || \
  die "stock package must have exactly one baseband requirement"
{
  printf 'require product=%s\n' "$DEVICE_CODENAME"
  printf 'require version-bootloader=%s\n' "$stock_bootloader_requirement"
  printf 'require version-baseband=%s\n' "$stock_baseband_requirement"
} > "$staging_dir/firmware-requirements.txt"

printf 'gsi\n' > "$staging_dir/bundle-kind"
gsi_system_sha256=$(sha256sum "$gsi_dir/system.img" | awk '{print $1}')
{
  printf 'bundle_kind=gsi\n'
  printf 'device=%s\n' "$DEVICE_CODENAME"
  printf 'aosp_revision=%s\n' "$AOSP_REVISION"
  printf 'source_aosp_build_id=%s\n' "$AOSP_BUILD_ID"
  printf 'output_build_id=%s\n' "$AOSP_BUILD_ID"
  printf 'framework_security_patch=%s\n' "$AOSP_SECURITY_PATCH"
  printf 'build_variant=userdebug\n'
  printf 'stock_vendor_build=%s\n' "$STOCK_BUILD_ID"
  printf 'platform_tools=%s\n' "$PLATFORM_TOOLS_VERSION"
  printf 'system_sha256=%s\n' "$gsi_system_sha256"
  printf 'build_attestation_sha256=%s\n' "$build_attestation_sha256"
  printf 'flash_scope=slot_a_partition_names_shared_super\n'
  printf 'recovery_anchor=slot_b_physical_fastbootd_lifeboat\n'
} > "$staging_dir/BUNDLE_INFO.txt"
install -m 0755 "$script_dir/flash-a.sh" "$staging_dir/flash-all.sh"

manifest_files=(
  bundle-kind
  BUNDLE_INFO.txt
  BUILD_ATTESTATION.txt
  firmware-requirements.txt
  flash-all.sh
  "${image_files[@]}"
)
(
  cd "$staging_dir"
  sha256sum "${manifest_files[@]}" > SHA256SUMS
  sha256sum --check --strict SHA256SUMS
)

[[ -f "$script_dir/validate-images.sh" && \
   ! -L "$script_dir/validate-images.sh" && \
   -x "$script_dir/validate-images.sh" ]] || \
  die "required static image validator is missing or not a safe executable"
AOSP_SOURCE_DIR="$source_dir" AOSP_OUT_DIR="$out_dir" \
GSI_ARTIFACT_DIR="$staging_dir" \
  "$script_dir/validate-images.sh" gsi

# Do not expose a refreshed checksum manifest until the already-validated
# staging bundle has been copied completely. An interrupted copy therefore
# cannot be mistaken for a valid release bundle.
mkdir -p "$gsi_dir"
allowed_existing=(SHA256SUMS "${manifest_files[@]}")
mapfile -d '' -t existing_entries < <(
  find "$gsi_dir" -mindepth 1 -maxdepth 1 -printf '%f\0' | LC_ALL=C sort -z
)
for name in "${existing_entries[@]}"; do
  allowed=
  for allowed_name in "${allowed_existing[@]}"; do
    if [[ "$name" == "$allowed_name" ]]; then
      allowed=1
      break
    fi
  done
  [[ -n "$allowed" ]] || die \
    "refusing to replace GSI artifact directory containing unexpected entry: $name"
  [[ -f "$gsi_dir/$name" && ! -L "$gsi_dir/$name" ]] || die \
    "refusing to replace unsafe GSI artifact entry: $name"
done
rm -f -- "$gsi_dir/SHA256SUMS"
for name in bundle-kind BUNDLE_INFO.txt BUILD_ATTESTATION.txt \
  firmware-requirements.txt "${image_files[@]}"; do
  install -m 0644 "$staging_dir/$name" "$gsi_dir/$name"
done
install -m 0755 "$staging_dir/flash-all.sh" "$gsi_dir/flash-all.sh"
install -m 0644 "$staging_dir/SHA256SUMS" "$gsi_dir/SHA256SUMS"

if ! AOSP_SOURCE_DIR="$source_dir" AOSP_OUT_DIR="$out_dir" \
    GSI_ARTIFACT_DIR="$gsi_dir" \
    "$script_dir/validate-images.sh" gsi; then
  rm -f -- "$gsi_dir/SHA256SUMS"
  die "published GSI bundle failed revalidation; its checksum manifest was withdrawn"
fi

note "GSI slot-A flash bundle: $gsi_dir"
note "the bundle contains no radio/bootloader images and never targets a slot-B partition"
note "the runner journals selection of stock A, enters A fastbootd, and writes logical A before physical A"
note "logical slot-A writes invalidate B Android while preserving the physical-B fastbootd lifeboat"
