/* Link at F1 runtime address 0x403e882d; exactly replaces one 6-byte FLIX. */

    .text
    .align  1

    .set    sync_192_trampoline, 0x403f648d

    .global frankel_aoc_d12_ultra_sync_hook
frankel_aoc_d12_ultra_sync_hook:
    j       sync_192_trampoline
    _nop
