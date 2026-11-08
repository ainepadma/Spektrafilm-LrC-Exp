"""Compare full-size CPU kernels against the same vectorized preview operations."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import numpy as np
from scipy.ndimage import map_coordinates

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from bridge import worker
worker.configure_runtime()
from bridge import grade
from bridge import pixel_ops


class PixelKernelTest(unittest.TestCase):
    def test_trilinear_uses_same_coordinates_and_clamps_as_scipy(self):
        rng=np.random.default_rng(24)
        rgb=rng.uniform(-.2,1.2,(52,65,3)).astype(np.float32)
        rgb[0,:5]=[(0,0,0),(1,1,1),(1,0,0),(0,1,0),(0,0,1)]
        table=rng.random((33,33,33,3),dtype=np.float32)
        coords=np.moveaxis(rgb,-1,0)*32
        reference=np.stack([map_coordinates(table[...,c],coords,order=1,mode="nearest",
                                            prefilter=False) for c in range(3)],axis=2)
        np.testing.assert_allclose(pixel_ops.trilinear(rgb,table),reference,atol=6e-8,rtol=0)
        rgb[6,4,0]=np.inf
        self.assertTrue(np.isnan(pixel_ops.trilinear(rgb,table)[6,4]).all())

    def test_colour_curves_zones_scene_placement_and_silver(self):
        rng=np.random.default_rng(54)
        rgb=rng.uniform(-.25,1.25,(53,63,3)).astype(np.float32)
        post={"exposure":.25,"saturation":23,"highlights":8,"shadows":-4,"contrast":-13,
              "black":5,"white":6,"brightness":4,"shadow_pull":2,"highlight_pull":.75,
              "curves":{"rgb":[[0,0],[.35,.44],[1,1]],"red":[[0,0],[.3,.4],[1,1]],
                        "green":[[0,0],[.7,.8],[1,1]],"blue":[[0,0],[.1,.05],[1,1]],
                        "luma":[[0,0],[.3,.33],[1,1]]},
              "zones":{"master":{"hue":330,"saturation":.2,"luminance":-.1},
                       "midtones":{"hue":38,"saturation":.5,"luminance":.06}}}
        for space in ("sRGB","Display P3","ProPhoto RGB"):
            for function,args in ((grade.grade,(rgb,post,space)),(grade.placement,(rgb,post,space)),
                                  (grade.silver_output,(rgb,space))):
                with self.subTest(space=space, stage=function.__name__):
                    reference=function(*args)
                    with patch.object(pixel_ops,"LARGE_IMAGE",0):
                        optimized=function(*args)
                    np.testing.assert_allclose(optimized,reference,atol=2e-7,rtol=0)

    def test_quantization_preserves_round_to_even_and_rejects_nonfinite(self):
        rng=np.random.default_rng(41)
        for dt in (np.float32,np.float64):
            image=rng.uniform(-.2,1.2,(26,39,3)).astype(dt)
            for bits, target in ((8,np.uint8),(16,np.uint16)):
                max_code=2**bits-1
                image[0,:4,0]=np.array([0.5,1.5,31.5,91.5])/max_code
                result=np.empty(image.shape,dtype=target)
                self.assertTrue(pixel_ops.quantize(image,result,max_code))
                np.testing.assert_array_equal(result,np.rint(np.clip(image,0,1)*max_code).astype(target))
            image[4,5,2]=np.nan
            self.assertFalse(pixel_ops.quantize(image,result,65535))


if __name__=="__main__":
    unittest.main()
