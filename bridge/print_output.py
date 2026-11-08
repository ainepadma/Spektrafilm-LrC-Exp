"""Output profiles and photographic finishing for plugin exports."""

from functools import lru_cache
from pathlib import Path
import os
import re
import struct
import tempfile


SPACES = {"srgb": "sRGB", "p3": "Display P3", "prophoto": "ProPhoto RGB"}
GATES = {"135": (36, 24), "half": (18, 24), "xpan": (65, 24),
         "645": (56, 41.5), "66": (56, 56), "67": (69, 56), "69": (84, 56),
         "612": (112, 56), "617": (168, 56)}
PAPER_COLORS = {"warm": "#F7F3E9", "white": "#FFFFFF", "black": "#141414"}


def colour_name(key):
    return SPACES[key]


def add_arguments(job):
    from bridge.preview_canvas import parse_box
    job.add_argument("--preview-box", type=parse_box, help="Fit a preview PNG/JPEG inside the display area.")
    job.add_argument("--display-proof", action="store_true", help="Use display-quality JPEG encoding.")
    job.add_argument("--paper-border", choices=("none", "auto", *PAPER_COLORS, "custom"), default="none")
    job.add_argument("--paper-layout", choices=("even", "instant"), default="even")
    job.add_argument("--paper-margin", type=float, default=.035,
                     help="Width on each side, as a fraction of the finished image's short edge.")
    job.add_argument("--paper-color", default=PAPER_COLORS["warm"], help="Custom paper color in sRGB #RRGGBB.")
    job.add_argument("--input-space", choices=SPACES, default="srgb")
    job.add_argument("--output-space", choices=SPACES, default="srgb")
    job.add_argument("--bit-depth", type=int, choices=(8, 16), default=16)
    job.add_argument("--long-edge", type=int, default=0)
    job.add_argument("--collision", choices=("unique", "skip", "overwrite"), default="unique")
    job.add_argument("--protected-source", type=Path, action="append", default=[])
    job.add_argument("--gate", choices=("none", *GATES), default="none")
    job.add_argument("--no-holes", action="store_true")
    job.add_argument("--markings", default="")
    job.add_argument("--frame-number", type=int, default=1)
    job.add_argument("--fog", type=float, default=0)
    job.add_argument("--leak", type=float, default=0)
    job.add_argument("--date", default="")
    job.add_argument("--date-position", choices=("br", "bl", "tr", "tl"), default="br")
    job.add_argument("--date-size", type=float, default=0.043)
    job.add_argument("--date-margin", type=float, default=0.04)
    job.add_argument("--date-brightness", type=float, default=0.85)
    job.add_argument("--pair-input", type=Path)
    job.add_argument("--pair-recipe")
    job.add_argument("--pair-film")
    job.add_argument("--pair-paper")
    job.add_argument("--pair-mode",choices=("full","preview","fast-color"))
    job.add_argument("--pair-direction", choices=("horizontal", "vertical"), default="horizontal")
    job.add_argument("--pair-gap", type=float, default=1)
    for side in ("first", "second"):
        job.add_argument(f"--{side}-ev", type=float, default=0)
        job.add_argument(f"--{side}-scale", type=float, default=1)
        job.add_argument(f"--{side}-x", type=float, default=0)
        job.add_argument(f"--{side}-y", type=float, default=0)
    job.add_argument("--cineon", action="store_true")


def bounded(value, lo, hi):
    if not lo <= value <= hi:
        raise ValueError(f"{value} outside allowed range [{lo}, {hi}]")
    return value


def expose(rgb, ev, space):
    if not ev:
        return rgb
    import colour
    import numpy as np
    curve = colour.RGB_COLOURSPACES[colour_name(space)]
    return np.asarray(curve.cctf_encoding(curve.cctf_decoding(rgb) * 2 ** bounded(ev, -3, 3)), dtype=np.float32)


