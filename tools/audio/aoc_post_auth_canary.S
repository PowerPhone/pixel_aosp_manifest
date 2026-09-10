/*
 * Reference assembly for the guarded Frankel AoC post-authentication canary.
 *
 * This is assembled only to audit instruction encodings used by the binary
 * patcher.  The real addresses are section-relative offsets in aoc_core.ko:
 * post_auth = 0x0a9c, cave = 0x0934, resume = 0x0aa0.
 */

        .text
        .org    0x0934
cave:
        movz    x9, #0xb665
        movk    x9, #0x00ce, lsl #16
        movz    w10, #0x0058
        strb    w10, [x8, x9]
        dsb     sy
        ldr     x9, [x19, #0x190]
        b       resume

        .org    0x0a9c
        .global post_auth_branch
post_auth_branch:
        b       cave

        .org    0x0aa0
resume:
        nop
