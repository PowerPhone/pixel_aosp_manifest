/* Exclusive Cubs 15876290-polygon research prototype. NOT an ordinary path.
 * The host must resolve/guard this boot's D5 AudioEntrypoint, patch the zero
 * endpoint literal, stop all audio services, and activate with F1 I-cache
 * invalidation. Reboot is the only rollback. No capture code is occupied.
 *
 * Keep the original 48-frame, four-slot, 768-byte DMA halves. Default BCLK
 * is 12.288 MHz: FS96 kHz / callback0.5ms. DIRECT_RATE192 selects24.576MHz
 * and callback0.25ms, but TAS2572 still internally decimates to96kHz.
 * Read 384 raw host bytes,
 * place L/R in slots0/1, zero slots2/3; no H0, SRC or protection processing.
 * DIRECT_TWO_SLOTS instead retains768B halves while using96 stereo frames,
 * two slots,12.288MHz and0.5ms; native DMA source/destination bursts are
 * adjusted coherently, with no backing allocation or constructor rerun.
 */
.begin no-transform
.ifndef DIRECT_RATE192
    .set DIRECT_RATE192,0
.endif
.ifdef DIRECT_TWO_SLOTS
    .set DIRECT_FRAMES,96
    .set DIRECT_INPUT_BYTES,768
    .set DIRECT_SLOTS,2
.else
    .set DIRECT_FRAMES,48
    .set DIRECT_INPUT_BYTES,384
    .set DIRECT_SLOTS,4
.endif
.section .entry_hook,"ax"
    j cubs_d5_entry_gate
.section .silence_call,"ax"
    call8 cubs_d5_sink_entry
.section .callback_tolerance,"ax"
.ifdef DIRECT_TWO_SLOTS
    movi a5,-60
.elseif DIRECT_RATE192
    movi a5,-45
.section .callback_shift,"ax"
    /* Two 3-byte scalars replace the original 6-byte parallel packet. */
    slli a5,a5,7
    sub a4,a3,a4
.else
    movi a5,-60
.endif
.section .clock_hook,"ax"
    j cubs_d5_clock_gate
    nop
.ifdef DIRECT_TWO_SLOTS
.section .slot_hook,"ax"
    j cubs_d5_slot_gate
    nop
.section .padding_hook,"ax"
    j cubs_d5_padding_gate
.section .dma_admission_hook,"ax"
    /* This target is beyond J range and L32R is backwards-only. a8 is
     * dead here. Replay the overwritten next stack load in the cave. */
    j .Ldma_admission_jump
    .balign 4
.Ldma_admission_target:
    .word cubs_d5_dma_admission
.Ldma_admission_jump:
    l32r a8,.Ldma_admission_target
    jx a8
    .byte 0
.section .dma_ccr_call,"ax"
    call8 cubs_d5_dma_ccr
.endif

.section .payload,"ax"
.global cubs_d5_sink_entry
cubs_d5_sink_entry:
    j cubs_d5_sink_worker
    .balign 4
.global cubs_d5_endpoint_literal
cubs_d5_endpoint_literal:
    .word 0 /* populated only after boot-local object/vtable guards */
.Lstats_literal:
    .word cubs_d5_stats
.Lendpoint_vtable:
    .word 0x401fdb24
.Lhost_ring_vtable:
    .word 0x4021d118
.ifdef DIRECT_TWO_SLOTS
.Ldma_admission_continue:
    .word 0x40251b4f
.Ldma_admission_reject:
    .word 0x402520e0
.endif
    .org 0x3c /* absolute0x40274440: one dedicated cache line */
.global cubs_d5_stats
cubs_d5_stats:
    /* callbacks, consumed blocks, empty blocks, geometry refusals,
     * last available bytes, not-running blocks (subset of empty),
     * TX geometry, endpoint class, source kind, bytes/frame, ring class,
     * reader identity, capacity, pointer bounds/alignment, last bad value,
     * geometry refusals while a guarded endpoint running flag was nonzero.
     * Host reads after DHWB below. */
    .space 64

.global cubs_d5_sink_worker
cubs_d5_sink_worker:
    /* Windowed CALL8 spills a4..a7 into the top32 bytes of this frame.
     * With ENTRY64 those slots overlap locals+32/+36/+40 below, which
     * corrupts ring geometry only when interrupt/window pressure spills
     * this worker. Reserve96: all locals stay below the save areas. */
    entry a1,96
    l32r a4,.Lstats_literal
    l32i.n a5,a4,0
    addi.n a5,a5,1
    s32i.n a5,a4,0
    l32i a5,a2,0x2b4
    movi a6,768
    beq a5,a6,.Ltx_bytes_ok
    j .Lbad_tx_geometry
