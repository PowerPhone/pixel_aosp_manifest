# Finding a widened DSP path that still plays at the wrong pitch

Use this when a higher ALSA rate is accepted but acoustic pitch, continuity,
or bandwidth is wrong. The Frankel example is 48 to 192 kHz; recompute for
the actual hardware and rate rather than copying its constants or offsets.

## Follow one sample block through every owner

For a fixed period in seconds, derive frames and bytes at each boundary:
sample rate × period, then frames × channels × bytes per sample. TDM slots
are not necessarily PCM channels. Track constructor-derived fields separately
from values subsequently changed by Start or Configure.

Inspect the entire sequence, not just an advertised rate or nested reader:

1. Producer block and notification cadence.
2. Ring capacity, wrap and available/read/write offsets.
3. Reader request, enclosing copy length, and cursor advancement.
4. Mixer iteration count and output stride.
5. Format conversion count and DMA ping-pong offset.
6. Cache extent, descriptor length, and bytes loaded versus stored per burst.

A caller may retain 48 while a patched callee fetches 192. If that caller
copies and advances only 48 stereo S32 frames, it leaves 1152 bytes behind
every iteration. Likewise, changing a DMA destination to two S32 slots while
retaining a 16-byte memory load creates an unequal load/store program even
when descriptors advertise the right overall duration.

Do not enlarge an entire DSP block beyond its existing ring to recover
throughput. Prefer a supported shorter period with the correct per-period
frame count, including the scheduler's expected-size comparisons. A firmware
may deliberately divide notifications by ten when a low-latency block has an
unexpected size. Correct copy geometry alone does not fix that scheduling.

## Use live evidence efficiently

First establish a known playback tone against an independently qualified
capture clock. A zero ALSA xrun counter can coexist with repeated samples,
sideband combs, or wrong pitch inside firmware. Captured CPU/source/DMA buffers
can locate the first corruption point; resolve their live pointers and account
for sequential, non-atomic reads. Active diagnostic traffic can itself starve
the stream, so qualify continuity again without those dumps.

An absent `/proc/asound/.../status` file does not establish closed or broken
PCM state: some kernels omit verbose PCM procfs even while streaming. Use
appropriate driver instrumentation and actual device descriptors. For a
read-only snapshot trigger, a dedicated player's process lifetime can be useful;
for a write-side idle guard, establish ownership and close state explicitly.

Keep a single owner for simultaneous playback/capture setup. Stopping
audioserver twice can restart a HAL or reset a microphone already capturing.
Do not restore Android services until both streams close and routes are off.

## Separate digital continuity from acoustic limits

Analyze the entire stable tone interval, not only the best two seconds.
Preserve interior gaps; exclude only documented outer fades. Use phase windows
short enough to expose the suspected artifact: a 2 ms window averages away a
500 Hz modulation cycle. A pure tone cannot expose a sample slip by an exact
whole number of its periods; combine phase evidence with other tones or coded
stimuli, transfer accounting, and hardware scheduling observations.

Use independently chosen frequencies above lower-rate Nyquist limits and
compare to quiet captures, aliases and harmonics. Coded on/off envelopes help
distinguish intended output from unrelated peaks. PDM noise rising at high
frequencies can bury phase information even when coherent long-window FFT
detects the tone; do not label noise-dominated phase estimates as transport
jitter. Report coherent spectral detectability separately from broadband SNR,
calibrated SPL, and a full transducer frequency response.

## Finish the host and boot paths

At high rates, a small ring may need real-time scheduling and a fuller initial
fill. Respect the actual ring capacity; a larger ALSA period count is not
automatically supported. A successful positive short WRITEI result is normal
progress: advance by the accepted frame count and submit only the remaining
suffix. Never replay accepted samples, count a full request as transferred, or
silently recover an EPIPE and call the run continuous.

If the DSP consumes at the correct rate but reports an empty source immediately
before EPIPE, investigate producer wakeups before changing DSP geometry again.
A 20 ms ring with 10 ms notifications leaves only about 10 ms to refill; keeping
the same capacity but using 1 ms periods can greatly increase refill margin.
On Frankel, 192 frames × 20 periods replaced 1920 × 2 at 192 kHz, with the same
3840-frame full-buffer start threshold. This was tested on the real driver;
do not assume its minimum period size on other hardware. Apply a proven setting
to both diagnostic writers and each production HAL, not just a test command.
Higher thread priority alone did not eliminate the old ten-millisecond failures.

Inspect the actual start transaction as well as `start_threshold`. An explicit
`pcm_start()` on an empty playback ring bypasses the intended automatic prefill.
Where appropriate, let playback writes reach the threshold before starting;
scope this to the affected playback PCM and preserve capture startup. Framework
client underrun counters may miss a lower HAL that automatically prepares and
retries EPIPE. Compare direct capture against the API path, actual duration,
and DSP source-empty logs before calling application playback continuous.

