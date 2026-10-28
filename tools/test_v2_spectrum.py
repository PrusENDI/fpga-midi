"""Analyze the independent V2 N-tone test-mode capture."""
from __future__ import annotations

import argparse
from pathlib import Path
import math


MAX_SIDEBAND_RATIO = 0.02


def _load(path: Path) -> list[float]:
    values = []
    for line in path.read_text(encoding="ascii").splitlines():
        line = line.strip()
        if line:
            values.append(float(line))
    if len(values) < 256:
        raise ValueError(f"{path} has too few samples")
    return values


def _fft_power(values: list[float]) -> list[float]:
    """Return a one-sided power spectrum using a small radix-2 FFT."""
    n = len(values)
    if n == 0 or n & (n - 1):
        raise ValueError("FFT input length must be a power of two")
    data = [complex(value, 0.0) for value in values]
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            data[i], data[j] = data[j], data[i]
    width = 2
    while width <= n:
        angle = -2.0 * math.pi / width
        root = complex(math.cos(angle), math.sin(angle))
        for start in range(0, n, width):
            twiddle = complex(1.0, 0.0)
            half = width // 2
            for offset in range(half):
                even = data[start + offset]
                odd = twiddle * data[start + offset + half]
                data[start + offset] = even + odd
                data[start + offset + half] = even - odd
                twiddle *= root
        width <<= 1
    return [value.real * value.real + value.imag * value.imag
            for value in data[: n // 2 + 1]]


def analyze(samples: list[float], tone_count: int, sample_rate: float = 48_000.0) -> dict:
    data = [float(value) for value in samples]
    mean = sum(data) / len(data)
    data = [value - mean for value in data]

    def magnitude(frequency: float) -> float:
        angle = 2.0 * math.pi * frequency / sample_rate
        rot = complex(math.cos(angle), -math.sin(angle))
        phase = complex(1.0, 0.0)
        accum = complex(0.0, 0.0)
        for value in data:
            accum += value * phase
            phase *= rot
        return abs(accum) * 2.0 / len(data)

    peaks = []
    for k in range(1, tone_count + 1):
        expected = 220.0 * k
        candidates = [expected + offset for offset in range(-10, 11)]
        measured = max(candidates, key=magnitude)
        amplitude = magnitude(measured)
        error = abs(measured - expected)
        if amplitude <= 1.0 or error > 8.0:
            raise AssertionError(
                f"tone {k}: expected={expected:g} measured={measured:g} "
                f"error={error:g} amplitude={amplitude:g}"
            )
        peaks.append({"tone": k, "expected_hz": expected,
                      "measured_hz": measured, "error_hz": error,
                      "amplitude": amplitude})
    # A Hann-windowed radix-2 FFT gives a reproducible sideband diagnostic
    # without requiring NumPy.  Keep the two neighboring bins around each
    # expected fundamental in the fundamental set to cover the finite window's
    # main lobe; everything else contributes to the reported ratio.
    windowed = [value * (0.5 - 0.5 * math.cos(2.0 * math.pi * i / (len(data) - 1)))
                for i, value in enumerate(data)]
    power = _fft_power(windowed)
    fundamental_bins = set()
    for peak in peaks:
        center = int(round(peak["expected_hz"] * len(data) / sample_rate))
        fundamental_bins.update(range(max(1, center - 1),
                                      min(len(power) - 1, center + 1) + 1))
    total_power = sum(power[1:])
    fundamental_power = sum(power[index] for index in fundamental_bins)
    sideband_ratio = ((total_power - fundamental_power) / total_power
                      if total_power else 0.0)
    return {"tone_count": tone_count, "peaks": peaks,
            "sideband_ratio": sideband_ratio}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True,
                        help="capture directory or one tone_N.csv file")
    parser.add_argument("--tones", type=int, default=0,
                        help="tone count for a single file")
    args = parser.parse_args()
    paths = [args.input] if args.input.is_file() else sorted(args.input.glob("tone_*.csv"))
    if not paths:
        raise SystemExit(f"no tone captures under {args.input}")
    reports = []
    for path in paths:
        tone_count = args.tones
        if not tone_count:
            try:
                tone_count = int(path.stem.split("_", 1)[1])
            except (IndexError, ValueError) as exc:
                raise SystemExit(f"cannot infer tone count from {path.name}") from exc
        if not 1 <= tone_count <= 32:
            raise SystemExit(f"tone count outside 1..32: {tone_count}")
        report = analyze(_load(path), tone_count)
        if report["sideband_ratio"] > MAX_SIDEBAND_RATIO:
            raise AssertionError(
                f"{path.name}: sideband ratio {report['sideband_ratio']:.4f} "
                f"exceeds {MAX_SIDEBAND_RATIO:.4f}"
            )
        reports.append(report)
    for report, path in zip(reports, paths):
        errors = ", ".join(f"{p['error_hz']:.2f}Hz" for p in report["peaks"])
        print(f"{path.name}: N={report['tone_count']} peak_errors=[{errors}] "
              f"sideband_ratio={report['sideband_ratio']:.4f}")
    print(f"v2 N-tone spectrum PASS files={len(paths)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
