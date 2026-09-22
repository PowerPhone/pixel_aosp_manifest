# Two-slot speaker DMA burst correction

Status: decoded defect and guarded live experiment; acoustic qualification is
still required. Applies only to Frankel `CP2A.260805.005` with the existing
192-frame, two-S32-slot speaker profile and corrected TX extent `0x600`.

The captured F1 TX program in
`work/audio-research/frankel/pitch-validation/live-framework-rings-20260911/f1-descriptors-after.hex`
starts with `DMAMOV CCR, 0x00054009`. Decoding the CCR gives:

| Field | Existing | Corrected |
| --- | --- | --- |
| Memory source beat | 16 bytes | 8 bytes |
| Memory source burst length | 1 beat | 1 beat |
| Peripheral destination beat | 4 bytes | 4 bytes |
| Peripheral destination burst length | 2 beats | 2 beats |
| TX CCR | `0x00054009` | `0x00054007` |

The bit layout is also defined in the local upstream kernel
`work/upstream/kernel-common-frankel/drivers/dma/pl330.c`: source width at
bits 3:1, source burst length minus one at bits 7:4, destination width at
bits 17:15, and destination burst length minus one at bits 21:18. Widths are
encoded as powers of two in bytes.

Thus every existing `DMALD` puts 16 bytes into the DMA FIFO but its paired
`DMAST` drains only eight. Changing the physical bus from four S32 slots to
two had already changed the destination burst length, while its memory-source
width remained hardcoded at 16 bytes. This is a concrete mismatch in the
generated program; precise audible consequences require hardware measurement.

`DMAStartRingTxRxDualChannel` begins at F1 `0x403aa43c`. The six-byte bundle
at `0x403aa50e` sets the memory-source width exponent in `a12`, passed into
the PL330 CCR builder at `0x403a05d0`. Change only `movi a12,4` to
`movi a12,3`, preserving its paired stack store. The aligned word at
`0x403aa510` becomes `a10f0081` from `a1130081`.

The existing source-width patch was categorized as an S16 alternative and
excluded from the native two-S32 profile. Both layouts nevertheless contain
eight bytes per physical frame. This one width correction is required for
the two-S32 profile as well; the other S16 patches must not be enabled as a
group.

RX CCR `0x00054015` is already balanced at two four-byte beats on each side.
Both descriptor lengths remain `192 * 2 * 4 = 0x600` bytes. The generated
24-iteration loop, with eight unrolled frame transfers per iteration, remains
192 frames. No loop, descriptor length, RX burst, or microphone changes are
part of this experiment.

With Android audio services stopped and D5 closed:

```bash
FRANKEL_AOC_DIAG_DEVICE=/data/local/tmp/frankel_aoc_diag-live \
python3 tools/audio/patch_frankel_aoc_f1_tx_dma_two_slot.py apply \
  --adb /usr/bin/adb --adb-server-port 5037 --serial 57101FDCR00107
```

The script checks the active two-slot geometry and exact affected instruction,
writes the single word, then runs the existing F1 instruction-cache flush.
The next D5 open generates the corrected DMA program. `revert` restores the
previous width; an AoC/device reboot also removes the change. Release helper
integration must remove this word from `UnselectedStockWords` and add it to
the selected mutation transaction after hardware qualification.

Qualify with the requested continuous 12 kHz tone captured by the known-good
D10 microphone, checking pitch, comb sidebands, and phase continuity. Record
the generated CCR and both bank addresses, ALSA xruns, and AoC hardware
timestamp glitches. Successful byte readback alone is not playback evidence.
