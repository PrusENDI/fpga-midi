import unittest

from tools.v2_patch_reference import (
    FxParameters,
    PatchBank,
    apply_patch_value,
    clamp_fx_parameters,
    crc16_samples,
)


class PatchAndFxTests(unittest.TestCase):
    def test_patch_values_are_rejected_outside_contract_bounds(self):
        bank = PatchBank()
        with self.assertRaises(ValueError):
            apply_patch_value(bank, family=0, track=0, index=0, value=65536)
        with self.assertRaises(ValueError):
            apply_patch_value(bank, family=0, track=0, index=15, value=4)

    def test_fx_controls_are_clamped_to_safe_feedback_and_gain_ranges(self):
        params = clamp_fx_parameters(
            FxParameters(gain_q16=-1, cutoff_hz=99999, delay_samples=99999,
                         feedback_q15=40000, reverb_mix_q15=-4,
                         z_gain_q15=40000, z_brightness_q15=-2, z_space_q15=40000)
        )
        self.assertEqual(params.gain_q16, 0)
        self.assertEqual(params.cutoff_hz, 20000)
        self.assertEqual(params.delay_samples, 1023)
        self.assertLessEqual(params.feedback_q15, 31129)
        self.assertEqual(params.reverb_mix_q15, 0)
        self.assertEqual(params.z_gain_q15, 32767)
        self.assertEqual(params.z_brightness_q15, 0)
        self.assertEqual(params.z_space_q15, 32767)

    def test_wavetable_crc_is_big_endian_signed16_payload(self):
        samples = [0, 32767, -32768, -1]
        self.assertEqual(crc16_samples(samples), 0x2B39)


if __name__ == "__main__":
    unittest.main()
