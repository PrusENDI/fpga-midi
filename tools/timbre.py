"""Timbre design on the PC: segmented FFT to a short periodic function.

The host does the analysis, the FPGA only plays the result. Knobs here are the
ones that will become CSR parameters: square base mix, spectral exponent, and
unison detune.
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Dict, List, Sequence

from tools.synthwave_loop import (DEFAULT_PITCH_SPACE, STYLE, compile_loop,
                                  load_jsonl_records, preprocess_samples,
                                  resample_to_ticks, length_from_take)

TABLE_SIZE = 1024
PARTIALS = 32


def _dft_amplitudes(values: Sequence[float], partials: int = PARTIALS) -> List[float]:
    count = len(values)
    mean = sum(values) / count
    centred = [value - mean for value in values]
    peak = max((abs(value) for value in centred), default=0.0) or 1.0
    centred = [value / peak for value in centred]
    out = []
    for harmonic in range(1, partials + 1):
        real = sum(centred[n] * math.cos(2.0 * math.pi * harmonic * n / count)
                   for n in range(count))
        imag = sum(centred[n] * math.sin(2.0 * math.pi * harmonic * n / count)
                   for n in range(count))
        out.append(math.hypot(real, imag) / count)
    return out


def _median(values: Sequence[float]) -> float:
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if ordered else 0.0


def segmented_spectrum(values: Sequence[float], segments: Sequence[tuple],
                       partials: int = PARTIALS) -> List[float]:
    """Median spectrum across segments, so one shaky segment cannot dominate."""
    per_harmonic: List[List[float]] = [[] for _ in range(partials)]
    for start, end in segments:
        piece = [float(value) for value in values[start:end] if value is not None]
        if len(piece) < 8:
            continue
        amps = _dft_amplitudes(piece, partials)
        for index, amplitude in enumerate(amps):
            per_harmonic[index].append(amplitude)
    median = [_median(column) for column in per_harmonic]
    first = median[0] or 1e-9
    return [value / first for value in median]


def build_table(amplitudes: Sequence[float], exponent: float = 1.5,
                square_mix: float = 0.6, size: int = TABLE_SIZE) -> List[float]:
    """Additive synthesis of the spectrum, blended with a square base."""
    shaped = [max(0.01, value ** exponent) for value in amplitudes]
    table = []
    for index in range(size):
        phase = 2.0 * math.pi * index / size
        additive = sum(amplitude * math.sin(phase * (harmonic + 1))
                       for harmonic, amplitude in enumerate(shaped))
        square = 1.0 if index < size // 2 else -1.0
        table.append((1.0 - square_mix) * additive + square_mix * square * 0.35)
    peak = max((abs(value) for value in table), default=0.0) or 1.0
    return [value / peak for value in table]


def build_timbre(capture: Path | str, knobs: Dict[str, float] | None = None) -> Dict[str, object]:
    """One call from the UI: capture plus knob values in, table and params out."""
    settings = {"exponent": 1.5, "square_mix": 0.6, "detune_cents": 7.0}
    if knobs:
        settings.update({key: float(value) for key, value in knobs.items()})
    records = load_jsonl_records(capture)
    rows = preprocess_samples(records, pitch_source="cursor")
    style = length_from_take(rows, STYLE, 32)
    ticks = resample_to_ticks(rows, style, "loop")
    values = [None if row.get("b_abs") is None else
              DEFAULT_PITCH_SPACE.min_midi + float(row["b_abs"]) * 17.0 for row in ticks]
    table = compile_loop(records, {}, note_source="variational", lam=5.83,
                         time_map="loop", auto_length=True)
    segments = [(int(event["tick"]), int(event["tick"]) + int(event.get("duration", 1)))
                for event in table["events"] if event.get("type") == "note_on"]
    amplitudes = segmented_spectrum(values, segments)
    return {"table": build_table(amplitudes, settings["exponent"], settings["square_mix"]),
            "amplitudes": amplitudes, "settings": settings,
            "segments": len(segments), "loop_bars": table["config"]["loop_bars"]}


if __name__ == "__main__":
    import json
    info = build_timbre("pc_receiver/captures/lead_20261025-131102.jsonl")
    print(json.dumps({"segments": info["segments"], "settings": info["settings"],
                      "first_partials": [round(value, 3) for value in info["amplitudes"][:6]]}))
