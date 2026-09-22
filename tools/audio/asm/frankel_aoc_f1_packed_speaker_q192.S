/* CP2A.260805.005 live diagnostic: q192 two-S32 speaker primary mixer.
 * The active branch requires speaker+0x282=1 and +0x281=0.  It constructs
 * the first stereo pair before the optional second pair.  Packed stride8
 * makes the next first pair overwrite the previous optional pair.  The
 * last optional pair is outside the 0x600-byte copied extent but remains
 * within the existing rebased 0xc00-byte source bank.
 */
    .section .patch.primary_frames, "ax"
    .global primary_frames
primary_frames:
    { ae_format_1; s32i a15, a1, 48; movi a13, 192 }

    .section .patch.primary_stride, "ax"
    .global primary_stride
primary_stride:
    { ae_format_1; addi a10, a10, 8; movnez a4, a14, a5 }
