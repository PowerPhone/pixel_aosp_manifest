#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
# shellcheck source=../lib/common.sh disable=SC1091
source "$project_root/scripts/lib/common.sh"
# shellcheck source=../lib/gsi-static-layout.sh disable=SC1091
source "$project_root/scripts/lib/gsi-static-layout.sh"

require_command \
  awk cp debugfs grep img2simg ln mkdir mke2fs mkfs.erofs mktemp od rm \
  sed sha256sum stat truncate tr

scratch_parent="$project_root/work/gsi-static-layout-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

fixture_tree="$scratch_dir/tree"
layout_scratch="$scratch_dir/layout"
build_id=CP2A.260605.016
build_number=pixel_aosp17_r1
fingerprint=Android/gsi_arm64/generic_arm64:17/
fingerprint+="$build_id/$build_number:userdebug/test-keys"
fixture_image=

write_skip_mount() {
  printf '%s\n' \
    '# Skip "system" mountpoints.' \
    /oem \
    /product \
    /system_ext \
    '# Skip sub-mountpoints of system mountpoints.' \
    '/oem/*' \
    '/product/*' \
    '/system_ext/*' \
    '/system/*' \
    >"$fixture_tree/system/system_ext/etc/init/config/skip_mount.cfg"
}

write_product_prop() {
  printf '%s\n' \
    "ro.product.build.fingerprint=$fingerprint" \
    "ro.product.build.id=$build_id" \
    'ro.product.build.tags=test-keys' \
    'ro.product.build.type=userdebug' \
    >"$fixture_tree/system/product/etc/build.prop"
}

write_system_ext_prop() {
  printf '%s\n' \
    "ro.system_ext.build.fingerprint=$fingerprint" \
    "ro.system_ext.build.id=$build_id" \
    'ro.system_ext.build.tags=test-keys' \
    'ro.system_ext.build.type=userdebug' \
    'ro.adb.secure=0' \
    >"$fixture_tree/system/system_ext/etc/build.prop"
}

make_tree() {
  rm -rf -- "$fixture_tree"
  mkdir -p \
    "$fixture_tree/system/etc/init" \
    "$fixture_tree/system/product/etc" \
    "$fixture_tree/system/system_ext/etc/init/config"
  ln -s /system/product "$fixture_tree/product"
  ln -s /system/system_ext "$fixture_tree/system_ext"
  ln -s /system/system_ext/etc/init/config \
    "$fixture_tree/system/etc/init/config"
  write_skip_mount
  write_product_prop
  write_system_ext_prop
}

build_ext4_fixture() {
  local name=$1
  fixture_image="$scratch_dir/$name.img"
  truncate -s 32M "$fixture_image"
  mke2fs -q -F -t ext4 -b 4096 -d "$fixture_tree" "$fixture_image"
}

expect_failure() {
  local description=$1
  local expected_message=$2
  local image=${3:-$fixture_image}
  local log="$scratch_dir/${description//[^a-zA-Z0-9]/-}.log"

  if (validate_gsi_static_layout \
      "$image" "$layout_scratch" "$build_id" "$build_number") \
      >"$log" 2>&1; then
    die "$description unexpectedly passed GSI static-layout validation"
  fi
  grep -Fq -- "$expected_message" "$log" || {
    sed -n '1,160p' "$log" >&2
    die "$description failed for an unexpected reason"
  }
}

mkdir -p "$layout_scratch"

make_tree
build_ext4_fixture canonical
validate_gsi_static_layout \
  "$fixture_image" "$layout_scratch" "$build_id" "$build_number"

sparse_image="$scratch_dir/system-sparse.img"
img2simg "$fixture_image" "$sparse_image"
expect_failure sparse-container \
  'GSI system.img must be raw, not Android sparse' "$sparse_image"

erofs_image="$scratch_dir/system-erofs.img"
mkfs.erofs --quiet "$erofs_image" "$fixture_tree"
expect_failure erofs-filesystem \
  'raw GSI system.img must use ext4' "$erofs_image"

make_tree
ln -sfn /wrong/product "$fixture_tree/product"
build_ext4_fixture wrong-product-alias
expect_failure wrong-product-alias \
  'GSI root /product alias must point exactly to /system/product'

make_tree
ln -sfn /wrong/system_ext "$fixture_tree/system_ext"
build_ext4_fixture wrong-system-ext-alias
expect_failure wrong-system-ext-alias \
  'GSI root /system_ext alias must point exactly to /system/system_ext'

