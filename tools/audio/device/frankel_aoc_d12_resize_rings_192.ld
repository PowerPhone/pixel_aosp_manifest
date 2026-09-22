/* SPDX-License-Identifier: Apache-2.0 */
SECTIONS {
  .orig_literal 0x403e7814 : { *(.orig_literal) }
  .stage1 0x403e87d0 : { *(.stage1) }
  .stage2 0x403f649e : { *(.stage2) }
}
