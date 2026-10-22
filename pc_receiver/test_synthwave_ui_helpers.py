import unittest

from synthwave_ui import _PixelPathCache, _thin_path


class ThinPathTests(unittest.TestCase):
    def test_points_on_one_pixel_collapse(self):
        rows = [{"x": 0, "y": 0}, {"x": 1, "y": 1}, {"x": 2, "y": 2}]
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
        rows = [{"x": 0, "y": 0}, {"x": 30000, "y": 40000}, {"x": 65535, "y": 65535}]
        pixels = _thin_path(rows, 800, 400)
        self.assertEqual(pixels[0], (28, 372))
        self.assertEqual(pixels[-1], (772, 28))

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


if __name__ == "__main__":
    unittest.main()