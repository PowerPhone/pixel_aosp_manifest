/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Reboot-volatile Fullband Ultrasonic callback-pointer probe for Frankel.
 *
 * The callback-table entry normally points at the occupancy drain at
 * 0x403f0c44.  While this probe is armed it points here instead.  The probe
 * records the callback processor (`a2`) in an audited data cave, then
 * tail-jumps to the unchanged drain.  The reader can subsequently be read at
 * `processor + 0x828`.  It has no stack frame and therefore preserves the
 * exact windowed callback ABI.
 *
 * This reads and writes only AoC-local SRAM.  It never accesses the AP-side
 * PDM/FIFO projection.
 */

    .section .reader_pointer_probe_literal,"a"
    .align 4
reader_pointer_probe_result_literal:
    .long reader_pointer_probe_result

    .set occupancy_drain, 0x403f0c44

    .section .reader_pointer_probe,"ax"
    .align 1
    .global frankel_aoc_d12_reader_pointer_probe
frankel_aoc_d12_reader_pointer_probe:
    l32r    a10, reader_pointer_probe_result_literal
    s32i    a2, a10, 0
    j       occupancy_drain

    .section .reader_pointer_probe_result,"aw"
    .align 4
reader_pointer_probe_result:
    .long 0
