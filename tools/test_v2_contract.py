import unittest
from tools.v2_contract import (
    crc16_ccitt, encode_control, decode_control, encode_event, encode_telemetry,
    is_valid_address, V2Event, V2Telemetry, ControlPacketError,
)

class ContractTests(unittest.TestCase):
    def test_indexed_patch_and_register_masks(self):
        from tools import v2_contract as c
        self.assertEqual(c.CSR["PATCH_SELECT"].address, 0x48)
        self.assertEqual(c.CSR["PATCH_SHADOW_DATA"].address, 0x4C)
        self.assertEqual(c.CSR["PATCH_ACTIVE_DATA"].access, "RO")
        self.assertEqual(c.PATCH_PARAMETERS[(0, 0)].name, "OSC_MIX")
        self.assertEqual(c.PATCH_PARAMETERS[(1, 0)].name, "NEUTRAL_X")
        self.assertEqual(c.CSR["TRACK"].write_mask, 0x7)
        self.assertEqual(c.CSR["PATCH_APPLY"].write_mask, 0x8000FFFF)
        self.assertEqual(c.CSR["WT_SELECT"].write_mask, 0xFF07)
        for name, reg in c.CSR.items():
            key = "V2_CSR_TEST_SELECT_WRITE_MASK" if name.startswith("TEST_SELECT_") else f"V2_CSR_{name}_WRITE_MASK"
            self.assertEqual(c.SV_CONSTANTS[key], reg.write_mask)
        with self.assertRaises(ValueError):
            c.encode_control(c.V2_OP_WRITE, c.V2_CSR_TRACK, 0x8, 1)
        with self.assertRaises(ValueError):
            c.encode_control(c.V2_OP_WRITE, c.V2_CSR_PATCH_SHADOW_DATA, 400000, 1,
                             indexed_selector=(0, 7, 14))
        with self.assertRaises(ValueError):
            c.encode_control(c.V2_OP_WRITE, c.V2_CSR_PATCH_SHADOW_DATA, 1, 1)
        for (family, index), parameter in c.PATCH_PARAMETERS.items():
            q_code = 4 if parameter.q_format.startswith("UQ") else 3 if parameter.q_format.startswith("SQ") else 1
            self.assertEqual(c.SV_CONSTANTS[f"V2_PARAM_F{family}_I{index}_Q_CODE"], q_code)
            self.assertEqual(c.SV_CONSTANTS[f"V2_PARAM_F{family}_I{index}_GLOBAL"], int(parameter.scope == "global"))

    def test_v2_capacity_voice_test_and_wavetable_extensions(self):
        from tools import v2_contract as c
        self.assertEqual(c.V2_LOOP_BANKS, 2)
        self.assertEqual(c.V2_LOOP_TRACKS, 6)
        self.assertEqual(c.V2_LOOP_SLOTS_PER_TRACK, 32)
        self.assertEqual(c.V2_LOOP_SLOT_BITS, 5)
        self.assertEqual(c.V2_LOOP_COUNT_BITS, 6)
        self.assertEqual(c.V2_LOOP_TOTAL_SLOTS, 192)
        self.assertEqual(c.V2_VOICE_COUNT, 32)
        self.assertEqual(c.V2_OSCILLATORS_PER_VOICE, 2)
        self.assertEqual(c.V2_VOICE_STEAL_COUNTER_BITS, 16)
        self.assertEqual(c.V2_VOICE_STEAL_PRIORITY, (
            c.V2_VOICE_STEAL_RELEASED,
            c.V2_VOICE_STEAL_OLDEST,
            c.V2_VOICE_STEAL_LOWEST_VELOCITY,
            c.V2_VOICE_STEAL_LOWEST_VOICE_ID,
        ))
        self.assertEqual(c.V2_TEST_SELECTOR_N_TONE, 1)
        self.assertEqual(c.V2_TEST_N_TONE_COUNT_MIN, 1)
        self.assertEqual(c.V2_TEST_N_TONE_COUNT_MAX, 32)
        self.assertEqual(c.V2_TEST_N_TONE_COUNT_DEFAULT, 8)
        self.assertEqual(c.V2_WT_BAND_MAX, 7)
        self.assertEqual(c.V2_WT_OCTAVE_MAX, 15)
        self.assertEqual(c.encode_wavetable_select(c.V2_WT_B, 1, 7, 15), 0x0000FF01)
        self.assertEqual(c.decode_wavetable_select(0x0000FF01),
                         {"table_id": 1, "bank": 1, "band": 7, "octave": 15})
        with self.assertRaises(ValueError):
            c.encode_wavetable_select(c.V2_WT_A, 0, 8, 0)
        with self.assertRaises(ValueError):
            c.encode_wavetable_select(c.V2_WT_A, 0, 0, 16)
        self.assertEqual(c.V2_VIBRATO_READBACK_PHASE_MASK, 0x0000FFFF)
        self.assertEqual(c.V2_VIBRATO_READBACK_DELTA_CENTS_MASK, 0xFFFF0000)

    def test_signed_indexed_wire_round_trip(self):
        from tools import v2_contract as c
        for family, index, value in ((0, 2, -1200), (1, 3, -65536), (2, 5, -256)):
            wire = c.patch_value_to_wire(family, index, value)
            self.assertEqual(c.patch_wire_to_value(family, index, wire), value)
            frame = c.encode_control(c.V2_OP_WRITE, c.V2_CSR_PATCH_SHADOW_DATA,
                                     value, 9, indexed_selector=(family, 0 if family != 1 else 7, index))
            self.assertEqual(int.from_bytes(frame[5:9], "big"), wire)

    def test_event_rejects_reserved_type_and_flags(self):
        from dataclasses import replace
        event = V2Event(type=1, track=5, tick=1, duration=2, note=60,
                        velocity=100, pitch_mod=0, timbre_mod=0, flags=0, sequence=1)
        for value in (0, 7, 15):
            with self.assertRaises(ValueError):
                encode_event(replace(event, type=value))
        for value in (0x40, 0x80):
            with self.assertRaises(ValueError):
                encode_event(replace(event, flags=value))

    def test_indexed_parameter_codec_and_crc(self):
        from tools import v2_contract as c
        self.assertEqual(c.encode_patch_select(0, 5, 0), 0x14)
        self.assertEqual(c.encode_patch_select(1, 7, 0), 0x1D)
        self.assertEqual(c.encode_patch_select(2, 3, 6), 0x60E)
        self.assertEqual(c.PATCH_PARAMETERS[(2, 0)].name, "LAMBDA_Q16")
        self.assertEqual(c.PATCH_PARAMETERS[(3, 2)].default, 36000)
        with self.assertRaises(ValueError):
            c.encode_patch_select(1, 0, 0)
        with self.assertRaises(ValueError):
            c.validate_patch_value(0, 0, 2, 400000)
        defaults = {key:value for key,value in c.default_patch_values().items() if key[:2] == (0,0)}
        self.assertEqual(c.patch_shadow_crc(defaults,0,0), c.patch_shadow_crc(dict(reversed(list(defaults.items()))),0,0))
        with self.assertRaises(ValueError):
            c.patch_shadow_crc({},0,0)

    def test_wavetable_coverage_version_and_crc(self):
        from tools import v2_contract as c
        samples = [0] * c.V2_WT_SAMPLES
        covered = set(range(c.V2_WT_SAMPLES))
        expected_crc = c.crc16_ccitt(bytes(2 * c.V2_WT_SAMPLES))
        c.validate_wavetable_upload(c.V2_WT_A, samples, covered, expected_crc, 7, 7)
        for table, sample_set, coverage, crc, version, active in (
            (3,samples,covered,expected_crc,7,7),
            (0,samples,covered-{17},expected_crc,7,7),
            (0,samples,covered,expected_crc^1,7,7),
            (0,samples,covered,expected_crc,8,7),
        ):
            with self.assertRaises(ValueError):
                c.validate_wavetable_upload(table,sample_set,coverage,crc,version,active)

    def test_machine_contract_constants_match_sv(self):
        from pathlib import Path
        from tools import v2_contract as c
        sv = (Path(__file__).resolve().parents[1] / "rtl/v2_contract_pkg.sv").read_text()
        for name, value in c.SV_CONSTANTS.items():
            import re
            match = re.search(r"\b" + name + r"\s*=\s*(?:(?:8|32)'h([0-9A-Fa-f]+)|(?:2|4|8)'d(\d+)|(-?\d+))", sv)
            self.assertIsNotNone(match, name)
            self.assertEqual(int(match.group(1), 16) if match.group(1) else int(match.group(2) or match.group(3)), value, name)
        self.assertEqual(c.CSR["STATUS"].address, 0x00)
        self.assertEqual(c.CSR["WT_APPLY"].access, "WO")

    def test_crc16_ccitt_known_vector(self):
        self.assertEqual(crc16_ccitt(b"123456789"), 0x29B1)

    def test_control_is_11_bytes_big_endian_and_round_trips(self):
        frame = encode_control(2, 0x4C, 100000, 0x34, indexed_selector=(0, 5, 14))
        self.assertEqual(len(frame), 11)
        self.assertEqual(frame[:5], bytes([0xA5, 0x02, 0x02, 0x4C, 0x34]))
        self.assertEqual(frame[5:9], (100000).to_bytes(4, "big"))
        packet = decode_control(frame, indexed_selector=(0, 5, 14))
        self.assertEqual(packet, {"op": 2, "address": 0x4C, "sequence": 0x34, "data": 100000})

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
        for address,data in ((0x04,6),(0x0C,6),(0x60,3),(0x48,0x7),(0x08,59)):
            with self.assertRaises(ValueError):
                encode_control(2,address,data,1)
        self.assertTrue(is_valid_address(0x44))
        self.assertTrue(is_valid_address(0xAF))
        self.assertFalse(is_valid_address(0x45))
        self.assertFalse(is_valid_address(0xB0))
        self.assertFalse(is_valid_address(0x49))
        self.assertFalse(is_valid_address(0x61))

    def test_event_is_96_bits_with_explicit_reserved_msb(self):
        event = V2Event(type=1, track=5, tick=0x12, duration=0x34, note=0x56, velocity=0x78,
                        pitch_mod=-2, timbre_mod=0x1234, flags=0x1A, sequence=0xBCDE)
        frame = encode_event(event)
        self.assertEqual(len(frame), 12)
        self.assertEqual(frame[0] & 0x80, 0)
        self.assertEqual(int.from_bytes(frame, "big") >> 95, 0)
        self.assertEqual((int.from_bytes(frame, "big") >> 91) & 0xF, 1)
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
