// PCM interface minimum-frame getter, vtable slot +0x40. Only the normal
// ALSA path reaches this hook; the alternate interface's original branch
// remains untouched. Advertise 960 for D1/D5 playback without changing
// pcm_config.period_size (192), period_count (20), or capture geometry.
.section .text.hook,"ax",@progbits
.global powerphone_fmq960_hook
powerphone_fmq960_hook:
    b powerphone_fmq960_device

.section .text.device,"ax",@progbits
.global powerphone_fmq960_device
powerphone_fmq960_device:
    ldr w8, [x0, #0x40]
    cmp w8, #5
    b powerphone_fmq960_direction

.section .text.direction,"ax",@progbits
.global powerphone_fmq960_direction
powerphone_fmq960_direction:
    ccmp w8, #1, #4, ne
    ldrb w9, [x0, #0x3c]
    b powerphone_fmq960_original

.section .text.original,"ax",@progbits
.global powerphone_fmq960_original
powerphone_fmq960_original:
    ccmp w9, #1, #0, eq
    ldr w0, [x0, #0x68]
    b powerphone_fmq960_result

.section .text.result,"ax",@progbits
.global powerphone_fmq960_result
powerphone_fmq960_result:
    mov w9, #960
    csel w0, w9, w0, eq
    ret
