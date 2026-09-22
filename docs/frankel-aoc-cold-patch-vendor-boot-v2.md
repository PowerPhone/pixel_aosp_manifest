# Frankel cold-audio vendor_boot v2 trial

> **Offline-ready, not device-verified:** this pair has passed guarded image,
> AVB, and local Android-init syntax checks. It has not been flashed. Treat it
> as a trial until a complete ADB boot proves that both audio services were
> never defined or executed.

This v2 trial keeps the AoC audio path cold before a guarded live patch while
preserving Frankel's normal second-stage init graph. It replaces neither the
system nor vendor partition. Instead, it uses the effective `vendor_boot`
bootconfig to select a generated primary init script that imports the exact
normal CP2A.260805.005 init inventory except the two files defining:

- `audioserver`; and
- `vendor.audio-hal-aidl`.

The prior vendor_boot experiment selected only the stock primary init script.
That skipped every partition init directory and returned the device to
bootloader fastboot. It remains documented as a negative result in
[`frankel-aoc-cold-patch-vendor-boot.md`](frankel-aoc-cold-patch-vendor-boot.md).

## Build and artifact

Build without flashing:

```bash
tools/audio/build_frankel_cold_audio_vendor_boot_v2_trial.sh
```

The guarded default output is:

```text
work/audio-research/frankel/host-timer-500us-ep3-192k-cold-audio-vendor-boot-v2/trial-1/
```

Flash candidates:

```text
vendor_boot.img
vbmeta.img
```

The same directory contains `FLASHING.txt`, the generated primary script,
the full and active import inventories, unpack/AVB audits, and a self-contained
exact rollback pair under `rollback/`.

The first offline build produced:

```text
vendor_boot.img  355859fee5d618dfe85a7e7621965d7db3d17a7c21c0652c98744abbf9d75c7d
vbmeta.img       dfb430b39bf69a3691ecd65c7af71bd8eadab5ad1540cf5b6398b0309fef0d30
```

It deliberately retains the already-flashed vendor-kernel-boot:

```text
file SHA-256       a6ddbcafa591a7797d7e442200e36f2be5596c9748ea44500a1a397afae1f957
descriptor digest  5382bb0d9ec46cf49c50c9227dd8384a331d751e3e351b659a0871a7796810d5
```

## Design

Android's first-stage init preserves one file from the disposable boot
ramdisk across switch-root:

```text
/system/etc/ramdisk/build.prop
    -> /second_stage_resources/system/etc/ramdisk/build.prop
```

The builder appends a tiny newc overlay to the byte-exact original vendor
ramdisk, replacing that file with a property/init polyglot, and adds this
effective vendor_boot bootconfig entry:

```text
androidboot.init_rc=/second_stage_resources/system/etc/ramdisk/build.prop
```

Property loading accepts only the literal prefix `import ` and assignments
containing `=`. The generated carrier has neither: init imports use a tab
separator, while boot-image properties are translated to `setprop` commands
in an `early-init` action. Android init's tokenizer treats the same tab as
ordinary whitespace. This keeps property parsing inert while giving
second-stage init a valid primary script.

The generated primary imports the guarded 196-file normal Frankel inventory
in its normal partition order after removing exactly:

```text
/system/etc/init/audioserver.rc
/vendor/etc/init/android.hardware.audio.service-aidl.aoc.rc
```

There are therefore 194 active imports. The services are absent, not merely
stopped. This avoids their `init.svc.*=stopped` triggers and guarantees that
neither executable is launched before the AoC patch if the device gate passes.
All other matched system, system_ext, and vendor init files remain in the
parse graph.

## Offline guarantees

The builder fails closed unless all exact inputs and init inventories match.
It then:

1. reconstructs the base vendor_boot raw image byte-for-byte;
2. validates the generated carrier with the local AOSP 17
   `host_init_verifier`;
3. keeps the original vendor ramdisk as a byte-exact prefix and appends only
   the overlay archive;
4. re-unpacks the candidate and compares its bootconfig and decompressed
   ramdisk against the generated inputs;
5. signs vendor_boot and creates its paired signed root vbmeta;
6. updates the vendor_boot descriptor's raw size and digest; and
7. proves that the current vendor-kernel-boot descriptor remains unchanged.

The relevant local AOSP implementation is in
`system/core/init/first_stage_init.cpp`, `second_stage_resources.h`,
`property_service.cpp`, `init.cpp`, and `host_import_parser.cpp`. In
particular, `LoadBootScripts()` parses only `ro.boot.init_rc` when set, so the
custom primary must import the complete normal graph itself.

## Device trial and acceptance gate

Only use the matched pair while vendor-kernel-boot still has the file hash
shown above:

```bash
fastboot flash vendor_boot vendor_boot.img
fastboot flash vbmeta vbmeta.img
fastboot reboot
```

Wait for a complete ADB boot, then run every check in `FLASHING.txt`. The hard
acceptance conditions are:

- `ro.boot.init_rc` and `/proc/bootconfig` select the preserved carrier;
- `sys.boot_completed=1`;
- both `init.svc.*` and `ro.boottime.*` properties for the target services are
  empty, proving the services were never defined; and
- neither executable has a PID.

Do not patch AoC after any failed condition.

## Rollback

From bootloader fastboot, restore the self-contained exact prior pair:

```bash
fastboot flash vendor_boot rollback/vendor_boot.img
fastboot flash vbmeta rollback/vbmeta.img
fastboot reboot
```

Rollback leaves vendor-kernel-boot untouched.
