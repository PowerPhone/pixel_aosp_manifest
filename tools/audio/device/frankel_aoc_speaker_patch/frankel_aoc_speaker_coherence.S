/* SPDX-License-Identifier: Apache-2.0 */
/* CP2A.260805.005 early-boot candidate; exact padding bounds are guarded
 * by the native helper. No generic cache primitive is modified.
 */
    .begin no-transform
    .section .cache_literals,"ax"
cache_function:
    .word 0x40486de0
cache_dispatch:
    .word 0x4038ea50

    .section .cache_body,"ax"
    .global speaker_coherent_cache_flush
speaker_coherent_cache_flush:
    entry a1, 32
    l32r a8, cache_function
    callx8 a8
    l32r a4, cache_dispatch
    dhu a4, 0
    dhi a4, 0
    memw
    movi.n a2, 64
    retw.n
    .space 28 - (. - speaker_coherent_cache_flush), 0

    .section .allocation_extension,"ax"
allocation_cookie:
    .word 0x403f64a0
allocation_function:
    .word 0x4040bf40
allocation_dispatch:
    .word 0x4038ea50
    .word 0
    .global speaker_coherent_allocate
speaker_coherent_allocate:
    entry a1, 32
    l32r a4, allocation_cookie
    l32i.n a2, a4, 0
    bnez.n a2, .Lallocation_done
    /* Same-core sentinel forbids a duplicate even if malloc returns null. */
    movi.n a2, -1
    s32i.n a2, a4, 0
    movi.n a10, 64
    movi.n a11, 48
    slli a11, a11, 8
    l32r a8, allocation_function
    callx8 a8
    movnez a2, a10, a10
    s32i.n a2, a4, 0
    dhwb a4, 0
    memw
.Lallocation_done:
    /* A32 may now restore this literal without leaving a stale F1 copy. */
    l32r a5, allocation_dispatch
    dhu a5, 0
    dhi a5, 0
    memw
    movi.n a2, 0
    retw.n
    .space 80 - (. - allocation_cookie), 0

    .section .allocation_entry,"ax"
    .global speaker_coherent_allocator_entry
speaker_coherent_allocator_entry:
    /* CALLX8 has placed its return address in incoming a8. ENTRY has not
     * rotated the register window yet: preserve a8. Incoming a9 is replaced
     * by ENTRY's new stack pointer and is safe for this pre-entry tail jump.
     */
    l32r a9, allocation_entry_literal
    jx a9
    .space 24 - (. - speaker_coherent_allocator_entry), 0
    .set allocation_entry_literal, 0x403e7818
    .end no-transform
