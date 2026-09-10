/* Absolute addresses are valid only for Frankel AoC 15070001-polygon. */
SECTIONS
{
  .patch.scratch_init     0x78972b86 : { *(.patch.scratch_init) }
  .patch.force_high       0x78972c02 : { *(.patch.force_high) }
  .patch.rate             0x78972c05 : { *(.patch.rate) }
  .patch.src_up_shape     0x78972d58 : { *(.patch.src_up_shape) }
  .patch.src_up_frames    0x78972d64 : { *(.patch.src_up_frames) }
  .patch.src_down_heap    0x78972d94 : { *(.patch.src_down_heap) }
  .patch.src_down_frames  0x78972d9a : { *(.patch.src_down_frames) }
}
