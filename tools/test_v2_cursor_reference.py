import unittest
from tools.v2_cursor_reference import (
    CursorFilter, CursorFrame, DISENGAGED, ENGAGED, REBASED, DEGRADED,
    REASON_INVALID, REASON_GAP, REASON_SATURATED, REASON_PROFILE,
    Q16_ONE,
)

class CursorReferenceTests(unittest.TestCase):
    def test_left_edge_engages_then_motion_is_slew_limited(self):
        f = CursorFilter(max_step_q16=Q16_ONE // 8, settle_ticks=0)
        first = f.push(CursorFrame(x=-32768, y=0, z=1000, left_edge=True, sequence=0))
        self.assertEqual(first.state, ENGAGED)
        self.assertEqual(first.cursor_x_q16, Q16_ONE // 2)
        second = f.push(CursorFrame(x=32767, y=32767, z=1000, sequence=1))
        self.assertEqual(second.state, ENGAGED)
        self.assertLessEqual(abs(second.cursor_x_q16 - first.cursor_x_q16), Q16_ONE // 8)
        self.assertLessEqual(abs(second.cursor_y_q16 - first.cursor_y_q16), Q16_ONE // 8)

    def test_low_z_without_left_edge_does_not_initially_arm(self):
        f = CursorFilter(settle_ticks=0)
        point = f.push(CursorFrame(x=0, y=0, z=1000, sequence=0))
        self.assertEqual(point.state, DISENGAGED)

    def test_settle_ticks_hold_after_rebase(self):
        f = CursorFilter(settle_ticks=2, max_step_q16=Q16_ONE)
        f.push(CursorFrame(x=-32768, y=0, z=1000, left_edge=True, sequence=0))
        f.push(CursorFrame(x=0, y=1000, z=40000, sequence=1))
        rebased = f.push(CursorFrame(x=0, y=1000, z=1000, sequence=2))
        self.assertEqual(rebased.state, REBASED)
        held1 = f.push(CursorFrame(x=30000, y=30000, z=1000, sequence=3))
        held2 = f.push(CursorFrame(x=30000, y=30000, z=1000, sequence=4))
        self.assertEqual((held1.cursor_x_q16, held1.cursor_y_q16), (rebased.cursor_x_q16, rebased.cursor_y_q16))
        self.assertEqual((held2.cursor_x_q16, held2.cursor_y_q16), (rebased.cursor_x_q16, rebased.cursor_y_q16))

    def test_high_z_freezes_and_release_rebases_one_frame_without_jump(self):
        f = CursorFilter(settle_ticks=0)
        f.push(CursorFrame(x=-32768, y=0, z=1000, left_edge=True, sequence=0))
        moved = f.push(CursorFrame(x=-10000, y=10000, z=1000, sequence=1))
        held = f.push(CursorFrame(x=20000, y=-20000, z=40000, sequence=2))
        self.assertEqual(held.state, DISENGAGED)
        self.assertEqual((held.cursor_x_q16, held.cursor_y_q16), (moved.cursor_x_q16, moved.cursor_y_q16))
        rebased = f.push(CursorFrame(x=20000, y=-20000, z=20000, sequence=3))
        self.assertEqual(rebased.state, REBASED)
        self.assertTrue(rebased.rebased)
        self.assertEqual((rebased.cursor_x_q16, rebased.cursor_y_q16), (held.cursor_x_q16, held.cursor_y_q16))
        next_frame = f.push(CursorFrame(x=21000, y=-19000, z=20000, sequence=4))
        self.assertEqual(next_frame.state, ENGAGED)
        self.assertFalse(next_frame.rebased)

    def test_invalid_gap_saturated_profile_do_not_change_pitch_or_anchor(self):
        f = CursorFilter(settle_ticks=0)
        f.push(CursorFrame(x=-32768, y=1000, z=1000, left_edge=True, sequence=0))
        good = f.push(CursorFrame(x=-10000, y=20000, z=1000, sequence=1))
        for i, reason in enumerate((REASON_INVALID, REASON_GAP, REASON_SATURATED, REASON_PROFILE), 2):
            bad = f.push(CursorFrame(x=30000, y=-30000, z=40000, valid=False, reason=reason, sequence=i))
            self.assertEqual(bad.state, DEGRADED)
            self.assertEqual(bad.normalized_pitch_q16, good.normalized_pitch_q16)
            self.assertEqual((bad.cursor_x_q16, bad.cursor_y_q16), (good.cursor_x_q16, good.cursor_y_q16))

    def test_pure_z_does_not_change_pitch_but_updates_depth(self):
        f = CursorFilter(settle_ticks=0)
        f.push(CursorFrame(x=-32768, y=1000, z=1000, left_edge=True, sequence=0))
        before = f.push(CursorFrame(x=-10000, y=12000, z=5000, sequence=1))
        after = f.push(CursorFrame(x=-10000, y=12000, z=25000, sequence=2))
        self.assertEqual(after.normalized_pitch_q16, before.normalized_pitch_q16)
        self.assertNotEqual(after.depth_q16, before.depth_q16)

    def test_five_point_median_rejects_single_spike(self):
        f = CursorFilter(settle_ticks=0, max_step_q16=Q16_ONE)
        xs = [-32768, -32768, -32768, 32767, -32768]
        out = [f.push(CursorFrame(x=x, y=0, z=1000, left_edge=(i == 0), sequence=i)) for i, x in enumerate(xs)]
        self.assertEqual(out[-1].cursor_x_q16, Q16_ONE // 2)

    def test_sample_ce_consumes_latest_point_and_keeps_timestamp(self):
        f = CursorFilter(settle_ticks=0)
        f.push(CursorFrame(x=-32768, y=1000, z=1000, left_edge=True, sequence=7, timestamp_ticks=1234))
        self.assertIsNone(f.sample_ce())
        f.push(CursorFrame(x=-20000, y=3000, z=1000, sequence=8, timestamp_ticks=5678))
        point = f.sample_ce()
        self.assertIsNotNone(point)
        self.assertEqual(point.timestamp_ticks, 5678)
        self.assertEqual(point.sequence, 8)

if __name__ == '__main__':
    unittest.main()
