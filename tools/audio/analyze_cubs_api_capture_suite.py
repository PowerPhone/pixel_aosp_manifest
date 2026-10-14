#!/usr/bin/env python3
"""Evidence-only audit of completed, real six-capture Cubs API matrices.

Original samples and suite results are not changed. No resampling or hashing.
"""
import argparse
import csv
import json
from pathlib import Path
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy import signal
from scipy.io import wavfile


def db(power):
    return 10 * np.log10(np.maximum(power, 1e-30))


def runs(mask):
    edges = np.diff(np.r_[False, mask, False].astype(np.int8))
    first, last = np.flatnonzero(edges == 1), np.flatnonzero(edges == -1)
    return first, last


def freshness(samples, start, stop, rate):
    pcm = samples[start:stop]
    zero_first, zero_last = runs(pcm == 0)
    lengths = zero_last - zero_first
    blocks = pcm[:len(pcm)//96*96].reshape(-1, 96)
    adjacent = np.all(blocks[1:] == blocks[:-1], axis=1)
    _, counts = np.unique(blocks, axis=0, return_counts=True)
    # Also find complete repeated 96-sample intervals independent of alignment
    # to the first sample in the selected API file window.
    lag_first, lag_last = runs(pcm[96:] == pcm[:-96])
    lag_length = lag_last - lag_first
    long_zeros = [{"first_sample": int(start+x), "last_exclusive_sample": int(start+y),
                   "start_seconds": (start+int(x))/rate, "duration_seconds": int(y-x)/rate}
                  for x, y in zip(zero_first, zero_last) if y-x >= 96]
    repeat_runs = [{"second_interval_first_sample": int(start+96+x),
                    "identical_sample_count": int(y-x)}
                   for x, y in zip(lag_first, lag_last) if y-x >= 96]
    return {"sample_bounds": [start, stop], "zero_samples": int(np.count_nonzero(pcm == 0)),
            "longest_consecutive_zero_samples": int(lengths.max(initial=0)),
            "all_zero_96_sample_blocks": int(np.count_nonzero(np.all(blocks == 0, axis=1))),
            "adjacent_identical_96_sample_block_pairs": int(np.count_nonzero(adjacent)),
            "identical_96_block_occurrences_beyond_first_anywhere": int(np.sum(counts-1)),
            "blocks_compared": len(blocks), "long_zero_runs_at_least_96_samples": long_zeros,
            "arbitrary_alignment_lag96_repeat_runs_at_least_96_samples": repeat_runs,
            "longest_lag96_equal_sample_run": int(lag_length.max(initial=0))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    a = parser.parse_args()
    for required in ("capture-files.txt", "summary.txt", "aoc-counters-after.tsv", "run-status.tsv"):
        if not (a.suite / required).is_file():
            parser.error("suite has not completed its artifact collection: " + required)
    if a.output_dir.exists():
        parser.error("use a NEW output directory")
    filenames = (a.suite / "capture-files.txt").read_text().splitlines()
    expected = {f"{api}_record-POWERPHONE_CUBS_C0_D10_MIC{mic}.wav"
                for api in ("java", "aaudio") for mic in range(3)}
    if set(filenames) != expected or len(filenames) != 6:
        parser.error("requires the six completed original Cubs endpoint/API WAVs")
    a.output_dir.mkdir(parents=True)
    records = []
    fig, axes = plt.subplots(6, 1, figsize=(12, 13), constrained_layout=True, sharex=True)
    specfig, specaxes = plt.subplots(2, 1, figsize=(12, 9), constrained_layout=True)
    for index, filename in enumerate(sorted(filenames)):
        path = a.suite / "captures" / filename
        rate, pcm = wavfile.read(path)
        if rate != 192000 or pcm.dtype != np.int16 or pcm.ndim != 1:
            parser.error(f"unexpected source format: {path}")
        stem = path.stem
        log = (a.suite / "runs" / stem / "logcat.txt").read_text(errors="replace")
        q = pcm[round(.2*rate):round(.8*rate)].astype(np.float64)/32768
        freq, psd = signal.welch(q, rate, window="hann", nperseg=16384, noverlap=8192,
                                 detrend="constant", scaling="density")
        bands = []
        for low, high in ((48000, 60000), (60000, 72000), (72000, 84000), (84000, 95000)):
            choose = (freq >= low) & (freq < high)
            bands.append({"band_hz": [low, high], "median_density_dbfs_per_hz": float(db(np.median(psd[choose])))})
        timestamp = [line.split("PowerPhoneLab:", 1)[-1].strip() for line in log.splitlines()
                     if re.search(r"(?:input |output )?timestamp (?:method|polls|span|full-run|first|second|delta)|xrun delta/total", line)]
        (a.output_dir / f"{stem}-timestamps.txt").write_text("\n".join(timestamp)+"\n")
        rate_match = re.search(r"input timestamp full-run regression rate: ([0-9.]+) Hz", log)
        hal_errors = [line for line in log.splitlines() if re.search(r"\sE\s+AHAL_Powerphone\s*:", line)]
        silence = [line for line in log.splitlines() if re.search(r"App op\s*27.*silenc|client silenced:\s*true|silenced=true", line, re.I)]
        record = dict(source=str(path.resolve()), label=stem, sample_rate_header_hz=int(rate),
                      frames=len(pcm), declared_seconds=len(pcm)/rate, original_unmodified=True,
                      zero_samples_note="Isolated exact-zero PCM values occur naturally in quantized quiet noise; they are not dropouts by themselves.",
                      full_file=freshness(pcm, 0, len(pcm), rate),
                      fixed_interior_01sec_boundary_exclusion=freshness(pcm, round(.1*rate), len(pcm)-round(.1*rate), rate),
                      clipped_samples=int(np.count_nonzero((pcm == -32768)|(pcm == 32767))),
                      quiet_sample_bounds=[round(.2*rate), round(.8*rate)],
                      quiet_dc_fs=float(q.mean()), quiet_ac_rms_dbfs=float(db(np.mean((q-q.mean())**2))),
                      quiet_bands=bands,
                      high_minus_low_median_db=bands[-1]["median_density_dbfs_per_hz"]-bands[0]["median_density_dbfs_per_hz"],
                      input_timestamp_regression_hz=float(rate_match[1]) if rate_match else None,
                      timestamp_summary=timestamp, hal_errors=hal_errors, framework_silencing=silence)
        records.append(record)
        np.savetxt(a.output_dir / f"{stem}-quiet-psd.csv", np.column_stack([freq, psd]), delimiter=",",
                   header="api_coordinate_hz,linear_density_fs_squared_per_hz", comments="")
        block = 3840
        full = pcm[:len(pcm)//block*block].reshape(-1, block).astype(np.float64)/32768
        centers = (np.arange(len(full))+.5)*block/rate
        rms = db(np.mean(full**2, axis=1))
        zero_fraction = np.mean(full == 0, axis=1)
        np.savetxt(a.output_dir / f"{stem}-whole-file-20ms.csv",
                   np.column_stack([centers, rms, zero_fraction]), delimiter=",",
                   header="api_coordinate_seconds,rms_dbfs,exact_zero_sample_fraction", comments="")
        axes[index].plot(centers, rms, lw=.8)
        for region in record["full_file"]["long_zero_runs_at_least_96_samples"]:
            axes[index].axvspan(region["start_seconds"], region["start_seconds"]+region["duration_seconds"], color="red", alpha=.3)
        axes[index].set(ylabel="RMS dBFS", title=stem, ylim=(-125, 0))
        axes[index].axvline(.1, ls=":", color="gray")
        axes[index].axvline(len(pcm)/rate-.1, ls=":", color="gray")
        specaxes[0].plot(freq/1000, db(psd), lw=.6, alpha=.8, label=stem)
        specaxes[1].plot([54, 66, 78, 89.5], [b["median_density_dbfs_per_hz"] for b in bands], ".-", label=stem)
    axes[-1].set_xlabel("Original API sample coordinate, seconds; all 20-ms blocks retained")
    fig.savefig(a.output_dir / "full-record-levels.png", dpi=160)
    plt.close(fig)
    for axis in specaxes:
        axis.set(xlabel="API frequency coordinate, kHz", ylabel="dBFS/Hz", xlim=(0, 96))
        axis.axvline(24, color="gray", ls=":")
        axis.axvline(48, color="gray", ls=":")
        axis.legend(fontsize=7)
    specaxes[0].set_title("All six fixed quiet 0.2–0.8-s intervals: Hann 16384/8192, df=11.71875 Hz")
    specaxes[1].set_title("Fixed upper-band median PSD; not independent acoustic-passband proof")
    specfig.savefig(a.output_dir / "quiet-noise-ramp.png", dpi=160)
    plt.close(specfig)
    limits = ["Original suite PASS/FAIL statuses and WAVs are unchanged.",
              "Full-file zeros/duplicates are reported alongside a fixed 0.1-s edge exclusion; startup samples are not hidden.",
              "Exact-zero sample values in quiet quantized noise do not alone imply framework silencing; inspect sustained runs and logs.",
              "A repeated 96-sample block detector is not a complete sample-loss or jitter detector; silence has no phase reference.",
              "The noise ramp is consistent with noise shaping but does not establish acoustic sensitivity near 96 kHz or speaker passband above 48 kHz.",
              "Timestamps follow the Android/HAL position model; their rate regression is not an independent microphone clock measurement."]
    (a.output_dir / "evidence.json").write_text(json.dumps(dict(records=records, limits=limits), indent=2)+"\n")
    with (a.suite / "run-status.tsv").open() as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    passed = sum(row["result"] == "PASS" for row in rows)
    lines = ["# Completed awake API matrix: recording evidence\n",
             f"Original matrix records {passed}/10 planned transport PASS ({len(rows)} result rows). Missing rows are failures/not-qualified, not extra passes. This report does not change its gates or results.\n",
             "All six original WAVs are mono S16 with 192000-Hz headers. These metadata alone are not a bandwidth measurement.\n",
             "| API/mic | Frames / seconds | Full longest zero run, samples | Full zero96 / adjacent duplicate96 | Interior zero96 / adjacent duplicate96 | Clips | Noise ramp, dB | Input timestamp Hz |",
             "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for r in records:
        full, interior = r["full_file"], r["fixed_interior_01sec_boundary_exclusion"]
        lines.append(f"| {r['label'].replace('_record-POWERPHONE_CUBS_C0_D10_', '/')} | {r['frames']} / {r['declared_seconds']:.3f} | {full['longest_consecutive_zero_samples']} | {full['all_zero_96_sample_blocks']} / {full['adjacent_identical_96_sample_block_pairs']} | {interior['all_zero_96_sample_blocks']} / {interior['adjacent_identical_96_sample_block_pairs']} | {r['clipped_samples']} | {r['high_minus_low_median_db']:.3f} | {r['input_timestamp_regression_hz'] if r['input_timestamp_regression_hz'] else 'not reported by Java'} |")
    lines += ["", "Noise ramp is the fixed 84–95-kHz median PSD minus 48–60-kHz median PSD, from sample coordinates 0.2–0.8 seconds. All data remain unnormalized and unresampled.", "",
              "## Limits", ""] + ["- "+limit for limit in limits]
    lines += ["", "## Artifacts", "", "Original captures remain in `../captures/`; detailed full-file/interior zero and duplicate runs, log errors, fixed quiet PSDs and timestamp summaries are in `evidence.json` and the adjacent CSV/text files. `full-record-levels.png` preserves all 20-ms level blocks; red overlays indicate zero runs of at least 96 samples. `quiet-noise-ramp.png` compares every fixed quiet interval.", ""]
    (a.output_dir / "QUALIFICATION.md").write_text("\n".join(lines))
    for r in records:
        print(r["label"], "zero96", r["full_file"]["all_zero_96_sample_blocks"],
              "dup96", r["full_file"]["adjacent_identical_96_sample_block_pairs"],
              "ramp", round(r["high_minus_low_median_db"], 3),
              "timestamp", r["input_timestamp_regression_hz"],
              "HAL/errors/silenced", len(r["hal_errors"]), len(r["framework_silencing"]))


if __name__ == "__main__":
    main()
