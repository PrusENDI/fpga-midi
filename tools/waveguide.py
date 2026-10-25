"""PC prototype of the bowed-string backend: one waveguide voice.

The string is excited continuously while the hand is inside the sensing field.
Height sets the loop damping (near means pressed and bright, far means light
and airy), hand speed sets how rough the excitation is, and contact only adds a
transient accent. Nothing here is gated by contact, because that would turn the
instrument into a touchpad.

Everything is as simple as it can be while still sounding like a string: a
delay line with linear interpolation, a one pole loop filter, and noise
injection. It is the reference the FPGA build will be compared against.
"""

from __future__ import annotations

import math
import random
import struct
import wave
from pathlib import Path
from typing import List, Sequence

from tools.synthwave_loop import (DEFAULT_PITCH_SPACE, STYLE, load_jsonl_records,
                                  preprocess_samples, resample_to_ticks, length_from_take)

SAMPLE_RATE = 48000
LEVEL_SCALE = 32767
# Loop gain well under one, so the string always decays when excitation stops.
LOOP_GAIN = 0.985
# Damping range: closed at the near end, open when the hand is far away.
DAMP_NEAR = 0.75
DAMP_FAR = 0.18


def semitone_to_hz(semitones: float) -> float:
    return 440.0 * (2.0 ** ((float(semitones) - 69.0) / 12.0))


def _delay_samples(hz: float, sample_rate: int, max_delay: int) -> float:
    delay = sample_rate / max(20.0, hz)
    return max(2.0, min(float(max_delay - 3), delay))


def render_contour(levels, pressure, activity, output, sample_rate=SAMPLE_RATE,
                   seconds_per_tick=0.15):
    rng = random.Random(20261025)
    per_tick = max(1, int(round(seconds_per_tick * sample_rate)))
    max_delay = int(sample_rate / 30.0) + 4
    buffer = [0.0] * max_delay
    write = 0
    last = 0.0
    samples = []
    for level, pressed, moving in zip(levels, pressure, activity):
        pressed = float(pressed); moving = float(moving)
        target = sample_rate / max(30.0, semitone_to_hz(level))
        target = max(4.0, min(float(max_delay - 3), target))
        alpha = 0.18 + 0.42 * pressed
        gain = 0.985 + 0.012 * pressed
        excite = 0.0002 + 0.0012 * moving * (0.3 + 0.7 * pressed)
        for _ in range(per_tick):
            read = write - target
            while read < 0.0:
                read += max_delay
            first = int(read); frac = read - first
            a = buffer[first % max_delay]; b = buffer[(first + 1) % max_delay]
            delayed = a + (b - a) * frac
            filtered = alpha * delayed + (1.0 - alpha) * last
            last = delayed
            buffer[write] = filtered * gain + rng.uniform(-excite, excite)
            write = (write + 1) % max_delay
            samples.append(filtered)
    peak = max((abs(v) for v in samples), default=0.0)
    if peak > 0:
        scale = (0.8 * 32767.0) / peak
        samples = [v * scale for v in samples]
    path = Path(output); path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as h:
        h.setnchannels(1); h.setsampwidth(2); h.setframerate(sample_rate)
        h.writeframes(b"".join(struct.pack("<h", int(max(-32768, min(32767, v)))) for v in samples))
    return {"samples": len(samples), "seconds": len(samples)/sample_rate,
            "peak": max((abs(int(v)) for v in samples), default=0)}


def contour_from_capture(path: Path | str, pitch_source: str = "cursor") -> dict:
    """Extract level, pressure and activity per tick from a real take."""
    records = load_jsonl_records(path)
    rows = preprocess_samples(records, pitch_source=pitch_source)
    style = length_from_take(rows, STYLE, 32)
    ticks = resample_to_ticks(rows, style, "loop")
    levels, pressure, activity = [], [], []
    for row in ticks:
        raw = row.get("b_abs")
        z = row.get("q_z")
        if raw is None:
            continue
        levels.append(DEFAULT_PITCH_SPACE.min_midi + float(raw) * (DEFAULT_PITCH_SPACE.max_midi - DEFAULT_PITCH_SPACE.min_midi))
        pressure.append(max(0.0, min(1.0, 1.0 - (float(z) if z is not None else 0.5))))
        activity.append(max(0.0, min(1.0, float(row.get("speed", 0.0)) * 3.0)))
    return {"levels": levels, "pressure": pressure, "activity": activity,
            "seconds_per_tick": 60.0 / style.bpm / 4.0}


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Render a take through the waveguide prototype")
    parser.add_argument("input", type=Path)
    parser.add_argument("--wav", type=Path, default=Path("waveguide.wav"))
    args = parser.parse_args()
    contour = contour_from_capture(args.input)
    info = render_contour(contour["levels"], contour["pressure"], contour["activity"],
                          args.wav, seconds_per_tick=contour["seconds_per_tick"], loop=True)
    print(info)
