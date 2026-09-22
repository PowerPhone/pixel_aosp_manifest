# Stock Frankel 48 kHz speaker-tap recorder decoding

The stock `aocxd` WAV recorder corrupts the layout of the four-byte-sample
`sspk.0` tap. Interpreting its WAV directly as the advertised interleaved
stereo S32 produces one nearly full-scale channel, a much smaller second
channel, and misleading spectral peaks. The underlying retained data does
contain the known 15 kHz stimulus.

This finding is specific to Frankel vendor `CP2A.260805.005`, the stock
48 kHz speaker path, and the observed 1920-frame AoCx packets. It is not a
decoder for the experimental 192 kHz path whose WAV metadata also says
48 kHz. A matching header alone cannot identify the actual transport rate.

## Evidence-backed layout

In every 15,360-byte payload packet, the final 7,680 bytes are exactly zero.
This holds for all 274 packets in the stock Android reference and all 198
packets in the Source-5 S16 direct-playback reference.

The local shipped userspace daemon's
`AocxBuffer::writeCaptureWav(AocxPacket const*)`, at `0x1a030`, calculates
frame count using the packet's channel count and bytes-per-sample fields.
Its multi-channel conversion nevertheless reads and writes 16-bit units
(`ldrh`/`strh`, including the loop near `0x1a880`), processes 10 ms units,
and writes the full advertised byte count near `0x1aa50`. For stereo S32
this populates only half of the allocated zero-initialized output buffer.
This is inspection of the stock recorder binary, not an available C++
source implementation or any modification of the daemon.

The supported inverse for the retained half is:

1. Divide the WAV data into 15,360-byte packets. Reject incomplete packets
   or a packet whose second 7,680 bytes are not all zero.
2. Retain each packet's first 7,680 bytes and divide those bytes into four
   1,920-byte chunks.
3. Interpret each chunk as 960 little-endian unsigned 16-bit units.
   Concatenate its even-indexed units followed by its odd-indexed units,
   reversing the recorder's incorrect 16-bit interleaving.
4. Interpret the restored bytes as interleaved stereo signed 32-bit PCM.
   Each packet yields 960 genuine frames, not the advertised 1920.
5. Preserve the remaining 960 frames of each packet as missing data.
   Their original values were not written to the WAV and cannot be recovered.

The original packet timestamps are also absent from the WAV. Packet-relative
frame positions are therefore a nominal timeline, not an independently
verified clock. Never discard the gaps and label the concatenated samples
as a continuous recording or use this file to certify jitter or underruns.

## Actual 15 kHz results

Evidence is under
`work/audio-research/frankel/stock-kernel-reference-20260905/`.
The analyzer computes spectra separately within observed 20 ms pieces; it
does not join samples across missing intervals. Both references peak in the
15,000 Hz bin (50 Hz bin spacing).

| Reference / channel | Nonzero observed samples | Median 15 kHz amplitude, S32 units | Median tone-energy fraction |
| --- | --- | --- | --- |
| `android-48k`, channel 0 | 211,690 | 1,404,677 | 0.99999757 |
| `android-48k`, channel 1 | 211,646 | 648,450 | 0.99999151 |
| `source5-48k-s16`, channel 0 | 165,480 | 214,739,674 | 0.99999999 |
| `source5-48k-s16`, channel 1 | 165,480 | 214,739,674 | 0.99999999 |

Amplitude medians select packets with 15 kHz amplitude at least half the
maximum observed amplitude, excluding zero. Integer units are preserved;
the DSP's full-scale convention is not inferred, and the differing
stimulus/volume/policy settings preclude a gain comparison from this table.
Channel numbers do not by themselves identify the physical enclosure
speaker. The Source-5 result establishes nonzero digital 15 kHz data at
this tap, not acoustic emission. No ultrasonic bandwidth is qualified.

The Android reference has 263,040 observed plus 263,040 missing frames per
channel. The Source-5 reference has 190,080 observed plus 190,080 missing
frames per channel. The earlier entirely zero tap files still contain zero
in every retained unit; this recorder bug prevents claiming knowledge of
the omitted halves from those files alone.

## Reproduce the analysis

Requires `python3` and `python3-numpy`, already included in the repository's
host package list. Run only on a known stock-48-kHz reference:

```bash
python3 tools/audio/decode_frankel_aocx_sspk48.py --confirm-stock-48k \
  PATH_TO/sspk_tapout20.wav \
  --json-output NEW_REPORT.json --npz-output NEW_GAPPED_TIMELINE.npz
```

The confirmation flag acknowledges the evidence-specific profile. The
decoder rejects unexpected metadata or packet layout and never emits a
continuous WAV. JSON describes the missing range `[960, 1920)` in every
1920-frame packet. The optional NPZ contains a stereo `pcm_s32_units` array
with NaN in missing intervals, an `observed` mask, and nominal rate/packet
geometry. Output paths must be new; original recordings remain unchanged.

Both references now contain `sspk-decoded48.json` and
`sspk-decoded48-with-gaps.npz`, generated from their actual captured WAVs.

The later `ep6-frontend192-backend48` trial also uses this decoder because
its backend and stock AoC pipeline remain at 48 kHz. Its 192 kHz source-file
15 kHz tone appears at 3,750 Hz, with approximately fourfold playback time.
See the [frontend-only trial results](frankel-speaker-routing-20260904.md#stock-48-khz-reference-and-frontend-only-192-khz-trial).
This is not permission to apply the decoder to a genuinely 192 kHz backend
merely because that experiment's WAV header still advertises 48 kHz.
