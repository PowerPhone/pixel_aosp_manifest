/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Qualified instruction-encoding references for the Frankel AoC
 * audio_capture2 strict-mono 192-frame geometry experiment.
 *
 * Assemble with the Frankel F1 binutils build, preserving bundle layout:
 *
 *   as-new --no-transform --no-target-align -o geometry.o this-file.S
 *
 * These encodings are safe candidates only while D8/D9/D10 are closed and
 * audio_capture2 is configured for exactly one source channel and one RAW
 * channel.  The source copy occupies self+0x224..self+0x523 (0x300 bytes),
 * ending exactly where the RAW output workspace begins at self+0x524.  The
 * mono converter writes 192 S16 samples (0x180 bytes), and the final shift
 * reports the same 0x180 bytes.  Multichannel paths have independent stock
 * 48-frame loops and must never execute with these common-site edits.
 *
 * Live 96 -> 192 transitions, expressed as complete instruction guards:
 *
 *   0x403daf5d  3e44242ee992 -> 3e44202ee992
 *   0x403dbc4f  fe00680fe992 -> fe10480fe992
 *   0x403dbce2  a02f11       -> 902f11
 */

    .section .source_fill192,"ax"
    .align  1
    .global frankel_aoc_d10_source_fill192
frankel_aoc_d10_source_fill192:
    { ae_format_1; movi a3, 0x224; slli a2, a11, 8 }

    .section .mono_convert192,"ax"
    .align  1
    .global frankel_aoc_d10_mono_convert192
frankel_aoc_d10_mono_convert192:
    { ae_format_1; movi a15, 192; slli a2, a3, 2 }

    .section .sent_bytes192,"ax"
    .align  1
    .global frankel_aoc_d10_sent_bytes192
frankel_aoc_d10_sent_bytes192:
    slli    a2, a15, 7
