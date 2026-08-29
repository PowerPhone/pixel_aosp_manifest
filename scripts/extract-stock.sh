#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_command sha256sum unzip

factory_image="$project_root/downloads/$FACTORY_IMAGE_FILENAME"
verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory_image"

stock_dir="$project_root/work/stock"
assert_inside_project "$stock_dir"
[[ ! -L "$stock_dir" ]] || \
  die "stock extraction root must not be a symbolic link: $stock_dir"
mkdir -p "$stock_dir"
[[ -d "$stock_dir" && ! -L "$stock_dir" ]] || \
  die "stock extraction root is not a real directory: $stock_dir"

target_dir="$stock_dir/${FACTORY_IMAGE_FILENAME%-factory-*}"
expected_inner="$target_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
sentinel="$target_dir/.pixel-aosp-complete"
outer_inner_entry="${FACTORY_IMAGE_FILENAME%-factory-*}/$(basename -- "$expected_inner")"

outer_entries=$(unzip -Z1 "$factory_image")
[[ $(grep -Fxc -- "$outer_inner_entry" <<<"$outer_entries" || true) -eq 1 ]] || \
  die "verified factory archive must contain exactly one $outer_inner_entry"

inner_hash_from_factory() {
  unzip -p "$factory_image" "$outer_inner_entry" | sha256sum | awk '{print $1}'
}

write_sentinel() {
  local destination=$1
  local inner_hash=$2
  local temporary_sentinel
  [[ ! -L "$destination" && ( ! -e "$destination" || -f "$destination" ) ]] || \
    die "stock extraction sentinel is not a safe regular file: $destination"
  temporary_sentinel=$(mktemp "$(dirname -- "$destination")/.sentinel.XXXXXX")
  {
    printf 'factory_sha256=%s\n' "$FACTORY_IMAGE_SHA256"
    printf 'inner_sha256=%s\n' "$inner_hash"
  } > "$temporary_sentinel"
  chmod 0644 "$temporary_sentinel"
  mv -- "$temporary_sentinel" "$destination"
}

validate_extracted() {
  local inner=$1
  local entries required_entry entry_count
  require_file "$inner"
  [[ ! -L "$inner" ]] || \
    die "stock inner image ZIP must not be a symbolic link: $inner"
  unzip -tqq "$inner"
  entries=$(unzip -Z1 "$inner")
  for required_entry in \
    android-info.txt \
    fastboot-info.txt \
    boot.img \
    init_boot.img \
    pvmfw.img \
    system.img \
    vendor.img \
    vendor_boot.img \
    vendor_kernel_boot.img \
    vbmeta.img; do
    entry_count=$(grep -Fxc -- "$required_entry" <<<"$entries" || true)
    (( entry_count == 1 )) || die \
      "stock image archive must contain exactly one root $required_entry"
  done
}

if [[ -e "$target_dir" || -L "$target_dir" ]]; then
  [[ -d "$target_dir" && ! -L "$target_dir" ]] || \
    die "stock extraction target is not a real directory: $target_dir"
fi

if [[ -e "$expected_inner" || -L "$expected_inner" ]]; then
  [[ -f "$expected_inner" && ! -L "$expected_inner" ]] || \
    die "stock inner image path is not a regular file: $expected_inner"
  note "proving pre-existing stock extraction against the verified outer archive"
  validate_extracted "$expected_inner"
  expected_inner_hash=$(inner_hash_from_factory)
  actual_inner_hash=$(sha256sum "$expected_inner" | awk '{print $1}')
  [[ "$actual_inner_hash" == "$expected_inner_hash" ]] || \
    die "pre-existing inner stock archive does not come from the pinned factory image"
  write_sentinel "$sentinel" "$actual_inner_hash"
  note "stock package already extracted and validated: $target_dir"
  exit 0
fi

note "extracting verified factory package"
temporary_root=$(mktemp -d "$stock_dir/.extract.XXXXXX")
cleanup() {
  if [[ -n "${temporary_root:-}" && -d "$temporary_root" && \
        ! -L "$temporary_root" && "$temporary_root" == "$stock_dir"/.extract.* ]]; then
    rm -rf -- "$temporary_root"
  fi
}
trap cleanup EXIT
unzip -q "$factory_image" -d "$temporary_root"
temporary_target="$temporary_root/${FACTORY_IMAGE_FILENAME%-factory-*}"
temporary_inner="$temporary_target/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
[[ -d "$temporary_target" && ! -L "$temporary_target" ]] || \
  die "factory archive did not produce the expected real stock directory"
validate_extracted "$temporary_inner"
temporary_inner_hash=$(sha256sum "$temporary_inner" | awk '{print $1}')
write_sentinel "$temporary_target/.pixel-aosp-complete" "$temporary_inner_hash"

if [[ -e "$target_dir" ]]; then
  incomplete_backup="$target_dir.incomplete.$(date -u +%Y%m%dT%H%M%SZ).$$"
  [[ ! -e "$incomplete_backup" && ! -L "$incomplete_backup" ]] || \
    die "stock extraction backup path already exists: $incomplete_backup"
  mv -- "$target_dir" "$incomplete_backup"
  note "preserved incomplete extraction at $incomplete_backup"
fi
mv -- "$temporary_target" "$target_dir"
note "stock package ready: $target_dir"
