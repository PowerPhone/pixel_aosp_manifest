/* SPDX-License-Identifier: Apache-2.0 */
SECTIONS {
  .batch_start_reset        0x4039e4fc : { KEEP(*(.batch_start_reset)) }
  .batch_start_hook         0x403e8588 : { KEEP(*(.batch_start_hook)) }
  .batch_flush_and_inert    0x403c1814 : { KEEP(*(.batch_flush_and_inert)) }
  .batch_advance_notify     0x403c1a34 : { KEEP(*(.batch_advance_notify)) }
  .batch_no_sync_and_notify 0x403f648d : { KEEP(*(.batch_no_sync_and_notify)) }
  .batch_output_tail        0x403e887f : { KEEP(*(.batch_output_tail)) }

  ASSERT(SIZEOF(.batch_start_reset) == 20, "start reset must end at live 0x4039e510")
  ASSERT(SIZEOF(.batch_start_hook) == 6, "start hook must replace one FLIX")
  ASSERT(SIZEOF(.batch_flush_and_inert) == 28, "A/inert cave overflow")
  ASSERT(frankel_aoc_d12_batch10_inert_callback == 0x403c1828, "inert callback moved")
  ASSERT(SIZEOF(.batch_advance_notify) == 28, "B cave overflow")
  ASSERT(SIZEOF(.batch_no_sync_and_notify) == 51, "no-sync/C cave overflow")
  ASSERT(frankel_aoc_d12_no_sync_wholeblock_mono_aligned == 0x403f6490, "no-sync entry moved")
  ASSERT(frankel_aoc_d12_batch10_notify == 0x403f64a8, "C helper moved")
  ASSERT(SIZEOF(.batch_output_tail) == 85, "output tail must end at 0x403e88d4")

  /DISCARD/ : { *(.comment) *(.note*) }
}
