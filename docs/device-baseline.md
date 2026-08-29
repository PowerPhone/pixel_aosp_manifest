# Pixel 11 (`cubs`) validation baseline

This record deliberately omits the device serial number. It captures the state
observed before any development image was flashed.

## Hardware and firmware

- Product/model: `cubs` / Pixel 11
- SKU: `GPQQ7` (US mmWave)
- Hardware revision: `MP1.0`
- Observed memory/storage capacity: 12 GB / 256 GB
- Bootloader: `spacecraft-17.4-15938155`
- Baseband: `a900a-MP_260716-260716-M-15880348`
- Stock build: `CD1A.260714.001.A9`
- Stock security patch level: `2026-08-05`
- Kernel: `6.12.69-android16-6-g5c5f2fea42dd-ab15835541-4k`
- Bootloader state: unlocked; production fuses; Verified Boot orange state

The exact bootloader and baseband match the checks in the downloaded factory
package's `android-info.txt`.

## Partition and Treble observations

- Active slot: `a`, marked bootable and successful before bring-up.
- Slot `b`: initially marked unbootable by the stock virtual A/B layout. This
  bring-up used the separately documented direct physical-B preparation and
  fastbootd-only trial; it did not install or boot a complete Android B.
- Super partition: 10 GiB, unslotted, with slotted logical `system`,
  `system_dlkm`, `system_ext`, `product`, `vendor`, and `vendor_dlkm` partitions.
- Virtual A/B and compression: enabled; no snapshot merge was in progress.
- System, product, vendor, system_ext, system_dlkm, and vendor_dlkm use EROFS.
- Architecture: ARM64-only (`arm64-v8a`), 4 KiB kernel page size.
- Treble: enabled; vendor API level `202604`; first API level 37.

The stock system fingerprint identifies `generic_system_google`, which is a
strong compatibility signal for an Android 17 ARM64 GSI. It is not, by itself,
proof that a locally built userdebug image will boot.

Fresh `lpdump -a` inspection of exact stock showed that each slot-0 A logical
view and slot-1 B logical view begins on the same physical `super` extent: this
was true for `system`, `system_dlkm`, `system_ext`, `product`, `vendor`, and
`vendor_dlkm`. `Update state: none` proved that this was the settled layout,
not an in-progress merge. Consequently, an explicit logical `_a` write also
changes physical blocks referenced by B. Healthy B boot flags after that write
are stale metadata, not proof of a bootable B Android installation.

| Logical class | A first `super` sector | B first `super` sector |
| --- | ---: | ---: |
| `system` | 2048 | 2048 |
| `system_dlkm` | 3043328 | 3043328 |
| `system_ext` | 3069952 | 3069952 |
| `product` | 4091904 | 4091904 |
| `vendor` | 14159872 | 14159872 |
| `vendor_dlkm` | 16392192 | 16392192 |

## Recovery invariant

The known-good recovery input is Google's complete, checksum-verified
`CD1A.260714.001.A9` factory package. A complete duplicate fallback installation
cannot fit in the 10 GiB virtual A/B super partition because the active stock
logical images already consume substantially more than half of it. Recovery is
therefore based on retained bootloader access and the matching factory package,
not on treating slot `b` as a second full installation. Before development, the
direct route attested exact stock A, wrote the checksum-pinned factory payloads
only to the 34 physical B partitions, and verified that path with a one-shot
fastbootd trial before returning to bootloader fastboot. It never booted Android
B. After shared-super changes, recovery preserves the 25 physical B firmware
partitions and nine B boot/recovery partitions as a lifeboat and explicitly
reconstructs stock A from the factory archive.
