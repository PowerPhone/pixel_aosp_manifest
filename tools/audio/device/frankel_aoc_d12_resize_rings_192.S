/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Frankel AoC F1 setup wrapper for the native D12 192 kHz path.
 *
 * The stock native PDM DMA ring and Fullband Ultrasonic input ring each hold
 * two 0x600-byte (96-frame, four-channel S32) blocks.  A 192-frame block is
 * 0xc00 bytes, so retain the same two-block geometry by assigning 0x1800
 * bytes to each ring.  One aligned 0x3000-byte allocation supplies both.
 *
 * This wrapper replaces the SetUpMicCapture call inside
 * ControllerAudioInput::SetUp.  It must only be installed with the companion
 * callback-vtable redirect because stage 1 reuses the old callback body.
 */

    .section .orig_literal,"a"
    .align 4
orig_setup:
    .word 0x78981694
ring_assign:
    .word 0x403824dc

    .section .stage1,"ax"
    .align 4
    .global frankel_aoc_d12_resize_rings_stage1
frankel_aoc_d12_resize_rings_stage1:
    entry a1, 32
    l32r a8, orig_setup
    mov.n a10, a2
    callx8 a8

    movi.n a10, 64
    movi.n a11, 48
    slli a11, a11, 8
    l32r a8, aligned_alloc_literal
    callx8 a8
    beqz a10, allocation_failed
    mov.n a4, a10
    j frankel_aoc_d12_resize_rings_stage2

    .section .stage2,"ax"
    .global frankel_aoc_d12_resize_rings_stage2
frankel_aoc_d12_resize_rings_stage2:
    l32i a5, a2, 0x1f0
    l32r a6, ring_assign
    movi.n a7, 24
    slli a7, a7, 8
    l32i a10, a5, 0x150
    mov.n a11, a4
    mov.n a12, a7
    callx8 a6
    l32i a10, a5, 0x15c
    addmi a11, a4, 0x1800
    mov.n a12, a7
    callx8 a6
    retw.n

    .set aligned_alloc_literal, 0x403c4030
    .set allocation_failed, 0x403e87a8
