/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Drain every complete 96-frame half-period queued for Frankel D12.
 *
 * Ring-output notifications carry a route bit, not a count.  When several
 * native 192-frame PDM blocks arrive before the Fullband Ultrasonic task runs,
 * NotifyDownstreamFilters ORs those notifications together.  The stock
 * callback then synchronizes its reader to the newest block and silently
 * discards the backlog.  Query RingBufferStatic::AvailableForRead instead and
 * invoke the stock body after its synchronization call once per queued
 * 0x600-byte half-period.
 *
 * The loop is bounded to the complete eight-half MIC_US queue.  A cap-five
 * hardware trial left the worker continuously runnable and starved AoC
 * control; cap eight catches up to the producer and permits a clean CMD 0x147
 * stop.  Every iteration still checks real input availability first.
 *
 * The callback section replaces the existing 44-byte two-pass shim at
 * 0x403f0c44.  The no-sync helper and relocated period shim exactly occupy the
 * now-unreferenced 32-byte stock callback wrapper at 0x403e87d0.
 */

    .section .occupancy_drain,"ax"
    .align  4

    .set    no_sync_half, 0x403e87d0

    .global frankel_aoc_d12_ultra_occupancy_drain_192
frankel_aoc_d12_ultra_occupancy_drain_192:
    entry   a1, 32
    bnez.n  a3, .Lreturn
    movi.n  a5, 8

    /* Preserve the stock one-shot message hook before draining occupancy. */
    l8ui    a6, a4, 7
    beqz.n  a6, .Lstart
    l32i    a10, a2, 0x13c
    l32i.n  a8, a10, 0
    l32i    a8, a8, 0x70
    callx8  a8

.Lstart:
    movi    a6, 0x600
.Lavailable:
    l32i    a10, a2, 0x13c      /* Fullband input RingBufferStatic */
    l32i.n  a8, a10, 0
    l32i    a8, a8, 0x40        /* AvailableForRead */
    addmi   a11, a2, 0x800
    l32i.n  a11, a11, 0x28      /* reader stored at this+0x828 */
    callx8  a8

    bltu    a10, a6, .Lreturn
    mov.n   a10, a2
    mov.n   a11, a4
    call8   no_sync_half
    addi.n  a5, a5, -1
    bnez    a5, .Lavailable

.Lreturn:
    retw.n

    .section .no_sync_half,"ax"
    .align  4

    .set    stock_after_sync, 0x403e883a

    .global frankel_aoc_d12_ultra_no_sync_half_192
frankel_aoc_d12_ultra_no_sync_half_192:
    entry   a1, 32
    l8ui    a4, a3, 0
    extui   a4, a4, 0, 3
    mov.n   a5, a2
    addmi   a6, a5, 0x800
    addx2   a3, a4, a4
    j       stock_after_sync

    .section .period,"ax"
    .align 1

    .set stock_store_period_geometry, 0x403e8684

    .global frankel_aoc_d12_ultra_period_192_relocated
frankel_aoc_d12_ultra_period_192_relocated:
    l8ui    a7, a3, 15
    l8ui    a15, a3, 14
    slli    a15, a15, 1
    j       stock_store_period_geometry

    .section .period_hook,"ax"
    .align 1

    .global frankel_aoc_d12_ultra_period_192_relocated_hook
frankel_aoc_d12_ultra_period_192_relocated_hook:
    j       frankel_aoc_d12_ultra_period_192_relocated
    _nop
