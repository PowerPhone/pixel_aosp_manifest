/*
 * Offline-only Sky1 assembly for the Frankel AoC speaker-192 analysis.
 *
 * This does not form a loadable firmware image.  It records the exact
 * instructions used by the semantic patch manifest so they can be decoded
 * and reviewed without hand-encoding Xtensa FLIX bundles.  Applying any of
 * these bytes to aoc.bin invalidates the OEM signature.
 */

/*
 * Replace the complete stock 0x78972b86..0x78972baf initialization in place.
 * The added shift doubles 0x600 to 0xc00.  To keep the exact 42-byte extent,
 * the sequence eliminates the separate a14 size temporary, writes both
 * 0x600 fields from a15, and doubles a15 only before the 0xc00 store.  The
 * stock null-DMA assertion's `movi a12, 107` argument is retained.
 */
    .section .patch.scratch_init, "ax"
    .global scratch_init
scratch_init:
    addmi a12, a2, 0x200
    movi a15, 0x600
    movi.n a13, 3
    s32i.n a6, a2, 0
    s32i a4, a2, 0x27c
    s32i.n a12, a1, 44
    s8i a4, a12, 128
    s32i a13, a2, 0x294
    movi a12, 107
    s32i a4, a2, 0x288
    s32i a15, a2, 0x2b4
    s32i a4, a2, 0x28c
    s32i a15, a2, 0x2bc
    slli a15, a15, 1
    s32i a15, a2, 0x2b8

    .section .patch.force_high, "ax"
    .global force_high
force_high:
    j speaker_high_rate

    .section .patch.rate, "ax"
    .global speaker_high_rate
speaker_high_rate:
    { ae_format_1; movi a15, 192; movi a10, 32 }

/*
 * These four bundles describe the coordinated 48 <-> 192 AspSrc design.
 * The frame counts and rate are resolved.  Static reconstruction gives
 * conservative 6,240 and 7,424-byte private-heap bounds for the ratio-4
 * plans. The encoded 7,040 and 8,768-byte capacities retain additional
 * margin; firmware execution is still required to qualify the reconstructed
 * bound.
 */
    .section .patch.src_up_shape, "ax"
    .global src_up_shape
src_up_shape:
    { ae_format_1; slli a5, a5, 9; slli a6, a6, 7 }

    .section .patch.src_up_frames, "ax"
    .global src_up_frames
src_up_frames:
    { ae_format_1; movi a12, 192; movi a11, 48 }

    .section .patch.src_down_heap, "ax"
    .global src_down_heap
src_down_heap:
    { ae_format_1; movi a14, 0x177; slli a6, a6, 6 }

    .section .patch.src_down_frames, "ax"
    .global src_down_frames
src_down_frames:
    { ae_format_1; movi a11, 192; movi a12, 48 }
