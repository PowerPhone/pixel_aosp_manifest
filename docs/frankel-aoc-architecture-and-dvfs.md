# Frankel AoC architecture and DVFS notes

This note records observations from the Pixel 10 (`frankel`) running vendor
build `CP2A.260805.005`. It describes the local hardware/firmware evidence
used by the PowerPhone audio work; it is not a claim about every Tensor
generation.

## Physical boundary

AoC is an independently managed subsystem integrated into the Tensor SoC. It
is not a separate packaged device on the phone's main board. The extracted
Frankel device tree describes `/aoc@9000000` with SoC MMIO ranges, IOMMU stream
IDs, mailbox channels, reserved memory, and the separate `sswrp_aoc_pd` and
`aoc_core_pd` power domains. The authenticated `aoc.bin` firmware runs an A32
control core plus F1, HF0, and HF1 firmware cores and communicates with Android
through the AoC kernel and mailbox drivers.

## Frequency and power control

The stock firmware contains DVFS operating points at 72, 96, 144, 192, 288,
384, 576, and 800 MHz. Its A32 debug command accepts a local diagnostic vote:

```sh
echo 'dvfs vote 800' > /dev/acd-debug
```

On real hardware, the firmware's `cpu_freq_test` reported
`cpu_ticks_delta = 800002220` over its one-second reference interval after
that vote. This proves that the A32 clock can reach 800 MHz. Use `dvfs vote 0`
to release the diagnostic vote. It does not prove or force F1 frequency: the
`dvfs vote` handler hard-codes A32 client ID 30, while the hidden
`dvfs vote_id` handler still calls the A32-local DVFS object. Do not use
`dvfs vote_id 1 ...` as an `AUDIO_INPUT_PDM`/F1 workaround.

The safe read-only F1 diagnostic is the firmware's `DVFSFF1` object on core 2:

```sh
echo 'dbg info -c 2 DVFSFF1' > /dev/acd-debug
timeout 0.5 cat /dev/acd-debug
```

It reports F1 frequency and per-application MIPS. Relevant firmware client IDs
are 1 (`AUDIO_INPUT_PDM`) and 5 (`AUDIO_OUTPUT_EP`). Serialize this one-shot
transaction against any live-patch apply/revert operation that also owns
`/dev/acd-debug`. A persistent F1 floor or RTOS-priority edit is not justified
by the former partial duplex capture: that run inherited a card-wide short
ALSA wait, and the corrected isolated-timeout run delivered its exact expected
capture frames while playback remained active.

Voltage can be held at nominal from the live firmware CLI with
`force_nominal_voltage on`, queried with `force_nominal_voltage status`, and
released with `force_nominal_voltage off`. The Android property
`persist.vendor.aoc.firmware.force_nominal_voltage=1` instead makes `aocd`
request the kernel's force-VNOM mode before loading firmware and therefore
takes effect on the next AoC/device boot. The PowerPhone image sets this
property from its vendor `post-fs-data` action, after persistent properties are
loaded and before `aocd` starts in `late_start`, so an older stored value cannot
silently remove the voltage floor.

The guarded diagnostic power-state command is:

```sh
echo 'aoc-power 90 0 0 0 0' > /dev/acd-debug
```

Its arguments are seconds followed by A32, F1, HF0, and HF1 state. The exact
firmware mapping is `0=ON`, `1=WFI`, `2=RETENTION`, and `3=OFF`; A32/F1 reject
OFF and HF0/HF1 reject RETENTION. The command restores the previous states
automatically at expiry. In particular, `3 3 3 3` is not an all-awake setting
and must never be used for an audio qualification run.

DVFS policy retains per-core votes and clock selection. Consequently, a high
A32 CLI vote is not proof that every processing core is continuously executing
at that rate. AoC's `AMixSPKR` logger showed both
749--780 MHz windows and later low effective-progress windows while the
aggregate vote remained 800. Treat those workload measurements separately
from `cpu_freq_test`; do not infer a silicon frequency ceiling from one low
`AMixSPKR` window.

## Current speaker stability result

The real-mailbox PCM0,D0 path completed a nominal 60-second stereo
S32_LE/192000 transfer:

```text
Played 92160000 bytes with 0 xrun(s). Remains 0 bytes.
AoC restart/coredump: 0/0 -> 0/0
```

That pass used the 480-frame-by-four-period ALSA geometry, the q48 F1 speaker
profile, nominal voltage, the 800-MHz A32 diagnostic vote, an all-ON timed
power request, and `tinyplay` at SCHED_FIFO priority 90. The otherwise
identical SCHED_OTHER run transferred every byte but reported one xrun. A
960-frame-by-two-period experiment is invalid for this route: it watchdoged
AoC during prepare and must not be exposed as a supported geometry.

This is only a stability result. A later clean-hardware timing measurement
showed D0 `SOURCE_ON` to `SOURCE_OFF` taking 19.98 seconds for a WAV declaring
960,000 frames (5.00 seconds at 192 kHz). The q48/source-0 pipeline therefore
consumes this nominal 192 kHz stream at exactly one quarter rate, 48 kHz. Byte
counts, zero xruns, and the ALSA-declared rate do not qualify its physical
sample clock or ultrasonic bandwidth. A native q192 pipeline must still pass
the same elapsed-time and Nyquist tests.

The Android sidecar therefore requires its playback worker to enter
`SCHED_FIFO/90` before acquiring or binding the D0 route. Failure to obtain
that policy is terminal; it does not fall back to `SCHED_OTHER` or simulate
hardware pacing with sleeps.

This is a q48 compatibility-transport result with the amplifiers disabled. It
does not prove 192 kHz physical playback or ultrasonic acoustic bandwidth.
