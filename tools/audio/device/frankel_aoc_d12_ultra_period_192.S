/*
 * Frankel Fullband Ultrasonic period-cadence adjustment for native 192 kHz.
 *
 * Link at F1 runtime address 0x403f0c70.  The stock processor counts one
 * invocation as one millisecond because one invocation consumes 96 frames at
 * 96 kHz.  The two-pass 192 kHz shim invokes it twice per millisecond.  Double
 * config byte 14 before storing it as this+0x81d so period notification and
 * output-ring capacity remain expressed in wall-clock milliseconds.
 */

    .text
    .align  1

    .set    stock_store_period_geometry, 0x403e8684

    .global frankel_aoc_d12_ultra_period_192
frankel_aoc_d12_ultra_period_192:
    l8ui    a7, a3, 15
    l8ui    a15, a3, 14
    slli    a15, a15, 1
    j       stock_store_period_geometry
