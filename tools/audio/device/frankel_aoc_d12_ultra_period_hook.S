/* Link at F1 runtime address 0x403e867e; exactly replaces one 6-byte FLIX. */

    .text
    .align  1

    .set    period_192_trampoline, 0x403f0c70

    .global frankel_aoc_d12_ultra_period_hook
frankel_aoc_d12_ultra_period_hook:
    j       period_192_trampoline
    _nop