.Ltx_bytes_ok:
    l32i a5,a2,0x2a4
    movi a6,DIRECT_FRAMES
    beq a5,a6,.Ltx_frames_ok
    j .Lbad_tx_geometry
.Ltx_frames_ok:
    l32i a5,a2,0x294
    beqi a5,DIRECT_SLOTS,.Ltx_slots_ok
    j .Lbad_tx_geometry
.Ltx_slots_ok:
    /* DMA updates the ping-pong status through uncached memory. Match
     * stock DHI/MEMW ordering before selecting the inactive TX half. */
    l32i a10,a2,0x2dc
    movi a11,64
    call8 0x4023338c
    memw
    l32i a4,a2,0x2dc
    l32i.n a4,a4,0
    movi.n a3,0
    beqz.n a4,.Lfirst_half
    movi a3,768
.Lfirst_half:
    l32i a10,a2,0x208
    l32i.n a8,a10,0
    l32i a8,a8,76
    callx8 a8
    add.n a3,a3,a10
    l32r a4,cubs_d5_endpoint_literal
    beqz a4,.Lempty
    l32i.n a5,a4,0
    l32r a6,.Lendpoint_vtable
    beq a5,a6,.Lendpoint_ok
    j .Lbad_endpoint_class
.Lendpoint_ok:
    /* Mirror stock40265c3c..4a: EP_SETUP may bind a full host ring before
     * EP_ENABLE. Never drain the client's prefill before the native start
     * method sets +34a, or after stop clears it. F1 owns this byte. */
    memw
    addmi a5,a4,0x300
    l8ui a5,a5,0x4a
    bnez a5,.Lendpoint_running
    l32r a8,.Lstats_literal
    l32i.n a9,a8,20
    addi.n a9,a9,1
    s32i.n a9,a8,20
    j .Lempty
.Lendpoint_running:
    /* Fresh boot may leave both format fields zero until PCM setup.
     * Never consume that state: require the exact S32/stereo pair live. */
    l32i a5,a4,0x338
    beqi a5,4,.Lkind_ok
    j .Lbad_kind
.Lkind_ok:
    l32i a5,a4,0x33c
    beqi a5,8,.Lframe_ok
    j .Lbad_frame_bytes
.Lframe_ok:
    l32i a5,a4,0x250
    l32i a6,a4,0x254
    beqz a5,.Lempty
    beqz a6,.Lempty
    l32i.n a8,a5,0
    l32r a9,.Lhost_ring_vtable
    beq a8,a9,.Lring_class_ok
    j .Lbad_ring_class
.Lring_class_ok:
    movi a8,228
    add.n a8,a8,a5
    beq a8,a6,.Lreader_ok
    j .Lbad_reader
.Lreader_ok:
    mov.n a10,a5
    mov.n a11,a6
    l32i.n a8,a5,0
    l32i a8,a8,68
    callx8 a8
    s32i.n a10,a1,28
    l32r a8,.Lstats_literal
    s32i.n a10,a8,16
    movi a9,DIRECT_INPUT_BYTES
    bgeu a10,a9,.Lhave_block
    j .Lempty
.Lhave_block:
    /* Read pointer and bank boundaries. Unlike a naive flat copy, this
     * handles a wrap at the AP service-ring end without overreading. */
    mov.n a10,a5
    mov.n a11,a6
    l32i.n a8,a5,0
    l32i a8,a8,84
    callx8 a8
    s32i.n a10,a1,24
    mov.n a10,a5
    l32i.n a8,a5,0
    l32i a8,a8,76
    callx8 a8
    s32i.n a10,a1,32
    mov.n a10,a5
    l32i.n a8,a5,0
    l32i a8,a8,80
    callx8 a8
    movi a8,DIRECT_INPUT_BYTES
    bgeu a10,a8,.Lcapacity_ok
    j .Lbad_capacity
.Lcapacity_ok:
    movi.n a9,7
    bnone a10,a9,.Lcapacity_aligned
    j .Lbad_capacity
.Lcapacity_aligned:
    l32i.n a8,a1,32
    add.n a9,a8,a10
    s32i.n a9,a1,36
    l32i.n a10,a1,24
    bgeu a10,a8,.Lpointer_above
    j .Lbad_pointer
