SECTIONS
{
    .probe_literal 0x4038fae8 : { *(.probe_literal) }
    .probe_text 0x4038fb34 : { *(.probe_text) }
    .probe_route 0x4038fb56 : { *(.probe_route) }
}
