"""Project RGB into the pinned engine's Hanatos spectral LUT in one pass."""

from functools import lru_cache
import math

import colour
import numpy as np
from numba import njit, prange
from spektrafilm.utils.fast_interp_lut import _cubic_interp_lut_at_2d
from spektrafilm.utils.spectral_upsampling import _illuminant_to_xy

from bridge.pixel_ops import decode


@lru_cache(maxsize=32)
def input_matrix(space, illuminant):
    # Derive the exact transform from the colour library used by the engine.
    # It includes the input primaries, white point and CAT16 adaptation to the
    # film's measured reference illuminant.
    basis = colour.RGB_to_XYZ(np.eye(3), colourspace=space,
                              illuminant=_illuminant_to_xy(illuminant),
                              apply_cctf_decoding=False, chromatic_adaptation_transform="CAT16")
    return np.ascontiguousarray(basis.T)


@njit(cache=True, parallel=True)
def project(pixels, matrix, decode_input, prophoto, table):
    result = np.empty_like(pixels)
    scale = table.shape[0] - 1
    for i in prange(len(pixels)):
        red, green, blue = pixels[i]
        if decode_input:
            red = decode(red, prophoto)
            green = decode(green, prophoto)
            blue = decode(blue, prophoto)
        x = matrix[0, 0]*red + matrix[0, 1]*green + matrix[0, 2]*blue
        y = matrix[1, 0]*red + matrix[1, 1]*green + matrix[1, 2]*blue
        z = matrix[2, 0]*red + matrix[2, 1]*green + matrix[2, 2]*blue
        brightness = x + y + z
        if not math.isfinite(brightness):
            result[i, :] = np.nan
            continue
        denominator = max(brightness, 1e-10)
        complement = 1 - x / denominator
        u = min(1., max(0., complement * complement))
        v = min(1., max(0., (y / denominator) / max(complement, 1e-10)))
        # Use the engine's existing reflected-edge Mitchell filter, including
        # its coordinate convention and weight normalization.
        sampled = _cubic_interp_lut_at_2d(table, u * scale, v * scale)
        for channel in range(3):
            result[i, channel] = sampled[channel] * brightness
    return result


def install_projection(pipeline):
    stage = pipeline._filming_stage
    if stage._settings.rgb_to_raw_method != "hanatos2025":
        return
    original = stage._rgb_to_film_raw

    def rgb_to_raw(rgb, *, color_space="sRGB", apply_cctf_decoding=False):
        # The stage's own mid-grey calibration already built this transform
        # from the film sensitivity, camera filters and gamut configuration.
        # Keep the upstream path for other transfer curves and unbuilt tables.
        table = stage._lut_service.filming_tc_lut_memory
        if table is None or table.shape[0] < 2 or color_space not in ("sRGB", "Display P3", "ProPhoto RGB"):
            return original(rgb, color_space=color_space, apply_cctf_decoding=apply_cctf_decoding)
        matrix = input_matrix(color_space, stage._film.info.reference_illuminant)
        flat = np.ascontiguousarray(rgb, dtype=np.float64).reshape(-1, 3)
        samples = project(flat, matrix, apply_cctf_decoding, color_space == "ProPhoto RGB", table)
        return samples.reshape(rgb.shape)

    stage._rgb_to_film_raw = rgb_to_raw