.Lpointer_above:
    bltu a10,a9,.Lpointer_below
    j .Lbad_pointer
.Lpointer_below:
    movi.n a8,7
    bnone a10,a8,.Lpointer_aligned
    j .Lbad_pointer
.Lpointer_aligned:
    sub a11,a9,a10
    movi a8,DIRECT_INPUT_BYTES
    minu a11,a11,a8
    s32i.n a11,a1,40
    call8 0x4023338c
    l32i.n a8,a1,40
    movi a9,DIRECT_INPUT_BYTES
    beq a8,a9,.Lsource_visible
    sub a11,a9,a8
    l32i.n a10,a1,32
    call8 0x4023338c
.Lsource_visible:
    memw
    l32i.n a8,a1,24
    mov.n a9,a3
    l32i.n a10,a1,36
    l32i.n a11,a1,32
    movi.n a12,0
    movi a15,-256
    movi a7,DIRECT_FRAMES
.Lpack_frame:
    l32i.n a13,a8,0
    l32i.n a14,a8,4
    and a13,a13,a15
    and a14,a14,a15
    s32i.n a13,a9,0
    s32i.n a14,a9,4
.ifdef DIRECT_TWO_SLOTS
    addi.n a9,a9,8
.else
    s32i.n a12,a9,8
    s32i.n a12,a9,12
    addi a9,a9,16
.endif
    addi.n a8,a8,8
    bne a8,a10,.Lnot_wrapped
    mov.n a8,a11
.Lnot_wrapped:
    addi.n a7,a7,-1
    bnez a7,.Lpack_frame
.Lpacked:
    /* Advance exactly the input bytes actually copied. Actual host ring
     * v+60=402981e4 updates the AP service counter and checks its own +d8
     * threshold before delivering the host IRQ (40298245..402982b8).
     * Base AudioEntrypoint virtual+68 is a no-op (4028c7fc); do NOT call the
     * unrelated derived AudioSonicProcessor notification at402669e8. */
    mov.n a10,a5
    mov.n a11,a6
    movi a12,DIRECT_INPUT_BYTES
    l32i.n a8,a5,0
    l32i a8,a8,60
    callx8 a8
    l32r a8,.Lstats_literal
    l32i.n a9,a8,4
    addi.n a9,a9,1
    s32i.n a9,a8,4
    j .Lpublish
.Lbad_geometry:
    mov.n a10,a7
    mov.n a11,a6
    call8 cubs_d5_record_geometry
    l32r a8,.Lstats_literal
    l32i.n a9,a8,12
    addi.n a9,a9,1
    s32i.n a9,a8,12
    j .Lzero
.Lempty:
    l32r a8,.Lstats_literal
    l32i.n a9,a8,8
    addi.n a9,a9,1
    s32i.n a9,a8,8
.Lzero:
    mov.n a8,a3
    movi.n a9,0
    movi a10,192
.Lzero_word:
    s32i.n a9,a8,0
    addi.n a8,a8,4
    addi.n a10,a10,-1
    bnez a10,.Lzero_word
.Lzero_done:
    nop.n
.Lpublish:
    mov.n a10,a3
    movi a11,768
    call8 0x4023339c
    memw
    l32r a8,.Lstats_literal
    dhwb a8,0
    memw
    retw.n
.Lgeometry_abort:
    mov.n a10,a7
    mov.n a11,a6
    call8 cubs_d5_record_geometry
    l32r a8,.Lstats_literal
    l32i.n a9,a8,12
    addi.n a9,a9,1
    s32i.n a9,a8,12
    dhwb a8,0
    memw
    retw.n

.Lbad_tx_geometry:
    movi.n a7,24
    mov.n a6,a5
    j .Lgeometry_abort
.Lbad_endpoint_class:
    movi.n a7,28
    mov.n a6,a5
    j .Lbad_geometry
.Lbad_kind:
    movi.n a7,32
    mov.n a6,a5
    j .Lbad_geometry
.Lbad_frame_bytes:
    movi.n a7,36
    mov.n a6,a5
    j .Lbad_geometry
.Lbad_ring_class:
    movi.n a7,40
    mov.n a6,a8
    j .Lbad_geometry
.Lbad_reader:
    movi.n a7,44
    /* a6 already contains the bad reader pointer. */
    j .Lbad_geometry
.Lbad_capacity:
    movi.n a7,48
    mov.n a6,a10
    j .Lbad_geometry
