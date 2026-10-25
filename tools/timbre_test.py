"""Fixed melody, several timbres, one file - for judging timbre only.

No sensor, no live audio. Renders a short five note phrase once per timbre,
back to back, so the differences can be compared without juggling files.

    python tools/timbre_test.py
"""

from __future__ import annotations

import math
import struct
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

SR = 48000
SIZE = 1024
NOTE_SECONDS = 0.55
GAP_SECONDS = 0.25
MELODY = [57, 60, 62, 64, 62]


def hz(note: int) -> float:
    return 440.0 * 2.0 ** ((note - 69) / 12.0)


def band_limit(table, partials: int = 32):
    keep = []
    for harmonic in range(1, partials + 1):
        real = sum(table[n] * math.cos(2.0 * math.pi * harmonic * n / SIZE) for n in range(SIZE))
        imag = sum(table[n] * math.sin(2.0 * math.pi * harmonic * n / SIZE) for n in range(SIZE))
        keep.append((2.0 * real / SIZE, 2.0 * imag / SIZE))
    out = []
    for index in range(SIZE):
        angle = 2.0 * math.pi * index / SIZE
        out.append(sum(a * math.cos(angle * h) + b * math.sin(angle * h)
                       for h, (a, b) in enumerate(keep, start=1)))
    peak = max((abs(value) for value in out), default=0.0) or 1.0
    return [value / peak for value in out]


def table_sine():
    return [math.sin(2.0 * math.pi * i / SIZE) for i in range(SIZE)]


def table_saw():
    return band_limit([2.0 * (i / SIZE) - 1.0 for i in range(SIZE)], 24)


def table_square():
    return band_limit([1.0 if i < SIZE // 2 else -1.0 for i in range(SIZE)], 24)


def table_curve():
    """The recorded contour, time normalised onto phase."""
    from tools.synthwave_loop import (STYLE, load_jsonl_records, preprocess_samples,
                                      resample_to_ticks, length_from_take)
    capture = ROOT / "pc_receiver" / "captures" / "lead_20261025-131102.jsonl"
    if not capture.exists():
        return table_saw()
    rows = preprocess_samples(load_jsonl_records(capture), pitch_source="cursor")
    style = length_from_take(rows, STYLE, 32)
    ticks = resample_to_ticks(rows, style, "loop")
    values = [float(row["b_abs"]) for row in ticks if row.get("b_abs") is not None]
    if len(values) < 8:
        return table_saw()
    table = []
    span = len(values) - 1
    for index in range(SIZE):
        position = index * span / (SIZE - 1.0)
        left = int(position)
        right = min(len(values) - 1, left + 1)
        frac = position - left
        value = values[left] * (1.0 - frac) + values[right] * frac
        table.append(2.0 * value - 1.0)
    return band_limit(table, 32)


def render(table, output, sample_rate: int = SR):
    samples = []
    attack = int(0.008 * sample_rate)
    release = int(0.09 * sample_rate)
    note_len = int(NOTE_SECONDS * sample_rate)
    for note in MELODY:
        step = hz(note) * SIZE / sample_rate
        phase = 0.0
        for index in range(note_len):
            if index < attack:
                env = index / attack
            elif index > note_len - release:
                env = max(0.0, (note_len - index) / release)
            else:
                env = 1.0
            samples.append(table[int(phase) % SIZE] * env)
            phase += step
        samples.extend([0.0] * int(GAP_SECONDS * sample_rate))
    peak = max((abs(value) for value in samples), default=0.0) or 1.0
    with wave.open(str(output), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"".join(struct.pack("<h", int(value / peak * 26000))
                                    for value in samples))
    return len(samples) / sample_rate


def main() -> None:
    out = Path(tempfile_path())
    timbres = [("sine", table_sine()), ("saw", table_saw()), ("square", table_square()),
               ("curve", table_curve())]
    order = []
    for name, table in timbres:
        path = out / ("timbre_%s.wav" % name)
        seconds = render(table, path)
        order.append(name)
        print("%-7s %.2fs  %s" % (name, seconds, path.name))
    print("order:", " ".join(order))


def tempfile_path() -> Path:
    import tempfile
    return Path(tempfile.gettempdir())


if __name__ == "__main__":
    main()
