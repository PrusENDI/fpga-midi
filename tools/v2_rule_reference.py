"""Reference rules for the V2 live note engine and six-track recorder.

The model deliberately keeps the rule engines separate.  It is used by the
small RTL benches and is also useful when generating host-side golden vectors.
"""
from __future__ import annotations
from dataclasses import dataclass
from typing import List, Optional

EVENT_NONE = 0
EVENT_NOTE_ON = 1
EVENT_NOTE_OFF = 2
EVENT_NOTE_REVOICE = 3
EVENT_CONTROL = 4

FLAG_TOUCH = 0x01
FLAG_BOW = 0x02
FLAG_Z = 0x04
FLAG_REBASED = 0x08
FLAG_FAULT = 0x80

FAULT_NONE = 0
FAULT_INVALID = 1
FAULT_REVERSE = 2
FAULT_FIFO = 3
FAULT_TICK = 4
FAULT_OVERFLOW = 5
FAULT_ABORT = 6


@dataclass(frozen=True)
class Event:
    type: int
    track: int = 0
    tick: int = 0
    duration: int = 0
    note: int = 0
    velocity: int = 0
    pitch_mod: int = 0
    timbre_mod: int = 0
    flags: int = 0
    sequence: int = 0


@dataclass(frozen=True)
class LiveFrame:
    x: int
    y: int = 0
    z: int = 0
    tick: int = 0
    valid: bool = True
    degraded: bool = False
    gap: bool = False
    rebased: bool = False
    left_edge: bool = False
    touch: bool = False
    bow: bool = True
    velocity: int = 96
    brightness: int = 0
    gain: int = 0


