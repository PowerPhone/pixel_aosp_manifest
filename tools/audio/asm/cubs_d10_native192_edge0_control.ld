INCLUDE cubs_d10_mono192_candidate.ld
SECTIONS {
 .native_receiver_edge_zero 0x4025d1fc : { *(.native_receiver_edge_zero) }
}
ASSERT(SIZEOF(.native_receiver_edge_zero)==3,"replace exactly the native edge load")
