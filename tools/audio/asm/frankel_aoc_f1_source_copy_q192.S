/* Speaker-only replacement of the 48-frame source-copy caller.
 * The callee retains a12 as its frame count across ReadFromSram and uses it
 * for its copy and final SRAM read-pointer advance.  Raising only the nested
 * ReadFromSram argument leaves the copy and advance at 48 frames.
 */
    .section .patch.source_copy, "ax"
    .global source_copy
source_copy:
    l32i a10, a1, 16
    beqz a3, 0x403d3949
    movi a12, 192
    j 0x403d3940

    .section .patch.source_copy_hook, "ax"
    .global source_copy_hook
source_copy_hook:
    j 0x403d3878
