#!/usr/bin/env python3
"""Generate and inspect deterministic PCM WAV files for Frankel audio tests."""

from __future__ import annotations

import argparse
import cmath
import math
import random
import struct
import sys
import wave
from pathlib import Path
from typing import Iterator


SUPPORTED_RATES = (48_000, 96_000, 192_000)
SUPPORTED_BITS = (16, 24, 32)


class SignalError(Exception):
    """A concise command-line validation failure."""


def bounded_float(label: str, value: str, minimum: float, maximum: float) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{label} must be a number") from error
    if not minimum <= parsed <= maximum:
        raise argparse.ArgumentTypeError(
            f"{label} must be between {minimum:g} and {maximum:g}"
        )
    return parsed


def duration_value(value: str) -> float:
    return bounded_float("duration", value, 0.001, 300.0)


def amplitude_value(value: str) -> float:
    return bounded_float("amplitude", value, 0.000_001, 0.5)


def frequency_value(value: str) -> float:
    return bounded_float("frequency", value, 0.0, 200_000.0)


def encode_sample(value: float, bits: int) -> bytes:
    value = max(-1.0, min(1.0, value))
    maximum = (1 << (bits - 1)) - 1
    sample = int(round(value * maximum))
    if bits == 16:
        return struct.pack("<h", sample)
    if bits == 32:
        return struct.pack("<i", sample)
    if sample < 0:
        sample += 1 << 24
    return sample.to_bytes(3, "little", signed=False)


def tone_samples(rate: int, frequency: float) -> Iterator[float]:
    phase_step = 2.0 * math.pi * frequency / rate
    frame = 0
    while True:
        yield math.sin(frame * phase_step)
        frame += 1


def white_samples(random_source: random.Random) -> Iterator[float]:
    while True:
        yield random_source.uniform(-1.0, 1.0)


def pink_samples(random_source: random.Random) -> Iterator[float]:
    # A deterministic 16-row Voss-McCartney generator.  This is intended as a
    # broadband stimulus, not as a calibrated metrology source.
    rows = [random_source.uniform(-1.0, 1.0) for _ in range(16)]
    counter = 0
    while True:
        counter = (counter + 1) & 0xFFFF
        changed_row = 0
        changing_bits = counter
        while changed_row < len(rows) - 1 and changing_bits & 1 == 0:
            changed_row += 1
            changing_bits >>= 1
        rows[changed_row] = random_source.uniform(-1.0, 1.0)
        yield (sum(rows) + random_source.uniform(-1.0, 1.0)) / 17.0


def chirp_samples(
    rate: int, duration: float, start_frequency: float, end_frequency: float
) -> Iterator[float]:
    slope = (end_frequency - start_frequency) / duration
    frame = 0
    while True:
        time = frame / rate
        phase = 2.0 * math.pi * (
            start_frequency * time + 0.5 * slope * time * time
        )
        yield math.sin(phase)
        frame += 1


def select_samples(arguments: argparse.Namespace) -> Iterator[float]:
    random_source = random.Random(arguments.seed)
    if arguments.signal == "tone":
        return tone_samples(arguments.rate, arguments.frequency)
    if arguments.signal == "white":
        return white_samples(random_source)
    if arguments.signal == "pink":
        return pink_samples(random_source)
    return chirp_samples(
        arguments.rate,
        arguments.duration,
        arguments.start_frequency,
        arguments.end_frequency,
    )


def validate_frequencies(arguments: argparse.Namespace) -> None:
    nyquist = arguments.rate / 2.0
    if arguments.signal == "tone" and not 0.0 < arguments.frequency < nyquist:
        raise SignalError(
            f"tone frequency must be above 0 and below Nyquist ({nyquist:g} Hz)"
        )
    if arguments.signal == "chirp":
        for label, frequency in (
            ("chirp start", arguments.start_frequency),
            ("chirp end", arguments.end_frequency),
        ):
            if not 0.0 < frequency < nyquist:
                raise SignalError(
                    f"{label} must be above 0 and below Nyquist ({nyquist:g} Hz)"
                )
        if arguments.start_frequency == arguments.end_frequency:
            raise SignalError("chirp start and end frequencies must differ")


