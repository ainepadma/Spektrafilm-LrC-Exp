"""Calibrate a negative-density scan and write its positive in Cineon code values.

The spectral printing-density read and neutral wedge follow SpektraLab's RFC-028.
Input is the film development tap, before the print or display rendering stages.
"""
from copy import deepcopy

import colour
import numpy as np
from colour.models.datasets import CCS_POINTER_GAMUT_BOUNDARY
from matplotlib.path import Path as GamutBoundary
from spektrafilm import load_profile
from spektrafilm.config import STANDARD_OBSERVER_CMFS
from spektrafilm.model.color_filters import compute_band_pass_filter
from spektrafilm.model.illuminants import standard_illuminant
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.utils.spectral_upsampling import HANATOS2025_SPECTRA_LUT


def encode_linear(linear):
    black = 10 ** ((95 - 685) / 300)
    return np.clip((685 + 300 * np.log10(np.maximum(linear, 0)*(1-black) + black)) / 1023, 0, 1)


def density_reader(film):
    paper = load_profile("kodak_portra_endura")
    dye = np.asarray(film.data.channel_density)
    valid = np.isfinite(dye).all(axis=1) & np.isfinite(film.data.base_density)
    dye = dye[valid]
    weights = np.nan_to_num(10**paper.data.log_sensitivity[valid]) * standard_illuminant(
        paper.info.reference_illuminant)[valid,None]
    sums = weights.sum(axis=0)
    if np.any(sums<=0):
        raise ValueError("Film has no usable spectral printing density.")
    weights /= sums

    def read(cmy):
        flat = cmy.reshape(-1,3)
        out = np.empty_like(flat,dtype=np.float32)
        for start in range(0,len(flat),4096):
            block=flat[start:start+4096]
            transmission=10.**(-(block @ dye.T))
            out[start:start+len(block)] = -np.log10(np.maximum(transmission @ weights,1e-10))
        return out.reshape(cmy.shape)
    return read


def fit_matrix(params):
    spectrum=np.asarray(HANATOS2025_SPECTRA_LUT).reshape(-1,len(STANDARD_OBSERVER_CMFS))
    cmfs=STANDARD_OBSERVER_CMFS.values
    white=standard_illuminant(params.film.info.reference_illuminant)
    sensitivity=np.nan_to_num(10.**params.film.data.log_sensitivity)
    band=compute_band_pass_filter(params.camera.filter_uv,params.camera.filter_ir)
    sensitivity *= band[:,None]
    xyz=spectrum @ cmfs
    eye=spectrum @ sensitivity
    white_xyz=white @ cmfs
    white_eye=white @ sensitivity
    xy=colour.XYZ_to_xy(xyz)
    selected=(xyz[:,1]>1e-8) & (eye>0).all(axis=1) & GamutBoundary(CCS_POINTER_GAMUT_BOUNDARY).contains_points(xy)
    xyz=xyz[selected]; eye=eye[selected]
    if len(xyz)<100 or (white_eye<=0).any():
        raise ValueError("Insufficient spectral samples for a Cineon colour matrix.")
    eye=eye/white_eye*white_xyz[1]/xyz[:,1,None]
    targets=colour.XYZ_to_RGB(xyz/xyz[:,1,None],params.io.output_color_space,
                              illuminant=colour.XYZ_to_xy(white_xyz),chromatic_adaptation_transform="CAT02")
    gram=eye.T @ eye
    # Enforce unit column sums so the neutral wedge stays neutral.
    system=np.block([[gram,np.ones((3,1))],[np.ones((1,3)),np.zeros((1,1))]])
    return np.linalg.solve(system,np.vstack([eye.T @ targets,np.ones(3)]))[:3]


def build_renderer(params):
    """Calibrate the stock once for repeated photographs using the same settings."""
    if params.film.info.type != "negative":
        raise ValueError("Cineon DI requires a negative film.")
    read=density_reader(params.film)
    calibrate=deepcopy(params)
    calibrate.io.input_cctf_decoding=False
    calibrate.camera.exposure_compensation_ev=0
    calibrate.camera.auto_exposure=False
    calibrate.camera.lens_blur_um=0
    calibrate.camera.diffusion_filter.active=False
    calibrate.film_render.grain.active=False
    calibrate.film_render.halation.active=False
    calibrate.film_render.dir_couplers.diffusion_size_um=0
    stops=np.linspace(-14,14,561)
    wedge=np.broadcast_to((.18 * 2**stops)[None,:,None],(1,len(stops),3))
    wedge_density=read(SimulationPipeline(calibrate).process(wedge,collect="cmy_film"))[0]
    mid=wedge_density[280,1]
    if wedge_density[320,1] - wedge_density[240,1] <= 0.05*(4*np.log10(2)):
        raise ValueError("Film has insufficient negative contrast for Cineon DI.")
    positive_log=np.log10(.18)+(wedge_density[:,1]-mid)/.6
    matrix=fit_matrix(params) if params.film.info.channel_model != "bw" else np.eye(3)
    abscissas=np.maximum.accumulate(wedge_density.astype(np.float64),axis=0)+np.arange(len(stops))[:,None]*1e-10
    floor=10**positive_log[0]
    pipeline=SimulationPipeline(params)

    def render_frame(rgb):
        cmy=pipeline.process(rgb,collect="cmy_film")
        result=np.empty(cmy.shape,dtype=np.float32)
        # Spectral transmission and matrix conversion use double precision but
        # need only a small row band at a time after collecting the film tap.
        band=max(1,65536//cmy.shape[1])
        for start in range(0,len(cmy),band):
            density=read(cmy[start:start+band])
            positive=np.empty_like(density)
            for channel in range(3):
                positive[:,:,channel]=10**np.interp(density[:,:,channel],abscissas[:,channel],positive_log)-floor
            result[start:start+len(density)]=encode_linear(positive @ matrix)
        return result
    return render_frame


def render(params, rgb):
    return build_renderer(params)(rgb)
