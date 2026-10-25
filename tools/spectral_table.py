"""Three spectral-envelope wavetables, built by additive synthesis."""

from __future__ import annotations

import math
import tempfile
from pathlib import Path

from tools.synthwave_loop import (DEFAULT_PITCH_SPACE, STYLE, compile_loop,
                                  load_jsonl_records, preprocess_samples,
                                  resample_to_ticks, length_from_take)
from tools.wavetable_lab import TABLE_SIZE, render

PARTIALS = 32


def table_from_amplitudes(amplitudes, size: int = TABLE_SIZE):
    table = []
    for index in range(size):
        phase = 2.0 * math.pi * index / size
        value = sum(amplitude * math.sin(phase * (harmonic + 1))
                    for harmonic, amplitude in enumerate(amplitudes))
        table.append(value)
    peak = max((abs(value) for value in table), default=0.0)
    return [value / peak for value in table] if peak else table


def flat_spectrum():
    return [1.0 / (harmonic + 1) for harmonic in range(PARTIALS)]


def lead_like_spectrum():
    """Approximates the original lead: saw 54 percent, pulse 26, sine 20."""
    out = []
    for harmonic in range(PARTIALS):
        n = harmonic + 1
        saw = 0.54 / n
        pulse = 0.26 * (2.0 / (math.pi * n)) * math.sin(math.pi * n * 0.47)
        sine = 0.20 if n == 1 else 0.0
        out.append(abs(saw) + abs(pulse) + sine)
    return out


def gesture_spectrum(capture: Path, exponent: float = 1.5):
    """Real spectrum of the contour: DFT magnitude, H1 normalised, compressed."""
    records = load_jsonl_records(capture)
    rows = preprocess_samples(records, pitch_source="cursor")
    style = length_from_take(rows, STYLE, 32)
    ticks = resample_to_ticks(rows, style, "loop")
    values = [float(row["b_abs"]) for row in ticks if row.get("b_abs") is not None]
    if len(values) < PARTIALS * 2:
        return flat_spectrum()
    mean = sum(values) / len(values)
    values = [value - mean for value in values]
    peak = max(abs(value) for value in values) or 1.0
    values = [value / peak for value in values]
    count = min(len(values), 2048)
    amplitudes = []
    for harmonic in range(1, PARTIALS + 1):
        real = sum(values[n] * math.cos(2.0 * math.pi * harmonic * n / count)
                   for n in range(count))
        imag = sum(values[n] * math.sin(2.0 * math.pi * harmonic * n / count)
                   for n in range(count))
        amplitudes.append(math.hypot(real, imag) / count)
    first = amplitudes[0] or 1e-9
    amplitudes = [value / first for value in amplitudes]
    # Compress the natural 1/f falloff so the upper partials stay audible.
    return [max(0.01, value ** exponent) for value in amplitudes]


def main() -> None:
    capture = Path("pc_receiver/captures/lead_20261025-131102.jsonl")
    records = load_jsonl_records(capture)
    table_result = compile_loop(records, {}, note_source="variational", lam=5.83,
                                time_map="loop", auto_length=True)
    notes = [{"tick": int(event["tick"]), "duration": int(event.get("duration", 1)),
              "note": int(event["note"]), "velocity": int(event.get("velocity", 90))}
             for event in table_result["events"] if event.get("type") == "note_on"]
    rows = preprocess_samples(records, pitch_source="cursor")
    style = length_from_take(rows, STYLE, 32)
    seconds_per_tick = 60.0 / style.bpm / 4.0

    out = Path(tempfile.gettempdir())
    tables = {
        "spec_flat": flat_spectrum(),
        "spec_lead": lead_like_spectrum(),
        "spec_gesture": gesture_spectrum(capture),
    }
    tables = {name: value for name, value in tables.items() if name != "spec_flat"}
    tables["spec_gesture"] = gesture_spectrum(capture, 1.5)
    tables["spec_soft"] = gesture_spectrum(capture, 2.0)
    for name, amplitudes in tables.items():
        table = table_from_amplitudes(amplitudes)
        print(name, render(table, notes, seconds_per_tick, out / (name + ".wav")))


if __name__ == "__main__":
    main()
