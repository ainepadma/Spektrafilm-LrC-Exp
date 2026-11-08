"""The optimized scanner should implement the native tone and chroma response."""
import warnings
import unittest

import numpy as np
from bridge.worker import configure_runtime
configure_runtime()

from bridge.recipe import Physical, make_params
from bridge.scanner import compress_scan, make_pipeline
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.utils.gamut_compression import OutputGamutCompressSpec, compress_rgb


class ScannerTest(unittest.TestCase):
    def test_cam16_equivalence_across_gamuts(self):
        rng = np.random.default_rng(175)
        rgb = rng.uniform(0, 1.8, (48, 65, 3))
        rgb[0, :4] = [(0,0,0), (0,1,0), (1,0,0), (-.002,.1,.4)]
        for name in ("sRGB", "ProPhoto RGB", "Display P3"):
            for shoulder in ((.7,1.,2.2), None):
                spec = OutputGamutCompressSpec(lightness_compression=shoulder)
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", RuntimeWarning)
                    expected = compress_rgb(rgb,spec,output_color_space=name)
                    actual = compress_scan(rgb,spec,name)
                np.testing.assert_allclose(actual,expected,atol=1.e-10,rtol=1.e-10)

    def test_film_and_paper_taps_match_native_pipeline(self):
        # Keep spatial optics and disable random noise for a pixel-for-pixel comparison.
        source = np.random.default_rng(34).random((73,96,3))
        for scan in (False, True):
            recipe = Physical(grain_on=False, glare_on=False, scan=scan)
            params = make_params("kodak_portra_400","kodak_portra_endura",recipe)
            native = SimulationPipeline(params).process(source)
            optimized = make_pipeline(params).process(source)
            np.testing.assert_allclose(optimized,native,atol=1.e-9,rtol=1.e-9)
