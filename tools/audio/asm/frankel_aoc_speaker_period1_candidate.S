/* CP2A.260805.005 F1 research candidate. No device action is performed by
 * assembling this file. See patch_frankel_aoc_speaker_period1_candidate.py.
 */
    .begin no-transform
    .section .period_mode, "ax"
    .byte 0x6b
    .global speaker_period1_mode
speaker_period1_mode:
    l16ui a8, a4, 100
    l32i a7, a3, 0x368
    l32i.n a2, a1, 16
    bnez.n a2, .Lmode_return
    movi.n a2, 5
    bbci a7, 5, .Lmode_rate
    movi a6, 192
    movi.n a2, 1
    s8i a2, a4, 136
    movi.n a2, 7
.Lmode_rate:
    s8i a2, a4, 138
.Lmode_return:
    j 0x4038ba52

    .section .expected_hook, "ax"
    j speaker_expected_block
    nop
    .section .account_hook, "ax"
    j speaker_account_block
    nop

    .section .expected_cave, "ax"
    .global speaker_expected_block
speaker_expected_block:
    { ae_format_1; l8ui a5, a5, 136; movi a8, 0x180 }
    /* a3 is sink index, a4 is the per-sink record. a9 is overwritten
     * by the next original packet at0x4038ca7a, so it is safe scratch. */
    bnez a3, .Lexpected_return
    addmi a9, a4, 0x300
    l8ui a9, a9, 138
    bnei a9, 7, .Lexpected_return
    l32i a9, a4, 0x368
    bbci a9, 5, .Lexpected_return
    movi a8, 0x600
.Lexpected_return:
    j 0x4038ca7a

    .section .account_cave, "ax"
    .global speaker_account_block
speaker_account_block:
    { ae_format_1; l32i a8, a5, 0; movi a9, 0x180 }
    /* a3 is per-sink record; saved sink index is stack+12. a11 is
     * overwritten by the next original packet at0x4038cb43. */
    l32i.n a11, a1, 12
    bnez a11, .Laccount_return
    addmi a11, a3, 0x300
    l8ui a11, a11, 138
    bnei a11, 7, .Laccount_return
    l32i a11, a3, 0x368
    bbci a11, 5, .Laccount_return
    movi a9, 0x600
.Laccount_return:
    j 0x4038cb43
    .end no-transform
