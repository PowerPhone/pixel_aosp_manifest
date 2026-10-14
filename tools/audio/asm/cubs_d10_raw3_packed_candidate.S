/* Exclusive Cubs RAW3/native192 candidate; not a general capture profile.
 * Extends the separately qualified mono receiver-edge0 configuration.
 * Destination3 stores upper16 directly, destination2 is not produced, and
 * the AP stager transfers exactly96 interleaved S16 three-channel frames.
 */
.begin no-transform
.section .raw_three_admission,"ax"
    { ae_format_1; bgeui a6,3,0x4027a64c; movi a11,0x658 }
.section .normal_stage_skip,"ax"
    j 0x4027ab62
.section .producer_destination_hook,"ax"
    j cubs_raw3_destination
.section .producer_sample_hook,"ax"
    j cubs_raw3_sample
    nop
.section .producer_missing_hook,"ax"
    j cubs_raw3_missing
    nop.n
.section .producer_post_hook,"ax"
    j cubs_raw3_post
    .byte 0

/* Replaces only the original AP stager entry/body before its old filter.
 * Both callers pass this/raw/channels; only RAW with three channels runs.
 * Source uses the existing reader and padded half-bank cursor semantics.
 */
.section .packed_stage,"ax"
    entry a1,48
    beqz a3,.Lstage_done
    bnei a4,3,.Lstage_done
    l32i a3,a2,0x148
    addmi a4,a2,0x800
    l32i a4,a4,232
    mov.n a10,a3
    l32i.n a8,a3,0
    l32i a8,a8,80
    callx8 a8
    srli a12,a10,1
    mov.n a10,a3
    mov.n a11,a4
    l32i.n a8,a3,0
    l32i a8,a8,44
    callx8 a8
    mov.n a10,a3
    mov.n a11,a4
    l32i.n a8,a3,0
    l32i a8,a8,84
    callx8 a8
    movi a5,0x524
    add.n a5,a2,a5
    movi a6,288
    loop a6,.Lcopy_done
    l16ui a7,a10,0
    addi.n a10,a10,2
    s16i a7,a5,0
    addi.n a5,a5,2
.Lcopy_done:
    mov.n a10,a3
    mov.n a11,a4
    movi a12,0x300
    l32i.n a8,a3,0
    l32i a8,a8,60
    callx8 a8
.Lstage_done:
    retw.n

/* These three helpers occupy the old AP-stager body, now unreachable.
 * They are midfunction branches, so there is no ENTRY/window rotation.
 * Destination+4*channel is corrected to +2*channel for packed S16.
 */
.section .producer_sample_cave,"ax"
.global cubs_raw3_sample
cubs_raw3_sample:
    l32i a14,a1,92
    bnei a14,3,.Lsample_stock
    bnei a3,3,.Lsample_stock
    bnei a8,7,.Lsample_stock
    addx4 a12,a12,a9
    slli a14,a10,1
    sub a13,a11,a14
    loop a7,.Lsample_packed_done
    l16ui a14,a12,2
    add.n a12,a12,a5
    s16i a14,a13,0
    addi.n a13,a13,6
.Lsample_packed_done:
    j 0x4025eee9
.Lsample_stock:
    addx4 a12,a12,a9
    loop a7,.Lsample_stock_done
    l32i.n a14,a12,0
    add.n a12,a12,a5
    s32i.n a14,a13,0
    add.n a13,a13,a6
.Lsample_stock_done:
    j 0x4025ef21

.section .producer_missing_cave,"ax"
.global cubs_raw3_missing
cubs_raw3_missing:
    l32i a12,a1,92
    bnei a12,3,.Lmissing_stock
    bnei a3,3,.Lmissing_stock
    bnei a8,7,.Lmissing_stock
    slli a12,a10,1
    sub a12,a11,a12
    loop a7,.Lmissing_packed_done
    s16i a2,a12,0
    addi.n a12,a12,6
.Lmissing_packed_done:
    j 0x4025eee9
.Lmissing_stock:
    mov.n a12,a11
    loop a7,.Lmissing_stock_done
    s32i.n a2,a12,0
    add.n a12,a12,a6
.Lmissing_stock_done:
    j 0x4025eee9

.section .producer_destination_cave,"ax"
.global cubs_raw3_destination
cubs_raw3_destination:
    l8ui a10,a8,0
    bnei a10,2,.Ldestination_stock
    bnei a3,3,.Ldestination_stock
    l32i.n a12,a1,20
    l8ui a12,a12,148
    bnei a12,7,.Ldestination_stock
    j 0x4025ee42
.Ldestination_stock:
    j 0x4025ee4e

/* Per-destination microphone compensation accepts S32. RAW3's packed
 * destination must bypass it, retaining original half-bank publication.
 */
.section .producer_post_cave,"ax"
.global cubs_raw3_post
cubs_raw3_post:
    l32i a9,a1,92
    bnei a9,3,.Lpost_stock
    bnei a3,3,.Lpost_stock
    bnei a8,7,.Lpost_stock
    j 0x4025efbe
.Lpost_stock:
    l32i.n a9,a1,20
    l32i.n a10,a1,20
    j 0x4025ef28

/* RAW stager already wrote packed S16 at+524. Retain the stock AP-ring
 * publisher: channels*3*64 produces576 bytes for exactlythree channels.
 */
.section .packed_publish_entry,"ax"
    entry a1,32
    bnei a3,3,.Lpublish_done
    addmi a4,a2,0x800
    l8ui a4,a4,89
    bnei a4,3,.Lpublish_done
    j 0x4027b715
.Lpublish_done:
    retw.n
.end no-transform
