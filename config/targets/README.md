# Target profiles

The checked-in profile allowlist currently contains:

| `PIXEL_TARGET` | Phone / platform | Product target | Implemented scope |
| --- | --- | --- | --- |
| `cubs` | Pixel 11 / Malibu | `cubs-aosp_current-userdebug` | Complete-device workflow and the legacy Cubs-bound GSI/recovery/runtime stack |
| `frankel` | Pixel 10 / Laguna | `frankel-aosp_current-userdebug` | Hardened complete bundle completed two real-device boots and two 66-pass/zero-failure runtime gates; broader end-to-end qualification remains partial |

Each `release.env` owns the target's codename, marketing name, platform, lunch
target, stock donor identity, firmware requirements, and factory/OTA pins.
Shared AOSP, deterministic-build, adevtool, and host-toolchain pins live in
[`../release.env`](../release.env). The loader in
[`../../scripts/lib/target-profile.sh`](../../scripts/lib/target-profile.sh)
accepts only the two directories above and checks that
`DEVICE_PRODUCT_TARGET` is exactly
`$DEVICE_CODENAME-aosp_current-userdebug`.

Select a target explicitly with `PIXEL_TARGET`. An unset value currently
defaults to `cubs` solely to preserve existing Pixel 11 commands. The attached
USB product is validation input, never a substitute for target selection.

Do not share AVB topology, firmware lists, fstab transforms, packaging policy,
or recovery state between platforms. Frankel uses one root `vbmeta` with
exactly 12 direct OS descriptors and no chain descriptors; Cubs uses its own
Malibu child-vbmeta/firmware-descriptor graph. The legacy GSI packager, static
validator, runtime validator, and recovery-anchor/restore tools remain
Cubs-only and are not Frankel hooks.

Frankel also selects two source-level Laguna compatibility adapters that must
not leak into the generic GSI or an unrelated device profile: missing standard
feature-prebuilt definitions (including Wi-Fi Aware and Wi-Fi RTT), and the
product-selected `PixelAospGservicesFlagsProvider` used only by the extracted
Pixel eUICC support app on this GSF-free AOSP product. See
[`../../docs/frankel-build-and-flash.md`](../../docs/frankel-build-and-flash.md)
for their exact scope and
[`../../docs/frankel-validation.md`](../../docs/frankel-validation.md) for the
checksum-identified hardware evidence and remaining limits.

Pixel 9 support is roadmap only. No Pixel 9 profile exists, and one must not be
added until its actual codename, platform, donor, partition/AVB topology,
target hooks, and hardware recovery plan have been reviewed. See
[`../../docs/multi-target-layout.md`](../../docs/multi-target-layout.md) for the
current layout and migration boundary.
