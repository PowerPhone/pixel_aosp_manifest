# Frankel guarded raw-PDM ALSA prototype

> **Retired hardware path:** the later AP-MMIO capture trial faulted the AP and
> rebooted the phone. This module is not selected by the current image and must
> not be used as 192 kHz evidence. The qualified transport is AoC card 0,
> PCM 10 (D10/EP3), mono S16_LE/192000.

`frankel_pdm_alsa.ko` is a host-built, experimental external module for the
Pixel 10 (`frankel`) exact GKI build 15739706. It presents three independent
capture devices:

| ALSA PCM device | Physical source | Format |
| --- | --- | --- |
| 0 | PDM controller 0 | mono S32_LE, 192000 Hz |
| 2 | PDM controller 2 | mono S32_LE, 192000 Hz |
| 3 | PDM controller 3 | mono S32_LE, 192000 Hz |

The card index is fixed to ALSA card 1 and module loading fails if that slot is
occupied. This deterministic `CARD_1, DEV_0/2/3` mapping is part of the
research audio-HAL ABI.

This was a prototype for a controlled A32-to-AP FIFO handoff. Its AP access
assumption failed the guarded hardware trial; do not repeat it on the current
PowerPhone image.

## Address and machine guards

The module accepts only this exact live Device Tree identity:

- root `compatible = "google,lga-frankel", "google,lga"`;
- root `model = "FRANKEL MP based on LGA"`;
- one exact `compatible = "google,aoc"` node;
- its named `blk_aoc` resource must be index 0, start `0x09000000`, size
  `0x02000000`.

It derives, rather than independently hard-codes, each mapped address:

```text
controller = blk_aoc.start + 0x01c0a000 + pdm_id * 0x1000
PDM0 = 0x0ac0a000
PDM2 = 0x0ac0c000
PDM3 = 0x0ac0d000
```

No clock, source-mux, gate, DMA, IRQ, or unrelated resource is mapped. The
module never performs an MMIO write and never reserves or takes ownership of
the existing `google,aoc` resource.

## Three explicit safety gates

Default insertion only validates DT and registers inert ALSA PCMs:

```sh
insmod frankel_pdm_alsa.ko
```

Controller mapping requires both load-time acknowledgements:

```sh
insmod frankel_pdm_alsa.ko \
  map_controllers=1 projection_ack=0x0ac0a000 controller_mask=0x1
```

`controller_mask` is immutable, nonzero, and restricted to bits 0, 2, and 3.
It defaults to `0x1`, maps and polls PDM0 only, and is the required first
AP-permission trial. Use `controller_mask=0x0d` only for the later coordinated
PDM0/PDM2/PDM3 trial. All three PCM nodes remain registered in either case,
but opening an unselected PCM fails with `ENODEV`, and unselected controllers
are neither mapped nor read. The mask must exactly match the A32 helper's
`--controllers` selection.

Mapping does not read a controller. Before any destructive FIFO access, the
root-writable `status_probe` parameter performs exactly one synchronous
`B+0x10` read for each controller in `controller_mask`:

```sh
echo 1 > /sys/module/frankel_pdm_alsa/parameters/status_probe
cat /sys/module/frankel_pdm_alsa/parameters/status_probe
```

The successful readback is `1`. This callback is serialized against polling,
does not wake the worker, has no path to `B+0x0c`, and increments
`probe_reads` once per selected controller while every FIFO/data counter stays
unchanged. It is a single-use permission token. The next `polling_enabled`
transition from zero to one consumes it before waking the worker; polling
without a fresh status proof fails with `EPERM`:

```sh
echo 1 > /sys/module/frankel_pdm_alsa/parameters/polling_enabled
```

Writing `0` waits for every in-flight poll-worker status/FIFO read and ALSA
period callback to finish before it returns:

```sh
echo 0 > /sys/module/frankel_pdm_alsa/parameters/polling_enabled
```

The polling worker's inactive-to-active transition is serialized by the same
mutex held by the stop writer. The worker publishes inactive with release
ordering only after its final MMIO read and ALSA period callback; the writer
waits with an acquire load. Therefore, after the `echo 0` command returns, that
polling session cannot perform another MMIO read or callback.

Do **not** run the status probe or enable polling while the A32 controller clock
is gated: even the non-destructive status read could cause an AP external
abort. First load/map the module in its waiting state, run the guarded A32
`apply`, synchronously run and validate `status_probe=1`, and only then enable
polling. Always write `0` and wait for it to return
**before** asking the A32 handoff helper to revert controller ownership or
state. Module unload also forces a synchronous stop before unmapping, but it
cannot order itself against an external A32 command.

While controller mapping is enabled, the module registers a system power
notifier that rejects suspend, hibernation, and restore preparation. This guard
remains active from successful mapping through synchronous polling stop,
unmapping, and sound-card teardown. It protects the complete external A32
apply/poll/revert window from an Android system-sleep transition that could gate
the controller clock. This module stops vetoing system sleep after unload.

