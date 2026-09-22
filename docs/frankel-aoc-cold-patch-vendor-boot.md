# Frankel corrected cold-audio vendor_boot trial

> **Failed on real hardware:** do not flash or promote this pair.  Frankel
> returned to bootloader fastboot without exposing ADB.  The vendor_boot
> selector worked at the correct partition boundary, but selecting only the
> stock primary init script creates an incomplete, unbootable init graph.

This page records the second negative init-selector experiment for keeping the
AoC capture path cold until a guarded live patch is installed.  Offline image
construction checks passed, but the real device did not boot.

The subsequent v2 candidate supplies a preserved custom primary that imports
the complete normal graph except the two audio service files. It is documented
in
[`frankel-aoc-cold-patch-vendor-boot-v2.md`](frankel-aoc-cold-patch-vendor-boot-v2.md).

The earlier attempt placed the bootconfig in `vendor_kernel_boot`.  Frankel
ignored it and booted normally.  See
[`frankel-aoc-cold-patch-boot.md`](frankel-aoc-cold-patch-boot.md) for that
negative result.  Android's local build rules and the stock images establish
that Frankel consumes `BOARD_BOOTCONFIG` from `vendor_boot`.

## Build and output

Build without flashing:

```bash
tools/audio/build_frankel_cold_audio_vendor_boot_trial.sh
```

The guarded default output is:

```text
work/audio-research/frankel/host-timer-500us-ep3-192k-cold-audio-vendor-boot/trial-1/
```

It retains the following negative-test artifacts:

- candidate `vendor_boot.img` and paired root `vbmeta.img`;
- the exact resulting `bootconfig.cold-audio`;
- base and candidate unpack reports plus `build-audit.txt`;
- rollback-only `FLASHING.txt` and an explicit `DO_NOT_FLASH.txt` marker; and
- a self-contained `rollback/vendor_boot.img` and `rollback/vbmeta.img` pair.

The builder consumes only the exact currently matched state.  In particular,
the root-vbmeta input already authenticates the retained vendor-kernel-boot
whose file SHA-256 is:

```text
a6ddbcafa591a7797d7e442200e36f2be5596c9748ea44500a1a397afae1f957
```

The corrected trial does not modify or package a replacement
`vendor_kernel_boot.img`.

## Exact change and why it cannot boot

The matched vendor_boot bootconfig contains:

```text
androidboot.load_modules_parallel=true
androidboot.boot_devices=3c400000.ufs
```

The candidate retains both lines and appends exactly:

```text
androidboot.init_rc=/system/etc/init/hw/init.rc
```

Android init maps this to `ro.boot.init_rc`.  `LoadBootScripts()` then parses
only `/system/etc/init/hw/init.rc` instead of automatically scanning the
partition init directories.  That suppresses the standalone files defining
`audioserver` and `vendor.audio-hal-aidl`, but it also suppresses critical
service definitions required by the primary script itself.

For example, the primary script executes or starts `init_dev_config`,
`apexd-bootstrap`, `servicemanager`, `hwservicemanager`, and many other
services whose definitions reside in the skipped init directories.  It later
starts the explicitly imported zygote without a complete service-manager and
APEX environment.  Zygote is a critical service with the `zygote-fatal`
target.  This incomplete dependency graph explains the observed reboot back
to bootloader fastboot.

## Failed device result

The exact candidate vendor_boot/root-vbmeta pair was flashed while retaining
the matched vendor-kernel-boot.  The device returned to bootloader fastboot
and never exposed ADB.  Do not retry this pair.  A usable selector approach
would require a custom mounted second-stage init script that imports the
normal service graph and disables only the two audio services; the stock
primary script alone cannot express that selective scan.

## Rollback

Rollback does not depend on another work directory:

```bash
fastboot flash vendor_boot rollback/vendor_boot.img
fastboot flash vbmeta rollback/vbmeta.img
fastboot reboot
```

This restores the exact vendor_boot/root-vbmeta state that was paired with the
retained vendor-kernel-boot before the corrected trial.

## Offline construction guarantees

The builder:

1. guards all three exact inputs: vendor_boot, current vendor-kernel-boot, and
   its paired root vbmeta;
2. unpacks vendor_boot and guards its ramdisk, bootconfig, and command line;
3. reconstructs the complete authenticated raw portion byte-for-byte before
   accepting the parsed header arguments;
4. appends only the init selector, keeping the AVB-declared 24,332,288-byte
   raw size unchanged;
5. adds the vendor_boot AVB footer and creates a paired signed root vbmeta;
6. proves the root vbmeta still contains the current vendor-kernel-boot
   digest; and
7. re-unpacks the signed candidate and rechecks the resulting bootconfig,
   ramdisk, and command line.

These checks establish that packing and AVB pairing were correct.  They do not
make the primary-only init graph bootable.
