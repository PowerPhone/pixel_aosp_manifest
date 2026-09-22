/*
 * Recovered H0 AudioMixerPlayback cadence wrapper for Frankel AoC
 * CP2A.260805.005. This is an offline review source, not loadable firmware.
 *
 * The first form is the exact 0x600-byte-geometry prototype recovered from
 * its surviving Python bytecode. The live q192 source-5 profile currently
 * exposes 0xf00 at AMixSPKR+0x38c, so the comparison must be relinked for
 * that geometry before use.
 */

    .section .text, "ax"
    .global h0_speaker_cadence_600_recovered
h0_speaker_cadence_600_recovered:
    .byte 0x36,0x21,0x00,0x58,0x02,0x52,0x25,0x15
    .byte 0x52,0xd5,0xe5,0x52,0xc5,0x78,0x72,0xd2
    .byte 0x03,0x72,0x27,0x23,0x62,0xa6,0x00,0x67
    .byte 0x97,0x12,0x62,0xa0,0x04,0xbd,0x03,0xad
    .byte 0x02,0xe0,0x05,0x00,0x0b,0x66,0x56,0x36
    .byte 0xff,0x1d,0xf0,0x00,0x00,0xbd,0x03,0xad
    .byte 0x02,0xe0,0x05,0x00,0x1d,0xf0

    .section .h0_cadence_f00, "ax"
    .align 4
    .global h0_speaker_cadence_f00
h0_speaker_cadence_f00:
    entry a1, 16
    l32i.n a5, a2, 0
    l32i a5, a5, 84
    addmi a5, a5, -0x1b00
    addi a5, a5, 120
    addmi a7, a2, 0x300
    l32i a7, a7, 140
    movi a6, 0x780
    slli a6, a6, 1
    bne a7, a6, .Lstock_once
    movi a6, 4
.Lfour_calls:
    mov.n a11, a3
    mov.n a10, a2
    callx8 a5
    addi.n a6, a6, -1
    bnez a6, .Lfour_calls
    retw.n
    .align 4
.Lstock_once:
    mov.n a11, a3
    mov.n a10, a2
    callx8 a5
    retw.n

    /* Current boot helper geometry cave, retained here for joint review. */
    .section .h0_geometry_period1, "ax"
    .global h0_speaker_geometry_period1
h0_speaker_geometry_period1:
    .byte 0x0b,0xe3,0x30,0xf3,0x90,0xcc,0x7e,0x60
    .byte 0xa2,0x24,0x66,0x7a,0x02,0xe0,0xff,0x11
    .byte 0x86,0x3b,0xe7,0x00
