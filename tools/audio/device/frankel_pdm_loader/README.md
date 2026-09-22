# Frankel PowerPhone PDM loader

This directory is source material for the opt-in Frankel research image. The
generated-vendor sanitizer copies it into the AOSP tree only together with the
PowerPhone audio sidecar and stages the separately audited
`frankel_pdm_alsa.ko` in vendor-DLKM without adding it to any `modules.load`
list.

At boot the loader waits for the stock AoC card ID at index 0, rejects any
preexisting card 1 or raw-PDM module, inserts the exact
module with all three physical controllers mapped, status token zero, and
polling disabled, then
validates the immutable module parameters, card-1 identity, three capture
nodes, exact mono S32_LE/192000 constraints, and zero status-probe/FIFO
statistics. Only
after every check passes does it set
`vendor.powerphone.pdm.topology_ready=1`. This is deliberately not the
sidecar's `vendor.powerphone.pdm.ready` data-path gate: the inert loader does
not power microphones, apply the A32 transaction, run the AP status probe,
enable polling, or own a
stream lease. Until that broker exists, capture ports remain discoverable but
every start fails closed. The loader remains resident and checks the immutable
module/card topology every two seconds. It clears topology readiness and exits
on a mismatch; init retries a failed loader after five seconds. A retry still
refuses to adopt a preexisting module, so a post-readiness loader crash fails
closed and requires an unload or reboot rather than trusting unknown
provenance.

The same policy directory labels
`vendor.powerphone.aoc_speaker_192k.ready` with a separate vendor-internal
property type and grants `hal_audio_default` read access to both data-path
flags. This loader has permission to set only its topology property. The PDM
data-ready and speaker-ready properties remain zero until separately confined
runtime owners and real-hardware qualification exist.

Mapping registers the module's suspend veto, so the explicitly enabled
research image cannot enter system suspend while the module remains loaded.
On any post-insertion failure the loader first re-proves synchronous
`polling_enabled=0`, unloads the module, and requires both its sysfs directory
and card 1 to disappear. If polling-off cannot be proven, it refuses an unsafe
unload and reports that suspend remains blocked.

This loader deliberately does not configure PDM MMIO, power a microphone,
enable FIFO polling, or claim physical 192 kHz bandwidth. Those actions remain
behind the guarded manual hardware qualification until the single-PDM0 trial
has passed on the real device.

The module currently has no embedded OEM signature. The sanitizer proves that
the staged bytes equal the reviewed local DDK output, while runtime provenance
relies on the research image's AVB boundary plus exact kernel, card, parameter,
PCM-name, topology, and constraint checks. It intentionally does not add an
independent runtime hash check.
