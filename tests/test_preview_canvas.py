import unittest
from pathlib import Path

import numpy as np
from PIL import Image

from bridge.preview_canvas import MATTE, PADDING, fit_preview, parse_box


class PreviewCanvasTests(unittest.TestCase):
    def test_portrait_landscape_and_square_fit_without_cropping(self):
        size = (640, 384)
        for source in [(36, 24), (24, 36), (30, 30), (650, 240)]:
            with self.subTest(source=source):
                photo = Image.new("RGB", source, "white")
                photo.paste("red", (0, 0, source[0], source[1] // 2))
                canvas = np.asarray(fit_preview(photo, size))
                rows, cols = np.nonzero(np.any(canvas != MATTE, axis=2))
                self.assertEqual(canvas.shape, (size[1], size[0], 3))
                left, right = cols.min(), cols.max()
                top, bottom = rows.min(), rows.max()
                self.assertGreaterEqual(min(left, top), PADDING)
                self.assertLessEqual(abs((right - left + 1) / (bottom - top + 1)
                                         - source[0] / source[1]), .02)
                self.assertLessEqual(abs(left - (size[0] - 1 - right)), 1)
                self.assertLessEqual(abs(top - (size[1] - 1 - bottom)), 1)
                self.assertTupleEqual(tuple(canvas[top, left]), (255, 0, 0))
                self.assertTupleEqual(tuple(canvas[bottom, right]), (255, 255, 255))

    def test_plugin_idle_assets_match_each_canvas(self):
        assets = Path(__file__).resolve().parents[1] / "Spektrafilm.lrplugin" / "preview"
        for name in ("420x264", "640x384", "832x468"):
            with Image.open(assets / (name + ".png")) as image:
                self.assertEqual(image.size, parse_box(name))
                self.assertEqual(image.getpixel((0, 0)), MATTE)

    def test_small_source_is_centered_at_its_native_resolution(self):
        pixels = np.zeros((80, 137, 3), np.uint8)
        pixels[:, ::2] = (254, 128, 4)
        result = np.asarray(fit_preview(Image.fromarray(pixels), parse_box("2560x1440")))
        y, x = (1440-80)//2, (2560-137)//2
        np.testing.assert_array_equal(result[y:y+80, x:x+137], pixels)
        np.testing.assert_array_equal(result[y, x-1], MATTE)

    def test_rejects_unbounded_canvas_sizes(self):
        for text in ("0x0", "8000x8000", "-1x400", "420-by-264"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_box(text)
