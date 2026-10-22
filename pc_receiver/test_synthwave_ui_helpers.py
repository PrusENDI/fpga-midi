import csv
import tempfile
import unittest
from pathlib import Path

from synthwave_ui import (DIAG_FIELDS, _PixelPathCache, _append_diag_row, _clip_percent,
                          _plot_rect, _project_point, _thin_path)


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
        self.assertAlmostEqual(points[0][1], 372.0, places=6)
        self.assertAlmostEqual(points[-1][1], 28.0, places=6)
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
        self.assertGreaterEqual(point[0], 28.0)
        self.assertLessEqual(point[0], 772.0)
        self.assertGreaterEqual(point[1], 28.0)
        self.assertLessEqual(point[1], 372.0)


if __name__ == "__main__":
    unittest.main()