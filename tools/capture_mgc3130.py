"""Capture MGC3130 ASCII reports and create replay files for Gowin simulation.

The FPGA debug UART emits one report per line, for example::

    TS=0 M=1 S=1 C=1 V=31 E=00 K=0 X=A4E3 Y=CBDC Z=1161 G=00 P=1 D=00000000 F=0117 L=18

Only reports with P=1, E=00 and K=0 are written to the replay files.  The
hex file packs X, Y, Z, gesture and valid into one 64-bit word:

    [63:48] X [47:32] Y [31:16] Z [15:8] G [7:1] reserved [0] VALID

It can be loaded with ``$readmemh`` in a Verilog testbench.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, Optional


REPORT_RE = re.compile(r"([A-Za-z][A-Za-z0-9]*)=([0-9A-Fa-f]+)")
REQUIRED_FIELDS = ("P", "E", "K", "X", "Y", "Z", "G")


def parse_report_line_detail(line: str):
    """Parse and validate one UART report.

    Returns a normalized report dictionary for valid XYZ records, otherwise
    ``None``.  Values are parsed as hexadecimal, matching the FPGA formatter.
    Decimal-only values have the same numeric interpretation for the fields
    used here.
    """
    fields = {key: int(value, 16) for key, value in REPORT_RE.findall(line)}
    if any(key not in fields for key in REQUIRED_FIELDS):
        return None, "missing-field"
    if fields["P"] != 1 or fields["E"] != 0 or fields["K"] != 0:
        if fields["P"] != 1:
            return None, f"P={fields['P']:X}"
        if fields["E"] != 0:
            return None, f"E={fields['E']:X}"
        return None, f"K={fields['K']:X}"
    if any(fields[key] < 0 or fields[key] > 0xFFFF for key in ("X", "Y", "Z")):
        return None, "coordinate-range"
    if fields["G"] > 0xFF:
        return None, "gesture-range"
    return {
        "x": fields["X"],
        "y": fields["Y"],
        "z": fields["Z"],
        "gesture": fields["G"],
        "position_valid": 1,
    }, "valid"


def parse_report_line(line: str) -> Optional[Dict[str, int]]:
    """Parse one valid report, retaining the original simple API."""
    report, _reason = parse_report_line_detail(line)
    return report


def pack_replay_word(report: Dict[str, int]) -> str:
    """Return one fixed-width 64-bit ``$readmemh`` word."""
    word = (
        (report["x"] << 48)
        | (report["y"] << 32)
        | (report["z"] << 16)
        | (report["gesture"] << 8)
        | report["position_valid"]
    )
    return f"{word:016X}"


def _default_prefix() -> Path:
    stamp = datetime.now().strftime("mgc3130_capture_%Y%m%d_%H%M%S")
    return Path(stamp)


def capture(port: str, baud: int, prefix: Path, duration: Optional[float],
            max_records: Optional[int], timeout: float) -> Dict[str, object]:
    """Capture reports until duration, record count, or Ctrl+C is reached."""
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError("需要 pyserial：python -m pip install pyserial") from exc

    prefix.parent.mkdir(parents=True, exist_ok=True)
    csv_path = prefix.with_suffix(".csv")
    hex_path = prefix.with_suffix(".hex")
    summary_path = prefix.with_suffix(".json")
    raw_path = prefix.with_suffix(".raw.log")
    start = time.monotonic()
    last_time: Optional[float] = None
    records = 0
    total_lines = 0
    invalid_lines = 0
    reject_reasons = {}
    intervals_ms = []
    mins = {key: 0xFFFF for key in ("x", "y", "z")}
    maxs = {key: 0 for key in ("x", "y", "z")}

    with serial.Serial(port, baudrate=baud, timeout=timeout) as ser, \
            csv_path.open("w", newline="", encoding="utf-8") as csv_file, \
            hex_path.open("w", encoding="ascii") as hex_file, \
            raw_path.open("w", encoding="utf-8") as raw_file:
        writer = csv.DictWriter(
            csv_file,
            fieldnames=["index", "time_ms", "delta_ms", "x", "y", "z",
                        "gesture", "position_valid"],
        )
        writer.writeheader()
        print(f"opened {port} at {baud} baud", flush=True)
        print(f"CSV: {csv_path}", flush=True)
        print(f"HEX: {hex_path}  (X Y Z G VALID, 64-bit)", flush=True)
        print(f"RAW: {raw_path}", flush=True)
        try:
            while True:
                elapsed = time.monotonic() - start
                if duration is not None and elapsed >= duration:
                    break
                if max_records is not None and records >= max_records:
                    break
                raw = ser.readline()
                if not raw:
                    continue
                total_lines += 1
                line = raw.decode("ascii", errors="replace").strip()
                report, reason = parse_report_line_detail(line)
                raw_file.write(f"{total_lines:06d} {reason}: {line}\n")
                raw_file.flush()
                if report is None:
                    invalid_lines += 1
                    reject_reasons[reason] = reject_reasons.get(reason, 0) + 1
                    if invalid_lines <= 10:
                        print(f"filtered[{reason}]: {line}", flush=True)
                    continue
                now = time.monotonic()
                time_ms = (now - start) * 1000.0
                delta_ms = ""
                if last_time is not None:
                    delta = (now - last_time) * 1000.0
                    intervals_ms.append(delta)
                    delta_ms = f"{delta:.3f}"
                last_time = now
                row = {
                    "index": records,
                    "time_ms": f"{time_ms:.3f}",
                    "delta_ms": delta_ms,
                    "x": f"{report['x']:04X}",
                    "y": f"{report['y']:04X}",
                    "z": f"{report['z']:04X}",
                    "gesture": f"{report['gesture']:02X}",
                    "position_valid": report["position_valid"],
                }
                writer.writerow(row)
                hex_file.write(pack_replay_word(report) + "\n")
                csv_file.flush()
                hex_file.flush()
                for key in ("x", "y", "z"):
                    mins[key] = min(mins[key], report[key])
                    maxs[key] = max(maxs[key], report[key])
                records += 1
                if records == 1 or records % 50 == 0:
                    print(f"valid={records} last={pack_replay_word(report)}", flush=True)
        except KeyboardInterrupt:
            print("stopped by Ctrl+C", flush=True)

    summary = {
        "port": port,
        "baud": baud,
        "total_lines": total_lines,
        "valid_reports": records,
        "invalid_or_filtered_lines": invalid_lines,
        "filter_reasons": reject_reasons,
        "coordinate_min": mins if records else None,
        "coordinate_max": maxs if records else None,
        "interval_ms": {
            "count": len(intervals_ms),
            "min": min(intervals_ms) if intervals_ms else None,
            "max": max(intervals_ms) if intervals_ms else None,
            "average": (sum(intervals_ms) / len(intervals_ms)) if intervals_ms else None,
        },
        "csv": str(csv_path),
        "hex": str(hex_path),
        "raw_log": str(raw_path),
    }
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2), flush=True)
    print(f"summary: {summary_path}", flush=True)
    return summary


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="采集 MGC3130 UART ASCII XYZ 报告并生成 Gowin 仿真回放文件"
    )
    parser.add_argument("port", help="串口，例如 COM4")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--duration", type=float, default=None,
                        help="采集秒数；省略则按 Ctrl+C 停止")
    parser.add_argument("--max-records", type=int, default=None)
    parser.add_argument("--timeout", type=float, default=0.2,
                        help="串口读超时秒数")
    parser.add_argument("--output-prefix", type=Path, default=None,
                        help="输出前缀；默认当前目录带时间戳的 mgc3130_capture_...")
    args = parser.parse_args(argv)
    prefix = args.output_prefix or _default_prefix()
    try:
        capture(args.port, args.baud, prefix, args.duration,
                args.max_records, args.timeout)
    except (OSError, RuntimeError) as exc:
        print(f"capture failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
