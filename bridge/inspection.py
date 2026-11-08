"""Compose split views, RGB histograms and native-resolution regions for Lightroom."""

import json
from pathlib import Path

from bridge.preview_canvas import parse_box


def configure_parser(commands):
    crop = commands.add_parser("crop-input")
    crop.add_argument("--input", type=Path, required=True)
    crop.add_argument("--output", type=Path, required=True)
    crop.add_argument("--info", type=Path, required=True)
    crop.add_argument("--x", type=float, default=0.5)
    crop.add_argument("--y", type=float, default=0.5)
    crop.add_argument("--box", type=parse_box, default=(512, 320))
    view = commands.add_parser("inspect")
    for key in ("before", "after", "output", "histogram"):
        view.add_argument("--" + key, type=Path, required=True)
    view.add_argument("--position", type=int, default=50)
    view.add_argument("--mode", choices=("before", "after", "split"), default="split")
    view.add_argument("--info", type=Path)
    view.add_argument("--box", type=parse_box, default=(512, 320))


def crop_input(args):
    import numpy as np
    import tifffile

    if not all(0 <= v <= 1 for v in (args.x, args.y)):
        raise ValueError("Region center must be in the range 0–1.")
    with tifffile.TiffFile(args.input) as photo:
        page = photo.pages[0]
        if page.samplesperpixel != 3 or page.bitspersample != 16 or page.sampleformat != 1:
            raise ValueError("A native-resolution region requires an unsigned 16-bit RGB TIFF.")
        try:
            frame = tifffile.memmap(args.input, page=0, mode="r")
        except ValueError:
            frame = page.asarray()
        if page.planarconfig == 2:
            frame = np.moveaxis(frame, 0, -1)
        orientation = int(page.tags.valueof("Orientation", default=1))
        if orientation >= 5:
            frame = frame.swapaxes(0, 1)
        if orientation in (2, 3, 6, 7):
            frame = frame[:, ::-1]
        if orientation in (3, 4, 7, 8):
            frame = frame[::-1]
        h, w = frame.shape[:2]
        target_w, target_h = getattr(args, "box", (512, 320))
        width, height = min(target_w, w), min(target_h, h)
        left = min(w-width, max(0, round(args.x*w-width/2)))
        top = min(h-height, max(0, round(args.y*h-height/2)))
        # Render neighbouring pixels as well so blur kernels have context.
        x0, y0 = max(0,left-96), max(0,top-96)
        x1, y1 = min(w,left+width+96), min(h,top+height+96)
        icc = page.tags.valueof("InterColorProfile")
        tifffile.imwrite(args.output, frame[y0:y1,x0:x1], photometric="rgb", iccprofile=icc)
    args.info.write_text(json.dumps({
        "box": [left-x0, top-y0, left-x0+width, top-y0+height],
        "fraction": max(x1-x0,y1-y0) / max(w,h),
    }), encoding="utf8")


def inspection_view(args):
    import numpy as np
    from PIL import Image, ImageDraw, ImageOps

    if not 0 <= args.position <= 100:
        raise ValueError("Divider position must be between 0 and 100.")
    box = json.loads(args.info.read_text(encoding="utf8"))["box"] if args.info else None
    def display(path):
        with Image.open(path) as source:
            img = ImageOps.exif_transpose(source).convert("RGB")
        if box:
            return img.crop(tuple(box))
        img.thumbnail(getattr(args, "box", (512, 320)), Image.Resampling.LANCZOS)
        return img
    before, after = display(args.before), display(args.after)
    if before.size != after.size:
        raise ValueError("Before and after comparison requires matching image geometry.")
    composed = before if args.mode == "before" else after.copy()
    if args.mode == "split":
        split = round(before.width * args.position / 100)
        if split:
            composed.paste(before.crop((0,0,split,before.height)), (0,0))
        if 0 < split < before.width:
            ImageDraw.Draw(composed).line((split,0,split,before.height), fill="white")
    composed.save(args.output, quality=97, subsampling=0)
    # Split mode reports the processed photo's histogram, independent of divider position.
    counts = np.asarray((before if args.mode == "before" else after).histogram()).reshape(3,256)
    levels = np.log1p(counts)
    levels *= 58 / max(1, levels.max())
    histogram = Image.new("RGB",(512,64),"#202124")
    draw = ImageDraw.Draw(histogram)
    for bins, color in zip(levels, ("#fa6e6e","#64d88b","#6da4ff")):
        draw.line([(2*i,62-round(v)) for i,v in enumerate(bins)], fill=color, width=2)
    histogram.save(args.histogram)


def run(args):
    if args.command == "crop-input":
        crop_input(args)
    else:
        inspection_view(args)
