#!/usr/bin/env bash
# Materialize the opt-in Cubs research primary from canonical sources.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
aosp_tree="${repo}/work/aosp"
target=cubs
usage() {
    printf '%s\n' 'Usage: stage-primary-profile.sh [--target cubs] [--aosp-tree CANONICAL_REPO/work/aosp]'
    printf '%s\n' 'Stages sources and idempotent build includes only; never builds, flashes or hashes.'
}
while (($#)); do
    case "$1" in
        --target) target=${2:?Missing target}; shift 2 ;;
        --aosp-tree) aosp_tree=${2:?Missing tree}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$target" == cubs ]] || die 'This script never stages another target.'
for tool in realpath cp mv mkdir mktemp awk grep find chmod touch; do
    command -v "$tool" >/dev/null || die "Required host tool missing: $tool"
done
aosp_tree="$(realpath -e -- "$aosp_tree")"
[[ "$aosp_tree" == "$(realpath -e -- "$repo/work/aosp")" ]] || \
    die 'Refusing a tree outside this repository canonical work/aosp.'
[[ -d "$aosp_tree/.repo" && -f "$aosp_tree/build/soong/soong_ui.bash" ]] || \
    die 'Not the existing repo-managed AOSP build tree.'

generated="$aosp_tree/vendor/google_devices/cubs"
product="$generated/cubs.mk"
board="$generated/BoardConfig.mk"
integration="$repo/config/targets/cubs/powerphone"
helper="$repo/tools/audio/device/cubs_powerphone_boot"
[[ -d "$generated" && ! -L "$generated" && -f "$product" && -f "$board" ]] || \
    die 'Generated Cubs product/BoardConfig is absent or not a plain directory.'
grep -Fxq 'PRODUCT_DEVICE := cubs' "$product" || die 'Product identity is not Cubs.'
grep -Fxq 'ifneq ($(BUILD_ID),CD1A.260714.001.A9)' "$product" || die 'Unknown Cubs donor build.'
grep -Fxq 'include vendor/adevtool/config/mk/google_devices/device/cubs/BoardConfig-base.mk' "$board" || \
    die 'BoardConfig is not the expected generated Cubs board.'
for item in Android.bp product.mk cubs_powerphone_services.rc \
    cubs_powerphone_platform_gate.rc cubs_powerphone.xml \
    sepolicy/cubs_powerphone.te sepolicy/file_contexts sepolicy/property_contexts; do
    [[ -s "$integration/$item" ]] || die "Missing canonical integration file: $item"
done
for item in Android.bp cubs_powerphone_boot.cpp factory_transport.inc profile_generated.h; do
    [[ -s "$helper/$item" ]] || die "Missing canonical boot-helper file: $item"
done
for source in "$integration" "$helper"; do
    [[ -d "$source" && ! -L "$source" ]] || die "Unsafe source directory: $source"
    [[ -z "$(find "$source" -type l -print -quit)" ]] || die "Source contains a symlink: $source"
done

# Keep Make's variable literal. Both generated source and the filter must name
# exactly this mapping; a basename-only filter would leave the old RC active.
stock_rc='vendor/google_devices/cubs/proprietary/vendor/etc/init/android.hardware.audio.service-aidl.aoc.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/android.hardware.audio.service-aidl.aoc.rc'
grep -Fq -- "$stock_rc" "$product" || die 'Generated stock RC copy mapping changed.'
grep -Fq -- "$stock_rc," "$integration/product.mk" || die 'Canonical stock RC filter does not match generated source.'
printf 'Exact proprietary RC filter matches generated cubs.mk.\n'

product_line='include vendor/google_devices/cubs/powerphone/product.mk'
policy_line='BOARD_VENDOR_SEPOLICY_DIRS += vendor/google_devices/cubs/powerphone/sepolicy'
for specification in product board; do
    if [[ "$specification" == product ]]; then file=$product; line=$product_line; else file=$board; line=$policy_line; fi
    count=$(grep -Fxc -- "$line" "$file" || true)
    ((count <= 1)) || die "Duplicate requested include in $file"
done

backup_root="$repo/work/audio-research/cubs/primary-profile-staging"
mkdir -p -- "$backup_root"
snapshot="$(mktemp -d "$backup_root/stage-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
cp -a -- "$product" "$snapshot/cubs.mk.before"
cp -a -- "$board" "$snapshot/BoardConfig.mk.before"
mkdir -- "$snapshot/incoming"
cp -a -- "$integration" "$snapshot/incoming/powerphone"
cp -a -- "$helper" "$snapshot/incoming/powerphone-boot"
for name in powerphone powerphone-boot; do
    destination="$generated/$name"
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -d "$destination" && ! -L "$destination" ]] || die "Unsafe destination: $destination"
        # Backups stay outside AOSP: duplicate Android.bp files must never be
        # left under the source tree where Soong could discover them.
        mv -- "$destination" "$snapshot/$name.before"
    fi
    mv -- "$snapshot/incoming/$name" "$destination"
    # A canonical edit may predate a build of the previous staged snapshot.
    # Preserving that old mtime would let Ninja incorrectly reuse an object
    # compiled from different content. The staging event is the source update.
    find "$destination" -type f -exec touch -- {} +
done

append_once() {
    local file=$1 line=$2 temporary
    grep -Fxq -- "$line" "$file" && return 0
    temporary="$(mktemp "${file}.powerphone-XXXXXX")"
    # Mechanical generated-file update. Preserve all existing content and
    # append after the whole donor body so filter-out sees every package/copy.
    awk -v addition="$line" '1; END { print ""; print "# Cubs PowerPhone research-primary integration (stage-primary-profile.sh)"; print addition }' \
        "$file" > "$temporary"
    chmod --reference="$file" "$temporary"
    mv -- "$temporary" "$file"
}
append_once "$product" "$product_line"
append_once "$board" "$policy_line"
printf 'Staged integration: %s\nBoot helper: %s\nRecoverable prior copies: %s\n' \
    "$generated/powerphone" "$generated/powerphone-boot" "$snapshot"
printf '%s\n' 'This is a source snapshot, not a build or hardware PASS.' \
    'If canonical sources are being edited concurrently, rerun after those edits finish before building.'
