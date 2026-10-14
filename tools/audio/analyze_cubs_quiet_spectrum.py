#!/usr/bin/env python3
"""Fixed physical-time quiet-window comparison of original mono S16 captures.

Physical rates are explicit externally established inputs, not inferred from WAV
headers. No resampling, normalization, favorable-window selection or denoising.
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


def db(x):
    return float(10 * np.log10(max(float(x), 1e-30)))


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--record', nargs=3, action='append', required=True,
               metavar=('LABEL', 'PHYSICAL_RATE', 'WAV'))
p.add_argument('--output-dir', type=Path, required=True)
a = p.parse_args()
if a.output_dir.exists() and any(a.output_dir.iterdir()):
    p.error('Refusing to overwrite existing evidence.')
a.output_dir.mkdir(parents=True, exist_ok=True)
results = []
fig, axes = plt.subplots(2, 1, figsize=(12, 9), constrained_layout=True)
for idx, (label, physical, path) in enumerate(a.record):
    physical = int(physical)
    if physical not in (32000, 48000, 64000, 96000, 192000):
        p.error('Require one of the independently established control clock rates.')
    rate, pcm = wavfile.read(path)
    if pcm.ndim != 1 or pcm.dtype != np.int16 or len(pcm) < physical:
        p.error(f'{path}: require at least one physical second of mono S16.')
    lo, hi = round(.2 * physical), round(.8 * physical)
    q = pcm[lo:hi].astype(np.float64) / 32768
    segment = round(physical * (16384 / 192000))
    freq, psd = signal.welch(q, fs=physical, window='hann', nperseg=segment,
                             noverlap=segment//2, detrend='constant', scaling='density')
    step = freq[1] - freq[0]
    bands = []
    for low, high in ((100, 1000), (1000, 20000), (20000, 24000),
                      (24000, 32000), (32000, 40000), (40000, 47000),
                      (48000, 60000), (60000, 72000), (72000, 84000),
                      (84000, 95000)):
        if high > physical / 2:
            continue
        select = (freq >= low) & (freq < high)
        bands.append(dict(low_hz=low, high_hz=high,
                          integrated_dbfs=db(np.sum(psd[select]) * step),
                          mean_density_dbfs_per_hz=db(np.mean(psd[select])),
                          median_density_dbfs_per_hz=db(np.median(psd[select]))))
    boundary_comparisons = []
    for boundary in (24000, 48000):
        if boundary + 4000 >= physical / 2:
            continue
        below = (freq >= boundary-4000) & (freq < boundary-1000)
        above = (freq >= boundary+1000) & (freq < boundary+4000)
        boundary_comparisons.append(dict(boundary_hz=boundary,
            below_band_hz=[boundary-4000, boundary-1000],
            above_band_hz=[boundary+1000, boundary+4000],
            median_density_change_db=db(np.median(psd[above]))-db(np.median(psd[below]))))
    report = dict(label=label, source=str(Path(path).resolve()), header_rate_hz=int(rate),
                  supplied_physical_rate_hz=physical, original_samples_unmodified=True,
                  quiet_physical_seconds=[.2, .8], quiet_sample_bounds=[lo, hi],
                  quiet_header_seconds=[lo/rate, hi/rate],
                  dc_fs=float(q.mean()), ac_rms_dbfs=db(np.mean((q-q.mean())**2)),
                  quiet_min_pcm=int(pcm[lo:hi].min()), quiet_max_pcm=int(pcm[lo:hi].max()),
                  quiet_unique_values=int(np.unique(pcm[lo:hi]).size),
                  clipped_samples_entire_file=int(np.sum((pcm == -32768) | (pcm == 32767))),
                  welch=dict(window='hann', frames=segment, overlap_frames=segment//2,
                             resolution_hz=float(step), detrend='constant per window'),
                  bands=bands, cutoff_neighborhoods=boundary_comparisons)
    results.append(report)
    np.savetxt(a.output_dir/f'{idx:02d}-quiet-psd.csv',
               np.column_stack([freq, psd]), delimiter=',',
               header='physical_hz,linear_psd_fs_squared_per_hz', comments='')
    axes[0].plot(freq / 1000, 10*np.log10(np.maximum(psd, 1e-30)),
                 lw=.7, label=label, alpha=.85)
    axes[1].plot([.5*(b['low_hz']+b['high_hz'])/1000 for b in bands],
                 [b['median_density_dbfs_per_hz'] for b in bands], '.-', label=label)
report = dict(records=results, limits=[
    'Clock rates are explicit externally established control inputs, not WAV-header proof.',
    'Fixed quiet physical0.2..0.8s; no resampling or original-WAV modification.',
    'A rising high-frequency noise floor is consistent with noise shaping, but may also contain quantization/electrical noise.',
    'Noise-floor shape and absence of an apparent24/48k cutoff do not demonstrate acoustic sensitivity or full Nyquist bandwidth.',
    'No speaker stimulus occurs in the designated quiet interval; intentional acoustic controls above48k remain necessary.'])
(a.output_dir/'quiet-comparison.json').write_text(json.dumps(report, indent=2)+'\n')
for ax in axes:
    ax.set(xlabel='Physical frequency (kHz)', ylabel='dBFS/Hz', xlim=(0, 96))
    ax.axvline(24, ls=':', c='gray'); ax.axvline(48, ls=':', c='gray')
    ax.grid(alpha=.15); ax.legend()
axes[0].set_title('Fixed physical quiet0.2–0.8s: Hann Welch, resolution11.71875Hz')
axes[1].set_title('Fixed-band median spectral density; no bandwidth inference')
fig.savefig(a.output_dir/'quiet-spectrum-comparison.png', dpi=160)
plt.close(fig)
print(json.dumps(report, indent=2))
