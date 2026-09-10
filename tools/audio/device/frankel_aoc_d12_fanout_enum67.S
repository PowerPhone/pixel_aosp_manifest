/*
 * Size-neutral scalar replacement for Frankel F1 0x403baad5..0x403baae2.
 *
 * The stock enum-6 target reloads a9 from [a1 + 44], then selects a 96-frame
 * fanout quantum.  a13, a15, and a14 already have their required values from
 * 0x403baa5d/0x403baa63, but a9 does not: its earlier stack offset is 132.
 * Preserve that distinct reload and derive 96/192 from rate enum 6/7 without
 * exceeding the original 14-byte region.
 */

    .text
    .align  4
    .global frankel_aoc_d12_fanout_enum67
    .type   frankel_aoc_d12_fanout_enum67, @function
frankel_aoc_d12_fanout_enum67:
    l32i    a9, a1, 44
    movi.n  a7, 3
    ssl     a8
    sll     a7, a7
    srli    a7, a7, 1
    .size   frankel_aoc_d12_fanout_enum67, .-frankel_aoc_d12_fanout_enum67
