#!/usr/bin/env python3
"""Plot untouched real192k D10 recordings; no denoising or sample-rate conversion.

Full-recording-time spectrograms are zoomed to each requested frequency±500Hz.
Fixed active2.5–6.5s and quiet0.1–1.1s spectra use1s Hann Welch segments.
Plots demonstrate recorded stimulus-correlated components, not by themselves
airborne acoustic transmission or a flat response through96kHz.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import shutil

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy import signal
from scipy.io import wavfile


def db(power):
    return 10 * np.log10(np.maximum(power, 1e-30))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old66", type=Path, required=True)
    parser.add_argument("--new66", type=Path, required=True)
    parser.add_argument("--new54", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    datasets = [("earlier-66547", "Earlier raw bottom speaker", args.old66, 66547, 5),
                ("primary-66547-gain17", "Ordinary AAudio / gain code17", args.new66, 66547, 8),
                ("primary-54283-gain17", "Ordinary AAudio / gain code17", args.new54, 54283, 8)]
    plt.rcParams.update({"font.size": 10, "axes.titlesize": 11, "axes.labelsize": 10,
                         "savefig.facecolor": "white", "figure.facecolor": "white"})
    figure, axes = plt.subplots(3, 2, figsize=(14, 11), layout="constrained")
    reports = []
    for row, (label, description, path, tone, nominal_play_seconds) in enumerate(datasets):
        rate, pcm = wavfile.read(path, mmap=True)
        if rate != 192000 or pcm.dtype != np.int16 or pcm.ndim != 1:
            parser.error(f"{path}: expected original mono S16/192000Hz D10 WAV")
        samples = pcm.astype(np.float64) / 32768
        if len(samples) < 7 * rate:
            parser.error(f"{path}: too short for fixed active/quiet windows")
        active_bounds = [round(2.5 * rate), round(6.5 * rate)]
        quiet_bounds = [round(.1 * rate), round(1.1 * rate)]
        active = samples[slice(*active_bounds)]
        quiet = samples[slice(*quiet_bounds)]
        frequency, active_psd = signal.welch(active, rate, window="hann", nperseg=rate,
                                            noverlap=rate // 2, detrend=False, scaling="density")
        _, quiet_psd = signal.welch(quiet, rate, window="hann", nperseg=rate,
                                   noverlap=rate // 2, detrend=False, scaling="density")
        df = frequency[1] - frequency[0]
        line = abs(frequency - tone) <= 4
        active_line = float(np.sum(active_psd[line]) * df)
        quiet_line = float(np.sum(quiet_psd[line]) * df)
        spec_n = 65536
        sf, st, spectrum = signal.spectrogram(samples, rate, window="hann", nperseg=spec_n,
                                              noverlap=spec_n * 3 // 4, detrend=False,
                                              scaling="density", mode="psd")
        near = abs(sf - tone) <= 500
        spectrogram_axis, psd_axis = axes[row]
        mesh = spectrogram_axis.pcolormesh(st, sf[near] / 1000, db(spectrum[near]),
                                           shading="auto", cmap="magma", vmin=-155, vmax=-75,
                                           rasterized=True)
        spectrogram_axis.axvspan(0, 2, color="white", alpha=.08)
        for moment in (2, 2 + nominal_play_seconds):
            spectrogram_axis.axvline(moment, color="white", linestyle=":", linewidth=.8)
        spectrogram_axis.axvspan(2.5, 6.5, color="#48c6ef", alpha=.1)
        spectrogram_axis.set(xlim=(0, len(samples) / rate), ylim=((tone - 500) / 1000, (tone + 500) / 1000),
                             xlabel="Original recording time (s)", ylabel="Frequency (kHz)",
                             title=f"{description} — {tone:,} Hz\nFull recording time; frequency zoom ±500 Hz")
        figure.colorbar(mesh, ax=spectrogram_axis, label="PSD (dBFS/Hz)", fraction=.025, pad=.02)
        zoom = abs(frequency - tone) <= 500
        psd_axis.plot(frequency[zoom] / 1000, db(quiet_psd[zoom]), color="#7a8795", lw=.8,
                      label="Quiet:0.1–1.1s")
        psd_axis.plot(frequency[zoom] / 1000, db(active_psd[zoom]), color="#006faf", lw=1.0,
                      label="Active:2.5–6.5s")
        psd_axis.axvline(tone / 1000, color="#c34634", ls=":", lw=1.0)
        psd_axis.set(xlim=((tone - 500) / 1000, (tone + 500) / 1000), ylim=(-160, -65),
                     xlabel="Frequency (kHz)", ylabel="PSD (dBFS/Hz)",
                     title=f"Fixed windows: integrated ±4 Hz line {db(active_line):.1f} dBFS\n"
                           f"Active/quiet ratio {db(active_line / max(quiet_line, 1e-30)):.1f} dB")
        psd_axis.grid(alpha=.2)
        psd_axis.legend(loc="upper left", fontsize=8)
        with (args.output_dir / f"{label}-psd.csv").open("w", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(["frequency_hz", "active_psd_dbfs_per_hz", "quiet_psd_dbfs_per_hz"])
            writer.writerows(zip(frequency[zoom], db(active_psd[zoom]), db(quiet_psd[zoom])))
        reports.append({"label": label, "source_wav": str(path.resolve()), "rate_hz": rate,
                        "frames": len(pcm), "duration_seconds": len(pcm) / rate,
                        "requested_tone_hz": tone, "active_sample_bounds": active_bounds,
                        "quiet_sample_bounds": quiet_bounds, "active_line_dbfs": float(db(active_line)),
                        "quiet_line_dbfs": float(db(quiet_line)),
                        "active_over_quiet_db": float(db(active_line / max(quiet_line, 1e-30))),
                        "original_wav_modified": False})
    figure.suptitle("Recorded ultrasonic components — fixed-window evidence, not proof of an airborne path\n"
                    "Original mono S16 microphone capture:192,000 samples/s; no resampling or denoising",
                    fontsize=14)
    figure.supxlabel("Spectrogram:65,536-sample Hann,341.33ms window,2.9297Hz bins,85.33ms hop. "
                     "Welch PSD:192,000-sample Hann,1Hz bins,50% overlap.\n"
                     "White dotted times:nominal2s lead / requested end; actual onset may be delayed. "
                     "Digital dBFS is not calibrated sound pressure or a flat response to96kHz.", fontsize=9)
    figure.savefig(args.output_dir / "hf-evidence.png", dpi=180)
    figure.savefig(args.output_dir / "hf-evidence.pdf")
    plt.close(figure)
    report = {"datasets": reports, "spectrogram_fft_frames": 65536,
              "spectrogram_bin_hz": 192000 / 65536, "psd_fft_frames": 192000,
              "psd_bin_hz": 1, "integrated_line_half_width_hz": 4,
              "normalization": "S16 PCM divided by32768; power reference1; PSD is power perHz.",
              "limits": ["Signals are measured in the phone's own microphone ADC, so electrical coupling remains a possible confound.",
                         "Old raw-bottom and new ordinary-primary runs differ in route/amplifiers and timing, not only gain code; this is not a controlled gain-only comparison.",
                         "A correlated narrow line does not establish continuous acoustic bandwidth, flatness to96kHz, human audibility or calibrated SPL.",
                         "Resolve the airborne/electrical distinction with physical-path occlusion or an electrically independent ultrasonic microphone."]}
    (args.output_dir / "hf-evidence.json").write_text(json.dumps(report, indent=2) + "\n")
    shutil.copy2(__file__, args.output_dir / Path(__file__).name)
    (args.output_dir / "README.md").write_text(
        "# Real-recording high-frequency evidence\n\n"
        "`hf-evidence.png` and `.pdf` visualize unchanged source recordings listed in`hf-evidence.json`. "
        "The spectrograms show the entire recording time but zoom frequency to the requested tone±500Hz. "
        "The raw-WAV sample bounds, normalization and FFT/window choices are recorded in JSON and on the figure.\n\n"
        "Dependencies:Python3,NumPy,SciPy,Matplotlib. This workspace uses`work/toolchains/hf-plot-venv` "
        "with system NumPy/SciPy and Matplotlib3.11.2. It was created with`python3 -m venv --system-site-packages work/toolchains/hf-plot-venv` "
        "then`work/toolchains/hf-plot-venv/bin/python -m pip install --cache-dir work/toolchains/pip-cache matplotlib`.\n\n"
        "Reproduce using the copied source:`python plot_frankel_hf_evidence.py --old66 OLD.wav --new66 NEW.wav --new54 CURRENT54.wav --output-dir NEWDIR`. "
        "Choose a new output directory; source WAVs are never modified.\n\n"
        "These plots show recorded stimulus-correlated components, not conclusive airborne acoustic transmission. "
        "They do not claim a flat response through96kHz. See the explicit limitations in JSON.\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
