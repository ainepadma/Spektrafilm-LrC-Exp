"""Exercise the real renderer without loading Lightroom or using any user photos."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image, ImageCms
import tifffile


ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "bridge" / "worker.py"


class FilmRenderTest(unittest.TestCase):
    def test_profile_lookup_and_export(self):
        runtime = ROOT / ".runtime"
        runtime.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=runtime, prefix="测试 & ") as folder:
            work = Path(folder)
            profiles = work / "profiles.tsv"
            self.worker("profiles", "--output", profiles)
            rows = profiles.read_text(encoding="utf-8-sig").splitlines()
            film = "kodak_portra_400"
            paper = "kodak_portra_endura"
            self.assertIn("film\t" + film, rows)
            self.assertIn("paper\t" + paper, rows)

            # A 16-bit sRGB ramp exercises the same boundary as an LrC export.
            ramp = np.linspace(1000, 60000, 96, dtype=np.uint16)
            red, green = np.meshgrid(ramp, ramp)
            rgb = np.stack([red, green, red // 2 + green // 2], axis=-1)
            source = work / "输入.tif"
            icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
            tifffile.imwrite(source, rgb, photometric="rgb", iccprofile=icc)
            for ext in ("jpg", "tif"):
                output = work / f"成片.{ext}"
                self.worker(
                    "render", "--input", source, "--output", output,
                    "--film", film, "--paper", paper,
                )
                with Image.open(output) as photo:
                    self.assertEqual(photo.size, (96, 96))
                    self.assertTrue(photo.info.get("icc_profile"))
                    rendered = np.asarray(photo.convert("RGB")).astype(np.float32)
                    self.assertGreater(rendered.std(), 2)
                    self.assertGreater(np.abs(rendered - rgb / 257).mean(), 1)
                if ext == "tif":
                    self.assertEqual(tifffile.imread(output).dtype, np.uint16)

    def test_one_stop_input_exposure_survives_rendering(self):
        runtime = ROOT / ".runtime"
        runtime.mkdir(exist_ok=True)
        # Encode the same neutral ramp at two exposures, doubling scene-linear
        # light before sRGB encoding as a one-stop Lightroom adjustment would.
        ramp = np.linspace(0.04, 0.28, 96)
        linear = np.broadcast_to(ramp[None, :, None], (96, 96, 3))
        icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
        with tempfile.TemporaryDirectory(dir=runtime, prefix="exposure-") as folder:
            medians = []
            for exposure in (1, 2):
                encoded = 1.055 * (linear * exposure) ** (1 / 2.4) - 0.055
                source = Path(folder) / f"input-{exposure}.tif"
                output = Path(folder) / f"output-{exposure}.tif"
                tifffile.imwrite(source, np.rint(encoded * 65535).astype(np.uint16),
                                 photometric="rgb", iccprofile=icc)
                self.worker("render", "--input", source, "--output", output,
                            "--film", "kodak_portra_400", "--paper", "kodak_portra_endura")
                central_patch = tifffile.imread(output)[16:-16, 24:-24]
                medians.append(float(np.median(central_patch)) / 65535)
            # A modest margin tolerates stochastic grain while catching exposure
            # normalization that would neutralize a user's brightness adjustment.
            self.assertGreater(medians[1] - medians[0], 0.015, msg=str(medians))

    def worker(self, *args):
        result = subprocess.run(
            [sys.executable, WORKER, *args], cwd=ROOT,
            capture_output=True, timeout=600,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))


if __name__ == "__main__":
    unittest.main()
