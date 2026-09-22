/*
 * Reference assembly for the guarded Frankel AoC GSA-unload canary.
 *
 * The binary patcher authenticates the unmodified stock AoC image first.  It
 * then asks GSA to unload the image, installs the stock non-GSA IOMMU/reset
 * setup, changes one diagnostic string byte in AoC DRAM, and takes the
 * existing direct reset-release path.  This file exists solely to audit the
 * AArch64 encodings and branch targets emitted by the patcher.
 */

        .text
        .org    0x0934
cave:
        ldr     x0, [x19, #0x3c0]
        bl      gsa_unload_aoc_fw_image
        mov     x0, x19
        mov     x1, x22
        bl      aoc_configure_iommu
        mov     x0, x22
        bl      write_reset_trampoline
        ldr     x8, [x19, #0x170]
        movz    x9, #0xb665
        movk    x9, #0x00ce, lsl #16
        strb    wzr, [x8, x9]
        dsb     sy
        mov     w21, wzr
        ldr     x9, [x19, #0x190]
        b       resume_bounds_check

        .org    0x0a9c
post_auth_hook:
        b       cave

        .org    0x0aa0
resume_bounds_check:
        nop

        .org    0x0ac8
clear_gsa_protection_flag:
        strb    wzr, [x19, #0x3c8]

        .org    0x1a0c
aoc_configure_iommu:
        nop

        .org    0x1bc4
write_reset_trampoline:
        nop
