"""Replay a real MGC3130 capture through a fixed host profile."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping

try:
    from .host_xyz_filter import HostCalibrationProfile, filter_capture
except ImportError:  # direct script execution
    from host_xyz_filter import HostCalibrationProfile, filter_capture


def load_capture(path: Path | str) -> List[Dict[str, Any]]:
    source = Path(path)
    if source.suffix.lower() == ".csv":
        with source.open(encoding="utf-8-sig", newline="") as handle:
            rows = list(csv.DictReader(handle))
        normalized: List[Dict[str, Any]] = []
        for row in rows:
            if row.get("x") is None or row.get("y") is None or row.get("z") is None:
                continue
            value = dict(row)
            value["position_valid"] = value.get("position_valid", value.get("xyz_valid", value.get("report_valid", "true")))
            value["xyz_valid"] = value.get("xyz_valid", value.get("report_valid", "true"))
            value["report_error"] = value.get("report_error", "false")
            value["gap_before"] = value.get("gap_before", "0")
            value["timestamp_ms"] = value.get("timestamp_ms", value.get("timestamp", "0"))
            normalized.append(value)
        return normalized
    rows: List[Dict[str, Any]] = []
    with source.open(encoding="utf-8-sig") as handle:
        for line in handle:
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict) and value.get("type", "position") == "position":
                rows.append(value)
    return rows


def replay_capture(path: Path | str, profile: HostCalibrationProfile) -> Dict[str, Any]:
    samples = load_capture(path)
    result = filter_capture(samples, profile)
    return {
        "profile": profile.to_dict(),
        "diagnostics": result.diagnostics,
        "filtered_frames": result.frames,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Replay an MGC3130 capture through a fixed host profile")
    parser.add_argument("capture", type=Path)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    profile = HostCalibrationProfile.from_dict(json.loads(args.profile.read_text(encoding="utf-8")))
    result = replay_capture(args.capture, profile)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, ensure_ascii=False, default=list) + "\n", encoding="utf-8")
    print(json.dumps(result["diagnostics"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
