/* Experimental CP2A.260805.005 D10-only three-channel capture delta.
 * NOT a standalone firmware profile. Requires the existing 22-site mono192
 * profile, raw capture, spatial processing off, and exclusive D10 ownership.
 * RAW destination3 is packed to S16 in the producer because the live input
 * ring is1536B total /768B per pingpong bank. Three96-frame S32 channels do
 * not fit; three S16 channels occupy576B. The unused normal-AP destination2
 * is skipped entirely for Three/native192: its bank is also only768B, and
 * its optional publisher expects S32. Other destinations stay S32.
 */
    .begin no-transform
    /* RAW_ENABLE_2 dispatches queued command112 to403da874. a6 is the
     * requested channel count minus1; keep zero and4+ invalid, admit1..3.
     * Preserve the packet's parallel log-level load and all other checks.
     */
    .section .raw_enable_bound, "ax"
    { bgeui.w15 a6, 3, 0x403da940; l32i a5, a2, 4 }

    /* The native enum7 branch skips the old enum5 selector and body. A
     * nearby trampoline reaches the negative-mapping helper without an
     * out-of-range direct J. On this path a2 was the negative mapping and
     * is overwritten by the original fallback anyway.
     */
    .section .near_bridges, "ax"
    .word d10_three_channel_missing
    .word d10_three_channel_skip_normal
    .global d10_missing_bridge
d10_missing_bridge:
    l32r a2, .Lmissing_target
    jx a2
    .set .Lmissing_target, 0x403baa84
    .global d10_skip_bridge
d10_skip_bridge:
    l32r a2, .Lskip_target
    jx a2
    .set .Lskip_target, 0x403baa88

    .section .missing_hook, "ax"
    j d10_missing_bridge

    .section .destination_hook, "ax"
    j d10_skip_bridge

    .section .producer_hook, "ax"
    j d10_three_channel_producer
    nop

    /* Native enum7 jumps directly403baad5. Reuse only its bypassed enum5
     * branch body; this experimental profile requires exclusive enum7 PDM.
     */
    .section .producer_body, "ax"
    .global d10_three_channel_producer
d10_three_channel_producer:
    l32i a2, a1, 152
    bnei a2, 3, .Lproducer_s32
    bnei a3, 12, .Lproducer_s32
    or a4, a6, a6
    or a6, a12, a12
    slli a5, a10, 1
    sub a5, a11, a5
    movi a2, 6
    loop a7, .Lproducer_packed
    l16ui a3, a6, 2
    s16i a3, a5, 0
    add a6, a6, a4
    addi a5, a5, 6
.Lproducer_packed:
    movi a2, 12
    j 0x403bab0c
.Lproducer_s32:
    { ae_format_1; or a2, a3, a3; or a4, a6, a6 }
    j 0x403baafa

    .section .stage_gate, "ax"
    l32i.n a13, a1, 20
    beqi a6, 3, d10_three_channel_direct
    j 0x403db798

    .section .direct_body, "ax"
    .global d10_three_channel_direct
d10_three_channel_direct:
    /* a10: packed S16 source, a7: APInputProcessor, original64-byte frame.
     * Copy directly into the original +524 S16 plane. The maximum write
     * is 96*3*2 = 576 bytes, ending at +764, below its original +824 limit.
     * No write to the undersized +224 S32 plane is performed.
     */
    movi a2, 0x524
    add a3, a7, a2
    movi a4, 288
    loop a4, .Lcompact_done
    l16ui a2, a10, 0
    s16i a2, a3, 0
    addi a10, a10, 2
    addi a3, a3, 2
.Lcompact_done:
    /* Original reader-release call. RingBufferStatic virtual+56 at40381e04
     * advances min(available, requested). Packed three channels require576B.
     * The unchanged next callback rewind selects writer-bank_size, so the
     * unused192B padding in each768B bank is never treated as captured audio.
     */
    l32i a2, a1, 24
    l32i a3, a1, 28
    l32i a10, a2, 60
    l32i a11, a3, 0
    movi a12, 0x240
    l32i a2, a10, 0
    l32i a2, a2, 56
    callx8 a2
    /* Reuse the existing output publisher, including ring write and range
     * writeback. Existing mono profile computes 192*channels bytes.
     * Its RETW returns from our original stager frame to the original caller.
     */
    movi a8, 3
    j 0x403dbcd6

    .global d10_three_channel_return
d10_three_channel_return:
    bnei a5, 3, .Lmono_return
    j 0x403db034
.Lmono_return:
    { ae_format_1; s32i a5, a1, 24; addx2 a11, a5, a5 }
    j 0x403dae20

    .balign 4
.Lmissing_return_common:
    .word 0x403bab0e
.Lmissing_return_original:
    .word 0x403bab3a
    .global d10_three_channel_missing
d10_three_channel_missing:
    l32i a2, a1, 152
    bnei a2, 3, .Lmissing_s32
    bnei a3, 12, .Lmissing_s32
    slli a2, a10, 1
    sub a4, a11, a2
    movi a2, 6
    srai a3, a14, 16
    loop a7, .Lmissing_packed
    s16i a3, a4, 0
    addi a4, a4, 6
.Lmissing_packed:
    movi a2, 12
    /* a14 remains the original fill value; a6 remains the source stride.
     * Common403bab0e restores a3 froma2 and advances the channel index.
     * a5 is dead on the stock missing-lane path and is overwritten403bab53.
     */
    l32r a5, .Lmissing_return_common
    jx a5
.Lmissing_s32:
    or a2, a3, a3
    l32r a5, .Lmissing_return_original
    jx a5

    .balign 4
.Ldestination_continue:
    .word 0x403baa30
.Ldestination_skip:
    .word 0x403baa21
    .global d10_three_channel_skip_normal
d10_three_channel_skip_normal:
    /* Entry replaces only l8ui a2,a7,0 before destination bookkeeping.
     * The stock destination0 branch already resumes403baa21 without bank
     * access or publication. Use that same continuation for unused normal
     * destination2, only with three channels and the native192 selector.
     * a12 is dead here: the normal selector reloads it from stack+124.
     */
    l8ui a2, a7, 0
    bnei a2, 2, .Ldestination_original
    bnei a3, 12, .Ldestination_original
    l32i a2, a1, 56
    l8ui a2, a2, 144
    bnei a2, 7, .Ldestination_original
    l32r a12, .Ldestination_skip
    jx a12
.Ldestination_original:
    l8ui a2, a7, 0
    l32r a12, .Ldestination_continue
    jx a12

    .section .main_return_hook, "ax"
    j d10_three_channel_return
    nop
    .end no-transform
