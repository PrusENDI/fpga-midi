"""Fixed point voice engine that the FPGA implementation must match.

Everything here is integer arithmetic on purpose. The FPGA cannot use floats,
so a float reference would drift from the hardware the moment it is ported.
The numbers below are the contract: phase accumulator 32 bits, envelope 16
bits, velocity 7 bits, mixer 24 bits before saturation.

The structure mirrors `mgc3130_voice_mixer` from the FPGA baseline: two phase
accumulators per voice, one shared sine table, a linear ADSR, a glide that
moves the phase increment towards its target, and a saturating sum.
"""

from __future__ import annotations

import math
from typing import Dict, List, Tuple

SAMPLE_RATE = 48000
PHASE_BITS = 32
PHASE_SCALE = 1 << PHASE_BITS
TABLE_BITS = 10
TABLE_SIZE = 1 << TABLE_BITS
TABLE_SHIFT = PHASE_BITS - TABLE_BITS
ENV_MAX = 1 << 16
VELOCITY_MAX = 127

# Waveform selectors, matching the timbre field of the event word.
TIMBRE_SINE = 0
TIMBRE_SAW = 1
TIMBRE_SQUARE = 2
TIMBRE_TRIANGLE = 3


def _build_sine_table() -> Tuple[int, ...]:
    """1024 entries, signed 16 bit, indexed by the top phase bits."""
    peak = 32767
    return tuple(int(round(peak * math.sin(2.0 * math.pi * (index + 0.5) / TABLE_SIZE)))
                 for index in range(TABLE_SIZE))


SINE_TABLE = _build_sine_table()


def phase_increment(frequency_hz: float) -> int:
    """Phase step for one sample. 440 Hz at 48 kHz is 39,370,534."""
    return int(round(float(frequency_hz) * PHASE_SCALE / SAMPLE_RATE)) & 0xFFFFFFFF


def note_frequency(note: int) -> float:
    """Equal temperament, A4 = 69 = 440 Hz."""
    return 440.0 * (2.0 ** ((int(note) - 69) / 12.0))


def oscillator(phase: int, timbre: int) -> int:
    """One sample of the selected waveform, signed 16 bit."""
    index = (phase >> TABLE_SHIFT) & (TABLE_SIZE - 1)
    if timbre == TIMBRE_SINE:
        return SINE_TABLE[index]
    if timbre == TIMBRE_SAW:
        return ((phase >> 16) & 0xFFFF) - 32768
    if timbre == TIMBRE_SQUARE:
        return 32767 if (phase >> 31) & 1 else -32768
    # Triangle from the sine table's first quarter, folded.
    quarter = SINE_TABLE[index >> 1]
    return quarter if (index >> 9) & 1 else -quarter


class Envelope:
    """Linear ADSR in 16 bit levels, advanced once per sample."""

    IDLE = 0
    ATTACK = 1
    DECAY = 2
    SUSTAIN = 3
    RELEASE = 4

    def __init__(self, attack_ms: float = 8.0, decay_ms: float = 120.0,
                 sustain: float = 0.65, release_ms: float = 180.0,
                 sample_rate: int = SAMPLE_RATE) -> None:
        self.sustain = int(max(0.0, min(1.0, sustain)) * (ENV_MAX - 1))
        self.attack_step = max(1, int(ENV_MAX / max(1.0, attack_ms * sample_rate / 1000.0)))
        self.decay_step = max(1, int((ENV_MAX - self.sustain) / max(1.0, decay_ms * sample_rate / 1000.0)))
        self.release_step = max(1, int(self.sustain / max(1.0, release_ms * sample_rate / 1000.0)))
        self.level = 0
        self.state = Envelope.IDLE

    def trigger(self) -> None:
        self.state = Envelope.ATTACK

    def release(self) -> None:
        if self.state != Envelope.IDLE:
            self.state = Envelope.RELEASE

    def step(self) -> int:
        if self.state == Envelope.ATTACK:
            self.level += self.attack_step
            if self.level >= ENV_MAX - 1:
                self.level = ENV_MAX - 1
                self.state = Envelope.DECAY
        elif self.state == Envelope.DECAY:
            self.level -= self.decay_step
            if self.level <= self.sustain:
                self.level = self.sustain
                self.state = Envelope.SUSTAIN
        elif self.state == Envelope.RELEASE:
            self.level -= self.release_step
            if self.level <= 0:
                self.level = 0
                self.state = Envelope.IDLE
        return self.level


