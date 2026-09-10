# Frankel AoC cold-patch boot

> **Failed on real hardware:** do not flash or promote this image pair.  On
> Frankel, both `audioserver` and `vendor.audio-hal-aidl` ran and
> `sys.boot_completed` reached `1`.  The embedded vendor_kernel_boot
> bootconfig did not produce the intended cold-audio init behavior.

The corrected experiment places the selector in the effective `vendor_boot`
partition and is documented in
[`frankel-aoc-cold-patch-vendor-boot.md`](frankel-aoc-cold-patch-vendor-boot.md).

This page records a negative boot-chain experiment.  The trial attempted to
prevent Android's normal audio services from being defined before an AoC live
patch, but real-device evidence disproved that mechanism on Frankel.

## Artifact

Build without flashing:

```bash
tools/audio/build_frankel_ep3_capture_192k_host_timer_500us_cold_audio_trial.sh
```

The guarded default output is:

```text
work/audio-research/frankel/host-timer-500us-ep3-192k-cold-audio/trial-1/
```

It contains the paired `vendor_kernel_boot.img` and `vbmeta.img`, an audit,
the exact bootconfig, a `DO_NOT_FLASH.txt` marker, and rollback instructions.
It is retained only so the failed experiment is reproducible.  The builder
refuses to overwrite an existing trial or consume anything except the exact
`host-timer-500us-ep3-192k/trial-1` parent images.

## Why an init rc in vendor_kernel_boot is not sufficient

The v4 vendor-kernel ramdisk participates in first-stage init.  It is not a
second-stage init partition: `first_stage_init.cpp` switches root and calls
`FreeRamdisk()` on the old root.  A new loose `.rc` member in that ramdisk
would therefore disappear before second-stage `LoadBootScripts()` and would
never define or override a service.

Second-stage init normally parses the primary
`/system/etc/init/hw/init.rc`, then scans `/system/etc/init`,
`/system_ext/etc/init`, `/vendor/etc/init`, `/odm/etc/init`, and
`/product/etc/init`.  If `ro.boot.init_rc` is nonempty, however,
`LoadBootScripts()` parses only that named primary script and skips those
directory scans.

Android init maps any bootconfig key prefixed by `androidboot.` to the
corresponding `ro.boot.` property.  The candidate therefore adds exactly:

```text
androidboot.init_rc=/system/etc/init/hw/init.rc
```

The built image contains that input and no system or vendor partition is
modified.  Real Frankel hardware did not apply it as the expected
second-stage-init selector.

The local Android build rules explain the failure.  `bootimg.go` accepts a
`Bootconfig` property only when the image type is exactly `vendor_boot`; it
rejects that property for `vendor_kernel_boot`.  The generated Frankel
`vendor_boot.img` contains the normal `BOARD_BOOTCONFIG` entries, while the
generated `vendor_kernel_boot.img` has an empty bootconfig.  The
vendor-kernel-boot factory likewise supplies its ramdisk and DTB but no
bootconfig module.  Manually adding a syntactically valid field made it
visible to `unpack_bootimg`, but not to the device's effective kernel
bootconfig.  On this platform, `vendor_kernel_boot` therefore cannot deliver
an `androidboot.init_rc` property to second-stage init.

A future init-selector experiment would have to modify `vendor_boot.img` and
its paired root vbmeta, or modify a mounted second-stage init partition.  That
is a different image pair and was not pursued because the active work moved
to the cold-geometry cache-flush hook.

## Expected behavior and actual result

The selected primary script explicitly imports the environment, generic USB,
hardware-specific vendor init, USB configfs, and zygote scripts.  In the
Frankel userdebug build, the USB scripts define and start `adbd`, so this boot
is expected to expose root-capable ADB.

It does not scan the files that define these two services:

```text
/system/etc/init/audioserver.rc
/vendor/etc/init/android.hardware.audio.service-aidl.aoc.rc
```

Had the selector taken effect, `audioserver` and `vendor.audio-hal-aidl` would
have remained undefined.  Instead, on the real device both services ran and
the framework reached `sys.boot_completed=1`.  This trial therefore did not
keep the targeted AoC firmware path cold and must not be used for live-patch
qualification.

The checks below describe the acceptance gate that the device failed:

```bash
adb wait-for-device
adb root
adb wait-for-device
test "$(adb shell getprop ro.boot.init_rc | tr -d '\r')" = \
  /system/etc/init/hw/init.rc
test -z "$(adb shell getprop init.svc.audioserver | tr -d '\r')"
test -z "$(adb shell getprop init.svc.vendor.audio-hal-aidl | tr -d '\r')"
test -z "$(adb shell pidof audioserver | tr -d '\r')"
test -z "$(adb shell pidof android.hardware.audio.service-aidl.aoc | tr -d '\r')"
```

Do not proceed to an AoC patch from this image.  Use the separately developed
cold-geometry cache-flush hook instead of this init-selector experiment.

## Image construction detail

The parent's AVB descriptor fixes the raw vendor_kernel_boot image size at
6,760,448 bytes, and its original packed ramdisk leaves no additional 2 KiB
page for bootconfig.  The builder deterministically reorders otherwise
unchanged cpio members (directories first, remaining entries by size),
normalizes archive timestamps, and applies legacy LZ4 high compression.  It
then:

1. compares the extracted repack against the input ramdisk;
2. checks the exact 500 us and EP3-192k audio-module states;
3. rebuilds the image with the one-line bootconfig and the original DTB;
4. pads it to the unchanged 6,760,448-byte guarded size;
5. adds the AVB footer and signs a paired root vbmeta with the new digest; and
6. re-unpacks the signed candidate to check its bootconfig, DTB, and module.

No parent trial was modified.  The failed output's `FLASHING.txt` now contains
rollback commands only.
