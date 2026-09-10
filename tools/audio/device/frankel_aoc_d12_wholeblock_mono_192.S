/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Process one complete 192-frame Frankel D12 block per Fullband invocation.
 *
 * The qualified CP2A.260805.005 F1 firmware normally invokes Fullband twice
 * for a native 192-frame PDM block.  Each invocation copies, commits, and
 * notifies only 96 mono S32 frames.  At a physical 192 kHz source rate that
 * doubles RingBufferHost traffic to 2,000 commits/notifications per second.
 * The host path eventually falls behind even though the retained prefix is
 * valid 192 kHz audio.
 *
 * This profile instead consumes the compact 0xc00-byte native block in one
 * invocation and emits one 0x300-byte mono period.  A cap-four occupancy
 * callback recovers notifications which were coalesced while the worker was
 * busy, but average host traffic remains 1,000 periods per second.  The
 * producer keeps its stock NotifyDownstreamFilters-before-commit order.
 *
 * This is deliberately a mono research profile.  The constructor rejects
 * every channel count except one, and the no-sync helper independently
 * refuses a process descriptor whose low three channel bits are not one.
 * Those two guards keep the widened copy below the metadata beginning at
 * Fullband object +0x81c.
 */

    .set    full_ring_bytes_literal, 0x403ba0f4
    .set    stock_after_reader_sync, 0x403e883a

    /* Replace the stock "channels < 5" constructor check with channels == 1. */
    .section .mono_constructor_guard,"ax"
    .align  1
    .global frankel_aoc_d12_mono_constructor_guard
frankel_aoc_d12_mono_constructor_guard:
    { ae_format_3; beqi.w15 a7, 1, frankel_aoc_d12_mono_constructor_guard + 0x1b; movi a14, 1 }

    /* 3 * channels * 128 -> 3 * channels * 256 output bytes. */
    .section .output_byte_count,"ax"
    .align  1
    .global frankel_aoc_d12_wholeblock_output_byte_count
frankel_aoc_d12_wholeblock_output_byte_count:
    /* Preserve the qualified firmware's scalar opcode form. */
    .byte   0x80, 0x77, 0x11       /* slli a7, a7, 8 */

    /*
     * Disconnect the retired full-sync cave before it is reused below.  The
     * whole-block callback has already proved 0xc00 bytes are available, but
     * this direct count keeps the ordinary process entry self-contained while
     * the callback table is quarantined during a live transition.
     */
    .section .reader_sync_count,"ax"
    .align  1
    .global frankel_aoc_d12_wholeblock_reader_sync_count
frankel_aoc_d12_wholeblock_reader_sync_count:
    /* Exact RT500 FLIX form of addx2 a3,a4,a4 + l32r a12,0x403ba0f4. */
    .byte   0x40, 0x34, 0x90, 0xc1, 0x31, 0x46

    /*
     * The cap-four callback calls this helper only after AvailableForRead is
     * at least 0xc00.  Reconstruct the stock scalar preamble, validate the
     * per-open process descriptor, and skip the body's ReaderSync call.
     */
    .section .no_sync_wholeblock,"ax"
    .align  1
    .byte   0, 0, 0
    .global frankel_aoc_d12_no_sync_wholeblock_mono
frankel_aoc_d12_no_sync_wholeblock_mono:
    .byte   0x36, 0x41, 0x00       /* entry a1,32 */
    .byte   0x42, 0x03, 0x00       /* l8ui a4,a3,0 */
    .byte   0x40, 0x40, 0x24       /* extui a4,a4,0,3 */
    .byte   0x66, 0x14, 0x0a       /* bnei a4,1, mismatch */
    .byte   0x5d, 0x02             /* mov.n a5,a2 */
    .byte   0x62, 0xd5, 0x08       /* addmi a6,a5,0x800 */
    .byte   0x40, 0x34, 0x90       /* addx2 a3,a4,a4 */
    .byte   0x86, 0xe4, 0xc8       /* j 0x403e883a */
    .byte   0x1d, 0xf0             /* mismatch: retw.n */
    .space  23, 0                  /* complete reviewed 51-byte cave */

    /* Double the scalar copy loop from 96 to 192 mono S32 frames. */
    .section .copy_loop_count,"ax"
    .align  1
    .global frankel_aoc_d12_wholeblock_copy_loop_count
