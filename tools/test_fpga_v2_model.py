import unittest

from tools.v2_contract import V2Telemetry, encode_telemetry, crc16_ccitt
from pc_receiver.fpga_v2_model import (
    FakeTransport, V2Parameters, V2ProtocolError, apply_patch_delta,
    build_upload, decode_telemetry,
)
from pc_receiver.fpga_v2_ui import z_color


class FPGAV2ModelTests(unittest.TestCase):
    def test_parameter_delta_clamps_scalar_controls(self):
        params = V2Parameters(bpm=120, lambda_q16=65536, density_q16=32768)
        updated = apply_patch_delta(params, {"bpm": 999, "lambda_q16": -4,
                                             "density_q16": 70000})
        self.assertEqual(updated.bpm, 240)
        self.assertEqual(updated.lambda_q16, 0)
        self.assertEqual(updated.density_q16, 65535)
        self.assertEqual(params.bpm, 120)

    def test_telemetry_decode_matches_contract_and_rejects_crc(self):
        source = V2Telemetry(type=2, sequence=0x1234, x=-1, y=2, z=-32768,
                             note=60, flags=0x80, tick=0xFE,
                             voice_bitmap=0xAABBCCDD, fifo_level=7,
                             fault_code=9)
        frame = encode_telemetry(source)
        self.assertEqual(decode_telemetry(frame), source)
        with self.assertRaises(V2ProtocolError):
            decode_telemetry(frame[:-1] + bytes([frame[-1] ^ 1]))

    def test_upload_is_complete_blocked_big_endian_sequence(self):
        samples = [((i * 37) % 65536) - 32768 for i in range(1024)]
        frames = build_upload(2, samples, 7)
        self.assertEqual(len(frames), 1061)
        self.assertEqual(frames[0][2:5], bytes([2, 0x60, 0]))
        self.assertEqual(frames[1][2:5], bytes([2, 0x64, 1]))
        self.assertEqual(int.from_bytes(frames[1][5:9], "big"), 0)
        self.assertEqual(int.from_bytes(frames[2][5:9], "big"), 0x8000)
        self.assertEqual(frames[-2][2:4], bytes([2, 0x74]))
        self.assertEqual(int.from_bytes(frames[-2][5:9], "big"), 7)
        self.assertEqual(frames[-1][2:4], bytes([2, 0x78]))
        self.assertEqual(int.from_bytes(frames[-1][5:9], "big"), 0x80000007)
        for frame in frames:
            self.assertEqual(int.from_bytes(frame[-2:], "big"), crc16_ccitt(frame[:-2]))

    def test_fake_transport_records_frames_and_telemetry_queue(self):
        transport = FakeTransport()
        frame = build_upload(0, [0] * 1024, 0)[-1]
        transport.send(frame)
        self.assertEqual(transport.sent[-1], frame)
        transport.inject_telemetry(encode_telemetry(V2Telemetry(
            type=1, sequence=1, x=0, y=0, z=0, note=0, flags=0, tick=0,
            voice_bitmap=0, fifo_level=0, fault_code=0)))
        self.assertEqual(transport.recv().sequence, 1)

    def test_ui_depth_color_is_bounded_without_opening_hardware(self):
        self.assertEqual(len(z_color(-32768)), 7)
        self.assertEqual(len(z_color(32767)), 7)
        self.assertNotEqual(z_color(-32768), z_color(32767))


if __name__ == "__main__":
    unittest.main()
