"""PC reference analyzer for the MGC3130 Ambient capture-and-loop design.

The module deliberately uses only the Python standard library.  It consumes
already decoded MGC3130 position reports (the SDK/FPGA boundary) and emits a
small, inspectable event table rather than audio.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple


Point = Tuple[float, float]
Sample = Dict[str, float]


def _bool(value: object) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _number(value: object) -> int:
    text = str(value).strip()
    return int(text, 0) if text.lower().startswith("0x") else int(float(text))


def load_samples_csv(path: Path | str) -> List[Sample]:
    """Load valid XYZ reports from an FPGA/SDK-compatible CSV capture."""
    rows: List[Sample] = []
    with Path(path).open(newline="", encoding="utf-8-sig") as handle:
        for raw in csv.DictReader(handle):
            if "report_valid" in raw and not _bool(raw.get("report_valid")):
                continue
            if "xyz_valid" in raw and not _bool(raw.get("xyz_valid")):
                continue
            if "report_error" in raw and _bool(raw.get("report_error")):
                continue
            try:
                rows.append(
                    {
                        "timestamp": float(raw.get("timestamp", len(rows))),
                        "x": float(_number(raw["x"])),
                        "y": float(_number(raw["y"])),
                        "z": float(_number(raw.get("z", 0))),
                    }
                )
            except (KeyError, TypeError, ValueError):
                continue
    rows.sort(key=lambda row: row["timestamp"])
    return rows


def load_samples_jsonl(path: Path | str) -> List[Sample]:
    """Load position records emitted by pc_receiver/mgc3130_receiver.exe."""
    rows: List[Sample] = []
    with Path(path).open(encoding="utf-8") as handle:
        for line in handle:
            try:
                raw = json.loads(line)
                if raw.get("type") != "position":
                    continue
                rows.append(
                    {
                        "timestamp": float(raw.get("timestamp_ms", len(rows))),
                        "x": float(raw["x"]),
                        "y": float(raw["y"]),
                        "z": float(raw.get("z", 0)),
                    }
                )
            except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                continue
    rows.sort(key=lambda row: row["timestamp"])
    return rows


def isotonic_non_decreasing(values: Sequence[float]) -> List[float]:
    """Return the least-squares non-decreasing isotonic regression."""
    blocks: List[List[float]] = []
    for value in values:
        blocks.append([float(value), 1.0])
        while len(blocks) >= 2 and blocks[-2][0] > blocks[-1][0]:
            right = blocks.pop()
            left = blocks.pop()
            total = left[1] + right[1]
            blocks.append([(left[0] * left[1] + right[0] * right[1]) / total, total])
    result: List[float] = []
    for value, count in blocks:
        result.extend([value] * int(count))
    return result


def _smooth(values: Sequence[float]) -> List[float]:
    """Five-point quadratic Savitzky-Golay smoothing without SciPy."""
    if len(values) < 5:
        return list(values)
    result = list(values)
    coefficients = (-3.0, 12.0, 17.0, 12.0, -3.0)
    for index in range(2, len(values) - 2):
        result[index] = sum(c * values[index + offset] for c, offset in zip(coefficients, (-2, -1, 0, 1, 2))) / 35.0
    return result


def _normalize(values: Sequence[float]) -> List[float]:
    if not values:
        return []
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return [0.5] * len(values)
    return [(value - lo) / (hi - lo) for value in values]


def _arc_resample(points: Sequence[Point], count: int) -> List[Point]:
    if not points:
        return []
    if len(points) == 1:
        return [points[0]] * count
    distances = [0.0]
    for first, second in zip(points, points[1:]):
        distances.append(distances[-1] + math.hypot(second[0] - first[0], second[1] - first[1]))
    total = distances[-1]
    if total < 1e-9:
        return [points[0]] * count
    result: List[Point] = []
    cursor = 0
    for sample_index in range(count):
        target = total * sample_index / max(1, count - 1)
        while cursor + 1 < len(distances) and distances[cursor + 1] < target:
            cursor += 1
        if cursor + 1 == len(distances):
            result.append(points[-1])
            continue
        span = distances[cursor + 1] - distances[cursor]
        fraction = 0.0 if span < 1e-9 else (target - distances[cursor]) / span
        x0, y0 = points[cursor]
        x1, y1 = points[cursor + 1]
        result.append((x0 + fraction * (x1 - x0), y0 + fraction * (y1 - y0)))
    return result


def preprocess(samples: Sequence[Sample], count: int = 400) -> Dict[str, List[float]]:
    if len(samples) < 2:
        raise ValueError("at least two valid XYZ reports are required")
    x = _normalize([sample["x"] for sample in samples])
    y = _normalize([sample["y"] for sample in samples])
    resampled = _arc_resample(list(zip(x, y)), count)
    monotonic_x = isotonic_non_decreasing([point[0] for point in resampled])
    smoothed_y = _smooth([point[1] for point in resampled])
    contour = [1.0 - value for value in _normalize(smoothed_y)]
    return {
        "x": _normalize(monotonic_x),
        "y": _normalize(smoothed_y),
        "contour": contour,
    }


def _point_line_distance(point: Point, start: Point, end: Point) -> float:
    dx, dy = end[0] - start[0], end[1] - start[1]
    if abs(dx) < 1e-12 and abs(dy) < 1e-12:
        return math.hypot(point[0] - start[0], point[1] - start[1])
    ratio = ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / (dx * dx + dy * dy)
    ratio = max(0.0, min(1.0, ratio))
    return math.hypot(point[0] - (start[0] + ratio * dx), point[1] - (start[1] + ratio * dy))


def _douglas_peucker(points: Sequence[Point], epsilon: float) -> List[int]:
    if len(points) <= 2:
        return list(range(len(points)))
    keep = {0, len(points) - 1}
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        distance, split = 0.0, None
        for index in range(start + 1, end):
            current = _point_line_distance(points[index], points[start], points[end])
            if current > distance:
                distance, split = current, index
        if split is not None and distance > epsilon:
            keep.add(split)
            stack.extend(((start, split), (split, end)))
    return sorted(keep)


def quantize_onsets(positions: Iterable[float], loop_ticks: int = 128) -> List[int]:
    """Quantize normalized onset positions with accumulated rounding error."""
    residual = 0.0
    result: List[int] = []
    for position in positions:
        target = max(0.0, min(1.0, float(position))) * (loop_ticks - 1)
        quantized = int(round(target + residual))
        residual += target - quantized
        quantized = max(0, min(loop_ticks - 1, quantized))
        if not result or quantized > result[-1]:
            result.append(quantized)
    return result


PENTATONIC = (9, 0, 2, 4, 7)  # A minor: A, C, D, E, G


def _scale_notes(low: int = 57, high: int = 81) -> List[int]:
    return [note for note in range(low, high + 1) if note % 12 in PENTATONIC]


def _nearest_scale(note: float, candidates: Sequence[int]) -> int:
    return min(candidates, key=lambda candidate: (abs(candidate - note), candidate))


def _viterbi(contour: Sequence[float], ticks: Sequence[int], candidates: Sequence[int], high_tick: int) -> List[int]:
    if not ticks:
        return []
    desired = [min(candidates) + value * (max(candidates) - min(candidates)) for value in contour]
    states: List[Dict[int, Tuple[float, int | None]]] = []
    for index, tick in enumerate(ticks):
        current: Dict[int, Tuple[float, int | None]] = {}
        for note in candidates:
            contour_cost = abs(note - desired[index]) / 12.0
            high_cost = 0.0
            if 0.65 * 127 <= high_tick <= 0.80 * 127 and abs(tick - high_tick) <= 8:
                high_cost = -0.75 * (note - min(candidates)) / max(1, max(candidates) - min(candidates))
            if index == 0:
                current[note] = (contour_cost + high_cost, None)
                continue
            best = min(
                states[-1].items(),
                key=lambda item: item[1][0] + 0.12 * abs(note - item[0]) + (0.5 if note == item[0] else 0.0),
            )
            current[note] = (contour_cost + high_cost + best[1][0] + 0.12 * abs(note - best[0]) + (0.5 if note == best[0] else 0.0), best[0])
        states.append(current)
    final_note = min(candidates, key=lambda note: states[-1][note][0] + (0.0 if note % 12 == 9 else 100.0))
    result = [final_note]
    for index in range(len(states) - 1, 0, -1):
        previous = states[index][result[-1]][1]
        result.append(previous if previous is not None else result[-1])
    return list(reversed(result))


def _event(track: str, event_type: str, tick: int, **fields: int) -> Dict[str, int | str]:
    result: Dict[str, int | str] = {"track": track, "type": event_type, "tick": int(tick)}
    result.update(fields)
    return result


def _limit_onsets(ticks: Sequence[int], loop_ticks: int, limit: int = 16) -> List[int]:
    if len(ticks) <= limit:
        return list(ticks)
    required = {ticks[0], ticks[-1], int(round(0.72 * (loop_ticks - 1)))}
    required = {tick for tick in required if tick in ticks}
    remaining = [tick for tick in ticks if tick not in required]
    slots = max(0, limit - len(required))
    selected = [remaining[int(index * len(remaining) / max(1, slots))] for index in range(slots)] if slots else []
    return sorted(set(selected) | required)[:limit]


def ambient_analyze(samples: Sequence[Sample], *, seed: int = 0, loop_ticks: int = 128) -> Dict[str, object]:
    del seed  # deterministic first reference implementation; kept in the public API for later layer variation.
    processed = preprocess(samples)
    points = list(zip(processed["x"], processed["contour"]))
    vertices = _douglas_peucker(points, epsilon=0.035)
    positions = [processed["x"][index] for index in vertices]
    ticks = quantize_onsets(positions, loop_ticks=loop_ticks)
    if len(ticks) < 3:
        ticks = quantize_onsets((0.0, 0.25, 0.5, 0.72, 1.0), loop_ticks=loop_ticks)
    high_tick = int(round(0.72 * (loop_ticks - 1)))
    if not any(abs(tick - high_tick) <= 2 for tick in ticks):
        ticks.append(high_tick)
        ticks = sorted(set(ticks))
    ticks = _limit_onsets(ticks, loop_ticks)
    contour_at_onset = [processed["contour"][min(len(processed["contour"]) - 1, int(round(tick / max(1, loop_ticks - 1) * (len(processed["contour"]) - 1))))] for tick in ticks]
    candidates = _scale_notes()
    notes = _viterbi(contour_at_onset, ticks, candidates, high_tick)
    if notes:
        high_candidates = [index for index, tick in enumerate(ticks) if 0.65 * (loop_ticks - 1) <= tick <= 0.80 * (loop_ticks - 1)]
        high_index = min(high_candidates or range(len(ticks)), key=lambda index: abs(ticks[index] - high_tick))
        notes[high_index] = max(candidates)
        second_high = max(note for note in candidates if note < max(candidates))
        for index, note in enumerate(notes):
            if index != high_index and note >= max(candidates):
                notes[index] = second_high
        notes[-1] = _nearest_scale(69, candidates)
    events: List[Dict[str, int | str]] = []
    for index, (tick, note) in enumerate(zip(ticks, notes)):
        end = ticks[index + 1] if index + 1 < len(ticks) else min(loop_ticks, tick + 16)
        events.append(_event("lead", "note_on", tick, duration=max(1, end - tick), note=note, velocity=92))
    for tick in range(0, loop_ticks, 16):
        events.append(_event("bass", "note_on", tick, duration=16, note=45, velocity=60))
    for tick in range(0, loop_ticks, 32):
        for note in (57, 60, 64):
            events.append(_event("pad", "note_on", tick, duration=32, note=note, velocity=38))
    for tick, note in ((0, 36), (32, 38), (64, 36), (96, 38)):
        events.append(_event("drums", "note_on", tick, duration=1, note=note, velocity=80))
    high_index = min(
        (index for index, tick in enumerate(ticks) if 0.65 * (loop_ticks - 1) <= tick <= 0.80 * (loop_ticks - 1)),
        key=lambda index: abs(ticks[index] - high_tick),
        default=0,
    )
    high_ratio = (ticks[high_index] if ticks else high_tick) / max(1, loop_ticks - 1)
    return {
        "version": 1,
        "style": "ambient",
        "loop_ticks": loop_ticks,
        "events": sorted(events, key=lambda event: (int(event["tick"]), str(event["track"]), int(event.get("note", 0)))),
        "diagnostics": {
            "input_reports": len(samples),
            "resampled_points": len(processed["contour"]),
            "onsets": len(ticks),
            "high_point_ratio": high_ratio,
            "scale": "A_minor_pentatonic",
            "vamp": "Am_8_bars",
            "fx": {"reverb": "large", "delay_ms": 600, "filter_lfo": "slow"},
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate an Ambient event table from MGC3130 XYZ CSV")
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    loader = load_samples_jsonl if args.input.suffix.lower() == ".jsonl" else load_samples_csv
    samples = loader(args.input)
    if len(samples) < 2:
        parser.error("input must contain at least two position reports")
    result = ambient_analyze(samples)
    text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.output:
        args.output.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
