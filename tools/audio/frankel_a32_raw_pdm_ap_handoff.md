# Frankel A32 raw-PDM to AP handoff

Status: **retired after the AP-MMIO consumer trial faulted and rebooted the
phone**. The implementation is retained for reverse-engineering history only;
do not apply it on the current PowerPhone image. The qualified capture
transport is AoC card 0, PCM 10 (D10/EP3), not this A32-to-AP handoff.

This helper only clocks a selected PDM controller and makes its raw FIFO fill.
It does not capture, buffer, filter, or decimate the data. Do not run `apply`
until an AP FIFO consumer is installed, is prepared to poll immediately, and
has a tested stop handshake. `apply` therefore requires both
`--ack-hardware-write` and `--ack-ap-consumer-ready`.

All control writes are issued by firmware-owned core 1 through
`CMD_DBG_MEM_SET` on `/dev/acd-factory_diag`. The helper does not ask the AP to
write AoC MMIO. AP access is relevant only to the future FIFO reader.

## Recovered hardware path

The generic A32 PDM manager at `0x7808a26c` constructs the same PdmClockV2
index (`2`) for every PDM ID. The index is hard-coded before controller-ID
selection, so PDM0, PDM2, and PDM3 do not have independent input clocks. They
share:

| Function | A32 address | Relevant field |
|---|---:|---:|
| clock source config/value/status | `0x824d0e00/0e04/0e08` | source/status bit 0 |
| clock divider config/value/status | `0x824d1020/1024/1028` | divider bits 5:0; status bit 0 |
| clock gate config/enable/status | `0x824d07a0/07a4/07bc` | enable bit 0; status bit 8 |
| stock global config | `0x81401000` | exact idle value `0x000001ff`; read-only to this helper |
| PdmV3 activity control | `0x8140100c` | exact zero idle; PdmV3 sets bit 0 around clock start/stop |
| reset control/status | `0x81400000/0008` | one bit per PDM ID in bits 4:0 |

The live PDM4 clock object at `0x4016d030` is the authoritative index record.
It contains source/divider/gate bases `0x024d0de0`, `0x024d1000`, and
`0x024d0760`, with strides `0x10`, `0x10`, and `0x20`. Index 2 therefore
resolves to local `0x024d0e00`, `0x024d1020`, and `0x024d07a0`, which the
clock methods map into the A32 peripheral alias above. The previously used
`0x824d2de0/3000/4760` addresses came from incorrect strides; real-device
reads proved those unrelated blocks remain zero while stock PDM4 operates.
The source and divider status bit is a transient write acknowledgement, not a
stable idle-state bit. A value-preserving store raised it to one, and a later
complete idle audit observed it back at zero without any change to divider 12,
the cached 3.2 MHz rate, or AoC health. Guards therefore allow exact status
words zero or one while requiring the value/configuration registers exactly;
the setter still polls for acknowledgement immediately after a real change.
PdmClockV2's separate vtable `+0x28` method modifies the low nibble of
`0x81401000`, not `0x8140100c`, under a firmware lock. Live stock state already
has that nibble enabled (`0x000001ff`) before and throughout PDM4 use, so the
raw helper preserves the complete word and never writes `0x81401000`.
The individual gate register at `0x824d07a4` follows stock activity, but
`0x824d07bc` bit 8 is not persistent: the complete word was `0x00000001` in
both stock idle and active captures. The helper therefore verifies the gate
enable write exactly and requires the full gate-status word to remain one.
Static tracing establishes that PdmV3 stores `0x8140100c` at `M+0x64`, sets
bit 0 before calling the clock `+0x24(true)` method, and calls
`+0x24(false)` before clearing bit 0. The helper reproduces that exact guarded
ordering; the gate-only reset phase deliberately does not touch it.

The 38.4 MHz parent divided by 8 is exactly 4.8 MHz. Raw PDM decimated by 25
in the AP produces 192 ksample/s. Each microphone contributes 600,000 bytes/s
of PDM payload. The FIFO transports only 24 payload bits in each 32-bit pop,
so the register-read traffic is 800,000 bytes/s per microphone. Three
simultaneous microphones therefore produce 1.8 MB/s of PDM payload and
2.4 MB/s of FIFO MMIO reads before software decimation.

The controller mapping is:

| PDM | A32 controller | AoC-local physical | DT-derived AP `blk_aoc` projection | built-in use |
|---:|---:|---:|---:|---|
| 0 | `0x81c0a000` | `0x01c0a000` | `0x0ac0a000` | built-in DMIC |
| 1 | `0x81c0b000` | `0x01c0b000` | `0x0ac0b000` | no identified Frankel DMIC |
| 2 | `0x81c0c000` | `0x01c0c000` | `0x0ac0c000` | built-in DMIC |
| 3 | `0x81c0d000` | `0x01c0d000` | `0x0ac0d000` | built-in DMIC |
| 4 | `0x81c0e000` | `0x01c0e000` | `0x0ac0e000` | flicker sensor |

