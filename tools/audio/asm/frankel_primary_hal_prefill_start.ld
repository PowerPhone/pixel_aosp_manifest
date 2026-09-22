ENTRY(powerphone_start_hook)
stock_pcm_start = 0x2e4460;
rate_helper_ret = 0x2c212c;
SECTIONS {
    .text.hook 0x28cde4 : { *(.text.hook) }
    .text.deferred 0x2c1a68 : { *(.text.deferred) }
    .text.gate 0x2c1a84 : { *(.text.gate) }
    .text.device 0x2c2784 : { *(.text.device) }
    .text.direction 0x2c6004 : { *(.text.direction) }
}