def generate(arguments: argparse.Namespace) -> None:
    if arguments.end_frequency is None:
        arguments.end_frequency = arguments.rate * 0.42
    validate_frequencies(arguments)

    destination = arguments.output.resolve()
    if destination.exists() and not arguments.force:
        raise SignalError(f"output exists (use --force): {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)

    sample_source = select_samples(arguments)
    frame_count = int(round(arguments.duration * arguments.rate))
    frames_remaining = frame_count
    sample_width = arguments.bits // 8
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(arguments.channels)
        output.setsampwidth(sample_width)
        output.setframerate(arguments.rate)
        while frames_remaining:
            current_frames = min(frames_remaining, arguments.chunk_frames)
            encoded = bytearray()
            for _ in range(current_frames):
                sample = encode_sample(next(sample_source) * arguments.amplitude, arguments.bits)
                encoded.extend(sample * arguments.channels)
            output.writeframesraw(encoded)
            frames_remaining -= current_frames

    print(
        f"generated path={destination} signal={arguments.signal} "
        f"rate={arguments.rate} channels={arguments.channels} bits={arguments.bits} "
        f"frames={frame_count} duration={frame_count / arguments.rate:.6f}"
    )


def inspect(arguments: argparse.Namespace) -> None:
    source = arguments.input.resolve()
    try:
        with wave.open(str(source), "rb") as input_file:
            channels = input_file.getnchannels()
            rate = input_file.getframerate()
            bits = input_file.getsampwidth() * 8
            frames = input_file.getnframes()
            compression = input_file.getcomptype()
    except (FileNotFoundError, wave.Error) as error:
        raise SignalError(f"cannot read PCM WAV {source}: {error}") from error

    if compression != "NONE":
        raise SignalError(f"compressed WAV is unsupported: {compression}")
    expected = (
        ("rate", arguments.expect_rate, rate),
        ("channels", arguments.expect_channels, channels),
        ("bits", arguments.expect_bits, bits),
    )
    mismatches = [
        f"{label} expected {wanted}, got {actual}"
        for label, wanted, actual in expected
        if wanted is not None and wanted != actual
    ]
    if mismatches:
        raise SignalError("WAV metadata mismatch: " + "; ".join(mismatches))
    print(
        f"wav path={source} rate={rate} channels={channels} bits={bits} "
        f"frames={frames} duration={frames / rate:.6f}"
    )


def decode_channel(
    raw: bytes, sample_width: int, channels: int, channel: int
) -> list[float]:
    frame_width = sample_width * channels
    samples = []
    maximum = float(1 << (sample_width * 8 - 1))
    for frame_offset in range(0, len(raw), frame_width):
        offset = frame_offset + channel * sample_width
        encoded = raw[offset : offset + sample_width]
        if sample_width == 3:
            value = int.from_bytes(encoded, "little", signed=False)
            if value & 0x800000:
                value -= 1 << 24
        else:
            value = int.from_bytes(encoded, "little", signed=True)
        samples.append(value / maximum)
    return samples


def fft_in_place(values: list[complex]) -> None:
    """Iterative radix-2 FFT, kept dependency-free for build hosts."""
    size = len(values)
    destination = 0
    for source in range(1, size):
        bit = size >> 1
        while destination & bit:
            destination ^= bit
            bit >>= 1
        destination ^= bit
        if source < destination:
            values[source], values[destination] = (
                values[destination],
                values[source],
            )

    transform_size = 2
    while transform_size <= size:
        step = cmath.exp(-2j * math.pi / transform_size)
        half = transform_size // 2
        for start in range(0, size, transform_size):
            rotation = 1 + 0j
            for lower in range(start, start + half):
                upper = values[lower + half] * rotation
                base = values[lower]
                values[lower] = base + upper
                values[lower + half] = base - upper
                rotation *= step
        transform_size *= 2


def default_spectrum_bands(nyquist: float) -> list[tuple[float, float]]:
    edges = [0.0, 5_000.0, 15_000.0, 24_000.0, 48_000.0, 72_000.0, 90_000.0]
    edges = [edge for edge in edges if edge < nyquist]
    edges.append(nyquist)
    return list(zip(edges, edges[1:]))


def spectrum(arguments: argparse.Namespace) -> None:
    source = arguments.input.resolve()
    try:
        with wave.open(str(source), "rb") as input_file:
            channels = input_file.getnchannels()
            rate = input_file.getframerate()
            sample_width = input_file.getsampwidth()
            total_frames = input_file.getnframes()
            compression = input_file.getcomptype()
            start_frame = round(arguments.start * rate)
            if start_frame >= total_frames:
                raise SignalError(
                    f"spectrum start is beyond the WAV ({total_frames / rate:.6f} s)"
                )
            available = min(arguments.fft_frames, total_frames - start_frame)
            fft_frames = 1 << (available.bit_length() - 1)
            if fft_frames < 1024:
                raise SignalError("at least 1024 frames are required for a spectrum")
            input_file.setpos(start_frame)
            raw = input_file.readframes(fft_frames)
    except (FileNotFoundError, wave.Error) as error:
        raise SignalError(f"cannot read PCM WAV {source}: {error}") from error

    if compression != "NONE" or sample_width not in (2, 3, 4):
        raise SignalError("spectrum requires uncompressed 16-, 24-, or 32-bit PCM")
    selected_channels = arguments.channel or list(range(channels))
    invalid = [channel for channel in selected_channels if not 0 <= channel < channels]
    if invalid:
        raise SignalError(
            f"channel index out of range 0..{channels - 1}: "
            + ", ".join(map(str, invalid))
        )

    print(
        f"spectrum path={source} rate={rate} channels={channels} "
        f"bits={sample_width * 8} start={start_frame / rate:.6f} "
        f"fft_frames={fft_frames} bin_hz={rate / fft_frames:.6f}"
    )
    nyquist = rate / 2.0
    bands = default_spectrum_bands(nyquist)
    window_sum = 0.0
    window = []
    for frame in range(fft_frames):
        coefficient = 0.5 - 0.5 * math.cos(
            2.0 * math.pi * frame / (fft_frames - 1)
        )
        window.append(coefficient)
        window_sum += coefficient

    for channel in selected_channels:
        samples = decode_channel(raw, sample_width, channels, channel)
        mean = sum(samples) / fft_frames
        rms = math.sqrt(sum(sample * sample for sample in samples) / fft_frames)
        transformed = [
            complex((sample - mean) * window[index])
            for index, sample in enumerate(samples)
        ]
        fft_in_place(transformed)
        powers = [
            4.0 * abs(transformed[index]) ** 2 / window_sum**2
            for index in range(fft_frames // 2 + 1)
        ]
        powers[0] /= 2.0
        powers[-1] /= 2.0
        total_power = sum(powers[1:])
        print(f"channel={channel} mean={mean:.9g} rms={rms:.9g}")
        for low, high in bands:
            first = max(1, math.ceil(low * fft_frames / rate))
            last = min(fft_frames // 2, math.floor(high * fft_frames / rate))
            band_powers = powers[first : last + 1]
            band_power = sum(band_powers)
            average_power = band_power / len(band_powers)
            dbfs_per_bin = 10.0 * math.log10(max(average_power, 1e-300))
            peak_offset = max(
                range(len(band_powers)), key=band_powers.__getitem__
            )
            peak_bin = first + peak_offset
            peak_hz = peak_bin * rate / fft_frames
            peak_dbfs = 10.0 * math.log10(
                max(band_powers[peak_offset], 1e-300)
            )
            percentage = 100.0 * band_power / max(total_power, 1e-300)
            print(
                f"  {low:8.0f}-{high:8.0f} Hz  "
                f"avg={dbfs_per_bin:8.2f} dBFS/bin  energy={percentage:7.3f}%  "
                f"peak={peak_hz:9.2f} Hz/{peak_dbfs:7.2f} dBFS"
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Generate deterministic, low-amplitude high-frequency stimuli and "
            "validate PCM WAV metadata. No device access is performed."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    generate_parser = subparsers.add_parser("generate", help="generate a PCM WAV")
    generate_parser.add_argument("output", type=Path)
    generate_parser.add_argument("--signal", choices=("tone", "white", "pink", "chirp"), default="tone")
    generate_parser.add_argument("--rate", type=int, choices=SUPPORTED_RATES, default=192_000)
    generate_parser.add_argument("--channels", type=int, choices=range(1, 5), default=4)
    generate_parser.add_argument("--bits", type=int, choices=SUPPORTED_BITS, default=32)
    generate_parser.add_argument("--duration", type=duration_value, default=5.0)
    generate_parser.add_argument(
        "--amplitude",
        type=amplitude_value,
        default=0.03,
        help="linear full-scale amplitude, at most 0.5 (default: 0.03)",
    )
    generate_parser.add_argument(
        "--frequency",
        type=frequency_value,
        default=18_000.0,
        help="tone frequency in Hz (default: 18000; deliberately not 1 kHz)",
    )
    generate_parser.add_argument("--start-frequency", type=frequency_value, default=15_000.0)
    generate_parser.add_argument(
        "--end-frequency",
        type=frequency_value,
        help="chirp end in Hz (default: 42%% of sample rate)",
    )
    generate_parser.add_argument("--seed", type=int, default=460)
    generate_parser.add_argument("--chunk-frames", type=int, default=4096, help=argparse.SUPPRESS)
    generate_parser.add_argument("--force", action="store_true", help="replace an existing output")
    generate_parser.set_defaults(handler=generate)

    inspect_parser = subparsers.add_parser("inspect", help="inspect and optionally validate a PCM WAV")
    inspect_parser.add_argument("input", type=Path)
    inspect_parser.add_argument("--expect-rate", type=int, choices=SUPPORTED_RATES)
    inspect_parser.add_argument("--expect-channels", type=int, choices=range(1, 5))
    inspect_parser.add_argument("--expect-bits", type=int, choices=SUPPORTED_BITS)
    inspect_parser.set_defaults(handler=inspect)

    spectrum_parser = subparsers.add_parser(
        "spectrum", help="report dependency-free FFT energy bands"
    )
    spectrum_parser.add_argument("input", type=Path)
    spectrum_parser.add_argument(
        "--start", type=float, default=0.0, help="start time in seconds (default: 0)"
    )
    spectrum_parser.add_argument(
        "--fft-frames",
        type=int,
        default=65_536,
        help="maximum FFT window; rounded down to a power of two",
    )
    spectrum_parser.add_argument(
        "--channel",
        type=int,
        action="append",
        help="zero-based channel to report; repeat as needed (default: all)",
    )
    spectrum_parser.set_defaults(handler=spectrum)
    return parser


def main() -> int:
    parser = build_parser()
    arguments = parser.parse_args()
    if getattr(arguments, "chunk_frames", 1) <= 0:
        parser.error("--chunk-frames must be greater than zero")
    if getattr(arguments, "fft_frames", 1) <= 0:
        parser.error("--fft-frames must be greater than zero")
    if getattr(arguments, "start", 0.0) < 0.0:
        parser.error("--start cannot be negative")
    try:
        arguments.handler(arguments)
    except SignalError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
