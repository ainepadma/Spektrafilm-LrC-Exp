"""Fused CAM16-UCS output compression for the pinned spektrafilm pipeline.

The upstream scanner still computes densities, stochastic glare, lens blur,
sharpening and output encoding. Only the pointwise CAM16 round trip is fused.
"""
from dataclasses import replace
from functools import lru_cache
import math
from time import perf_counter

import colour
import numpy as np
from colour.appearance import VIEWING_CONDITIONS_CAM16
from colour.appearance.cam16 import MATRIX_16, MATRIX_INVERSE_16
from colour.appearance.ciecam02 import (
    achromatic_response_forward, degree_of_adaptation,
    post_adaptation_non_linear_response_compression_forward,
    viewing_conditions_dependent_parameters,
)
from numba import njit, prange
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.utils import gamut_compression as gamut
from bridge.film_input import install_projection
from bridge.pixel_ops import encode


@lru_cache(maxsize=3)
def _viewing_transform(space):
    cs = colour.RGB_COLOURSPACES[space]
    white = 100 * colour.xy_to_XYZ(cs.whitepoint)
    surround = VIEWING_CONDITIONS_CAM16["Average"]
    adapting = gamut._CAM16UCS_L_A
    background = gamut._CAM16UCS_Y_B
    n, fl, nbb, ncb, z = viewing_conditions_dependent_parameters(background, white[1], adapting)
    d = np.clip(degree_of_adaptation(surround.F, adapting), 0, 1)
    cones = MATRIX_16 @ white
    gain = d * white[1] / cones + 1 - d
    white_response = post_adaptation_non_linear_response_compression_forward(gain * cones, fl)
    aw = achromatic_response_forward(white_response, nbb)
    # Derive both directions independently: not all RGB colour spaces store
    # their forward and inverse matrices at the same precision.
    rgb_xyz = colour.RGB_to_XYZ(np.eye(3), colourspace=cs, illuminant=cs.whitepoint).T
    xyz_rgb = colour.XYZ_to_RGB(np.eye(3), colourspace=cs, illuminant=cs.whitepoint).T
    forward = np.diag(gain) @ MATRIX_16 @ rgb_xyz * 100
    inverse = xyz_rgb @ MATRIX_INVERSE_16 @ np.diag(1/gain) / 100
    light, hue, maximum = gamut._get_output_c_max_table("cam16ucs", space)
    constants = (float(fl), float(nbb), float(aw), float(surround.c*z),
                 float((1.64 - 0.29**n)**0.73 * fl**0.25),
                 float(50000/13 * surround.N_c * ncb), float(gamut._cam16ucs_white_Jp(space)))
    return forward, inverse, constants, light, hue, maximum


@njit(inline="always")
def _knee(x, threshold, limit, power):
    if x <= threshold:
        return x
    scale = limit - threshold
    offset = (x-threshold)/scale
    return threshold + scale*offset/(1+offset**power)**(1/power)


@njit(inline="always")
def _adapt(cone, fl):
    v = (fl*abs(cone)/100)**0.42
    return math.copysign(400*v/(27.13+v), cone)+0.1


@njit(inline="always")
def _unadapt(response, fl):
    v = response-0.1
    return math.copysign(100/fl * (27.13*abs(v)/(400-abs(v)))**(1/0.42), v)


@njit(inline="always")
def _dot(matrix, row, x, y, z):
    return matrix[row,0]*x + matrix[row,1]*y + matrix[row,2]*z


@njit(inline="always")
def _limit(lightness, angle, lights, hues, table):
    u = (min(lights[-1],max(lights[0],lightness))-lights[0])/(lights[-1]-lights[0])*(len(lights)-1)
    v = (angle-hues[0])/(hues[1]-hues[0])
    i = min(int(u),len(lights)-2)
    j = math.floor(v)
    fu, fv = u-i, v-j
    j %= len(hues)
    k = (j+1)%len(hues)
    return max(1e-9,(1-fu)*((1-fv)*table[i,j]+fv*table[i,k]) +
               fu*((1-fv)*table[i+1,j]+fv*table[i+1,k]))


