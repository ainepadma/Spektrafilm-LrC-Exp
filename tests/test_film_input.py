"""Check the fused input projection against the pinned spectral engine."""

from pathlib import Path
import sys
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from bridge.worker import configure_runtime
configure_runtime()
from bridge.film_input import install_projection
from bridge.recipe import Physical, make_params
from spektrafilm.runtime.pipeline import SimulationPipeline


class FilmInputTest(unittest.TestCase):
    def test_projection_matches_native_raw_exposure(self):
        samples = np.random.default_rng(3721).uniform(-.2, 1.8, (32, 48, 3))
        samples[0, :8] = [
            [0., 0., 0.], [1., 1., 1.], [1., 0., 0.], [0., 1., 0.], [0., 0., 1.],
            [.04045, .0031308 * 12.92, .03125], [1.e-13, 2.e-13, 0.], [0., -.4, .5],
        ]
        for film, paper in (("kodak_portra_400", "kodak_portra_endura"),
                            ("kodak_vision3_500t", "kodak_2383"),
                            ("ilford_hp5_plus_400", "ilford_multigrade_iv_rc")):
            params = make_params(film, paper, Physical())
            if film == "kodak_portra_400":
                params.camera.filter_uv = (0.5, 420., 8.)
            pipeline = SimulationPipeline(params)
            stage = pipeline._filming_stage
            native = stage._rgb_to_film_raw
            install_projection(pipeline)
            for space in ("sRGB", "Display P3", "ProPhoto RGB", "Adobe RGB (1998)"):
                for decode in (False, True):
                    with self.subTest(film=film, space=space, decode=decode):
                        options = dict(color_space=space, apply_cctf_decoding=decode)
                        # The fallback transfer function expects nonnegative code values.
                        input_rgb = np.maximum(samples, 0.) if space == "Adobe RGB (1998)" else samples
                        np.testing.assert_allclose(stage._rgb_to_film_raw(input_rgb, **options),
                                                   native(input_rgb, **options), rtol=1e-11, atol=1e-11)


if __name__ == "__main__":
    unittest.main()
