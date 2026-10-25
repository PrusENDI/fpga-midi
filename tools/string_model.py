"""Isolated Karplus-Strong string, for measuring before it is driven by a gesture.

Kept separate from `waveguide.py` so the model can be tested on a fixed pitch
alone: a string that cannot hold a tune at constant pitch will not hold one
under a moving contour either.
"""

from __future__ import annotations

import random

SAMPLE_RATE = 48000


def semitone_to_hz(semitones: float) -> float:
    return 440.0 * (2.0 ** ((float(semitones) - 69.0) / 12.0))


def render_string(note: float, seconds: float, sample_rate: int = SAMPLE_RATE,
                  pressure: float = 0.6, excite: float = 1.0, seed: int = 7) -> list:
    """Delay line closed through a one pole lowpass, excited by faint noise."""
    rng = random.Random(seed)
    delay = sample_rate / max(20.0, semitone_to_hz(note))
    size = int(sample_rate / 20.0) + 4
    buffer = [0.0] * size
    write = 0
    last = 0.0
    alpha = 0.35 + 0.35 * float(pressure)
    gain = 0.9955 + 0.0040 * float(pressure)
    level = 0.0012 * float(excite) * (0.4 + 0.6 * float(pressure))
    out = []
    for _ in range(int(seconds * sample_rate)):
        read = write - delay
        while read < 0.0:
            read += size
        first = int(read)
        frac = read - first
        a = buffer[first % size]
        b = buffer[(first + 1) % size]
        delayed = a + (b - a) * frac
        filtered = alpha * delayed + (1.0 - alpha) * last
        last = delayed
        buffer[write] = filtered * gain + rng.uniform(-level, level)
        write = (write + 1) % size
        out.append(filtered)
    peak = max((abs(value) for value in out), default=0.0)
    return [value / peak for value in out] if peak else out
