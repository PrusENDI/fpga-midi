import unittest

from synthwave_ui import _downsample


def _rows(count):
    return [{"x": index, "y": index, "z": 0} for index in range(count)]


class DownsampleTests(unittest.TestCase):
    def test_short_capture_is_returned_untouched(self):
        rows = _rows(10)
        self.assertIs(_downsample(rows, limit=1500), rows)

    def test_long_capture_is_thinned_but_keeps_both_endpoints(self):
        rows = _rows(9000)
        thinned = _downsample(rows, limit=1500)
        self.assertLessEqual(len(thinned), 1501)
        self.assertGreater(len(thinned), 1000)
        self.assertIs(thinned[0], rows[0])
        self.assertIs(thinned[-1], rows[-1])

    def test_thinning_preserves_order(self):
        rows = _rows(4000)
        xs = [row["x"] for row in _downsample(rows, limit=500)]
        self.assertEqual(xs, sorted(xs))
        self.assertEqual(len(xs), len(set(xs)))

    def test_degenerate_limit_returns_input(self):
        rows = _rows(100)
        self.assertIs(_downsample(rows, limit=1), rows)


if __name__ == "__main__":
    unittest.main()
