"""Scene placement on linear light and grading on the simulated encoded RGB."""

from colorsys import hsv_to_rgb
from dataclasses import replace
from functools import lru_cache

import numpy as np
from colour.models import RGB_COLOURSPACES


def native_ops(image, space):
    if space not in ("sRGB","Display P3","ProPhoto RGB"):
        return None
    from bridge import pixel_ops
    return pixel_ops if image.shape[0]*image.shape[1]>=pixel_ops.LARGE_IMAGE else None


def linear_luminance(rgb, space):
    profile = RGB_COLOURSPACES[space]
    linear = profile.cctf_decoding(np.maximum(rgb, 0))
    return linear, linear @ profile.matrix_RGB_to_XYZ[1]


def silver_output(rgb, space):
    # Silver density contains no dye hue. Preserve the native luminance before
    # the user's optional split toning and channel curves.
    profile = RGB_COLOURSPACES[space]
    ops=native_ops(rgb,space)
    if ops:
        return ops.silver_pixels(rgb,profile.matrix_RGB_to_XYZ[1],space=="ProPhoto RGB")
    result = np.empty_like(rgb)
    for start in range(0, len(rgb), 128):
        rows = slice(start, start + 128)
        _, y = linear_luminance(rgb[rows], space)
        result[rows] = profile.cctf_encoding(y)[..., None]
    return result


def knee(distance, strength):
    # Smooth, monotonic compression that approaches `strength` stops.
    if strength == 0:
        return 0
    return -strength * np.expm1(-np.maximum(distance, 0) / strength)


def suggested_pull(distance, needed):
    if needed <= 0:
        return 0
    lo, hi = 0.0, 8.0
    for _ in range(16):
        strength = (lo + hi) / 2
        if knee(distance, strength) >= needed:
            hi = strength
        else:
            lo = strength
    return hi


def placement(rgb, opts, space):
    """Move shadow and highlight exposures towards middle grey, with a smooth knee."""
    shadows = opts.get("shadow_pull", 0)
    highs = opts.get("highlight_pull", 0)
    if not (highs or shadows):
        return rgb
    ops=native_ops(rgb,space)
    if ops:
        return ops.place_pixels(rgb,RGB_COLOURSPACES[space].matrix_RGB_to_XYZ[1],
                                space=="ProPhoto RGB",float(shadows),float(highs))
    placed = np.empty_like(rgb)
    for start in range(0, len(rgb), 128):
        rows = slice(start, start + 128)
        linear, y = linear_luminance(rgb[rows], space)
        ev = np.log2(np.maximum(y, 1.e-9) / .18)
        # 1-EV knee on each side of middle grey. The exponential shoulder
        # moves extremes by at most the requested stops and stays monotonic.
        delta = knee(-ev - 1, shadows) - knee(ev - 1, highs)
        placed[rows] = RGB_COLOURSPACES[space].cctf_encoding(linear * np.exp2(delta)[..., None])
    return np.clip(placed, 0, 1)


