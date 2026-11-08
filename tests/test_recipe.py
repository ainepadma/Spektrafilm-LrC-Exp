"""Real film, print, direct-scan, latitude and color-grading regression checks."""

from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest

import numpy as np
import tifffile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from bridge import worker
worker.configure_runtime()
from bridge import fast_color
from bridge import grade
from bridge.recipe import Physical, make_params, parse_recipe
from bridge import print_output


class RecipeTest(unittest.TestCase):
    film = "kodak_portra_400"
    paper = "kodak_portra_endura"

    @classmethod
    def setUpClass(cls):
        x, y = np.meshgrid(np.linspace(.02,.96,64), np.linspace(.04,.91,48))
        cls.image = np.stack([x, y, (x+y)/2], axis=-1).astype(np.float32)

    def test_stock_recommendations_and_auto_positive_scan(self):
        profiles = worker.profiles()
        self.assertEqual(profiles["film"]["kodak_vision3_500t"]["target_print"], "kodak_2383")
        self.assertIn("kodak_2383", profiles["paper"])
        positive = "fujifilm_provia_100f"
        first = fast_color.apply(self.image, positive, self.paper)
        second = fast_color.apply(self.image, positive, "kodak_2383",
                                  Physical(scan=True, print_ev=2, yellow=1))
        np.testing.assert_allclose(first, second, atol=1e-5)

    def test_real_stock_exposures_and_color_balance(self):
        def image(**kwargs):
            return fast_color.apply(self.image, self.film, self.paper, Physical(**kwargs))

        base = image()
        self.assertGreater(image(print_ev=1).mean(), base.mean() + .03)
        self.assertGreater(image(film_ev=1).mean(), base.mean() + .03)
        for change in ({"yellow": .8}, {"magenta": -.8}, {"preflash": .025}, {"scan": True}):
            self.assertGreater(np.mean(np.abs(image(**change)-base)), .005)
        # A quick LUT contains no spatial texture or random glare.
        np.testing.assert_allclose(image(grain=2, halation=3, glare=10), base)

    def test_silver_stocks_and_no_layer_cinema_negative(self):
        silver_paper = "ilford_multigrade_iv_rc"
        tones = []
        for film in ("kodak_tri_x_400", "ilford_hp5_plus_400"):
            self.assertEqual(worker.resolve_paper(worker.profiles(), film, "auto"), silver_paper)
            for pixels in (worker.simulator(film, silver_paper, False).process(self.image),
                           fast_color.apply(self.image, film, silver_paper)):
                grey = grade.silver_output(pixels, "sRGB")
                self.assertTrue(np.isfinite(grey).all())
                self.assertGreater(grey.std(), .05)
                np.testing.assert_array_equal(grey[..., 0], grey[..., 2])
            tones.append(grey)
            with self.assertRaises(ValueError):
                make_params(film, self.paper, Physical())
            metrics = grade.diagnostics(self.image, film, silver_paper, Physical(), "sRGB", {})
            self.assertGreater(metrics["film_high"], metrics["medium_high"])
        self.assertGreater(np.mean(np.abs(tones[0] - tones[1])), .015)

        source = np.full((128, 128, 3), .05)
        source[60:68, 60:68] = 1
        optics = Physical(format_mm=4, grain_on=False, glare_on=False, couplers_on=False, boost=3)
        base = worker.simulator("kodak_vision3_500t", "kodak_2383", True, optics).process(source)
        bare = worker.simulator("cinestill_800t", "kodak_2383", True, optics).process(source)
        self.assertGreater(bare[59, 64, 0] - base[59, 64, 0], .02)

    def test_grain_radius_and_layer_behavior(self):
        opts = Physical(grain=2, format_mm=56, antihalation=False, halation=2,
                        scatter=.5, boost=3, couplers=.6, glare=2)
        params = make_params(self.film, self.paper, opts, preview=True, frame_fraction=.5)
        self.assertEqual(params.camera.film_format_mm, 28)
        self.assertEqual(params.film.info.antihalation, "no")
        self.assertTrue(params.film_render.grain.active)
        self.assertAlmostEqual(params.film_render.grain.particle_area_um2, .8)
        self.assertAlmostEqual(params.film_render.halation.halation_amount, 2)
        self.assertAlmostEqual(params.film_render.halation.scatter_amount, .5)
        self.assertAlmostEqual(params.film_render.halation.boost_ev, 3)
        self.assertAlmostEqual(params.film_render.dir_couplers.amount, .6)
        self.assertAlmostEqual(params.print_render.glare.percent, .06)
        rgb = np.full((72,96,3), .45, dtype=np.float32)
        coarse = worker.simulator(self.film, self.paper, True, Physical(
            grain=2, format_mm=4, glare_on=False)).process(rgb)
        clear = worker.simulator(self.film, self.paper, True, Physical(
            grain_on=False, format_mm=4, glare_on=False)).process(rgb)
        self.assertGreater(coarse[...,1].std(), clear[...,1].std() + .001)

    def test_grading_and_validation(self):
        _, opts = parse_recipe({"curves":{"red":[[0,0],[.5,.7],[1,1]]},
                                "zones":{"shadows":{"hue":240,"saturation":.7}}})
        out = grade.grade(self.image, opts, "sRGB")
        self.assertGreater(out[...,0].mean(), self.image[...,0].mean())
        self.assertGreater(out[:4,:4,2].mean(), self.image[:4,:4,2].mean())
        self.assertIs(grade.grade(self.image, {}, "sRGB"), self.image)
        for invalid in ({"grain":3}, {"film_ev": True}, {"glare_on":1}, {"typo":4},
                        {"curves":{"rgb":[[0,0],[0,.3],[1,1]]}}):
            with self.assertRaises(ValueError): parse_recipe(invalid)

    def test_measured_scene_placement(self):
        ramp = np.linspace(.03,.9,96)
        target = np.broadcast_to(ramp[None,:,None], (40,96,3)).copy()
        args = (target, self.film, self.paper, Physical(), "sRGB")
        before = grade.diagnostics(*args, {})
        self.assertLess(before["medium_low"], 0)
        self.assertGreater(before["medium_high"], 0)
        self.assertGreater(before["film_high"], before["medium_high"])
        pull = before["suggest_shadow"]
        self.assertGreater(pull, 0)
        after = grade.diagnostics(*args, {"shadow_pull":pull})
        self.assertLess(after["shadow_pct"], before["shadow_pct"])
        moved = grade.placement(target, {"shadow_pull":pull}, "sRGB")
        self.assertTrue(np.all(np.diff(moved[0,:,0]) >= 0))
        self.assertGreater(moved[0,0,0], target[0,0,0])
        np.testing.assert_allclose(moved[0,-1],target[0,-1],atol=1e-5)

    def test_half_frames_use_independent_stock_and_post_recipe(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".runtime") as folder:
            path = Path(folder)
            source, output = path / "in.tif", path / "pair.tif"
            tifffile.imwrite(source, np.rint(self.image * 65535).astype(np.uint16), photometric="rgb")
            settings = {"brightness": 40, "print_ev": .5}
            subprocess.run([
                sys.executable, str(ROOT / "bridge" / "worker.py"), "render",
                "--input", str(source), "--output", str(output), "--film", self.film,
                "--paper", self.paper, "--preview", "--pair-input", str(source),
                "--pair-film", "ilford_hp5_plus_400", "--pair-paper", "auto",
                "--pair-mode", "fast-color", "--pair-recipe", json.dumps(settings),
            ], check=True, timeout=120)
            pair = tifffile.imread(output) / 65535
            width = round(self.image.shape[0] * 18 / 24)
            left, right = pair[:, :width], pair[:, -width:]
            self.assertGreater(np.mean(np.abs(left[...,0]-left[...,2])), .01)
            np.testing.assert_array_equal(right[...,0], right[...,2])
            physical, post = parse_recipe(settings)
            expected = fast_color.apply(worker.read_input(source), "ilford_hp5_plus_400",
                                        "ilford_multigrade_iv_rc", physical)
            expected = grade.grade(grade.silver_output(expected, "sRGB"), post, "sRGB")
            expected = print_output.crop(expected, 18/24)
            np.testing.assert_allclose(right, expected, atol=2/65535)


if __name__ == "__main__":
    unittest.main()
