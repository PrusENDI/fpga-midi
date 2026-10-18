import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from mgc3130_calibration_protocol import FRAME_TYPE_METADATA, FRAME_TYPE_REPORT, encode_frame
from capture_mgc3130_calibration import process_capture


class CaptureToolTests(unittest.TestCase):
    def test_process_capture_writes_raw_csv_metadata_and_summary(self):
        metadata = encode_frame(FRAME_TYPE_METADATA, 0, 1, 0x30, 0, 0, 0, 0, 0, 0,
                                build_tag=0x12345678)
        report = encode_frame(FRAME_TYPE_REPORT, 2, 20, 0x13, 0x1000, 0x2000, 0x8000,
                              0x10, 0, 0x55, build_tag=0x12345678)
        with tempfile.TemporaryDirectory() as directory:
            summary = process_capture(metadata + report, directory, port="COM4", baud=115200)
            with open(os.path.join(directory, "samples.csv"), encoding="utf-8") as handle:
                csv_text = handle.read()
            with open(os.path.join(directory, "metadata.json"), encoding="utf-8") as handle:
                saved_metadata = json.load(handle)
            with open(os.path.join(directory, "summary.json"), encoding="utf-8") as handle:
                saved_summary = json.load(handle)
            self.assertEqual(summary["frames"], 2)
            self.assertEqual(saved_metadata["build_tag"], 0x12345678)
            self.assertIn("0x1000", csv_text)
            self.assertEqual(saved_summary["sequence_gaps"], 1)


if __name__ == "__main__":
    unittest.main()
