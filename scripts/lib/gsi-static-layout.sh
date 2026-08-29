#!/usr/bin/env bash

# Read-only validation for the deliberately embedded product/system_ext layout
# of the Android 17 GSI. Callers provide die() through scripts/lib/common.sh.

gsi_static_magic_at() {
  local image=$1
  local offset=$2
  local count=$3
  od -An -tx1 -j "$offset" -N "$count" -v "$image" | tr -d ' \n'
}

gsi_static_debugfs_stat() {
  local image=$1
  local path=$2
  local output=$3
  local description=$4
  local -a types=()

  [[ "$path" =~ ^/[a-zA-Z0-9._/-]+$ && "$path" != *//* && \
     "$path" != */../* && "$path" != */.. ]] || \
    die "unsafe GSI filesystem path: $path"
  if ! LC_ALL=C debugfs -R "stat $path" "$image" >"$output" 2>&1; then
    die "could not inspect $description in GSI system.img"
  fi
  mapfile -t types < <(
    sed -n \
      's/^Inode: [0-9][0-9]*[[:space:]]*Type: \([^[:space:]]*\).*/\1/p' \
      "$output"
  )
  (( ${#types[@]} == 1 )) || \
    die "$description is missing or has ambiguous inode metadata"
  printf '%s\n' "${types[0]}"
}

gsi_static_require_symlink() {
  local image=$1
  local path=$2
  local expected=$3
  local scratch=$4
  local description=$5
  local label stat_file type

  label=${path#/}
  label=${label//\//-}
  stat_file="$scratch/gsi-layout-$label.stat"
  type=$(gsi_static_debugfs_stat "$image" "$path" "$stat_file" \
    "$description")
  [[ "$type" == symlink ]] || \
    die "$description must be a symbolic link"
  [[ $(grep -Fxc -- "Fast link dest: \"$expected\"" "$stat_file") -eq 1 ]] || \
    die "$description must point exactly to $expected"
}

gsi_static_extract_regular_file() {
  local image=$1
  local path=$2
  local destination=$3
  local scratch=$4
  local description=$5
  local label stat_file cat_log type actual_size
  local -a declared_sizes=()

  label=${path#/}
  label=${label//\//-}
  stat_file="$scratch/gsi-layout-$label.stat"
  cat_log="$scratch/gsi-layout-$label.cat.log"
  type=$(gsi_static_debugfs_stat "$image" "$path" "$stat_file" \
    "$description")
  [[ "$type" == regular ]] || \
    die "$description must be a regular file"
  mapfile -t declared_sizes < <(
    sed -n \
      's/^User:.*[[:space:]]Size: \([0-9][0-9]*\)$/\1/p' \
      "$stat_file"
  )
  (( ${#declared_sizes[@]} == 1 && declared_sizes[0] > 0 )) || \
    die "$description has invalid or ambiguous size metadata"
  if ! LC_ALL=C debugfs -R "cat $path" "$image" \
      >"$destination" 2>"$cat_log"; then
    die "could not extract $description from GSI system.img"
  fi
  actual_size=$(stat -c '%s' "$destination")
  (( actual_size == declared_sizes[0] )) || \
    die "$description extraction size does not match its inode"
}

gsi_static_require_exact_property() {
  local property_file=$1
  local property_name=$2
  local expected=$3
  local description=$4
  local -a values=()

  mapfile -t values < <(
    awk -v key="$property_name" \
      'index($0, key "=") == 1 {print substr($0, length(key) + 2)}' \
      "$property_file"
  )
  (( ${#values[@]} == 1 )) || \
    die "$description must occur exactly once in its embedded build.prop"
  [[ "${values[0]}" == "$expected" ]] || \
    die "$description mismatch: expected $expected, found ${values[0]}"
}

validate_gsi_static_layout() {
  local image=$1
  local scratch=$2
  local build_id=$3
  local build_number=$4
  local product_prop="$scratch/gsi-embedded-product-build.prop"
  local system_ext_prop="$scratch/gsi-embedded-system-ext-build.prop"
  local skip_mount="$scratch/gsi-skip-mount.cfg"
  local expected_fingerprint
  local digest

  [[ -f "$image" && ! -L "$image" && -s "$image" ]] || \
    die "GSI system.img is missing, empty, or unsafe"
  [[ -d "$scratch" && ! -L "$scratch" ]] || \
    die "GSI layout scratch directory is missing or unsafe"
  [[ "$build_id" =~ ^[A-Z0-9.]+$ && \
     "$build_number" =~ ^[a-zA-Z0-9._-]+$ ]] || \
    die "unsafe expected GSI build identity"

  [[ $(gsi_static_magic_at "$image" 0 4) != 3aff26ed ]] || \
    die "GSI system.img must be raw, not Android sparse"
  [[ $(gsi_static_magic_at "$image" 1080 2) == 53ef ]] || \
    die "raw GSI system.img must use ext4"

  gsi_static_require_symlink "$image" /product /system/product "$scratch" \
    "GSI root /product alias"
  gsi_static_require_symlink "$image" /system_ext /system/system_ext \
    "$scratch" "GSI root /system_ext alias"
  gsi_static_require_symlink \
    "$image" /system/etc/init/config /system/system_ext/etc/init/config \
    "$scratch" "GSI init config compatibility alias"

  gsi_static_extract_regular_file \
    "$image" /system/system_ext/etc/init/config/skip_mount.cfg \
    "$skip_mount" "$scratch" "GSI skip_mount.cfg"
  [[ $(stat -c '%s' "$skip_mount") == 143 ]] || \
    die "GSI skip_mount.cfg does not have the exact reviewed length"
  digest=$(sha256sum -- "$skip_mount")
  digest=${digest%% *}
  [[ "$digest" == \
     7c28485e025157acbbd0abf9505a212af3b4a96211b5aa3bc3d858a560a3aefd ]] || \
    die "GSI skip_mount.cfg does not exactly suppress the reviewed mountpoints"

  gsi_static_extract_regular_file \
    "$image" /system/product/etc/build.prop "$product_prop" "$scratch" \
    "GSI embedded product build.prop"
  gsi_static_extract_regular_file \
    "$image" /system/system_ext/etc/build.prop "$system_ext_prop" "$scratch" \
    "GSI embedded system_ext build.prop"
  expected_fingerprint=Android/gsi_arm64/generic_arm64:17/
  expected_fingerprint+="$build_id/$build_number:userdebug/test-keys"

  gsi_static_require_exact_property "$product_prop" ro.product.build.id \
    "$build_id" "GSI embedded product build ID"
  gsi_static_require_exact_property "$product_prop" ro.product.build.type \
    userdebug "GSI embedded product build type"
  gsi_static_require_exact_property "$product_prop" ro.product.build.tags \
    test-keys "GSI embedded product build tags"
  gsi_static_require_exact_property "$product_prop" \
    ro.product.build.fingerprint "$expected_fingerprint" \
    "GSI embedded product fingerprint"

  gsi_static_require_exact_property "$system_ext_prop" ro.system_ext.build.id \
    "$build_id" "GSI embedded system_ext build ID"
  gsi_static_require_exact_property "$system_ext_prop" \
    ro.system_ext.build.type userdebug "GSI embedded system_ext build type"
  gsi_static_require_exact_property "$system_ext_prop" \
    ro.system_ext.build.tags test-keys "GSI embedded system_ext build tags"
  gsi_static_require_exact_property "$system_ext_prop" \
    ro.system_ext.build.fingerprint "$expected_fingerprint" \
    "GSI embedded system_ext fingerprint"
  gsi_static_require_exact_property "$system_ext_prop" ro.adb.secure 0 \
    "GSI embedded system_ext ro.adb.secure"
}
