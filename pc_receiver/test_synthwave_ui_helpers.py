import csv
import tempfile
import unittest
from pathlib import Path

from synthwave_ui import (DIAG_FIELDS, _DepthPathCache, _PixelPathCache, _append_diag_row, _capture_filename,
                          _clip_percent, _iso_point, _plot_rect, _preview_xy_z, _project_3d,
                          _project_point, _thin_path, _thin_xy_z,
                          _z_color)


class ThinPathTests(unittest.TestCase):
    def test_points_on_one_pixel_collapse(self):
        rows = [{"x": 0, "y": 0}, {"x": 0, "y": 0}, {"x": 0, "y": 0}]
        self.assertEqual(len(_thin_path(rows, 856, 451)), 1)

    def test_distinct_pixels_are_kept_in_capture_order(self):
        rows = [{"x": 0, "y": 0}, {"x": 32768, "y": 32768}, {"x": 65535, "y": 65535}]
        pixels = _thin_path(rows, 800, 400)
        self.assertEqual(len(pixels), 3)
        self.assertLess(pixels[0][0], pixels[1][0])
        self.assertLess(pixels[1][0], pixels[2][0])
        self.assertGreater(pixels[0][1], pixels[1][1])
        self.assertGreater(pixels[1][1], pixels[2][1])

    def test_output_is_bounded_by_canvas_area_not_capture_length(self):
        rows = [{"x": (index * 7919) % 65535, "y": (index * 104729) % 65535} for index in range(20000)]
        pixels = _thin_path(rows, 800, 400)
        self.assertLessEqual(len(pixels), 800 * 400)
        self.assertGreater(len(pixels), 100)

    def test_first_and_last_pixels_are_present(self):
        left, top, plot_w, plot_h = _plot_rect(800, 400)
        rows = [{"x": 0, "y": 0}, {"x": 30000, "y": 40000}, {"x": 65535, "y": 65535}]
        pixels = _thin_path(rows, 800, 400)
        self.assertAlmostEqual(pixels[0][0], left, places=6)
        self.assertAlmostEqual(pixels[0][1], top + plot_h, places=6)
        self.assertAlmostEqual(pixels[-1][0], left + plot_w, places=6)
        self.assertAlmostEqual(pixels[-1][1], top, places=6)

    def test_degenerate_canvas_does_not_invert_the_mapping(self):
        rows = [{"x": 0, "y": 0}, {"x": 65535, "y": 65535}]
        pixels = _thin_path(rows, 10, 10)
        self.assertEqual(len(pixels), 2)
        self.assertLessEqual(pixels[0][0], pixels[1][0])


class PixelPathCacheTests(unittest.TestCase):
    def test_incremental_appends_match_one_shot_thinning(self):
        rows = [{"x": (index * 7919) % 65535, "y": (index * 104729) % 65535} for index in range(600)]
        cache = _PixelPathCache()
        grown = []
        for row in rows:
            grown.append(row)
            incremental = list(cache.points(grown, 800, 400))
        self.assertEqual(incremental, _thin_path(rows, 800, 400))

    def test_resize_recomputes_from_scratch(self):
        rows = [{"x": index * 100, "y": index * 80} for index in range(200)]
        cache = _PixelPathCache()
        cache.points(rows, 800, 400)
        self.assertEqual(list(cache.points(rows, 400, 300)), _thin_path(rows, 400, 300))

    def test_shrinking_the_source_resets_the_cache(self):
        rows = [{"x": index * 100, "y": index * 80} for index in range(200)]
        cache = _PixelPathCache()
        cache.points(rows, 800, 400)
        smaller = rows[:3]
        self.assertEqual(list(cache.points(smaller, 800, 400)), _thin_path(smaller, 800, 400))

    def test_long_path_is_capped_to_the_point_budget(self):
        # Revisiting pixels must not grow the polyline without bound: a 120 s
        # take reached 7000 distinct points and a 7 ms redraw.
        rows = [{"x": (index * 997) % 65535, "y": (index * 1013) % 65535} for index in range(40000)]
        cache = _PixelPathCache(limit=2500)
        points = cache.points(rows, 856, 410)
        self.assertLessEqual(len(points), 2500)
        self.assertGreater(len(points), 500)


