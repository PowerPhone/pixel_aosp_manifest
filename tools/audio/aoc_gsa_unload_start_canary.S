/*
 * Reference assembly for Frankel's authenticate/unload/GSA-START canary.
 *
 * After successful stock firmware authentication, ask GSA to release the
 * image, change one harmless firmware diagnostic byte through the now-open AP
 * mapping, and return to the callback with its GSA-start selector unchanged.
 * This tests whether GSA retains a startable state after releasing protection.
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
        nop

        .org    0x0ac8
removed_info_log:
        nop

