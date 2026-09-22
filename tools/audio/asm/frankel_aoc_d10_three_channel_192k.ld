SECTIONS
{
  .destination_hook 0x403baa2d : { *(.destination_hook) }
  .near_bridges 0x403baa84 : { *(.near_bridges) }
  .producer_body 0x403baa98 : { *(.producer_body) }
  .producer_hook 0x403baaf4 : { *(.producer_hook) }
  .missing_hook 0x403bab37 : { *(.missing_hook) }
  .raw_enable_bound 0x403da908 : { *(.raw_enable_bound) }
  .main_return_hook 0x403dae1a : { *(.main_return_hook) }
  .stage_gate 0x403db6ba : { *(.stage_gate) }
  .direct_body 0x403db6c2 : { *(.direct_body) }
}
ASSERT(SIZEOF(.destination_hook) == 3, "replace only destination ID load")
ASSERT(SIZEOF(.raw_enable_bound) == 8, "replace only original channel-bound packet")
ASSERT(SIZEOF(.near_bridges) == 20, "two literals and two long-jump trampolines")
ASSERT(SIZEOF(.missing_hook) == 3, "replace original three-byte missing-source setup")
ASSERT(SIZEOF(.producer_body) <= 0x3d, "remain inside skipped enum5 branch")
ASSERT(SIZEOF(.producer_hook) == 6, "replace original six-byte per-channel packet")
ASSERT(SIZEOF(.stage_gate) == 8, "replace original eight-byte branch packet")
ASSERT(SIZEOF(.main_return_hook) == 6, "replace only original six-byte caller packet")
ASSERT(SIZEOF(.direct_body) <= 0xd6, "remain inside bypassed non-RAW body")
