/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Repack Frankel ring output 8 after its optional tap and before commit.
 *
 * PdmV3 produces one compact 192-frame block per millisecond at 192 kHz.
 * Fullband Ultrasonic consumes two fixed 0x600-byte, 96-frame slots.  For an
 * N-channel route, preserve the first 96*N*4 bytes and overlap-safely move the
 * second 96*N*4 bytes from immediately after them to destination + 0x600.
 * The native memmove is used because the three-channel case overlaps.
 *
 * The hook site is reached only by ring output 8.  The saved route descriptor
 * supplies the real rate enum, so 96 kHz remains an exact no-op.  A proper
 * call8/entry/retw window preserves the enclosing fanout function's a0 return
 * link.  A ring-8-only tail trampoline then forces the writer commit to the
 * native 0xc00-byte producer quantum.  This must not be derived from
 * SizeGet()/2 once the consumer ring is deepened beyond 0x1800.
 *
 * The repack cave covers 0x403f6490..0x403f64bf, including the allocator's
 * temporary scratch word at 0x403f64a0.  Install this only after the 0x3000
 * MIC_US rebase has committed and cleared that scratch word.  Revert it before
 * re-arming the allocator.
 */

    .section .repack,"ax"
    .align 1

    /* Existing stock literal containing the overlap-safe memmove entry. */
    .set memmove_literal, 0x403f1cec

    .global frankel_aoc_d12_ring8_repack_192
frankel_aoc_d12_ring8_repack_192:
    /* After entry(32), caller-frame fields are addressed at caller offset+32. */
    entry   a1, 32
    l32i    a6, a1, 88          /* caller +56: route descriptor */
    l8ui    a6, a6, 144         /* actual sample-rate enum */
    bnei    a6, 7, .Lstock

    /* half = channels * 3 * 128 = 96 frames * 4 bytes * channels. */
    l32i    a4, a1, 80          /* caller +48: output-channel count */
    addx2   a4, a4, a4
    slli    a4, a4, 7
    movi    a6, 0x600

    l32i    a3, a1, 72          /* caller +40: destination base */
    add.n   a10, a3, a6         /* memmove destination: slot 2 */
    add.n   a11, a3, a4         /* source: compact temporal half 2 */
    mov.n   a12, a4             /* byte count */
    l32r    a8, memmove_literal
    callx8  a8

.Lstock:
    retw.n

    .section .hook,"ax"
    .align 1
    .global frankel_aoc_d12_ring8_repack_192_hook
frankel_aoc_d12_ring8_repack_192_hook:
    j       frankel_aoc_d12_ring8_repack_192_advance

    /*
     * Stream 8 reaches the original hook exclusively.  Other fanout streams
     * enter the stock SizeGet()/2 sequence at 0x403bacbb and remain untouched.
     * The 14-byte stock-zero cave at 0x403ba962 has room for this nine-byte
     * call/reload/tail sequence.
     */
    .section .advance,"ax"
    .align 1
    .set full_ring_bytes, 0x403ba0f4
    .set common_advance_write_pointer, 0x403baa05
    .global frankel_aoc_d12_ring8_repack_192_advance
frankel_aoc_d12_ring8_repack_192_advance:
    call8   frankel_aoc_d12_ring8_repack_192
    l32r    a2, full_ring_bytes
    j       common_advance_write_pointer

    .section .sync,"ax"
    .align 1
    .global frankel_aoc_d12_full_ring_sync_direct
frankel_aoc_d12_full_ring_sync_direct:
    addx2   a3, a4, a4
    l32r    a12, full_ring_bytes
