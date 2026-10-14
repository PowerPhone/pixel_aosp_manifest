/* Cubs live15876290-polygon. Diagnostic96k CLOCK CONTROL, not192 support.
 * Retains v5 RAW96-frame geometry but uses stock3.2MHz/1ms native timing.
 * When captured with a192k WAV header, a physical20k tone should appear40k.
 * Not a general multichannel/framework profile. Stop all audio clients first.
 * All sections replace exact instructions from this firmware, not Frankel.
 */
.begin no-transform
.section .stream_rate,"ax"
    movi.n a6,7
.section .restart_native_rate,"ax"
    movi.n a11,7
.section .classify_native,"ax"
    bgeui a13,6,0x4025c36c
.section .configure_native_rate,"ax"
    movi.n a10,7
.section .native_timebase,"ax"
    { ae_format_1; slli a3,a3,8; slli a11,a11,7 }
.section .native_clock,"a"
    .word 3200000
/* Preserve the stock coefficient-dependent HPF bypass polarity. At d1e0,
 * saltu a12,a6,a3 passes1 when coefficient programming was skipped, not0.
 * Forcing0 here in v4 may enable an unconfigured filter; that trial was noisy.
 */
.section .timestamp_expected_half_ms,"ax"
    /* Stock38.4MHz timestamp clock *1ms. These three unchanged regions
     * are emitted as guards, not mutable patches, by the control builder.
     */
    { ae_format_1; l32i a8,a7,188; slli a6,a6,9 }
.section .notify_native,"ax"
    bgeui a6,6,0x4025e4b6
.section .fanout_native,"ax"
    bgeui a8,6,0x4025eecc
.section .ap_rate_admission_hook,"ax"
    j 0x4027ab88
.section .normal_bytes,"ax"
    { ae_format_1; l32i a10,a2,0x21c; slli a5,a7,7 }
.section .normal_samples,"ax"
    { ae_format_1; l8ui a3,a10,9; slli a11,a7,5 }
.section .raw_direct_return,"ax"
    /* RAW staging just returned. Quarantined RAW-only profile: do not feed
     * legacy48-frame SRC/effect blocks. Preserve this in a2 and producer
     * channel count in a6; the existing converter publishes to the AP ring.
     */
    addmi a3,a2,0x800
    l8ui a3,a3,88
    beqz.n a3,.Lraw_bookkeeping
    mov.n a10,a2
    mov.n a11,a6
    call8 0x4027b6a0
.Lraw_bookkeeping:
    j 0x4027acb1
.section .ap_rate_admission_cave,"ax"
    /* Only enum7 is newly accepted. Match stock enum1/5 status semantics:
     * a7 is zero when inactive and -1 when configuring an active object.
     * a12 is shifted7 by the original continuation:1500<<7=192000.
     */
    beqi a4,7,.Lap_native192
    j 0x4027a1d0
.Lap_native192:
    mov.n a13,a7
    movi a12,1500
    j 0x4027a1d3
.section .raw_stage_finish_cave,"ax"
    /* The original stager has already copied both planes and released its
     * input ring. RAW needs neither the legacy processor at this+840 nor
     * its fixed-frame descriptors. Retain that original tail for arg1=0.
     * Saved incoming arg1 is still at stack+4; no stack/window change.
     */
    l32i.n a8,a1,4
    bnez.n a8,.Lraw_stage_done
    addmi a3,a2,0x800
    j 0x4027b2d2
.Lraw_stage_done:
    retw.n
.section .raw_bytes,"ax"
    { ae_format_1; movi a5,0x224; slli a4,a3,7 }
.section .stage_gate,"ax"
    slli a11,a7,5
    j 0x4027b274
/* Original conditional-filter body is unreachable after stage_gate applies.
 * It is not assumed unused in stock firmware. Restore it on rollback.
 */
.section .stage_count_cave,"ax"
    add.n a2,a2,a15
    movi a14,96
    movi.n a11,0
    j 0x4027b2ef
/* Remaining bypassed filter tail. Host restores the temporary HD literal
 * through the NC alias immediately after status64, with senders stopped.
 */
.section .cache_wrapper,"ax"
.Lhd_literal:
    .word 0x402392b4
.Lclock_literal:
    .word 0x4025d054
.Licache_function:
    .word 0x403085d0
.global cubs_cache_wrapper
cubs_cache_wrapper:
    entry a1,32
    l32r a4,.Lhd_literal
    dhu a4,0
    dhi a4,0
    l32r a4,.Lclock_literal
    dhu a4,0
    dhi a4,0
    memw
    l32r a8,.Licache_function
    callx8 a8
    mov.n a2,a10
    retw.n
.section .stage_publish,"ax"
    slli a12,a7,7
.section .raw_stage_finish_hook,"ax"
    j 0x4027ab98
.section .stage_count_hook,"ax"
    j 0x4027b235
    nop
.section .mono_count_hook,"ax"
    { ae_format_1; beqi a4,1,0x4027b6f2; slli a3,a3,2 }
.section .mono_unshifted_source,"ax"
    /* Stage+524 is unshifted S32; forward in-place mono4B->2B compression
     * reads each sample before writing below the unread source tail.
     */
    { ae_format_1; l8ui a4,a4,89; movi a6,0x524 }
.section .mono_count_cave,"ax"
    movi a7,96
    j 0x4027b6c1
.section .raw_output_bytes,"ax"
    slli a3,a4,6
.section .allowed_rate_mask,"ax"
    { ae_format_1; movi a5,226; sext a2,a2,7 }
.section .allowed_rate_bound,"ax"
    bgeui a4,8,0x4028c541
.end no-transform
