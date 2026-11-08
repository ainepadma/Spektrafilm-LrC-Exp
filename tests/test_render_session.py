"""Check the Lua-compatible render queue with real film profiles and synthetic photos."""

import base64
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

import numpy as np
from PIL import Image
import tifffile


ROOT = Path(__file__).resolve().parents[1]


class RenderSessionTest(unittest.TestCase):
    def setUp(self):
        runtime = ROOT / ".runtime"
        runtime.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="测试 % & ", dir=runtime)
        self.session = Path(self.temp.name)
        self.log = (self.session / "test.log").open("wb")
        self.process = subprocess.Popen(
            [sys.executable, ROOT / "bridge" / "worker.py", "serve", "--session", self.session],
            stdout=self.log, stderr=subprocess.STDOUT,
        )
        self.addCleanup(self.stop)
        self.wait_for("ready.txt")

    def stop(self):
        (self.session / "stop.txt").mkdir(exist_ok=True)
        try:
            self.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise
        finally:
            self.log.close()
            self.temp.cleanup()

    def wait_for(self, filename):
        target = self.session / filename
        deadline = time.monotonic() + 180
        while not target.exists():
            self.assertIsNone(self.process.poll(), "Worker exited before replying")
            self.assertLess(time.monotonic(), deadline, f"Timed out waiting for {filename}")
            time.sleep(0.03)
        return target

    def enqueue(self, number, args):
        job = self.session / f"request-{number:08d}.job"
        job.mkdir()
        encoded = base64.urlsafe_b64encode("\0".join(map(str, args)).encode()).decode()
        for start in range(0, len(encoded), 80):
            (job / f"{1 + start // 80:04d}_{encoded[start:start + 80]}").mkdir()
        (job / "complete").mkdir()
        return self.wait_for(f"response-{number:08d}.txt").read_text(encoding="utf-8")

    def test_queue_recovery_and_preview_consistency(self):
        # An unpublished request must not block a committed request.
        (self.session / "request-00000000.job").mkdir()
        invalid = self.enqueue(1, ["invalid"])
        self.assertTrue(invalid.startswith("error\n"))
        source = self.session / "光影.tif"
        ramp = np.linspace(5000, 55000, 96, dtype=np.uint16)
        red, green = np.meshgrid(ramp, ramp)
        tifffile.imwrite(source, np.stack([red, green, red // 2 + green // 2], -1),
                         photometric="rgb")
        recipe = ["render", "--input", source, "--film", "kodak_portra_400",
                  "--paper", "kodak_portra_endura"]
        frames = []
        for number, flags in ((2, ["--preview"]), (3, [])):
            out = self.session / f"frame-{number}.jpg"
            self.assertEqual(self.enqueue(number, [*recipe, "--output", out, *flags]), "ok\n")
            with Image.open(out) as image:
                frames.append(np.array(image, dtype=np.float64))
        self.assertLess(np.abs(frames[1] - frames[0]).mean(), 4.0)

        # Change dimensions and content under the same filename. A persistent
        # simulator may reuse spectral tables, but never pixel buffers from a prior job.
        tifffile.imwrite(source, np.full((48, 70, 3), 49000, np.uint16), photometric="rgb")
        replaced = self.session / "new.jpg"
        self.assertEqual(self.enqueue(4, [*recipe, "--output", replaced, "--preview"]), "ok\n")
        with Image.open(replaced) as image:
            self.assertEqual(image.size, (70, 48))
            self.assertGreater(np.asarray(image).mean(), frames[0].mean() + 3)
        self.assertFalse((self.session / "response-00000000.txt").exists())


if __name__ == "__main__":
    unittest.main()