def honor_input_profile(rgb, profile, expected_space):
    """Interpret the actual Adobe TIFF embedding if it differs from the requested space."""
    if not profile:
        return rgb
    import io
    import colour
    import numpy as np
    from PIL import ImageCms
    embedded=ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(io.BytesIO(profile))).lower()
    names = (("srgb","sRGB"),("prophoto","ProPhoto RGB"),("romm","ProPhoto RGB"),
             ("display p3","Display P3"),("display-p3","Display P3"),("adobe rgb","Adobe RGB (1998)"))
    actual=next((name for token,name in names if token in embedded),None)
    if not actual:
        raise ValueError(f"Unsupported embedded input ICC profile: {embedded.strip()}")
    expected=colour_name(expected_space)
    if actual==expected:
        return rgb
    result=np.empty_like(rgb)
    for start in range(0,rgb.shape[0],64):
        block=rgb[start:start+64]
        result[start:start+len(block)]=colour.RGB_to_RGB(block,actual,expected,
            chromatic_adaptation_transform="Bradford",apply_cctf_decoding=True,apply_cctf_encoding=True)
    return result


@lru_cache(maxsize=3)
def icc_profile(space):
    """ICC v2 matrix/shaper profile with D50 PCS and each space's native transfer curve."""
    import colour
    import numpy as np
    from PIL import ImageCms
    if space == "srgb":
        return ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    model = colour.RGB_COLOURSPACES[colour_name(space)]
    d50 = np.array([0.9642, 1.0, 0.8249])
    cat = colour.adaptation.matrix_chromatic_adaptation_VonKries(colour.xy_to_XYZ(model.whitepoint), d50, "Bradford")
    matrix = cat @ model.matrix_RGB_to_XYZ
    def xyz(values):
        return b"XYZ "+bytes(4)+struct.pack(">iii", *(round(float(v)*65536) for v in values))
    desc = (colour_name(space)+" (Spektrafilm)").encode("ascii")+bytes(1)
    trc = np.round(65535 * model.cctf_decoding(np.linspace(0, 1, 4096))).astype(">u2")
    curve = b"curv"+bytes(4)+struct.pack(">I",len(trc))+trc.tobytes()
    tags = {"desc": b"desc"+bytes(4)+struct.pack(">I",len(desc))+desc+bytes(78),
            "wtpt": xyz(d50), "cprt": b"text"+bytes(4)+b"Spektrafilm LrC-Exp\0"}
    for i,ch in enumerate("rgb"):
        tags[ch+"XYZ"] = xyz(matrix[:, i])
        tags[ch+"TRC"] = curve
    header = bytearray(128)
    header[8:24] = b"\x02\x10\0\0mntrRGB XYZ "
    header[24:36] = struct.pack(">6H", 2026, 1, 1, 0, 0, 0)
    header[36:40] = b"acsp"
    header[68:80] = xyz(d50)[8:]
    records, payload = bytearray(), bytearray()
    for key,data in tags.items():
        offset = 132 + 12*len(tags) + len(payload)
        records += key.encode("ascii")+struct.pack(">II",offset,len(data))
        payload += data+bytes(-len(data)%4)
    profile = header+struct.pack(">I",len(tags))+records+payload
    profile[:4] = struct.pack(">I", len(profile))
    return bytes(profile)


def resample(image, width, height):
    from PIL import Image
    import numpy as np
    if image.shape[:2] == (height, width):
        return image
    # Pillow's F mode preserves floating-point channels and uses antialiased Lanczos.
    return np.stack([np.asarray(Image.fromarray(image[:,:,c].astype(np.float32, copy=False)).resize(
        (width,height), Image.Resampling.LANCZOS)) for c in range(3)],axis=2)


def crop(image, ratio, scale=1, x=0, y=0):
    h,w = image.shape[:2]
    scale = bounded(scale,1,4)
    cw = max(1,round(min(w,h*ratio)/scale))
    ch = max(1,round(min(h,w/ratio)/scale))
    left = round((w-cw)*(bounded(x,-1,1)+1)/2)
    top = round((h-ch)*(bounded(y,-1,1)+1)/2)
    return image[top:top+ch,left:left+cw]


def paired(left, right, args):
    import numpy as np
    vertical = args.pair_direction=="vertical"
    ratio = 24/18 if vertical else 18/24
    left = crop(left,ratio,args.first_scale,args.first_x,args.first_y)
    right = crop(right,ratio,args.second_scale,args.second_x,args.second_y)
    h = max(1,min(left.shape[0],right.shape[0]))
    w = max(1,round(h*ratio))
    a, b = resample(left,w,h),resample(right,w,h)
    gap = max(1,round((h if vertical else w)*bounded(args.pair_gap,0.5,2)/18))
    shape = (gap,w,3) if vertical else (h,gap,3)
    return np.concatenate((a,np.full(shape,0.025,np.float32),b),axis=0 if vertical else 1)


