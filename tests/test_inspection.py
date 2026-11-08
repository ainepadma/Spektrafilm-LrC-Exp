"""Check native pixels, orientation, the wipe and profile memory on synthetic images."""

import base64
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest

import numpy as np
from PIL import Image, JpegImagePlugin
import tifffile

from bridge.inspection import crop_input, inspection_view
from bridge.project_data import publish

ROOT = Path(__file__).resolve().parents[1]


class InspectionTest(unittest.TestCase):
    def test_large_viewport_uses_native_roi_and_a_lossless_unboxed_image(self):
        with TemporaryDirectory(dir=ROOT / ".runtime") as tmp:
            folder = Path(tmp)
            yy, xx = np.indices((900,1300))
            original = np.stack((xx * 31, yy * 51, (xx ^ yy) * 27), axis=-1).astype(np.uint16)
            source, roi, info = (folder / name for name in ("source.tif","roi.tif","region.json"))
            tifffile.imwrite(source, original, photometric="rgb")
            worker = [sys.executable, str(ROOT/"bridge"/"worker.py")]
            subprocess.run([*worker,"crop-input","--input",source,"--output",roi,"--info",info,
                            "--box","960x640","--x","0","--y","1"],check=True)
            x, y, r, b = json.loads(info.read_text())["box"]
            cropped = tifffile.imread(roi)
            np.testing.assert_array_equal(cropped[y:b,x:r],original[-640:,:960])
            original_png, edited_png, out = [folder/n for n in ("in.png","edited.png","out.png")]
            high_frequency = ((cropped >> 8).astype(np.uint8)) ^ np.uint8(93)
            Image.fromarray(high_frequency).save(edited_png)
            Image.fromarray((original>>8).astype(np.uint8)).save(original_png)
            subprocess.run([*worker,"inspect","--before",roi,"--after",edited_png,"--info",info,
                            "--mode","after","--box","960x640","--output",out,
                            "--histogram",folder/"hist.png"], check=True)
            with Image.open(out) as proof:
                self.assertEqual(proof.size,(960,640))
                np.testing.assert_array_equal(proof,high_frequency[y:b,x:r])
            # Fit the whole picture at the requested viewport resolution.
            target = folder/"overview.jpg"
            subprocess.run([*worker,"inspect","--before",original_png,"--after",original_png,
                            "--mode","after","--box","1040x720","--output",target,
                            "--histogram",folder/"hist.png"], check=True)
            with Image.open(target) as proof:
                self.assertEqual(proof.size,(1040,720))
                self.assertEqual(JpegImagePlugin.get_sampling(proof),0)

    def test_oriented_roi_and_split_view(self):
        with TemporaryDirectory(dir=ROOT / ".runtime") as tmp:
            folder = Path(tmp)
            yy,xx = np.indices((940,720))
            original = np.stack([xx*68,yy*52,(xx+yy)*28],axis=2).astype(np.uint16)
            source, roi, info = (folder / name for name in ("source.tif","roi.tif","region.json"))
            tifffile.imwrite(source,original,photometric="rgb",extratags=[(274,"H",1,6,False)])
            crop_input(SimpleNamespace(input=source,output=roi,info=info,x=.5,y=.5))
            oriented = np.rot90(original,3)
            box = json.loads(info.read_text())["box"]
            x,y,right,bottom = box
            cropped = tifffile.imread(roi)
            np.testing.assert_array_equal(cropped[y:bottom,x:right],oriented[200:520,214:726])
            after = folder/"after.jpg"
            Image.new("RGB",(cropped.shape[1],cropped.shape[0]),(4,16,222)).save(after)
            args = SimpleNamespace(before=roi,after=after,info=info,position=50,mode="split",
                                   output=folder/"split.jpg",histogram=folder/"rgb.png")
            inspection_view(args)
            with Image.open(args.output) as out:
                self.assertEqual(out.size,(512,320))
                self.assertLess(np.abs(np.asarray(out)[80,60].astype(float) -
                                       cropped[y+80,x+60] / 257).max(),4)
                self.assertGreater(np.asarray(out)[80,380,2],215)
            with Image.open(args.histogram) as hist:
                self.assertEqual(hist.size,(512,64))

    def test_record_publish_on_unicode_path_with_curves(self):
        with TemporaryDirectory(dir=ROOT / ".runtime",prefix="目录 & ") as name:
            folder=Path(name)
            staging=folder / "write"
            staging.mkdir()
            (folder/"1.json").write_text('{"film":"original"}')
            records={"1":{"film":"黑白","options":{"curves":{"blue":[[0,0],[1,.8]]}}},
                     "2":{"film":"other"}}
            encoded=base64.urlsafe_b64encode(json.dumps(records,ensure_ascii=False).encode()).decode()
            for pos in range(0,len(encoded),80):
                (staging / f"{pos+1:08d}_{encoded[pos:pos+80]}").mkdir()
            publish(folder,staging)
            self.assertEqual(json.loads((folder/"1.json").read_text("utf8")),records["1"])
            self.assertEqual(json.loads((folder/"2.json").read_text("utf8")),records["2"])


if __name__ == "__main__":
    unittest.main()
