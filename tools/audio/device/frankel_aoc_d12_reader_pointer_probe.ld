/* SPDX-License-Identifier: Apache-2.0 */
SECTIONS {
  .reader_pointer_probe_literal 0x403e91f4 : {
    *(.reader_pointer_probe_literal)
  }
  .reader_pointer_probe 0x403e91f8 : { *(.reader_pointer_probe) }
  .reader_pointer_probe_result 0x403e9204 : {
    *(.reader_pointer_probe_result)
  }
}