def stamp(image, text, xy, size, colour, anchor, brightness=1):
    from PIL import Image, ImageDraw, ImageFont
    import numpy as np
    size = max(5,round(size))
    font = ImageFont.load_default(size=size)
    mask = Image.new("L",(image.shape[1],image.shape[0]))
    ImageDraw.Draw(mask).text(xy,text[:96],font=font,fill=255,anchor=anchor)
    # Restrict float allocations to the actual ink rectangle.
    bounds = mask.getbbox()
    if bounds:
        x,y,r,b = bounds
        alpha = np.asarray(mask.crop(bounds),dtype=np.float32)[:,:,None]*(brightness/255)
        region=image[y:b,x:r]
        region += (np.asarray(colour,dtype=np.float32)-region)*alpha


_SEGMENTS = {
    # Centre lines in units of digit height: top, upper-right, lower-right,
    # bottom, lower-left, upper-left, middle.
    "a": (.09,.065,.45,.065), "b": (.49,.11,.49,.44), "c": (.49,.56,.49,.89),
    "d": (.09,.935,.45,.935), "e": (.05,.56,.05,.89), "f": (.05,.11,.05,.44),
    "g": (.09,.50,.45,.50),
}
_DIGITS = {"0":"abcdef","1":"bc","2":"abdeg","3":"abcdg","4":"bcfg",
           "5":"acdfg","6":"acdefg","7":"abc","8":"abcdefg","9":"abcdfg","-":"g"}


def date_imprint(image, text, position, margin, requested_size, brightness):
    """Expose a local amber date-back display, including soft spill around each bar."""
    from PIL import Image, ImageDraw, ImageFilter
    import numpy as np
    if brightness == 0:
        return
    h,w=image.shape[:2]
    # Keep room for the entire date, even in a narrow half-frame preview.
    em = min(max(9,requested_size), (w-2*margin)/(len(text)*.72), h-2*margin)
    if em < 1:
        return
    oversample = 4 if em < 64 else 2 if em < 256 else 1
    pad = max(2,round(.14*em))
    width = int(np.ceil((.72*(len(text)-1)+.55)*em))
    height = int(np.ceil(em))
    tile = Image.new("L",((width+2*pad)*oversample,(height+2*pad)*oversample))
    draw = ImageDraw.Draw(tile)
    for i,char in enumerate(text):
        for segment in _DIGITS[char]:
            x1,y1,x2,y2=_SEGMENTS[segment]
            horizontal = y1==y2
            nx,ny = (0,.053) if horizontal else (.053,0)
            tx,ty = (.05,0) if horizontal else (0,.05)
            polygon = [(x1-tx,y1-ty),(x1+nx,y1+ny),(x2+nx,y2+ny),
                       (x2+tx,y2+ty),(x2-nx,y2-ny),(x1-nx,y1-ny)]
            points = [((pad+em*(.72*i+x))*oversample,(pad+em*y)*oversample) for x,y in polygon]
            draw.polygon(points,fill=255)
    mask=tile.resize((width+2*pad,height+2*pad), Image.Resampling.LANCZOS)
    x=round(w-margin-width if position[1]=="r" else margin)-pad
    y=round(h-margin-height if position[0]=="b" else margin)-pad
    left,top=max(0,x),max(0,y)
    right,bottom=min(w,x+mask.width),min(h,y+mask.height)
    if left>=right or top>=bottom:
        return
    bounds=(left-x,top-y,right-x,bottom-y)
    region=image[top:bottom,left:right]
    glow=mask.filter(ImageFilter.GaussianBlur(max(.6,.062*em)))
    for layer,tint,strength in ((glow,(1,.26,.025),.29),(mask,(1,.57,.10),1)):
        alpha=np.asarray(layer.crop(bounds),dtype=np.float32)[:,:,None]*(strength*brightness/255)
        region += (np.asarray(tint,dtype=np.float32)-region)*alpha


@lru_cache(maxsize=32)
def encoded_paper_color(hex_color, space):
    import numpy as np

    if not re.fullmatch(r"#[0-9A-Fa-f]{6}", hex_color):
        raise ValueError("Paper color must be an sRGB hex value, e.g. #F7F3E9.")
    color = np.array([int(hex_color[i:i+2], 16) for i in (1, 3, 5)], dtype=np.float64) / 255.
    if space != "srgb":
        import colour
        color = colour.RGB_to_RGB(color, "sRGB", colour_name(space),
                                  chromatic_adaptation_transform="Bradford",
                                  apply_cctf_decoding=True, apply_cctf_encoding=True)
    return np.clip(color, 0., 1.)