class DiagLogTests(unittest.TestCase):
    def test_header_is_written_once_and_rows_append(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "nested" / "ui.csv"
            _append_diag_row(path, {"rate_hz": 200.0, "queue": 0, "state": "recording"})
            _append_diag_row(path, {"rate_hz": 199.5, "queue": 3, "state": "recording"})
            with path.open(encoding="utf-8", newline="") as handle:
                rows = list(csv.DictReader(handle))
        self.assertEqual(len(rows), 2)
        self.assertEqual(list(rows[0].keys()), list(DIAG_FIELDS))
        self.assertEqual(rows[0]["rate_hz"], "200.0")
        self.assertEqual(rows[1]["queue"], "3")

    def test_unknown_fields_do_not_raise(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ui.csv"
            _append_diag_row(path, {"rate_hz": 1.0, "surprise": "ignored"})
            self.assertTrue(path.exists())


class ClipTests(unittest.TestCase):
    def test_rail_frames_are_counted(self):
        rows = [{"x": 0, "y": 100}, {"x": 65535, "y": 100},
                {"x": 30000, "y": 30000}, {"x": 30000, "y": 30000}]
        self.assertEqual(_clip_percent(rows), 50.0)

    def test_empty_capture_reports_zero(self):
        self.assertEqual(_clip_percent([]), 0.0)


class ViewRangeTests(unittest.TestCase):
    def test_a_square_workspace_draws_as_a_square(self):
        # The sensor area is square; one count must be worth the same number
        # of pixels on both axes or the drawing is distorted.
        points = _thin_path([{"x": 0, "y": 0}, {"x": 65535, "y": 65535}], 800, 400)
        dx = abs(points[-1][0] - points[0][0])
        dy = abs(points[-1][1] - points[0][1])
        self.assertAlmostEqual(dx, dy, places=6)

    def test_workspace_edges_map_to_the_plot_rect(self):
        points = _thin_path([{"x": 4000, "y": 4000}, {"x": 60000, "y": 50000}],
                            800, 400, x_range=(4000, 60000), y_range=(4000, 50000))
        self.assertAlmostEqual(points[0][1], 384.0, places=6)
        self.assertAlmostEqual(points[-1][1], 16.0, places=6)
        self.assertLess(points[0][0], points[-1][0])

    def test_projection_stays_fractional_so_the_line_is_not_a_staircase(self):
        first = _project_point({"x": 33000, "y": 30000}, 800, 400)
        second = _project_point({"x": 33030, "y": 30030}, 800, 400)
        self.assertNotEqual(first, second)

    def test_out_of_range_values_clamp_inside_the_plot(self):
        left, top, plot_w, plot_h = _plot_rect(800, 400)
        point = _project_point({"x": 90000, "y": -500}, 800, 400)
        self.assertGreaterEqual(point[0], left - 1e-9)
        self.assertLessEqual(point[0], left + plot_w + 1e-9)
        self.assertGreaterEqual(point[1], top - 1e-9)
        self.assertLessEqual(point[1], top + plot_h + 1e-9)

    def test_out_of_range_values_clamp_inside_the_plot(self):
        point = _project_point({"x": 90000, "y": -500}, 800, 400)
        self.assertGreaterEqual(point[0], 16.0)
        self.assertLessEqual(point[0], 784.0)
        self.assertGreaterEqual(point[1], 16.0)
        self.assertLessEqual(point[1], 384.0)


class IsoProjectionTests(unittest.TestCase):
    def test_the_three_axes_have_equal_length(self):
        import math
        origin = _iso_point(0.5, 0.5, 0.5, 800, 400)
        lengths = [math.dist(origin, _iso_point(0.5 + dx, 0.5 + dy, 0.5 + dz, 800, 400))
                   for dx, dy, dz in ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))]
        self.assertAlmostEqual(lengths[0], lengths[1], places=6)
        self.assertAlmostEqual(lengths[0], lengths[2], places=6)

    def test_projection_uses_the_cursor_fields(self):
        row = {"cursor_x": 0.5, "cursor_y": 0.5, "z_norm": 0.5}
        self.assertEqual(_project_3d(row, 800, 400), _iso_point(0.5, 0.5, 0.5, 800, 400))

    def test_missing_cursor_fields_fall_back_to_the_centre(self):
        self.assertEqual(_project_3d({}, 800, 400), _iso_point(0.5, 0.5, 0.5, 800, 400))


class CaptureFilenameTests(unittest.TestCase):
    def test_label_prefixes_the_capture(self):
        self.assertEqual(_capture_filename("z_sweep", "lead", "20261022-213000"),
                         "z_sweep_20261022-213000.jsonl")

    def test_spaces_and_symbols_become_underscores(self):
        self.assertEqual(_capture_filename("clutch cross/2", "lead", "T"),
                         "clutch_cross_2_T.jsonl")

    def test_empty_label_falls_back_to_the_track(self):
        self.assertEqual(_capture_filename("   ", "lead", "T"), "lead_T.jsonl")