make_tree
ln -sfn /wrong/config "$fixture_tree/system/etc/init/config"
build_ext4_fixture wrong-config-alias
expect_failure wrong-config-alias \
  'GSI init config compatibility alias must point exactly to /system/system_ext/etc/init/config'

make_tree
printf '%s\n' '/product' '/system_ext' \
  >"$fixture_tree/system/system_ext/etc/init/config/skip_mount.cfg"
build_ext4_fixture incomplete-skip-mount
expect_failure incomplete-skip-mount \
  'GSI skip_mount.cfg does not have the exact reviewed length'

make_tree
sed -i 's|^/oem$|/odm|' \
  "$fixture_tree/system/system_ext/etc/init/config/skip_mount.cfg"
build_ext4_fixture changed-same-length-skip-mount
expect_failure changed-same-length-skip-mount \
  'GSI skip_mount.cfg does not exactly suppress the reviewed mountpoints'

make_tree
sed -i 's/^ro.product.build.id=.*/ro.product.build.id=WRONG/' \
  "$fixture_tree/system/product/etc/build.prop"
build_ext4_fixture wrong-product-id
expect_failure wrong-product-id \
  'GSI embedded product build ID mismatch'

make_tree
sed -i 's/^ro.product.build.type=.*/ro.product.build.type=user/' \
  "$fixture_tree/system/product/etc/build.prop"
build_ext4_fixture wrong-product-type
expect_failure wrong-product-type \
  'GSI embedded product build type mismatch'

make_tree
sed -i 's/^ro.product.build.tags=.*/ro.product.build.tags=release-keys/' \
  "$fixture_tree/system/product/etc/build.prop"
build_ext4_fixture wrong-product-tags
expect_failure wrong-product-tags \
  'GSI embedded product build tags mismatch'

make_tree
sed -i 's/pixel_aosp17_r1/pixel_aosp17_wrong/' \
  "$fixture_tree/system/product/etc/build.prop"
build_ext4_fixture wrong-product-fingerprint
expect_failure wrong-product-fingerprint \
  'GSI embedded product fingerprint mismatch'

make_tree
sed -i 's/^ro.system_ext.build.id=.*/ro.system_ext.build.id=WRONG/' \
  "$fixture_tree/system/system_ext/etc/build.prop"
build_ext4_fixture wrong-system-ext-id
expect_failure wrong-system-ext-id \
  'GSI embedded system_ext build ID mismatch'

make_tree
sed -i 's/^ro.system_ext.build.type=.*/ro.system_ext.build.type=user/' \
  "$fixture_tree/system/system_ext/etc/build.prop"
build_ext4_fixture wrong-system-ext-type
expect_failure wrong-system-ext-type \
  'GSI embedded system_ext build type mismatch'

make_tree
sed -i 's/^ro.system_ext.build.tags=.*/ro.system_ext.build.tags=release-keys/' \
  "$fixture_tree/system/system_ext/etc/build.prop"
build_ext4_fixture wrong-system-ext-tags
expect_failure wrong-system-ext-tags \
  'GSI embedded system_ext build tags mismatch'

make_tree
sed -i 's/pixel_aosp17_r1/pixel_aosp17_wrong/' \
  "$fixture_tree/system/system_ext/etc/build.prop"
build_ext4_fixture wrong-system-ext-fingerprint
expect_failure wrong-system-ext-fingerprint \
  'GSI embedded system_ext fingerprint mismatch'

make_tree
sed -i '/^ro.adb.secure=/d' \
  "$fixture_tree/system/system_ext/etc/build.prop"
build_ext4_fixture missing-adb-policy
expect_failure missing-adb-policy \
  'GSI embedded system_ext ro.adb.secure must occur exactly once'

make_tree
printf '%s\n' 'ro.adb.secure=0' \
  >>"$fixture_tree/system/system_ext/etc/build.prop"
build_ext4_fixture duplicate-adb-policy
expect_failure duplicate-adb-policy \
  'GSI embedded system_ext ro.adb.secure must occur exactly once'

make_tree
sed -i 's/^ro.adb.secure=.*/ro.adb.secure=1/' \
  "$fixture_tree/system/system_ext/etc/build.prop"
build_ext4_fixture authenticated-adb-policy
expect_failure authenticated-adb-policy \
  'GSI embedded system_ext ro.adb.secure mismatch: expected 0, found 1'

note "GSI raw-ext4 embedded-layout positive and mutation fixtures passed"