## FIFO and decimator assumptions

Static A32 tracing established this provisional read protocol:

- status at `B + 0x10`; bit 0 set means empty;
- a read at `B + 0x0c` destructively pops one 32-bit FIFO word;
- bits 7:0 are discarded;
- bytes at offsets +1, +2, +3 carry 24 PDM bits per word; forward order is
  the provisional default and reverse order is independently selectable.

The electrical chronology was not recoverable from the stock popcount-only
consumer. Immutable load parameters therefore make all candidate orderings
available without rebuilding:

- `pdm_reverse_bytes=0` (provisional default) consumes bytes `+1,+2,+3`;
  value `1` consumes `+3,+2,+1`;
- `pdm_msb_first=0` (provisional default) consumes bit 0 through bit 7 in each
  byte; value `1` consumes bit 7 through bit 0;
- `pdm_invert=0` is normal polarity; value `1` flips every PDM bit.

The selected chronology is printed at load. Pilot/spectral calibration must
choose it on hardware; polarity changes only sign, while byte/bit order affects
time chronology and high-frequency phase. At the expected 4.8 MHz PDM clock,
`/25` produces 192000 signed S32 frames/s.

The default `decimator_order=3` path is a third-order CIC decimator: three
modulo-2^64 signed integrators at the PDM bit rate and three differential-delay
one comb stages at the output rate. Its normalized DC gain is `25^3 = 15625`;
the module divides by 15625 and maps a theoretical full-scale +/-1 PDM input
to S32 `[-2147483647, +2147483647]`. A clipped transient increments the
`clips` counter. The expected CIC3 magnitude at output Nyquist (96 kHz) is
about 0.258, or -11.8 dB relative to DC. That droop is intentional and must be
accounted for when interpreting an ultrasonic sweep.

Load-time `decimator_order=1` selects a centered 25-bit boxcar/CIC1 debug
path with DC gain 25. Both modes preserve their complete decimator state
across FIFO words, ALSA periods, PCM start/stop, and discarded frames for as
long as polling remains enabled. Starting a new polling session resets only
the partial CIC state. Neither mode is a production-quality compensated PDM
low-pass chain. Bit polarity and within-byte phase remain calibration
assumptions.

Polling drains and decimates only the `controller_mask`-selected FIFOs whenever
`polling_enabled=1`. Frames for a closed/stopped PCM are deliberately
discarded, keeping each selected decimator continuous and FIFO drained. PCM
open/close never toggles polling.

Counters are available without an MMIO access:

```sh
cat /sys/module/frankel_pdm_alsa/parameters/stats
```

They report status polls, status-only permission-probe reads, empty polls, FIFO
words, payload bits, decimated
frames, delivered/discarded frames, period notifications, ALSA overruns, and
the last already-observed status value for PDM0/2/3. Lifetime counters are not
reset when polling is toggled; only partial `/25` accumulator state is reset
on a new polling session.

`overruns` counts ALSA ring-buffer XRUNs only. Bit 0 is currently the only
decoded hardware FIFO-status bit, so this prototype cannot yet prove that a
controller FIFO never overflowed or dropped PDM chronology. Do not interpret a
nominal 192000 frame count as a jitter result. Identify and count any hardware
overflow flags, or use a phase-continuous external pilot and spectral analysis,
before calling a capture lossless—especially for the three-controller trial.

## Build and audit

The build reuses the official exact DDK scaffold documented by
`../frankel_pdm_dt_probe/README.md`. From `pixel_aosp_manifest`:

```sh
tools/audio/kernel/frankel_pdm_alsa/build-frankel-gki.sh
```

Direct DDK command:

```sh
cd work/upstream/frankel-gki-15739706/ddk-workspace
tools/bazel build //probes/frankel_pdm_alsa:frankel_pdm_alsa
```

Stable outputs:

```text
work/upstream/frankel-gki-15739706/modules/frankel_pdm_alsa.ko
work/upstream/frankel-gki-15739706/modules/frankel_pdm_alsa.unstripped.ko
```

`build-frankel-gki.sh` verifies exact vermagic, every symbol CRC against the
official `Module.symvers`, and an exact undefined-import allowlist (including
the system-sleep notifier registration). It also rejects the enumerated direct
MMIO-write call families and clock/source/gate address patterns in source, plus
hardware-mutating import-name families in the artifact. Those pattern checks
support, but do not replace, source review of the two `readl()` call sites.

Host packages are the same as the exact DDK bootstrap:

```sh
sudo apt-get install curl git repo python3 unzip tar binutils kmod ripgrep
```

## Exact future guarded hardware trial (not performed)

The required ordering is shown below. Replace `ADB_SERIAL`, module/card paths,
and the snapshot path explicitly; do not paste it into an unattended shell.
The A32 helper runs on the host and its `apply` must complete before the first
AP status read.

