#!/usr/bin/env python3
"""Report frame timing and drops for a Lead capture.

Accepts the two capture shapes used in this repository:

* ``jsonl`` — lines emitted by ``pc_receiver/mgc3130_receiver`` (``timestamp_ms``,
  ``sequence``, ``sequence_gap``, optional ``position_valid``);
* ``csv`` — columns ``index,time_ms,delta_ms,x,y,z,gesture,position_valid``
  written by ``tools/capture_mgc3130.py``.

The point is to separate three failure modes that look identical in the UI:
a genuinely slow sensor stream, transport stalls, and consumer-side backlog.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Dict, List, Sequence


def _percentile(values: Sequence[float], ratio: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round(ratio * (len(ordered) - 1)))))
    return float(ordered[index])


def load_records(path: Path) -> List[Dict[str, float]]:
    suffix = path.suffix.lower()
    if suffix == ".jsonl":
        records: List[Dict[str, float]] = []
        with path.open(encoding="utf-8-sig") as handle:
            for line in handle:
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(value, dict) or value.get("type") != "position":
                    continue
                records.append({
                    "time_ms": float(value.get("timestamp_ms", len(records))),
                    "sequence_gap": float(value.get("sequence_gap") or 0.0),
                })
        return records
    if suffix == ".csv":
        records = []
        with path.open(encoding="utf-8-sig", newline="") as handle:
            for row in csv.DictReader(handle):
                try:
                    records.append({"time_ms": float(row["time_ms"]), "sequence_gap": 0.0})
                except (KeyError, TypeError, ValueError):
                    continue
        return records
    raise SystemExit(f"unsupported capture type: {path.name}")


def summarise(records: Sequence[Dict[str, float]]) -> Dict[str, object]:
    if len(records) < 2:
        return {"frames": len(records)}
    times = [record["time_ms"] for record in records]
    gaps = [times[index + 1] - times[index] for index in range(len(times) - 1)]
    span_s = (times[-1] - times[0]) / 1000.0
    skips = [record["sequence_gap"] for record in records]
    hist: Dict[float, int] = {}
    for gap in gaps:
        key = round(gap, 1)
        hist[key] = hist.get(key, 0) + 1
    return {
        "frames": len(records),
        "span_s": span_s,
        "rate_hz": len(records) / span_s if span_s > 0 else 0.0,
        "gap_p50_ms": _percentile(gaps, 0.50),
        "gap_p95_ms": _percentile(gaps, 0.95),
        "gap_max_ms": max(gaps),
        "long_gaps": sum(1 for gap in gaps if gap > 250.0),
        "total_skipped": int(sum(skips)),
        "frames_with_skip": sum(1 for skip in skips if skip > 0),
        "top_gaps": sorted(hist.items(), key=lambda item: -item[1])[:5],
    }


def report(name: str, stats: Dict[str, object]) -> str:
    if stats.get("frames", 0) < 2:
        return f"{name}: only {stats.get('frames', 0)} position frame(s), nothing to measure"
    return (
        f"{name}\n"
        f"  frames            {stats['frames']}\n"
        f"  span              {stats['span_s']:.2f} s\n"
        f"  effective rate    {stats['rate_hz']:.1f} Hz\n"
        f"  frame gap p50/p95 {stats['gap_p50_ms']:.1f} / {stats['gap_p95_ms']:.1f} ms\n"
        f"  worst gap         {stats['gap_max_ms']:.1f} ms  ({stats['long_gaps']} gaps > 250 ms)\n"
        f"  SDK skipped       {stats['total_skipped']} frame(s) over {stats['frames_with_skip']} report(s)\n"
        f"  common gaps (ms)  {stats['top_gaps']}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help=".jsonl or .csv capture")
    args = parser.parse_args()
    records = load_records(args.capture)
    print(report(args.capture.name, summarise(records)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