class Voice:
    """Two phase accumulators, one envelope, one glide ramp."""

    def __init__(self, sample_rate: int = SAMPLE_RATE) -> None:
        self.active = False
        self.track = 0
        self.note = 0
        self.velocity = 0
        self.timbre = TIMBRE_SAW
        self.phase = [0, 0]
        self.increment = 0
        self.target_increment = 0
        self.glide_step = 0
        self.envelope = Envelope(sample_rate=sample_rate)
        self.detune = int(0.004 * PHASE_SCALE / sample_rate) if sample_rate else 0
        self.serial = 0

    def start(self, note: int, velocity: int, timbre: int, glide_samples: int, sample_rate: int) -> None:
        target = phase_increment(note_frequency(note))
        if glide_samples > 0 and self.active:
            self.glide_step = max(1, abs(target - self.increment) // glide_samples)
            self.target_increment = target
        else:
            self.increment = target
            self.target_increment = target
            self.glide_step = 0
        self.note = int(note)
        self.velocity = max(1, min(VELOCITY_MAX, int(velocity)))
        self.timbre = int(timbre)
        self.envelope = Envelope(sample_rate=sample_rate)
        self.envelope.trigger()
        self.active = True

    def stop(self) -> None:
        self.envelope.release()

    def render(self, count: int) -> List[int]:
        """Produce `count` samples for this voice alone."""
        out: List[int] = []
        for _ in range(count):
            out.append(self._next_sample())
        return out

    def _next_sample(self) -> int:
        if not self.active:
            return 0
        if self.glide_step:
            if self.increment < self.target_increment:
                self.increment = min(self.target_increment, self.increment + self.glide_step)
            else:
                self.increment = max(self.target_increment, self.increment - self.glide_step)
        self.phase[0] = (self.phase[0] + self.increment) & 0xFFFFFFFF
        self.phase[1] = (self.phase[1] + self.increment + self.detune) & 0xFFFFFFFF
        left = oscillator(self.phase[0], self.timbre)
        right = oscillator(self.phase[1], self.timbre)
        wave = (left + right) >> 1
        level = self.envelope.step()
        if self.envelope.state == Envelope.IDLE:
            self.active = False
        return (wave * level >> 16) * self.velocity >> 7


class SynthEngine:
    """Thirty two voices, last-note stealing, saturating mix."""

    def __init__(self, voice_count: int = 32, sample_rate: int = SAMPLE_RATE,
                 glide_ms: float = 0.0) -> None:
        self.sample_rate = int(sample_rate)
        self.voices: List[Voice] = [Voice(sample_rate) for _ in range(int(voice_count))]
        self.glide_samples = int(glide_ms * sample_rate / 1000.0)
        self.serial = 0
        self.master = 1.0

    # ---- voice allocation -------------------------------------------------
    def note_on(self, track: int, note: int, velocity: int = 100,
                timbre: int = TIMBRE_SAW) -> int:
        for voice in self.voices:
            if not voice.active:
                return self._assign(voice, track, note, velocity, timbre)
        # Steal the oldest voice on the same track, else the oldest overall.
        same_track = [voice for voice in self.voices if voice.track == track]
        pool = same_track or self.voices
        victim = min(pool, key=lambda item: item.serial)
        return self._assign(victim, track, note, velocity, timbre)

    def _assign(self, voice: Voice, track: int, note: int, velocity: int, timbre: int) -> int:
        voice.track = int(track)
        voice.start(note, velocity, timbre, self.glide_samples, self.sample_rate)
        self.serial += 1
        voice.serial = self.serial
        return self.voices.index(voice)

    def note_off(self, track: int, note: int) -> int:
        released = 0
        for voice in self.voices:
            if voice.active and voice.track == track and voice.note == note:
                voice.stop()
                released += 1
        return released

    def all_notes_off(self) -> None:
        for voice in self.voices:
            voice.stop()

    # ---- rendering --------------------------------------------------------
    def render(self, count: int) -> List[int]:
        out: List[int] = []
        for _ in range(count):
            accumulator = 0
            for voice in self.voices:
                if voice.active:
                    accumulator += voice._next_sample()
            # Six bits of headroom for thirty two voices, then saturate.
            sample = accumulator >> 2
            if sample > 32767:
                sample = 32767
            elif sample < -32768:
                sample = -32768
            out.append(int(sample))
        return out

    def active_voices(self) -> int:
        return sum(1 for voice in self.voices if voice.active)

    def state(self) -> List[Dict[str, int]]:
        return [{"active": int(voice.active), "track": voice.track, "note": voice.note,
                 "velocity": voice.velocity, "phase": voice.phase[0],
                 "increment": voice.increment, "envelope": voice.envelope.level}
                for voice in self.voices]
