#!/usr/bin/env bash
# Actual Android native build only; does not install or touch a device.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
aosp=${AOSP_DIR:-$repo/work/aosp}
clang=${AOSP_CLANG_ROOT:-$aosp/prebuilts/clang/host/linux-x86/clang-r596125}
sysroot=${AOSP_NDK_SYSROOT:-$aosp/out_pixel/frankel/soong/ndk/sysroot}
crtroot=${AOSP_CRT_ROOT:-$aosp/out_pixel/frankel/soong/.intermediates/bionic/libc}
crtvariant=android_vendor_arm64_armv9-a_cortex-a76
out=${1:-$repo/work/audio-research/cubs/bin/cubs_powerphone_boot}
python3 "$repo/tools/audio/cubs/generate_boot_profile.py"
mkdir -p -- "$(dirname -- "$out")"
"$clang/bin/clang++" --target=aarch64-linux-android35 --sysroot="$sysroot" \
    -fPIE -pie -nostartfiles -nostdlib++ -std=c++20 -O2 -Wall -Wextra -Werror \
    -isystem "$clang/include/c++/v1" \
    "$crtroot/crtbegin_dynamic/$crtvariant/crtbegin_dynamic.o" \
    "$repo/tools/audio/device/cubs_powerphone_boot/cubs_powerphone_boot.cpp" \
    "$clang/android_libc++/platform/aarch64/lib/libc++_static.a" \
    "$clang/android_libc++/platform/aarch64/lib/libc++abi.a" \
    "$clang/runtimes_ndk_cxx/aarch64/libunwind.a" \
    -L "$sysroot/usr/lib/aarch64-linux-android/35" -ldl -lm -lc \
    "$crtroot/crtend_android/$crtvariant/crtend_android.o" -o "$out"
printf '%s\n' "$out"
