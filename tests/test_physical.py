"""Validate accelerated emulsion sampling against the native physical model."""

from pathlib import Path
import sys
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from bridge import worker
worker.configure_runtime()
from bridge.physical import PhysicalSimulator, particle_planes
from bridge.recipe import Physical, make_params
from spektrafilm import Simulator
from spektrafilm.model.grain import layer_particle_model
from spektrafilm.runtime.pipeline import SimulationPipeline


class PhysicalGrainTest(unittest.TestCase):
    def test_particle_mean_and_rms_in_toe_midscale_and_shoulder(self):
        axis = np.array([0., 1.])
        curves = np.tile(axis[:, None], (1, 3))
        for probability in (.04, .5, .985):
            density = np.full((152, 176), probability)
            layers = particle_planes(density, axis, curves, np.zeros(3),
                                     np.ones(3), np.full(3, 48.), .97, False, 0)
            saturation = 1 - probability * .97 * (1 - 1e-6)
            expected_rms = np.sqrt(probability * saturation / 48.)
            reference = layer_particle_model(density, density_max=1, n_particles_per_pixel=48,
                                             grain_uniformity=.97, seed=12)
            for plane in (*layers, reference):
                self.assertAlmostEqual(plane.mean(), probability, delta=expected_rms * .03)
                self.assertAlmostEqual(plane.std(), expected_rms, delta=expected_rms * .03)
            self.assertLess(abs(np.corrcoef(layers[0].ravel(), layers[1].ravel())[0, 1]), .03)

    def test_spatial_correlation_and_density_of_multilayer_grain(self):
        # Select native-size pixel pitch even in a short test image to exercise
        # dye-cloud and final grain blur. Compare stock-specific layer response.
        from spektrafilm.model.grain import apply_grain
        for film, paper in (("kodak_portra_400", "kodak_portra_endura"),
                            ("fujifilm_provia_100f", "kodak_portra_endura"),
                            ("ilford_hp5_plus_400", "ilford_multigrade_iv_rc")):
            params = make_params(film, paper, Physical(grain=1.5, glare_on=False))
            model = PhysicalSimulator(params, pipeline_factory=SimulationPipeline)
            density = np.full((180, 192, 3), .7)
            old = apply_grain(density.copy(), 6., params.film_render.grain,
                              model.curves, model.layers, params.film.info.type)
            new = model.multilayer_grain(density, 6.)
            for ch in range(3):
                a, b = old[4:-4, 4:-4, ch], new[4:-4, 4:-4, ch]
                self.assertGreater(a.std(), 1e-4)
                self.assertLess(abs(b.mean() - a.mean()), .08 * a.std())
                self.assertAlmostEqual(b.std() / a.std(), 1., delta=.06)
                old_corr = np.corrcoef(a[:, :-1].ravel(), a[:, 1:].ravel())[0, 1]
                new_corr = np.corrcoef(b[:, :-1].ravel(), b[:, 1:].ravel())[0, 1]
                self.assertLess(abs(new_corr - old_corr), .04)

    def test_full_frame_image_keeps_color_and_texture(self):
        # Exercise the actual large-frame dispatch + resumed print/scan path.
        # Comparing smoothed patches avoids expecting identical silver crystals.
        params = make_params("kodak_portra_400", "kodak_portra_endura",
                             Physical(format_mm=8, grain=1.5, glare_on=False))
        x, y = np.meshgrid(np.linspace(.1, .85, 56), np.linspace(.15, .9, 36))
        tiles = np.stack((x, y, .4*x+.6*y), axis=2)
        source = tiles.repeat(12, axis=0).repeat(12, axis=1)
        old = Simulator(params).process(source)
        new = PhysicalSimulator(params).process(source)
        def centers(image):
            return image.reshape(36, 12, 56, 12, 3)[:, 3:-3, :, 3:-3, :]
        old_patch, new_patch = centers(old), centers(new)
        np.testing.assert_allclose(new_patch.mean(axis=(0, 1, 2, 3)),
                                   old_patch.mean(axis=(0, 1, 2, 3)), atol=.0005)
        old_rms = old_patch.std(axis=(1, 3)).mean()
        new_rms = new_patch.std(axis=(1, 3)).mean()
        self.assertAlmostEqual(new_rms / old_rms, 1, delta=.06)


if __name__ == "__main__":
    unittest.main()
