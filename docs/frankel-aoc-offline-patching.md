# Guarded offline Frankel AoC patch workflow

`tools/audio/patch_frankel_aoc_offline_manifest.py` creates an analysis copy
from the exact reviewed stock Frankel `aoc.bin` and a review-complete semantic
JSON manifest. It has no device operations, signing code, firmware-loading
path, runtime memory access, or authentication workaround.

Any change to this OEM firmware invalidates its signature. The resulting file
is **not flashable or loadable** and is not a release image. Its only supported
purpose is offline review, comparison, and further reverse engineering.

The patcher refuses all of the following:

- a source other than the exact 24,791,040-byte stock image with SHA-256
  `ac6d7d86e6aa78379bfa3db5eaea4dadebf8113dc8f46aab52d55f3987064abd`;
- a mismatched superbin version, table geometry, section marker, or reviewed
  external/shared-memory layout;
- an incomplete manifest in write or strict `--validate-only` mode, a missing
  reviewer record, or an unknown schema;
- edits outside the two mapped analysis regions, address/offset disagreement,
  length-changing or overlapping edits, and unexpected stock bytes;
- a candidate whose whole-file digest differs from its supplied output digest
  (a digest is mandatory for write and strict reviewed validation);
- in-place operation, symlink inputs, or replacement of an existing output.

The manifest is semantic rather than an unannotated list of byte offsets. Each
edit must identify its analysis region and address, container offset, exact
before/after bytes, intended audio behavior, and supporting evidence. A
reviewed manifest also commits to the final whole-file digest. The patcher does
not decide that a collection of edits is sufficient for 192 kHz.

An edit record has this shape (placeholders are intentionally not actionable):

```json
{
  "id": "audio.block.reviewed-change",
  "region": "shared",
  "container_offset": "0x...",
  "analysis_address": "0x...",
  "expected_hex": "...",
  "replacement_hex": "...",
  "semantic_intent": "Describe the proved audio-only behavior change.",
  "evidence": ["Path to disassembly and the corresponding design finding"]
}
```

The supported region names are `dsp-external` and `shared`. The tool derives
the expected file-offset/address relation from the reviewed container map and
rejects a manifest that merely asserts an inconsistent pair.

The current placeholder is
`tools/audio/manifests/frankel-aoc-speaker-192k.incomplete.json`. It is
intentionally marked `incomplete-design` and has no edit records, so the tool
will not emit a binary from it. This reflects the remaining SRC-library,
scratch-buffer, clock, DMA, and codec dependencies documented in
`docs/frankel-speaker-192-design-20260905.md`.

The separate
`tools/audio/manifests/frankel-aoc-speaker-192k-constructor-candidate.incomplete.json`
records seven exact in-place constructor/SRC substitutions for review. It is
also `incomplete-design`: its private-heap bounds are statically reconstructed
but not executed, and the complete audio/hardware mode is unqualified. Its
exact records do not make it approved or loadable, and the patcher
intentionally refuses to emit an output from it.

The review-complete counterpart is
`tools/audio/manifests/frankel-aoc-speaker-192k-offline-analysis.json`. Its
scope is deliberately limited to `exact-offline-semantic-byte-construction`:
the seven substitutions, stock guards, instruction encodings, rate-pair
tables, and conservative private-heap bounds passed independent offline
review. It does not claim that the firmware initializes, meets deadlines,
loads, boots, drives a 192 kHz physical bus, or has ultrasonic bandwidth.
The generated ignored-work copy is
`work/audio-research/frankel/speaker-firmware-decomp-20260905/candidate-aoc-speaker192.UNSIGNED-NOT-FLASHABLE.bin`.

## Read-only incomplete-design review

The explicit `--validate-incomplete-design` mode accepts only
`review.status: incomplete-design`. It keeps the exact-stock identity and
container checks, schema/target/reviewer checks, address mapping, stock-byte
guards, non-empty equal-length replacement bytes, and overlap rejection.
The `patch_set.output_sha256` field must be present, but may be JSON `null`.
If a digest is supplied, it must match the calculated preview.

```sh
python3 tools/audio/patch_frankel_aoc_offline_manifest.py \
  work/audio-research/frankel/speaker-firmware-decomp-20260905/device-aoc.bin \
  tools/audio/manifests/frankel-aoc-speaker-192k-constructor-candidate.incomplete.json \
  --validate-incomplete-design
```

This mode constructs the preview only in memory, prints its SHA-256 and
returns without writing a firmware copy or modifying the manifest. It rejects
an OUTPUT argument, the write acknowledgement, and combination with
`--validate-only`. The empty placeholder manifest still fails the non-empty
edit requirement. A successful result establishes structural consistency and
exact byte guards only: it does not review instruction semantics, ownership of
padding, audio correctness, signature/loading requirements, or acoustics.
The manifest remains incomplete. Do not turn a printed preview digest into
a claim of reviewed-complete status.

## Strict reviewed validation and analysis copies

The patcher accepts a review-complete manifest only when it declares artifact
class `unsigned-offline-analysis-copy-only`, review scope
`exact-offline-semantic-byte-construction`, and explicitly sets OEM-signature,
loadable, flashable, hardware-192-kHz, and acoustic-bandwidth qualifications
to false. A non-empty warning list and exact resulting SHA-256 are mandatory.
These checks prevent review completeness from being presented as deployment
or hardware qualification.

The current reviewed manifest validates read-only with:

```sh
python3 tools/audio/patch_frankel_aoc_offline_manifest.py \
  work/audio-research/frankel/speaker-firmware-decomp-20260905/device-aoc.bin \
  tools/audio/manifests/frankel-aoc-speaker-192k-offline-analysis.json \
  --validate-only
```

To create a new analysis copy, explicitly acknowledge its unusable signature:

```sh
python3 tools/audio/patch_frankel_aoc_offline_manifest.py \
  work/audio-research/frankel/speaker-firmware-decomp-20260905/device-aoc.bin \
  tools/audio/manifests/frankel-aoc-speaker-192k-offline-analysis.json \
  work/audio-research/frankel/speaker-firmware-decomp-20260905/candidate-aoc-speaker192.UNSIGNED-NOT-FLASHABLE.bin \
  --acknowledge-unsigned-analysis-copy
```

The synthetic-only regression test does not read or modify real firmware:

```sh
python3 -m unittest tools/audio/test_patch_frankel_aoc_offline_manifest.py
```
