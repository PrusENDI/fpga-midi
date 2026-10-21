import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent


class PcReceiverContractTests(unittest.TestCase):
    def test_project_and_source_exist(self):
        self.assertTrue((ROOT / "mgc3130_receiver.cpp").is_file())
        self.assertTrue((ROOT / "mgc3130_receiver.vcxproj").is_file())

    def test_jsonl_fixture_has_audio_boundary_fields(self):
        fixture = ROOT / "fixtures" / "sample.jsonl"
        records = [json.loads(line) for line in fixture.read_text().splitlines() if line.strip()]
        self.assertEqual(records[0]["type"], "ready")
        sample = records[1]
        for field in ("type", "timestamp_ms", "frame", "x", "y", "z", "gesture", "touch_flags"):
            self.assertIn(field, sample)
        self.assertEqual(sample["type"], "position")

    def test_fixture_exposes_quality_contract_without_fabricating_sdk_bits(self):
        sample = json.loads((ROOT / "fixtures" / "sample.jsonl").read_text().splitlines()[1])
        for field in ("sequence", "timestamp_raw", "logical_time_ms", "position_valid", "xyz_valid", "report_error", "clipping", "environmental_noise", "calibration_reason", "sequence_gap", "quality_known"):
            self.assertIn(field, sample)
        self.assertFalse(sample["quality_known"])

    def test_msbuild_project_is_win32(self):
        project = (ROOT / "mgc3130_receiver.vcxproj").read_text(encoding="utf-8")
        self.assertIn("Static-Release|Win32", project)
        self.assertIn("gestic.lib", project)


if __name__ == "__main__":
    unittest.main()
