import math
import unittest

from tools.host_xyz_filter import (
    HostCalibrationProfile,
    build_identity_profile,
    filter_capture,
    fit_z_coupling,
    build_profile,
    estimate_neutral,
)


def _frame(i, x, y, z, *, valid=True, sequence=None, gap_before=0):
    return {
        "timestamp_ms": float(i * 5),
        "sequence": i if sequence is None else sequence,
        "x": int(round(x)),
        "y": int(round(y)),
        "z": int(round(z)),
        "position_valid": valid,
        "xyz_valid": valid,
        "report_error": False,
        "gap_before": gap_before,
    }


class HostXYZFilterTests(unittest.TestCase):
    def test_identity_profile_round_trip_is_stable_and_explicit(self):
        profile = build_identity_profile()
        restored = HostCalibrationProfile.from_dict(profile.to_dict())
        self.assertEqual(restored.profile_hash, profile.profile_hash)
        self.assertEqual(restored.coupling_confidence, 0.0)
        result = filter_capture([_frame(0, 10000, 20000, 30000)], restored)
        self.assertEqual(result.frames[0]["coupling_reason"], "identity_profile")
        self.assertEqual(result.frames[0]["q_raw"], result.frames[0]["q_decoupled"])

    def test_profile_loader_accepts_tick_frequency_from_recorded_profile(self):
        profile = HostCalibrationProfile.from_dict({"timestamp_units": "ticks", "timestamp_tick_hz": 200.0})
        self.assertEqual(profile.timestamp_units, "ticks")
        self.assertEqual(profile.timestamp_tick_hz, 200.0)

    def test_z_coupling_fit_removes_reproducible_xy_drift(self):
        samples = [_frame(i, 20000 + 0.20 * i * 65535 / 6, 40000 - 0.30 * i * 65535 / 6, 10000 + i * 8000) for i in range(7)]
        model = fit_z_coupling(samples, bin_count=7)
        profile = build_identity_profile(coupling_bins=model, coupling_confidence=1.0)
        result = filter_capture(samples, profile)
        pitch = [float(row["b_abs"]) for row in result.frames]
        self.assertLess(max(pitch) - min(pitch), 0.04)
        self.assertGreater(result.frames[-1]["coupling_alpha"], 0.8)

    def test_invalid_frame_breaks_segment_without_interpolation(self):
        profile = build_identity_profile()
        samples = [
            _frame(0, 20000, 30000, 20000),
            _frame(1, 21000, 31000, 21000, valid=False),
            _frame(2, 50000, 50000, 50000),
        ]
        result = filter_capture(samples, profile)
        self.assertEqual(result.frames[1]["motion_state"], "INVALID/LOST")
        self.assertIsNone(result.frames[1]["q_filtered"])
        self.assertEqual(result.frames[2]["filter_reason"], "segment_restart")

    def test_pure_z_motion_is_depth_only_after_decoupling(self):
        samples = []
        for i in range(20):
            z = 18000 + i * 1200
            x = 24000 + 0.12 * (z - 18000)
            y = 36000 - 0.18 * (z - 18000)
            samples.append(_frame(i, x, y, z))
        model = fit_z_coupling(samples, bin_count=7)
        profile = build_identity_profile(coupling_bins=model, coupling_confidence=1.0)
        result = filter_capture(samples, profile)
        states = {row["motion_state"] for row in result.frames[4:]}
        self.assertIn("DEPTH_ONLY", states)
        self.assertNotIn("PITCH_INTENT", states)
        pitch = [float(row["b_abs"]) for row in result.frames if row["q_filtered"] is not None]
        self.assertLess(max(pitch) - min(pitch), 0.05)

    def test_diagonal_motion_keeps_pitch_intent(self):
        samples = [_frame(i, 24000 + i * 600, 24000 + i * 1400, 25000 + i * 200) for i in range(20)]
        result = filter_capture(samples, build_identity_profile())
        self.assertTrue({"PITCH_INTENT", "DIAGONAL_INTENT"}.intersection(row["motion_state"] for row in result.frames[4:]))
        self.assertGreater(float(result.frames[-1]["b_abs"]), float(result.frames[0]["b_abs"]))

    def test_profile_builder_uses_explicit_captures_and_records_metadata(self):
        neutral = [_frame(i, 32000 + (i % 2), 30000 - (i % 2), 18000 + (i % 2)) for i in range(12)]
        estimate = estimate_neutral(neutral)
        self.assertEqual(len(estimate.reference_xyz), 3)
        profile, diagnostics = build_profile(neutral, neutral, neutral, {"sensor_orientation": "test"})
        self.assertEqual(profile.coupling_model, "piecewise_median")
        self.assertEqual(profile.profile_id, diagnostics["profile_id"])
        self.assertEqual(diagnostics["metadata"]["sensor_orientation"], "test")

    def test_string_false_quality_fields_are_invalid(self):
        profile = build_identity_profile()
        result = filter_capture([{"timestamp_ms": 0, "x": 1000, "y": 2000, "z": 3000, "position_valid": "False", "xyz_valid": "False"}], profile)
        self.assertEqual(result.diagnostics["valid_count"], 0)


if __name__ == "__main__":
    unittest.main()