frankel_aoc_d12_wholeblock_copy_loop_count:
    /* Exact RT500 FLIX form of { l32i a10,a5,0x13c; slli a7,a3,6 }. */
    .byte   0xae, 0xe5, 0xb8, 0x8e, 0x1b, 0x93

    /* Consume exactly the same complete block checked by the callback. */
    .section .input_advance,"ax"
    .align  1
    .global frankel_aoc_d12_wholeblock_input_advance
frankel_aoc_d12_wholeblock_input_advance:
    addmi   a4, a5, 0x800
    l32r    a12, full_ring_bytes_literal

    /* One 192-frame invocation is one millisecond: restore stock geometry. */
    .section .period_geometry,"ax"
    .align  1
    .global frankel_aoc_d12_wholeblock_period_geometry
frankel_aoc_d12_wholeblock_period_geometry:
    /* Exact six-byte stock bundle. */
    .byte   0x7e, 0xf3, 0xbc, 0x0f, 0x07, 0x71

    /*
     * Drain at most four complete 0xc00-byte blocks per notification.  The
     * availability query is RingBufferStatic-local; output RingBufferHost is
     * touched only once by the stock tail for each complete 192-frame block.
     */
    .section .wholeblock_callback,"ax"
    .align  4
    .global frankel_aoc_d12_wholeblock_mono_callback
frankel_aoc_d12_wholeblock_mono_callback:
    /*
     * Keep the qualified assembler's compact encodings around the one
     * relocated call.  RT500 objdump decodes this prefix as the cap-four
     * algorithm described above; the Python installer carries the same
     * complete 60-byte before/after guards.
     */
    .byte   0x36, 0x41, 0x00       /* entry a1,32 */
    .byte   0xfc, 0x23             /* bnez.n a3, return */
    .byte   0x0c, 0x45             /* movi.n a5,4 */
    .byte   0x62, 0x04, 0x07       /* l8ui a6,a4,7 */
    .byte   0x8c, 0x96             /* beqz.n a6, load quantum */
    .byte   0xa2, 0x22, 0x4f       /* l32i a10,a2,0x13c */
    .byte   0x88, 0x0a             /* l32i.n a8,a10,0 */
    .byte   0x82, 0x28, 0x1c       /* l32i a8,a8,0x70 */
    .byte   0xe0, 0x08, 0x00       /* callx8 a8 */
    .byte   0x61, 0x26, 0x25       /* l32r a6,0x403ba0f4 */
    .byte   0xa2, 0x22, 0x4f       /* l32i a10,a2,0x13c */
    .byte   0x88, 0x0a             /* l32i.n a8,a10,0 */
    .byte   0x82, 0x28, 0x10       /* l32i a8,a8,0x40 */
    .byte   0xb2, 0xd2, 0x08       /* addmi a11,a2,0x800 */
    .byte   0xb8, 0xab             /* l32i.n a11,a11,0x28 */
    .byte   0xe0, 0x08, 0x00       /* callx8 a8 */
    .byte   0x67, 0x3a, 0x0b       /* bltu a10,a6, return */
    .byte   0xad, 0x02             /* mov.n a10,a2 */
    .byte   0xbd, 0x04             /* mov.n a11,a4 */
    call8   frankel_aoc_d12_no_sync_wholeblock_mono
    .byte   0x0b, 0x55             /* addi.n a5,a5,-1 */
    .byte   0x56, 0x05, 0xfe       /* bnez a5, available */
    .byte   0x1d, 0xf0             /* retw.n */
    .byte   0x00                   /* reviewed cave padding */