The AP projection follows the stock DT `blk_aoc` resource at `0x09000000`
(size `0x02000000`) plus the AoC-local address. The firmware's PDM resource
table independently pairs PDM0 with local `0x01c0a000`, and the same table
places PDM2/PDM3 at `0x01c0c000`/`0x01c0d000`. Thus all three projected FIFO
windows are within the declared Linux resource. This proves the address
translation, but not that the peripheral firewall permits AP reads. A
synchronous AP abort remains possible until a read-only probe succeeds. The
A32 factory-diag path is established for control access; that does not by
itself prove AP FIFO access.

The local clock block projects nominally to AP `0x0b4dxxxx`, but it lies
outside `blk_aoc` and beyond the separately declared `lcpm` resource. The AP
consumer must not map or probe that clock range. In particular,
`0x384d3000` belongs to the separate Aurora/AURDSP mailbox subsystem and is
not an alternate AoC clock alias. Clock/reset sequencing remains exclusively
on the guarded A32 factory-diag path.

For each controller base `B`:

| Offset | Meaning used by the stock firmware |
|---:|---|
| `+0x00` | CONTROL: enable bit 0, selected bit 2, normal mode bit 18, raw bypass bit 22 |
| `+0x04` | A32 interrupt enable/rearm bit 0 |
| `+0x0c` | destructive 32-bit FIFO pop; bits 31:8 are PDM payload and bits 7:0 are ignored by the stock raw converter |
| `+0x10` | FIFO empty in bit 0; no other status/count field is used by the stock PdmV3 path |
| `+0x14` | FIFO watermark |
| `+0x24` | RFactor25 encoding `4` |
| `+0x2c` | stock `pdm_hpf=0` selection in bit 1 |
| `+0x30` | stock setup bits 0, 4, and 9 |

The helper never reads `B+0x0c` and never writes `B+0x04`. Omitting the
stock manager's `+0x88` IRQ-rearm call prevents a dormant A32 callback from
competing with the AP polling consumer. Raw start is the exact stock PdmV3
CONTROL transformation:

```text
new_control = (old_control & 0xffbbfffe) | 0x00400001
```

This clears enable/normal/raw mode first and then selects raw mode plus enable.
Bit 2 is set separately by the stock selection method and is preserved by the
transformation.

## Guarded sequence

`check-idle` requires all of the following before any write-capable command:

- product `frankel`, vendor build `CP2A.260805.005`, completed Android boot,
  working root, and both factory diagnostic character devices;
- every ALSA capture PCM under card 0 reports `closed`;
- every handle reached from A32 list head `0x40130e88` has active byte
  `H+0x04 == 0`;
- all five controllers have CONTROL enable clear, interrupt register exactly
  zero, and FIFO-empty set;
- the stock global config is exactly `0x000001ff`, PDM activity is zero, the
  shared clock gate is off, source mux is the 38.4 MHz selection, transient
  source/divider status contains no unexpected bits, the persistent gate
  status word is exactly one, and the index-2 divider is exactly 12;
- reset control/status agree and every selected controller is out of reset.

Before evaluating those guards, `check-idle` prints the exact captured value
and address of every allowlisted common register and every safe register on
PDM0 through PDM4, followed by every discovered A32 handle (or an explicit
`state=none` for that controller). This diagnostic block is marked
`validation=pending`: it is evidence of the rejected state, not an acceptance
signal. Printing performs no additional target access. The underlying snapshot
uses contiguous groups only where every word is allowlisted, and the
destructive FIFO-pop offset `+0x0c` is absent from every group and printed row.

`apply` saves every observed word in an atomic host JSON snapshot before its
first memory-set command. Each store has an immediate exact full-word pre-read
and post-read. A failed guard, write, poll, or active-state validation reverses
recorded stores in reverse order and restores known controller words affected
by the reset pulse. The default snapshot is
`/tmp/frankel-a32-raw-pdm-<ids>.json`; use `--snapshot` for a durable explicit
path.

For one or more selected controllers, apply performs:

1. Set PdmV3 common activity `0x8140100c` from zero to one, select software
   clock gating, enable the index-2 clock, and verify each persistent control
   register exactly.
2. Pulse each selected reset bit low and high, matching status bits 4:0 after
   each phase.
3. Disable the clock, then restore common activity from one to zero. This
   complete bracket is required for Frankel reset status to follow control.
4. Change only divider bits 5:0 from 12 to 8 and require divider-status bit 0.
5. Write RFactor25 encoding 4, set `B+0x30` bits `0x211`, write watermark 150,
   and select CONTROL bit 2.
