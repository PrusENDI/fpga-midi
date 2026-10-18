import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))

from mgc3130_calibration_protocol import (
    FRAME_LENGTH,
    FRAME_TYPE_METADATA,
    FRAME_TYPE_REPORT,
    decode_frames,
    encode_frame,
)


class CalibrationProtocolTests(unittest.TestCase):
    def test_round_trip_metadata_and_report(self):
        metadata = encode_frame(FRAME_TYPE_METADATA, 0, 0x12345678, 0x30,
                                0, 0, 0, 0, 0, 0, build_tag=0x424C3031)
        report = encode_frame(FRAME_TYPE_REPORT, 7, 0x12345699, 0x1B,
                              0x1111, 0x2222, 0xD5F4, 0x5A, 3,
                              0x01020304, build_tag=0x424C3031)
        self.assertEqual(len(metadata), FRAME_LENGTH)
        frames = decode_frames(metadata + report)
        self.assertEqual(len(frames), 2)
        self.assertEqual(frames[1]["sequence"], 7)
        self.assertEqual(frames[1]["x"], 0x1111)
        self.assertEqual(frames[1]["z"], 0xD5F4)
        self.assertEqual(frames[1]["touch_info"], 0x01020304)
        self.assertEqual(frames[1]["gap_before"], 6)

    def test_crc_rejection_and_resynchronization(self):
        good = encode_frame(FRAME_TYPE_REPORT, 1, 2, 0, 3, 4, 5, 6, 7, 8)
        corrupt = bytearray(good)
        corrupt[15] ^= 0x80
        next_frame = encode_frame(FRAME_TYPE_REPORT, 2, 3, 0, 9, 10, 11, 12, 13, 14)
        frames = decode_frames(b"garbage" + bytes(corrupt) + b"noise" + next_frame)
        self.assertEqual([item["sequence"] for item in frames], [2])
        self.assertEqual(frames[0]["crc_errors"], 1)


if __name__ == "__main__":
    unittest.main()
