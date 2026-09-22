/*
 * Reference assembly for Frankel's authenticate/unload/release-reset canary.
 *
 * After successful stock firmware authentication, ask GSA to unload the
 * image, change one harmless firmware diagnostic byte through the now-open AP
 * mapping, and continue through the stock callback.  The stock secure-boot
 * call site is retained but its command selector is changed from GSA_AOC_START
 * (1) to GSA_AOC_RELEASE_RESET (5).  No direct PCU/reset MMIO is performed.
 */

        .text
        .org    0x0934
cave:
        ldr     x0, [x19, #0x3c0]
        bl      gsa_unload_aoc_fw_image
        ldr     x8, [x19, #0x170]
        movz    x9, #0xb665
        movk    x9, #0x00ce, lsl #16
        strb    wzr, [x8, x9]
        dsb     sy
        ldr     x9, [x19, #0x190]
        b       resume_bounds_check

        .org    0x0a9c
post_auth_hook:
        b       cave

        .org    0x0aa0
resume_bounds_check:
        add     x8, x8, x20

        .org    0x0ac8
removed_info_log:
        nop

        .org    0x0af0
release_reset_command:
        mov     w1, #5
