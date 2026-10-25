"""Render an EventTable to audio with the fixed point reference engine.

This is the PC side of the pipeline tail: the event table the compiler already
produces is scheduled onto sample positions and played by `synth_reference`.
The FPGA will run the same schedule, so the numbers here are the comparison
target for the hardware.
"""

from __future__ import annotations

import struct
import wave
from pathlib import Path
from typing import Iterable, List, Mapping, Sequence

from tools.synth_reference import (SAMPLE_RATE, TIMBRE_SAW, TIMBRE_SINE,
                                   TIMBRE_SQUARE, TIMBRE_TRIANGLE, SynthEngine)

# One timbre per track, so the four parts stay distinguishable.
TRACK_TIMBRE = {
    "lead": TIMBRE_SAW,
    "bass": TIMBRE_SQUARE,
    "pad": TIMBRE_SINE,
    "arp": TIMBRE_TRIANGLE,
    "drums": TIMBRE_SQUARE,
    "texture_fx": TIMBRE_SINE,
}
TRACK_INDEX = {"lead": 0, "bass": 1, "pad": 2, "arp": 3, "drums": 4, "texture_fx": 5}


def _schedule(table: Mapping[str, object], loops: int, sample_rate: int) -> List[tuple]:
    """One (sample, kind, track, note, velocity) row per scheduled action."""
    config = table.get("config", {})
    bpm = float(config.get("bpm", 100))
    loop_bars = int(config.get("loop_bars", 8))
    loop_seconds = 60.0 * 4.0 * loop_bars / bpm
    seconds_per_tick = loop_seconds / max(1, loop_bars * int(config.get("ticks_per_bar", 16)))
    actions: List[tuple] = []
    for event in table.get("events", []):
        if event.get("type") != "note_on" or "note" not in event:
            continue
        track = str(event.get("track", "lead"))
        index = TRACK_INDEX.get(track, 0)
        for loop in range(max(1, loops)):
            start = (loop * loop_seconds + int(event.get("tick", 0)) * seconds_per_tick)
            start_sample = int(round(start * sample_rate))
            length = max(1, int(round(int(event.get("duration", 1)) * seconds_per_tick * sample_rate)))
            actions.append((start_sample, "on", index, int(event["note"]), int(event.get("velocity", 90))))
            actions.append((start_sample + length, "off", index, int(event["note"]), 0))
    actions.sort(key=lambda item: (item[0], 0 if item[1] == "off" else 1))
    return actions


def render_table(table: Mapping[str, object], output: Path | str, *,
                 sample_rate: int = SAMPLE_RATE, loops: int = 1,
                 tail_ms: float = 800.0, voices: int = 32) -> Path:
    """Write a 16 bit mono WAV from an event table."""
    config = table.get("config", {})
    bpm = float(config.get("bpm", 100))
    loop_seconds = 60.0 * 4.0 * int(config.get("loop_bars", 8)) / bpm
    total = int((loop_seconds * max(1, loops) + tail_ms / 1000.0) * sample_rate)
    actions = _schedule(table, loops, sample_rate)
    engine = SynthEngine(voice_count=voices, sample_rate=sample_rate)
    timbre_of = {index: TRACK_TIMBRE.get(name, TIMBRE_SAW) for name, index in TRACK_INDEX.items()}

    samples: List[int] = []
    pointer = 0
    block = 256
    produced = 0
    while produced < total:
        # Apply every action due before the end of the next block.
        limit = produced + block
        while pointer < len(actions) and actions[pointer][0] < limit:
            _, kind, track, note, velocity = actions[pointer]
            if kind == "on":
                engine.note_on(track, note, velocity, timbre_of.get(track, TIMBRE_SAW))
            else:
                engine.note_off(track, note)
            pointer += 1
        chunk = engine.render(min(block, total - produced))
        samples.extend(chunk)
        produced += len(chunk)

    path = Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, int(sample))))
                                    for sample in samples))
    return path


def peak_amplitude(samples: Iterable[int]) -> int:
    peak = 0
    for sample in samples:
        peak = max(peak, abs(int(sample)))
    return peak
