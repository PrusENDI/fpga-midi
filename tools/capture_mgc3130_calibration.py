"""Capture and decode raw MGC3130 calibration frames from COM4."""

from __future__ import annotations

import argparse
import csv
import json
import os
import time
from datetime import datetime, timezone
from typing import Dict

from mgc3130_calibration_protocol import (
    FRAME_TYPE_METADATA,
    FRAME_TYPE_REPORT,
    decode_frames,
)


def process_capture(data: bytes, output_dir: str, *, port: str, baud: int) -> Dict[str, int]:
    os.makedirs(output_dir, exist_ok=True)
    with open(os.path.join(output_dir, "frames.bin"), "wb") as handle:
        handle.write(data)
    frames = decode_frames(data)
    metadata = next((frame for frame in frames if frame["frame_type"] == FRAME_TYPE_METADATA), None)
    reports = [frame for frame in frames if frame["frame_type"] == FRAME_TYPE_REPORT]
    with open(os.path.join(output_dir, "samples.csv"), "w", newline="", encoding="utf-8") as handle:
        fields = ["frame_type", "sequence", "timestamp", "flags", "report_valid", "xyz_valid",
                  "report_error", "touch_valid", "mgc_ready", "reader_busy", "capture_overflow",
                  "x", "y", "z", "gesture", "error_code", "touch_info", "build_tag", "gap_before"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for frame in frames:
            writer.writerow({field: (f"0x{frame[field]:04X}" if field in ("x", "y", "z") else frame.get(field, ""))
                             for field in fields})
    metadata_json = {
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "port": port,
        "baud": baud,
        "protocol_version": metadata["version"] if metadata else None,
        "build_tag": metadata["build_tag"] if metadata else None,
    }
    with open(os.path.join(output_dir, "metadata.json"), "w", encoding="utf-8") as handle:
        json.dump(metadata_json, handle, indent=2)
    sequence_gaps = sum(frame.get("gap_before", 0) for frame in frames)
    summary = {
        "frames": len(frames),
        "reports": len(reports),
        "metadata_frames": sum(frame["frame_type"] == FRAME_TYPE_METADATA for frame in frames),
        "sequence_gaps": sequence_gaps,
        "crc_errors": frames[-1].get("crc_errors", 0) if frames else 0,
        "x_min": min((frame["x"] for frame in reports), default=None),
        "x_max": max((frame["x"] for frame in reports), default=None),
        "y_min": min((frame["y"] for frame in reports), default=None),
        "y_max": max((frame["y"] for frame in reports), default=None),
        "z_min": min((frame["z"] for frame in reports), default=None),
        "z_max": max((frame["z"] for frame in reports), default=None),
    }
    with open(os.path.join(output_dir, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--seconds", type=float, default=60.0)
    parser.add_argument("--out", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    args = parser.parse_args()
    try:
        import serial
    except ImportError as exc:
        raise SystemExit("pyserial is required for live capture: python -m pip install pyserial") from exc
    with serial.Serial(args.port, args.baud, timeout=0.2) as connection:
        deadline = time.monotonic() + args.seconds
        captured = bytearray()
        while time.monotonic() < deadline:
            captured.extend(connection.read(4096))
    summary = process_capture(bytes(captured), args.out, port=args.port, baud=args.baud)
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
