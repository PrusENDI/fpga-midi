import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from loop_control_uart import command_for_ui, format_ack, Ack


class LoopControlUiHelpersTest(unittest.TestCase):
    def test_ui_action_maps_to_protocol_arguments(self):
        self.assertEqual(command_for_ui("live"), (1, 1, 0))
        self.assertEqual(command_for_ui("bpm", bpm=135), (2, 135, 0))
        self.assertEqual(command_for_ui("track", track=3), (3, 3, 0))
        self.assertEqual(command_for_ui("thresholds", enter=0x2000, exit=0x3000),
                         (13, 0x2000, 0x3000))

    def test_ack_text_contains_human_readable_status_and_mode(self):
        text = format_ack(Ack(opcode=0, status=1, data=5, sequence=7))
        self.assertIn("APPLIED", text)
        self.assertIn("PLAY", text)


if __name__ == "__main__":
    unittest.main()