6. Set `0x8140100c` from exact zero to exact one, re-enable the shared gate and
   clock, start each controller in raw mode, and select `B+0x2c` bit 1. Leave
   `B+0x04` at zero.
7. Re-read all ownership and active-state guards and persist the exact active
   words to the JSON snapshot.

Because the clock/gate is shared, simultaneous PDM0/PDM2/PDM3 is feasible only
as a coordinated group. Start all three in one `apply --controllers 0,2,3`
transaction and stop all three in the matching `revert`. Starting or stopping
one while another AoC client owns the clock is unsafe.

## Commands (do not run until the AP consumer exists)

From the repository root:

```sh
# Read-only. This is also what running the script without an operation does.
python3 tools/audio/frankel_a32_raw_pdm.py check-idle \
  --controllers 0,2,3 \
  --snapshot /tmp/frankel-pdm023.json

# First install/start the AP consumer in its waiting state. Then, and only
# then, acknowledge both the A32 debug/MMIO writes and consumer readiness.
python3 tools/audio/frankel_a32_raw_pdm.py apply \
  --controllers 0,2,3 \
  --snapshot /tmp/frankel-pdm023.json \
  --ack-hardware-write \
  --ack-ap-consumer-ready

# Read-only verification; it checks the exact active words in the snapshot.
python3 tools/audio/frankel_a32_raw_pdm.py check-active \
  --controllers 0,2,3 \
  --snapshot /tmp/frankel-pdm023.json

# Tell the AP consumer to stop and wait for its confirmed exit before revert.
python3 tools/audio/frankel_a32_raw_pdm.py revert \
  --controllers 0,2,3 \
  --snapshot /tmp/frankel-pdm023.json \
  --ack-hardware-write \
  --ack-polling-stopped
```

`revert` first stops raw production, pulses only the selected reset bits to
flush their FIFOs, disables the shared clock/gate, restores the snapshotted
known controller words and divider 12, validates the full idle guard set, and
retains the JSON as an audit record marked `reverted`.

## AP consumer requirements

The consumer must be ready before `apply`, must poll all selected FIFO-status
registers without starving one controller, and must read a FIFO word only when
that controller's empty bit is clear. It must never assume that the raw word is
PCM. For each little-endian 32-bit pop, discard memory byte 0 (bits 7:0) and
append memory bytes 1, 2, and 3 (bits 15:8, 23:16, and 31:24) to that
controller's PDM stream. The input is a one-bit delta-sigma stream; the AP
needs a real low-pass/decimation-by-25 implementation and explicit bit-order,
edge, polarity, and endpoint calibration.

This packing is recovered from the stock Direct1 raw consumer, not inferred
from throughput. PdmV3 vmethod `+0x98` at A32 `0x4008dcaa` reads `B+0x10`
and masks only bit 0. Vmethod `+0x9c` at `0x4008dcb8` performs one 32-bit load
from `B+0x0c`. The generic manager at `0x7808a6da` rounds a requested byte
count down to a multiple of four, tests empty, copies each pop unchanged, and
accounts four bytes per pop. The Direct1 converter at
`0x780ba7f8..0x780ba8d0` then skips every buffer byte whose index is divisible
by four. It processes the remaining three bytes through the exact nibble
popcount table at `0x4010ce8c`:

```text
00 01 01 02 01 02 02 03 01 02 02 03 02 03 03 04
```

The traced software performs no XOR, raw-bit reversal, sign conversion, or
channel deinterleave before counting one bits. That does not establish which
bit is electrically earliest, which PDM edge is sampled, or whether the
hardware applies a polarity inversion. It also does not reveal a supported
FIFO-depth/count field: only status bit 0 is consumed, so an AP implementation
must use `while (!(status & 1)) pop` rather than interpreting undocumented
status bits. Each controller is handled as an independent stream; no channel
tag is present in the software-visible word format.

The DT/firmware-derived AP FIFO addresses are `0x0ac0a00c`, `0x0ac0c00c`,
and `0x0ac0d00c`; their status addresses are the corresponding bases plus
`0x10`. Prove AP read permission with non-destructive status/control reads
before adding destructive FIFO reads.
There is no AP IRQ resource for A32 IRQs 183/185/186 in the stock DT, so the
first implementation must poll or arrange a separately reviewed handoff.

Stop conditions include any changed target/build identity, active A32 handle,
open ALSA capture, nonzero controller interrupt enable, non-stock divider,
shared gate already in use, controller ownership change, AP mapping fault, or
snapshot mismatch. F1 hotword/audio/ultrasound ownership is not fully visible
through the A32 handle list; the shared-gate and controller-idle checks reduce
that risk but do not prove that every F1 client is quiescent.
