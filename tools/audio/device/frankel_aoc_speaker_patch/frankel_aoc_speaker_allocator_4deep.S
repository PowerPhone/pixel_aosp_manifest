/* SPDX-License-Identifier: Apache-2.0 */
/*
 * One-shot F1 allocator body for the proven native-q192 speaker layout.
 * Original standalone allocator reference, superseded for early boot by
 * frankel_aoc_speaker_coherence.S/.ld. The native six-word temporary body at
 * 0x403e87d0 now tail-dispatches through literal0x403e7818 to its guarded
 * extension0x40371590. That extension refuses duplicate allocation, publishes
 * through DHWB+MEMW, and invalidates the HD Mic dispatch D-cache line.
 * Do not assemble this historical body into the current native helper.
 */

    .section .allocation_body,"ax"
    .align 4
    .global frankel_aoc_speaker_allocator_4deep
frankel_aoc_speaker_allocator_4deep:
    entry a1, 32
    movi.n a10, 64
    movi.n a11, 48
    slli a11, a11, 8
    l32r a8, aligned_alloc_literal
    callx8 a8
    l32r a4, scratch_address
    s32i.n a10, a4, 0
    retw.n

    .set aligned_alloc_literal, 0x403c4030
    .set scratch_address, 0x403e7814
