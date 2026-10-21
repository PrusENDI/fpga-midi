import csv
import json
import tempfile
import unittest
from pathlib import Path

from ambient_analyzer import (
    ambient_analyze,
    isotonic_non_decreasing,
    load_samples_csv,
    load_samples_jsonl,
    quantize_onsets,
)


class AmbientAnalyzerTests(unittest.TestCase):
    def test_isotonic_regression_removes_backward_x_steps(self):
        result = isotonic_non_decreasing([0.0, 0.8, 0.4, 0.9])
        self.assertEqual(len(result), 4)
        self.assertEqual(result, sorted(result))
        self.assertAlmostEqual(result[1], result[2])

    def test_loader_keeps_only_valid_position_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "samples.csv"
            with path.open("w", newline="") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=["timestamp", "report_valid", "xyz_valid", "report_error", "x", "y", "z"],
                )
                writer.writeheader()
                writer.writerow({"timestamp": "10", "report_valid": "True", "xyz_valid": "True", "report_error": "False", "x": "0x1000", "y": "0x2000", "z": "0x3000"})
                writer.writerow({"timestamp": "20", "report_valid": "True", "xyz_valid": "False", "report_error": "False", "x": "0x4000", "y": "0x5000", "z": "0x6000"})
            rows = load_samples_csv(path)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["x"], 0x1000)

    def test_jsonl_loader_accepts_pc_receiver_position_stream(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "samples.jsonl"
            path.write_text(
                '{"type":"ready","schema":1}\n'
                '{"type":"position","timestamp_ms":5,"frame":0,"x":100,"y":200,"z":300}\n'
                '{"type":"status","message":"ignored"}\n',
                encoding="utf-8",
            )
            rows = load_samples_jsonl(path)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["y"], 200)

    def test_onsets_use_loop_grid_with_cumulative_drift_compensation(self):
        ticks = quantize_onsets([0.03, 0.26, 0.51, 0.76], loop_ticks=128)
        self.assertEqual(ticks[0], 4)
        self.assertTrue(all(0 <= tick < 128 for tick in ticks))
        self.assertEqual(ticks, sorted(set(ticks)))

    def test_ambient_output_has_constrained_lead_and_support_tracks(self):
        samples = []
        for i in range(240):
            x = int(i * 65535 / 239)
            y = int((0.5 + 0.45 * __import__("math").sin(i / 18.0)) * 65535)
            samples.append({"timestamp": i * 5000, "x": x, "y": y, "z": 18000})
        result = ambient_analyze(samples, seed=7)
        events = result["events"]
        lead = [event for event in events if event["track"] == "lead" and event["type"] == "note_on"]
        self.assertGreaterEqual(len(lead), 3)
        self.assertTrue(all(event["note"] % 12 in {0, 2, 4, 7, 9} for event in lead))
        self.assertEqual(lead[-1]["note"] % 12, 9)
        self.assertTrue(any(event["track"] == "bass" for event in events))
        self.assertTrue(any(event["track"] == "pad" for event in events))
        self.assertTrue(any(event["track"] == "drums" for event in events))
        self.assertGreaterEqual(result["diagnostics"]["high_point_ratio"], 0.65)
        self.assertLessEqual(result["diagnostics"]["high_point_ratio"], 0.80)

    def test_lead_density_is_bounded_for_noisy_long_capture(self):
        samples = []
        for i in range(1200):
            x = int(i * 65535 / 1199)
            y = int((0.5 + 0.48 * __import__("math").sin(i / 2.7)) * 65535)
            samples.append({"timestamp": i * 5000, "x": x, "y": y, "z": 18000})
        result = ambient_analyze(samples)
        lead = [event for event in result["events"] if event["track"] == "lead"]
        self.assertLessEqual(len(lead), 16)
        self.assertGreaterEqual(result["diagnostics"]["high_point_ratio"], 0.65)
        self.assertLessEqual(result["diagnostics"]["high_point_ratio"], 0.80)


if __name__ == "__main__":
    unittest.main()