.Lbad_pointer:
    movi.n a7,52
    mov.n a6,a10
    j .Lbad_geometry

    .balign 4 /* preceding path ends in J */
cubs_d5_record_geometry:
    entry a1,32
    l32r a4,.Lstats_literal
    add.n a5,a4,a2
    l32i.n a6,a5,0
    addi.n a6,a6,1
    s32i.n a6,a5,0
    s32i a3,a4,56
    /* Distinguish startup TX refusals from real active-stream failures,
     * without reading a flag from an unguarded endpoint class. */
    l32r a5,cubs_d5_endpoint_literal
    beqz a5,.Lrecord_done
    l32i.n a6,a5,0
    l32r a7,.Lendpoint_vtable
    bne a6,a7,.Lrecord_done
    memw
    addmi a5,a5,0x300
    l8ui a6,a5,0x4a
    beqz a6,.Lrecord_done
    l32i a6,a4,60
    addi.n a6,a6,1
    s32i a6,a4,60
.Lrecord_done:
    retw.n

.global cubs_d5_entry_gate
    .balign 4 /* unreachable padding after RETW above */
cubs_d5_entry_gate:
    /* Exactly replay the stock ENTRY64 for every other AudioEntrypoint. */
    entry a1,64
    l32r a4,cubs_d5_endpoint_literal
    bne a2,a4,.Lstock_entry
    movi.n a2,1
    retw.n
.Lstock_entry:
    j 0x40265c0b

.global cubs_d5_clock_gate
cubs_d5_clock_gate:
    /* Mid-function trampoline; retain the caller's window and a3=this. */
    l32i a10,a3,0x28c
    movi a11,3
.ifdef DIRECT_TWO_SLOTS
    slli a11,a11,12
.elseif DIRECT_RATE192
    slli a11,a11,13
.else
    slli a11,a11,12
.endif
    s32i a11,a3,0x290
    j 0x40274a7e
.ifdef DIRECT_TWO_SLOTS

cubs_d5_slot_gate:
    /* Native SetSlots must see2 before programming hardware. Keep all
     * allocated byte geometry unchanged:96 frames*2 slots*4 bytes=768. */
    movi.n a4,2
    s32i a4,a3,0x294
    movi a4,96
    s32i a4,a3,0x2a4
    l32i a10,a3,0x348
    movi a2,0x294
    j 0x40274a6d

cubs_d5_padding_gate:
    /* Existing4/8-slot DMA discards slots beyond its four RX words.
     * Two slots have no such padding; never pass signed2-4 as a count. */
    beqi a13,2,.Lno_padding
    addi a10,a13,-4
    j 0x40274b8d
.Lno_padding:
    movi.n a10,0
    j 0x40274b8d

cubs_d5_dma_admission:
    l8ui a7,a2,116
    beqi a7,2,.Ldma_admitted
    beqi a7,4,.Ldma_admitted
    beqi a7,8,.Ldma_admitted
    l32r a8,.Ldma_admission_reject
    jx a8
.Ldma_admitted:
    l32i a8,a1,0x13c
    /* a8 is the immediately overwritten native stack load; it must be
     * live on return, so use a13 (overwritten by the next native insn). */
    l32r a13,.Ldma_admission_continue
    jx a13

    .balign 4 /* unreachable padding after JX above */
cubs_d5_dma_ccr:
    /* Native TX computes source length=slots/4, size=4 (16B), destination
     * length=slots,size=2 (4B). Only slots2 yields source length0: use
     * length1,size3 (8B) to match destination2*4B exactly. Forward every
     * native stack argument; ENTRY80 is window-spill-safe for CALL8. */
    entry a1,80
    l32i a8,a1,80
    bnez a3,.Lccr_original
    bnei a8,2,.Lccr_original
    movi.n a3,1
    movi.n a4,3
.Lccr_original:
    s32i.n a8,a1,0
    l32i a8,a1,84
    s32i.n a8,a1,4
    l32i a8,a1,88
    s32i.n a8,a1,8
    l32i a8,a1,92
    s32i.n a8,a1,12
    l32i a8,a1,96
    s32i.n a8,a1,16
    l32i a8,a1,100
    s32i.n a8,a1,20
    mov.n a10,a2
    mov.n a11,a3
    mov.n a12,a4
    mov.n a13,a5
    mov.n a14,a6
    mov.n a15,a7
    call8 0x40248144
    mov.n a2,a10
    retw.n
.endif
.end no-transform
