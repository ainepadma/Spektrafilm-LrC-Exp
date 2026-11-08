"""Color-only export using a sampled spektrafilm film/paper response in sRGB."""

from functools import lru_cache
from dataclasses import replace

import numpy as np
from scipy.ndimage import map_coordinates
from spektrafilm import Simulator

from bridge.pixel_ops import LARGE_IMAGE, trilinear
from bridge.recipe import Physical, make_params


@lru_cache(maxsize=4)
def _color_table(film, paper, physical, input_space, output_space):
    params = make_params(film, paper, physical, lut=True,
                         input_space=input_space, output_space=output_space)
    side = 33
    axis = np.linspace(0, 1, side)
    grid = np.stack(np.meshgrid(axis, axis, axis, indexing="ij"), axis=-1)
    samples = Simulator(params).process(grid.reshape(side, side * side, 3))
    if not np.isfinite(samples).all():
        raise ValueError("The engine produced an invalid film/paper color table.")
    return np.ascontiguousarray(samples.reshape(grid.shape), dtype=np.float32)


def apply(rgb, film, paper, physical=Physical(), input_space="sRGB", output_space="sRGB"):
    """Interpolate each pixel in encoded RGB. Bound scratch space on large exports."""
    color_only = replace(physical, grain_on=False, grain=0, halation_on=False, halation=0,
                         scatter=0, boost=0, glare_on=False, glare=0, format_mm=35, antihalation=True)
    table = _color_table(film, paper, color_only, input_space, output_space)
    if rgb.shape[0]*rgb.shape[1] >= LARGE_IMAGE:
        return trilinear(rgb, table)
    output = np.empty(rgb.shape, dtype=np.float32)
    for y in range(0, len(rgb), 128):
        rows = slice(y, y + 128)
        coords = np.moveaxis(rgb[rows], -1, 0) * (table.shape[0] - 1)
        for channel in range(3):
            output[rows, :, channel] = map_coordinates(
                table[..., channel], coords, order=1, mode="nearest", prefilter=False,
            )
    return output
