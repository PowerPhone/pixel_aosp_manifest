#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"

usage() {
  printf 'usage: %s create|verify\n' "$0" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
action=$1
case "$action" in
  create|verify) ;;
  *) usage ;;
esac

require_command cmp find git grep readlink realpath sha256sum sort stat

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
assert_inside_work "$source_dir"
"$script_dir/check-source.sh" --allow-patches

generated_dir="$source_dir/vendor/google_devices/$DEVICE_CODENAME"
adevtool_dir="$source_dir/vendor/adevtool"
vendor_state_dir="$source_dir/vendor/state"
vendor_state_spec="$vendor_state_dir/$DEVICE_CODENAME.json"
resolved_manifest="$project_root/manifests/resolved.xml"
patch_sha256_lock="$project_root/patches/SHA256SUMS"
release_env="$project_root/config/release.env"
target_release_env="$project_root/config/targets/$DEVICE_CODENAME/release.env"
adevtool_package_json="$adevtool_dir/package.json"
adevtool_yarn_lock="$adevtool_dir/yarn.lock"
adevtool_config_dir="$adevtool_dir/config"
vendor_spec="$adevtool_dir/vendor-specs/google_devices/$DEVICE_CODENAME.yml"
vendor_skels_dir="$adevtool_dir/vendor-skels/google_devices/$DEVICE_CODENAME"
gservices_flags_dir="$adevtool_dir/gservices-flags/google_devices/$DEVICE_CODENAME"
case "$DEVICE_CODENAME" in
  cubs)
    sanitizer="$script_dir/sanitize-generated-vendor.sh"
    target_sanitizer_library="$script_dir/lib/cubs-fstab.sh"
    target_sanitizer_library_path=scripts/lib/cubs-fstab.sh
    ;;
  frankel)
    sanitizer="$script_dir/sanitize-generated-vendor-frankel.sh"
    target_sanitizer_library="$sanitizer"
    target_sanitizer_library_path=scripts/sanitize-generated-vendor-frankel.sh
    ;;
  *) die "no generated-vendor attestation policy for $DEVICE_CODENAME" ;;
esac
attestation_dir="$project_root/work/attestations"
attestation="$attestation_dir/${DEVICE_CODENAME}-generated-vendor.attestation"

[[ -d "$generated_dir" && ! -L "$generated_dir" ]] || \
  die "generated vendor root is missing or is a symlink: $generated_dir"
[[ -d "$adevtool_dir/.git" || -f "$adevtool_dir/.git" ]] || \
  die "adevtool Git checkout not found: $adevtool_dir"
[[ -d "$vendor_state_dir/.git" || -f "$vendor_state_dir/.git" ]] || \
  die "vendor state Git checkout not found: $vendor_state_dir"
require_file "$vendor_state_spec"
require_file "$generated_dir/$DEVICE_CODENAME.mk"
require_file "$generated_dir/BoardConfig.mk"
[[ ! -L "$generated_dir/$DEVICE_CODENAME.mk" && \
   ! -L "$generated_dir/BoardConfig.mk" ]] || \
  die "generated product entry points must not be symlinks"
require_file "$resolved_manifest"
require_file "$patch_sha256_lock"
require_file "$release_env"
require_file "$target_release_env"
require_file "$adevtool_package_json"
require_file "$adevtool_yarn_lock"
require_file "$vendor_spec"
require_file "$sanitizer"
require_file "$target_sanitizer_library"
[[ ! -L "$target_sanitizer_library" ]] || \
  die "target sanitizer library must not be a symlink"
for input_directory in \
  "$adevtool_config_dir" \
  "$vendor_skels_dir" \
  "$gservices_flags_dir"; do
  [[ -d "$input_directory" && ! -L "$input_directory" ]] || \
    die "adevtool generation input is not a real directory: $input_directory"
done
for input_file in \
  "$vendor_state_spec" \
  "$resolved_manifest" \
  "$patch_sha256_lock" \
  "$release_env" \
  "$target_release_env" \
  "$adevtool_package_json" \
  "$adevtool_yarn_lock" \
  "$vendor_spec" \
  "$sanitizer" \
  "$target_sanitizer_library"; do
  [[ ! -L "$input_file" ]] || \
    die "provenance input must not be a symlink: $input_file"
done

