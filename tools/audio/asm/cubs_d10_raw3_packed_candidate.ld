SECTIONS {
 .raw_three_admission 0x4027a618 : { *(.raw_three_admission) }
 .normal_stage_skip 0x4027aaa7 : { *(.normal_stage_skip) }
 .producer_destination_hook 0x4025ee4b : { *(.producer_destination_hook) }
 .producer_sample_hook 0x4025ef13 : { *(.producer_sample_hook) }
 .producer_missing_hook 0x4025eee0 : { *(.producer_missing_hook) }
 .producer_post_hook 0x4025ef24 : { *(.producer_post_hook) }
 .packed_stage 0x4027b1c8 : { *(.packed_stage) }
 .producer_sample_cave 0x4027b274 : { *(.producer_sample_cave) }
 .producer_missing_cave 0x4027b2b0 : { *(.producer_missing_cave) }
 .producer_destination_cave 0x4027b2e0 : { *(.producer_destination_cave) }
 .producer_post_cave 0x4027b2f8 : { *(.producer_post_cave) }
 .packed_publish_entry 0x4027b6a0 : { *(.packed_publish_entry) }
}
ASSERT(SIZEOF(.raw_three_admission)==6,"whole channel-admission FLIX packet")
ASSERT(SIZEOF(.normal_stage_skip)==3,"normal stage branch width")
ASSERT(SIZEOF(.producer_destination_hook)==3,"destination hook width")
ASSERT(SIZEOF(.producer_sample_hook)==6,"sample hook whole FLIX packet")
ASSERT(SIZEOF(.producer_missing_hook)==5,"missing path mov+loop width")
ASSERT(SIZEOF(.producer_post_hook)==4,"post path two narrow loads")
ASSERT(SIZEOF(.packed_stage)<=0x67,"stager must end before old stage gate/cache wrapper")
ASSERT(SIZEOF(.producer_sample_cave)<=0x3c,"sample cave boundary")
ASSERT(SIZEOF(.producer_missing_cave)<=0x30,"missing cave boundary")
ASSERT(SIZEOF(.producer_destination_cave)<=0x18,"destination cave boundary")
ASSERT(SIZEOF(.producer_post_cave)<=0x23,"post cave original stager boundary")
ASSERT(SIZEOF(.packed_publish_entry)<=0x18,"publisher must not overlap unused old mono hook")
