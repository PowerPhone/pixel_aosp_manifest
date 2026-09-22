/* Link at F1 runtime address 0x403ba968. */

    .text
    .align  1

    .set    full_ring_byte_count,         0x403ba0f4
    .set    common_advance_write_pointer, 0x403baa05

    .global frankel_aoc_d12_ring8_advance_192
frankel_aoc_d12_ring8_advance_192:
    l32r    a2, full_ring_byte_count
    j       common_advance_write_pointer
