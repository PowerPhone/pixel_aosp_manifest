#!/usr/bin/env python3
"""Inspect an actual three-channel PCM16/192k recording without altering it.

Use a quiet lead of at least1.2s and an explicit nominal stimulus-start anchor.
CW mode reuses the existing full-active-interval phase/dropout analysis; no
best-window phase result replaces a full interval. Sweep mode saves all STFT
rows and every predicted ridge observation across all three repetitions.
No automatic hardware-bandwidth PASS is produced.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile

from analyze_frankel_playback_tone import full_active_analysis

RATE = 192000


def db(power):
    return float(10 * np.log10(max(float(power), 1e-30)))


def safe(value):
    if isinstance(value, dict):
        return {key: safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [safe(item) for item in value]
    if isinstance(value, (float, np.floating)):
        return float(value) if np.isfinite(value) else None
    if isinstance(value, np.integer):
        return int(value)
    return value


def write_csv(path, header, rows):
    with path.open('w', newline='') as output:
        writer = csv.writer(output)
        writer.writerow(header)
        writer.writerows(rows)


def freshness(pcm):
    # Do not hash blocks: compare the actual PCM words directly. A periodic
    #50k tone has a96-frame period, so repeated192-frame blocks need not be stale.
    frames = 192
    count = len(pcm) // frames
    blocks = pcm[:count * frames].reshape(count, frames)
    equal = {}
    for lag in (1, 2, 4, 8, 16):
        matched = np.all(blocks[lag:] == blocks[:-lag], axis=1) if count > lag else np.zeros(0, bool)
        locations = np.flatnonzero(matched) + lag
        equal[str(lag)] = {'compared_pairs': len(matched),
                           'exact_equal_pairs': int(matched.sum()),
                           'first_20_later_block_indices': locations[:20].tolist()}
    zero = np.all(blocks == 0, axis=1)
    constant = np.all(blocks == blocks[:, :1], axis=1)
    return {'block_frames': frames, 'block_seconds': frames / RATE,
            'complete_blocks': count, 'unexamined_tail_frames': len(pcm) - count * frames,
            'all_zero_blocks': int(zero.sum()), 'constant_blocks': int(constant.sum()),
            'lag_blocks_exact_comparisons': equal,
            'interpretation': 'Diagnostic observations only, not freshness proof. Periodic tones, silence and common acoustic input can cause equal blocks; fresh transfer requires independent kernel/API timing and route evidence.'}


def cw_analysis(values, output, channel, expected_duration, start, quiet_start, quiet_stop):
    # The new three-channel startup transient precedes the deliberately quiet
    # lead. Anchor the detector at the declared quiet interval, never at the
    # loudest recording span. Keep the unaltered full-file metrics separately.
    # Retain every remaining sample: internal gaps and an early final stop must
    # remain visible rather than being hidden by a selected comparison window.
    offset = round(quiet_start * RATE)
    evidence, arrays = full_active_analysis(values[offset:], RATE, 50000)
    for key in ('outer_detected_start_seconds', 'outer_detected_stop_seconds',
                'analyzed_start_seconds', 'analyzed_stop_seconds'):
        if key in evidence:
            evidence[key] += offset / RATE
    if 'phase_event_capture_seconds' in evidence:
        evidence['phase_event_capture_seconds'] = [t + offset / RATE for t in evidence['phase_event_capture_seconds']]
    for event in evidence.get('amplitude_dropout_events', []):
        event['capture_start_seconds'] += offset / RATE
    if arrays:
        arrays['time'] += offset / RATE
    planned = values[round(start * RATE):round((start + expected_duration) * RATE)]
    quiet = values[round(quiet_start * RATE):round(quiet_stop * RATE)]
    window = min(RATE, len(quiet), len(planned))
    frequency, planned_psd = signal.welch(planned, RATE, nperseg=window, scaling='density')
    _, quiet_psd = signal.welch(quiet, RATE, nperseg=window, scaling='density')
    df = frequency[1] - frequency[0]
    intended = np.abs(frequency - 50000) <= max(3, 3 * df)
    nearby = np.abs(frequency - 50000) <= 10
    peak = int(np.argmax(np.where(nearby, planned_psd, -1)))
    left, center, right = np.log(np.maximum(planned_psd[peak - 1:peak + 2], 1e-30))
    denominator = left - 2 * center + right
    correction = .5 * (left - right) / denominator if denominator else 0
    carrier = float(np.sum(planned_psd[intended]) * df)
    quiet_carrier = float(np.sum(quiet_psd[intended]) * df)
    local = (np.abs(frequency - 50000) >= 100) & (np.abs(frequency - 50000) <= 1000)
    local_equal_band = float(np.median(planned_psd[local]) * np.sum(intended) * df)
    evidence['planned_narrow_line'] = {
        'window': 'Hann', 'window_frames': window, 'frequency_bin_hz': float(df),
        'peak_within_10hz_of_intended_hz': float(frequency[peak] + np.clip(correction, -.5, .5) * df),
        'intended_band_power_dbfs': db(carrier),
        'same_band_quiet_power_dbfs': db(quiet_carrier),
        'intended_band_over_quiet_db': db(carrier / max(quiet_carrier, 1e-30)),
        'intended_band_over_equal_band_local_noise_db': db(carrier / max(local_equal_band, 1e-30)),
        'interpretation': 'Uses the entire declared nominal30s interval and the declared quiet reference, even when envelope/phase is unmeasurable. A nearby peak alone is not a qualified carrier or physical-bandwidth proof.'}
    write_csv(output / f'channel-{channel}-planned-spectrum.csv',
              ['frequency_hz', 'planned_psd_fs_squared_per_hz', 'quiet_psd_fs_squared_per_hz'],
              zip(frequency, planned_psd, quiet_psd))
    evidence['nominal_stimulus_start_seconds'] = start
    evidence['declared_quiet_interval_seconds'] = [quiet_start, quiet_stop]
    evidence['detector_input_interval_seconds'] = [offset / RATE, len(values) / RATE]
    evidence['planned_interval_all_samples'] = {
        'capture_interval_seconds': [start, start + expected_duration],
        'frames': len(planned), 'expected_frames': round(expected_duration * RATE),
        'rms_dbfs': db(np.mean(planned * planned)),
        'peak_abs_fs': float(np.max(np.abs(planned))),
        'samples_above_0_999fs': int(np.sum(np.abs(planned) > .999)),
        'interpretation': 'All samples in the declared nominal30s window are counted, including any gaps. Launch/PCM startup latency can shift actual onset relative to this nominal anchor; the separate full detected interval is accepted only with bounded onset/offset and complete-duration evidence.'}
    evidence['expected_stimulus_seconds'] = expected_duration
    evidence['covers_expected_duration_with_250ms_boundary_allowance'] = bool(
        evidence['measurable'] and evidence['analyzed_duration_seconds'] >= expected_duration - .25
        and abs(evidence['outer_detected_start_seconds'] - start) <= .25
        and abs(evidence['outer_detected_stop_seconds'] - start - expected_duration) <= .25)
    if arrays:
        write_csv(output / f'channel-{channel}-cw-phase.csv',
                  ['capture_seconds', 'carrier_demod_amplitude', 'phase_residual_rad', 'above_amplitude_floor'],
                  zip(arrays['time'], arrays['amplitude'], arrays['residual'], arrays['good'].astype(int)))
        write_csv(output / f'channel-{channel}-cw-spectrum.csv',
                  ['frequency_hz', 'psd_fs_squared_per_hz'], zip(arrays['frequency'], arrays['psd']))
    evidence['limits'] = 'A weak/noise-only carrier cannot qualify phase or dropouts. A single50k carrier cannot reveal slips of an exact number of carrier cycles. Full captured duration and API/kernel XRUN evidence must be considered independently.'
    return evidence


def sweep_anchor(values, stimulus_path, output, nominal_start):
    """One fixed first-sweep low-frequency template, shared by every result."""
    rate, stimulus = wavfile.read(stimulus_path, mmap=True)
    if rate != RATE or stimulus.dtype != np.int32 or stimulus.ndim != 2 or stimulus.shape[1] != 2:
        raise ValueError('sweep timing requires the actual192k/stereo/S32 stimulus WAV')
    if len(stimulus) != RATE * 30 or not np.array_equal(stimulus[:, 0], stimulus[:, 1]):
        raise ValueError('sweep timing requires the actual30s identical-channel stimulus')
    begin, end, search_halfwidth = .35, 1.75, .30
    first = round((nominal_start - search_halfwidth + begin) * RATE)
    last = round((nominal_start + search_halfwidth + end) * RATE)
    if first < 0 or last > len(values):
        raise ValueError('capture does not cover the complete declared timing search')
    sos = signal.butter(4, [3000, 18000], 'bandpass', fs=RATE, output='sos')
    template = stimulus[round(begin * RATE):round(end * RATE), 0].astype(float) / 2147483648
    template = signal.sosfiltfilt(sos, template)
    template_power = float(np.dot(template, template))
    correlations = []
    for channel in range(3):
        recording = signal.sosfiltfilt(sos, values[first:last, channel])
        norm = np.sqrt(template_power * float(np.dot(recording, recording)))
        correlations.append(signal.correlate(recording, template, mode='valid', method='fft') / max(norm, 1e-30))
    correlations = np.asarray(correlations)
    score = np.sqrt(np.mean(correlations * correlations, axis=0))
    candidates = (first + np.arange(score.size)) / RATE - begin
    peak = int(np.argmax(score))
    anchor = float(candidates[peak])
    competitor_mask = np.abs(candidates - anchor) >= .010
    competitor = float(np.max(score[competitor_mask]))
    ratio = float(score[peak] / max(competitor, 1e-30))
    interior = bool(candidates[0] + .010 < anchor < candidates[-1] - .010)
    # Do not force an answer at a search boundary or with several equally
    # plausible delays. These declared criteria are timing diagnostics only.
    valid = bool(interior and score[peak] >= .02 and ratio >= 1.5)
    np.savez_compressed(output / 'sweep-timing-correlation.npz',
                        candidate_onset_seconds=candidates,
                        normalized_channel_correlations=correlations,
                        combined_rms_correlation=score)
    result = {
        'valid': valid, 'stimulus_wav': str(stimulus_path.resolve()),
        'nominal_onset_seconds': nominal_start,
        'candidate_onset_seconds': anchor, 'accepted_onset_seconds': anchor if valid else None,
        'template_stimulus_interval_seconds': [begin, end],
        'template_instantaneous_frequency_hz': [begin * 9600, end * 9600],
        'analysis_bandpass_hz': [3000, 18000],
        'search_onset_interval_seconds': [float(candidates[0]), float(candidates[-1])],
        'capture_search_interval_seconds': [first / RATE, last / RATE],
        'combined_peak_normalized_correlation': float(score[peak]),
        'per_channel_normalized_correlation_at_single_peak': correlations[:, peak].tolist(),
        'largest_competing_peak_outside_10ms': competitor,
        'peak_to_competitor_amplitude_ratio': ratio,
        'peak_interior_with_10ms_margin': interior,
        'acceptance': 'Interior by10ms; combined normalized peak>=0.02; amplitude ratio>=1.5 against all candidates more than10ms away.',
        'method': 'Fixed actual first-sweep0.35–1.75s template; fixed3–18kHz analysis-only bandpass; equal-weight RMS of normalized correlations from all three channels. One sample-domain delay is shared by all channels, all three repetitions and every frequency. No high-frequency response is used to choose delay; original PCM and STFT coordinates are unchanged.',
        'limits': 'This estimates a common acoustic/recording delay, including propagation and frequency-dependent path effects. It does not measure ADC clock independently. Repetition drift remains visible because timing is never refitted later.'}
    (output / 'sweep-timing.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def sweep_analysis(values, output, channel, start, quiet_start, quiet_stop):
    window = 4096
    hop = 1920
    frequencies, times, psd = signal.spectrogram(
        values, RATE, window='hann', nperseg=window, noverlap=window - hop,
        detrend='constant', scaling='density', mode='psd')
    quiet = (times >= quiet_start + window / RATE / 2) & (times <= quiet_stop - window / RATE / 2)
    if not np.any(quiet):
        raise ValueError('quiet baseline has no complete STFT windows')
    # Median quiet PSD is only a comparison reference; it is not subtracted
    # from the original signal or from the stored full STFT.
    baseline = np.median(psd[:, quiet], axis=1)
    np.savez_compressed(output / f'channel-{channel}-sweep-stft.npz',
                        frequency_hz=frequencies, capture_seconds=times,
                        psd_fs_squared_per_hz=psd, quiet_median_psd=baseline)
    if start is None:
        return {'timing_valid': False, 'repetitions': [],
                'limits': 'Full unaligned STFT is retained. No ridge or bandwidth inference is made because the fixed low-frequency timing template had no accepted unambiguous interior delay.'}
    df = float(frequencies[1] - frequencies[0])
    rows = []
    summaries = []
    for repetition in range(3):
        begin = start + repetition * 10
        stop = begin + 10
        # Use every complete window inside the planned repetition; do not
        # select favorable response spans or move boundaries to match peaks.
        indices = np.flatnonzero((times >= begin + window / RATE / 2)
                                 & (times <= stop - window / RATE / 2))
        bins = {lower: [] for lower in range(0, 96000, 4000)}
        for index in indices:
            t = float(times[index])
            expected = 9600 * (t - begin)
            allowed = abs(frequencies - expected) <= 500
            where = np.flatnonzero(allowed)
            strongest = int(where[np.argmax(psd[allowed, index])])
            peak = float(frequencies[strongest])
            band_power = float(np.sum(psd[allowed, index]) * df)
            quiet_power = float(np.sum(baseline[allowed]) * df)
            contrast = db(band_power / max(quiet_power, 1e-30))
            # The +/-500Hz corridor allows STFT sweep smear and small launch
            # offsets. It is a declared search corridor, not a bandwidth gate.
            global_index = int(np.argmax(np.where(frequencies >= 100, psd[:, index], -1)))
            folded = {}
            for alias_rate in (48000, 96000):
                alias = abs((expected + alias_rate / 2) % alias_rate - alias_rate / 2)
                alias_mask = abs(frequencies - alias) <= 500
                overlap = bool(np.any(alias_mask & allowed))
                alias_power = float(np.sum(psd[alias_mask, index]) * df)
                folded[alias_rate] = (alias, db(alias_power), overlap)
            rows.append([channel, repetition + 1, t, t - begin, expected, peak,
                         peak - expected, db(band_power), db(quiet_power), contrast,
                         float(frequencies[global_index]),
                         *folded[48000], *folded[96000]])
            lower = min(92000, int(expected // 4000) * 4000)
            bins[lower].append(contrast)
        summaries.append({'repetition': repetition + 1,
                          'planned_capture_interval_seconds': [begin, stop],
                          'complete_stft_windows': len(indices),
                          'frequency_bin_summaries': [
                              {'expected_hz': [lower, lower + 4000], 'windows': len(scores),
                               'median_intended_corridor_over_quiet_db': float(np.median(scores)) if scores else None,
                               'fraction_windows_corridor_over_quiet_at_least_10db': float(np.mean(np.array(scores) >= 10)) if scores else None}
                              for lower, scores in bins.items()]})
    write_csv(output / f'channel-{channel}-sweep-ridge.csv',
              ['channel', 'repetition', 'capture_seconds', 'repetition_seconds',
               'expected_hz', 'corridor_peak_hz', 'peak_minus_expected_hz',
               'corridor_power_dbfs', 'same_corridor_quiet_dbfs', 'corridor_over_quiet_db',
               'global_peak_above_100hz', '48k_folded_hz', '48k_folded_power_dbfs', '48k_corridor_overlap',
               '96k_folded_hz', '96k_folded_power_dbfs', '96k_corridor_overlap'], rows)
    return {'window': 'Hann', 'window_frames': window, 'hop_frames': hop,
            'timing_valid': True, 'shared_calibrated_stimulus_start_seconds': start,
            'window_seconds': window / RATE, 'hop_seconds': hop / RATE,
            'frequency_bin_hz': df, 'predicted_frequency_corridor_halfwidth_hz': 500,
            'quiet_capture_interval_seconds': [quiet_start, quiet_stop],
            'repetitions': summaries,
            'limits': 'No automatic bandwidth pass. Weak output, fixed noise, harmonics, aliasing and timing offsets can produce a corridor peak. Inspect intended ridge and folded alternatives across all repetitions. Columns with overlapping intended/folded corridors are not independent. Endpoints are faded/window-limited; a96k mathematical endpoint cannot prove96k acoustic response.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('wav', type=Path)
    parser.add_argument('--stimulus', choices=['cw50k', 'sweep3'], required=True)
    parser.add_argument('--stimulus-start', type=float, required=True,
                        help='nominal playback onset in capture seconds, from the real experiment')
    parser.add_argument('--stimulus-wav', type=Path,
                        help='actual transmitted stereo/S32 WAV, required for one fixed sweep timing calibration')
    parser.add_argument('--quiet-start', type=float, default=.5)
    parser.add_argument('--quiet-stop', type=float, default=1.5)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    if args.output_dir.exists():
        parser.error('choose a new output directory; prior measurements are preserved')
    if not (0 <= args.quiet_start < args.quiet_stop < args.stimulus_start):
        parser.error('require a quiet interval before the explicit stimulus start')
    if args.stimulus == 'cw50k' and args.quiet_stop - args.quiet_start < .5:
        parser.error('CW full-interval detector requires at least0.5s of declared quiet baseline')
    if args.stimulus == 'sweep3' and args.stimulus_wav is None:
        parser.error('sweep3 requires --stimulus-wav for fixed low-frequency sample-domain timing; nominal timing alone can misplace the ridge')
    rate, pcm = wavfile.read(args.wav, mmap=True)
    if rate != RATE or pcm.dtype != np.int16 or pcm.ndim != 2 or pcm.shape[1] != 3:
        parser.error('requires a real interleaved three-channel S16/192000 WAV; no format conversion is performed')
    duration = len(pcm) / RATE
    if duration < args.stimulus_start + 30:
        parser.error('capture does not cover the complete planned30s stimulus; retain it as incomplete evidence')
    args.output_dir.mkdir(parents=True)
    report = {'original_capture': str(args.wav.resolve()), 'sample_rate': rate,
              'format': 'PCM_S16_LE', 'channels': 3, 'frames_per_channel': len(pcm),
              'duration_seconds': duration, 'stimulus': args.stimulus,
              'nominal_stimulus_start_seconds': args.stimulus_start,
              'declared_quiet_interval_seconds': [args.quiet_start, args.quiet_stop],
              'planned_stimulus_duration_seconds': 30,
              'physical_channel_mapping': 'not inferred: channel indices0,1,2 follow the recorded interleaving',
              'channel_results': [], 'interchannel': [], 'hardware_qualification': 'NOT_AUTOMATICALLY_QUALIFIED',
              'limits': 'Metadata/counts are not clock or physical-bandwidth proof. Original PCM is never modified, resampled, or split into substitute WAVs. Correlation and exact repeated samples do not alone establish duplicate endpoints or stale DMA. Correlate with real kernel/API logs and controlled acoustic endpoints.'}
    values = pcm.astype(np.float64) / 32768
    calibrated_start = args.stimulus_start
    if args.stimulus == 'sweep3':
        timing = sweep_anchor(values, args.stimulus_wav, args.output_dir, args.stimulus_start)
        report['sweep_timing'] = timing
        calibrated_start = timing['accepted_onset_seconds']
    means = values.mean(axis=0)
    centered = values - means
    for left in range(3):
        for right in range(left + 1, 3):
            denominator = np.sqrt(np.dot(centered[:, left], centered[:, left]) * np.dot(centered[:, right], centered[:, right]))
            correlation = float(np.dot(centered[:, left], centered[:, right]) / denominator) if denominator > 0 else None
            report['interchannel'].append({'channels': [left, right], 'zero_lag_pearson': correlation,
                                            'exact_sample_equality_fraction': float(np.mean(pcm[:, left] == pcm[:, right]))})
    del centered
    for channel in range(3):
        x = values[:, channel]
        raw = pcm[:, channel].astype(np.int32)
        details = {'channel_index': channel, 'dc_mean_fs': float(means[channel]),
                   'rms_dbfs': db(np.mean(x * x)), 'peak_abs_code': int(abs(raw).max()),
                   'exact_pcm_rail_samples': int(np.sum((raw == -32768) | (raw == 32767))),
                   'samples_above_0_999fs': int(np.sum(abs(x) > .999)),
                   'zero_sample_fraction': float(np.mean(raw == 0)),
                   'block_freshness_diagnostics': freshness(pcm[:, channel])}
        startup = x[:round(args.quiet_start * RATE)]
        large = np.flatnonzero(np.abs(startup) > .1)
        details['pre_quiet_startup_interval'] = {
            'capture_interval_seconds': [0, args.quiet_start], 'frames': len(startup),
            'rms_dbfs': db(np.mean(startup * startup)) if len(startup) else None,
            'peak_abs_fs': float(np.max(np.abs(startup))) if len(startup) else None,
            'samples_above_0_999fs': int(np.sum(np.abs(startup) > .999)),
            'samples_above_0_1fs': len(large),
            'first_last_above_0_1fs_seconds': [float(large[0] / RATE), float(large[-1] / RATE)] if len(large) else None,
            'interpretation': 'Original startup samples remain part of full-file metrics and are not excused by the later tone analysis.'}
        details['declared_quiet_freshness_diagnostics'] = freshness(
            pcm[round(args.quiet_start * RATE):round(args.quiet_stop * RATE), channel])
        if args.stimulus == 'cw50k':
            details['cw_full_interval'] = cw_analysis(x, args.output_dir, channel, 30,
                                                     args.stimulus_start, args.quiet_start, args.quiet_stop)
        else:
            details['sweep'] = sweep_analysis(x, args.output_dir, channel, calibrated_start,
                                               args.quiet_start, args.quiet_stop)
        report['channel_results'].append(details)
    report = safe(report)
    (args.output_dir / 'measurement.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    print(json.dumps(report, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
