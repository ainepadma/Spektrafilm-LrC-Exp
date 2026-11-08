import argparse
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
import tifffile
from PIL import Image, ImageCms, JpegImagePlugin

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from bridge import worker
worker.configure_runtime()
from bridge import print_output as printing


def options(*fields):
    parser=argparse.ArgumentParser()
    printing.add_arguments(parser)
    result=parser.parse_args(fields)
    result.quality=90
    result.preview=False
    return result


class PrintOutputTest(unittest.TestCase):
    def test_png_watermark_position_opacity_and_transparency(self):
        photo = np.zeros((100, 200, 3), dtype=np.float32)
        with tempfile.TemporaryDirectory(dir=ROOT/".runtime") as folder:
            path = Path(folder)/"标识.png"
            logo = np.zeros((20, 20, 4), dtype=np.uint8)
            logo[:, 10:] = (255, 0, 0, 128)
            Image.fromarray(logo).save(path)
            args = options("--watermark","png","--watermark-png",str(path),"--watermark-size",".2",
                           "--watermark-position","center","--watermark-opacity",".5")
            out = printing.finish(photo,args)
            np.testing.assert_array_equal(out[:40], 0)
            np.testing.assert_array_equal(out[:, :100], 0)
            self.assertAlmostEqual(float(out[50,105,0]), 64/255, places=5)
            np.testing.assert_array_equal(photo, 0)

    def test_selected_caption_font_and_text_watermark(self):
        from PIL import ImageFont
        photo = np.zeros((200, 320, 3), dtype=np.float32)
        args = options("--watermark","text","--watermark-text","Signature","--watermark-font","example.ttf",
                       "--paper-layout","instant","--paper-border","white","--paper-caption","Title",
                       "--caption-font","second.ttf")
        with patch.object(printing,"caption_font",side_effect=lambda size,face: ImageFont.load_default(size=size)) as fonts:
            output = printing.finish(photo,args)
            self.assertEqual({call.args[1] for call in fonts.call_args_list},{"example.ttf","second.ttf"})
            self.assertGreater(output[7:207,7:327].max(),0)
    def test_instant_square_position_and_caption_are_confined_to_the_paper(self):
        for height, width in ((80, 120), (120, 80)):
            y, x = np.indices((height, width))
            photo = np.stack((x/width, y/height, x*0), axis=-1).astype(np.float32)
            args = options("--paper-layout","instant","--paper-border","white","--paper-margin",".10",
                           "--instant-frame","square","--instant-position","1","--paper-caption","旅行 2026")
            print_with_text = printing.paper_border(photo, args, True)
            self.assertEqual(print_with_text.shape, (112, 96, 3))
            np.testing.assert_array_equal(print_with_text[8:88,8:-8], photo[-80:,-80:])
            args.paper_caption = ""
            blank = printing.paper_border(photo, args, True)
            np.testing.assert_array_equal(print_with_text[:-24], blank[:-24])
            self.assertTrue(np.any(print_with_text[-24:] != blank[-24:]))

    def test_draft_and_final_render_at_distinct_resolutions(self):
        with tempfile.TemporaryDirectory(dir=ROOT/".runtime") as folder:
            path = Path(folder)
            args = options("--display-proof", "--draft")
            args.input = path/"input.tif"
            tifffile.imwrite(args.input, np.full((400, 1000, 3), 30000, np.uint16), photometric="rgb")
            args.film, args.paper, args.fast_color = "kodak_portra_400", "auto", True
            args.recipe, args.frame_fraction, args.diagnostics = "{}", 1, None
            for draft, size in ((True, (800, 320)), (False, (1000, 400))):
                args.draft, args.output = draft, path/f"{draft}.png"
                worker.render(args, worker.profiles())
                with Image.open(args.output) as proof:
                    self.assertEqual(proof.size, size)

    def test_instant_paper_preserves_image_with_triple_bottom_margin(self):
        for height, width in ((100, 150), (150, 100)):
            photo = np.zeros((height, width, 3), dtype=np.float32)
            args = options("--paper-border", "white", "--paper-layout", "instant", "--paper-margin", ".06")
            result = printing.paper_border(photo, args, printed=True)
            self.assertEqual(result.shape, (height + 24, width + 12, 3))
            np.testing.assert_array_equal(result[6:-18, 6:-6], photo)
            self.assertTrue(np.all(result[:6] == 1) and np.all(result[-18:] == 1))

    def test_paper_edits_reuse_only_the_matching_developed_preview(self):
        with tempfile.TemporaryDirectory(dir=ROOT/".runtime") as folder:
            path = Path(folder)
            args = options("--display-proof", "--paper-border", "warm", "--paper-margin", ".125")
            args.input = path/"input.tif"
            pixels = np.full((64, 96, 3), 37000, dtype=np.uint16)
            tifffile.imwrite(args.input, pixels, photometric="rgb")
            args.film, args.paper, args.fast_color = "kodak_portra_400", "auto", True
            args.recipe, args.frame_fraction = "{}", 1
            with patch.object(worker, "read_input", wraps=worker.read_input) as read:
                for i, style in enumerate(("warm", "black", "warm")):
                    args.paper_border = style
                    args.output, args.diagnostics = path/f"{i}.png", path/f"{i}.tsv"
                    if i == 2:
                        args.recipe = '{"film_ev": 1}'
                    worker.render(args, worker.profiles())
                self.assertEqual(read.call_count, 2)
            self.assertEqual((path/"0.tsv").read_bytes(), (path/"1.tsv").read_bytes())
            with Image.open(path/"0.png") as first, Image.open(path/"1.png") as second:
                np.testing.assert_array_equal(np.asarray(first)[8:-8,8:-8], np.asarray(second)[8:-8,8:-8])
                self.assertNotEqual(first.getpixel((0, 0)), second.getpixel((0, 0)))

    def test_paper_is_part_of_framed_image_across_preview_and_export(self):
        x, y = np.meshgrid(np.linspace(0, 1, 120), np.linspace(0, 1, 80))
        source = np.stack([x, y, (x+y)/2], axis=-1).astype(np.float32)
        common = ("--paper-border","custom","--paper-color","#B47848","--paper-margin",".10")
        with tempfile.TemporaryDirectory(dir=ROOT/".runtime") as folder:
            path = Path(folder)
            proof_args = options(*common, "--display-proof")
            printing.publish(path/"proof.png", source, proof_args)
            printing.publish(path/"export.tif", source, options(*common))
            with Image.open(path/"proof.png") as image:
                self.assertEqual(image.size, (136, 96))
                proof = np.asarray(image)
            export = tifffile.imread(path/"export.tif")
            np.testing.assert_allclose(proof, export / 257, atol=.51)
            np.testing.assert_array_equal(proof[0,0], (180,120,72))
            np.testing.assert_array_equal(proof[8:-8,8:-8], np.rint(source*255).astype("uint8"))
            boxed_args = options(*common, "--display-proof", "--preview-box", "220x160")
            printing.publish(path/"display.png", source, boxed_args)
            with Image.open(path/"display.png") as image:
                display = np.asarray(image)
            self.assertEqual(display.shape[:2], (160,220))
            np.testing.assert_array_equal(display[32:128,42:178], proof)
            np.testing.assert_array_equal(display[0,0], (38,38,38))
            for space in ("p3", "prophoto"):
                wide = path/f"{space}.png"
                printing.publish(wide, source, options(*common, "--output-space",space))
                with Image.open(wide) as image:
                    profile = ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"]))
                    standard = ImageCms.profileToProfile(image, profile, ImageCms.createProfile("sRGB"))
                np.testing.assert_allclose(standard.getpixel((0,0)), (180,120,72), atol=2)

        # The substrate surrounds the film strip, including its rebate and holes.
        strip_args = ("--gate","135","--markings","TEST")
        strip = printing.finish(source, options(*strip_args))
        bordered = printing.finish(source, options(*strip_args,*common))
        margin = round(min(strip.shape[:2]) * .1)
        np.testing.assert_array_equal(bordered[margin:-margin,margin:-margin], strip)
        limited = printing.finish(source, options(*strip_args,*common,"--long-edge","90"))
        self.assertEqual(max(limited.shape[:2]),90)

    def test_auto_paper_follows_the_actual_scan_path(self):
        h, w = 64, 96
        source = np.broadcast_to(np.linspace(512, 62000, w, dtype=np.uint16)[None,:,None], (h,w,3))
        with tempfile.TemporaryDirectory(dir=ROOT/".runtime") as folder:
            path = Path(folder)
            input_file = path/"input.tif"
            tifffile.imwrite(input_file, source, photometric="rgb")
            for i, (film, scan, border, expected) in enumerate((
                ("kodak_portra_400",False,"auto",True),
                ("kodak_portra_400",True,"auto",False),
                ("fujifilm_provia_100f",False,"auto",False),
                ("fujifilm_provia_100f",False,"white",True),
            )):
                args = options("--paper-border",border,"--paper-margin",".125")
                args.input, args.output = input_file, path/f"{i}.png"
                args.film, args.paper, args.fast_color = film, "auto", True
                args.recipe = '{"scan": true}' if scan else '{}'
                args.diagnostics, args.frame_fraction = None, 1
                worker.render(args, worker.profiles())
                with Image.open(args.output) as img:
                    self.assertEqual(img.size, (w+16, h+16) if expected else (w,h))
                    if expected:
                        self.assertEqual(img.getpixel((0,0)), (247,243,233) if border=="auto" else (255,255,255))

    def test_high_quality_jpeg_proof_preserves_chroma_sampling(self):
        lines = np.zeros((32, 80, 3), dtype=np.float32)
        lines[:, ::2, 0] = 1
        lines[:, 1::2, 2] = 1
        with tempfile.TemporaryDirectory(dir=ROOT/".runtime") as folder:
            path = Path(folder)
            args = options("--display-proof")
            args.quality = 35
            printing.publish(path/"proof.jpg",lines,args)
            with Image.open(path/"proof.jpg") as image:
                self.assertEqual(JpegImagePlugin.get_sampling(image), 0)
                self.assertLess(np.abs(np.asarray(image) / 255. - lines).mean(), .02)
    def test_date_back_segments_and_small_preview(self):
        canvas=np.zeros((64,200,3),np.float32)
        printing.date_imprint(canvas,"2026-11-08","tl",5,20,1)
        # A seven-segment 2 has an upper-right bar and an unlit upper-left bar.
        self.assertGreater(canvas[10,15,0], .6)
        self.assertLess(canvas[10,6,0], .05)
        self.assertGreater(canvas[10,15,1], canvas[10,15,2])
        # The halo fades outside a bar and remains localized.
        self.assertGreater(canvas[10,17,0],0)
        self.assertLess(canvas[10,17,0],.25)
        self.assertFalse(canvas[32:].any())
        preview=np.zeros((40,72,3),np.float32)
        printing.date_imprint(preview,"2026-11-08","br",2,2,.85)
        occupied=np.where(preview[:,:,0]>.20)[1]
        self.assertGreater(occupied.max()-occupied.min(),40)
        self.assertLess(occupied.max(),71)
        self.assertFalse(preview[:24].any())
        off=np.zeros_like(preview)
        printing.date_imprint(off,"2026-11-08","br",2,2,0)
        self.assertFalse(off.any())

    def test_icc_matrix_and_curve_match_encoded_pixels(self):
        import colour
        samples=np.array([[[254,16,0],[128,64,160],[0,15,253],[255,255,255]]],dtype=np.uint8)
        for space in ("p3","prophoto"):
            dest=ImageCms.ImageCmsProfile(io.BytesIO(printing.icc_profile(space)))
            converted=ImageCms.profileToProfile(Image.fromarray(samples),ImageCms.createProfile("sRGB"),dest)
            ref=colour.RGB_to_RGB(samples/255,"sRGB",printing.colour_name(space),
                chromatic_adaptation_transform="Bradford",apply_cctf_decoding=True,apply_cctf_encoding=True)
            np.testing.assert_allclose(np.asarray(converted),np.rint(np.clip(ref,0,1)*255),atol=1)
            recovered=printing.honor_input_profile(samples/255,printing.icc_profile("srgb"),space)
            np.testing.assert_allclose(recovered,ref,atol=1e-6)

    def test_pair_placement_gates_and_independent_date(self):
        red=np.zeros((130,160,3),np.float32)
        red[:,:,0]=.9
        green=red[:,:,::-1].copy()
        for direction in ("horizontal","vertical"):
            args=options("--pair-direction",direction, "--pair-gap","1.5")
            image=printing.finish(red,args,green)
            h,w=image.shape[:2]
            y,x=(h//2,w//4) if direction=="horizontal" else (h//4,w//2)
            self.assertGreater(image[y,x,0],.8)
            self.assertGreater(image[-y,-x,2],.8)
            self.assertLess(image[h//2,w//2].max(),.1)
        stamped=printing.finish(red,options("--date","2026-11-08","--date-size",".1"))
        self.assertEqual(stamped.shape,red.shape)
        self.assertGreater(np.max(np.abs(stamped-red)),.1)
        for gate in printing.GATES:
            strip=printing.finish(red,options("--gate",gate,"--markings","STOCK","--leak",".5","--fog",".5","--long-edge","95"))
            self.assertEqual(max(strip.shape[:2]),95)
            self.assertTrue(np.isfinite(strip).all())

    def test_cineon_and_protection(self):
        from bridge.cineon import encode_linear
        np.testing.assert_allclose(encode_linear(np.array([0,1]))*1023,[95,685],atol=1e-5)
        with tempfile.TemporaryDirectory(dir=ROOT/".runtime") as folder:
            base=Path(folder)
            ramp=np.linspace(1000,64000,80,dtype=np.uint16)
            source=base/"负片.tif"
            tifffile.imwrite(source,np.broadcast_to(ramp[None,:,None],(36,80,3)),photometric="rgb")
            command=[sys.executable,str(ROOT/"bridge"/"worker.py"),"render","--cineon","--input",str(source),
                 "--film","kodak_portra_400","--paper","kodak_portra_endura","--output",str(base/"DI.tif")]
            subprocess.run(command,check=True)
            with tifffile.TiffFile(base/"DI.tif") as result:
                page=result.pages[0]
                self.assertEqual(page.bitspersample,16)
                self.assertNotIn(34675,page.tags)
                self.assertIn("Cineon log RGB",page.description)
                codes=page.asarray()
                self.assertGreater(codes[:,-5:].mean()-codes[:,:5].mean(),2000)
            # A display-only PNG can carry unboxed log codes at source resolution;
            # the photographic print substrate must never affect a density proof.
            proof = base/"DI-proof.png"
            proof_cmd = [*command[:-1], str(proof), "--display-proof", "--paper-border","white",
                         "--paper-margin",".20","--recipe",'{"grain_on":false}']
            subprocess.run(proof_cmd,check=True)
            with Image.open(proof) as image:
                self.assertEqual(image.size,(80,36))
                self.assertIsNone(image.info.get("icc_profile"))
                self.assertLess(np.asarray(image)[0,0].max(),200)
            args=options("--collision","overwrite","--protected-source",str(source))
            with self.assertRaisesRegex(ValueError,"original photo"):
                printing.publish(source,np.ones((4,4,3)),args)


if __name__=="__main__":
    unittest.main()
