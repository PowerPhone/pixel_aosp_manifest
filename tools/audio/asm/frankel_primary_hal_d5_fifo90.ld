ENTRY(powerphone_fifo90_entry)
stock_sched_setscheduler = 0x2e4820;
SECTIONS {
    .text.call 0x28cbe4 : { *(.text.call) }
    .text.priority 0x28cda4 : { *(.text.priority) }
    .text.policy 0x28cec4 : { *(.text.policy) }
    .text.entry 0x2c1a68 : { *(.text.entry) }
}
