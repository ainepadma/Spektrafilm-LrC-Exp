"""Full film pipeline with exact Poisson thinning for multilayer emulsion grain."""

from dataclasses import replace

import numpy as np
from numba import njit, prange
from spektrafilm.model.grain import add_micro_structure, apply_grain
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.utils.fast_gaussian_filter import fast_gaussian_filter


@njit(cache=True, parallel=True)
def particle_planes(density, exposure_axis, curves, minimum, maximum, particles,
                    uniformity, positive, channel):
    """Interpolate layer densities and sample developed particles in a single pass."""
    height, width = density.shape
    planes = np.empty((3, height, width), dtype=np.float64)
    for row in prange(height):
        # Independent reproducible rows keep the grain field independent of the
        # scheduler's choice of worker threads. No Python RNG state is modified.
        np.random.seed((row * 65537 + channel * 1009 + 13879) % 4294967296)
        for col in range(width):
            value = -density[row, col] if positive else density[row, col]
            if value <= exposure_axis[0]:
                lo = hi = 0
                fraction = 0.0
            elif value >= exposure_axis[-1]:
                lo = hi = len(exposure_axis) - 1
                fraction = 0.0
            else:
                hi = np.searchsorted(exposure_axis, value, side="right")
                lo = hi - 1
                fraction = (value - exposure_axis[lo]) / (exposure_axis[hi] - exposure_axis[lo])
            for layer in range(3):
                layer_density = curves[lo, layer] + fraction * (curves[hi, layer] - curves[lo, layer])
                probability = min(max((layer_density + minimum[layer]) / maximum[layer], 1e-6), 1 - 1e-6)
                saturation = 1 - probability * uniformity * (1 - 1e-6)
                # Seeds ~ Poisson(particles / saturation). Conditional on the
                # seeds, independent development with probability p gives a
                # Poisson(particles * p / saturation) count exactly.
                rate = particles[layer] * probability / saturation
                if rate > 1.e18:
                    # A nearly-zero particle area can exceed the integer
                    # generator's range. Relative noise is then below 1e-9.
                    sample = probability * maximum[layer] * (1 + np.random.normal() / np.sqrt(rate))
                else:
                    sample = np.random.poisson(rate) * (maximum[layer] / particles[layer]) * saturation
                planes[layer, row, col] = sample
    return planes


class PhysicalSimulator:
    def __init__(self, params, pipeline_factory=SimulationPipeline):
        self.params = params
        self.grain = params.film_render.grain
        # Run the engine's own couplers and develop curve, then insert sampled
        # silver density at its public CMY film tap before printing and scanning.
        film_render = replace(params.film_render, grain=replace(self.grain, active=False))
        self.pipeline = pipeline_factory(replace(params, film_render=film_render))
        film = params.film.data
        self.curves = film.density_curves - np.nanmin(film.density_curves, axis=0)
        self.layers = film.density_curves_layers

    def process(self, image):
        if not self.grain.active:
            return self.pipeline.process(image)
        density = self.pipeline.process(image, collect="cmy_film")
        pitch = self.params.camera.film_format_mm * 1000 / (max(image.shape[:2]) * self.params.io.upscale_factor)
        small_cold_frame = image.shape[0] * image.shape[1] < 240_000 and not particle_planes.signatures
        if small_cold_frame or not self.grain.sublayers_active:
            # Small thumbnails avoid compiling a new kernel before first view,
            # then benefit from it once this worker has rendered a larger frame.
            sampled = apply_grain(density, pitch, self.grain, self.curves, self.layers, self.params.film.info.type)
        else:
            sampled = self.multilayer_grain(density, pitch)
        del density
        return self.pipeline.process(sampled, inject="cmy_film")

    def multilayer_grain(self, density, pitch):
        grain = self.grain
        maximum = np.nanmax(self.layers, axis=0)
        fractions = maximum / maximum.sum(axis=0)
        minimum = fractions * np.asarray(grain.density_min)
        maximum = maximum + minimum
        area = (grain.particle_area_um2 * np.asarray(grain.particle_scale_layers)[:, None]
                * np.asarray(grain.particle_scale)[None, :])
        particles = pitch**2 * fractions / area
        positive = self.params.film.is_positive
        image = np.zeros_like(density)
        for channel in range(3):
            axis = self.curves[:, channel]
            planes = particle_planes(
                density[..., channel], -axis if positive else axis, self.layers[..., channel],
                minimum[:, channel], maximum[:, channel], particles[:, channel],
                grain.uniformity[channel], positive, channel,
            )
            for layer, plane in enumerate(planes):
                sigma = grain.blur_dye_clouds_um * np.sqrt(maximum[layer, channel] / particles[layer, channel])
                # Upstream's default truncate=3 kernel is the identity when
                # its rounded radius is zero.
                image[..., channel] += fast_gaussian_filter(plane, sigma) if 3 * sigma >= .5 else plane
            del plane, planes
        image = add_micro_structure(image, grain.micro_structure, pitch)
        image -= grain.density_min
        return fast_gaussian_filter(image, grain.blur) if grain.blur > 0 else image