def grade(rgb, opts, space):
    if not (opts.keys() - {"shadow_pull", "highlight_pull"}):
        return rgb
    weights = RGB_COLOURSPACES[space].matrix_RGB_to_XYZ[1]
    profile = RGB_COLOURSPACES[space]
    ops=native_ops(rgb,space)
    if ops:
        exposure=2.**opts.get("exposure",0)
        contrast=2.**(opts.get("contrast",0)/100)
        black,white=opts.get("black",0)/200,1-opts.get("white",0)/200
        settings=(exposure,contrast,.0025*opts.get("brightness",0),.0025*opts.get("shadows",0),
                  .0025*opts.get("highlights",0),black,white-black,1+opts.get("saturation",0)/100)
        # Curves retain their exact piecewise-linear nodes. The compiled loop
        # skips absent stages and calculates only the luminance values in use.
        curves=np.zeros((5,256,2),np.float64)
        counts=np.zeros(5,np.int32)
        for i,key in enumerate(("rgb","red","green","blue","luma")):
            points=opts.get("curves",{}).get(key,[])
            if points:
                counts[i]=len(points)
                curves[i,:len(points)]=points
        shifts=np.zeros((4,3),np.float64)
        zones=opts.get("zones",{})
        for i,key in enumerate(("master","shadows","midtones","highlights")):
            if key in zones:
                zone=zones[key]
                hue=np.array(hsv_to_rgb(zone["hue"]/360,1.,1.))
                shifts[i]=.25*(zone["saturation"]*(hue-hue@weights)+zone["luminance"])
        return ops.grade_pixels(rgb,weights,space=="ProPhoto RGB",settings,curves,counts,shifts,bool(zones))
    output = np.empty_like(rgb)
    for start in range(0, len(rgb), 128):
        rows = slice(start, start + 128)
        block = np.clip(rgb[rows], 0, 1)
        if opts.get("exposure"):
            block = profile.cctf_encoding(profile.cctf_decoding(block) * 2 ** opts["exposure"])
        y = np.clip(block @ weights, 0, 1)[..., None]
        tone = opts.get("brightness", 0) * .0025
        tone += opts.get("shadows", 0) * .0025 * (1-y)**2
        tone += opts.get("highlights", 0) * .0025 * y**2
        block = (block - .5) * (2 ** (opts.get("contrast", 0) / 100)) + .5 + tone
        black, white = opts.get("black", 0) / 200, 1 - opts.get("white", 0) / 200
        block = (block - black) / (white - black)
        y = block @ weights
        block = y[..., None] + (block - y[..., None]) * (1 + opts.get("saturation", 0)/100)
        curves = opts.get("curves", {})
        if "rgb" in curves:
            block = np.interp(block, *zip(*curves["rgb"]))
        for channel, plane in enumerate(("red", "green", "blue")):
            if plane in curves:
                block[...,channel] = np.interp(block[...,channel], *zip(*curves[plane]))
        y = np.clip(block @ weights, 0, 1)
        if "luma" in curves:
            block += (np.interp(y, *zip(*curves["luma"])) - y)[..., None]
        zones = opts.get("zones", {})
        if zones:
            y = np.clip(block @ weights, 0, 1)
            shadow = np.clip(1 - y * 2, 0, 1)
            high = np.clip(y * 2 - 1, 0, 1)
            blend = {"master": np.ones_like(y), "shadows": shadow, "highlights": high,
                     "midtones": 1 - shadow - high}
            for name, zone in zones.items():
                tint = np.array(hsv_to_rgb(zone["hue"] / 360, 1.0, 1.0))
                shift = .25 * zone["saturation"] * (tint - tint @ weights)
                block += blend[name][..., None] * (shift + .25 * zone["luminance"])
        output[rows] = np.clip(block, 0, 1)
    return output


@lru_cache(maxsize=16)
def usable_range(film, paper, physical, space):
    """Neutral exposure range between 5% and 95% of the stock pair's output response."""
    from spektrafilm import Simulator
    from bridge.recipe import make_params

    ev = np.linspace(-14, 12, 209)
    # No spatial effects or stochastic grain during the characteristic-curve probe.
    ramp = .18 * np.exp2(ev)
    grey = RGB_COLOURSPACES[space].cctf_encoding(np.tile(ramp[None, :, None], (1, 1, 3)))
    params = make_params(film, paper, physical, lut=True, input_space=space)
    response = Simulator(params).process(grey)[0] @ RGB_COLOURSPACES["sRGB"].matrix_RGB_to_XYZ[1]
    if not np.isfinite(response).all():
        raise ValueError("Nonfinite stock latitude response.")
    if response[-1] < response[0]:
        response = -response
    response = np.maximum.accumulate(response)
    span = response[-1] - response[0]
    if span < 1e-5:
        raise ValueError("No usable contrast for this film/print combination.")
    return tuple(np.interp(response[0] + span * np.array([.05, .95]), response, ev))


def diagnostics(rgb, film, paper, physical, space, post):
    low, high = usable_range(film, paper, physical, space)
    film_low, film_high = usable_range(film, paper, replace(physical, scan=True), space)
    # An evenly spaced sample bounds the cost for full-resolution inputs.
    step = max(1, int(np.ceil(np.sqrt(rgb.shape[0] * rgb.shape[1] / 250_000))))
    _, y = linear_luminance(rgb[::step, ::step], space)
    ev = np.log2(np.maximum(y, .18 * 2**-14) / .18)
    dark, bright = np.percentile(ev, [1, 99])
    placed = ev + knee(-ev - 1, post.get("shadow_pull", 0)) - knee(ev - 1, post.get("highlight_pull", 0))
    # A code-zero pixel has no recoverable luminance when scaled. Keep it at
    # the plotting floor instead of reporting brightness that was never rendered.
    placed = np.where(y == 0, -14, placed)
    placed_low, placed_high = np.percentile(placed, [1, 99])
    return dict(medium_low=low, medium_high=high, film_low=film_low, film_high=film_high,
                scene_low=dark, scene_high=bright,
                placed_low=placed_low, placed_high=placed_high,
                shadow_pct=100*np.mean(placed < low), highlight_pct=100*np.mean(placed > high),
                suggest_shadow=suggested_pull(-dark - 1, low - dark) if np.percentile(y, 1) > 0 else 0,
                suggest_highlight=suggested_pull(bright - 1, bright - high))