def paper_border(image, args, printed):
    import numpy as np

    style = args.paper_border
    width = bounded(args.paper_margin, 0, .30)
    if style == "none" or width == 0 or (style == "auto" and not printed):
        return image
    color = args.paper_color if style == "custom" else PAPER_COLORS["warm" if style == "auto" else style]
    h, w = image.shape[:2]
    margin = round(min(h, w) * width)
    if not margin:
        return image
    bottom = margin * 3 if args.paper_layout == "instant" else margin
    canvas = np.empty((h + margin + bottom, w + margin*2, 3), dtype=image.dtype)
    edges = encoded_paper_color(color, args.output_space)
    canvas[:margin] = edges
    canvas[-bottom:] = edges
    canvas[margin:-bottom, :margin] = edges
    canvas[margin:-bottom, -margin:] = edges
    canvas[margin:margin+h, margin:margin+w] = image
    return canvas


def finish(image, args, second=None, *, printed=True):
    import numpy as np
    if second is not None:
        image = paired(image,second,args)
    elif args.gate != "none":
        a,b = GATES[args.gate]
        long_short=max(a,b)/min(a,b)
        ratio = long_short if image.shape[1]>=image.shape[0] else 1/long_short
        image = crop(image,ratio)
    if args.date or args.leak:
        image = image.copy()
    h,w=image.shape[:2]
    if args.leak:
        # Dye the image from the film edge; intensity falls off toward its centre.
        x = np.linspace(0,1,w,dtype=np.float32)[None,:]
        for y in range(0,h,128):
            yy = np.arange(y,min(y+128,h),dtype=np.float32)[:,None]/max(1,h-1)
            alpha = bounded(args.leak,0,1)*np.exp(-12*x)*(0.55+0.45*np.cos(3*yy)**2)
            region=image[y:y+len(yy)]
            region += (np.array([1,.37,.07],np.float32)-region)*alpha[:,:,None]
    if args.date:
        pos=args.date_position
        margin=bounded(args.date_margin,0,0.4)*min(h,w)
        size=min(h,w)*bounded(args.date_size,0.01,0.25)
        brightness=bounded(args.date_brightness,0,1)
        if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}",args.date):
            date_imprint(image,args.date,pos,margin,size,brightness)
        else:
            stamp(image,args.date,(w-margin if pos[1]=="r" else margin,h-margin if pos[0]=="b" else margin),
                  size,(1,.46,.11),pos[1]+("b" if pos[0]=="b" else "t"),brightness)
    if args.gate != "none":
        # Rotate the geometry to landscape for rail placement, then restore orientation.
        along, across = GATES[args.gate]
        rotated = (w >= h) != (along >= across)
        strip=np.rot90(image) if rotated else image
        sh,sw=strip.shape[:2]
        gauge135 = args.gate in ("135","half","xpan")
        pxmm = sh/across
        rail=max(2,round(pxmm*(5.5 if gauge135 else 2.5)))
        side=max(1,round(pxmm))
        canvas=np.empty((sh+rail*2,sw+side*2,3),dtype=np.float32)
        canvas[:]=[.07,.045,.025]
        if args.fog:
            alpha=bounded(args.fog,0,1)*np.exp(-np.linspace(0,3,canvas.shape[1],dtype=np.float32))
            canvas += (np.array([.75,.30,.12],np.float32)-canvas)*alpha[None,:,None]
        canvas[rail:rail+sh,side:side+sw]=strip
        if gauge135 and not args.no_holes:
            pitch=max(3,round(4.75*pxmm)); ww=max(1,round(2.79*pxmm)); hh=max(1,round(1.98*pxmm))
            cy=round(rail*.45)
            yy,xx=np.ogrid[:hh,:ww]
            radius=max(.5,min(hh,ww)*.23)
            dx=np.maximum(abs(xx-(ww-1)/2)-(ww/2-radius),0)
            dy=np.maximum(abs(yy-(hh-1)/2)-(hh/2-radius),0)
            mask=np.clip(radius+.5-np.sqrt(dx**2+dy**2),0,1).astype(np.float32)
            for x in range(pitch//2,canvas.shape[1],pitch):
                for y in (cy,canvas.shape[0]-cy):
                    left,top=x-ww//2,y-hh//2
                    region=canvas[top:top+hh,left:left+ww]
                    region += (.83-region)*mask[:region.shape[0],:region.shape[1],None]
        if args.markings:
            stamp(canvas,f"{args.markings}    {args.frame_number:02d}",(side+1,rail+sh),max(5,rail*.40),
                  (.88,.62,.22),"lt")
        image=np.rot90(canvas,-1) if rotated else canvas
    image = paper_border(image, args, printed)
    limit=int(bounded(args.long_edge,0,65535))
    if limit and max(image.shape[:2])>limit:
        h,w=image.shape[:2]; k=limit/max(h,w)
        image=resample(image,max(1,round(w*k)),max(1,round(h*k)))
    return image


def publish(destination, image, args, second=None, *, printed=True):
    import numpy as np
    import tifffile
    from PIL import Image
    destination=Path(destination)
    if any(source.resolve()==destination.resolve() or (destination.exists() and source.exists() and
            source.samefile(destination)) for source in args.protected_source):
        raise ValueError("Choose a different name or folder: the target is an original photo.")
    if destination.exists() and args.collision!="overwrite":
        raise FileExistsError(f"Output exists: {destination}")
    ext = destination.suffix.lower()
    preview_box = getattr(args, "preview_box", None)
    is_proof = args.preview or getattr(args, "display_proof", False) or bool(preview_box)
    if preview_box and (ext not in (".jpg", ".jpeg", ".png") or
                        not (args.preview or getattr(args, "display_proof", False) or getattr(args, "fast_color", False))):
        raise ValueError("A preview box requires a preview JPEG or PNG.")
    if ext not in (".jpg",".jpeg",".png",".tif",".tiff"):
        raise ValueError("Output must be TIFF, JPEG or PNG.")
    if args.cineon and ext not in (".tif",".tiff") and not (is_proof and ext in (".jpg", ".jpeg", ".png")):
        raise ValueError("A Cineon intermediate must be saved as a 16-bit TIFF.")
    if args.cineon:
        # DI carries film density alone. Apply sizing only, never a print overlay or display profile.
        if second is not None: raise ValueError("Export Cineon negatives individually.")
        cap=bounded(args.long_edge,0,65535)
        h,w=image.shape[:2]
        if cap and max(h,w)>cap:
            k=cap/max(h,w); image=resample(image,max(1,round(w*k)),max(1,round(h*k)))
    else:
        image = finish(image,args,second,printed=printed)
    is_tiff=ext in (".tif",".tiff")
    bits = 16 if args.cineon and is_tiff else args.bit_depth if is_tiff else 8
    dtype=np.uint16 if bits==16 else np.uint8
    from bridge import pixel_ops
    if image.shape[0]*image.shape[1]>=pixel_ops.LARGE_IMAGE:
        data=np.empty(image.shape,dtype=dtype)
        if not pixel_ops.quantize(image,data,2**bits-1):
            raise ValueError("Non-finite image samples.")
    else:
        if not np.isfinite(image).all(): raise ValueError("Non-finite image samples.")
        data=np.rint(np.clip(image,0.,1.)*(2**bits-1)).astype(dtype)
    profile=None if args.cineon else icc_profile(args.output_space)
    fd,partial=tempfile.mkstemp(dir=destination.parent,prefix=".spektrafilm-",suffix=ext)
    os.close(fd)
    try:
        if is_tiff:
            tifffile.imwrite(partial,data,photometric="rgb",iccprofile=profile,metadata=None,
                             description=f"Cineon log RGB; {colour_name(args.output_space)} primaries; black 95, reference white 685, 10-bit code scaled to 16-bit" if args.cineon else None)
        else:
            options={"icc_profile":profile} if profile else {}
            if ext != ".png":
                options["quality"] = max(args.quality, 96) if is_proof else args.quality
                if is_proof:
                    options["subsampling"] = 0
            display = Image.fromarray(data)
            if preview_box:
                from bridge.preview_canvas import fit_preview
                display = fit_preview(display, preview_box)
            display.save(partial,**options)
        if args.collision=="overwrite":
            os.replace(partial,destination)
        elif os.name=="nt":
            os.rename(partial,destination)
        else:
            os.link(partial,destination)
    finally:
        Path(partial).unlink(missing_ok=True)
