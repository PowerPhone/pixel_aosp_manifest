#!/usr/bin/env bash
# Actual Android binary build; never contacts a device.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)
aosp=${AOSP_DIR:-$repo/work/aosp}
clang=${AOSP_CLANG_ROOT:-$aosp/prebuilts/clang/host/linux-x86/clang-r596125}
sysroot=${AOSP_NDK_SYSROOT:-$aosp/out_pixel/frankel/soong/ndk/sysroot}
crtroot=${AOSP_CRT_ROOT:-$aosp/out_pixel/frankel/soong/.intermediates/bionic/libc}
crtvariant=android_vendor_arm64_armv9-a_cortex-a76
out=${1:-$repo/work/audio-research/cubs/bin/cubs_tas_diag}
mkdir -p -- "$(dirname -- "$out")"
"$clang/bin/clang" --target=aarch64-linux-android35 --sysroot="$sysroot" \
    -fPIE -pie -nostartfiles -std=c11 -O2 -Wall -Wextra -Werror \
    "$crtroot/crtbegin_dynamic/$crtvariant/crtbegin_dynamic.o" \
    "$repo/tools/audio/device/cubs_tas_diag/cubs_tas_diag.c" \
    -L "$sysroot/usr/lib/aarch64-linux-android/35" -lc \
    "$crtroot/crtend_android/$crtvariant/crtend_android.o" -o "$out"
printf '%s\n' "$out"
