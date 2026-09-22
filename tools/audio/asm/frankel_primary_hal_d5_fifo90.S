// Scoped continuation of the existing D1/D5 playback prefill gate.
// Start() allocates 0x40 bytes and saves x23 at sp+0x10, x22/x21 at
// sp+0x20. Its sp+0x18 slot is unused until an optional error LogMessage
// is constructed after this call returns. Use its first four bytes for
// sched_param; no stack/LR/callee-saved register changes are necessary.
// sched_setscheduler's normal 0/-1 return is consumed by Start(): success
// keeps the full-ring WRITEI autostart, failure follows its PCM-close path.
.section .text.entry,"ax",@progbits
.global powerphone_fifo90_entry
powerphone_fifo90_entry:
    mov w0, #0
    b powerphone_fifo90_priority

.section .text.priority,"ax",@progbits
.global powerphone_fifo90_priority
powerphone_fifo90_priority:
    mov w8, #90
    str w8, [sp, #0x18]
    b powerphone_fifo90_policy

.section .text.policy,"ax",@progbits
.global powerphone_fifo90_policy
powerphone_fifo90_policy:
    mov w1, #1
    movk w1, #0x4000, lsl #16
    b powerphone_fifo90_call

.section .text.call,"ax",@progbits
.global powerphone_fifo90_call
powerphone_fifo90_call:
    add x2, sp, #0x18
    b stock_sched_setscheduler
    .word 0
