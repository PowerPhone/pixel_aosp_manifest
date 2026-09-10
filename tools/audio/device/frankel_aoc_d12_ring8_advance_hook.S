/*
 * Link at F1 runtime address 0x403bacb8; replace only the first instruction.
 *
 * The alternate route at 0x403bac2d enters directly at 0x403bacbb, so every
 * byte from that address onward must remain stock.
 */

    .text
    .align  1

    .set    full_ring_advance, 0x403ba968

    .global frankel_aoc_d12_ring8_advance_hook
frankel_aoc_d12_ring8_advance_hook:
    j       full_ring_advance
