import json
import math
import tempfile
import unittest
from pathlib import Path

from tools.synthwave_loop import (
    DEFAULT_CALIBRATION,
    DEFAULT_LEAD_PATCH,
    DEFAULT_PITCH_SPACE,
    LeadStartGate,
    STYLE,
    StreamingLeadFilter,
    TRACKS,
    compile_lead,
    compile_loop,
    extract_landmarks,
    load_jsonl_records,
    preprocess_samples,
    project_sample,
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
    def test_streaming_lead_start_gate_releases_only_final_edge_candidate(self):
        gate = LeadStartGate()
        records = [_sample(i, x=x, y=30000) for i, x in enumerate((48000, 3000, 4200, 3600, 5200, 10500, 17000))]
        accepted = [row for record in records for row in gate.push(record)]
        self.assertEqual([row["timestamp_ms"] for row in accepted], [60, 80, 100, 120])
        self.assertEqual(accepted[0]["start_gate_reason"], "left_edge_release_rightward")

    def test_streaming_lead_start_gate_drops_capture_without_rightward_release(self):
        gate = LeadStartGate()
        accepted = [row for i, x in enumerate((48000, 3000, 4200, 3600, 2500)) for row in gate.push(_sample(i, x=x, y=32000))]
        self.assertEqual(accepted, [])

    def test_streaming_gate_accepts_real_left_edge_departure_without_waiting_for_large_delta(self):
        gate = LeadStartGate()
        records = [_sample(i, x=x, y=30000) for i, x in enumerate((0, 0, 3598, 4183, 5529))]
        accepted = [row for record in records for row in gate.push(record)]
        self.assertEqual([row["x"] for row in accepted[:2]], [3598, 4183])
        self.assertEqual(accepted[0]["start_gate_reason"], "left_edge_release_rightward")

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
        samples = [_sample(i, x=1000 + i * 1200, y=28000 + i * 500,
                           valid=(i not in (0, 1, 8, 9))) for i in range(20)]
        result = compile_lead(samples, host_profile=build_identity_profile())
        self.assertTrue(result["events"])
        self.assertTrue(any(event["type"] == "rest" for event in result["events"]))
        self.assertTrue(any(event["type"] == "note_on" for event in result["events"]))

    def test_lead_start_gate_ignores_pre_roll_and_keeps_last_left_edge_point(self):
        x_values = (48000, 52000, 3000, 4200, 3600, 5200, 10500, 17000, 24000, 30000)
        samples = [_sample(i, x=x, y=30000 + i * 300) for i, x in enumerate(x_values)]
        projected = preprocess_samples(samples)
        accepted = [row for row in projected if row.get("start_gate_state") == "accepted"]
        self.assertTrue(accepted)
        self.assertEqual(accepted[0]["timestamp_ms"], 80)
        self.assertEqual(accepted[0]["start_gate_reason"], "left_edge_release_rightward")
        self.assertTrue(all(row.get("position_valid") for row in accepted))
        self.assertTrue(all(row.get("start_gate_state") == "prestart" for row in projected[:2]))
        self.assertEqual(projected[2]["start_gate_state"], "edge_candidate")

    def test_lead_start_gate_rejects_capture_without_confirmed_rightward_motion(self):
        x_values = (48000, 52000, 3000, 4200, 3600, 2500, 1800)
        samples = [_sample(i, x=x, y=32000) for i, x in enumerate(x_values)]
        projected = preprocess_samples(samples)
        self.assertTrue(projected)
        self.assertTrue(all(not row.get("position_valid", False) for row in projected))
        self.assertTrue(all(row.get("start_gate_state") != "accepted" for row in projected))

    def test_lead_gate_preserves_sequence_when_device_timestamp_wraps(self):
        samples = [
            _sample(0, x=0, y=30000, timestamp=4294967000),
            _sample(1, x=0, y=30000, timestamp=100),
            _sample(2, x=500, y=30000, timestamp=200),
            _sample(3, x=5000, y=30000, timestamp=300),
            _sample(4, x=7000, y=30000, timestamp=400),
        ]
        for index, row in enumerate(samples):
            row["sequence"] = index
        projected = preprocess_samples(samples)
        accepted = [row for row in projected if row.get("start_gate_state") == "accepted"]
        self.assertTrue(accepted)
        self.assertEqual(accepted[0]["sequence"], 2)

    def test_host_profile_pipeline_preserves_sequence_when_timestamp_wraps(self):
        x_values = (0, 0, 3598, 4183, 5529, 9000)
        timestamps = (4294967000, 100, 200, 300, 400, 500)
        samples = []
        for index, (x, timestamp) in enumerate(zip(x_values, timestamps)):
            row = _sample(index, x=x, y=30000, timestamp=timestamp)
            row["sequence"] = index
            samples.append(row)
        projected = preprocess_samples(samples, host_profile=build_identity_profile())
        self.assertEqual([row["sequence"] for row in projected], [0, 1, 2, 3, 4, 5])
        accepted = [row["sequence"] for row in projected if row.get("start_gate_state") == "accepted"]
        self.assertEqual(accepted, [2, 3, 4, 5])

    def test_jsonl_loader_prefers_sequence_over_wrapped_timestamps(self):
        rows = [
            {"type": "position", "sequence": 0, "timestamp_ms": 4294967000, "x": 0},
            {"type": "position", "sequence": 1, "timestamp_ms": 100, "x": 4000},
            {"type": "position", "sequence": 2, "timestamp_ms": 200, "x": 8000},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "capture.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            records = load_jsonl_records(path)
        self.assertEqual([record["sequence"] for record in records], [0, 1, 2])

    def test_live_receiver_null_validity_is_treated_as_valid(self):
        # pc_receiver emits "position_valid": null until SDK quality flags are
        # wired up; unknown validity must not discard the capture.
        def live(index, x):
            row = _sample(index, x=x, y=30000 + index * 300)
            row.update({"position_valid": None, "xyz_valid": None, "report_error": None,
                        "clipping": None, "environmental_noise": None, "quality_known": False})
            return row
        samples = [live(index, x) for index, x in enumerate((0, 0, 3598, 4183, 5529, 9000, 14000, 20000))]
        gate = LeadStartGate()
        accepted = [row for sample in samples for row in gate.push(sample)]
        self.assertTrue(accepted)
        self.assertTrue(all(row["start_gate_state"] == "accepted" for row in accepted))
        for kwargs in ({}, {"host_profile": build_identity_profile()}):
            result = compile_lead(samples, **kwargs)
            self.assertEqual(result["diagnostics"]["status"], "ok")
            self.assertTrue(any(event["type"] == "note_on" for event in result["events"]))
            self.assertTrue(result["diagnostics"]["lead_start_gate"]["accepted"])
            self.assertGreater(result["diagnostics"]["coverage"], 0.5)

    def test_explicit_invalid_frames_stay_invalid(self):
        for value in (False, "false", 0):
            samples = [_sample(index, x=3000, valid=value) for index in range(4)]
            projected = preprocess_samples(samples)
            self.assertTrue(all(not row["position_valid"] for row in projected), value)


    def test_streaming_filter_matches_the_batch_preprocessor(self):
        # The UI draws the streaming output, so it must equal what the
        # compiler sees, otherwise the operator draws noise.
        samples = [_sample(index, x=1000 + (index * 137) % 3000, y=30000 + (index * 211) % 5000)
                   for index in range(200)]
        projected = [project_sample(sample) for sample in samples]
        batch = preprocess_samples(samples)
        streaming = StreamingLeadFilter()
        emitted = []
        for row in projected:
            value = streaming.push(row["q_app"])
            if value is not None:
                emitted.append(value)
        self.assertEqual(len(emitted), len(batch) - 2)
        for index, value in enumerate(emitted):
            self.assertAlmostEqual(value[0], batch[index]["q_x"], places=9)
            self.assertAlmostEqual(value[1], batch[index]["q_y"], places=9)
            self.assertAlmostEqual(value[2], batch[index]["q_z"], places=9)


    def test_phrase_time_starts_at_the_gate_confirmed_frame(self):
        # Operator waits five seconds before drawing. The pre-roll must not
        # own the beginning of the loop: it used to cost about 33 of the 128
        # ticks and squeezed the real phrase into the tail.
        samples = [_sample(index, x=60000, y=30000) for index in range(250)]
        samples += [_sample(250 + step, x=3000 + step * 120, y=30000 + step * 60) for step in range(250)]
        projected = preprocess_samples(samples)
        accepted = [row for row in projected if row.get("start_gate_state") == "accepted"]
        self.assertTrue(accepted)
        self.assertAlmostEqual(accepted[0]["a_rel"], 0.0, places=6)
        ticks = resample_to_ticks(projected)
        valid_ticks = [row["tick"] for row in ticks if row["position_valid"]]
        self.assertTrue(valid_ticks)
        self.assertLessEqual(min(valid_ticks), 2)
        self.assertGreaterEqual(max(valid_ticks), 120)


if __name__ == "__main__":
    unittest.main()

