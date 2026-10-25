"""Macro is melody, micro is timbre: build a wavetable from how notes are played.

Each variational segment has a constant pitch level, so the deviation inside a
segment is free of pitch information. Normalising those deviations and
concatenating them gives a single cycle that records only how the hand moved:
a steady hand gives a pure shape, a shaky one gives a rough shape.
"""

from __future__ import annotations

import math
import struct
import tempfile
import wave
from pathlib import Path
from typing import List, Sequence

from tools.synthwave_loop import (DEFAULT_PITCH_SPACE, STYLE, compile_loop,
                                  load_jsonl_records, preprocess_samples, resample_to_ticks)
from tools.synthwave_loop import length_from_take

SR = 48000
TABLE_SIZE = 1024
CHUNK = 64


def resample(values: Sequence[float], size: int) -> List[float]:
    if not values:
        return [0.0] * size
    out = []
    span = max(1, len(values) - 1)
    for index in range(size):
        position = index * span / max(1, size - 1)
        left = int(position)
        right = min(len(values) - 1, left + 1)
        frac = position - left
        out.append(values[left] * (1.0 - frac) + values[right] * frac)
    return out


def default_table(kind: str = "saw") -> List[float]:
    if kind == "saw":
        return [(2.0 * index / TABLE_SIZE) - 1.0 for index in range(TABLE_SIZE)]
    if kind == "square":
        return [1.0 if index < TABLE_SIZE // 2 else -1.0 for index in range(TABLE_SIZE)]
    return [math.sin(2.0 * math.pi * index / TABLE_SIZE) for index in range(TABLE_SIZE)]


def build_table(values: Sequence[float], segments: Sequence[tuple],
                max_chunks: int = TABLE_SIZE // CHUNK) -> List[float]:
    """Average the normalised shape of each segment into one cycle."""
    chunks: List[List[float]] = []
    for start, end, level in segments:
        piece = [float(value) - (DEFAULT_PITCH_SPACE.min_midi + float(level) * 0.0)
                 for value in values[start:end]]
        if len(piece) < 4:
            continue
        base = sum(piece) / len(piece)
        residue = [value - base for value in piece]
        peak = max((abs(value) for value in residue), default=0.0)
        if peak <= 1e-6:
            continue
        chunks.append(resample([value / peak for value in residue], CHUNK))
        if len(chunks) >= max_chunks:
            break
    if not chunks:
        return default_table("saw")
    flat: List[float] = []
    for chunk in chunks:
        flat.extend(chunk)
    table = resample(flat, TABLE_SIZE)
    mean = sum(table) / len(table)
    table = [value - mean for value in table]
    peak = max((abs(value) for value in table), default=0.0)
    return [value / peak for value in table] if peak else default_table("saw")


def blend(a: Sequence[float], b: Sequence[float], weight: float) -> List[float]:
    return [(1.0 - weight) * x + weight * y for x, y in zip(a, b)]


def render(table: Sequence[float], notes: Sequence[dict], seconds_per_tick: float,
           output: Path) -> dict:
    """Monophonic render, enough to judge timbre."""
    total_seconds = max(1, notes[-1]["tick"] + notes[-1].get("duration", 1)) * seconds_per_tick + 0.4
    total = int(total_seconds * SR)
    buffer = [0.0] * total
    for event in notes:
        start = int(event["tick"] * seconds_per_tick * SR)
        length = int(max(1, int(event.get("duration", 1))) * seconds_per_tick * SR)
        freq = 440.0 * 2.0 ** ((event["note"] - 69) / 12.0)
        step = freq * TABLE_SIZE / SR
        phase = 0.0
        attack = max(1, int(0.006 * SR))
        release = max(1, int(0.05 * SR))
        for index in range(length):
            if start + index >= total:
                break
            if index < attack:
                env = index / attack
            elif index > length - release:
                env = max(0.0, (length - index) / release)
            else:
                env = 1.0
            sample = table[int(phase) % TABLE_SIZE] * env * 0.22
            buffer[start + index] += sample
            phase += step
    peak = max((abs(value) for value in buffer), default=0.0)
    if peak:
        scale = 0.8 / peak
        buffer = [value * scale for value in buffer]
    with wave.open(str(output), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SR)
        handle.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, value)) * 32000))
                                    for value in buffer))
    return {"seconds": len(buffer) / SR, "notes": len(notes)}


def main() -> None:
    capture = Path("pc_receiver/captures/lead_20261025-131102.jsonl")
    records = load_jsonl_records(capture)
    rows = preprocess_samples(records, pitch_source="cursor")
    style = length_from_take(rows, STYLE, 32)
    ticks = resample_to_ticks(rows, style, "loop")
    values = [None if row.get("b_abs") is None else
              DEFAULT_PITCH_SPACE.min_midi + float(row["b_abs"]) * 17.0 for row in ticks]
    table_result = compile_loop(records, {}, note_source="variational", lam=5.83,
                                time_map="loop", auto_length=True)
    segments = []
    for event in table_result["events"]:
        if event.get("type") == "note_on":
            segments.append((int(event["tick"]), int(event["tick"]) + int(event.get("duration", 1)), 0))
    notes = [{"tick": int(event["tick"]), "duration": int(event.get("duration", 1)),
              "note": int(event["note"]), "velocity": int(event.get("velocity", 90))}
             for event in table_result["events"] if event.get("type") == "note_on"]
    seconds_per_tick = 60.0 / style.bpm / 4.0

    gesture = build_table(values, segments)
    saw = default_table("saw")
    mixed = blend(saw, gesture, 0.7)
    out = Path(tempfile.gettempdir())
    for name, table in (("wt_saw", saw), ("wt_gesture", gesture), ("wt_mixed", mixed)):
        print(name, render(table, notes, seconds_per_tick, out / f"{name}.wav"))


if __name__ == "__main__":
    main()
