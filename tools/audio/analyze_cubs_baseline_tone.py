#!/usr/bin/env python3
"""Analyze a real Cubs baseline WAV without resampling or best-window selection.

Reuse the existing full-interval detector/math, not the Frankel192k qualification
contract. The supplied WAV rate is a coordinate, NOT proof of physical bandwidth.
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

from analyze_frankel_playback_tone import db, full_active_analysis


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('wav', type=Path)
p.add_argument('--tone', type=float, required=True)
p.add_argument('--expected-duration', type=float, default=2)
p.add_argument('--channel', type=int, help='Zero-based interleaved channel; required for multichannel input. Original WAV is not rewritten.')
p.add_argument('--output-dir', type=Path, required=True)
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
if pcm.ndim != 1 or not np.issubdtype(pcm.dtype, np.signedinteger):
    p.error('Expected actual mono signed-integer D10 capture.')
if not 1000 < a.tone < rate / 2 - 1000:
    p.error('This analyzer requires a carrier at least1kHz below the declared Nyquist rate.')
if a.output_dir.exists() and any(a.output_dir.iterdir()):
    p.error('Analysis destination must be new or empty; preserve previous reports.')
a.output_dir.mkdir(parents=True, exist_ok=True)
samples = pcm.astype(np.float64) / 2**(np.iinfo(pcm.dtype).bits - 1)
original_dc = float(np.mean(samples))
centered = samples - original_dc
active, trace = full_active_analysis(centered, rate, a.tone)
quiet_first, quiet_last = round(.2*rate), round(.8*rate)
quiet = centered[quiet_first:quiet_last]
f_quiet, p_quiet = signal.welch(quiet, rate, nperseg=min(rate, quiet.size), scaling='density')
report = dict(source=str(a.wav.resolve()), original_samples_unmodified=True,
              source_channels=int(source_channels), selected_channel_index=selected_channel,
              channel_selection='Original interleaved channel view; no rewritten WAV or resampling.',
              sample_rate_header_hz=int(rate), frames=int(pcm.size),
              wav_duration_seconds=pcm.size/rate, requested_tone_hz=a.tone,
              expected_playback_seconds=a.expected_duration,
              dc_before_analysis=original_dc,
              all_file_rms_dbfs=float(db(np.mean(samples**2))),
              saturated_samples=int(np.sum((pcm == np.iinfo(pcm.dtype).min) | (pcm == np.iinfo(pcm.dtype).max))),
              quiet_interval_seconds=[.2, .8], full_active_interval=active,
              limits=['WAV sample rate is not independent physical clock or bandwidth proof.',
                      'No resampling; all samples between detected outer carrier boundaries retained; only fixed50ms fade margins removed.',
                      'Single-tone phase cannot detect a slip by an exact whole number of carrier cycles.',
                      'A recorded line alone does not distinguish acoustic transmission from electrical coupling; amplifier-off and spatial controls remain useful.',
                      'Transport logs, elapsed sample production and missing intended tail must be assessed separately.'])
if active['measurable']:
    fs, psd = trace['frequency'], trace['psd']
    quiet_bins = np.abs(f_quiet-a.tone) <= max(3, 3*(f_quiet[1]-f_quiet[0]))
    quiet_power = float(np.sum(p_quiet[quiet_bins]) * (f_quiet[1]-f_quiet[0]))
    report['active_requested_line_over_quiet_db'] = active['requested_tone_dbfs'] - float(db(quiet_power))
    report['expected_interior_seconds'] = max(0., a.expected_duration-.1)
    report['interior_duration_error_seconds'] = active['analyzed_duration_seconds'] - report['expected_interior_seconds']
    np.savetxt(a.output_dir/'whole-active-phase.csv',
               np.column_stack([trace['time'], trace['amplitude'], trace['residual'], trace['good'].astype(int)]),
               delimiter=',', header='capture_seconds,demod_amplitude,phase_residual_rad,above_amplitude_floor', comments='')
else:
    fs = psd = None
(a.output_dir/'metrics.json').write_text(json.dumps(report, indent=2) + '\n')

fig, axes = plt.subplots(4, 1, figsize=(12, 12), constrained_layout=True)
times = np.arange(samples.size)/rate
axes[0].plot(times[::max(1, rate//5000)], samples[::max(1, rate//5000)], lw=.6)
axes[0].set(xlabel='Capture sample coordinate (s)', ylabel='Amplitude /FS', title=f'Original capture, {rate}Hz header; no resampling')
if active['measurable']:
    axes[0].axvspan(active['outer_detected_start_seconds'], active['outer_detected_stop_seconds'], color='orange', alpha=.18)
freq, st, spec = signal.spectrogram(centered, rate, window='hann', nperseg=4096, noverlap=3072, scaling='density')
axes[1].pcolormesh(st, freq/1000, db(spec), shading='auto', vmin=-150, vmax=-50, cmap='magma')
axes[1].axhline(a.tone/1000, color='cyan', lw=.7)
axes[1].set(xlabel='Capture sample coordinate (s)', ylabel='kHz', title=f'Full-record STFT: Hann4096, df={rate/4096:.4g}Hz, dBFS/Hz')
axes[2].plot(f_quiet, db(p_quiet), label='Fixed quiet0.2..0.8s', alpha=.7)
if fs is not None:
    axes[2].plot(fs, db(psd), label='Entire detected tone interior')
axes[2].set(xlim=(max(0, a.tone-1000), min(rate/2, a.tone+1000)), xlabel='Hz', ylabel='dBFS/Hz')
axes[2].legend()
if active['measurable']:
    axes[3].plot(trace['time'], trace['residual'], lw=.7)
    axes[3].set(title=f"Full interior: {active['analyzed_duration_seconds']:.4f}s; phase events>{.35}rad={active['phase_step_over_035rad_count']}, dropout blocks={active['amplitude_dropout_blocks']}")
else:
    axes[3].text(.05, .5, active.get('reason', 'No measurable interval'), transform=axes[3].transAxes)
axes[3].set(xlabel='Capture sample coordinate (s)', ylabel='Carrier phase residual (rad)')
fig.savefig(a.output_dir/'full-capture-analysis.png', dpi=150)
plt.close(fig)
print(json.dumps(report, indent=2))
