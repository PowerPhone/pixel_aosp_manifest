/* SPDX-License-Identifier: Apache-2.0 */
SECTIONS {
  .mono_constructor_guard 0x403e872d : { *(.mono_constructor_guard) }
  .output_byte_count      0x403e877d : { *(.output_byte_count) }
  .reader_sync_count      0x403e882d : { *(.reader_sync_count) }
  .no_sync_wholeblock     0x403f648d : { *(.no_sync_wholeblock) }
  .copy_loop_count        0x403e883a : { *(.copy_loop_count) }
  .input_advance          0x403e886a : { *(.input_advance) }
  .period_geometry        0x403e867e : { *(.period_geometry) }
  .wholeblock_callback    0x403f0c44 : { *(.wholeblock_callback) }
}
