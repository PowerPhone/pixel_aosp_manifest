/* CP2A.260805.005 F1, DMAStartRingTxRxDualChannel.
 * Full six-byte bundle begins at 0x403aa50e.
 * Stock:   { s32i a8,a1,20; movi a12,4 } = 8e b1 a1 13 00 81
 * Patched: { s32i a8,a1,20; movi a12,3 } = 8e b1 a1 0f 00 81
 * The aligned live write at 0x403aa510 changes a1130081 -> a10f0081.
 * a12 is the source-width exponent passed into the PL330 CCR builder
 * 0x403a05d0: 4 gives 16 bytes, 3 gives 8 bytes.
 */
    .section .patch.tx_dma_source_width, "ax"
    .global tx_dma_source_width
tx_dma_source_width:
    { ae_format_1; s32i a8, a1, 20; movi a12, 3 }
