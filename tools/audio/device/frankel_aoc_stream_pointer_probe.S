/*
 * One-shot, reboot-volatile AoC F1 diagnostic trampoline.
 *
 * The probe is entered instead of the first CMD 0x146 instruction.  It records
 * the command handler's Stream object pointer in a separate data cave, repeats
 * the displaced instruction, and returns to the stock instruction stream.
 * This uses only ordinary AoC memory; it never accesses the AP PDM projection.
 */

    .section .probe_literal, "a"
    .align 4
probe_destination:
    .long 0x4038faec

    .section .probe_text, "ax"
    .global probe_entry
probe_entry:
    l32i a11, a2, 0x138
    l32r a10, probe_destination
    s32i a11, a10, 0
    j 0x4038fb59

    .section .probe_route, "ax"
probe_route:
    j probe_entry
