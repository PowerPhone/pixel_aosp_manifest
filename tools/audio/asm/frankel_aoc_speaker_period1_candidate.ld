SECTIONS
{
  .expected_cave 0x40371500 : { *(.expected_cave) }
  .account_cave 0x40371540 : { *(.account_cave) }
  .expected_hook 0x4038ca74 : { *(.expected_hook) }
  .account_hook 0x4038cb3d : { *(.account_hook) }
  .period_mode 0x4039d520 : { *(.period_mode) }
}
ASSERT(SIZEOF(.expected_cave) <= 64, "expected-block cave exceeds reserved line")
ASSERT(SIZEOF(.account_cave) <= 64, "accounting cave exceeds reserved line")
ASSERT(SIZEOF(.expected_hook) == 6, "expected-block hook must replace one packet")
ASSERT(SIZEOF(.account_hook) == 6, "accounting hook must replace one packet")
ASSERT(SIZEOF(.period_mode) == 32, "source5 mode cave must fit existing gap")
