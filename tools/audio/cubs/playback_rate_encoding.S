/* Inspected live Cubs aoc_alsa_dev_util.ko only. No function calls or stack
 * changes. Add an exact D5-only high-rate branch to the existing default case.
 * All original low-rate branches, capture logic and entrypoint IDs survive.
 */
.text
.org 0xd4cc
    b cubs_d5_playback_rate
.Loriginal_continue:
.org 0x16d00
.global cubs_d5_playback_rate
cubs_d5_playback_rate:
    mov w8, #5
    ldr w9, [x19, #216]
    cmp w9, #5
    b.ne .Loriginal_continue
    mov w9, #48000
    cmp w2, w9, lsl #1
    cinc w8, w8, eq
    cmp w2, w9, lsl #2
    mov w9, #7
    csel w8, w9, w8, eq
    b .Loriginal_continue
