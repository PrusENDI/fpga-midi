"""LIVE note rule: level crossing with hysteresis, one note at a time.

This is the rule the FPGA will run frame by frame, because the variational
segmentation needs a whole take and cannot stream. It is deliberately simple:
quantise the contour to the scale with hysteresis, and open a note whenever the
quantised level changes, subject to a minimum length.
"""

from __future__ import annotations

from typing import List, Optional, Sequence

from tools.synth_reference import (SAMPLE_RATE, TIMBRE_SAW, SynthEngine,
                                   note_frequency, phase_increment)


def quantise(value: float, pitches: Sequence[int], previous: Optional[int],
             hysteresis: float = 0.10) -> int:
    """Nearest scale degree, with a dead band around the previous choice."""
    nearest = min(pitches, key=lambda pitch: abs(float(pitch) - value))
    if previous is None:
        return nearest
    if abs(float(previous) - value) <= hysteresis + 1e-9:
        return previous
    return nearest


class LiveLead:
    """Streaming pitch tracker that emits note boundaries as ticks arrive."""

    def __init__(self, pitches: Sequence[int], hysteresis: float = 0.10,
                 min_ticks: int = 4) -> None:
        self.pitches = list(pitches)
        self.hysteresis = float(hysteresis)
        self.min_ticks = int(min_ticks)
        self.current: Optional[int] = None
        self.current_tick: Optional[int] = None
        self.notes: List[dict] = []

    def push(self, tick: int, semitones: float) -> List[dict]:
        level = quantise(semitones, self.pitches, self.current, self.hysteresis)
        events: List[dict] = []
        if level == self.current:
            return events
        if self.current is not None and self.current_tick is not None:
            duration = tick - self.current_tick
            if duration < self.min_ticks:
                return events   # too short to be a note; keep the old one
            events.append({"type": "note_off", "tick": tick, "note": self.current,
                           "duration": duration})
        self.current = level
        self.current_tick = tick
        events.append({"type": "note_on", "tick": tick, "note": level})
        self.notes.append({"tick": tick, "note": level})
        return events

    def close(self, tick: int) -> List[dict]:
        if self.current is None or self.current_tick is None:
            return []
        events = [{"type": "note_off", "tick": tick, "note": self.current,
                   "duration": max(1, tick - self.current_tick)}]
        self.current = None
        return events


def render_live(levels: Sequence[float], pitches: Sequence[int], output,
                sample_rate: int = SAMPLE_RATE, seconds_per_tick: float = 0.15,
                timbre: int = TIMBRE_SAW, velocity: int = 100) -> dict:
    """Play a contour through the LIVE rule and render it to a WAV."""
    import struct
    import wave
    from pathlib import Path

    lead = LiveLead(pitches)
    engine = SynthEngine(voice_count=1, sample_rate=sample_rate)
    samples_per_tick = max(1, int(round(seconds_per_tick * sample_rate)))
    samples: List[int] = []
    pending: List[dict] = []
    for tick, value in enumerate(levels):
        pending.extend(lead.push(tick, value))
        for event in pending:
            if event["type"] == "note_on":
                engine.note_on(0, event["note"], velocity, timbre)
            else:
                engine.note_off(0, event["note"])
        pending = []
        samples.extend(engine.render(samples_per_tick))
    for event in lead.close(len(levels)):
        if event["type"] == "note_off":
            engine.note_off(0, event["note"])
    samples.extend(engine.render(int(0.6 * sample_rate)))

    path = Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, int(s))))
                                    for s in samples))
    return {"notes": len(lead.notes), "samples": len(samples),
            "sequence": [item["note"] for item in lead.notes]}
