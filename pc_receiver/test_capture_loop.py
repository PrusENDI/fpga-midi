import unittest

from capture_loop import CaptureSession


class CaptureLoopTests(unittest.TestCase):
    def test_session_accumulates_position_reports_only(self):
        session = CaptureSession(min_reports=2)
        session.accept({"type": "ready"})
        session.accept({"type": "position", "timestamp_ms": 0, "frame": 0, "x": 0, "y": 100, "z": 10000})
        session.accept({"type": "status", "timestamp_ms": 1})
        session.accept({"type": "position", "timestamp_ms": 5, "frame": 1, "x": 100, "y": 200, "z": 10000})
        self.assertEqual(len(session.samples), 2)

    def test_finalize_generates_ambient_event_table(self):
        session = CaptureSession(min_reports=2)
        for index in range(80):
            session.accept(
                {
                    "type": "position",
                    "timestamp_ms": index * 5,
                    "frame": index,
                    "x": int(index * 65535 / 79),
                    "y": int((0.5 + 0.4 * ((index % 10) / 9)) * 65535),
                    "z": 12000,
                }
            )
        result = session.finalize()
        self.assertEqual(result["style"], "ambient")
        self.assertGreater(len(result["events"]), 0)

    def test_finalize_rejects_empty_take(self):
        session = CaptureSession(min_reports=2)
        with self.assertRaises(ValueError):
            session.finalize()


if __name__ == "__main__":
    unittest.main()
