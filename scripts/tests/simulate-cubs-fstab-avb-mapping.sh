#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
# shellcheck source=../lib/common.sh disable=SC1091
source "$project_root/scripts/lib/common.sh"
# shellcheck source=../lib/cubs-fstab.sh disable=SC1091
source "$project_root/scripts/lib/cubs-fstab.sh"

require_command awk cmp cp grep mkdir mktemp rm sed sha256sum sort

scratch_parent="$project_root/work/fstab-avb-mapping-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

write_adevtool_fixture() {
  local path=$1
  printf '%s\n' \
    '# synthetic fstab with the exact active cubs AVB record set' \
    'system /system erofs ro wait,slotselect,avb=vbmeta,logical' \
    'system /system ext4 ro wait,slotselect,avb=vbmeta,logical' \
    'system_dlkm /system_dlkm erofs ro wait,slotselect,avb=vbmeta,logical' \
    'system_dlkm /system_dlkm ext4 ro wait,slotselect,avb=vbmeta,logical' \
    'system_ext /system_ext erofs ro wait,slotselect,avb=vbmeta,logical' \
    'product /product erofs ro wait,slotselect,avb=vbmeta,logical' \
    'vendor /vendor erofs ro wait,slotselect,avb=vbmeta,logical' \
    'vendor_dlkm /vendor_dlkm erofs ro wait,slotselect,avb=vbmeta,logical' \
    'vendor_dlkm /vendor_dlkm ext4 ro wait,slotselect,avb=vbmeta,logical' \
    '/dev/block/by-name/boot /boot emmc defaults wait,slotselect,avb=vbmeta,first_stage_mount' \
    '/dev/block/by-name/init_boot /init_boot emmc defaults wait,slotselect,avb=vbmeta,first_stage_mount' \
    '#/dev/block/by-name/pvmfw /pvmfw emmc defaults wait,slotselect,avb=vbmeta,first_stage_mount' \
    '/dev/block/by-name/misc /misc emmc defaults wait' \
    >"$path"
}

file_sha256() {
  local digest
  digest=$(sha256sum -- "$1")
  digest=${digest%% *}
  printf '%s\n' "$digest"
}

expect_failure() {
  local description=$1
  local expected_message=$2
  shift 2
  local log="$scratch_dir/${description//[^a-zA-Z0-9]/-}.log"

  if ("$@") >"$log" 2>&1; then
    die "$description unexpectedly passed"
  fi
  grep -Fq -- "$expected_message" "$log" || {
    sed -n '1,120p' "$log" >&2
    die "$description failed for an unexpected reason"
  }
}

fixture="$scratch_dir/fstab.malibu"
expected="$scratch_dir/fstab.expected.malibu"
write_adevtool_fixture "$fixture"
cubs_validate_fstab_avb_mapping "$fixture" adevtool-root "fixture fstab"
cubs_rewrite_fstab_avb_mapping "$fixture" "$expected" "fixture fstab"
cubs_validate_fstab_avb_mapping "$expected" chained "normalized fixture fstab"

expected_targets=$(cubs_fstab_child_avb_targets \
  "$expected" "normalized fixture fstab")
[[ "$expected_targets" == $'boot\ninit_boot\nvbmeta_system\nvbmeta_vendor' ]] || \
  die "normalized fixture exposes the wrong child AVB target set"
root_chains=$'boot:2\ninit_boot:4\nvbmeta_system:1\nvbmeta_vendor:3'
cubs_validate_fstab_against_root_chains \
  "$expected" "$root_chains" "normalized fixture fstab"
expect_failure missing-root-chain \
  'child AVB targets differ from root vbmeta chain descriptors' \
  cubs_validate_fstab_against_root_chains \
  "$expected" $'boot:2\ninit_boot:4\nvbmeta_system:1' \
  "normalized fixture fstab"
expect_failure malformed-root-chain \
  'root AVB chain records are malformed' \
  cubs_validate_fstab_against_root_chains \
  "$expected" $'boot:2\ninit_boot:zero\nvbmeta_system:1\nvbmeta_vendor:3' \
  "normalized fixture fstab"

pristine_sha256=$(file_sha256 "$fixture")
normalized_sha256=$(file_sha256 "$expected")
expect_failure pristine-check \
  'generated cubs fstab child AVB mapping has not been restored' \
  sanitize_cubs_fstab_avb_mapping \
  "$fixture" "$pristine_sha256" "$normalized_sha256" true "fixture fstab"
sanitize_cubs_fstab_avb_mapping \
  "$fixture" "$pristine_sha256" "$normalized_sha256" false "fixture fstab"
cmp -s -- "$fixture" "$expected" || \
  die "cubs fstab sanitizer changed bytes outside the exact mapping transform"
sanitize_cubs_fstab_avb_mapping \
  "$fixture" "$pristine_sha256" "$normalized_sha256" true "fixture fstab"

wrong_mapping="$scratch_dir/fstab.wrong-mapping"
cp -- "$expected" "$wrong_mapping"
sed -i '0,/avb=vbmeta_system,/s//avb=vbmeta_vendor,/' "$wrong_mapping"
expect_failure wrong-mapping \
  'does not contain the exact chained AVB mapping' \
  cubs_validate_fstab_avb_mapping \
  "$wrong_mapping" chained "wrong-mapping fixture"

key_bypass="$scratch_dir/fstab.key-bypass"
cp -- "$expected" "$key_bypass"
sed -i '0,/avb=vbmeta,/s//avb=vbmeta,avb_keys=no_such_key,/' "$key_bypass"
expect_failure key-bypass \
  'malformed, duplicate, or key-bypassing AVB flags' \
  cubs_validate_fstab_avb_mapping \
  "$key_bypass" chained "key-bypass fixture"

extra_record="$scratch_dir/fstab.extra-record"
cp -- "$expected" "$extra_record"
printf '%s\n' \
  'odm /odm erofs ro wait,slotselect,avb=vbmeta,logical' >>"$extra_record"
expect_failure extra-record \
  'does not contain the exact chained AVB mapping' \
  cubs_validate_fstab_avb_mapping \
  "$extra_record" chained "extra-record fixture"

partial="$scratch_dir/fstab.partial"
write_adevtool_fixture "$partial"
sed -i '0,/avb=vbmeta,/s//avb=vbmeta_system,/' "$partial"
expect_failure partial-hash-state \
  'differs from both exact pristine and normalized states' \
  sanitize_cubs_fstab_avb_mapping \
  "$partial" "$pristine_sha256" "$normalized_sha256" false "partial fixture"

# When a private generated tree is available, exercise the public transform
# against its real FileTreeSpec-pinned bytes without modifying that tree.
real_fstab="$project_root/work/aosp/vendor/google_devices/cubs/proprietary/vendor_ramdisk/system/etc/fstab.malibu"
if [[ -f "$real_fstab" && ! -L "$real_fstab" ]]; then
  real_copy="$scratch_dir/real-fstab.malibu"
  cp -- "$real_fstab" "$real_copy"
  sanitize_cubs_fstab_avb_mapping \
    "$real_copy" \
    "$CUBS_ADEVTOOL_FSTAB_SHA256" \
    "$CUBS_CHAINED_AVB_FSTAB_SHA256" \
    false \
    "copied real generated fstab.malibu"
fi

printf '%s\n' 'mocked cubs fstab AVB normalization and chain validation passed'
