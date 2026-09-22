/* SPDX-License-Identifier: GPL-2.0-only
 * Reference assembly for Frankel's raw-mailbox GSA unload canary.
 *
 * A normal stock authentication has already succeeded.  Command 92 is sent
 * through the exported legacy GSA mailbox API rather than Trusty HWMGR.  Only
 * a zero return permits the guarded one-byte firmware-body write.  The byte is
 * read back before the callback resumes its normal Trusty GSA_AOC_START path.
 */

        .text
        .org    0x0934
cave:
        ldr     x0, [x19, #0x3c0]
        bl      gsa_unload_aoc_fw_image
        cbnz    w0, reload_bounds
        ldr     x8, [x19, #0x170]
        movz    x10, #0xb665
        movk    x10, #0x00ce, lsl #16
        strb    wzr, [x8, x10]
        dsb     sy
        ldrb    w9, [x8, x10]
        cbnz    w9, reload_bounds
        ldr     x9, [x19, #0x190]
        b       resume_bounds_check
reload_bounds:
        ldr     x9, [x19, #0x190]
        b       resume_bounds_check

        .org    0x0a9c
post_auth_hook:
        b       cave

        .org    0x0aa0
resume_bounds_check:
        add     x8, x8, x20

        .org    0x0ac8
relocation_donor:
        nop
