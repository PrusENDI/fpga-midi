"""Capture-and-loop orchestration for the MGC3130 PC receiver."""

from __future__ import annotations

import json
import argparse
import subprocess
import sys
from pathlib import Path
from typing import Dict, Iterable, List


TOOLS_DIR = Path(__file__).resolve().parents[1] / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from ambient_analyzer import ambient_analyze  # noqa: E402


class CaptureSession:
    def __init__(self, min_reports: int = 8) -> None:
        self.min_reports = min_reports
        self.samples: List[Dict[str, float]] = []
        self.started = False

    def accept(self, record: Dict[str, object]) -> None:
        if record.get("type") != "position":
            return
        try:
            sample = {
                "timestamp": float(record["timestamp_ms"]),
                "x": float(record["x"]),
                "y": float(record["y"]),
                "z": float(record.get("z", 0)),
            }
        except (KeyError, TypeError, ValueError):
            return
        self.samples.append(sample)
        self.started = True

    def finalize(self) -> Dict[str, object]:
        if len(self.samples) < self.min_reports:
            raise ValueError(f"capture has {len(self.samples)} reports; need at least {self.min_reports}")
        return ambient_analyze(self.samples)


def iter_jsonl(stream: Iterable[str]) -> Iterable[Dict[str, object]]:
    for line in stream:
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            yield value


def capture_stream(stream: Iterable[str], min_reports: int = 8) -> Dict[str, object]:
    session = CaptureSession(min_reports=min_reports)
    for record in iter_jsonl(stream):
        session.accept(record)
    return session.finalize()


def run_receiver(receiver: Path, raw_output: Path, event_output: Path, seconds: float = 0.0, min_reports: int = 8) -> Dict[str, object]:
    command = [str(receiver), "--output", str(raw_output), "--format", "jsonl"]
    if seconds > 0:
        command.extend(["--seconds", str(seconds)])
    raw_output.parent.mkdir(parents=True, exist_ok=True)
    session = CaptureSession(min_reports=min_reports)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=sys.stderr, text=True, encoding="utf-8")
    try:
        assert process.stdout is not None
        for line in process.stdout:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(record, dict):
                session.accept(record)
    except KeyboardInterrupt:
        process.terminate()
    finally:
        process.wait()
    result = session.finalize()
    event_output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture one MGC3130 phrase, then compile an Ambient Loop")
    parser.add_argument("--receiver", type=Path, default=Path(__file__).with_name("Static-Release") / "mgc3130_receiver.exe")
    parser.add_argument("--seconds", type=float, default=0.0, help="capture duration; 0 means until Ctrl+C")
    parser.add_argument("--raw-output", type=Path, default=Path("capture.jsonl"))
    parser.add_argument("--event-output", type=Path, default=Path("ambient_events.json"))
    parser.add_argument("--min-reports", type=int, default=8)
    args = parser.parse_args()
    try:
        result = run_receiver(args.receiver, args.raw_output, args.event_output, args.seconds, args.min_reports)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(result["diagnostics"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
