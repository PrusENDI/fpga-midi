import json
import tempfile
import unittest
from pathlib import Path

from tools.host_xyz_filter import build_identity_profile
from tools.replay_host_filter import replay_capture


class ReplayHostFilterTests(unittest.TestCase):
    def test_replay_is_deterministic_and_preserves_raw_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "capture.jsonl"
            source.write_text("\n".join(json.dumps({"type": "position", "timestamp_ms": i * 5, "x": 20000 + i * 100, "y": 30000 + i * 200, "z": 25000, "position_valid": True, "custom": "keep"}) for i in range(12)), encoding="utf-8")
            profile = build_identity_profile()
            first = replay_capture(source, profile)
            second = replay_capture(source, profile)
            self.assertEqual(first, second)
            self.assertEqual(first["filtered_frames"][0]["custom"], "keep")
            self.assertEqual(first["diagnostics"]["profile_hash"], profile.profile_hash)


if __name__ == "__main__":
    unittest.main()
