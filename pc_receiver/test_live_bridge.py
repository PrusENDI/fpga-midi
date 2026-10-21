import json
import unittest

from live_bridge import LiveNoteMapper, parse_receiver_line


class LiveBridgeTests(unittest.TestCase):
    def test_position_line_is_decoded_immediately(self):
        record = parse_receiver_line(
            '{"type":"position","timestamp_ms":10,"frame":3,"x":100,"y":32768,"z":12000}'
        )
        self.assertEqual(record["frame"], 3)
        self.assertEqual(record["y"], 32768)

    def test_touch_crossing_emits_note_on_without_waiting_for_phrase_end(self):
        mapper = LiveNoteMapper()
        first = mapper.process({"timestamp_ms": 10, "frame": 0, "x": 1, "y": 32768, "z": 18000})
        self.assertEqual(first["type"], "note_on")
        self.assertIn(first["note"] % 12, {0, 2, 4, 7, 9})

    def test_release_emits_note_off(self):
        mapper = LiveNoteMapper()
        mapper.process({"timestamp_ms": 10, "frame": 0, "x": 1, "y": 32768, "z": 12000})
        event = mapper.process({"timestamp_ms": 20, "frame": 1, "x": 1, "y": 32768, "z": 25000})
        self.assertEqual(event["type"], "note_off")


if __name__ == "__main__":
    unittest.main()
