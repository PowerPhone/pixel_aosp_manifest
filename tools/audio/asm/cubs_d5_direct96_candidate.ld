SECTIONS {
 .dma_admission_hook 0x40251b40 : { *(.dma_admission_hook) }
 .dma_ccr_call 0x40251ba8 : { *(.dma_ccr_call) }
 .entry_hook 0x40265c08 : { *(.entry_hook) }
 .silence_call 0x40274219 : { *(.silence_call) }
 .callback_tolerance 0x40274260 : { *(.callback_tolerance) }
 .callback_shift 0x40274265 : { *(.callback_shift) }
 .payload 0x40274404 : { *(.payload) }
 .clock_hook 0x40274a78 : { *(.clock_hook) }
 .slot_hook 0x40274a67 : { *(.slot_hook) }
 .padding_hook 0x40274b8a : { *(.padding_hook) }
}
ASSERT(SIZEOF(.dma_admission_hook)==0 || SIZEOF(.dma_admission_hook)==15,"DMA admission guard plus stack load width")
ASSERT(SIZEOF(.dma_ccr_call)==0 || SIZEOF(.dma_ccr_call)==3,"DMA CCR call width")
ASSERT(SIZEOF(.slot_hook)==0 || SIZEOF(.slot_hook)==6,"slot setup packet width")
ASSERT(SIZEOF(.padding_hook)==0 || SIZEOF(.padding_hook)==3,"padding instruction width")
ASSERT(SIZEOF(.entry_hook)==3,"entry hook must replace only ENTRY64")
ASSERT(SIZEOF(.silence_call)==3,"silence call width")
ASSERT(SIZEOF(.callback_tolerance)==3,"timing comparison width")
ASSERT(SIZEOF(.callback_shift)==0 || SIZEOF(.callback_shift)==6,"timing packet width")
ASSERT(SIZEOF(.clock_hook)==6,"clock hook must replace exact format1 packet")
ASSERT(ADDR(.payload)+SIZEOF(.payload)<=0x40274868,"payload must stay in replaced worker")