class DepthEncodedPathTests(unittest.TestCase):
    def test_preview_coordinates_prefer_filtered_cursor_and_keep_depth(self):
        row = {"x": 1000, "y": 2000, "z": 3000,
               "cursor_x": 0.2, "cursor_y": 0.7, "z_norm": 0.9}
        self.assertEqual(_preview_xy_z(row), (0.2, 0.7, 0.9))

    def test_raw_position_rows_are_normalized_for_the_xy_view(self):
        x, y, z = _preview_xy_z({"x": 32767.5, "y": 65535, "z": 0})
        self.assertAlmostEqual(x, 0.5, places=6)
        self.assertAlmostEqual(y, 1.0, places=6)
        self.assertEqual(z, 0.0)

    def test_depth_color_runs_from_cool_to_warm(self):
        low = tuple(int(_z_color(0.0)[i:i + 2], 16) for i in (1, 3, 5))
        high = tuple(int(_z_color(1.0)[i:i + 2], 16) for i in (1, 3, 5))
        self.assertGreater(low[2], low[0])
        self.assertGreater(high[0], high[2])
        self.assertNotEqual(_z_color(0.25), _z_color(0.75))
        self.assertEqual(_z_color(-0.1), _z_color(0.0))
        self.assertEqual(_z_color(2.0), _z_color(1.0))

    def test_xy_path_keeps_depth_per_segment_and_preserves_endpoints(self):
        rows = [
            {"cursor_x": 0.0, "cursor_y": 0.0, "z_norm": 0.1},
            {"cursor_x": 0.5, "cursor_y": 0.5, "z_norm": 0.5},
            {"cursor_x": 1.0, "cursor_y": 1.0, "z_norm": 0.9},
        ]
        path = _thin_xy_z(rows, 800, 400)
        self.assertEqual(len(path), 3)
        self.assertEqual(path[0][2], 0.1)
        self.assertEqual(path[-1][2], 0.9)
        self.assertLess(path[0][0], path[-1][0])
        self.assertAlmostEqual(path[-1][0] - path[0][0], path[0][1] - path[-1][1])

    def test_pure_depth_changes_keep_xy_fixed_but_remain_visible(self):
        rows = [{"cursor_x": 0.4, "cursor_y": 0.6, "z_norm": z}
                for z in (0.0, 0.5, 1.0)]
        path = _thin_xy_z(rows, 800, 400)
        self.assertEqual(len(path), 3)
        self.assertEqual(len({point[:2] for point in path}), 1)
        self.assertEqual([point[2] for point in path], [0.0, 0.5, 1.0])

    def test_lift_and_invalid_frames_break_the_drawn_stroke(self):
        rows = [
            {"cursor_x": 0.1, "cursor_y": 0.2, "z_norm": 0.1},
            {"cursor_x": 0.2, "cursor_y": 0.3, "cursor_engaged": False},
            {"cursor_x": 0.3, "cursor_y": 0.4, "z_norm": 0.2},
            {"cursor_x": 0.4, "cursor_y": 0.5, "position_valid": False},
            {"cursor_x": 0.5, "cursor_y": 0.6, "z_norm": 0.3},
        ]
        path = _thin_xy_z(rows, 800, 400)
        self.assertEqual(len(path), 3)
        self.assertEqual(len({point[3] for point in path}), 3)

    def test_long_capture_keeps_both_ends_and_stroke_breaks_when_thinned(self):
        rows = [{"cursor_x": (i % 100) / 100, "cursor_y": (i % 80) / 80,
                 "z_norm": i / 4999, "cursor_engaged": i != 2500}
                for i in range(5000)]
        path = _DepthPathCache(limit=128).points(rows, 800, 400)
        self.assertLessEqual(len(path), 128)
        self.assertEqual(path[0][2], 0.0)
        self.assertEqual(path[-1][2], 1.0)
        self.assertEqual({point[3] for point in path}, {0, 1})

    def test_incremental_depth_cache_matches_full_replay_and_resizes(self):
        rows = [{"cursor_x": i / 199, "cursor_y": 0.5, "z_norm": i / 199}
                for i in range(200)]
        cache = _DepthPathCache()
        growing = []
        for row in rows:
            growing.append(row)
            path = cache.points(growing, 800, 400)
        self.assertEqual(path, _thin_xy_z(rows, 800, 400))
        self.assertEqual(cache.points(growing, 400, 300), _thin_xy_z(rows, 400, 300))


if __name__ == "__main__":
    unittest.main()