class LiveRuleEngine:
    """Causal live rules with a one-frame event output.

    ``gate_source`` is ``"bow"`` by default; ``"touch"`` selects the touch
    electrode as the gate.  Invalid, gap, degraded and rebase frames are
    diagnostic only and never create a note event.
    """
    def __init__(self, *, track: int = 0, note_min: int = 24, note_max: int = 96,
                 x_edge: int = 2048, hysteresis: int = 1024,
                 min_event_ticks: int = 4, gate_source: str = "bow") -> None:
        self.track, self.note_min, self.note_max = track, note_min, note_max
        self.x_edge, self.hysteresis = x_edge, max(0, hysteresis)
        self.min_event_ticks, self.gate_source = max(0, min_event_ticks), gate_source
        self.armed = False
        self.edge_pending = False
        self.active = False
        self.note: Optional[int] = None
        self.prev_x: Optional[int] = None
        self.prev_z: Optional[int] = None
        self.last_tick: Optional[int] = None
        self.sequence = 0
        self.event_count = 0
        self.fault_code = FAULT_NONE
        self.gate_state = False

    def _note(self, x: int) -> int:
        x = max(0, min(65535, int(x)))
        span = self.note_max - self.note_min
        return max(0, min(127, self.note_min + (x * span // 65535)))

    def _due(self, tick: int) -> bool:
        return self.last_tick is None or ((int(tick) - self.last_tick) & 0xFFFFFFFF) >= self.min_event_ticks

    def _note_change_ok(self, y: int, candidate: int) -> bool:
        if not self.active or self.note is None or candidate == self.note:
            return True
        span = max(1, self.note_max - self.note_min)
        boundary = (self.note - self.note_min + (1 if candidate > self.note else 0)) * 65535 // span
        return int(y) >= boundary + self.hysteresis if candidate > self.note else int(y) + self.hysteresis <= boundary

    def _emit(self, typ: int, f: LiveFrame, note: int = 0, flags: int = 0) -> Event:
        velocity = max(0, min(255, int(f.velocity)))
        e = Event(typ, self.track, int(f.tick) & 0xFF, 0, note & 0xFF, velocity,
                  0, max(0, min(65535, int(f.brightness))), flags,
                  self.sequence & 0xFFFF)
        self.sequence = (self.sequence + 1) & 0xFFFF
        self.event_count += 1
        self.last_tick = int(f.tick) & 0xFFFFFFFF
        return e

    def push(self, frame: LiveFrame) -> List[Event]:
        """Consume one frame and return zero or one V2 events."""
        gate = bool(frame.touch if self.gate_source == "touch" else frame.bow)
        self.gate_state = gate
        bad = not frame.valid or frame.degraded or frame.gap or frame.rebased
        if bad:
            self.fault_code = FAULT_INVALID
            return []
        x = int(frame.x)
        if not self.armed:
            # Edge observation arms only after a final rightward confirmation.
            reverse = self.prev_x is not None and x < self.prev_x
            if not self.edge_pending and (frame.left_edge or x <= self.x_edge):
                if reverse:
                    self.fault_code = FAULT_REVERSE
                else:
                    self.edge_pending = True
            elif self.edge_pending:
                if x > self.x_edge and not reverse:
                    self.armed = True
                    self.edge_pending = False
                elif reverse:
                    self.edge_pending = False
                    self.fault_code = FAULT_REVERSE
        candidate = self._note(frame.y)
        edge_cross = self.prev_x is not None and ((self.prev_x <= self.x_edge < x) or
                                                  (self.prev_x > self.x_edge >= x))
        out: List[Event] = []
        if not self.active and self.armed and gate and self._due(frame.tick):
            self.active, self.note = True, candidate
            flags = FLAG_TOUCH if frame.touch else FLAG_BOW
            out.append(self._emit(EVENT_NOTE_ON, frame, candidate, flags))
        elif self.active and not gate and self._due(frame.tick):
            old = self.note or candidate
            self.active = False
            out.append(self._emit(EVENT_NOTE_OFF, frame, old, 0))
        elif self.active and gate and self.note is not None and candidate != self.note and self._note_change_ok(frame.y, candidate) and self._due(frame.tick):
            self.note = candidate
            out.append(self._emit(EVENT_NOTE_REVOICE, frame, candidate, FLAG_TOUCH if frame.touch else FLAG_BOW))
        elif self.active and gate and edge_cross and self.note == candidate and self._due(frame.tick):
            out.append(self._emit(EVENT_NOTE_REVOICE, frame, candidate,
                                   (FLAG_TOUCH if frame.touch else FLAG_BOW) | FLAG_REBASED))
        elif self.prev_z is not None and int(frame.z) != self.prev_z:
            # Z is expression only.  It can never be accompanied by a note event.
            flags = FLAG_Z | (FLAG_TOUCH if frame.touch else FLAG_BOW)
            out.append(self._emit(EVENT_CONTROL, frame, self.note or candidate, flags))
        self.prev_x, self.prev_z = x, int(frame.z)
        return out


class LoopEventRecorder:
    """Six independent track stores with monotonic tick and bounded capacity."""
    def __init__(self, *, depth: int = 64, tracks: int = 6) -> None:
        self.depth, self.tracks = int(depth), int(tracks)
        self.events: List[List[Event]] = [[] for _ in range(tracks)]
        self.recording = False
        self.fault_code = FAULT_NONE
        self.event_count = 0
        self.last_tick: Optional[int] = None
        self.left_edge_armed = False
        self.gate_state = False

    def start(self) -> None:
        self.events = [[] for _ in range(self.tracks)]
        self.recording, self.fault_code, self.event_count = True, FAULT_NONE, 0
        self.last_tick = None

    def stop(self) -> None:
        self.recording = False

    def abort(self) -> None:
        self.recording = False
        self.fault_code = FAULT_ABORT

    def push(self, event: Event, *, tick: Optional[int] = None) -> bool:
        if not self.recording:
            return False
        track = int(event.track)
        if track < 0 or track >= self.tracks:
            self.fault_code = FAULT_OVERFLOW
            return False
        t = int(event.tick if tick is None else tick) & 0xFFFFFFFF
        if self.last_tick is not None and t < self.last_tick:
            self.fault_code = FAULT_TICK
            return False
        if len(self.events[track]) >= self.depth:
            self.fault_code = FAULT_OVERFLOW
            return False
        self.events[track].append(Event(event.type, track, t & 0xFF, event.duration,
                                        event.note, event.velocity, event.pitch_mod,
                                        event.timbre_mod, event.flags, event.sequence))
        self.last_tick = t
        self.event_count += 1
        self.left_edge_armed = True
        self.gate_state = bool(event.flags & (FLAG_TOUCH | FLAG_BOW))
        return True

    def read(self, track: int, index: int) -> Event:
        return self.events[int(track)][int(index)]


__all__ = [name for name in globals() if not name.startswith("_")]
