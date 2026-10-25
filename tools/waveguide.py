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


def render_contour(levels: Sequence[float], pressure: Sequence[float], activity: Sequence[float],
                   output: Path | str, sample_rate: int = SAMPLE_RATE,
                   seconds_per_tick: float = 0.15, loop: bool = False) -> dict:
    """One string, driven by a pitch contour with per tick pressure and activity.

    `levels` are semitones, `pressure` 0..1 (1 = pressed against the string),
    `activity` 0..1 (how fast the hand is moving). `loop` repeats the contour so
    the result can be judged as a groove rather than a fragment.
    """
    max_delay = int(sample_rate / 40.0) + 8
    buffer = [0.0] * max_delay
    write = 0
    rng = random.Random(20261025)
    samples_per_tick = max(1, int(round(seconds_per_tick * sample_rate)))
    samples: List[int] = []
    passes = 2 if loop else 1

    for _ in range(passes):
        for index, level in enumerate(levels):
            pressed = float(pressure[index])
            moving = float(activity[index])
            target = _delay_samples(semitone_to_hz(level), sample_rate, max_delay)
            damping = DAMP_NEAR * pressed + DAMP_FAR * (1.0 - pressed)
            gain = LOOP_GAIN * (0.30 + 0.30 * pressed)
            # Excitation: friction noise, rougher when the hand moves quickly.
            excite = (0.02 + 0.10 * moving) * (0.3 + 0.7 * pressed)
            for _sample in range(samples_per_tick):
                read = write - target
                while read < 0:
                    read += max_delay
                first = int(read)
                frac = read - first
                a = buffer[first % max_delay]
                b = buffer[(first + 1) % max_delay]
                delayed = a + (b - a) * frac
                filtered = delayed * (1.0 - damping) + damping * buffer[(write - 2) % max_delay]
                buffer[write] = filtered * gain + rng.uniform(-excite, excite)
                write = (write + 1) % max_delay
                value = filtered * LEVEL_SCALE
                if value > 32767:
                    value = 32767
                elif value < -32768:
                    value = -32768
                samples.append(int(value))
            # Glide the delay length towards the new pitch between ticks.
            current = target

    # Normalise to a fixed headroom so every take is comparable by ear.
    peak = max((abs(sample) for sample in samples), default=0)
    if peak > 0:
        scale = (0.8 * 32767.0) / peak
        samples = [int(max(-32768, min(32767, sample * scale))) for sample in samples]
    path = Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"".join(struct.pack("<h", sample) for sample in samples))
    peak = max(abs(sample) for sample in samples) if samples else 0
    return {"samples": len(samples), "seconds": len(samples) / sample_rate, "peak": peak}


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
