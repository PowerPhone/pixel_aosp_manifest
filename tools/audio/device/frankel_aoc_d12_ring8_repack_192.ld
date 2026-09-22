/* SPDX-License-Identifier: Apache-2.0 */
SECTIONS {
  .repack 0x403f6490 : { *(.repack) }
  .hook   0x403bacb8 : { *(.hook) }
  .advance 0x403ba962 : { *(.advance) }
  .sync   0x403e882d : { *(.sync) }
}
