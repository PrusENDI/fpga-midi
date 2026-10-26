import unittest
from tools.v2_contract import (
    crc16_ccitt, encode_control, decode_control, encode_event, encode_telemetry,
    is_valid_address, V2Event, V2Telemetry, ControlPacketError,
)

class ContractTests(unittest.TestCase):
    def test_machine_contract_constants_match_sv(self):
        from pathlib import Path
        from tools import v2_contract as c
        sv = (Path(__file__).resolve().parents[1] / "rtl/v2_contract_pkg.sv").read_text()
        for name, value in c.SV_CONSTANTS.items():
            import re
            match = re.search(r"\b" + name + r"\s*=\s*(?:8'h([0-9A-Fa-f]+)|(?:2|4|8)'d(\d+)|(\d+))", sv)
            self.assertIsNotNone(match, name)
            self.assertEqual(int(match.group(1), 16) if match.group(1) else int(match.group(2) or match.group(3)), value, name)
        self.assertEqual(c.CSR["STATUS"].address, 0x00)
        self.assertEqual(c.CSR["WT_APPLY"].access, "WO")

    def test_crc16_ccitt_known_vector(self):
        self.assertEqual(crc16_ccitt(b"123456789"), 0x29B1)

    def test_control_is_11_bytes_big_endian_and_round_trips(self):
        frame = encode_control(2, 0x48, 0x89ABCDEF, 0x34)
        self.assertEqual(len(frame), 11)
        self.assertEqual(frame[:5], bytes([0xA5, 0x02, 0x02, 0x48, 0x34]))
        self.assertEqual(frame[5:9], bytes.fromhex("89abcdef"))
        packet = decode_control(frame)
        self.assertEqual(packet, {"op": 2, "address": 0x48, "sequence": 0x34, "data": 0x89ABCDEF})

    def test_control_rejects_bad_sof_version_crc_and_address(self):
        frame = encode_control(1, 0x00, 0, 1)
        for bad in (bytes([0x00]) + frame[1:], frame[:1] + bytes([3]) + frame[2:], frame[:-1] + bytes([frame[-1] ^ 1])):
            with self.assertRaises(ControlPacketError):
                decode_control(bad)
        with self.assertRaises(ValueError):
            encode_control(1, 0x45, 0, 1)
        with self.assertRaises(ValueError):
            encode_control(2, 0x00, 1, 1)
        with self.assertRaises(ValueError):
            encode_control(1, 0x14, 0, 1)
        with self.assertRaises(ValueError):
            encode_control(0x12, 0x48, 0, 1)
        self.assertTrue(is_valid_address(0x44))
        self.assertTrue(is_valid_address(0xAF))
        self.assertFalse(is_valid_address(0x45))
        self.assertFalse(is_valid_address(0xB0))
        self.assertFalse(is_valid_address(0x49))
        self.assertFalse(is_valid_address(0x61))

    def test_event_is_96_bits_with_explicit_reserved_msb(self):
        event = V2Event(type=0xA, track=5, tick=0x12, duration=0x34, note=0x56, velocity=0x78,
                        pitch_mod=-2, timbre_mod=0x1234, flags=0x9A, sequence=0xBCDE)
        frame = encode_event(event)
        self.assertEqual(len(frame), 12)
        self.assertEqual(frame[0] & 0x80, 0)
        self.assertEqual(int.from_bytes(frame, "big") >> 95, 0)
        self.assertEqual((int.from_bytes(frame, "big") >> 91) & 0xF, 0xA)
        self.assertEqual((int.from_bytes(frame, "big") >> 88) & 0x7, 5)

    def test_telemetry_is_22_bytes_signed_xyz_and_crc(self):
        snapshot = V2Telemetry(type=2, sequence=0x1234, x=-1, y=2, z=-32768, note=60,
                               flags=0x80, tick=0xFE, voice_bitmap=0xAABBCCDD,
                               fifo_level=7, fault_code=9)
        frame = encode_telemetry(snapshot)
        self.assertEqual(len(frame), 22)
        self.assertEqual(frame[:5], bytes.fromhex("5a02021234"))
        self.assertEqual(frame[5:11], bytes.fromhex("ffff00028000"))
        body, crc = frame[:-2], int.from_bytes(frame[-2:], "big")
        self.assertEqual(crc, crc16_ccitt(body))

if __name__ == "__main__":
    unittest.main()
