import unittest
from tools.v2_fixed_reference import Profile, process_frame, REASON_SATURATED, REASON_GAP, REASON_CLAMP, REASON_INVALID, REASON_EPOCH, REASON_PROFILE

class FixedInputReferenceTest(unittest.TestCase):
    def setUp(self):
        self.p = Profile(neutral=(100, -200, 300), coupling=(0x1000, -0x0800), gain=(0x10000,)*3,
                         workspace=((-1000, 1000), (-1000, 1000), (-1000, 1000)), epoch=7)
    def test_sign_extension_and_ordered_transform(self):
        p = self.p._replace(coupling=(0, 0))
        out = process_frame(dict(sequence=1, timestamp_ticks=10, raw=(-32768, 32767, -1), valid_xyz=True,
                                 saturated=False, gap=False, calibration_epoch=7), p)
        self.assertEqual(out["xyz"], (-1000, 1000, -301))
        self.assertTrue(out["frame_valid"])
    def test_gap_invalid_and_count(self):
        out = process_frame(dict(sequence=4, timestamp_ticks=20, raw=(0,0,0), valid_xyz=True,
                                 saturated=False, gap=True, calibration_epoch=7), self.p, previous_sequence=1, gap_count=0)
        self.assertFalse(out["frame_valid"])
        self.assertTrue(out["lost"])
        self.assertEqual(out["gap_count"], 2)
        self.assertEqual(out["calibration_reason"] & REASON_GAP, REASON_GAP)
    def test_saturation_never_valid(self):
        out = process_frame(dict(sequence=1, timestamp_ticks=0, raw=(0,0,0), valid_xyz=True,
                                 saturated=True, gap=False, calibration_epoch=7), self.p)
        self.assertFalse(out["frame_valid"])
        self.assertEqual(out["xyz"], (0, 0, 0))
        self.assertEqual(out["calibration_reason"] & REASON_SATURATED, REASON_SATURATED)
    def test_invalid_output_is_zero_and_recovery_is_fresh(self):
        bad = process_frame(dict(sequence=1, raw=(200,200,200), valid_xyz=False, saturated=False, gap=False, calibration_epoch=7), self.p)
        self.assertEqual(bad["xyz"], (0, 0, 0))
        self.assertEqual(bad["calibration_reason"] & REASON_INVALID, REASON_INVALID)
        good = process_frame(dict(sequence=2, raw=(100,-200,300), valid_xyz=True, saturated=False, gap=False, calibration_epoch=7), self.p, previous_sequence=1)
        self.assertTrue(good["frame_valid"])
        self.assertEqual(good["calibration_reason"], 0)

    def test_wrap_and_profile_epoch(self):
        first = process_frame(dict(sequence=0xffff, raw=(0,0,0), valid_xyz=True, saturated=False, gap=False, calibration_epoch=7), self.p)
        wrapped = process_frame(dict(sequence=0, raw=(0,0,0), valid_xyz=True, saturated=False, gap=False, calibration_epoch=7), self.p, previous_sequence=first["sequence"], gap_count=0)
        self.assertEqual(wrapped["gap_count"], 0)
        self.assertFalse(wrapped["lost"])
        mismatch = process_frame(dict(sequence=1, raw=(0,0,0), valid_xyz=True, saturated=False, gap=False, calibration_epoch=8), self.p, previous_sequence=0)
        self.assertFalse(mismatch["frame_valid"])
        self.assertTrue(mismatch["calibration_reason"] & REASON_EPOCH)
        self.assertTrue(mismatch["calibration_reason"] & REASON_PROFILE)

    def test_clamp_reason(self):
        out = process_frame(dict(sequence=1, timestamp_ticks=0, raw=(2000,0,0), valid_xyz=True,
                                 saturated=False, gap=False, calibration_epoch=7), self.p)
        self.assertEqual(out["xyz"][0], 1000)
        self.assertEqual(out["calibration_reason"] & REASON_CLAMP, REASON_CLAMP)
        self.assertTrue(out["frame_valid"])

if __name__ == '__main__': unittest.main()
