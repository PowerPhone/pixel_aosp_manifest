#!/usr/bin/env python3
"""Describe a real mono S16 capture without resampling or claiming its clock.

Preserve every original sample; fixed 10ms block metrics expose quiet holes and
startup artifacts. Spectral energy above 48k is not proof of acoustic bandwidth:
corruption, electrical pickup and filter behavior can also create it.
"""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from scipy import signal
from scipy.io import wavfile


def db(power):
    return 10 * np.log10(np.maximum(power, 1e-30))


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('wav', type=Path)
p.add_argument('--output-dir', type=Path, required=True)
p.add_argument('--tone', type=float)
p.add_argument('--tone-start', type=float)
p.add_argument('--tone-stop', type=float)
p.add_argument('--channel', type=int, help='Zero-based original interleaved channel; required for multichannel WAV.')
a = p.parse_args()
rate, pcm = wavfile.read(a.wav)
source_channels = 1 if pcm.ndim == 1 else (pcm.shape[1] if pcm.ndim == 2 else 0)
if source_channels < 1 or (source_channels > 1 and a.channel is None):
    p.error('Multichannel WAV requires explicit --channel index.')
selected_channel = 0 if a.channel is None else a.channel
if not 0 <= selected_channel < source_channels:
    p.error('Channel index outside original WAV channel count.')
if pcm.ndim == 2:
    pcm = pcm[:, selected_channel]
if pcm.ndim != 1 or pcm.dtype != np.int16 or pcm.size < rate:
    p.error('Require an actual mono S16 recording at least one second long.')
if a.output_dir.exists() and any(a.output_dir.iterdir()):
    p.error('Refusing to overwrite an existing report.')
if a.tone is not None and not (0 < a.tone < rate / 2 and
        a.tone_start is not None and a.tone_stop is not None and
        0 <= a.tone_start < a.tone_stop <= len(pcm) / rate):
    p.error('Tone analysis requires valid explicit sample-coordinate bounds.')
