import json
import math
import tempfile
import unittest
from pathlib import Path

from tools.synthwave_loop import (
    DEFAULT_CALIBRATION,
    DEFAULT_LEAD_PATCH,
    DEFAULT_PITCH_SPACE,
    AbsoluteCursor,
    LeadStartGate,
    PitchSpace,
    STYLE,
    RelativeCursor,
    StreamingLeadFilter,
    SynthwaveStyle,
    TRACKS,
    compile_lead,
    compile_loop,
    density_to_lambda,
    bow_attacks,
    merge_leaps,
    extract_landmarks,
    length_from_take,
    make_cursor,
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


    def test_hand_absent_frames_are_invalid(self):
        # Without a hand the device reports x=65535, y=0, z=65535. Treating
        # that as a position drew a spike into the top-right corner.
        idle = [{"timestamp_ms": 20 * index, "x": 65535, "y": 0, "z": 65535} for index in range(3)]
        samples = idle + [_sample(index + 3, x=3000 + index * 400, y=30000, timestamp=(index + 3) * 20)
                          for index in range(20)]
        projected = preprocess_samples(samples)
        self.assertTrue(all(not row["position_valid"] for row in projected[:3]))
        self.assertTrue(any(row["position_valid"] for row in projected[3:]))


class RelativeCursorTests(unittest.TestCase):
    def test_gain_falls_as_the_hand_rises(self):
        cursor = RelativeCursor()
        self.assertAlmostEqual(cursor.gain_at(4000), 1.0)
        self.assertAlmostEqual(cursor.gain_at(24000), 0.25)
        self.assertLess(cursor.gain_at(15000), cursor.gain_at(6000))

    def test_movement_is_scaled_by_the_current_gain(self):
        cursor = RelativeCursor()
        cursor.push((0.5, 0.5), 4000)
        moved, _ = cursor.push((0.51, 0.5), 4000)
        self.assertAlmostEqual(moved[0], 0.5 + 0.01 - 0.0004, places=6)

    def test_raising_the_hand_slows_the_same_movement(self):
        low, high = RelativeCursor(), RelativeCursor()
        low.push((0.5, 0.5), 4000)
        high.push((0.5, 0.5), 12000)
        low_moved, _ = low.push((0.51, 0.5), 4000)
        high_moved, _ = high.push((0.51, 0.5), 12000)
        ratio = (high_moved[0] - 0.5) / (low_moved[0] - 0.5)
        self.assertAlmostEqual(ratio, high.gain_at(12000) / low.gain_at(4000), places=6)
        self.assertLess(ratio, 1.0)

    def test_lifting_discards_motion_and_reengages_without_a_jump(self):
        cursor = RelativeCursor()
        cursor.push((0.5, 0.5), 6000)
        moved = (0.5, 0.5)
        for step in range(1, 10):
            moved, _ = cursor.push((0.5 + step * 0.02, 0.5), 6000, engaged=False)
        self.assertAlmostEqual(moved[0], 0.5)
        after, _ = cursor.push((0.5 + 10 * 0.02, 0.5), 6000, engaged=True)
        expected = 0.5 + cursor.gain_at(6000) * (0.02 - cursor.deadzone)
        self.assertAlmostEqual(after[0], expected, places=6)

    def test_deadzone_ignores_sensor_jitter(self):
        cursor = RelativeCursor()
        cursor.push((0.5, 0.5), 4000)
        moved, _ = cursor.push((0.5002, 0.5), 4000)
        self.assertAlmostEqual(moved[0], 0.5)

    def test_cursor_clamps_at_the_pitch_limits(self):
        cursor = RelativeCursor()
        cursor.push((0.5, 0.5), 4000)
        for _ in range(200):
            cursor.push((0.5 + 0.05, 0.5), 4000)
            cursor._prev = (0.5, 0.5)
        self.assertLessEqual(cursor.cursor[0], 1.0)
        self.assertGreater(cursor.cursor[0], 0.9)


    def test_engagement_uses_hysteresis(self):
        cursor = RelativeCursor(z_engage=16000, z_release=20000)
        self.assertTrue(cursor.update_engagement(8000))
        self.assertFalse(cursor.update_engagement(21000))
        self.assertFalse(cursor.update_engagement(17000))
        self.assertTrue(cursor.update_engagement(15000))

    def test_default_release_sits_above_normal_play(self):
        cursor = RelativeCursor()
        self.assertTrue(cursor.update_engagement(24000))
        self.assertFalse(cursor.update_engagement(37000))

    def test_axis_scale_makes_a_square_hand_move_draw_a_square(self):
        cursor = RelativeCursor()
        cursor.push((0.5, 0.5), 6000)
        # Same physical distance: the Y axis reports fewer counts.
        moved, _ = cursor.push((0.51, 0.5 + 0.01 * 0.648), 6000)
        self.assertAlmostEqual(moved[0] - 0.5, moved[1] - 0.5, places=6)

    def test_raising_the_hand_above_release_stops_the_cursor(self):
        cursor = RelativeCursor(z_engage=16000, z_release=20000)
        cursor.push((0.5, 0.5), 8000)
        cursor.push((0.52, 0.5), 21000)
        self.assertAlmostEqual(cursor.cursor[0], 0.5)
        self.assertFalse(cursor.engaged)


class AbsoluteCursorTests(unittest.TestCase):
    def test_sensor_edges_map_to_canvas_edges(self):
        cursor = AbsoluteCursor()
        self.assertEqual(cursor.target((0.0, 11534.0)), (0.0, 0.0))
        self.assertEqual(cursor.target((65535.0, 54002.0)), (1.0, 1.0))

    def test_a_square_hand_move_draws_a_square(self):
        # The Y axis reports 0.648 counts per X count for the same distance.
        cursor = AbsoluteCursor()
        left = cursor.target((10000.0, 30000.0))
        right = cursor.target((10000.0 + 10000.0, 30000.0 + 10000.0 * 0.648))
        self.assertAlmostEqual(right[0] - left[0], right[1] - left[1], places=6)

    def test_follow_rate_falls_with_height(self):
        cursor = AbsoluteCursor()
        self.assertAlmostEqual(cursor.alpha_at(4000), 1.0)
        self.assertAlmostEqual(cursor.alpha_at(24000), 0.12)
        self.assertLess(cursor.alpha_at(15000), cursor.alpha_at(6000))

    def test_resting_hand_sits_exactly_under_the_pointer(self):
        cursor = AbsoluteCursor()
        for _ in range(20):
            moved, _alpha = cursor.push((50000.0, 40000.0), 4000)
        target = cursor.target((50000.0, 40000.0))
        self.assertAlmostEqual(moved[0], target[0], places=6)
        self.assertAlmostEqual(moved[1], target[1], places=6)

    def test_reengaging_snaps_and_flags_the_frame(self):
        cursor = AbsoluteCursor()
        cursor.push((32768.0, 32768.0), 6000)
        cursor.push((32768.0, 32768.0), 40000)
        self.assertFalse(cursor.engaged)
        moved, _alpha = cursor.push((60000.0, 40000.0), 6000)
        self.assertTrue(cursor.rebased)
        self.assertAlmostEqual(moved[0], cursor.target((60000.0, 40000.0))[0], places=6)


    def test_a_lift_is_silence_not_a_rest(self):
        # Lifting the hand must not write a rest: that turned a 0.5 s lift
        # into a 70 tick hole in the melody.
        def row(index, y, z):
            return {"timestamp_ms": index * 5, "x": 32768, "y": y, "z": z, "position_valid": True}
        samples = [row(index, 20000 + index * 25, 6000) for index in range(400)]
        samples += [row(index, 30000 + (index - 400) * 20, 42000) for index in range(400, 500)]
        samples += [row(index, 32000 + (index - 500) * 25, 6000) for index in range(500, 900)]
        result = compile_lead(samples, pitch_source="cursor")
        self.assertFalse([event for event in result["events"] if event["type"] == "rest"])
        self.assertTrue([event for event in result["events"] if event["type"] == "note_on"])

    def test_note_durations_do_not_cross_the_next_event(self):
        # A 126 tick note used to overlap the rest that followed it.
        def row(index, y, z):
            return {"timestamp_ms": index * 5, "x": 32768, "y": y, "z": z, "position_valid": True}
        samples = [row(index, 20000 + index * 30, 6000) for index in range(300)]
        samples += [{"timestamp_ms": index * 5, "x": 65535, "y": 0, "z": 65535} for index in range(300, 600)]
        samples += [row(index, 29000 + (index - 600) * 20, 6000) for index in range(600, 900)]
        result = compile_lead(samples, pitch_source="cursor")
        events = [event for event in result["events"] if event["type"] in {"note_on", "rest"}]
        for index, event in enumerate(events):
            if event["type"] != "note_on":
                continue
            following = int(events[index + 1]["tick"]) if index + 1 < len(events) else STYLE.loop_ticks
            self.assertLessEqual(int(event["tick"]) + int(event["duration"]), following)


class StructureParameterTests(unittest.TestCase):
    def test_harmony_progression_comes_from_the_style(self):
        samples = []
        for index in range(64):
            row = _sample(index, x=3000 + index * 30, y=20000, z=6000)
            row["touch_flags"] = 1 if index in (0, 16) else 0
            samples.append(row)
        default = compile_loop(samples, {"bass": samples}, pitch_source="cursor")
        other = compile_loop(samples, {"bass": samples}, pitch_source="cursor",
                             style=SynthwaveStyle(harmony=("Dm", "Bb", "F", "C")))
        default_notes = [event["note"] for event in default["tracks"]["bass"]]
        other_notes = [event["note"] for event in other["tracks"]["bass"]]
        self.assertTrue(default_notes and other_notes)
        self.assertNotEqual(default_notes, other_notes)
        self.assertEqual(other_notes[0], 38)  # D2, from parse_chord("Dm")

    def test_scale_pitch_classes_drive_the_lead_scale(self):
        space = PitchSpace(scale_pitch_classes=(0, 4, 7))
        self.assertEqual(space.scale_pitches, (55, 60, 64, 67, 72))
        samples = [_sample(index, x=3000 + index * 40, y=20000 + index * 40, z=6000) for index in range(400)]
        result = compile_lead(samples, pitch_source="cursor", pitch_space=space)
        notes = [event["note"] for event in result["events"] if event["type"] == "note_on"]
        self.assertTrue(notes)
        for note in notes:
            self.assertIn(note, space.scale_pitches)

    def test_loop_length_and_tempo_are_parameterised(self):
        style = SynthwaveStyle(loop_bars=4, bpm=120)
        self.assertEqual(style.loop_ticks, 64)
        samples = [_sample(index, x=3000 + index * 40, y=20000 + index * 40, z=6000) for index in range(400)]
        result = compile_loop(samples, {}, style=style, pitch_source="cursor")
        for event in result["events"]:
            self.assertLess(int(event["tick"]), 64)


class VariationalSegmentTests(unittest.TestCase):
    def _capture(self, count=600):
        return [_sample(index, x=3000 + index * 30, y=20000 + index * 55, z=6000) for index in range(count)]

    def test_segments_are_on_scale_contiguous_and_deterministic(self):
        samples = self._capture()
        first = compile_lead(samples, pitch_source="cursor", note_source="variational", lam=6.0)
        second = compile_lead(samples, pitch_source="cursor", note_source="variational", lam=6.0)
        self.assertEqual(first["events"], second["events"])
        notes = [event for event in first["events"] if event["type"] == "note_on"]
        self.assertTrue(notes)
        for note in notes:
            self.assertIn(note["note"], DEFAULT_PITCH_SPACE.scale_pitches)
        for before, after in zip(notes, notes[1:]):
            self.assertEqual(before["tick"] + before["duration"], after["tick"])

    def test_min_segment_length_holds_except_at_the_tail(self):
        samples = self._capture()
        result = compile_lead(samples, pitch_source="cursor", note_source="variational", lam=6.0, min_segment=4)
        notes = [event for event in result["events"] if event["type"] == "note_on"]
        for note in notes[:-1]:
            self.assertGreaterEqual(note["duration"], 4)

    def test_larger_lambda_produces_fewer_notes(self):
        samples = self._capture()
        counts = []
        for lam in (0.5, 6.0, 30.0):
            result = compile_lead(samples, pitch_source="cursor", note_source="variational", lam=lam)
            counts.append(sum(1 for event in result["events"] if event["type"] == "note_on"))
        self.assertGreaterEqual(counts[0], counts[1])
        self.assertGreaterEqual(counts[1], counts[2])

    def test_variational_mode_emits_no_rests(self):
        samples = self._capture()
        result = compile_lead(samples, pitch_source="cursor", note_source="variational")
        self.assertFalse([event for event in result["events"] if event["type"] == "rest"])

    def test_density_maps_to_lambda_monotonically(self):
        values = [density_to_lambda(value) for value in (0.0, 0.25, 0.5, 0.75, 1.0)]
        self.assertEqual(values, sorted(values))
        self.assertAlmostEqual(values[0], 0.5)
        self.assertAlmostEqual(values[-1], 30.0)
        self.assertAlmostEqual(density_to_lambda(-1.0), 0.5)
        self.assertAlmostEqual(density_to_lambda(2.0), 30.0)


class IntentFeatureTests(unittest.TestCase):
    def _rise_then_fall(self):
        samples = [_sample(index, x=3000 + index * 20, y=20000 + index * 60, z=6000)
                   for index in range(300)]
        samples += [_sample(300 + index, x=3000 + (300 + index) * 20,
                            y=38000 - index * 60, z=6000) for index in range(300)]
        return samples

    def test_features_cover_every_tick_and_are_bounded(self):
        result = compile_lead(self._rise_then_fall(), pitch_source="cursor")
        features = result["intent"]
        self.assertEqual(len(features), 128)
        expected = {"tick", "pitch", "pitch_norm", "bow", "height", "speed",
                    "direction", "valid", "engaged"}
        for item in features:
            self.assertEqual(set(item), expected)
            if item["pitch"] is not None:
                self.assertGreaterEqual(item["pitch"], DEFAULT_PITCH_SPACE.min_midi - 1e-6)
                self.assertLessEqual(item["pitch"], DEFAULT_PITCH_SPACE.max_midi + 1e-6)
            for key in ("bow", "height"):
                if item[key] is not None:
                    self.assertGreaterEqual(item[key], -1e-6)
                    self.assertLessEqual(item[key], 1.0 + 1e-6)

    def test_direction_follows_a_rise_then_fall(self):
        result = compile_lead(self._rise_then_fall(), pitch_source="cursor")
        directions = [item["direction"] for item in result["intent"]]
        self.assertEqual(directions[0], 0)
        self.assertIn(1, directions)
        self.assertIn(-1, directions)
        self.assertGreater(result["diagnostics"]["intent_summary"]["reversals"], 0)

    def test_intent_layer_emits_no_events(self):
        result = compile_lead(self._rise_then_fall(), pitch_source="cursor")
        for item in result["intent"]:
            self.assertNotIn("type", item)
            self.assertNotIn("event_type", item)

    def test_intent_layer_is_deterministic(self):
        first = compile_lead(self._rise_then_fall(), pitch_source="cursor")
        second = compile_lead(self._rise_then_fall(), pitch_source="cursor")
        self.assertEqual(first["intent"], second["intent"])


class ArticulationTests(unittest.TestCase):
    def test_bow_attacks_counts_each_reversal(self):
        # A full oscillation has two extrema, so two attacks.
        self.assertEqual(bow_attacks([0.5, 0.6, 0.5, 0.4, 0.5, 0.6], 0.03), [1, 3])

    def test_bow_jitter_below_the_deadzone_is_ignored(self):
        self.assertEqual(bow_attacks([0.5, 0.51, 0.5, 0.51, 0.5], 0.03), [])

    def test_merge_leaps_drops_passing_degrees(self):
        merged = merge_leaps([(0, 4, 57), (4, 8, 60), (8, 12, 64), (12, 40, 67)], 3, 8)
        self.assertEqual(merged, [(0, 4, 57), (4, 40, 67)])

    def test_merge_leaps_keeps_a_real_dwell(self):
        segments = [(0, 4, 57), (4, 24, 60), (24, 28, 64), (28, 40, 67)]
        self.assertEqual(merge_leaps(segments, 3, 8), segments)

    def test_bow_reversals_split_a_held_pitch(self):
        samples = []
        for index in range(600):
            # y constant, x sweeps back and forth every 100 frames
            phase = (index // 100) % 2
            x = 30000 if phase == 0 else 42000
            samples.append(_sample(index, x=x, y=30000, z=6000))
        result = compile_lead(samples, pitch_source="cursor", note_source="variational", lam=6.0)
        notes = [event for event in result["events"] if event["type"] == "note_on"]
        self.assertGreaterEqual(len(notes), 4)
        self.assertEqual(len({note["note"] for note in notes}), 1)
        self.assertTrue(any(note.get("reattack") for note in notes))


class TouchGateTests(unittest.TestCase):
    def _capture(self, runs):
        frames = []
        for index in range(960):
            touching = any(start <= index < end for start, end in runs)
            row = _sample(index, x=3000 + index * 2, y=30000 + index * 10, z=6000)
            row["touch_flags"] = 1 if touching else 0
            frames.append(row)
        return frames

    def test_touch_gate_sounds_only_while_touching(self):
        samples = self._capture([(100, 160), (300, 340), (500, 560)])
        result = compile_lead(samples, pitch_source="cursor", note_source="variational",
                              lam=5.83, time_map="loop", gate_source="touch")
        notes = [event for event in result["events"] if event["type"] == "note_on"]
        self.assertGreaterEqual(len(notes), 3)
        for event in notes:
            self.assertEqual(event["gated_by"], "touch")

    def test_touch_gate_is_silent_without_contact(self):
        samples = self._capture([])
        result = compile_lead(samples, pitch_source="cursor", note_source="variational",
                              lam=5.83, time_map="loop", gate_source="touch")
        self.assertFalse([event for event in result["events"] if event["type"] == "note_on"])

    def test_bow_gate_stays_the_default(self):
        samples = self._capture([(100, 900)])
        result = compile_lead(samples, pitch_source="cursor", note_source="variational", lam=5.83)
        notes = [event for event in result["events"] if event["type"] == "note_on"]
        self.assertTrue(notes)
        self.assertTrue(all(event.get("gated_by") == "bow" for event in notes))


class TouchHoldTests(unittest.TestCase):
    def test_cursor_holds_still_while_touching(self):
        # Contact shifts the reported centroid about 10000 counts to the left;
        # the cursor must not follow that shift.
        cursor = make_cursor()
        start = cursor.push((40000, 30000, 6000), 6000)[0]
        held = cursor.push((30000, 30000, 6000), 6000, touching=True)[0]
        self.assertEqual(held, start)

    def test_release_snaps_and_flags_a_rebase(self):
        cursor = make_cursor()
        cursor.push((40000, 30000, 6000), 6000)[0]
        cursor.push((30000, 30000, 6000), 6000, touching=True)[0]
        released = cursor.push((30000, 30000, 6000), 6000)[0]
        self.assertAlmostEqual(released[0], 30000 / 65535.0, places=4)
        self.assertTrue(cursor.rebased)


class LoopTimeMapTests(unittest.TestCase):
    # _sample() advances 20 ms per frame, so 960 frames is one 19.2 s bar.

    def test_short_take_reports_partial_coverage(self):
        samples = [_sample(index, x=3000 + index * 20, y=34000, z=6000) for index in range(250)]
        result = compile_lead(samples, pitch_source="cursor", time_map="loop")
        self.assertLess(result["diagnostics"]["coverage"], 0.5)

    def test_full_bar_take_covers_the_loop(self):
        samples = [_sample(index, x=3000 + index * 5, y=34000, z=6000) for index in range(960)]
        result = compile_lead(samples, pitch_source="cursor", time_map="loop")
        self.assertAlmostEqual(result["diagnostics"]["coverage"], 1.0, places=2)

    def test_tick_positions_follow_absolute_time(self):
        # A pitch step at 1.5 s must land near tick 10 at 100 BPM (150 ms/tick),
        # whatever the take length, rather than at a fraction of the take.
        samples = [_sample(index, x=3000, y=20000 if index < 75 else 40000, z=6000)
                   for index in range(200)]
        ticks = resample_to_ticks(preprocess_samples(samples, pitch_source="cursor"), STYLE, "loop")
        before = float(ticks[9]["b_abs"])
        after = float(ticks[11]["b_abs"])
        self.assertLess(before, after)


class LoopLengthAndLayerTests(unittest.TestCase):
    # _sample() advances 20 ms per frame; a bar at 100 BPM is 2.4 s.

    def test_length_follows_the_take(self):
        samples = [_sample(index, x=3000 + index * 2, y=30000, z=6000) for index in range(2150)]
        self.assertEqual(length_from_take(samples, STYLE).loop_bars, 18)

    def test_length_is_capped(self):
        samples = [_sample(index, x=3000 + index * 2, y=30000, z=6000) for index in range(10000)]
        self.assertEqual(length_from_take(samples, STYLE, max_bars=32).loop_bars, 32)

    def test_auto_length_is_reported_in_the_table(self):
        samples = [_sample(index, x=3000 + index * 2, y=30000, z=6000) for index in range(2150)]
        result = compile_loop(samples, {}, auto_length=True)
        self.assertEqual(result["config"]["loop_bars"], 18)
        self.assertTrue(result["diagnostics"]["auto_length"])

    def test_layers_merge_and_tag_their_events(self):
        first = [_sample(index, x=3000 + index * 2, y=30000 + index * 8, z=6000) for index in range(960)]
        second = [_sample(index, x=3000 + index * 2, y=20000 + index * 14, z=6000) for index in range(960)]
        result = compile_loop(first, {}, lead_layers=[first, second], time_map="loop")
        layers = {event["layer"] for event in result["tracks"]["lead"] if event["type"] == "note_on"}
        self.assertEqual(layers, {0, 1})
        self.assertEqual(result["diagnostics"]["layers"], 2)
        self.assertEqual(len(result["diagnostics"]["layer_notes"]), 2)


    def test_auto_length_keeps_notes_beyond_the_default_grid(self):
        # Slow steps (three seconds each) so every plateau is long enough to
        # become a segment under the default minimum length.
        samples = [_sample(index, x=3000 + index * 2, y=30000 + ((index // 60) % 4) * 5000, z=6000)
                   for index in range(2150)]
        result = compile_loop(samples, {}, auto_length=True, note_source="variational", time_map="loop")
        ticks = [event["tick"] for event in result["tracks"]["lead"] if event["type"] == "note_on"]
        self.assertTrue(any(tick > 128 for tick in ticks))
        self.assertLessEqual(max(ticks), result["config"]["loop_bars"] * 16 - 1)


if __name__ == "__main__":
    unittest.main()

