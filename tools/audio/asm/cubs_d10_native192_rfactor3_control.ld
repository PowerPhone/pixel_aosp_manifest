SECTIONS {
 .rfactor3_native_hook 0x4024e31b : { *(.rfactor3_native_hook) }
 .rfactor3_native_cave 0x4025ee9a : { *(.rfactor3_native_cave) }
 .stream_rate 0x40238845 : { *(.stream_rate) }
 .restart_native_rate 0x4025bf4a : { *(.restart_native_rate) }
 .classify_native 0x4025c335 : { *(.classify_native) }
 .configure_native_rate 0x4025c3bb : { *(.configure_native_rate) }
 .native_timebase 0x4025cda3 : { *(.native_timebase) }
 .native_clock 0x4025d054 : { *(.native_clock) }
 .timestamp_expected_half_ms 0x4025d7a4 : { *(.timestamp_expected_half_ms) }
 .notify_native 0x4025e49f : { *(.notify_native) }
 .fanout_native 0x4025ee8b : { *(.fanout_native) }
 .ap_rate_admission_hook 0x4027a09c : { *(.ap_rate_admission_hook) }
 .normal_bytes 0x4027aac1 : { *(.normal_bytes) }
 .normal_samples 0x4027ab01 : { *(.normal_samples) }
 .raw_direct_return 0x4027ab76 : { *(.raw_direct_return) }
  .ap_rate_admission_cave 0x4027ab88 : { *(.ap_rate_admission_cave) }
  .raw_stage_finish_cave 0x4027ab98 : { *(.raw_stage_finish_cave) }
 .raw_bytes 0x4027abbd : { *(.raw_bytes) }
 .stage_gate 0x4027b22f : { *(.stage_gate) }
 .stage_count_cave 0x4027b235 : { *(.stage_count_cave) }
 .cache_wrapper 0x4027b240 : { *(.cache_wrapper) }
  .stage_publish 0x4027b2b1 : { *(.stage_publish) }
  .raw_stage_finish_hook 0x4027b2cf : { *(.raw_stage_finish_hook) }
 .stage_count_hook 0x4027b2e9 : { *(.stage_count_hook) }
 .mono_count_hook 0x4027b6b8 : { *(.mono_count_hook) }
 .mono_unshifted_source 0x4027b6a9 : { *(.mono_unshifted_source) }
 .mono_count_cave 0x4027b6f2 : { *(.mono_count_cave) }
 .raw_output_bytes 0x4027b721 : { *(.raw_output_bytes) }
 .allowed_rate_mask 0x4028c55a : { *(.allowed_rate_mask) }
 .allowed_rate_bound 0x4028c568 : { *(.allowed_rate_bound) }
}
ASSERT(SIZEOF(.stage_gate)==6,"stage gate packet width")
ASSERT(SIZEOF(.stage_count_cave)==10,"stage count cave width")
ASSERT(SIZEOF(.stage_count_hook)==6,"stage count hook width")
ASSERT(SIZEOF(.mono_count_cave)==6,"mono cave width")
ASSERT(SIZEOF(.mono_count_hook)==6,"mono hook width")
ASSERT(SIZEOF(.cache_wrapper)==46,"cache wrapper must fit bypassed filter tail")
ASSERT(SIZEOF(.raw_direct_return)==18,"RAW caller shortcut and enable gate width")
ASSERT(SIZEOF(.ap_rate_admission_cave)==14,"AP rate admission cave width")
ASSERT(SIZEOF(.ap_rate_admission_hook)==3,"AP rate admission jump width")
ASSERT(SIZEOF(.mono_unshifted_source)==6,"RAW source selector packet width")
