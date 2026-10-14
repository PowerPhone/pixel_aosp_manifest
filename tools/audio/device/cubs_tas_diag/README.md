# Cubs TAS2572 clock readback

This diagnostic does not change routes, amplifier configuration, gains, or
interrupt latches. It opens `/dev/tas_audio_dev` read-only and reads only book0,
page0 registers `07`, `08`, `09`, `0a`, and `14`. No raw I²C access or page dump.
Use on the two-amplifier Cubs platform with the matching `tas25xx` misc ABI.
Channel0 is top and channel1 bottom in the captured Cubs tuning/logs; this is
not a universal TAS25xx channel assignment.

Build from the manifest repository root:

```bash
bash tools/audio/device/cubs_tas_diag/build.sh
```

The build uses the existing AOSP clang and API35 libc stubs and emits
`work/audio-research/cubs/bin/cubs_tas_diag`; it does not install or contact a
phone. The hardware owner can push it to `/data/local/tmp/cubs_tas_diag`, make
it executable, and run while the selected speaker's clocks are active:

```sh
/data/local/tmp/cubs_tas_diag --channel 1 --samples 20 --interval-ms 100
# Lower-overhead clock-only polling; no inferred Hz without family readback:
/data/local/tmp/cubs_tas_diag --channel 1 --detect-only --samples 20 --interval-ms 100
```

The count is bounded (1–100); interval is20–1000ms between completed samples.
Output contains monotonic timestamps. Driver I²C retries can lengthen timing;
the hardware owner should wrap this with a host/device timeout. An error or
changing read pair is retained as `ERROR` and makes the final exit nonzero.
Readback may be invalid when clocks are off or changing. Avoid aggressive
polling: this driver logs each register request.

## Why this ABI is safe for concurrent driver access

`work/upstream/google-modules-amplifiers/tas25xx/src/tas25xx-misc.c`,
`tas25xx_file_read`, implements an unusual seven-byte input/output read buffer:
`{2, channel, register_BE32, response_byte}`. Command2 is defined by
`inc/tas25xx-misc.h`. For count7 it reads precisely one register, holding
`file_lock`. The `read` callback is `tas25xx_dev_read` in `tas25xx-regmap.c`,
which also holds `dev_lock` around book/regmap access. Regmap serializes page
selection; all queried registers are volatile, so these are hardware reads.
The captured live module's `tas25xx_file_read` disassembly has the same binary
branch (`count <9`) and locking. No changes to that kernel module are needed.

The driver's error path can return the requested byte count without updating
the caller buffer. Therefore every selected register is read twice with two
different response sentinels; both values and returned command headers must
agree. A clock changing between reads is reported, not silently retried away.
The register set is fixed in source: no arbitrary write or fault-latch access
is exposed. The driver's alternative ASCII pending-operation interface has
global state across calls and is deliberately unused.

## Interpreting the result

For four32-bit slots, SBCLK/FSYNC=128: `TDM_DET` (`14`) should be`35` at96k or
`36` at192k (12.288/24.576MHz respectively). Bits6:3 encode ratio; bits2:0
encode rate. Register`07` bit6 selects48k-family (0) versus44.1k-family (1).
Register`08` contains frame polarity(bit7), justification(6), offset(5:1),
and capture edge(0). Register`09` bits3:2 select word length(3=32bits), bits1:0
slot length(2=32bits); bits5:4 choose channel mapping. Register`0a` contains
right/left slot indices in its high/low nibbles. Read these fields; do not
overwrite the complete bytes. TI explicitly permits192k input but internally
converts it to96k: correct`36` readback is transport evidence, not96k acoustic
bandwidth. [TI SLASF66, tables7-40 and7-55–58/67](https://e2e.ti.com/cfs-file/__key/communityserver-discussions-components-files/6/074.02572.0001_5F00_TAS2572YCGR_5F00_SPEC.pdf).

## Actual failure compared with the working96k trial

`work/audio-research/cubs/direct96-v2-20260922/duplex30013-bottom-mic0/logcat-live.txt`
records bottom-channel interrupt register`62=00` at00:32:37.405; no invalid
ratio/sample-rate-change events appear in that session.

`work/audio-research/cubs/direct192-v1-20260922/duplex30013-bottom-mic0/logcat-live.txt`
records`62=0b` at00:41:00.547, initially cleared as a startup clock event, then
the same flags at00:41:00.646. At00:41:00.650 the driver logs action4 but
explicitly ignores force-power-on for a clock-only interrupt. Thus the error
recurred100ms after startup; it is not proven to be only a single stale latch.
Neither log records settled`14`. Read it during a properly prefilled stream
before deciding whether the192k clock/ratio itself is stable.
