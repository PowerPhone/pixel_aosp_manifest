/*
 * Frankel AoC Fullband Ultrasonic full-ring synchronization trampoline.
 *
 * Link at F1 runtime address 0x403f648d.  The in-function hook at
 * 0x403e882d enters with the stock handler's register state.  A 192-frame,
 * four-channel native block occupies the complete 0xc00-byte input ring, so
 * synchronize its reader one full ring behind the writer before processing
 * the first 0x600-byte half.  Control resumes immediately after the stock
 * ReaderSyncOffsetDeprecated call.
 *
 * This is deliberately a tail trampoline, not a callable function: it keeps
 * the stock handler's register window and stack frame.
 */

    .text
    .align  1

    .set    stock_after_sync, 0x403e883a

    .global frankel_aoc_d12_ultra_sync_192
frankel_aoc_d12_ultra_sync_192:
    addx2   a3, a4, a4
    movi    a12, 0x600
    slli    a12, a12, 1
    l32i    a2, a2, 40
    callx8  a2
    j       stock_after_sync
