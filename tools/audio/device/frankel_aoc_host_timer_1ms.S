/* Reviewed AArch64 encodings used by patch_frankel_aoc_host_timer_1ms.py. */

.text
.global frankel_aoc_host_timer_stock_10ms
.type frankel_aoc_host_timer_stock_10ms, %function
frankel_aoc_host_timer_stock_10ms:
    mov  w8, #0x9680
    movk w8, #0x0098, lsl #16
    ret

.global frankel_aoc_host_timer_fast_1ms
.type frankel_aoc_host_timer_fast_1ms, %function
frankel_aoc_host_timer_fast_1ms:
    mov  w8, #0x4240
    movk w8, #0x000f, lsl #16
    ret

.global frankel_aoc_host_timer_fast_500us
.type frankel_aoc_host_timer_fast_500us, %function
frankel_aoc_host_timer_fast_500us:
    mov  w8, #0xa120
    movk w8, #0x0007, lsl #16
    ret
