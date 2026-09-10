/* SPDX-License-Identifier: Apache-2.0 */
SECTIONS {
  .advance 0x403ba962 : { *(.advance) }
  .commit_then_notify 0x403c1814 : { *(.commit_then_notify) }
  .notify_after_commit 0x403c1a34 : { *(.notify_after_commit) }
  .suppress_precommit_notify 0x403bacb5 : { *(.suppress_precommit_notify) }
}