generated_dir=$(realpath -e -- "$generated_dir")
case "$generated_dir" in
  "$source_dir"/*) ;;
  *) die "generated vendor root escapes the AOSP source tree: $generated_dir" ;;
esac

# Re-run the reviewed sanitizer's semantic postcondition in read-only mode for
# both attestation creation and verification. Its digest is recorded below.
"$sanitizer" --check

# These generated make variables disable policy checks globally. The
# sanitizer must remove them; recording strict mode here makes their absence a
# verified build input instead of an undocumented exception.
while IFS= read -r -d '' makefile; do
  if LC_ALL=C grep -Fq \
    -e 'SELINUX_IGNORE_NEVERALLOWS' \
    -e 'BUILD_BROKEN_DUP_RULES' "$makefile"; then
    die "generated vendor tree enables a prohibited build relaxation"
  fi
done < <(find "$generated_dir" -type f -name '*.mk' -print0)

actual_adevtool_revision=$(git -C "$adevtool_dir" rev-parse --verify 'HEAD^{commit}')
[[ "$actual_adevtool_revision" =~ ^[0-9a-f]{40}$ ]] || \
  die "invalid adevtool Git revision: $actual_adevtool_revision"
[[ "$actual_adevtool_revision" == "$ADEVTOOL_REVISION" ]] || \
  die "adevtool revision is $actual_adevtool_revision, expected $ADEVTOOL_REVISION"
actual_vendor_state_revision=$(
  git -C "$vendor_state_dir" rev-parse --verify 'HEAD^{commit}'
)
[[ "$actual_vendor_state_revision" =~ ^[0-9a-f]{40}$ ]] || \
  die "invalid vendor state Git revision: $actual_vendor_state_revision"
vendor_state_spec_sha256=$(sha256sum "$vendor_state_spec")
vendor_state_spec_sha256=${vendor_state_spec_sha256%% *}

resolved_manifest_sha256=$(sha256sum "$resolved_manifest")
resolved_manifest_sha256=${resolved_manifest_sha256%% *}
patch_sha256_lock_sha256=$(sha256sum "$patch_sha256_lock")
patch_sha256_lock_sha256=${patch_sha256_lock_sha256%% *}
release_env_sha256=$(sha256sum "$release_env")
release_env_sha256=${release_env_sha256%% *}
target_release_env_sha256=$(sha256sum "$target_release_env")
target_release_env_sha256=${target_release_env_sha256%% *}
adevtool_package_json_sha256=$(sha256sum "$adevtool_package_json")
adevtool_package_json_sha256=${adevtool_package_json_sha256%% *}
adevtool_yarn_lock_sha256=$(sha256sum "$adevtool_yarn_lock")
adevtool_yarn_lock_sha256=${adevtool_yarn_lock_sha256%% *}
sanitizer_sha256=$(sha256sum "$sanitizer")
sanitizer_sha256=${sanitizer_sha256%% *}
target_sanitizer_library_sha256=$(sha256sum "$target_sanitizer_library")
target_sanitizer_library_sha256=${target_sanitizer_library_sha256%% *}

mkdir -p "$attestation_dir"
[[ -d "$attestation_dir" && ! -L "$attestation_dir" ]] || \
  die "attestation directory is not a real directory: $attestation_dir"
assert_inside_work "$attestation_dir"
if [[ -e "$attestation" || -L "$attestation" ]]; then
  [[ -f "$attestation" && ! -L "$attestation" ]] || \
    die "attestation path is not a regular file: $attestation"
fi

temporary_attestation=$(mktemp "$attestation_dir/.vendor-attestation.XXXXXX")
temporary_paths=$(mktemp "$attestation_dir/.vendor-paths.XXXXXX")
temporary_input_paths=$(mktemp "$attestation_dir/.vendor-input-paths.XXXXXX")
temporary_input_inventory=$(mktemp "$attestation_dir/.vendor-inputs.XXXXXX")
cleanup() {
  [[ -z "${temporary_attestation:-}" ]] || \
    rm -f -- "$temporary_attestation"
  [[ -z "${temporary_paths:-}" ]] || rm -f -- "$temporary_paths"
  [[ -z "${temporary_input_paths:-}" ]] || \
    rm -f -- "$temporary_input_paths"
  [[ -z "${temporary_input_inventory:-}" ]] || \
    rm -f -- "$temporary_input_inventory"
}
trap cleanup EXIT

# A NUL-delimited sort keeps discovery deterministic before any pathname is
# interpreted by the shell. The manifest deliberately accepts only the
# portable pathname alphabet emitted by the pinned generator. This rejects
# control characters, whitespace, traversal components, and ambiguous fields.
find "$generated_dir" -mindepth 1 -print0 | LC_ALL=C sort -z > "$temporary_paths"

validate_relative_path() {
  local relative_path=$1
  [[ "$relative_path" =~ ^[-A-Za-z0-9._+@%=]+(/[-A-Za-z0-9._+@%=]+)*$ ]] || \
    die "unsafe attested pathname"
  [[ ! "$relative_path" =~ (^|/)\.\.?(/|$) ]] || \
    die "attested pathname contains a traversal component: $relative_path"
}

validate_mode() {
  local file_mode=$1
  [[ "$file_mode" =~ ^[0-7]{3,4}$ ]] || \
    die "invalid filesystem mode in generated vendor tree: $file_mode"
}

# Bind every pathname and file byte in the exact per-device data closure read
# by generate-all. The whole config root is intentional: its recursive YAML
# includes, build index, and makefile templates all participate in generation.
# Cub-specific Gservices flags are also direct generator input. Directory
# metadata and absolute checkout paths are excluded so the digest is portable.
generation_input_roots=(
  "$adevtool_config_dir"
  "$vendor_spec"
  "$vendor_skels_dir"
  "$gservices_flags_dir"
)
generation_input_entry_count=0
: > "$temporary_input_inventory"
find "${generation_input_roots[@]}" -mindepth 0 -print0 | \
  LC_ALL=C sort -z > "$temporary_input_paths"
while IFS= read -r -d '' input_path; do
  case "$input_path" in
    "$adevtool_dir"/*) input_relative_path=${input_path#"$adevtool_dir"/} ;;
    *) die "adevtool generation input escaped its root" ;;
  esac
  validate_relative_path "$input_relative_path"

  if [[ -L "$input_path" ]]; then
    die "symlinks are prohibited in the adevtool generation inputs: $input_relative_path"
  elif [[ -f "$input_path" ]]; then
    input_content_sha256=$(sha256sum -- "$input_path")
    input_content_sha256=${input_content_sha256%% *}
    [[ "$input_content_sha256" =~ ^[0-9a-f]{64}$ ]] || \
      die "failed to hash adevtool generation input: $input_relative_path"
    printf 'file\t%s\t%s\n' \
      "$input_content_sha256" "$input_relative_path" \
      >> "$temporary_input_inventory"
  elif [[ -d "$input_path" ]]; then
    printf 'directory\t-\t%s\n' "$input_relative_path" \
      >> "$temporary_input_inventory"
  else
    die "special file is prohibited in adevtool generation inputs: $input_relative_path"
  fi
  generation_input_entry_count=$((generation_input_entry_count + 1))
done < "$temporary_input_paths"
(( generation_input_entry_count > 0 )) || die "empty adevtool generation input inventory"
generation_inputs_inventory_sha256=$(sha256sum "$temporary_input_inventory")
generation_inputs_inventory_sha256=${generation_inputs_inventory_sha256%% *}
[[ "$generation_inputs_inventory_sha256" =~ ^[0-9a-f]{64}$ ]] || \
  die "failed to hash adevtool generation input inventory"

root_mode=$(stat -c '%a' -- "$generated_dir")
validate_mode "$root_mode"
entry_count=1
{
  printf 'format=pixel-aosp-generated-vendor-attestation-v1\n'
  printf 'device=%s\n' "$DEVICE_CODENAME"
  printf 'stock_build_id=%s\n' "$STOCK_BUILD_ID"
  printf 'factory_image_filename=%s\n' "$FACTORY_IMAGE_FILENAME"
  printf 'factory_image_sha256=%s\n' "$FACTORY_IMAGE_SHA256"
  printf 'aosp_revision=%s\n' "$AOSP_REVISION"
  printf 'release_env_sha256=%s\n' "$release_env_sha256"
  printf 'target_release_env_sha256=%s\n' "$target_release_env_sha256"
  printf 'resolved_manifest_sha256=%s\n' "$resolved_manifest_sha256"
  printf 'patch_sha256_lock_path=patches/SHA256SUMS\n'
  printf 'patch_sha256_lock_sha256=%s\n' "$patch_sha256_lock_sha256"
  printf 'adevtool_revision=%s\n' "$actual_adevtool_revision"
  printf 'adevtool_package_json_sha256=%s\n' "$adevtool_package_json_sha256"
  printf 'adevtool_yarn_lock_sha256=%s\n' "$adevtool_yarn_lock_sha256"
  printf 'generation_inputs=config,vendor-specs/google_devices/%s.yml,vendor-skels/google_devices/%s,gservices-flags/google_devices/%s\n' \
    "$DEVICE_CODENAME" "$DEVICE_CODENAME" "$DEVICE_CODENAME"
  printf 'generation_inputs_entry_count=%d\n' "$generation_input_entry_count"
  printf 'generation_inputs_inventory_sha256=%s\n' \
    "$generation_inputs_inventory_sha256"
  printf 'vendor_state_revision=%s\n' "$actual_vendor_state_revision"
  printf 'vendor_state_spec_sha256=%s\n' "$vendor_state_spec_sha256"
  printf 'sanitizer_path=%s\n' "${sanitizer#"$project_root"/}"
  printf 'sanitizer_sha256=%s\n' "$sanitizer_sha256"
  printf 'target_sanitizer_library_path=%s\n' \
    "$target_sanitizer_library_path"
  printf 'target_sanitizer_library_sha256=%s\n' \
    "$target_sanitizer_library_sha256"
  printf 'strict_neverallows=true\n'
  printf 'duplicate_rules_strict=true\n'
  printf 'tree_path=vendor/google_devices/%s\n' "$DEVICE_CODENAME"
  printf 'fields=type\\tmode\\tcontent_sha256_or_symlink_target\\trelative_path\n'
  printf -- '--tree--\n'
  printf 'directory\t%s\t-\t.\n' "$root_mode"
} > "$temporary_attestation"

while IFS= read -r -d '' entry_path; do
  case "$entry_path" in
    "$generated_dir"/*) relative_path=${entry_path#"$generated_dir"/} ;;
    *) die "generated-vendor path escaped its root" ;;
  esac
  validate_relative_path "$relative_path"
  entry_mode=$(stat -c '%a' -- "$entry_path")
  validate_mode "$entry_mode"

  if [[ -L "$entry_path" ]]; then
    symlink_target=
    IFS= read -r -d '' symlink_target < <(readlink --zero -- "$entry_path") || \
      die "failed to read generated-vendor symlink: $relative_path"
    [[ -n "$symlink_target" && "$symlink_target" != /* && \
       "$symlink_target" =~ ^[-A-Za-z0-9._+@%=/]+$ ]] || \
      die "unsafe generated-vendor symlink target: $relative_path"
    resolved_target=$(realpath -m -- "$(dirname -- "$entry_path")/$symlink_target")
    case "$resolved_target" in
      "$generated_dir"|"$generated_dir"/*) ;;
      *) die "generated-vendor symlink escapes its root: $relative_path" ;;
    esac
    printf 'symlink\t%s\t%s\t%s\n' \
      "$entry_mode" "$symlink_target" "$relative_path" \
      >> "$temporary_attestation"
  elif [[ -f "$entry_path" ]]; then
    content_sha256=$(sha256sum -- "$entry_path")
    content_sha256=${content_sha256%% *}
    [[ "$content_sha256" =~ ^[0-9a-f]{64}$ ]] || \
      die "failed to hash generated-vendor file: $relative_path"
    printf 'file\t%s\t%s\t%s\n' \
      "$entry_mode" "$content_sha256" "$relative_path" \
      >> "$temporary_attestation"
  elif [[ -d "$entry_path" ]]; then
    printf 'directory\t%s\t-\t%s\n' \
      "$entry_mode" "$relative_path" >> "$temporary_attestation"
  else
    die "special file is prohibited in generated vendor tree: $relative_path"
  fi
  entry_count=$((entry_count + 1))
done < "$temporary_paths"
printf -- '--summary--\nentry_count=%d\n' "$entry_count" \
  >> "$temporary_attestation"

case "$action" in
  create)
    chmod 0644 "$temporary_attestation"
    mv -f -- "$temporary_attestation" "$attestation"
    temporary_attestation=
    note "created generated-vendor attestation: $attestation"
    ;;
  verify)
    [[ -f "$attestation" && ! -L "$attestation" ]] || \
      die "generated-vendor attestation is missing or unsafe; rerun extract-vendor.sh"
    cmp -s -- "$attestation" "$temporary_attestation" || \
      die "generated vendor tree does not match its extraction attestation"
    note "generated vendor tree and extraction inputs verified"
    ;;
esac
