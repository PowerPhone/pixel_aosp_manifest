SECTIONS {
 .raw_mcps_enable_hook 0x40279a06 : { *(.raw_mcps_enable_hook) }
 .raw_mcps_disable_hook 0x40279a22 : { *(.raw_mcps_disable_hook) }
 /* RAW caller's direct-return hook bypasses this old processor body.
  * mono raw_stage_finish_cave ends exactly atabA4; AP rate cave endsab96.
  */
 .raw_mcps_enable_cave 0x4027aba4 : { *(.raw_mcps_enable_cave) }
 .raw_mcps_disable_cave 0x4027abb0 : { *(.raw_mcps_disable_cave) }
}
ASSERT(SIZEOF(.raw_mcps_enable_hook)==5,"enable load+narrow jump")
ASSERT(SIZEOF(.raw_mcps_disable_hook)==5,"disable load+negate")
ASSERT(SIZEOF(.raw_mcps_enable_cave)==11,"enable cave exactsize")
ASSERT(SIZEOF(.raw_mcps_disable_cave)==17,"disable cave exactsize")
