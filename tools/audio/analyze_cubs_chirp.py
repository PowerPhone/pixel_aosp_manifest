#!/usr/bin/env python3
"""Actual mono192k self-loop chirp spectrum, with one fixed low-band timing fit.

No resampling, source/capture normalization, WAV rewriting or best-HF-window
selection. The physical192k coordinate must be established independently.
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

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('wav', type=Path)
p.add_argument('--stimulus', type=Path, required=True)
p.add_argument('--output-dir', type=Path, required=True)
p.add_argument('--channel', type=int, help='Original interleaved channel; required for RAW3.')
p.add_argument('--timing-channel', type=int, help='One declared low-band calibration channel shared across all RAW3 analyses.')
a = p.parse_args()
rate, pcm = wavfile.read(a.wav)
sr, src = wavfile.read(a.stimulus, mmap=True)
meta = json.loads(a.stimulus.with_suffix('.json').read_text())
channels = 1 if pcm.ndim == 1 else pcm.shape[1] if pcm.ndim == 2 else 0
if rate != 192000 or channels not in (1,3) or pcm.dtype != np.int16:
    p.error('Require original mono or RAW3 S16/192k capture.')
if channels > 1 and (a.channel is None or a.timing_channel is None):
    p.error('RAW3 requires explicit --channel and one shared --timing-channel.')
selected = a.channel if a.channel is not None else 0
calibration_channel = a.timing_channel if a.timing_channel is not None else selected
if not (0 <= selected < channels and 0 <= calibration_channel < channels):
    p.error('Channel index outside original WAV.')
original = pcm
pcm = original if channels == 1 else original[:, selected]
cal_pcm = original if channels == 1 else original[:, calibration_channel]
if sr != rate or src.ndim != 2 or src.shape[1] != 2 or src.dtype != np.int32:
    p.error('Require actual stereo S32/192k stimulus.')
if (meta.get('signal'), meta.get('tone_hz'), meta.get('end_tone_hz'), meta.get('duration_seconds')) != ('linear_chirp',18000.,90000.,10.):
    p.error('This bounded analysis requires the actual18k→90k/10s linear stimulus metadata.')
if len(src) != rate*10 or not np.array_equal(src[:,0],src[:,1]):
    p.error('Stimulus must contain10s and identical stereo channels.')
if a.output_dir.exists() and any(a.output_dir.iterdir()):
    p.error('Refusing to overwrite evidence.')
a.output_dir.mkdir(parents=True, exist_ok=True)
x = pcm.astype(float)/32768
f,t,psd = signal.spectrogram(x, rate, window='hann', nperseg=4096,
                            noverlap=3072, detrend='constant', scaling='density')
quiet = (t >= .2) & (t <= .8)
q = np.mean(psd[:,quiet],axis=1)
db = lambda z: 10*np.log10(np.maximum(z,1e-30))
# Timing uses only a fixed low band/time region, not the high-frequency result.
if calibration_channel == selected:
    cal_psd = psd
else:
    _,_,cal_psd = signal.spectrogram(cal_pcm.astype(float)/32768, rate,
        window='hann', nperseg=4096, noverlap=3072,
        detrend='constant', scaling='density')
cal_q = np.mean(cal_psd[:,quiet],axis=1)
low = (f >= 18500) & (f <= 24000)
cal_time = np.flatnonzero((t >= 1.) & (t <= 3.3))
lo_index = np.flatnonzero(low)
peak_index = lo_index[np.argmax(cal_psd[low][:,cal_time],axis=0)]
peak_freq = f[peak_index]
contrast = db(cal_psd[peak_index,cal_time]/np.maximum(cal_q[peak_index],1e-30))
use = (peak_freq >= 19000) & (peak_freq <= 23500) & (contrast >= 10)
all_anchors = t[cal_time]-(peak_freq-18000)/7200
# A real constant-slope ridge gives a cluster of equal onset coordinates.
# Fixed +/-10 ms support rejects unrelated stationary/broadband peaks without
# choosing a high-frequency interval. Save every rejected point as evidence.
candidate_anchors = all_anchors[use]
counts = np.array([np.sum(np.abs(candidate_anchors-v)<=.010) for v in candidate_anchors])
center = candidate_anchors[np.argmax(counts)] if len(counts) else None
ridge_use = use & (np.abs(all_anchors-center)<=.010) if center is not None else use
anchors = all_anchors[ridge_use]
anchor = float(np.median(anchors)) if len(anchors) else None
scatter = float(np.percentile(np.abs(anchors-anchor),95)) if anchor is not None else None
span = float(np.ptp(peak_freq[ridge_use])) if np.any(ridge_use) else 0.
support_fraction = len(anchors)/len(candidate_anchors) if len(candidate_anchors) else 0.
remote_counts = counts[np.abs(candidate_anchors-center)>.050] if center is not None else counts
runner_up = int(np.max(remote_counts)) if len(remote_counts) else 0
valid = bool(len(anchors)>=20 and span>=3500 and scatter<.02 and .5<anchor<3.
             and support_fraction>=.65 and runner_up<len(anchors)*.5)
timing = dict(valid=valid, selected_points=int(len(anchors)), low_band_span_hz=span,
              calibration_original_channel=calibration_channel,
              candidate_points=int(len(candidate_anchors)), ridge_support_fraction=support_fraction,
              separated_runner_up_support=runner_up,
              accepted_onset_seconds=anchor if valid else None,
              candidate_onset_seconds=anchor, anchor_absolute_residual_95_seconds=scatter,
              method='Fixed1.0–3.3s calibration search,18.5–24k spectral peaks; candidate19–23.5k peaks at least10dB over fixedquiet.2–.8s. Densest fixed +/-10ms onset-coordinate cluster distinguishes the rising ridge from unrelated peaks; median(t−(f−18000)/7200) gives ONE anchor. No high-frequency data influences timing.',
              thresholds='At least20points,3500Hz span,95%anchor scatter<20ms,interior onset.5–3s; cluster >=65%of candidates, separated runner-up <50%of support.')
np.savetxt(a.output_dir/'timing-calibration.csv',np.column_stack([t[cal_time],peak_freq,contrast,use.astype(int),ridge_use.astype(int),all_anchors]),
           delimiter=',',header='capture_seconds,low_band_peak_hz,peak_over_quiet_db,candidate,used,onset_coordinate_seconds',comments='')
np.savez_compressed(a.output_dir/'full-original-coordinate-stft.npz',
                    frequency_hz=f,time_seconds=t,psd_fs_squared_per_hz=psd.astype(np.float32))
bands = []
ridge = []
if valid:
    for ti in np.flatnonzero((t >= anchor) & (t <= anchor+10)):
        intended = 18000+7200*(t[ti]-anchor)
        corridor = np.abs(f-intended)<=500
        power = np.sum(psd[corridor,ti])*(f[1]-f[0])
        quiet_power = np.sum(q[corridor])*(f[1]-f[0])
        folded = intended if intended <= 48000 else 96000-intended
        alias_corridor = np.abs(f-folded)<=500
        alias_power = np.sum(psd[alias_corridor,ti])*(f[1]-f[0])
        alias_quiet = np.sum(q[alias_corridor])*(f[1]-f[0])
        ridge.append([t[ti],intended,float(db(power)),float(db(quiet_power)),float(db(power/quiet_power)),
                      folded,float(db(alias_power)),float(db(alias_power/alias_quiet))])
    ridge = np.asarray(ridge)
    np.savetxt(a.output_dir/'whole-chirp-ridge.csv',ridge,delimiter=',',
        header='capture_seconds,intended_hz,corridor_power_dbfs,quiet_corridor_dbfs,contrast_db,fold96_hz,fold96_power_dbfs,fold96_over_quiet_db',comments='')
    for lo,hi in ((18000,30000),(30000,40000),(40000,44000),(44000,48000),
                  (48000,60000),(60000,72000),(72000,90000)):
        rows=ridge[(ridge[:,1]>=lo)&(ridge[:,1]<hi)]
        bands.append(dict(low_hz=lo,high_hz=hi,frames=len(rows),
            median_corridor_over_quiet_db=float(np.median(rows[:,4])),
            fraction_over_6db=float(np.mean(rows[:,4]>6)),
            median_fold96_over_quiet_db=float(np.median(rows[:,7])),
            fold96_fraction_over_6db=float(np.mean(rows[:,7]>6))))
report=dict(source=str(a.wav.resolve()),stimulus=str(a.stimulus.resolve()),original_samples_unmodified=True,
    original_channels=channels,selected_original_channel=selected,
    rate_coordinate_hz=rate,frames=len(pcm),duration_seconds=len(pcm)/rate,
    clipped_samples=int(np.sum((pcm==-32768)|(pcm==32767))),timing=timing,bands=bands,
    stft=dict(window='hann',frames=4096,overlap_frames=3072,resolution_hz=rate/4096,
              analysis_detrend='per-window constant; originalWAV unchanged',corridor_halfwidth_hz=500),
    limits=['Self-loop response combines speaker,air path,microphone andpossibleelectricalcoupling; it cannot localize a cutoff to one component.',
            'Corridor contrast near0dB means no detected chirp excess above quiet; it does not prove zero sensitivity.',
            'Timing derives only from a declared low-frequency calibration; duration drift/sample loss can shift later ridge.',
            'No acoustic96k bandwidth or completion PASS is inferred automatically.'])
(a.output_dir/'metrics.json').write_text(json.dumps(report,indent=2)+'\n')
fig,axes=plt.subplots(2,1,figsize=(12,10),constrained_layout=True)
im=axes[0].pcolormesh(t,f/1000,db(psd),shading='auto',vmin=-150,vmax=-60,cmap='magma')
fig.colorbar(im,ax=axes[0],label='dBFS/Hz')
axes[0].set(xlabel='Original capture seconds',ylabel='kHz',title='Entire unchanged recording, Hann4096 STFT')
if valid:
    axes[0].plot([anchor,anchor+10],[18,90],c='cyan',lw=.6)
    axes[0].plot([anchor+30/7.2,anchor+10],[48,6],c='lime',lw=.6)
    axes[1].plot(ridge[:,1]/1000,ridge[:,4],lw=.8,label='Intended frequency')
    high=ridge[:,1]>48000
    axes[1].plot(ridge[high,1]/1000,ridge[high,7],lw=.8,label='Predicted 96k-domain fold')
    axes[1].legend()
axes[1].axhline(0,c='gray',ls=':');axes[1].axhline(6,c='gray',ls=':')
axes[1].axvline(48,c='gray',ls=':')
axes[1].set(xlabel='Intended chirp frequency(kHz)',ylabel='±500Hz corridor /quiet(dB)',
            title=f'Fixed low-band timing valid={valid}; self-loop, not isolated component response')
fig.savefig(a.output_dir/'whole-chirp-evidence.png',dpi=160)
plt.close(fig)
print(json.dumps(report,indent=2))
