/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Encoding references for the Frankel AoC audio_capture2 RAW converter.
 *
 * These stand-alone instructions are assembled with the qualified RT500
 * toolchain.  The live installer preserves every unrelated slot in the
 * firmware's FLIX bundles and changes only the immediate fields identified
 * from these reference encodings.
 */

    .section .movi48,"ax"
    .align 1
    .global frankel_aoc_d10_movi48_reference
frankel_aoc_d10_movi48_reference:
    movi a15, 48

    .section .movi96,"ax"
    .align 1
    .global frankel_aoc_d10_movi96_reference
frankel_aoc_d10_movi96_reference:
    movi a15, 96

    .section .shift5,"ax"
    .align 1
    .global frankel_aoc_d10_shift5_reference
frankel_aoc_d10_shift5_reference:
    slli a2, a15, 5

    .section .shift6,"ax"
    .align 1
    .global frankel_aoc_d10_shift6_reference
frankel_aoc_d10_shift6_reference:
    slli a2, a15, 6

    .section .bundle48,"ax"
    .align 1
    .global frankel_aoc_d10_bundle48_reference
frankel_aoc_d10_bundle48_reference:
    { fusion_format48; movi a15, 48; nop }

    .section .bundle96,"ax"
    .align 1
    .global frankel_aoc_d10_bundle96_reference
frankel_aoc_d10_bundle96_reference:
    { fusion_format48; movi a15, 96; nop }

    .section .bundle_second48,"ax"
    .align 1
    .global frankel_aoc_d10_bundle_second48_reference
frankel_aoc_d10_bundle_second48_reference:
    { fusion_format48; nop; movi a15, 48 }

    .section .bundle_second96,"ax"
    .align 1
    .global frankel_aoc_d10_bundle_second96_reference
frankel_aoc_d10_bundle_second96_reference:
    { fusion_format48; nop; movi a15, 96 }

    .section .bundle_narrow_first48,"ax"
    .align 1
    .global frankel_aoc_d10_bundle_narrow_first48_reference
frankel_aoc_d10_bundle_narrow_first48_reference:
    { fusion_format48; movi.n a15, 48; nop }

    .section .bundle_narrow_second48,"ax"
    .align 1
    .global frankel_aoc_d10_bundle_narrow_second48_reference
frankel_aoc_d10_bundle_narrow_second48_reference:
    { fusion_format48; nop; movi.n a15, 48 }
