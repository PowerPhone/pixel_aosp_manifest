SECTIONS {
    .patch.source_copy 0x403d3878 : { *(.patch.source_copy) }
    .patch.source_copy_hook 0x403d3938 : { *(.patch.source_copy_hook) }
    /DISCARD/ : { *(.xtensa.info) *(.xt.prop) }
}
