"""Fit a finished preview in the Lightroom preview area, preserving its aspect ratio."""

import re

MATTE = (38, 38, 38)
PADDING = 12


def parse_box(text):
    match = re.fullmatch(r"(\d{2,4})x(\d{2,4})", text)
    if not match:
        raise ValueError("Preview box must be WIDTHxHEIGHT.")
    size = tuple(map(int, match.groups()))
    if any(not 64 <= dimension <= 4096 for dimension in size):
        raise ValueError("Preview box dimensions must be 64–4096 pixels.")
    return size


def fit_preview(image, size):
    from PIL import Image

    width, height = size
    # A larger viewport centers small originals at their native pixel size.
    scale = min(1., (width - 2 * PADDING) / image.width, (height - 2 * PADDING) / image.height)
    fitted_size = max(1, round(image.width * scale)), max(1, round(image.height * scale))
    fitted = image if fitted_size == image.size else image.resize(fitted_size, Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", size, MATTE)
    canvas.paste(fitted, ((width - fitted.width) // 2, (height - fitted.height) // 2))
    return canvas
