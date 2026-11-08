"""Compare fast export interpolation to the engine's pointwise color mode."""

from pathlib import Path
import sys
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bridge import worker
worker.configure_runtime()
from bridge import fast_color
from spektrafilm import init_params, simulate


class FastColorTest(unittest.TestCase):
    def test_matches_direct_color_mode_at_unsampled_rgb_values(self):
        # Include black, white, primaries and values between the LUT grid points.
        image = np.random.default_rng(321).random((64, 64, 3), dtype=np.float32)
        image[0, :5] = [(0, 0, 0), (1, 1, 1), (1, 0, 0), (0, 1, 0), (0, 0, 1)]
        film, paper = "kodak_portra_400", "kodak_portra_endura"
        params = init_params(film_profile=film, print_profile=paper)
        params.io.input_color_space = params.io.output_color_space = "sRGB"
        params.io.input_cctf_decoding = params.io.output_cctf_encoding = True
        params.debug.lut_mode = True
        params.settings.use_enlarger_lut = params.settings.use_scanner_lut = True
        params.settings.lut_resolution = 33
        reference = simulate(image, params)
        difference = np.abs(fast_color.apply(image, film, paper) - reference)
        self.assertLess(difference.mean(), 1 / 255)
        self.assertLess(np.quantile(difference, 0.99), 2 / 255)


if __name__ == "__main__":
    unittest.main()
