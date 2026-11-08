"""The Lightroom script and package entry point must share the same JIT cache."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

import numpy as np
import tifffile


ROOT = Path(__file__).resolve().parents[1]


class BridgeImportTest(unittest.TestCase):
    def test_script_then_module_loads_compiled_particle_kernel(self):
        runtime = ROOT / ".runtime"
        runtime.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=runtime) as scratch:
            folder = Path(scratch)
            source = folder / "source.tif"
            tifffile.imwrite(source, np.full((480, 512, 3), 32000, dtype=np.uint16), photometric="rgb")
            args = ["render", "--input", str(source), "--film", "kodak_portra_400", "--paper", "auto"]
            env = {**os.environ, "NUMBA_DEBUG_CACHE": "1"}
            for index, (entry, cwd) in enumerate((
                ([str(ROOT / "bridge" / "worker.py")], folder), (["-m", "bridge.worker"], ROOT)
            )):
                result = subprocess.run([sys.executable, *entry, *args, "--output", str(folder / f"{index}.jpg")],
                                        cwd=cwd, env=env, capture_output=True, timeout=300)
                log = (result.stderr + result.stdout).decode("utf-8", "replace")
                self.assertEqual(result.returncode, 0, log)
                if index == 1:
                    self.assertRegex(log, r"data loaded from [^\n]*physical\.particle_planes")


if __name__ == "__main__":
    unittest.main()
