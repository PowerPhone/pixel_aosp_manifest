/* SPDX-License-Identifier: Apache-2.0 */
SECTIONS {
  .scratch_literal 0x403e7814 : { *(.scratch_literal) }
  .allocation_body 0x403e87d0 : { *(.allocation_body) }
  .command_cave 0x4038fb34 : { *(.command_cave) }
}
