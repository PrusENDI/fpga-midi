import math
import unittest

from tools import test_v2_spectrum as spectrum


class SpectrumAnalyzerTests(unittest.TestCase):
    def test_sideband_ratio_detects_known_spur(self):
        samples = [
            1000.0 * math.sin(2.0 * math.pi * 220.0 * n / 48000.0)
            + 300.0 * math.sin(2.0 * math.pi * 3000.0 * n / 48000.0)
            for n in range(4096)
        ]
        report = spectrum.analyze(samples, tone_count=1)
        self.assertGreater(report["sideband_ratio"], 0.02)


if __name__ == "__main__":
    unittest.main()