```sh
# Host: verify exact kernel, push, then load/map. This does not read MMIO.
adb -s ADB_SERIAL shell uname -r
adb -s ADB_SERIAL push \
  work/upstream/frankel-gki-15739706/modules/frankel_pdm_alsa.ko \
  /data/local/tmp/
adb -s ADB_SERIAL shell su 0 insmod \
  /data/local/tmp/frankel_pdm_alsa.ko \
  map_controllers=1 projection_ack=0x0ac0a000 \
  controller_mask=0x1 decimator_order=3 \
  pdm_reverse_bytes=0 pdm_msb_first=0 pdm_invert=0 \
  status_probe=0 polling_enabled=0

# Host: card/thread are now installed and waiting, with polling still exactly 0.
adb -s ADB_SERIAL shell su 0 cat \
  /sys/module/frankel_pdm_alsa/parameters/polling_enabled
python3 tools/audio/frankel_a32_raw_pdm.py check-idle \
  --serial ADB_SERIAL --controllers 0 \
  --snapshot /tmp/frankel-pdm0.json

# Host: enable the shared 4.8 MHz clock/controllers through guarded A32 writes.
python3 tools/audio/frankel_a32_raw_pdm.py apply \
  --serial ADB_SERIAL --controllers 0 \
  --snapshot /tmp/frankel-pdm0.json \
  --ack-hardware-write --ack-ap-consumer-ready

# Device: first prove one status-only AP access. This cannot pop a FIFO or wake
# the poller. On a fresh PDM0 module, stats must show status=1, probe_reads=1,
# words/bits/frames/delivered/discarded/periods/overruns/clips=0 for PDM0 and
# all-zero activity for unselected PDM2/PDM3.
adb -s ADB_SERIAL shell \
  "su 0 sh -c 'echo 1 > /sys/module/frankel_pdm_alsa/parameters/status_probe'"
adb -s ADB_SERIAL shell su 0 cat \
  /sys/module/frankel_pdm_alsa/parameters/status_probe
adb -s ADB_SERIAL shell su 0 cat \
  /sys/module/frankel_pdm_alsa/parameters/stats

# Device: consume that one-shot proof and start FIFO status/pops, then confirm
# the token readback returned to zero and card 1 remains fixed.
adb -s ADB_SERIAL shell \
  "su 0 sh -c 'echo 1 > /sys/module/frankel_pdm_alsa/parameters/polling_enabled'"
adb -s ADB_SERIAL shell su 0 cat \
  /sys/module/frankel_pdm_alsa/parameters/status_probe
adb -s ADB_SERIAL shell cat /proc/asound/cards

# Device: example PDM0 capture. Device 0=PDM0, 2=PDM2, 3=PDM3.
# 19200 frames is a 100 ms period.
adb -s ADB_SERIAL shell su 0 tinycap /data/local/tmp/pdm0-192k.wav \
  -D 1 -d 0 -c 1 -r 192000 -b 32 -p 19200 -n 4

# After tinycap exits: stop all AP reads synchronously before A32 revert.
adb -s ADB_SERIAL shell \
  "su 0 sh -c 'echo 0 > /sys/module/frankel_pdm_alsa/parameters/polling_enabled'"
adb -s ADB_SERIAL shell su 0 cat \
  /sys/module/frankel_pdm_alsa/parameters/stats
python3 tools/audio/frankel_a32_raw_pdm.py revert \
  --serial ADB_SERIAL --controllers 0 \
  --snapshot /tmp/frankel-pdm0.json \
  --ack-hardware-write --ack-polling-stopped
adb -s ADB_SERIAL shell su 0 rmmod frankel_pdm_alsa
```

After PDM0 AP access and capture are proven, repeat the same complete sequence
with `controller_mask=0x0d`, A32 `--controllers 0,2,3`, and matching snapshot;
capture devices 0, 2, and 3 concurrently so none of the selected FIFOs is
starved. Never select a controller on only one side of the handoff.

Operationally, that is:

1. Verify running `uname -r` exactly matches the module vermagic.
2. Insert with both mapping acknowledgements; leave polling at zero.
3. Apply the separately reviewed A32 raw-PDM handoff, which ungates clocks.
4. Write `status_probe=1`; prove its exact selected/unselected counter deltas
   and zero destructive/data-counter change while polling remains zero.
5. Set `polling_enabled=1`, prove it consumed `status_probe` back to zero, then
   start the selected tinycap PCM.
6. Observe `stats`, ALSA progress, kernel logs, and AoC health.
7. Stop tinycap, write `polling_enabled=0`, and wait for return.
8. Only then revert the A32 handoff; unload the module afterward.

Do not run more than one FIFO consumer, do not enable polling while AoC/F1
still owns or consumes the same FIFO, and do not use this prototype on a
production device.