@njit(parallel=True, cache=True)
def _compress(pixels, forward, inverse, constants, lights, hues, maximum, chroma_knee, light_knee):
    fl, nbb, aw, cz, m_scale, t_scale, white_jp = constants
    result = np.empty((len(pixels),3), dtype=np.float64)
    for i in prange(len(pixels)):
        r,g,b = pixels[i]
        ra = _adapt(_dot(forward,0,r,g,b),fl)
        ga = _adapt(_dot(forward,1,r,g,b),fl)
        ba = _adapt(_dot(forward,2,r,g,b),fl)
        # Standard CAM16 opponent coordinates and achromatic response.
        a = ra-12*ga/11+ba/11
        op_b = (ra+ga-2*ba)/9
        achromatic = (2*ra+ga+ba/20-0.305)*nbb
        denominator = ra+ga+1.05*ba
        if achromatic <= 0 or denominator <= 0:
            # The reference implements signed powers in the extended domain.
            result[i,:] = np.nan
            continue
        h = math.atan2(op_b,a)
        cos_h, sin_h = math.cos(h), math.sin(h)
        eccentricity = (math.cos(h+2)+3.8)/4
        t = t_scale*eccentricity*math.hypot(a,op_b)/denominator
        j = 100*(achromatic/aw)**cz
        m = m_scale * math.sqrt(j/100)*t**0.9
        jp = 1.7*j/(1+0.007*j)
        cp = math.log1p(0.0228*m)/0.0228
        if light_knee[1] > 0:
            jp = _knee(jp/white_jp, light_knee[0],light_knee[1],light_knee[2])*white_jp
        cmax = _limit(jp,h,lights,hues,maximum)
        cp = _knee(cp/cmax,chroma_knee[0],chroma_knee[1],chroma_knee[2])*cmax
        # Invert CAM16-UCS with the compressed lightness and chroma, keeping hue.
        j = jp/(1.7-0.007*jp)
        m = math.expm1(0.0228*cp)/0.0228
        t = (m/(m_scale*math.sqrt(max(j,1e-15)/100)))**(1/0.9)
        p2 = aw*(j/100)**(1/cz)/nbb+0.305
        radius = 0.0
        if t > 0:
            radius = p2*3.05*460/(1403*t_scale*eccentricity/t +
                                   3.05*220*cos_h + (1.05*6300-27)*sin_h)
        a, op_b = radius*cos_h, radius*sin_h
        ra = _unadapt((460*p2 + 451*a + 288*op_b)/1403,fl)
        ga = _unadapt((460*p2 - 891*a - 261*op_b)/1403,fl)
        ba = _unadapt((460*p2 - 220*a - 6300*op_b)/1403,fl)
        for c in range(3):
            result[i,c] = _dot(inverse,c,ra,ga,ba)
    return result


def compress_scan(rgb, spec, space):
    if spec.algorithm != "cam16ucs":
        return gamut.compress_rgb(rgb,spec,output_color_space=space)
    flat = np.ascontiguousarray(rgb).reshape(-1,3)
    light_knee = spec.lightness_compression or (0.,0.,1.)
    out = _compress(flat,*_viewing_transform(space),tuple(map(float,spec.knee)),light_knee)
    unusual = ~np.isfinite(out).all(axis=1)
    if unusual.any():
        out[unusual] = gamut.compress_rgb(flat[unusual],spec,output_color_space=space)
    return out.reshape(rgb.shape)


@njit(parallel=True, cache=True)
def _transfer(pixels, matrix, prophoto):
    result = np.empty_like(pixels)
    for i in prange(len(pixels)):
        r,g,b = pixels[i]
        for c in range(3):
            result[i,c] = encode(_dot(matrix,c,r,g,b),prophoto)
    return result


class ExportPipeline(SimulationPipeline):
    """Release each full-resolution intermediate as soon as its consumer finishes."""

    def process(self, image, *, inject=None, collect=None):
        # In the pinned engine, both scan and print topologies are linear.
        # Keep the upstream dispatcher available for branched / new topologies.
        nodes = self._topology
        if (any(len(n.reads) != 1 or len(n.writes) != 1 for n in nodes) or
                any(a.writes != b.reads for a,b in zip(nodes,nodes[1:]))):
            return super().process(image, inject=inject, collect=collect)
        current = inject or self.taps.inject or "rgb_in"
        target = collect or self.taps.collect or "rgb_out"
        self.timings.clear()
        start = perf_counter()
        try:
            for node in nodes:
                if current == node.reads[0]:
                    stage_start = perf_counter()
                    image = node.run(image)
                    self._record_node_timing(node, perf_counter()-stage_start)
                    current = node.writes[0]
                    if current == target:
                        return image
            raise RuntimeError(f"Cannot reach pipeline output {target!r} from {inject!r}.")
        finally:
            self._last_elapsed_time = perf_counter()-start


def make_pipeline(params):
    pipeline = ExportPipeline(params)
    install_projection(pipeline)
    if params.io.output_gamut_compress.algorithm != "cam16ucs":
        return pipeline
    stage = pipeline._scanning_stage
    # Let this scanner's reference density conversion include its own glare and
    # XYZ adaptation. Move only its final pointwise compression into our kernel,
    # ahead of the native spatial blur / sharpening and transfer encoding.
    spec = stage._io.output_gamut_compress
    space = stage._io.output_color_space
    stage._io = replace(stage._io, output_gamut_compress=replace(spec, algorithm="off"))
    read_density = stage._density_to_rgb

    def read_and_compress(density, *, use_lut):
        linear = read_density(density, use_lut=use_lut)
        return compress_scan(linear, spec, space)

    stage._density_to_rgb = read_and_compress
    if stage._io.output_cctf_encoding and space in ("sRGB","Display P3","ProPhoto RGB"):
        # Match the native RGB_to_RGB conversion, including any residual from
        # the published, rounded RGB↔XYZ matrices, before the transfer curve.
        matrix = colour.matrix_RGB_to_RGB(space, space)
        def encode_scan(rgb):
            return _transfer(rgb.reshape(-1,3),matrix,space=="ProPhoto RGB").reshape(rgb.shape)
        stage._apply_cctf_encoding = encode_scan
    return pipeline
