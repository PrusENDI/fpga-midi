"""Deterministic PC-side MGC3130 quality, decoupling, and filtering layer.

The module intentionally does not pretend to be GestIC hardware calibration.
It consumes an explicit, reviewable HostCalibrationProfile and preserves raw
reports alongside every derived coordinate.
"""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import asdict, dataclass, field
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple

RAW_MAX = 65535.0


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def _median(values: Sequence[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(float(value) for value in values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2.0


def _mad(values: Sequence[float], center: float | None = None) -> float:
    if not values:
        return 0.0
    pivot = _median(values) if center is None else float(center)
    return _median([abs(float(value) - pivot) for value in values])


def _dot(a: Sequence[float], b: Sequence[float]) -> float:
    return sum(float(left) * float(right) for left, right in zip(a, b))


def _canonical_hash(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, default=list).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()[:16]


def _tuple3(value: Sequence[float], default: Tuple[float, float, float]) -> Tuple[float, float, float]:
    if len(value) != 3:
        return default
    return tuple(float(item) for item in value)  # type: ignore[return-value]


DEFAULT_FILTER_CONFIG: Dict[str, float] = {
    "median_ms": 20.0,
    "lowpass_tau_ms": 45.0,
    "minimum_intent_ms": 80.0,
    "pitch_dead_zone": 0.003,
    "pitch_speed_threshold": 0.30,
    "depth_speed_threshold": 0.15,
    "horizontal_speed_threshold": 0.30,
    "max_slew_per_second": 8.0,
    "max_gap_frames": 3.0,
    "max_gap_ms": 100.0,
}


@dataclass(frozen=True)
class HostCalibrationProfile:
    profile_id: str = "mgc3130_host_identity_v1"
    raw_reference_xyz: Tuple[float, float, float] = (0.0, 0.0, 0.0)
    raw_scale: Tuple[float, float, float] = (1.0 / RAW_MAX, 1.0 / RAW_MAX, 1.0 / RAW_MAX)
    q_ref: Tuple[float, float, float] = (0.0, 0.0, 0.0)
    workspace_min: Tuple[float, float, float] = (0.0, 0.0, 0.0)
    workspace_max: Tuple[float, float, float] = (1.0, 1.0, 1.0)
    pitch_axis: Tuple[float, float, float] = (0.0, 1.0, 0.0)
    color_axis: Tuple[float, float, float] = (0.0, 0.0, 1.0)
    horizontal_axis: Tuple[float, float, float] = (1.0, 0.0, 0.0)
    b_min: float = 0.0
    b_max: float = 1.0
    saturation_low: Tuple[float, float, float] = (-1.0, -1.0, -1.0)
    saturation_high: Tuple[float, float, float] = (RAW_MAX + 1.0, RAW_MAX + 1.0, RAW_MAX + 1.0)
    neutral_mad_xyz: Tuple[float, float, float] = (0.0, 0.0, 0.0)
    coupling_bins: Tuple[Mapping[str, float], ...] = ()
    coupling_reference_z: float = 0.0
    coupling_confidence: float = 0.0
    coupling_model: str = "identity"
    timestamp_units: str = "ms"
    timestamp_tick_hz: float = 1.0
    filter_config: Mapping[str, float] = field(default_factory=lambda: dict(DEFAULT_FILTER_CONFIG))

    @property
    def profile_hash(self) -> str:
        return _canonical_hash(self.to_dict(include_hash=False))

    def to_dict(self, *, include_hash: bool = True) -> Dict[str, Any]:
        value = asdict(self)
        value["coupling_bins"] = [dict(item) for item in self.coupling_bins]
        value["filter_config"] = dict(self.filter_config)
        if include_hash:
            value["profile_hash"] = self.profile_hash
        return value

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "HostCalibrationProfile":
        fields = dict(value)
        fields.pop("profile_hash", None)
        for name in ("raw_reference_xyz", "raw_scale", "q_ref", "workspace_min", "workspace_max",
                     "pitch_axis", "color_axis", "horizontal_axis", "saturation_low", "saturation_high",
                     "neutral_mad_xyz"):
            if name in fields:
                fields[name] = _tuple3(fields[name], getattr(cls(), name))
        fields["coupling_bins"] = tuple(dict(item) for item in fields.get("coupling_bins", ()))
        fields["filter_config"] = {**DEFAULT_FILTER_CONFIG, **dict(fields.get("filter_config", {}))}
        return cls(**fields)


@dataclass(frozen=True)
class FilteredCapture:
    frames: List[Dict[str, Any]]
    diagnostics: Dict[str, Any]


@dataclass(frozen=True)
class NeutralEstimate:
    reference_xyz: Tuple[float, float, float]
    mad_xyz: Tuple[float, float, float]
    valid_ratio: float


def build_identity_profile(**overrides: Any) -> HostCalibrationProfile:
    """Return an explicit no-coupling profile for legacy/replay use."""
    values: Dict[str, Any] = {
        "coupling_model": "identity",
        "coupling_confidence": 0.0,
        "coupling_bins": (),
        "coupling_reference_z": 0.0,
    }
    values.update(overrides)
    if "coupling_bins" in values:
        values["coupling_bins"] = tuple(dict(item) for item in values["coupling_bins"])
        if values["coupling_bins"] and "coupling_reference_z" not in overrides:
            values["coupling_reference_z"] = float(values["coupling_bins"][0]["z"])
            values["coupling_model"] = "piecewise_median"
    return HostCalibrationProfile(**values)


def _number(value: Any, default: float = 0.0) -> float:
    try:
        text = str(value).strip()
        return float(int(text, 0)) if text.lower().startswith("0x") else float(text)
    except (TypeError, ValueError):
        return default


def _as_bool(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value).strip().lower()
    if text in {"true", "yes", "y", "on", "valid", "1"}:
        return True
    if text in {"false", "no", "n", "off", "invalid", "0", ""}:
        return False
    return default


def valid_flag(value: Any, default: bool = True) -> bool:
    """Position validity where an explicit JSON null means "unknown".

    The live SDK receiver emits ``"position_valid": null`` until hardware
    quality reporting is wired up.  Treating that null as "invalid" silently
    discards every frame, so unknown validity falls back to the caller's
    default (valid for the Lead path, matching ``_quality``).
    """
    return _as_bool(value, default)


def capture_order(samples: Sequence[Mapping[str, Any]], key=None) -> List[Dict[str, Any]]:
    """Restore capture order, preferring frame sequence over wall-clock time.

    The MGC3130 frame counter wraps, so a timestamp sort can move the first
    frames of a phrase to the end.  Sequence numbers are monotonic within a
    session and are authoritative when every row carries one.
    """
    rows = [dict(row) for row in samples]
    sequences = [_sequence_number(row) for row in rows]
    if rows and all(sequence is not None for sequence in sequences):
        return sorted(rows, key=lambda row: _sequence_number(row))
    return sorted(rows, key=key or (lambda row: _timestamp(row, 0.0)))


def _sequence_number(row: Mapping[str, Any]) -> int | None:
    try:
        return int(str(row.get("sequence")), 0)
    except (TypeError, ValueError):
        return None


def _raw_xyz(row: Mapping[str, Any]) -> Tuple[float, float, float]:
    return tuple(_number(row.get(axis, 0.0)) for axis in ("x", "y", "z"))  # type: ignore[return-value]


def _timestamp(row: Mapping[str, Any], fallback: float, profile: HostCalibrationProfile | None = None) -> float:
    value = _number(row.get("timestamp_ms", row.get("timestamp", fallback)), fallback)
    if profile is not None and profile.timestamp_units == "ticks":
        return value * 1000.0 / max(1.0, float(profile.timestamp_tick_hz))
    return value


def _quality(row: Mapping[str, Any], profile: HostCalibrationProfile, previous_time: float | None) -> Tuple[bool, Dict[str, Any]]:
    raw = _raw_xyz(row)
    position_valid = _as_bool(row.get("position_valid", row.get("positionValid", True)), True)
    xyz_valid = _as_bool(row.get("xyz_valid", True), True)
    report_error = _as_bool(row.get("report_error", False), False)
    saturated = any(raw[i] <= profile.saturation_low[i] or raw[i] >= profile.saturation_high[i] for i in range(3))
    gap_frames = int(_number(row.get("gap_before", 0)))
    timestamp = _timestamp(row, 0.0, profile)
    gap_ms = 0.0 if previous_time is None else max(0.0, timestamp - previous_time)
    long_gap = gap_frames > int(profile.filter_config.get("max_gap_frames", 3.0)) or gap_ms > float(profile.filter_config.get("max_gap_ms", 100.0))
    quality = {
        "position_valid": position_valid,
        "xyz_valid": xyz_valid,
        "report_error": report_error,
        "sensor_saturated": saturated,
        "sequence_gap": gap_frames,
        "long_gap": long_gap,
    }
    return position_valid and xyz_valid and not report_error and not saturated and not long_gap, quality


def _raw_to_q(raw: Sequence[float], profile: HostCalibrationProfile) -> Tuple[float, float, float]:
    return tuple((float(raw[i]) - profile.raw_reference_xyz[i]) * profile.raw_scale[i] for i in range(3))  # type: ignore[return-value]


def _coupling_at(z: float, profile: HostCalibrationProfile) -> Tuple[float, float, float]:
    bins = sorted(profile.coupling_bins, key=lambda item: float(item.get("z", 0.0)))
    if not bins:
        return 0.0, 0.0, 0.0
    if z <= float(bins[0]["z"]):
        item = bins[0]
        return float(item.get("x", 0.0)), float(item.get("y", 0.0)), float(item.get("z", 0.0))
    if z >= float(bins[-1]["z"]):
        item = bins[-1]
        return float(item.get("x", 0.0)), float(item.get("y", 0.0)), float(item.get("z", 0.0))
    for left, right in zip(bins, bins[1:]):
        zl, zr = float(left["z"]), float(right["z"])
        if zl <= z <= zr:
            ratio = 0.0 if zr <= zl else (z - zl) / (zr - zl)
            return (
                float(left.get("x", 0.0)) + ratio * (float(right.get("x", 0.0)) - float(left.get("x", 0.0))),
                float(left.get("y", 0.0)) + ratio * (float(right.get("y", 0.0)) - float(left.get("y", 0.0))),
                z,
            )
    return 0.0, 0.0, z


def _coupling_alpha(z: float, valid: bool, quality: Mapping[str, Any], profile: HostCalibrationProfile) -> Tuple[float, str]:
    if not profile.coupling_bins or profile.coupling_confidence <= 0.0:
        return 0.0, "identity_profile"
    if not valid or quality.get("sensor_saturated") or quality.get("long_gap"):
        return 0.0, "quality_degraded"
    _, _, nearest_z = _coupling_at(z, profile)
    distance = abs(z - nearest_z)
    bin_confidence = 1.0 if distance < 0.2 else _clamp(1.0 - distance, 0.0, 1.0)
    alpha = _clamp(float(profile.coupling_confidence) * bin_confidence, 0.0, 1.0)
    return alpha, "profile_coupling" if alpha > 0.0 else "sparse_coupling_bin"


def _median_window(history: Sequence[Tuple[float, Tuple[float, float, float]]], now: float, window_ms: float) -> Tuple[float, float, float]:
    values = [q for timestamp, q in history if now - timestamp <= window_ms]
    if not values:
        values = [history[-1][1]] if history else [(0.0, 0.0, 0.0)]
    return tuple(_median([q[axis] for q in values]) for axis in range(3))  # type: ignore[return-value]


def _limit_slew(target: Sequence[float], previous: Sequence[float], dt_s: float, max_per_s: float) -> Tuple[float, float, float]:
    if max_per_s <= 0.0 or dt_s <= 0.0:
        return tuple(float(value) for value in target)  # type: ignore[return-value]
    limit = max_per_s * dt_s
    return tuple(float(previous[i]) + _clamp(float(target[i]) - float(previous[i]), -limit, limit) for i in range(3))  # type: ignore[return-value]


def _motion_state(row: Dict[str, Any], previous: Dict[str, Any] | None, duration_ms: float, profile: HostCalibrationProfile) -> str:
    if row.get("q_filtered") is None:
        return "INVALID/LOST"
    if previous is None or previous.get("q_filtered") is None:
        return "HOLD"
    dt_s = max(1e-6, (_timestamp(row, 0.0, profile) - _timestamp(previous, 0.0, profile)) / 1000.0)
    q = row["q_filtered"]
    old = previous["q_filtered"]
    delta = tuple(float(q[i]) - float(old[i]) for i in range(3))
    db = float(row["b_abs"]) - float(previous["b_abs"])
    dc = float(row["c_abs"]) - float(previous["c_abs"])
    pitch_speed = abs(db) / dt_s
    depth_speed = abs(dc) / dt_s
    horizontal_speed = abs(_dot(delta, profile.horizontal_axis)) / dt_s
    config = profile.filter_config
    if pitch_speed < float(config.get("pitch_dead_zone", 0.003)) / dt_s and depth_speed < float(config.get("depth_speed_threshold", 0.15)) and horizontal_speed < float(config.get("horizontal_speed_threshold", 0.30)):
        return "HOLD"
    if pitch_speed < float(config.get("pitch_speed_threshold", 0.30)) and depth_speed >= float(config.get("depth_speed_threshold", 0.15)) and horizontal_speed < float(config.get("horizontal_speed_threshold", 0.30)):
        return "DEPTH_ONLY" if duration_ms >= float(config.get("minimum_intent_ms", 100.0)) else "HOLD"
    if pitch_speed >= float(config.get("pitch_speed_threshold", 0.30)):
        if duration_ms < float(config.get("minimum_intent_ms", 100.0)):
            return "HOLD"
        return "DIAGONAL_INTENT" if depth_speed >= float(config.get("depth_speed_threshold", 0.15)) else "PITCH_INTENT"
    return "TREMOR" if pitch_speed > 0.0 else "HOLD"


def filter_capture(samples: Sequence[Mapping[str, Any]], profile: HostCalibrationProfile) -> FilteredCapture:
    """Filter a capture while preserving gaps and raw fields."""
    ordered = capture_order(samples, key=lambda row: _timestamp(row, 0.0, profile))
    frames: List[Dict[str, Any]] = []
    history: List[Tuple[float, Tuple[float, float, float]]] = []
    previous_time: float | None = None
    previous_valid: Dict[str, Any] | None = None
    previous_filtered: Tuple[float, float, float] | None = None
    intent_duration_ms = 0.0
    config = profile.filter_config
    counts: Dict[str, int] = {}
    for row in ordered:
        timestamp = _timestamp(row, 0.0, profile)
        valid, quality = _quality(row, profile, previous_time)
        raw = _raw_xyz(row)
        output = dict(row)
        output.update(quality)
        output["timestamp_ms"] = timestamp
        output["x_raw"], output["y_raw"], output["z_raw"] = raw
        output["q_raw"] = _raw_to_q(raw, profile)
        output["q_decoupled"] = None
        output["q_filtered"] = None
        output["coupling_alpha"] = 0.0
        output["coupling_reason"] = "invalid_frame"
        output["filter_reason"] = "invalid_frame"
        output["b_abs"] = None
        output["c_abs"] = None
        if valid:
            q_raw = output["q_raw"]
            alpha, coupling_reason = _coupling_alpha(q_raw[2], valid, quality, profile)
            cx, cy, _ = _coupling_at(q_raw[2], profile)
            reference_x, reference_y, _ = _coupling_at(profile.coupling_reference_z, profile)
            q_decoupled = (
                q_raw[0] - alpha * (cx - reference_x),
                q_raw[1] - alpha * (cy - reference_y),
                q_raw[2],
            )
            history.append((timestamp, q_decoupled))
            window_ms = float(config.get("median_ms", 20.0))
            history = [(t, q) for t, q in history if timestamp - t <= window_ms]
            median = _median_window(history, timestamp, window_ms)
            tau_s = max(0.001, float(config.get("lowpass_tau_ms", 45.0)) / 1000.0)
            dt_s = 0.0 if previous_valid is None else max(0.001, (timestamp - _timestamp(previous_valid, timestamp, profile)) / 1000.0)
            lowpassed = median if previous_filtered is None or previous_valid is None else tuple(previous_filtered[i] + (median[i] - previous_filtered[i]) * dt_s / (tau_s + dt_s) for i in range(3))
            filtered = lowpassed if previous_filtered is None or previous_valid is None else _limit_slew(lowpassed, previous_filtered, dt_s, float(config.get("max_slew_per_second", 8.0)))
            q_ref_delta = tuple(filtered[i] - profile.q_ref[i] for i in range(3))
            output.update({
                "q_decoupled": q_decoupled,
                "q_filtered": filtered,
                "coupling_alpha": round(alpha, 6),
                "coupling_reason": coupling_reason,
                "filter_reason": "segment_restart" if previous_valid is None else "median_lowpass_slew",
                "b_abs": _dot(q_ref_delta, profile.pitch_axis),
                "c_abs": _dot(q_ref_delta, profile.color_axis),
            })
            if previous_valid is None:
                intent_duration_ms = 0.0
            else:
                intent_duration_ms += max(0.0, timestamp - _timestamp(previous_valid, timestamp, profile))
            output["motion_state"] = _motion_state(output, previous_valid, intent_duration_ms, profile)
            previous_filtered = filtered
            previous_valid = output
            counts[output["motion_state"]] = counts.get(output["motion_state"], 0) + 1
        else:
            output["motion_state"] = "INVALID/LOST"
            counts["INVALID/LOST"] = counts.get("INVALID/LOST", 0) + 1
            history.clear()
            previous_filtered = None
            previous_valid = None
            intent_duration_ms = 0.0
        frames.append(output)
        previous_time = timestamp
    valid_count = sum(1 for row in frames if row.get("q_filtered") is not None)
    diagnostics = {
        "profile_hash": profile.profile_hash,
        "profile_id": profile.profile_id,
        "coupling_model": profile.coupling_model,
        "coupling_confidence": profile.coupling_confidence,
        "frame_count": len(frames),
        "valid_count": valid_count,
        "valid_ratio": valid_count / len(frames) if frames else 0.0,
        "motion_state_counts": counts,
        "saturated_count": sum(1 for row in frames if row.get("sensor_saturated")),
        "invalid_count": sum(1 for row in frames if row.get("motion_state") == "INVALID/LOST"),
    }
    return FilteredCapture(frames=frames, diagnostics=diagnostics)


def fit_z_coupling(samples: Sequence[Mapping[str, Any]], *, bin_count: int = 7) -> Tuple[Mapping[str, float], ...]:
    """Fit robust quantile bins from an explicit depth-only capture."""
    valid = []
    for row in samples:
        if not _as_bool(row.get("position_valid", row.get("positionValid", True)), True) or _as_bool(row.get("report_error", False), False):
            continue
        raw = _raw_xyz(row)
        valid.append((raw[2] / RAW_MAX, raw[0] / RAW_MAX, raw[1] / RAW_MAX))
    if not valid:
        raise ValueError("depth capture contains no valid XYZ samples")
    valid.sort(key=lambda item: item[0])
    count = max(1, min(int(bin_count), len(valid)))
    bins: List[Mapping[str, float]] = []
    for index in range(count):
        start = index * len(valid) // count
        end = (index + 1) * len(valid) // count
        group = valid[start:max(start + 1, end)]
        bins.append({
            "z": _median([item[0] for item in group]),
            "x": _median([item[1] for item in group]),
            "y": _median([item[2] for item in group]),
            "count": float(len(group)),
            "residual_x": _mad([item[1] for item in group]),
            "residual_y": _mad([item[2] for item in group]),
        })
    return tuple(bins)


def estimate_neutral(samples: Sequence[Mapping[str, Any]]) -> NeutralEstimate:
    values = [_raw_xyz(row) for row in samples if _as_bool(row.get("position_valid", row.get("positionValid", True)), True) and not _as_bool(row.get("report_error", False), False)]
    if not values:
        raise ValueError("neutral capture contains no valid XYZ samples")
    reference = tuple(_median([row[axis] for row in values]) for axis in range(3))
    spread = tuple(_mad([row[axis] for row in values], reference[axis]) for axis in range(3))
    return NeutralEstimate(reference_xyz=reference, mad_xyz=spread, valid_ratio=len(values) / max(1, len(samples)))


def build_profile(
    neutral_samples: Sequence[Mapping[str, Any]],
    depth_samples: Sequence[Mapping[str, Any]],
    workspace_samples: Sequence[Mapping[str, Any]],
    metadata: Mapping[str, Any] | None = None,
) -> Tuple[HostCalibrationProfile, Dict[str, Any]]:
    """Build a fixed host profile only from explicit calibration captures."""
    neutral = estimate_neutral(neutral_samples)
    coupling = fit_z_coupling(depth_samples, bin_count=7)
    workspace_values = [_raw_to_q(_raw_xyz(row), HostCalibrationProfile()) for row in workspace_samples if _as_bool(row.get("position_valid", row.get("positionValid", True)), True)]
    if not workspace_values:
        raise ValueError("workspace capture contains no valid XYZ samples")
    workspace_min = tuple(min(row[axis] for row in workspace_values) for axis in range(3))
    workspace_max = tuple(max(row[axis] for row in workspace_values) for axis in range(3))
    # Keep the default application axes explicit. The musical pitch bounds are
    # fixed workspace coordinates, not this take's min/max.
    profile = HostCalibrationProfile(
        profile_id="mgc3130_host_" + _canonical_hash({"metadata": dict(metadata or {}), "neutral": neutral.reference_xyz, "coupling": coupling})[:12],
        raw_reference_xyz=(0.0, 0.0, 0.0),
        q_ref=(0.5, 0.5, 0.5),
        workspace_min=workspace_min,
        workspace_max=workspace_max,
        b_min=workspace_min[1] - 0.5,
        b_max=workspace_max[1] - 0.5,
        neutral_mad_xyz=tuple(value / RAW_MAX for value in neutral.mad_xyz),
        coupling_bins=coupling,
        coupling_reference_z=float(coupling[0]["z"]),
        coupling_confidence=1.0 if len(coupling) >= 3 else 0.5,
        coupling_model="piecewise_median",
    )
    diagnostics = {
        "profile_id": profile.profile_id,
        "profile_hash": profile.profile_hash,
        "metadata": dict(metadata or {}),
        "neutral": asdict(neutral),
        "coupling_bins": [dict(item) for item in coupling],
        "workspace_min": workspace_min,
        "workspace_max": workspace_max,
    }
    return profile, diagnostics

