/* SPDX-License-Identifier: Apache-2.0 */
/*
 * One-shot allocator trigger for Frankel's native D12 192 kHz rings.
 *
 * MIC_DMA_RING and MIC_US_RING are RingBufferStatic objects.  They must never
 * be passed to RingBufferDynamic::Assign: the dynamic class interprets the
 * static object's inline size word as a mutex pointer.  Instead, this
 * qualification helper performs only aligned_alloc(64, 0x3000) during one
 * sacrificial D12 open and publishes the returned address in an otherwise
 * unused word.  After that PCM is closed, the host-side guarded commit updates
 * the two static backing pointers and their idle descriptors directly.
 *
 * The full D12 profile redirects the callback vtable away from the stock body
 * at 0x403e87d0, making that 32-byte body available for this temporary entry.
 * Windowed return publishes the Stream pointer in caller a11 so the normal
 * command handler can complete the sacrificial open with stock-size rings.
 */

    .section .scratch_literal,"a"
    .align 4
scratch_address:
    .word 0x403f64a0
    .word 0x50313932              /* "P192" install marker */

    .section .allocation_body,"ax"
    .align 4
    .global frankel_aoc_d12_allocation_body
frankel_aoc_d12_allocation_body:
    entry a1, 32
    l32i a3, a2, 0x138
    movi.n a6, 7
    s8i a6, a3, 124

    movi.n a10, 64
    movi.n a11, 48
    slli a11, a11, 8
    l32r a8, aligned_alloc_literal
    callx8 a8
    l32r a4, scratch_address
    s32i.n a10, a4, 0
    retw.n

    .section .command_cave,"ax"
    .global frankel_aoc_d12_allocation_command_cave
frankel_aoc_d12_allocation_command_cave:
    mov.n a10, a2
    call8 allocation_body
    j command_resume
    .space 4

    /* This existing literal contains the aligned allocator entry 0x4040bf40. */
    .set aligned_alloc_literal, 0x403c4030
    .set allocation_body, 0x403e87d0
    .set command_resume, 0x4038fb59
