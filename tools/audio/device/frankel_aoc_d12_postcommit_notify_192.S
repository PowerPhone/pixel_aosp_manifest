/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Move Frankel D12 stream-8 notification after its MIC_US writer commit.
 *
 * The stock stream-8 producer calls NotifyDownstreamFilters before the
 * post-tap repacker and RingBufferStatic::AdvanceWritePointer.  A Fullband
 * callback woken by that message can consequently observe only the previous
 * 0x600-byte half-period.  Route notifications are coalesced bits rather than
 * counted events, so no later callback is guaranteed for the second half.
 *
 * The stream-8-only trampoline preserves the exact dynamic byte count from
 * the original a12 argument, performs the existing repack, commits the fixed
 * native 0xc00-byte producer block, executes a memory barrier, and only then
 * reproduces the original downstream notification.  Other fanout routes keep
 * their stock common commit and notification order.
 *
 * This source is linked at the qualified CP2A.260805.005 F1 runtime
 * addresses.  The Python installer classifies the complete helper caves and
 * changes the live pre-notify call only after both helpers and this trampoline
 * are installed.
 */

    .set    ring8_repack, 0x403f6490
    .set    full_ring_bytes_literal, 0x403ba0f4
    .set    resume_after_common_commit, 0x403baa11
    .set    notify_downstream_filters, 0x40385344

    /*
     * Replace the current 14-byte stream-8 repack/advance trampoline at
     * 0x403ba962.  a12 still contains the exact byte count prepared for the
     * original pre-commit notification at 0x403bacb5.  Save it in caller-local
     * a2: the existing trampoline already overwrites a2 with 0xc00 here, and
     * the producer reloads a2 before the next fanout iteration.
     */
    .section .advance,"ax"
    .align  1
    .global frankel_aoc_d12_ring8_postcommit_advance
frankel_aoc_d12_ring8_postcommit_advance:
    mov.n   a2, a12
    call8   ring8_repack
    mov.n   a10, a2
    call8   frankel_aoc_d12_ring8_commit_then_notify
    j       resume_after_common_commit

    /*
     * First nested 32-byte window.  The original producer's ring object at
     * caller sp+96 is therefore at this sp+128.  Reproduce the common
     * 0x403baa05..0x403baa0e virtual AdvanceWritePointer call, then order it
     * before notification with MEMW.  a2 remains the saved notification byte
     * count because it is outside this callee's outgoing register window.
     */
    .section .commit_then_notify,"ax"
    .align  1
    .global frankel_aoc_d12_ring8_commit_then_notify
frankel_aoc_d12_ring8_commit_then_notify:
    entry   a1, 32
    l32i    a10, a1, 128
    l32i.n  a4, a10, 0
    l32i    a4, a4, 0x18
    l32r    a11, full_ring_bytes_literal
    callx8  a4
    memw
    mov.n   a10, a2
    call8   frankel_aoc_d12_ring8_notify_after_commit
    retw.n

    /*
     * Second nested 32-byte window.  Original producer sp+36 (fanout owner)
     * and sp+40 (the block/write pointer) are at this sp+100 and sp+104.
     * Recreate the stock route-8 call:
     *
     *   NotifyDownstreamFilters(owner[0x1f0], write_pointer,
     *                           original_byte_count, *, 1, 0)
     */
    .section .notify_after_commit,"ax"
    .align  1
    .global frankel_aoc_d12_ring8_notify_after_commit
frankel_aoc_d12_ring8_notify_after_commit:
    entry   a1, 32
    l32i    a4, a1, 100
    l32i    a10, a4, 0x1f0
    l32i    a11, a1, 104
    mov.n   a12, a2
    movi.n  a14, 1
    movi.n  a15, 0
    call8   notify_downstream_filters
    retw.n

    /* Replace only the original route-8 pre-commit callx8 with a 3-byte NOP. */
    .section .suppress_precommit_notify,"ax"
    .align  1
    .global frankel_aoc_d12_suppress_precommit_notify
frankel_aoc_d12_suppress_precommit_notify:
    _nop
