# Device-side audio helpers

Directory status for the current Frankel work:

| Path | Status | Image inclusion |
| --- | --- | --- |
| `frankel_aoc_d10_patch/` | Live-hardware-qualified D10 transport helper | Selected only with `POWERPHONE_AUDIO_SIDECAR=true` |
| `frankel_powerphone_d10_bootstrap/` | D10 boot orchestrator and policy | Selected only with `POWERPHONE_AUDIO_SIDECAR=true` |
| `frankel_aoc_speaker_patch/` | Exact native-q192 EP6/source-5 helper; dynamically allocates/rebases four F1 sink rings, conditionally selects H0 192-frame/1,536-byte geometry only for enum-7/one-millisecond Configure, and replaces both AudioEntrypoint quantum getters in place | Selected only with `POWERPHONE_AUDIO_SIDECAR=true` |
| `frankel_aoc_staged_play/` | Raw-WRITEI D0 player for the hardware-qualified native-q192 `1920x2`, start-threshold-1920 path | Selected only with `POWERPHONE_AUDIO_SIDECAR=true` |
| `frankel_aoc_diag/` | Transient diagnostic transport | Not selected |
| `frankel_pdm_loader/` | Retired card-1 AP-PDM experiment | Explicitly rejected by the current image closure |
| Root-level `.S`, `.ld`, and `frankel_pcm_hold.c` files | Historical D10/D12 probe and patch fragments | Not selected |

“Selected” means copied into the generated Frankel vendor tree by the reviewed
sanitizer and bound through generated-vendor, build-output, and bundle
attestation. It does not mean that every physical or Android API acceptance
gate has passed. See `../../../docs/frankel-powerphone-image-integration.md`
for the current image contract.
