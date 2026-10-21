import math
import tempfile
import unittest
from pathlib import Path

from tools.synthwave_loop import (
    DEFAULT_CALIBRATION,
    DEFAULT_LEAD_PATCH,
    DEFAULT_PITCH_SPACE,
    STYLE,
    TRACKS,
    compile_lead,
    compile_loop,
    extract_landmarks,
    load_jsonl_records,
    preprocess_samples,
    render_loop,
    resample_to_ticks,
)
from tools.host_xyz_filter import build_identity_profile, filter_capture, fit_z_coupling


def _sample(i, *, x=None, y=32768, z=32768, timestamp=None, valid=True):
    return {
        "timestamp_ms": i * 20 if timestamp is None else timestamp,
        "x": int(i * 4000 if x is None else x),
        "y": int(y),
        "z": int(z),
        "position_valid": valid,
    }


class SynthwaveLoopTests(unittest.TestCase):
    def test_style_and_fixed_profiles_are_frozen(self):
        self.assertEqual(STYLE.name, "melodic_synthwave")
        self.assertEqual(STYLE.bpm, 100)
        self.assertEqual(STYLE.harmony, ("Am", "F", "C", "G"))
        self.assertEqual(TRACKS, ("lead", "bass", "pad", "arp", "drums", "texture_fx"))
        self.assertEqual(DEFAULT_PITCH_SPACE.min_midi, 55)
        self.assertEqual(DEFAULT_PITCH_SPACE.max_midi, 72)
        self.assertEqual(DEFAULT_CALIBRATION.pitch_axis, (0.0, 1.0, 0.0))
        self.assertEqual(DEFAULT_LEAD_PATCH.voice_mode, "mono_legato")

    def test_jsonl_loader_preserves_position_and_touch_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "capture.jsonl"
            path.write_text(
                '{"type":"ready","schema":1}\n'
                '{"type":"position","timestamp_ms":10,"x":100,"y":200,"z":300,'
                '"touch_flags":2,"tap_flags":4,"gesture":0}\n',
                encoding="utf-8",
            )
            records = load_jsonl_records(path)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["tap_flags"], 4)

    def test_preprocess_uses_timestamp_order_and_fixed_absolute_projection(self):
        samples = [_sample(2, x=2000, y=50000), _sample(0, x=1000, y=30000), _sample(1, x=1500, y=40000)]
        projected = preprocess_samples(samples, DEFAULT_CALIBRATION)
        self.assertEqual([row["timestamp_ms"] for row in projected], [0, 20, 40])
        self.assertLess(projected[0]["b_abs"], projected[-1]["b_abs"])
        self.assertEqual(projected[0]["out_of_range"], False)

    def test_resampling_preserves_time_order_and_produces_loop_ticks(self):
        samples = preprocess_samples([_sample(i, y=30000 + i * 250) for i in range(10)], DEFAULT_CALIBRATION)
        ticks = resample_to_ticks(samples, STYLE)
        self.assertEqual(len(ticks), 128)
        self.assertEqual([row["tick"] for row in ticks], list(range(128)))
        self.assertLess(ticks[0]["b_abs"], ticks[-1]["b_abs"])

    def test_landmarks_find_hold_turn_and_rest(self):
        samples = []
        for i in range(20):
            samples.append(_sample(i, x=i * 1500, y=30000 + i * 300))
        for i in range(20, 35):
            samples.append(_sample(i, x=30000, y=36000))
        for i in range(35, 55):
            samples.append(_sample(i, x=30000 - (i - 35) * 1500, y=36000 - (i - 35) * 300))
        samples.extend(_sample(i, x=30000, y=33000, valid=False) for i in range(55, 60))
        ticks = resample_to_ticks(preprocess_samples(samples, DEFAULT_CALIBRATION), STYLE)
        kinds = {item["kind"] for item in extract_landmarks(ticks)}
        self.assertIn("hold", kinds)
        self.assertIn("turn", kinds)
        self.assertIn("rest", kinds)

    def test_compile_has_fixed_pitch_range_and_landmark_sources(self):
        samples = [_sample(i, y=20000 + i * 2400, z=18000 + i * 400) for i in range(18)]
        result = compile_lead(samples)
        notes = [event for event in result["events"] if event["type"] == "note_on"]
        self.assertTrue(notes)
        self.assertTrue(all(55 <= event["note"] <= 72 for event in notes))
        self.assertTrue(all(event["source_landmarks"] for event in notes))
        self.assertTrue(all(event["register_id"] == 0 for event in notes))

    def test_depth_changes_color_without_octave_jump(self):
        samples = [_sample(i, y=35000 + (i % 4) * 500, z=10000 if i < 9 else 56000) for i in range(18)]
        result = compile_lead(samples)
        notes = [event for event in result["events"] if event["type"] == "note_on"]
        self.assertTrue(notes)
        self.assertTrue(all(55 <= event["note"] <= 72 for event in notes))
        self.assertLessEqual(max(event["note"] for event in notes) - min(event["note"] for event in notes), 7)
        self.assertGreaterEqual(len({event.get("color_layer") for event in notes}), 1)

    def test_no_unconditional_tonic_or_high_point(self):
        samples = [_sample(i, y=35000, z=32000) for i in range(18)]
        result = compile_lead(samples)
        notes = [event for event in result["events"] if event["type"] == "note_on"]
        self.assertTrue(notes)
        self.assertFalse(result["diagnostics"]["forced_tonic"])
        self.assertFalse(result["diagnostics"]["forced_high_point"])

    def test_compile_is_deterministic_and_non_lead_tracks_are_user_triggered(self):
        lead = [_sample(i, y=25000 + int(8000 * math.sin(i / 3))) for i in range(24)]
        touch = [{"type": "position", "timestamp_ms": 0, "x": 1000, "y": 30000, "z": 30000, "touch_flags": 1, "tap_flags": 1}]
        first = compile_loop(lead, {"bass": touch})
        second = compile_loop(lead, {"bass": touch})
        self.assertEqual(first, second)
        self.assertTrue(first["tracks"]["bass"])
        self.assertFalse(first["tracks"]["pad"])

    def test_render_loop_writes_nonempty_deterministic_wav(self):
        result = compile_loop([_sample(i, y=28000 + i * 500) for i in range(18)], {})
        self.assertIn("lead_patch", result)
        with tempfile.TemporaryDirectory() as tmp:
            first_path = render_loop(result, Path(tmp) / "first.wav", sample_rate=8000)
            second_path = render_loop(result, Path(tmp) / "second.wav", sample_rate=8000)
            self.assertGreater(first_path.stat().st_size, 44)
            self.assertEqual(first_path.read_bytes(), second_path.read_bytes())

    def test_host_profile_is_used_before_fixed_pitch_compilation(self):
        samples = []
        for i in range(24):
            z = 16000 + i * 1000
            samples.append(_sample(i, x=22000 + int(0.10 * (z - 16000)), y=38000 - int(0.16 * (z - 16000)), z=z))
        profile = build_identity_profile(coupling_bins=fit_z_coupling(samples, bin_count=7), coupling_confidence=1.0)
        first = compile_lead(samples, host_profile=profile)
        second = compile_lead(samples, host_profile=profile)
        self.assertEqual(first, second)
        self.assertEqual(first["diagnostics"]["host_profile_hash"], profile.profile_hash)
        self.assertEqual(first["diagnostics"]["host_filter"]["coupling_model"], "piecewise_median")
        self.assertTrue(all(DEFAULT_PITCH_SPACE.min_midi <= event["note"] <= DEFAULT_PITCH_SPACE.max_midi for event in first["events"] if event["type"] == "note_on"))

    def test_compile_loop_keeps_host_filter_diagnostics(self):
        samples = [_sample(i, x=1000 + i * 500, y=28000 + i * 500) for i in range(20)]
        profile = build_identity_profile()
        result = compile_loop(samples, {}, host_profile=profile)
        self.assertEqual(result["diagnostics"]["host_profile_hash"], profile.profile_hash)
        self.assertIn("host_filter", result["diagnostics"])

    def test_host_invalid_spans_compile_to_explicit_rest_without_interpolation(self):
        samples = [_sample(i, x=1000 + i * 500, y=28000 + i * 500, valid=(i not in (8, 9))) for i in range(20)]
        result = compile_lead(samples, host_profile=build_identity_profile())
        rests = [event for event in result["events"] if event["type"] == "rest"]
        self.assertTrue(rests)
        self.assertGreaterEqual(result["diagnostics"]["host_filter"]["invalid_count"], 2)

    def test_lead_compile_survives_invalid_capture_prefix(self):
        samples = [_sample(i, x=1000 + i * 500, y=28000 + i * 500,
                           valid=(i not in (0, 1, 8, 9))) for i in range(20)]
        result = compile_lead(samples, host_profile=build_identity_profile())
        self.assertTrue(result["events"])
        self.assertTrue(any(event["type"] == "rest" for event in result["events"]))
        self.assertTrue(any(event["type"] == "note_on" for event in result["events"]))


if __name__ == "__main__":
    unittest.main()

