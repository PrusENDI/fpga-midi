"""Dependency-free Capture & Loop compiler for the MGC3130 PC prototype.

The Lead path is deliberately small and explainable. Timestamps define the
phrase order, a fixed calibrated three-dimensional workspace defines pitch,
and geometric landmarks define where notes may start. Other tracks retain
their independent Touch/Tap recording semantics.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import wave
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, MutableMapping, Sequence, Tuple

try:
    from .host_xyz_filter import (FilteredCapture, HostCalibrationProfile, capture_order,
                                  filter_capture, valid_flag)
except ImportError:  # direct script execution
    from host_xyz_filter import (FilteredCapture, HostCalibrationProfile, capture_order,
                                 filter_capture, valid_flag)

TRACKS = ("lead", "bass", "pad", "arp", "drums", "texture_fx")
PENTATONIC = (0, 2, 4, 7, 9)


@dataclass(frozen=True)
class SynthwaveStyle:
    name: str = "melodic_synthwave"
    bpm: int = 100
    loop_bars: int = 8
    ticks_per_bar: int = 16
    swing: float = 0.50
    harmony: tuple = ("Am", "F", "C", "G")
    scale: str = "A_minor_pentatonic"
    delay_ms: int = 600
    reverb: str = "large"

    @property
    def loop_ticks(self) -> int:
        return self.loop_bars * self.ticks_per_bar

    @property
    def loop_ms(self) -> float:
        return 60000.0 * 4.0 * self.loop_bars / self.bpm


@dataclass(frozen=True)
class CalibrationProfile:
    name: str = "mgc3130_workspace_v1"
    offset: tuple = (0.0, 0.0, 0.0)
    rotation: tuple = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))
    scale: tuple = (1.0 / 65535.0, 1.0 / 65535.0, 1.0 / 65535.0)
    q_ref: tuple = (0.0, 0.0, 0.0)
    workspace_min: tuple = (0.0, 0.0, 0.0)
    workspace_max: tuple = (1.0, 1.0, 1.0)
    pitch_axis: tuple = (0.0, 1.0, 0.0)
    color_axis: tuple = (0.0, 0.0, 1.0)
    horizontal_axis: tuple = (1.0, 0.0, 0.0)
    position_valid_required: bool = True


@dataclass(frozen=True)
class PitchSpace:
    name: str = "a_minor_pentatonic_g3_c5"
    scale_name: str = "A_minor_pentatonic"
    min_midi: int = 55
    max_midi: int = 72
    center_midi: int = 64
    register_lock: bool = True
    pitch_axis: tuple = (0.0, 1.0, 0.0)
    hysteresis: float = 0.10
    # Pitch classes of the scale, semitones above C. Everything downstream reads
    # this field, so changing the scale is a configuration change, not a code
    # change.
    scale_pitch_classes: tuple = PENTATONIC

    @property
    def scale_pitches(self) -> tuple[int, ...]:
        return tuple(n for n in range(self.min_midi, self.max_midi + 1)
                     if n % 12 in self.scale_pitch_classes)


@dataclass(frozen=True)
class LeadPatchProfile:
    name: str = "neon_ambient_lead_v1"
    voice_mode: str = "mono_legato"
    oscillator: str = "saw_pulse"
    attack_ms: int = 35
    decay_ms: int = 180
    sustain: float = 0.72
    release_ms: int = 520
    glide_ms: int = 85
    vibrato_hz: float = 4.2
    vibrato_cents: float = 11.0
    cutoff_hz: float = 1800.0
    cutoff_lfo_hz: float = 0.08
    delay_ms: int = 620
    delay_feedback: float = 0.30
    reverb_send: float = 0.28


STYLE = SynthwaveStyle()
DEFAULT_CALIBRATION = CalibrationProfile()
DEFAULT_PITCH_SPACE = PitchSpace()
DEFAULT_LEAD_PATCH = LeadPatchProfile()

# Lead phrases are deliberately left-to-right open paths.  The edge zone is
# wide enough to absorb hand placement jitter, while the release distance
# prevents a stationary or leftward edge gesture from starting a phrase.
LEAD_LEFT_EDGE_MAX = 4096.0 / 65535.0
LEAD_MIN_RIGHTWARD_DELTA = 256.0 / 65535.0


def _number(value: object, default: int = 0) -> int:
    try:
        text = str(value).strip()
        return int(text, 0) if text.lower().startswith("0x") else int(float(text))
    except (TypeError, ValueError):
        return default


def load_jsonl_records(path: Path | str) -> List[Dict[str, object]]:
    records: List[Dict[str, object]] = []
    with Path(path).open(encoding="utf-8-sig") as handle:
        for line in handle:
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(value, dict) or value.get("type") != "position":
                continue
            value = dict(value)
            value["timestamp_ms"] = float(value.get("timestamp_ms", len(records)))
            value["x"] = _number(value.get("x"))
            value["y"] = _number(value.get("y"))
            value["z"] = _number(value.get("z"))
            value["touch_flags"] = _number(value.get("touch_flags"))
            value["tap_flags"] = _number(value.get("tap_flags"))
            value["gesture"] = _number(value.get("gesture"))
            records.append(value)
    return _capture_order(records)


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def _dot(a: Sequence[float], b: Sequence[float]) -> float:
    return sum(float(x) * float(y) for x, y in zip(a, b))


def _median(values: Sequence[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2.0


# Cursor calibration shared by the UI preview and the compiler, so the drawn
# curve and the compiled pitch can never disagree.
#
# Axis scale: a square traced on the sensor gave sum|dx| = 207761 against
# sum|dy| = 134631, so the Y axis reports 0.648 counts per X count for the same
# physical distance. Dividing dy by that ratio makes a square hand movement
# draw a square (tablet-like and isotropic). Re-measure before changing it.
CURSOR_AXIS_SCALE = (1.0, 1.0 / 0.648)
#
# Lift thresholds. 24 percent of the captured frames sit above 20000, so the
# old release point fired during normal playing; 30000/36000 leaves ordinary
# gesture below the band and keeps the lift deliberate.
CURSOR_Z_ENGAGE = 30000.0
CURSOR_Z_RELEASE = 36000.0


def _profile_hash(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), default=list).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()[:16]


def _sample_timestamp(sample: Mapping[str, object], fallback: float) -> float:
    raw = sample.get("timestamp_ms", sample.get("timestamp", fallback))
    try:
        return float(raw)
    except (TypeError, ValueError):
        return fallback


def _capture_order(samples: Sequence[Mapping[str, object]]) -> List[Dict[str, object]]:
    return capture_order(samples, key=lambda row: _sample_timestamp(row, 0.0))


def _phrase_window(samples: Sequence[Mapping[str, object]]) -> Tuple[float, float]:
    """Time window of the phrase itself, excluding the left-edge pre-roll.

    The start gate accepts the edge frame retroactively, so everything before
    it is capture diagnostics. Letting those frames own the beginning of the
    loop compressed the real phrase into whatever was left: a five second wait
    before drawing cost about 33 of the 128 ticks. Rows without a gate state
    fall back to the full capture so non-Lead callers keep their behaviour.
    """
    ordered = _capture_order(samples)
    if not ordered:
        return 0.0, 0.0
    accepted = [row for row in ordered if row.get("start_gate_state") == "accepted"]
    window = accepted or ordered
    start = _sample_timestamp(window[0], 0.0)
    end = _sample_timestamp(window[-1], start)
    return start, (end if end > start else start + 1.0)


def _cross(a: Sequence[float], b: Sequence[float]) -> tuple[float, float, float]:
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _unit(vector: Sequence[float]) -> tuple[float, float, float] | None:
    length = math.sqrt(_dot(vector, vector))
    if length < 1e-9:
        return None
    return tuple(float(value) / length for value in vector)  # type: ignore[return-value]


def _gesture_axes(rows: Sequence[Mapping[str, object]], calibration: CalibrationProfile) -> tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float], str | None]:
    """Return a stable open-path frame without moving the fixed pitch origin."""
    if len(rows) < 2:
        return calibration.horizontal_axis, calibration.pitch_axis, calibration.color_axis, "insufficient_endpoints"
    q0 = tuple(float(rows[0]["q_app"][i]) for i in range(3))
    q1 = tuple(float(rows[-1]["q_app"][i]) for i in range(3))
    e = _unit(tuple(q1[i] - q0[i] for i in range(3)))
    if e is None:
        return calibration.horizontal_axis, calibration.pitch_axis, calibration.color_axis, "degenerate_endpoint_vector"
    up = calibration.pitch_axis
    projected = tuple(up[i] - _dot(up, e) * e[i] for i in range(3))
    p = _unit(projected)
    if p is None:
        return calibration.horizontal_axis, calibration.pitch_axis, calibration.color_axis, "endpoint_parallel_to_pitch_axis"
    d = _unit(_cross(e, p))
    if d is None:
        return calibration.horizontal_axis, calibration.pitch_axis, calibration.color_axis, "degenerate_path_frame"
    return e, p, d, None


def _looks_absent(sample: Mapping[str, object]) -> bool:
    """Detect a report that carries no hand position.

    Two signatures are known. Without a hand the device reports
    x=65535, y=0, z=65535; right after the stream opens it also reports
    x=0, y=0 before the first real measurement. Both are indistinguishable
    from a real pose once the envelope is dropped, and the second one used to
    become a fourteen tick note at the bottom of the range at the start of
    every take.
    """
    try:
        x = float(sample.get("x", 0))
        y = float(sample.get("y", 0))
    except (TypeError, ValueError):
        return False
    if x <= 5.0 and y <= 5.0:
        return True
    return x >= 65530.0 and y <= 5.0


def project_sample(sample: Mapping[str, object], calibration: CalibrationProfile = DEFAULT_CALIBRATION,
                   mode: str = "workspace") -> Dict[str, object]:
    raw = tuple(float(_number(sample.get(axis), 0)) for axis in ("x", "y", "z"))
    centered = tuple(raw[i] - calibration.offset[i] for i in range(3))
    rotated = tuple(_dot(calibration.rotation[i], centered) for i in range(3))
    q = tuple(rotated[i] * calibration.scale[i] for i in range(3))
    relative = tuple(q[i] - calibration.q_ref[i] for i in range(3))
    outside = any(q[i] < calibration.workspace_min[i] or q[i] > calibration.workspace_max[i] for i in range(3))
    result: Dict[str, object] = dict(sample)
    result.update({
        "timestamp_ms": _sample_timestamp(sample, 0.0),
        "x_raw": raw[0], "y_raw": raw[1], "z_raw": raw[2], "q_app": q,
        "q_x": q[0], "q_y": q[1], "q_z": q[2],
        "position_valid": valid_flag(sample.get("position_valid", sample.get("positionValid")))
                          and not _looks_absent(sample),
        "out_of_range": bool(outside), "calibration_mode": mode, "a_rel": 0.0,
        "b_abs": _dot(relative, calibration.pitch_axis),
        "c_abs": _dot(relative, calibration.color_axis),
    })
    return result


def _apply_lead_start_gate(projected: Sequence[Mapping[str, object]], *,
                           left_edge_max: float = LEAD_LEFT_EDGE_MAX,
                           min_rightward_delta: float = LEAD_MIN_RIGHTWARD_DELTA) -> List[Dict[str, object]]:
    """Accept only a left-edge point followed by confirmed rightward motion.

    Before the gate opens, rows remain in the capture for diagnostics but are
    marked invalid so resampling turns them into explicit rests.  The latest
    edge candidate is retroactively marked as the phrase start when a later
    valid point moves sufficiently to the right.
    """
    rows = [dict(row) for row in projected]
    candidate_index: int | None = None
    candidate_x: float | None = None
    departure_index: int | None = None
    departure_x: float | None = None
    gate_open = False
    for index, row in enumerate(rows):
        valid = valid_flag(row.get("position_valid")) and row.get("q_app") is not None
        q = row.get("q_app")
        # Gate on the raw sensor X. Median/low-pass filtering can smear a
        # genuine edge contact far into the workspace before this decision.
        raw_x = row.get("x_raw", row.get("x"))
        try:
            x = float(raw_x) / 65535.0 if valid and raw_x is not None else None
        except (TypeError, ValueError):
            x = float(q[0]) if valid and isinstance(q, (tuple, list)) else None
        row["start_gate_state"] = "accepted" if gate_open else "prestart"
        row["start_gate_reason"] = "gate_already_open" if gate_open else "awaiting_left_edge"
        if not valid:
            row["position_valid"] = False
            continue
        if gate_open:
            continue
        if x is not None and x <= left_edge_max:
            candidate_index = index
            candidate_x = x
            departure_index = None
            departure_x = None
            row["start_gate_state"] = "edge_candidate"
            row["start_gate_reason"] = "left_edge_candidate"
            row["position_valid"] = False
            continue
        if candidate_index is not None and candidate_x is not None and x is not None:
            if departure_index is None:
                if x - candidate_x >= min_rightward_delta:
                    departure_index = index
                    departure_x = x
                    row["position_valid"] = False
                    row["start_gate_state"] = "prestart"
                    row["start_gate_reason"] = "rightward_confirmation_pending"
                else:
                    row["position_valid"] = False
                    row["start_gate_state"] = "prestart"
                    row["start_gate_reason"] = "waiting_rightward_confirmation"
                continue
            if departure_x is not None and x > departure_x:
                gate_open = True
                start = rows[candidate_index]
                start["position_valid"] = True
                start["start_gate_state"] = "accepted"
                start["start_gate_reason"] = "left_edge_release_rightward"
                for prior in rows[candidate_index + 1:index]:
                    prior["position_valid"] = False
                    prior["start_gate_state"] = "prestart"
                    prior["start_gate_reason"] = "edge_release_confirmation"
                rows[departure_index]["start_gate_state"] = "accepted"
                rows[departure_index]["start_gate_reason"] = "rightward_confirmation"
                rows[departure_index]["position_valid"] = True
                row["start_gate_state"] = "accepted"
                row["start_gate_reason"] = "rightward_confirmation"
            else:
                row["position_valid"] = False
                row["start_gate_state"] = "prestart"
                row["start_gate_reason"] = "rightward_confirmation_pending"
        else:
            row["position_valid"] = False
            row["start_gate_state"] = "prestart"
            row["start_gate_reason"] = "left_edge_required"
    return rows


class LeadStartGate:
    """Streaming form of the left-edge Lead start rule used by the UI."""

    def __init__(self, *, left_edge_max: float = LEAD_LEFT_EDGE_MAX,
                 min_rightward_delta: float = LEAD_MIN_RIGHTWARD_DELTA) -> None:
        self.left_edge_max = float(left_edge_max)
        self.min_rightward_delta = float(min_rightward_delta)
        self._candidate: Dict[str, object] | None = None
        self._candidate_x: float | None = None
        self._departure: Dict[str, object] | None = None
        self._departure_x: float | None = None
        self._open = False

    def push(self, record: Mapping[str, object]) -> List[Dict[str, object]]:
        row = dict(record)
        try:
            x = _number(row.get("x"), 0) / 65535.0
        except (TypeError, ValueError):
            x = 0.0
        valid = valid_flag(row.get("position_valid", row.get("positionValid")))
        if self._open:
            row.update({"start_gate_state": "accepted", "start_gate_reason": "gate_already_open"})
            return [row] if valid else []
        if not valid:
            row.update({"start_gate_state": "prestart", "start_gate_reason": "invalid_before_start"})
            return []
        if x <= self.left_edge_max:
            self._candidate = row
            self._candidate_x = x
            self._departure = None
            self._departure_x = None
            row.update({"start_gate_state": "edge_candidate", "start_gate_reason": "left_edge_candidate"})
            return []
        if self._candidate is None or self._candidate_x is None:
            row.update({"start_gate_state": "prestart", "start_gate_reason": "left_edge_required"})
            return []
        if self._departure is None:
            if x - self._candidate_x < self.min_rightward_delta:
                row.update({"start_gate_state": "prestart", "start_gate_reason": "waiting_rightward_confirmation"})
                return []
            self._departure = row
            self._departure_x = x
            row.update({"start_gate_state": "prestart", "start_gate_reason": "waiting_rightward_confirmation"})
            return []
        if self._departure_x is not None and x <= self._departure_x:
            row.update({"start_gate_state": "prestart", "start_gate_reason": "rightward_confirmation_pending"})
            return []
        start = dict(self._candidate)
        start.update({"start_gate_state": "accepted", "start_gate_reason": "left_edge_release_rightward"})
        departure = dict(self._departure)
        departure.update({"start_gate_state": "accepted", "start_gate_reason": "rightward_confirmation"})
        row.update({"start_gate_state": "accepted", "start_gate_reason": "rightward_confirmation"})
        self._open = True
        self._candidate = None
        self._candidate_x = None
        self._departure = None
        self._departure_x = None
        return [start, departure, row]


def make_cursor():
    """Build the cursor selected by CURSOR_MODE.

    The UI preview and the compiler both call this, so the drawn curve and the
    compiled pitch can never be built from different cursor models.
    """
    return AbsoluteCursor() if CURSOR_MODE == "absolute" else RelativeCursor()


def _apply_cursor_layer(rows: List[Dict[str, object]], pitch_source: str = "cursor") -> List[Dict[str, object]]:
    """Run the cursor over filtered frames and mark the phrase.

    In cursor mode the phrase starts at the first engaged frame and stops
    producing evidence while the hand is lifted. With the absolute cursor the
    re-engage frame snaps to the hand; it is flagged ``rebased`` and marked
    invalid so the catch-up cannot be read as a turn.
    """
    cursor = make_cursor()
    started = False
    for row in rows:
        q = row.get("q_app")
        if not row.get("position_valid", True) or q is None:
            row["start_gate_state"] = "accepted" if started else "prestart"
            row["cursor_x"] = row.get("cursor_x")
            row["cursor_y"] = row.get("cursor_y")
            row["cursor_engaged"] = cursor.engaged
            row["cursor_lift"] = started and not cursor.engaged
            continue
        touching = bool(row.get("touch_flags") or 0)
        point, gain = cursor.push((float(q[0]) * 65535.0, float(q[1]) * 65535.0),
                                  float(q[2]) * 65535.0, touching=touching)
        rebased = bool(getattr(cursor, "rebased", False))
        row["cursor_x"], row["cursor_y"] = point
        row["cursor_gain"] = gain
        row["cursor_engaged"] = cursor.engaged
        row["cursor_rebased"] = rebased
        row["cursor_touch"] = touching
        # A lift is the operator letting go; a rebase is the hand returning to
        # a new place. Both are silent frames, but neither is a musical rest.
        row["cursor_lift"] = started and (not cursor.engaged or rebased)
        if cursor.engaged and not started:
            started = True
        row["start_gate_state"] = "accepted" if started else "prestart"
        if not started or not cursor.engaged or rebased:
            row["position_valid"] = False
        if pitch_source == "cursor":
            row["b_abs"] = point[1]
    return rows


def preprocess_samples(samples: Sequence[Mapping[str, object]],
                       calibration: CalibrationProfile = DEFAULT_CALIBRATION,
                       mode: str = "workspace",
                       host_profile: HostCalibrationProfile | None = None,
                       _filtered_capture: FilteredCapture | None = None,
                       pitch_source: str = "absolute") -> List[Dict[str, object]]:
    if host_profile is not None:
        filtered_capture = _filtered_capture or filter_capture(samples, host_profile)
        projected: List[Dict[str, object]] = []
        for frame in filtered_capture.frames:
            row = dict(frame)
            q = frame.get("q_filtered")
            if q is None:
                row.update({"q_app": None, "q_x": None, "q_y": None, "q_z": None,
                            "position_valid": False, "out_of_range": False})
                projected.append(row)
                continue
            q_tuple = tuple(float(value) for value in q)
            b_raw = float(frame.get("b_abs", 0.0))
            c_raw = float(frame.get("c_abs", 0.0))
            b_norm = _clamp((b_raw - host_profile.b_min) / max(1e-9, host_profile.b_max - host_profile.b_min), 0.0, 1.0)
            c_norm = _clamp(c_raw, 0.0, 1.0)
            row.update({
                "q_app": q_tuple, "q_x": q_tuple[0], "q_y": q_tuple[1], "q_z": q_tuple[2],
                "b_abs_raw": b_raw, "c_abs_raw": c_raw,
                "b_abs": b_norm, "c_abs": c_norm,
                "position_valid": True,
                "out_of_range": any(q_tuple[i] < host_profile.workspace_min[i] or q_tuple[i] > host_profile.workspace_max[i] for i in range(3)),
            })
            projected.append(row)
        projected = _capture_order(projected)
        projected = _apply_lead_start_gate(projected)
        if pitch_source == "cursor":
            projected = _apply_cursor_layer(projected, pitch_source)
        if not projected:
            return []
        start, end = _phrase_window(projected)
        span = max(1e-9, end - start)
        for row in projected:
            row["a_rel"] = _clamp((float(row.get("timestamp_ms", start)) - start) / span, 0.0, 1.0)
        return projected
    projected = [project_sample(sample, calibration, mode) for sample in _capture_order(samples)]
    if not projected:
        return []
    coords = [[float(row["q_app"][axis]) for row in projected] for axis in range(3)]
    filtered = [[0.0] * len(projected) for _ in range(3)]
    for axis in range(3):
        for i in range(len(projected)):
            lo, hi = max(0, i - 2), min(len(projected), i + 3)
            window = coords[axis][lo:hi]
            med = _median(window)
            mad = _median([abs(value - med) for value in window])
            value = coords[axis][i]
            filtered[axis][i] = med if abs(value - med) > max(0.035, 6.0 * mad) else value
        previous = filtered[axis][0]
        for i, value in enumerate(filtered[axis]):
            previous = value if i == 0 else previous + 0.35 * (value - previous)
            filtered[axis][i] = previous
    active_axes = (calibration.horizontal_axis, calibration.pitch_axis, calibration.color_axis)
    alignment_fallback = None
    if mode == "gesture_aligned":
        active_axes = _gesture_axes(projected, calibration)[:3]
        alignment_fallback = _gesture_axes(projected, calibration)[3]
        if alignment_fallback:
            active_axes = (calibration.horizontal_axis, calibration.pitch_axis, calibration.color_axis)
    output: List[Dict[str, object]] = []
    for i, row in enumerate(projected):
        q = tuple(filtered[axis][i] for axis in range(3))
        relative = tuple(q[axis] - calibration.q_ref[axis] for axis in range(3))
        updated = dict(row)
        updated.update({
            "q_app": q, "q_x": q[0], "q_y": q[1], "q_z": q[2],
            "a_rel": 0.0,
            "b_abs": _dot(relative, active_axes[1]),
            "c_abs": _dot(relative, active_axes[2]),
            "a_path": _dot(tuple(q[axis] - calibration.q_ref[axis] for axis in range(3)), active_axes[0]),
            "alignment_fallback": alignment_fallback,
        })
        output.append(updated)
    # Gate first: the phrase clock starts at the frame the gate confirmed, so
    # the pre-roll cannot claim the beginning of the loop. a_rel is filled in
    # afterwards against that window.
    if pitch_source == "cursor":
        output = _apply_cursor_layer(output, pitch_source)
    else:
        output = _apply_lead_start_gate(output)
    start, end = _phrase_window(output)
    span = max(1e-9, end - start)
    for row in output:
        row["a_rel"] = _clamp((float(row["timestamp_ms"]) - start) / span, 0.0, 1.0)
    return output


def _interp(a: float, b: float, ratio: float) -> float:
    return a + (b - a) * ratio


# Absolute (tablet) mapping. The calibrated rectangle maps edge to edge onto
# the cursor square. The Y range is narrower than X because a square traced on
# the sensor produced sum|dx| 207761 against sum|dy| 134631 (ratio 0.648), so
# the same physical height spans fewer counts; using 0.648 of the X span keeps
# a square hand movement drawing a square while both edges still reach 0 and 1.
CURSOR_MODE = "absolute"
CURSOR_X_RANGE = (0.0, 65535.0)
CURSOR_Y_RANGE = (32768.0 - 65535.0 * 0.648 / 2.0, 32768.0 + 65535.0 * 0.648 / 2.0)
CURSOR_ALPHA_LOW = 1.0
CURSOR_ALPHA_HIGH = 0.12


class AbsoluteCursor:
    """Tablet-like mapping: the sensor rectangle fills the cursor square.

    Z does not scale displacement, because that would break the edge-to-edge
    correspondence. It scales the follow rate instead: a resting hand sits
    exactly under the pointer, while a raised hand damps fast movement and
    leaves fine control. Re-engaging after a lift snaps to the hand on a
    single frame flagged ``rebased``, which the compiler marks invalid so the
    catch-up cannot be read as a turn.
    """

    def __init__(self, x_range: Tuple[float, float] = CURSOR_X_RANGE,
                 y_range: Tuple[float, float] = CURSOR_Y_RANGE,
                 alpha_low: float = CURSOR_ALPHA_LOW, alpha_high: float = CURSOR_ALPHA_HIGH,
                 z_low: float = 4000.0, z_high: float = 24000.0,
                 z_engage: float = CURSOR_Z_ENGAGE, z_release: float = CURSOR_Z_RELEASE,
                 start: Tuple[float, float] = (0.5, 0.5),
                 settle_frames: int = 20, alpha_settle: float = 0.25) -> None:
        self.x_range = (float(x_range[0]), float(x_range[1]))
        self.y_range = (float(y_range[0]), float(y_range[1]))
        self.alpha_low = float(alpha_low)
        self.alpha_high = float(alpha_high)
        self.z_low = float(z_low)
        self.z_high = float(z_high)
        self.z_engage = float(z_engage)
        self.z_release = float(z_release)
        self.settle_frames = int(settle_frames)
        self.history: List[Tuple[float, float]] = []
        self.alpha_settle = float(alpha_settle)
        self.cursor: Tuple[float, float] = (float(start[0]), float(start[1]))
        self.engaged = True
        self.touching = False
        self.settle = 0
        self.rebased = False

    def update_engagement(self, z: float) -> bool:
        if self.engaged:
            if float(z) > self.z_release:
                self.engaged = False
        elif float(z) < self.z_engage:
            self.engaged = True
        return self.engaged

    def alpha_at(self, z: float) -> float:
        span = max(1e-9, self.z_high - self.z_low)
        z_norm = (float(z) - self.z_low) / span
        z_norm = 0.0 if z_norm < 0.0 else (1.0 if z_norm > 1.0 else z_norm)
        return self.alpha_low - (self.alpha_low - self.alpha_high) * z_norm

    def target(self, q: Sequence[float]) -> Tuple[float, float]:
        x_lo, x_hi = self.x_range
        y_lo, y_hi = self.y_range
        return (_clamp((float(q[0]) - x_lo) / max(1e-9, x_hi - x_lo), 0.0, 1.0),
                _clamp((float(q[1]) - y_lo) / max(1e-9, y_hi - y_lo), 0.0, 1.0))

    def push(self, q: Sequence[float], z: float, engaged: bool | None = None,
             touching: bool = False) -> Tuple[Tuple[float, float], float]:
        was_engaged = self.engaged
        active = self.update_engagement(z) if engaged is None else bool(engaged)
        self.rebased = False
        if touching:
            if not self.touching:
                # The centroid is dragged towards the false position for about
                # four frames before the touch flag rises (measured: 18043 to
                # 10509 between frames 817 and 822). Roll the cursor back to
                # where it sat before that approach, otherwise every tap drags
                # it out and the repeated taps draw a fan.
                if self.history:
                    self.cursor = self.history[0]
                self.settle = 0
            self.touching = True
            if not active:
                self.engaged = False
            return self.cursor, self.alpha_at(z)
        if self.touching:
            # The reading stays wrong for about twenty frames after the finger
            # leaves (8452 at release, 16082 once settled), so hold through that
            # window and then snap once, instead of following the spring back.
            self.touching = False
            self.settle = int(self.settle_frames)
            self.engaged = active
        if self.settle > 0:
            self.settle -= 1
            self.engaged = active
            if self.settle > 0:
                return self.cursor, self.alpha_at(z)
            self.cursor = self.target(q)
            self.rebased = True
            return self.cursor, self.alpha_at(z)
        point = self.target(q)
        alpha = self.alpha_at(z)
        if active and not was_engaged:
            self.cursor = point
            self.rebased = True
        elif active:
            self.cursor = (self.cursor[0] + alpha * (point[0] - self.cursor[0]),
                           self.cursor[1] + alpha * (point[1] - self.cursor[1]))
        self.history.append(self.cursor)
        if len(self.history) > 6:
            self.history.pop(0)
        return self.cursor, alpha


class RelativeCursor:
    """Mouse-like cursor: integrate deltas, with height controlling the gain.

    The hand never has to reach an absolute position, so the usable area and
    the centre offset stop mattering. Raising the hand slows the cursor rather
    than causing drift: at ``z_high`` the same movement moves a quarter as far,
    which is the "fine control" gear and gives Z an expressive role. Lifting
    (``engaged=False``) discards deltas instead of accumulating them, exactly
    like picking a mouse up and putting it down elsewhere.

    The gain is a pure function of z and the whole thing is deterministic, so
    the same capture replays to the same cursor path.
    """

    def __init__(self, *, g_max: float = 1.0, g_min: float = 0.25,
                 z_low: float = 4000.0, z_high: float = 24000.0,
                 z_engage: float = CURSOR_Z_ENGAGE, z_release: float = CURSOR_Z_RELEASE,
                 axis_scale: Tuple[float, float] = CURSOR_AXIS_SCALE,
                 deadzone: float = 0.0004,
                 start: Tuple[float, float] = (0.5, 0.5)) -> None:
        self.g_max = float(g_max)
        self.g_min = float(g_min)
        self.z_low = float(z_low)
        self.z_high = float(z_high)
        self.z_engage = float(z_engage)
        self.z_release = float(z_release)
        self.axis_scale = (float(axis_scale[0]), float(axis_scale[1]))
        self.deadzone = float(deadzone)
        self.cursor: Tuple[float, float] = (float(start[0]), float(start[1]))
        self.engaged = True
        self._prev: Tuple[float, float] | None = None

    def update_engagement(self, z: float) -> bool:
        """Hysteresis: engage below z_engage, release above z_release.

        A single threshold would chatter while the hand idles at the boundary,
        and every chatter would either drop or inject a delta.
        """
        if self.engaged:
            if float(z) > self.z_release:
                self.engaged = False
        elif float(z) < self.z_engage:
            self.engaged = True
        return self.engaged

    def gain_at(self, z: float) -> float:
        span = max(1e-9, self.z_high - self.z_low)
        z_norm = (float(z) - self.z_low) / span
        z_norm = 0.0 if z_norm < 0.0 else (1.0 if z_norm > 1.0 else z_norm)
        return self.g_max - (self.g_max - self.g_min) * z_norm

    def _deadzone(self, value: float) -> float:
        if abs(value) <= self.deadzone:
            return 0.0
        return value - self.deadzone * (1.0 if value > 0.0 else -1.0)

    def push(self, q: Sequence[float], z: float, engaged: bool | None = None) -> Tuple[Tuple[float, float], float]:
        point = (float(q[0]), float(q[1]))
        gain = self.gain_at(z)
        active = self.update_engagement(z) if engaged is None else bool(engaged)
        if self._prev is None:
            self._prev = point
            return self.cursor, gain
        dx = (point[0] - self._prev[0]) * self.axis_scale[0]
        dy = (point[1] - self._prev[1]) * self.axis_scale[1]
        self._prev = point
        if active:
            x = _clamp(self.cursor[0] + gain * self._deadzone(dx), 0.0, 1.0)
            y = _clamp(self.cursor[1] + gain * self._deadzone(dy), 0.0, 1.0)
            self.cursor = (x, y)
        return self.cursor, gain

    def reset(self, start: Tuple[float, float] = (0.5, 0.5)) -> None:
        self.cursor = (float(start[0]), float(start[1]))
        self._prev = None


class StreamingLeadFilter:
    """Causal mirror of the batch filter inside preprocess_samples.

    The batch pass replaces an isolated spike using a window centred on the
    frame (i-2 .. i+2) and then runs a single-pole IIR over the axis. Emitting
    the value for frame ``i-2`` reproduces that sequence exactly with two
    frames (~10 ms at 200 Hz) of display latency, so the curve the UI draws is
    the curve the compiler consumes. Without this the operator watches raw
    sensor noise while the compiler sees a smoothed path, and cannot predict
    the result from the drawing.
    """

    WINDOW = 5
    ALPHA = 0.35
    SPIKE_FLOOR = 0.035
    SPIKE_MAD = 6.0

    def __init__(self) -> None:
        self._q: List[Tuple[float, float, float]] = []
        self._published = 0
        self._iir: List[float] | None = None

    def reset(self) -> None:
        self._q = []
        self._published = 0
        self._iir = None

    def push(self, q: Sequence[float]) -> Tuple[float, float, float] | None:
        self._q.append((float(q[0]), float(q[1]), float(q[2])))
        index = self._published
        if len(self._q) < index + 3:
            return None
        lo = max(0, index - 2)
        hi = min(len(self._q), index + 3)
        smoothed: List[float] = []
        for axis in range(3):
            window = [self._q[k][axis] for k in range(lo, hi)]
            median = _median(window)
            mad = _median([abs(value - median) for value in window])
            value = self._q[index][axis]
            smoothed.append(median if abs(value - median) > max(self.SPIKE_FLOOR, self.SPIKE_MAD * mad) else value)
        if self._iir is None:
            self._iir = list(smoothed)
        else:
            self._iir = [self._iir[axis] + self.ALPHA * (smoothed[axis] - self._iir[axis]) for axis in range(3)]
        self._published += 1
        return (self._iir[0], self._iir[1], self._iir[2])


def _annotate_ticks(result: List[Dict[str, object]]) -> List[Dict[str, object]]:
    """Derive speed, state and curvature for a tick series in place."""
    for i, row in enumerate(result):
        previous, following = result[max(0, i - 1)], result[min(len(result) - 1, i + 1)]
        if previous.get("b_abs") is None or following.get("b_abs") is None:
            row["db"], row["dc"], row["speed"] = 0.0, 0.0, 0.0
            row["curvature"], row["state"] = 0.0, "rest"
            continue
        db = float(following["b_abs"]) - float(previous["b_abs"])
        dc = float(following["c_abs"]) - float(previous["c_abs"])
        row["db"], row["dc"], row["speed"] = db, dc, math.hypot(db, dc)
        row["curvature"] = 0.0
        if not row["position_valid"]:
            row["state"] = "rest"
        elif row["speed"] < 0.002:
            row["state"] = "hold"
        else:
            row["state"] = "move"
    for i in range(1, len(result) - 1):
        result[i]["curvature"] = float(result[i + 1]["db"]) - float(result[i - 1]["db"])
    return result


def _resample_loop(rows: Sequence[Mapping[str, object]], style: SynthwaveStyle) -> List[Dict[str, object]]:
    """Map absolute time onto the tick grid and wrap at the loop end.

    One tick lasts 60/BPM/4 seconds regardless of how long the take runs, so
    playing a beat is worth the same rhythm in a five second take and a two
    minute one. Time past the loop wraps to tick zero and overwrites what the
    previous pass wrote, which is how a looper pedal behaves; ticks never
    reached stay invalid instead of being stretched to fill the bar.
    """
    if not rows:
        return []
    ticks_per_beat = max(1, style.ticks_per_bar // 4)
    ms_per_tick = 60000.0 / max(1, style.bpm) / ticks_per_beat
    loop = style.loop_ticks
    start = _sample_timestamp(rows[0], 0.0)
    table: Dict[int, Mapping[str, object]] = {}
    for row in rows:
        if row.get("b_abs") is None:
            continue
        tick = int((_sample_timestamp(row, start) - start) / ms_per_tick) % loop
        table[tick] = row  # later passes overwrite earlier ones
    result: List[Dict[str, object]] = []
    for tick in range(loop):
        row = table.get(tick)
        if row is None:
            result.append({
                "tick": tick, "a_rel": tick / max(1, loop - 1),
                "timestamp_ms": start + tick * ms_per_tick,
                "b_abs": None, "c_abs": None, "q_x": None, "q_y": None, "q_z": None,
                "position_valid": False, "out_of_range": False, "lift": False,
                "touch_flags": 0,
            })
            continue
        result.append({
            "tick": tick, "a_rel": tick / max(1, loop - 1),
            "timestamp_ms": start + tick * ms_per_tick,
            "b_abs": row.get("b_abs"), "c_abs": row.get("c_abs"),
            "q_x": row.get("q_x"), "q_y": row.get("q_y"), "q_z": row.get("q_z"),
            "cursor_x": row.get("cursor_x"), "cursor_y": row.get("cursor_y"),
            "position_valid": valid_flag(row.get("position_valid")),
            "out_of_range": bool(row.get("out_of_range", False)),
            "lift": bool(row.get("cursor_lift", False)),
            "touch_flags": int(row.get("touch_flags") or 0),
        })
    return _annotate_ticks(result)


def resample_to_ticks(samples: Sequence[Mapping[str, object]], style: SynthwaveStyle = STYLE,
                      time_map: str = "stretch") -> List[Dict[str, object]]:
    if not samples:
        return []
    ordered = _capture_order(samples)
    if time_map == "loop":
        return _resample_loop(ordered, style)
    start, end = _phrase_window(ordered)
    span = max(1e-9, end - start)
    times = [_sample_timestamp(row, start) for row in ordered]
    result: List[Dict[str, object]] = []
    cursor = 0
    for tick in range(style.loop_ticks):
        a_rel = tick / max(1, style.loop_ticks - 1)
        target = start + span * a_rel
        while cursor + 1 < len(ordered) and times[cursor + 1] < target:
            cursor += 1
        left = ordered[cursor]
        right = ordered[min(cursor + 1, len(ordered) - 1)]
        left_t, right_t = times[cursor], times[min(cursor + 1, len(ordered) - 1)]
        ratio = 0.0 if right_t <= left_t else _clamp((target - left_t) / (right_t - left_t), 0.0, 1.0)
        row: Dict[str, object] = {"tick": tick, "a_rel": a_rel, "timestamp_ms": target}
        for field in ("b_abs", "c_abs", "q_x", "q_y", "q_z", "cursor_x", "cursor_y"):
            left_value, right_value = left.get(field), right.get(field)
            left_valid = valid_flag(left.get("position_valid")) and left_value is not None
            right_valid = valid_flag(right.get("position_valid")) and right_value is not None
            if left_valid and right_valid:
                row[field] = _interp(float(left_value), float(right_value), ratio)
            elif left_value is not None:
                row[field] = float(left_value)
            elif right_value is not None:
                row[field] = float(right_value)
            else:
                row[field] = None
        row["position_valid"] = valid_flag(left.get("position_valid")) and valid_flag(right.get("position_valid")) and row.get("b_abs") is not None
        row["out_of_range"] = bool(left.get("out_of_range", False) or right.get("out_of_range", False))
        # A lifted hand is silent but is not a musical rest: keep the flag so
        # landmark extraction can tell "let go" from "bad data".
        row["lift"] = bool(left.get("cursor_lift", False) or right.get("cursor_lift", False))
        # Touch is a binary contact, not a quantity: carry the nearer sample's
        # value instead of interpolating it.
        row["touch_flags"] = int(left.get("touch_flags") or 0) if ratio < 0.5 else int(right.get("touch_flags") or 0)
        result.append(row)
    return _annotate_ticks(result)


def extract_landmarks(projected_samples: Sequence[Mapping[str, object]], style: SynthwaveStyle = STYLE) -> List[Dict[str, object]]:
    if not projected_samples:
        return []
    rows = sorted(projected_samples, key=lambda row: int(row.get("tick", 0)))
    landmarks: List[Dict[str, object]] = []

    def add(kind: str, row: Mapping[str, object], reason: str) -> None:
        tick = int(row.get("tick", 0))
        if any(int(item["tick"]) == tick and item["kind"] == kind for item in landmarks):
            return
        b_value = row.get("b_abs")
        c_value = row.get("c_abs")
        landmarks.append({
            "id": f"lm{len(landmarks):03d}", "kind": kind, "tick": tick,
            "a_rel": float(row.get("a_rel", tick / max(1, style.loop_ticks - 1))),
            # Invalid/rest frames have no spatial coordinates. Keep the
            # landmark schema numeric for the UI, while its kind/reason
            # carries the semantic fact that this is an explicit rest.
            "b_abs": float(b_value) if b_value is not None else 0.0,
            "c_abs": float(c_value) if c_value is not None else 0.0,
            "speed": float(row.get("speed", 0.0)),
            "confidence": _clamp(1.0 - float(row.get("speed", 0.0)) * 4.0, 0.2, 1.0),
            "reason": reason,
        })

    if valid_flag(rows[0].get("position_valid")) and rows[0].get("b_abs") is not None:
        add("move", rows[0], "capture_start")
    i = 0
    while i < len(rows):
        state = str(rows[i].get("state", "move"))
        j = i + 1
        while j < len(rows) and str(rows[j].get("state", "move")) == state:
            j += 1
        if state == "rest":
            if not rows[i].get("lift"):
                add("rest", rows[i], "position_invalid")
        elif state == "hold" and j - i >= 2:
            add("hold", rows[(i + j - 1) // 2], "low_velocity")
        i = j
    for index in range(1, len(rows) - 1):
        current, before, after = rows[index], rows[index - 1], rows[index + 1]
        if (not valid_flag(current.get("position_valid")) or current.get("b_abs") is None
                or before.get("b_abs") is None or after.get("b_abs") is None):
            continue
        b = float(current.get("b_abs", 0.0))
        bb, ba = float(before.get("b_abs", b)), float(after.get("b_abs", b))
        if b >= bb and b >= ba and b - min(bb, ba) > 0.012:
            add("apex", current, "local_maximum")
        elif b <= bb and b <= ba and max(bb, ba) - b > 0.012:
            add("valley", current, "local_minimum")
        db_before, db_after = b - bb, ba - b
        if abs(db_before) > 0.0015 and abs(db_after) > 0.0015 and db_before * db_after < 0:
            add("turn", current, "direction_reversal")
        if (str(current.get("state")) == "move" and str(before.get("state")) == "hold"
                and db_after < -0.0002):
            add("turn", current, "hold_to_downward_motion")
    if valid_flag(rows[-1].get("position_valid")) and rows[-1].get("state") != "rest" and int(rows[-1].get("tick", 0)) > int(rows[0].get("tick", 0)):
        add("release", rows[-1], "capture_end")
    landmarks.sort(key=lambda item: (int(item["tick"]), item["kind"]))
    for index, item in enumerate(landmarks):
        item["id"] = f"lm{index:03d}"
    return landmarks


def _nearest_scale(note: float, pitches: Sequence[int]) -> int:
    return min(pitches, key=lambda n: (abs(n - note), n))


def _quantize_hysteresis(raw: float, pitches: Sequence[int], previous: int | None, hysteresis: float) -> int:
    target = _nearest_scale(raw, pitches)
    return previous if previous in pitches and abs(raw - previous) <= hysteresis else target


def _capture_hash(samples: Sequence[Mapping[str, object]]) -> str:
    canonical = [{key: sample.get(key) for key in ("timestamp_ms", "timestamp", "x", "y", "z", "position_valid")}
                 for sample in sorted(samples, key=lambda row: _sample_timestamp(row, 0.0))]
    return _profile_hash(canonical)


def _event(track: str, tick: int, *, note: int | None = None, duration: int = 1,
           velocity: int = 80, event_type: str = "note_on", source: str = "touch_tap",
           limit: int | None = None, **fields: object) -> Dict[str, object]:
    # The clamp must use the style actually being compiled: with automatic loop
    # length the grid is longer than the module default, and clamping to it
    # folded every later note onto tick 127.
    bound = (STYLE.loop_ticks if limit is None else int(limit)) - 1
    result: Dict[str, object] = {
        "track": track, "type": event_type, "tick": int(_clamp(tick, 0, max(0, bound))),
        "duration": max(0, int(duration)), "velocity": int(_clamp(velocity, 1, 127)), "source": source,
    }
    if note is not None:
        result["note"] = int(_clamp(note, 0, 127))
    result.update(fields)
    return result


LAM_DENSITY_MIN = 0.5
LAM_DENSITY_MAX = 30.0


def density_to_lambda(density: float) -> float:
    """Map a 0-1 density control onto the segment change price λ.

    Low density (0.0) gives λ=0.5, which keeps almost every contour wiggle;
    high density (1.0) gives λ=30, which keeps only the large gestures. The
    mapping is geometric so the middle of the slider is musically useful
    rather than crammed against one end.
    """
    ratio = _clamp(float(density), 0.0, 1.0)
    return LAM_DENSITY_MIN * (LAM_DENSITY_MAX / LAM_DENSITY_MIN) ** ratio


def intent_features(ticks: Sequence[Mapping[str, object]],
                    pitch_space: PitchSpace = DEFAULT_PITCH_SPACE) -> List[Dict[str, object]]:
    """Per-tick expression features of the trajectory. Produces no events.

    This is the explicit middle layer between geometry and music: the curve is
    a vector valued function, and each musical parameter reads one scalar
    functional of it. Keeping the layer separate means the note generators (the
    anchor path and the variational segmentation) both read the same features,
    and that a new feature can be added and validated without touching them.

    Only zeroth and first order quantities are provided. Curvature and torsion
    are deliberately absent: measured at 200 Hz they are noise dominated
    (median 11.9 against MAD 11.1), so they need a scale space smoother first.
    """
    span = max(1, pitch_space.max_midi - pitch_space.min_midi)
    features: List[Dict[str, object]] = []
    previous_pitch: float | None = None
    for row in ticks:
        raw = row.get("b_abs")
        pitch: float | None = None if raw is None else pitch_space.min_midi + float(raw) * span
        bow = row.get("cursor_x")
        if bow is None:
            bow = row.get("q_x")
        height = row.get("q_z")
        speed = float(row.get("speed", 0.0))
        direction = 0
        if pitch is not None and previous_pitch is not None:
            delta = pitch - previous_pitch
            direction = 0 if abs(delta) < 1e-9 else (1 if delta > 0.0 else -1)
        features.append({
            "tick": int(row.get("tick", 0)),
            "pitch": None if pitch is None else round(pitch, 4),
            "pitch_norm": None if raw is None else round(float(raw), 6),
            "bow": None if bow is None else round(float(bow), 6),
            "height": None if height is None else round(float(height), 6),
            "speed": round(speed, 6),
            "direction": direction,
            "valid": bool(row.get("position_valid", True)),
            "engaged": not bool(row.get("lift", False)),
        })
        if pitch is not None:
            previous_pitch = pitch
    return features


def _intent_summary(features: Sequence[Mapping[str, object]]) -> Dict[str, object]:
    pitches = [float(item["pitch"]) for item in features if item.get("pitch") is not None]
    speeds = [float(item["speed"]) for item in features]
    engaged = sum(1 for item in features if item.get("engaged"))
    return {
        "ticks": len(features),
        "pitch_min": round(min(pitches), 3) if pitches else None,
        "pitch_max": round(max(pitches), 3) if pitches else None,
        "speed_mean": round(sum(speeds) / len(speeds), 4) if speeds else 0.0,
        "engaged_ratio": round(engaged / len(features), 4) if features else 0.0,
        "reversals": sum(1 for before, after in zip(features, features[1:])
                         if before["direction"] and after["direction"]
                         and before["direction"] != after["direction"]),
    }


def bow_attacks(values: Sequence[float], deadzone: float = 0.03) -> List[int]:
    """Return the ticks where the bow reverses direction.

    A reversal counts only after the bow has travelled ``deadzone`` back from
    its extreme, so sensor jitter cannot machine-gun a repeated note. A full
    round trip produces two attacks (out and back), which is the agreed
    behaviour.
    """
    attacks: List[int] = []
    if len(values) < 2:
        return attacks
    direction = 0
    extreme = float(values[0])
    extreme_index = 0
    for index in range(1, len(values)):
        value = float(values[index])
        if direction == 0:
            if value - extreme >= deadzone:
                direction, extreme, extreme_index = 1, value, index
            elif extreme - value >= deadzone:
                direction, extreme, extreme_index = -1, value, index
            elif value > extreme:
                extreme, extreme_index = value, index
        elif direction > 0:
            if value > extreme:
                extreme, extreme_index = value, index
            elif extreme - value >= deadzone:
                attacks.append(extreme_index)
                direction, extreme, extreme_index = -1, value, index
        else:
            if value < extreme:
                extreme, extreme_index = value, index
            elif value - extreme >= deadzone:
                attacks.append(extreme_index)
                direction, extreme, extreme_index = 1, value, index
    return attacks


def merge_leaps(segments: Sequence[Tuple[int, int, int]], degrees: int = 3,
                dwell: int = 8) -> List[Tuple[int, int, int]]:
    """Collapse short glances at passing degrees into one leap.

    Starting from a segment, everything shorter than ``dwell`` is treated as a
    sweep; the run ends at the first segment that actually dwells. When the
    swept pitch distance reaches ``degrees``, the departure note is kept and
    the sweep lands directly on the arrival level, so the levels merely passed
    through never become notes. A real dwell on a passing note is longer than
    ``dwell`` and therefore survives.
    """
    if degrees <= 0 or len(segments) < 2:
        return list(segments)
    merged: List[Tuple[int, int, int]] = []
    index = 0
    while index < len(segments):
        end = index
        while end + 1 < len(segments) and (segments[end][1] - segments[end][0]) < dwell:
            end += 1
        target = end
        if target > index and abs(segments[target][2] - segments[index][2]) >= degrees:
            merged.append(segments[index])
            merged.append((segments[index + 1][0], segments[target][1], segments[target][2]))
            index = target + 1
        else:
            merged.append(segments[index])
            index += 1
    return merged


def segment_contour(values: Sequence[float], levels: Sequence[int],
                    lam: float, min_len: int = 4) -> List[Tuple[int, int, int]]:
    """Optimal piecewise-constant fit of a contour on a fixed degree set.

    Minimises ``Σ (f - g)² + λ · segments`` with ``g`` restricted to ``levels``
    and every segment at least ``min_len`` frames long, solved exactly by
    dynamic programming over (frame, degree, run length). The segment
    boundaries are the notes and the segment lengths are their durations, so
    density is controlled by one musical quantity: λ, the price of changing
    note.
    """
    n = len(values)
    if n == 0:
        return []
    dp: List[Dict[Tuple[int, int], float]] = [dict() for _ in range(n)]
    back: List[Dict[Tuple[int, int], Tuple[int, int] | None]] = [dict() for _ in range(n)]
    for k, level in enumerate(levels):
        dp[0][(k, 1)] = (float(values[0]) - float(level)) ** 2
        back[0][(k, 1)] = None
    for t in range(1, n):
        frame_value = float(values[t])
        for k, level in enumerate(levels):
            frame_cost = (frame_value - float(level)) ** 2
            for (previous, run), cost in dp[t - 1].items():
                if previous == k:
                    key = (k, run + 1)
                    if key not in dp[t] or cost + frame_cost < dp[t][key]:
                        dp[t][key] = cost + frame_cost
                        back[t][key] = (previous, run)
                elif run >= min_len:
                    key = (k, 1)
                    if key not in dp[t] or cost + lam + frame_cost < dp[t][key]:
                        dp[t][key] = cost + lam + frame_cost
                        back[t][key] = (previous, run)
    if not dp[n - 1]:
        return []
    state = min(dp[n - 1], key=lambda item: dp[n - 1][item])
    path: List[int] = []
    for t in range(n - 1, -1, -1):
        path.append(state[0])
        previous = back[t][state]
        if previous is not None:
            state = previous
    path.reverse()
    segments: List[Tuple[int, int, int]] = []
    start = 0
    for index in range(1, n):
        if path[index] != path[index - 1]:
            segments.append((start, index, int(levels[path[index - 1]])))
            start = index
    segments.append((start, n, int(levels[path[-1]])))
    return segments


def _segment_events(ticks: Sequence[Mapping[str, object]], pitch_space: PitchSpace,
                    style: SynthwaveStyle, lam: float, min_len: int,
                    bow_deadzone: float = 0.10, leap_degrees: int = 0,
                    leap_dwell: int = 8,
                    gate_source: str = "bow") -> List[Dict[str, object]]:
    """Turn the optimal segmentation into Lead events, then articulate it.

    Two post-passes sit on top of the segmentation: short glances at passing
    degrees collapse into one leap, and every bow reversal inside a segment
    re-attacks the same pitch. The segmentation decides where the melody goes;
    these decide how it is played.
    """
    span = max(1, pitch_space.max_midi - pitch_space.min_midi)
    raw_values: List[float | None] = []
    for row in ticks:
        value = row.get("b_abs")
        raw_values.append(None if value is None else pitch_space.min_midi + float(value) * span)
    filled: List[float] = []
    previous = float(pitch_space.center_midi)
    for value in raw_values:
        if value is not None:
            previous = value
        filled.append(previous)
    levels = list(pitch_space.scale_pitches)
    bows: List[float] = []
    for row in ticks:
        bow = row.get("cursor_x")
        if bow is None:
            bow = row.get("q_x")
        bows.append(0.5 if bow is None else float(bow))
    # Segment each covered run separately: in loop time mapping a short take
    # leaves the end of the loop unreached, and that gap is a rest, not a note
    # that sustains on stale data.
    runs: List[List[Tuple[int, float]]] = []
    current: List[Tuple[int, float]] = []
    for index, value in enumerate(raw_values):
        if value is None:
            if current:
                runs.append(current)
                current = []
        else:
            current.append((index, value))
    if current:
        runs.append(current)
    segments: List[Tuple[int, int, int]] = []
    for run in runs:
        local = segment_contour([value for _, value in run], levels, lam, min_len)
        # Leap merging is off by default. Measured: a genuine fast oscillation
        # produces many short segments, and merging those swallowed whole
        # melodies (a 1 Hz sine dropped from 71 notes to 3). min_segment
        # already stops sub-four-tick passing tones, which is the rule that was
        # actually asked for; set leap_degrees above zero to opt back in.
        for start, end, level in merge_leaps(local, leap_degrees, leap_dwell):
            if end <= start:
                continue
            segments.append((run[start][0], run[end - 1][0] + 1, level))
    gap = max(1, min_len)
    events: List[Dict[str, object]] = []
    touches = [int(row.get("touch_flags") or 0) != 0 for row in ticks]
    for segment_index, (start, end, level) in enumerate(segments):
        if gate_source == "touch":
            # Contact is the gate: every touch run inside the segment sounds,
            # and its length is the note length. Hovering is silence.
            intervals: List[Tuple[int, int]] = []
            cursor = start
            while cursor < end:
                if touches[cursor]:
                    run_start = cursor
                    while cursor < end and touches[cursor]:
                        cursor += 1
                    intervals.append((run_start, cursor))
                else:
                    cursor += 1
        else:
            bounds = [start]
            for attack in bow_attacks(bows[start:end], bow_deadzone):
                tick = start + attack
                if tick - bounds[-1] >= gap and end - tick >= 2:
                    bounds.append(tick)
            bounds.append(end)
            intervals = [(bounds[part], bounds[part + 1]) for part in range(len(bounds) - 1)]
        for part, (note_start, note_end) in enumerate(intervals):
            row = ticks[min(len(ticks) - 1, note_start)] if ticks else {}
            duration = max(1, note_end - note_start)
            travel = abs(bows[note_end - 1] - bows[note_start]) if note_end > note_start else 0.0
            z_norm = _clamp((float(row.get("q_z", 0.0)) * 65535.0 - 4000.0) / 20000.0, 0.0, 1.0)
            proximity = 1.0 - z_norm
            velocity = int(_clamp(40.0 + 55.0 * proximity
                                  + 22.0 * _clamp(float(row.get("speed", 0.0)) * 12.0, 0.0, 1.0)
                                  + 10.0 * _clamp(travel / 0.1, 0.0, 1.0), 32.0, 122.0))
            articulation = "legato" if duration >= 8 else "pluck"
            events.append(_event(
                "lead", note_start, note=level, duration=duration, velocity=velocity, source="trajectory",
                source_landmarks=[], raw_target_midi=round(filled[note_start], 4),
                target_scale_index=levels.index(level),
                quantization_delta=round(level - filled[note_start], 4), register_id=0,
                color_layer=int(_clamp(float(row.get("c_abs", 0.5)), 0.0, 1.0) * 2.999),
                out_of_range=bool(row.get("out_of_range", False)),
                b_abs=round(float(row.get("b_abs", 0.0)), 6),
                b_norm=round(_clamp(float(row.get("b_abs", 0.0)), 0.0, 1.0), 6),
            z_norm=round(z_norm, 4), proximity=round(proximity, 4),
            confidence=1.0 if duration >= min_len else 0.5,
            pitch_profile_hash=_profile_hash(asdict(pitch_space)),
            correction_reason="optimal_piecewise_constant",
            articulation=articulation, gate_ratio=0.92 if articulation == "legato" else 0.72,
            legato=articulation == "legato", tie=False,
            glide_ms=DEFAULT_LEAD_PATCH.glide_ms if note_start else 0,
            accent=round(_clamp(velocity / 127.0, 0.0, 1.0), 4),
            release_tail=DEFAULT_LEAD_PATCH.release_ms,
            reattack=part > 0, bow_travel=round(travel, 6), gated_by=gate_source,
            generated_reason=f"segment:{segment_index}", segment_index=segment_index, lam=lam,
            limit=style.loop_ticks,
        ))
    return events


def compile_lead(samples: Sequence[Mapping[str, object]], style: SynthwaveStyle = STYLE,
                 calibration: CalibrationProfile = DEFAULT_CALIBRATION,
                 pitch_space: PitchSpace = DEFAULT_PITCH_SPACE,
                 mode: str = "workspace",
                 host_profile: HostCalibrationProfile | None = None,
                 pitch_source: str = "absolute",
                 note_source: str = "anchors",
                 lam: float = 6.0,
                 min_segment: int = 4,
                 bow_deadzone: float = 0.10,
                 leap_degrees: int = 0,
                 leap_dwell: int = 8,
                 time_map: str = "stretch", gate_source: str = "bow") -> Dict[str, object]:
    host_filter = filter_capture(samples, host_profile) if host_profile is not None else None
    processed = preprocess_samples(samples, calibration, mode, host_profile, host_filter, pitch_source)
    ticks = resample_to_ticks(processed, style, time_map) if processed else []
    landmarks = extract_landmarks(ticks, style)
    features = intent_features(ticks, pitch_space)
    pitches = pitch_space.scale_pitches
    chosen: List[Dict[str, object]] = []
    for landmark in (item for item in landmarks if item["kind"] in {"move", "hold", "turn", "apex", "valley", "release"}):
        if chosen and int(landmark["tick"]) - int(chosen[-1]["tick"]) < 4:
            if landmark["kind"] in {"turn", "apex", "valley"}:
                chosen[-1] = landmark
            continue
        chosen.append(landmark)
    events: List[Dict[str, object]] = []
    previous_note: int | None = None
    for index, landmark in enumerate(chosen):
        tick = int(landmark["tick"])
        row = ticks[min(len(ticks) - 1, tick)] if ticks else {}
        raw = pitch_space.min_midi + _clamp(float(row.get("b_abs", 0.5)), 0.0, 1.0) * (pitch_space.max_midi - pitch_space.min_midi)
        note = _quantize_hysteresis(raw, pitches, previous_note, pitch_space.hysteresis)
        previous_note = note
        next_tick = int(chosen[index + 1]["tick"]) if index + 1 < len(chosen) else style.loop_ticks
        duration = max(2, next_tick - tick)
        color = int(_clamp(float(row.get("c_abs", 0.5)), 0.0, 1.0) * 2.999)
        # Height carries the dynamics: close to the sensor reads as force, far
        # as softness. Speed still contributes, so a fast gesture at any height
        # stays articulate.
        z_norm = _clamp((float(row.get("q_z", 0.0)) * 65535.0 - 4000.0) / 20000.0, 0.0, 1.0)
        proximity = 1.0 - z_norm
        velocity = int(_clamp(40.0 + 55.0 * proximity + 22.0 * _clamp(float(row.get("speed", 0.0)) * 12.0, 0.0, 1.0), 32.0, 122.0))
        articulation = "legato" if landmark["kind"] in {"hold", "move"} or duration >= 8 else "pluck"
        events.append(_event("lead", tick, note=note, duration=duration, velocity=velocity, source="trajectory",
                             source_landmarks=[landmark["id"]], raw_target_midi=round(raw, 4),
                             target_scale_index=pitches.index(note), quantization_delta=round(note - raw, 4),
                             register_id=0, color_layer=color, out_of_range=bool(row.get("out_of_range", False)),
                             b_abs=round(float(row.get("b_abs", 0.0)), 6),
                             b_norm=round(_clamp(float(row.get("b_abs", 0.0)), 0.0, 1.0), 6),
                             z_norm=round(z_norm, 4), proximity=round(proximity, 4),
                             confidence=round(float(landmark.get("confidence", 0.5)), 4),
                             pitch_profile_hash=_profile_hash(asdict(pitch_space)),
                             correction_reason="nearest_fixed_scale_with_hysteresis",
                             articulation=articulation, gate_ratio=0.92 if articulation == "legato" else 0.72,
                             legato=articulation == "legato", tie=False,
                             glide_ms=DEFAULT_LEAD_PATCH.glide_ms if index else 0,
                             accent=round(_clamp(velocity / 127.0, 0.0, 1.0), 4), release_tail=DEFAULT_LEAD_PATCH.release_ms,
                             generated_reason=f"landmark:{landmark['kind']}", limit=style.loop_ticks))
    for landmark in landmarks:
        if landmark["kind"] == "rest":
            next_tick = next((int(future["tick"]) for future in landmarks if int(future["tick"]) > int(landmark["tick"])), style.loop_ticks)
            events.append(_event("lead", int(landmark["tick"]), duration=max(1, next_tick - int(landmark["tick"])),
                                 event_type="rest", source="trajectory", source_landmarks=[landmark["id"]], generated_reason="position_invalid", limit=style.loop_ticks))
    if note_source == "variational":
        # The segmentation covers every tick, so landmarks stay diagnostic and
        # their rest events are not emitted.
        events = _segment_events(ticks, pitch_space, style, lam, min_segment,
                                 bow_deadzone, leap_degrees, leap_dwell, gate_source)
    events.sort(key=lambda event: (int(event["tick"]), str(event["type"])) )
    # A note may not outlast the next event. Before this, a 126 tick note
    # overlapped the 70 tick rest that followed it, so any player that honours
    # rests cut the note off mid-flight.
    for index, event in enumerate(events):
        if event["type"] != "note_on":
            continue
        following = int(events[index + 1]["tick"]) if index + 1 < len(events) else style.loop_ticks
        event["duration"] = max(1, min(int(event["duration"]), following - int(event["tick"])))
    valid_count = sum(1 for row in processed if valid_flag(row.get("position_valid")))
    coverage = valid_count / len(processed) if processed else 0.0
    if time_map == "loop" and ticks:
        # In loop recording the useful number is how much of the bar the take
        # actually reached, not how many captured frames were valid.
        coverage = sum(1 for row in ticks if row.get("b_abs") is not None) / len(ticks)
    status = "insufficient_capture" if len(processed) < 2 else (
        "weak_motif" if sum(1 for event in events if event["type"] == "note_on") <= 1 else "ok")
    diagnostics = {
        "status": status, "coverage": round(coverage, 4),
        "lead_start_gate": {
            "left_edge_max": LEAD_LEFT_EDGE_MAX,
            "min_rightward_delta": LEAD_MIN_RIGHTWARD_DELTA,
            "accepted": any(row.get("start_gate_state") == "accepted" for row in processed),
            "accepted_count": sum(1 for row in processed if row.get("start_gate_state") == "accepted"),
        },
        "landmark_counts": {kind: sum(1 for item in landmarks if item["kind"] == kind) for kind in ("move", "hold", "turn", "apex", "valley", "rest", "release")},
        "no_source_count": sum(1 for event in events if event.get("type") == "note_on" and not event.get("source_landmarks")),
        "forced_tonic": False, "forced_high_point": False, "capture_hash": _capture_hash(samples),
        "pitch_profile_hash": _profile_hash(asdict(pitch_space)), "calibration_profile_hash": _profile_hash(asdict(calibration)), "mode": mode,
        "note_source": note_source, "lam": lam if note_source == "variational" else None,
        "intent_summary": _intent_summary(features),
    }
    if host_profile is not None and host_filter is not None:
        diagnostics.update({
            "host_profile_hash": host_profile.profile_hash,
            "host_filter": host_filter.diagnostics,
        })
    else:
        diagnostics.update({"host_profile_hash": None, "host_filter": None})
    return {"version": 3, "style": style.name, "config": asdict(style), "events": events, "landmarks": landmarks,
            "intent": features,
            "samples": ticks, "pitch_space": asdict(pitch_space), "calibration": asdict(calibration),
            "lead_patch": asdict(DEFAULT_LEAD_PATCH), "diagnostics": diagnostics}


NOTE_PITCH_CLASSES = {
    "C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4,
    "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11,
}
CHORD_QUALITIES = {
    "": (0, 4, 7), "maj": (0, 4, 7), "M": (0, 4, 7), "m": (0, 3, 7), "min": (0, 3, 7),
    "dim": (0, 3, 6), "aug": (0, 4, 8), "sus2": (0, 2, 7), "sus4": (0, 5, 7),
}
CHORD_BASE_MIDI = 48  # C3; keeps the default progression on the same roots


def parse_chord(name: str) -> Tuple[int, Tuple[int, ...]]:
    """Turn a chord name such as ``Am`` or ``Cmaj`` into root and intervals.

    The progression is configuration, not code: any list of names written the
    usual way works, and the default ``Am F C G`` resolves to the same roots
    the hardcoded table used (57, 53, 48, 55).
    """
    text = str(name).strip()
    if not text:
        text = "C"
    root_name = text[:2] if len(text) > 1 and text[1] in "#b" else text[:1]
    quality = text[len(root_name):]
    pitch_class = NOTE_PITCH_CLASSES.get(root_name)
    if pitch_class is None:
        raise ValueError(f"unknown chord root: {name!r}")
    intervals = CHORD_QUALITIES.get(quality, CHORD_QUALITIES["maj"])
    root = CHORD_BASE_MIDI + pitch_class
    return root, tuple(root + interval for interval in intervals)


def _chord(tick: int, style: SynthwaveStyle = STYLE) -> Tuple[int, Tuple[int, ...]]:
    harmony = tuple(style.harmony) or ("Am",)
    bar = max(1, int(style.ticks_per_bar))
    return parse_chord(harmony[(int(tick) // bar) % len(harmony)])


def _tick_for(timestamp: float, start: float, style: SynthwaveStyle) -> int:
    return int(_clamp(round((timestamp - start) / style.loop_ms * style.loop_ticks), 0, style.loop_ticks - 1)) if style.loop_ms > 0 else 0


def _record_track(track: str, records: Sequence[Mapping[str, object]], style: SynthwaveStyle) -> List[Dict[str, object]]:
    if not records or track == "lead":
        return []
    ordered = sorted(records, key=lambda r: _sample_timestamp(r, 0.0))
    start, previous_touch, previous_tap = _sample_timestamp(ordered[0], 0.0), 0, 0
    result: List[Dict[str, object]] = []
    for record in ordered:
        touch, tap = _number(record.get("touch_flags")), _number(record.get("tap_flags"))
        rising_touch, new_tap = touch & ~previous_touch, tap & ~previous_tap
        trigger = new_tap or rising_touch
        if trigger:
            tick = _tick_for(_sample_timestamp(record, start), start, style)
            y, z = _clamp(_number(record.get("y")) / 65535.0, 0.0, 1.0), _clamp(_number(record.get("z")) / 65535.0, 0.0, 1.0)
            velocity = int(52 + 68 * z)
            if track == "drums":
                mapping = (36, 38, 42, 46, 49)
                bit = (new_tap or rising_touch) & -(new_tap or rising_touch)
                index = min(4, max(0, bit.bit_length() - 1))
                result.append(_event(track, tick, note=mapping[index], duration=1, velocity=velocity, source="touch_tap", electrode=index, limit=style.loop_ticks))
            elif track == "bass":
                root, _ = _chord(tick, style)
                degree = 0 if y < 0.45 else (7 if y < 0.75 else 12)
                result.append(_event(track, tick, note=root - 12 + degree, duration=8, velocity=velocity, source="touch_tap", limit=style.loop_ticks))
            elif track == "pad":
                _, chord = _chord(tick, style)
                inversion = 0 if y < 0.5 else 1
                for offset, note in enumerate(chord):
                    result.append(_event(track, tick, note=note + 12 * inversion, duration=32, velocity=max(1, velocity - offset * 5), source="touch_tap", chord_voice=offset, limit=style.loop_ticks))
            elif track == "arp":
                _, chord = _chord(tick, style)
                order = chord if y < 0.5 else tuple(reversed(chord))
                for offset, note in enumerate(order):
                    result.append(_event(track, min(style.loop_ticks - 1, tick + offset * 4), note=note + 12, duration=3, velocity=velocity, source="touch_tap", arp_step=offset, limit=style.loop_ticks))
            elif track == "texture_fx":
                result.append(_event(track, tick, duration=16, velocity=velocity, event_type="control_point", source="touch_tap", cutoff=int(300 + 6000 * y), reverb_send=int(40 + 80 * z), delay_send=int(30 + 90 * z), limit=style.loop_ticks))
        previous_touch, previous_tap = touch, tap
    return result[:16]


def length_from_take(samples: Sequence[Mapping[str, object]], style: SynthwaveStyle,
                     max_bars: int = 32) -> SynthwaveStyle:
    """Return a style whose loop covers the take, rounded up to whole bars.

    The loop is still a loop, but its length follows how long the operator
    played instead of being fixed at eight bars. The cap exists because the
    event table and the eventual hardware loop buffer are finite.
    """
    if not samples:
        return style
    ordered = _capture_order(samples)
    start = _sample_timestamp(ordered[0], 0.0)
    end = _sample_timestamp(ordered[-1], start)
    bar_ms = 60000.0 * 4.0 / max(1, style.bpm)
    bars = max(1, int(math.ceil(max(0.0, end - start) / bar_ms)))
    return replace(style, loop_bars=min(max(1, int(max_bars)), bars))


def compile_loop(lead_samples: Sequence[Mapping[str, object]], track_records: Mapping[str, Sequence[Mapping[str, object]]], style: SynthwaveStyle = STYLE, mode: str = "workspace", host_profile: HostCalibrationProfile | None = None, pitch_source: str = "cursor", pitch_space: PitchSpace = DEFAULT_PITCH_SPACE, note_source: str = "anchors", lam: float = 6.0, bow_deadzone: float = 0.10, leap_degrees: int = 0, leap_dwell: int = 8, time_map: str = "stretch", auto_length: bool = False, max_bars: int = 32, lead_layers: Sequence[Sequence[Mapping[str, object]]] | None = None, gate_source: str = "bow") -> Dict[str, object]:
    if auto_length:
        style = length_from_take(lead_samples, style, max_bars)
    layers = [list(layer) for layer in (lead_layers if lead_layers is not None else [lead_samples]) if layer]
    if not layers:
        layers = [list(lead_samples)]
    compile_kwargs = dict(style=style, calibration=DEFAULT_CALIBRATION, pitch_space=pitch_space, mode=mode,
                          host_profile=host_profile, pitch_source=pitch_source, note_source=note_source, lam=lam,
                          bow_deadzone=bow_deadzone, leap_degrees=leap_degrees, leap_dwell=leap_dwell,
                          time_map=time_map)
    lead_results = [compile_lead(layer, **compile_kwargs) for layer in layers]
    lead_result = lead_results[0]
    lead_events: List[Dict[str, object]] = []
    seen: set = set()
    for index, result in enumerate(lead_results):
        for event in result["events"]:
            event["layer"] = index
            key = (int(event["tick"]), str(event.get("type")), event.get("note"), int(event.get("duration", 0)))
            if key in seen:
                continue
            seen.add(key)
            lead_events.append(event)
    lead_events.sort(key=lambda event: (int(event["tick"]), str(event.get("type"))))
    tracks: Dict[str, List[Dict[str, object]]] = {name: [] for name in TRACKS}
    tracks["lead"] = lead_events
    for track in TRACKS[1:]:
        tracks[track] = _record_track(track, track_records.get(track, ()), style)
    all_events = [event for values in tracks.values() for event in values]
    diagnostics = dict(lead_result["diagnostics"])
    diagnostics.update({"lead_events": len(tracks["lead"]), "recorded_events": {name: len(tracks[name]) for name in TRACKS[1:]}, "harmony": list(style.harmony), "high_point_ratio": None,
                        "loop_bars": style.loop_bars, "auto_length": bool(auto_length),
                        "layers": len(layers), "layer_notes": [sum(1 for event in values if event.get("type") == "note_on") for values in
                                                              ([result["events"] for result in lead_results])]})
    return {"version": 3, "style": style.name, "config": asdict(style), "tracks": tracks,
            "events": sorted(all_events, key=lambda e: (int(e["tick"]), TRACKS.index(str(e["track"])) if e["track"] in TRACKS else 99)),
            "landmarks": lead_result["landmarks"], "samples": lead_result["samples"], "pitch_space": lead_result["pitch_space"],
            "calibration": lead_result["calibration"], "lead_patch": lead_result["lead_patch"], "diagnostics": diagnostics}


def _role_wave(role: str, phase: float, note: int, age: float) -> float:
    angle = 2.0 * math.pi * phase
    if role == "lead":
        return 0.54 * (2.0 * phase - 1.0) + 0.26 * (1.0 if phase < 0.47 else -1.0) + 0.20 * math.sin(angle)
    if role == "bass":
        return 0.75 if phase < 0.5 else -0.75
    if role == "pad":
        return 0.65 * math.sin(angle) + 0.20 * math.sin(2 * angle)
    if role == "arp":
        return 0.6 * (2.0 * abs(2.0 * (phase - math.floor(phase + 0.5))) - 1.0)
    if role == "drums":
        return math.sin(angle * (1.0 + 0.0005 * note)) * math.exp(-age * (20.0 if note in (36, 38) else 55.0))
    if role == "texture_fx":
        return 0.25 * math.sin(angle * 0.5) + 0.15 * math.sin(angle * 3.01)
    return 0.6 * math.sin(angle)


def _lead_envelope(age: float, remaining: float, patch: Mapping[str, object], accent: float) -> float:
    attack = max(0.001, float(patch.get("attack_ms", 35)) / 1000.0)
    decay = max(0.001, float(patch.get("decay_ms", 180)) / 1000.0)
    release = max(0.001, float(patch.get("release_ms", 520)) / 1000.0)
    sustain = float(patch.get("sustain", 0.72))
    level = age / attack if age < attack else (1.0 - (1.0 - sustain) * (age - attack) / decay if age < attack + decay else sustain)
    if remaining < 0.0:
        level *= _clamp(1.0 + remaining / release, 0.0, 1.0)
    return level * (0.82 + 0.18 * accent)


def render_loop(result: Mapping[str, object], output: Path | str, *, sample_rate: int = 22050, loops: int = 1) -> Path:
    config, patch = result.get("config", {}), result.get("lead_patch", asdict(DEFAULT_LEAD_PATCH))
    bpm, loop_bars, ticks_per_bar = float(config.get("bpm", STYLE.bpm)), int(config.get("loop_bars", STYLE.loop_bars)), int(config.get("ticks_per_bar", STYLE.ticks_per_bar))
    loop_ticks, loop_seconds = loop_bars * ticks_per_bar, 60.0 * 4.0 * loop_bars / bpm
    total = int((loop_seconds * loops + 1.2) * sample_rate)
    starts: List[Dict[str, object]] = []
    for loop_index in range(loops):
        for event in list(result.get("events", [])):
            if event.get("type") != "note_on" or "note" not in event:
                continue
            starts.append({**event, "time": loop_index * loop_seconds + int(event["tick"]) / loop_ticks * loop_seconds, "end": loop_index * loop_seconds + (int(event["tick"]) + int(event.get("duration", 1))) / loop_ticks * loop_seconds})
    starts.sort(key=lambda event: (float(event["time"]), str(event.get("track"))))
    active: List[MutableMapping[str, object]] = []
    audio: List[float] = []
    cursor = 0
    for index in range(total):
        now = index / sample_rate
        while cursor < len(starts) and float(starts[cursor]["time"]) <= now:
            event = starts[cursor]
            active.append({"event": event, "phase": 0.0, "on": float(event["time"]), "frequency": None})
            cursor += 1
        value, kept = 0.0, []
        for voice in active:
            event, on, end = voice["event"], float(voice["on"]), float(voice["event"]["end"])
            age, remaining, role = now - on, end - now, str(event["track"])
            if remaining < -0.7:
                continue
            target = 440.0 * 2.0 ** ((int(event["note"]) - 69) / 12.0)
            current = target if voice["frequency"] is None else float(voice["frequency"])
            glide = max(0.001, float(patch.get("glide_ms", 85)) / 1000.0) if role == "lead" else 0.001
            current += (target - current) * _clamp(1.0 / (sample_rate * glide), 0.0, 1.0)
            voice["frequency"] = current
            voice["phase"] = (float(voice["phase"]) + current / sample_rate) % 1.0
            accent = float(event.get("accent", int(event.get("velocity", 80)) / 127.0))
            if role == "lead":
                envelope = _lead_envelope(age, remaining, patch, accent)
                vibrato = float(patch.get("vibrato_cents", 11.0)) * math.sin(2.0 * math.pi * float(patch.get("vibrato_hz", 4.2)) * age)
                phase = (float(voice["phase"]) * 2.0 ** (vibrato / 1200.0)) % 1.0
                wave_value = _role_wave(role, phase, int(event["note"]), age)
            else:
                attack = 0.025 if role in ("drums", "bass") else (0.25 if role == "pad" else 0.07)
                release = 0.15 if role == "drums" else (0.8 if role in ("pad", "texture_fx") else 0.35)
                envelope = min(1.0, age / attack)
                if remaining < 0:
                    envelope *= _clamp(1.0 + remaining / release, 0.0, 1.0)
                envelope *= 0.65 if role == "bass" else (0.45 if role == "pad" else 0.72)
                wave_value = _role_wave(role, float(voice["phase"]), int(event["note"]), age)
            value += envelope * int(event.get("velocity", 80)) / 127.0 * wave_value
            kept.append(voice)
        active = kept
        lfo = 0.92 + 0.08 * math.sin(2.0 * math.pi * float(patch.get("cutoff_lfo_hz", 0.08)) * now)
        audio.append(value * 0.16 * lfo)
    delay = int(sample_rate * float(patch.get("delay_ms", 620)) / 1000.0)
    echo = list(audio)
    for i in range(delay, len(echo)):
        echo[i] += audio[i - delay] * float(patch.get("delay_feedback", 0.30))
        if i >= 2 * delay:
            echo[i] += audio[i - 2 * delay] * float(patch.get("delay_feedback", 0.30)) * 0.45
        short = int(sample_rate * 0.037)
        if i >= short:
            echo[i] += audio[i - short] * float(patch.get("reverb_send", 0.28)) * 0.08
    peak = max(1e-9, max((abs(value) for value in echo), default=1e-9))
    scale = min(0.92 / peak, 1.0)
    target = Path(output)
    target.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(target), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"".join(struct.pack("<h", int(_clamp(math.tanh(value * 1.4) * 32767 * scale, -32768, 32767))) for value in echo))
    return target


def write_event_table(result: Mapping[str, object], output: Path | str) -> Path:
    path = Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description="Compile MGC3130 JSONL into a six-track Synthwave loop")
    parser.add_argument("input", type=Path)
    parser.add_argument("--events", type=Path, default=Path("synthwave_events.json"))
    parser.add_argument("--wav", type=Path, default=Path("synthwave_loop.wav"))
    parser.add_argument("--sample-rate", type=int, default=22050)
    parser.add_argument("--notes", choices=("anchors", "variational"), default="anchors")
    parser.add_argument("--lam", type=float, default=6.0, help="segment change price for --notes variational")
    parser.add_argument("--time-map", choices=("stretch", "loop"), default="stretch")
    args = parser.parse_args()
    records = load_jsonl_records(args.input)
    result = compile_loop(records, {track: records for track in TRACKS[1:]}, note_source=args.notes, lam=args.lam, time_map=args.time_map)
    write_event_table(result, args.events)
    render_loop(result, args.wav, sample_rate=args.sample_rate)
    print(json.dumps(result["diagnostics"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
