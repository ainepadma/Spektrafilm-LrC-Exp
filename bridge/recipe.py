"""Validated, immutable settings for the physical film and print stages."""

from dataclasses import dataclass, fields
import math


@dataclass(frozen=True)
class Physical:
    scan: bool = False
    film_ev: float = 0
    print_ev: float = 0
    yellow: float = 0
    magenta: float = 0
    preflash: float = 0
    format_mm: float = 35
    grain_on: bool = True
    grain: float = 1
    halation_on: bool = True
    antihalation: bool = True
    halation: float = 1
    scatter: float = 1
    boost: float = 0
    couplers_on: bool = True
    couplers: float = 1
    glare_on: bool = True
    glare: float = 1


PHYSICAL_LIMITS = {
    "film_ev": (-4, 4), "print_ev": (-3, 3), "yellow": (-1, 1),
    "magenta": (-1, 1), "preflash": (0, .03), "format_mm": (4, 200),
    "grain": (0, 2), "halation": (0, 4), "scatter": (0, 4),
    "boost": (0, 8), "couplers": (0, 4), "glare": (0, 30),
}
POST_LIMITS = {
    "exposure": (-3, 3), "contrast": (-100, 100), "brightness": (-100, 100),
    "saturation": (-100, 100), "highlights": (-100, 100), "shadows": (-100, 100),
    "black": (0, 50), "white": (0, 50), "highlight_pull": (0, 8), "shadow_pull": (0, 8),
}
CHANNELS = ("rgb", "luma", "red", "green", "blue")
ZONES = ("master", "shadows", "midtones", "highlights")


def number(value, name, low, high):
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise ValueError(f"{name} must be a number from {low} to {high}.")
    return float(value)


def mapping(value, keys, name):
    if not isinstance(value, dict) or not set(value) <= set(keys):
        raise ValueError(f"Unknown or invalid {name} settings.")
    return value


def parse_recipe(raw):
    physical = {}
    post = {}
    field_names = {field.name for field in fields(Physical)}
    mapping(raw, field_names | POST_LIMITS.keys() | {"curves", "zones"}, "recipe")
    for key, value in raw.items():
        if key in field_names:
            if key in PHYSICAL_LIMITS:
                physical[key] = number(value, key, *PHYSICAL_LIMITS[key])
            elif type(value) is bool:
                physical[key] = value
            else:
                raise ValueError(f"{key} requires true or false.")
        elif key in POST_LIMITS:
            v = number(value, key, *POST_LIMITS[key])
            if v:
                post[key] = v
    for channel, points in mapping(raw.get("curves", {}), CHANNELS, "curve channel").items():
        if not isinstance(points, list) or not 2 <= len(points) <= 256:
            raise ValueError("A tone curve needs 2–256 points.")
        pairs = []
        for point in points:
            if not isinstance(point, list) or len(point) != 2:
                raise ValueError("Curve points must be [input, output] pairs.")
            x, y = (number(v, channel, 0, 1) for v in point)
            if pairs and pairs[-1][0] >= x:
                raise ValueError("Curve input values must strictly increase.")
            pairs.append((x, y))
        if pairs[0][0] != 0 or pairs[-1][0] != 1:
            raise ValueError("A curve must span inputs 0 to 1.")
        if any(x != y for x, y in pairs):
            post.setdefault("curves", {})[channel] = pairs
    limits = {"hue": (0, 360), "saturation": (0, 1), "luminance": (-1, 1)}
    for zone, settings in mapping(raw.get("zones", {}), ZONES, "color zone").items():
        settings = mapping(settings, limits, "color zone")
        params = {k: number(settings.get(k, 0), k, *bounds) for k, bounds in limits.items()}
        if params["luminance"] or params["saturation"]:
            post.setdefault("zones", {})[zone] = params
    return Physical(**physical), post


def make_params(film, paper, physical, preview=False, lut=False,
                input_space="sRGB", output_space="sRGB", frame_fraction=1):
    from spektrafilm import digest_params
    from bridge.stock_data import make_stock_params

    params = make_stock_params(film, paper)
    scan = physical.scan or params.film.is_positive
    if not scan and params.film.info.channel_model != params.print.info.channel_model:
        raise ValueError("The film and print stock use incompatible color channels.")
    params.io.scan_film = scan
    params.io.input_color_space = input_space
    params.io.output_color_space = output_space
    params.io.input_cctf_decoding = params.io.output_cctf_encoding = True
    params.camera.auto_exposure = False
    params.camera.film_format_mm = physical.format_mm * frame_fraction
    params.settings.use_enlarger_lut = params.settings.use_scanner_lut = True
    params.settings.lut_resolution = 17 if preview else 33
    # Product silver stocks supply measured sensitivity but no fitted Hanatos
    # adaptation window. The engine supports this through its unwindowed LUT.
    params.settings.apply_hanatos2025_adaptation_window = bool(
        params.film.data.hanatos2025_adaptation_window_params.size
    )
    params.settings.preview_mode = preview
    params.debug.lut_mode = lut
    if not physical.antihalation:
        params.film.info.antihalation = "no"  # Select the engine's no-layer stock preset.
    grain = params.film_render.grain
    grain.active = physical.grain_on and physical.grain > 0
    grain.particle_area_um2 *= physical.grain ** 2
    grain_area, grain_blur = grain.particle_area_um2, grain.blur
    halo = params.film_render.halation
    halo.active = physical.halation_on
    halo.halation_amount = physical.halation
    halo.scatter_amount = physical.scatter
    halo.boost_ev = physical.boost
    params.film_render.dir_couplers.active = physical.couplers_on
    params.film_render.dir_couplers.amount = physical.couplers
    params.print_render.glare.active = physical.glare_on
    params.print_render.glare.percent *= physical.glare
    # The Python engine takes absolute CC units, with stock-neutral offsets.
    params.enlarger.y_filter_shift = 30 * physical.yellow
    params.enlarger.m_filter_shift = 30 * physical.magenta
    params.enlarger.preflash_exposure = physical.preflash
    params = digest_params(params)
    if preview and not lut and physical.grain_on and physical.grain > 0:
        # Keep the faster preview tables and optics, but let the user actually
        # inspect the grain control, especially inside a native-pixel ROI.
        params.film_render.grain.active = True
        params.film_render.grain.particle_area_um2 = grain_area
        params.film_render.grain.blur = grain_blur
    # lut_mode normally resets exposures for LUT sampling. Here these controls
    # are fixed across every sample of a given film/print recipe.
    params.camera.exposure_compensation_ev = physical.film_ev
    params.enlarger.print_exposure = 2 ** -physical.print_ev
    if physical.film_ev:
        params.enlarger.print_exposure_compensation = False
    return params
