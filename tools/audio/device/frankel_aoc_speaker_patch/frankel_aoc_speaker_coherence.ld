SECTIONS
{
  .allocation_extension 0x40371580 : { *(.allocation_extension) }
  .allocation_entry 0x403e87d0 : { *(.allocation_entry) }
  .cache_literals 0x403f6490 : { *(.cache_literals) }
  .cache_body 0x403f64a4 : { *(.cache_body) }
  ASSERT(SIZEOF(.allocation_extension) == 80, "allocator exceeds zero tail")
  ASSERT(SIZEOF(.allocation_entry) == 24, "D12 entry extent changed")
  ASSERT(SIZEOF(.cache_literals) == 8, "cache literal extent changed")
  ASSERT(SIZEOF(.cache_body) == 28, "cache body exceeds retired D12 padding")
}
