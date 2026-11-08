"""Compile frequently used renderer kernels during the project-local setup."""

from bridge.worker import configure_runtime


def prime():
    configure_runtime()
    import numpy as np
    from bridge import pixel_ops, worker

    pixel_ops.prime()
    # Exercise both the normal density axis and the ascending negative axis
    # used for positive film, using the real array layouts the sampler sees.
    density = np.full((12, 16, 3), .5)
    for film in ("kodak_portra_400", "fujifilm_provia_100f"):
        model = worker.simulator(film, "kodak_portra_endura", False)
        model.multilayer_grain(density, pitch=7.)
        model.process(density)
