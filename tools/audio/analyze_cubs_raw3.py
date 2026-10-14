#!/usr/bin/env python3
"""Analyze actual Cubs RAW3 capture without rewriting/resampling original WAV.

This aggregates all three physical192k channel views, full-tone analyses,
freshness, interchannel comparisons and fixed quiet spectra. It does not infer
physical clock or acoustic bandwidth from the header or quiet noise alone.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from scipy import signal
from scipy.io import wavfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('wav', type=Path)
p.add_argument('--tone', type=float, help='Known real stimulus; omit for a quiet-only recording.')
p.add_argument('--expected-duration', type=float, default=2)
p.add_argument('--output-dir', type=Path, required=True)
a = p.parse_args()
rate, pcm = wavfile.read(a.wav)
if rate != 192000 or pcm.ndim != 2 or pcm.shape[1] != 3 or pcm.dtype != np.int16 or len(pcm) < rate:
    p.error('Require actual three-channel S16/192k WAV at least one second long.')
if a.output_dir.exists() and any(a.output_dir.iterdir()):
    p.error('Refusing to overwrite analysis evidence.')
a.output_dir.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent
summaries = []
for channel in range(3):
    dest = a.output_dir/f'channel-{channel}'
    dest.mkdir()
    commands = []
    if a.tone is not None:
        commands.append(('tone', [str(root/'analyze_cubs_baseline_tone.py'), str(a.wav),
                  '--channel', str(channel), '--tone', str(a.tone),
                  '--expected-duration', str(a.expected_duration), '--output-dir', str(dest/'tone')]))
    commands.append(('raw', [str(root/'analyze_cubs_raw_pcm.py'), str(a.wav),
                 '--channel', str(channel), '--output-dir', str(dest/'raw')]))
    for label, command in commands:
        with (dest/f'{label}-console.txt').open('w') as log:
            subprocess.run([sys.executable, *command], stdout=log, stderr=subprocess.STDOUT, check=True)
    tone = json.loads((dest/'tone/metrics.json').read_text()) if a.tone is not None else None
    raw = json.loads((dest/'raw/metrics.json').read_text())
    active = tone['full_active_interval'] if tone is not None else {}
    summaries.append(dict(channel_index=channel,
        full_record_dc_fs=raw['dc'], minimum_pcm=raw['minimum_pcm'], maximum_pcm=raw['maximum_pcm'],
        unique_pcm_values=raw['unique_pcm_values'], clipped_samples=raw['clipped_samples'],
        zero_10ms_blocks=raw['zero_blocks'], exact_repeat_checks=raw['freshness_checks'],
        full_tone={k:v for k,v in active.items() if k not in ('phase_event_capture_seconds', 'amplitude_dropout_events')}))

quiet = pcm[round(.2*rate):round(.8*rate)].astype(np.float64) / 32768
quiet_reports = []
fig, ax = plt.subplots(figsize=(12, 6), constrained_layout=True)
for ch in range(3):
    q = quiet[:, ch]
    freq, psd = signal.welch(q, rate, window='hann', nperseg=16384, noverlap=8192,
                             detrend='constant', scaling='density')
    db = lambda value: float(10*np.log10(max(float(value), 1e-30)))
    bands = []
    for lo, hi in ((1000,20000),(20000,24000),(24000,48000),(48000,60000),
                   (60000,72000),(72000,84000),(84000,95000)):
        mask = (freq >= lo) & (freq < hi)
        bands.append(dict(low_hz=lo, high_hz=hi,
                          mean_density_dbfs_per_hz=db(np.mean(psd[mask])),
                          median_density_dbfs_per_hz=db(np.median(psd[mask]))))
    quiet_reports.append(dict(channel_index=ch, sample_bounds=[38400,153600],
        dc_fs=float(q.mean()), ac_rms_dbfs=db(np.mean((q-q.mean())**2)), bands=bands))
    np.savetxt(a.output_dir/f'quiet-channel-{ch}-psd.csv', np.column_stack([freq,psd]),
               delimiter=',', header='hz,linear_psd_fs_squared_per_hz', comments='')
    ax.plot(freq/1000, 10*np.log10(np.maximum(psd,1e-30)), lw=.7, label=f'Original channel{ch}')
ax.set(xlabel='Frequency(kHz), physical192k coordinate supplied by experiment', ylabel='dBFS/Hz',
       title='All RAW3 channels, fixed quiet0.2–0.8s; Hann16384/50%overlap; no bandwidth inference')
ax.axvline(24, c='gray', ls=':'); ax.axvline(48, c='gray', ls=':'); ax.legend()
fig.savefig(a.output_dir/'quiet-all-channels.png', dpi=160)
plt.close(fig)
with np.errstate(invalid='ignore', divide='ignore'):
    full_corr = np.corrcoef(pcm, rowvar=False)
    quiet_corr = np.corrcoef(quiet, rowvar=False)
pairs = []
for left, right in ((0,1),(0,2),(1,2)):
    pairs.append(dict(channels=[left,right],
        identical_entire_file=bool(np.array_equal(pcm[:,left],pcm[:,right])),
        exact_equal_sample_fraction=float(np.mean(pcm[:,left] == pcm[:,right])),
        full_correlation=float(full_corr[left,right]) if np.isfinite(full_corr[left,right]) else None,
        quiet_correlation=float(quiet_corr[left,right]) if np.isfinite(quiet_corr[left,right]) else None))
report = dict(source=str(a.wav.resolve()), original_samples_unmodified=True,
    header_rate_hz=rate, frames=len(pcm), header_duration_seconds=len(pcm)/rate,
    channels=3, format='S16_LE interleaved', stimulus_hz=a.tone,
    expected_tone_seconds=a.expected_duration if a.tone is not None else None, per_channel=summaries,
    interchannel=pairs, fixed_quiet=quiet_reports,
    limits=['Physical192k is an externally established experiment coordinate, not inferred from WAV header.',
            'All original channels retained; no resampling, normalization or channel-file rewrites.',
            'High correlation under a shared tone does not imply duplicate microphones; exact equality is reported separately.',
            'Noise shape does not prove acoustic sensitivity near96k or exclude electrical coupling.',
            'Capture startup deficit and transport errors must be assessed from original session logs.'])
(a.output_dir/'matrix.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(dict(source=report['source'], frames=len(pcm), channels=3,
    tone_summary=[dict(channel=s['channel_index'], **s['full_tone']) for s in summaries],
    interchannel=pairs), indent=2))
