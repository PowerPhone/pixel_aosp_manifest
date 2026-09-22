ENTRY(powerphone_fmq960_hook)
SECTIONS {
    .text.hook 0x28e308 : { *(.text.hook) }
    .text.device 0x2c11a4 : { *(.text.device) }
    .text.direction 0x2c2054 : { *(.text.direction) }
    .text.original 0x2c6304 : { *(.text.original) }
    .text.result 0x2c66a4 : { *(.text.result) }
}
