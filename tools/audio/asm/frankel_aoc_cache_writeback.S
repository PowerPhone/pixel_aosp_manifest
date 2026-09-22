/* Offline encoding reference for the complete q192 speaker cache writeback. */
    .section .patch.cache_writeback, "ax"
    .global speaker_cache_writeback
speaker_cache_writeback:
    { ae_format_1; or a10, a3, a3; movi a11, 0x600 }

    .section .patch.cache_writeback_stock, "ax"
    .global speaker_cache_writeback_stock
speaker_cache_writeback_stock:
    { ae_format_1; or a10, a3, a3; movi a11, 0x180 }
