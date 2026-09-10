/*
 * Frankel AoC native-ultrasound 192-frame drain shim.
 *
 * The native PDM producer emits one 192-frame block per 1 ms callback at
 * 192 kHz.  The stock Fullband Ultrasonic processor owns only a 96-frame
 * scratch block and therefore consumes 0x600 bytes per invocation.  The
 * producer-side patch commits the complete 0xc00-byte input ring; this shim
 * invokes the stock processor once for each half without resynchronizing the
 * reader before the second invocation.
 *
 * Link this section at F1 runtime address 0x403f0c44.  The first invocation
 * uses the stock processor after its ReaderSyncOffsetDeprecated argument has
 * separately been changed from 0x600 to 0xc00.  The second entry reconstructs
 * the stock scalar preamble and tail-jumps to 0x403e883a, immediately after
 * that synchronization call.  Both passes retain the stock 0x600-byte copy,
 * read advance, output-ring commit, notification, and statistics paths.
 *
 * The public callback ABI is the same as the stock wrapper at 0x403e87d0:
 * a2 = processor, a3 = callback status, a4 = message.  A nonzero status is a
 * no-op.  Xtensa's windowed call8 ABI preserves the wrapper's a2/a4 across
 * each child call.
 */

    .text
    .align  4

    .set    stock_process,      0x403e87fc
    .set    stock_after_sync,   0x403e883a

    .global frankel_aoc_d12_ultra_drain_192
    .type   frankel_aoc_d12_ultra_drain_192, @function
frankel_aoc_d12_ultra_drain_192:
    entry   a1, 32
    bnez    a3, .Lreturn

    mov     a10, a2
    mov     a11, a4
    call8   stock_process

    mov     a10, a2
    mov     a11, a4
    call8   .Lprocess_without_sync

.Lreturn:
    retw.n
    .size   frankel_aoc_d12_ultra_drain_192, .-frankel_aoc_d12_ultra_drain_192

    .align  4
    .type   .Lprocess_without_sync, @function
.Lprocess_without_sync:
    entry   a1, 32
    l8ui    a4, a3, 0
    extui   a4, a4, 0, 3
    mov     a5, a2
    addmi   a6, a5, 0x800
    addx2   a3, a4, a4
    j       stock_after_sync
    .size   .Lprocess_without_sync, .-.Lprocess_without_sync