Test the transition to silence and a second playback without restarting audio
services. A framework buffer that improves active batching can make idle pacing
worse: Android's normal mixer can sleep half its buffer duration before sending
silence. If that equals the entire physical ring duration, the first idle write
can underrun and leave a shared HAL stream stuck in ERROR. Reducing the exposed
framework buffer may fix this without enlarging hardware rings or changing
AudioFlinger. On Frankel, a 960-frame/5 ms framework burst with the existing
3840-frame/20 ms ALSA ring enabled FastMixer and passed consecutive 30-second
AAudio and AudioTrack sessions, including their quiet tails. A 192-frame/1 ms
framework burst also enabled FastMixer but increased IPC traffic and failed
one active trial; the smallest possible burst was not the best setting.
Confirm the actual mixer selected, accepted-frame accounting across bursts,
and clean reuse on the target; these numbers are not portable defaults.
Establish the actual command sequence before patching pause/drain methods
that are not invoked at the failing boundary.

An application reporting completion does not mean its HAL released the
hardware. In one real handoff, AudioFlinger retained the research PCM for its
default three-second idle period; ordinary playback then changed the shared
amplifier route before its own PCM open failed with EBUSY. The rollback broke
the still-open research stream. Test both directions of completed-stream
handoff with short gaps. Where the platform provides it,
`ro.audio.flinger_standbytime_ms=0` uses the existing presentation-drain and
standby sequence to remove this idle hold, without a framework source patch.
It is cached at audioserver startup and changes idle policy globally. It is
not arbitration for simultaneously active HALs; that requires a common
hardware owner or coordinated exclusion before either HAL writes routes.

Do not stop at two clean live runs: Frankel's same 5 ms profile failed after
reboot because the kernel queued period work behind shared unbound workers.
Trace queue, execution start and execution end separately. One real D5
notification waited 29.738 ms before a callback that took only 9 microseconds;
that exceeded the entire 20 ms ring. Raising the userspace writer's priority
cannot wake a writer still waiting for a delayed kernel notification. A
sleepable dedicated real-time worker is one remedy to qualify on hardware.
Do not blindly invoke the callback from hard IRQ: a PCM marked `nonatomic`
may acquire a sleeping mutex inside `snd_pcm_period_elapsed`. Preserve work
coalescing, real device counters and flush/destroy lifetime barriers when
changing dispatch, and qualify the new image rather than hiding its xruns.

Qualify the primary and research HALs separately. Frankel's ordinary primary
writer also needed FIFO/90 and 960-frame framework batches; changing only its
priority left measured dropouts. Scope these changes to playback and retain
capture's independent geometry. Check CPU idle-latency policy as well as thread
priority: a real-time task still has to wake a sleeping CPU. The research
profile keeps the existing low-latency idle-residency setting during display
idle, at a documented idle-power cost; it does not lock CPU frequency or
disable thermal protection. A global PowerHAL boolean is not a per-stream
lease, so indiscriminate enable/disable calls can undo another client's hint.

For API clock checks, retain timestamps over the full active run with a fixed,
documented startup exclusion, not just one pair immediately after STARTED.
Require monotonicity, availability and sufficient observation coverage, and
save the full result under a unique run ID. Long native reports can be lost
to log throttling; persist them as files and reject stale or incomplete results.
Accepted-frame/software-time pairs are not hardware presentation timestamps.
Even a passing full-run API clock estimate must be paired with the independent
waveform and HAL error checks, including the transition to silence.

For unexpectedly weak API output, read the active track's port volume and
per-device volume setting before changing amplifier or HAL gain. A research BUS
may retain a different volume index from the built-in speaker even for the same
media stream. Adjust that device while it is selected, then measure without
mid-stream volume changes. An app's successful completion or zero xrun count
does not override a muted/error-state HAL or an implausibly short playback time.
An API volume query made before preferred-device activation can still report
the ordinary speaker's value. Confirm that playback actually started (a locked
screen can immediately cancel a test activity), change volume while the
intended device is active, and inspect the per-device AudioService values.
Treat final volume restoration as another route-handoff test: a responsive UI
and running services do not exclude a latched HAL fault. Check fresh completion
and error logs after the maintenance sequence, not only before it.

Bypass effects whose processing descriptors remain at the old rate, through
existing mixer/HAL controls where possible. Keep amplifier fault protections;
DSP bypass may remove calibrated speaker protection, so use bounded stimulus
levels rather than indiscriminate gain increases.

Integrate the smallest proven change set into boot-time initialization and
the actual HAL route. Remove or back up development overlays that would mask
freshly flashed files. Reboot and repeat the acoustic measurement before
claiming a flashable image reproduces a successful live-memory experiment.
