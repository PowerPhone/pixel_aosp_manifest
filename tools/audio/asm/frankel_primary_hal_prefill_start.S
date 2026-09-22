// AArch64 primary HAL startup gate. Only playback PCMs D1/D5 defer START
// until WRITEI reaches the configured full 3840-frame start threshold.
// Other PCMs tail-call the original pcm_start PLT entry with x0/LR intact.
.section .text.hook,"ax",@progbits
.global powerphone_start_hook
powerphone_start_hook:
    bl powerphone_start_gate

.section .text.gate,"ax",@progbits
.global powerphone_start_gate
powerphone_start_gate:
    ldr w8, [x19, #0x40]
    cmp w8, #5
    b powerphone_start_device

.section .text.device,"ax",@progbits
.global powerphone_start_device
powerphone_start_device:
    ccmp w8, #1, #4, ne
    ldrb w9, [x19, #0x3c]
    b powerphone_start_direction

.section .text.direction,"ax",@progbits
.global powerphone_start_direction
powerphone_start_direction:
    ccmp w9, #1, #0, eq
    b.ne stock_pcm_start
    b powerphone_start_deferred

.section .text.deferred,"ax",@progbits
.global powerphone_start_deferred
powerphone_start_deferred:
    mov w0, #0
    b rate_helper_ret