a.output_dir.mkdir(parents=True, exist_ok=True)
x = pcm.astype(np.float64) / 32768
block = round(rate * .01)
frames = len(pcm)
blocks = x[:frames // block * block].reshape(-1, block)
block_rms = np.sqrt(np.mean(blocks**2, axis=1))
block_dc = np.mean(blocks, axis=1)
block_zero = np.sum(blocks == 0, axis=1)
block_repeat = np.r_[False, np.all(blocks[1:] == blocks[:-1], axis=1)]
times = (np.arange(len(blocks)) + .5) * block / rate
freq, psd = signal.welch(x, rate, window='hann', nperseg=min(65536, frames),
                         noverlap=min(65536, frames) // 2, scaling='density')
df = float(freq[1] - freq[0])
bands = []
for low, high in ((0, 1000), (1000, 20000), (20000, 24000),
                  (24000, 48000), (48000, 72000), (72000, 96000)):
    high = min(high, rate / 2)
    if low >= high:
        continue
    select = (freq >= low) & (freq < high)
    bands.append(dict(low_hz=low, high_hz=high,
                      integrated_dbfs=float(db(np.sum(psd[select]) * df)),
                      mean_density_dbfs_per_hz=float(db(np.mean(psd[select])))))
freshness = []
for n in (48, 96, 192, 384, 768, 960, 1920):
    if frames <= n:
        continue
    packed = pcm[:frames // n * n].reshape(-1, n)
    repeated_locations = np.flatnonzero(np.all(packed[1:] == packed[:-1], axis=1)) + 1
    repeats = int(len(repeated_locations))
    freshness.append(dict(lag_frames=n, equivalent_seconds=n/rate,
                          equal_sample_fraction=float(np.mean(pcm[n:] == pcm[:-n])),
                          correlation=float(np.corrcoef(x[n:], x[:-n])[0, 1]),
                          adjacent_exact_repeat_blocks=repeats,
                          repeated_block_start_seconds=(repeated_locations * n / rate).tolist(),
                          checked_aligned_blocks=len(packed)))
report = dict(source=str(a.wav.resolve()), original_samples_unmodified=True,
              source_channels=int(source_channels), selected_channel_index=selected_channel,
              channel_selection='Original interleaved channel view; no rewritten WAV or resampling.',
              header_rate_hz=int(rate), frames=frames, header_duration_seconds=frames/rate,
              pcm_format='S16_LE mono', dc=float(np.mean(x)),
              full_record_rms_dbfs=float(db(np.mean(x**2))),
              dc_removed_full_record_rms_dbfs=float(db(np.mean((x-np.mean(x))**2))),
              minimum_pcm=int(pcm.min()), maximum_pcm=int(pcm.max()),
              unique_pcm_values=int(np.unique(pcm).size),
              clipped_samples=int(np.sum((pcm == -32768) | (pcm == 32767))),
              zero_samples=int(np.sum(pcm == 0)),
              block_seconds=block/rate, complete_blocks=len(blocks),
              trailing_frames=frames % block,
              zero_blocks=int(np.sum(block_zero == block)),
              adjacent_identical_10ms_blocks=int(np.sum(block_repeat)),
              block_rms_dbfs_min_median_max=[float(db(v*v)) for v in
                                           np.percentile(block_rms, [0, 50, 100])],
              welch=dict(window='hann', frames_per_window=min(65536, frames),
                         overlap_frames=min(65536, frames)//2, resolution_hz=df,
                         detrend='constant per window; original DC and total RMS are reported separately'),
              spectral_bands=bands, freshness_checks=freshness,
              limits=['Header rate and sample count alone do not establish a physical clock.',
                      'No resampling or denoising. Analysis uses all recorded samples.',
                      'No exact repeated blocks does not exclude skipped samples or subtler corruption.',
                      'Broadband noise and energy above48k are not evidence of acoustic sensitivity there.',
                      'Quiet recordings cannot independently qualify carrier phase or transport jitter.'])
if a.tone is not None:
    selected = x[round(a.tone_start * rate):round(a.tone_stop * rate)]
    tf, tp = signal.periodogram(selected, rate, window='hann', scaling='density')
    tdf = float(tf[1]-tf[0])
    local = np.abs(tf-a.tone) < 1000
    peak = int(np.argmax(np.where(np.abs(tf-a.tone) < 20, tp, 0)))
    background = local & (np.abs(tf-a.tone) > 20)
    report['explicit_interval_tone_evidence'] = dict(
        requested_hz=a.tone, sample_coordinate_interval_seconds=[a.tone_start, a.tone_stop],
        window='hann', detrend='constant over declared interval', fft_resolution_hz=tdf, peak_bin_hz=float(tf[peak]),
        peak_density_dbfs_per_hz=float(db(tp[peak])),
        local_median_density_dbfs_per_hz=float(db(np.median(tp[background]))),
        peak_over_local_median_db=float(db(tp[peak]/np.median(tp[background]))),
        qualification='Spectral component only; full-interval phase/dropout qualification is separate.')
np.savetxt(a.output_dir/'ten-ms-blocks.csv',
           np.column_stack((times, db(block_rms**2), block_dc, block_zero, block_repeat)),
           delimiter=',', header='sample_coordinate_seconds,rms_dbfs,dc,zero_samples,exact_previous_block', comments='')
np.savetxt(a.output_dir/'full-record-psd.csv', np.column_stack((freq, psd, db(psd))),
           delimiter=',', header='frequency_hz,power_per_hz,dbfs_per_hz', comments='')
(a.output_dir/'metrics.json').write_text(json.dumps(report, indent=2)+'\n')
fig, ax = plt.subplots(4, 1, figsize=(12, 13), constrained_layout=True)
ax[0].plot(times, db(block_rms**2), lw=.8)
ax[0].set(xlabel='Original sample coordinate (s)', ylabel='10ms RMS (dBFS)',
          title=f'{a.wav.parent.name}: {rate}Hz header, {frames} samples; not physical clock proof')
sf, st, ss = signal.spectrogram(x, rate, nperseg=4096, noverlap=3072, window='hann', scaling='density')
mesh = ax[1].pcolormesh(st, sf/1000, db(ss), shading='auto', cmap='magma')
fig.colorbar(mesh, ax=ax[1], label='dBFS/Hz')
ax[1].set(xlabel='Original sample coordinate (s)', ylabel='kHz', title=f'Entire recording STFT, Hann4096, {rate/4096:.3f}Hz bins')
ax[2].plot(freq/1000, db(psd), lw=.7)
for edge in (24, 48):
    if edge*1000 < rate/2:
        ax[2].axvline(edge, color='gray', linestyle=':', lw=.7)
ax[2].set(xlabel='kHz', ylabel='dBFS/Hz', title=f'Full-record Welch PSD (per-window mean removed), df={df:.3f}Hz')
if a.tone is not None:
    ax[3].plot(tf, db(tp), lw=.7)
    ax[3].set(xlim=(a.tone-500, a.tone+500), xlabel='Hz', ylabel='dBFS/Hz',
              title=f'Entire declared {a.tone_start}..{a.tone_stop}s interval; not a selected best window')
else:
    ax[3].plot(np.arange(min(frames, round(.005*rate)))/rate*1000,
               x[:min(frames, round(.005*rate))], lw=.7)
    ax[3].set(xlabel='First5ms sample coordinate (ms)', ylabel='Original amplitude /FS')
fig.savefig(a.output_dir/'raw-pcm-evidence.png', dpi=160)
plt.close(fig)
print(json.dumps(report, indent=2))
