"""File-based interface between the Lightroom plugin and the spektrafilm runtime."""

import argparse
from contextlib import contextmanager
from functools import lru_cache
from importlib.metadata import distribution
import json
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if not __package__:
    # Lightroom launches the script by path; load sibling modules by their
    # canonical package names so Numba can share compiled kernels with setup.
    sys.path.insert(0, str(ROOT))

from bridge.session import serve
from bridge.recipe import Physical, parse_recipe, make_params

# The Lightroom TIFF is immutable within a preview job. Reuse the developed
# single frame when only paper margins, dates or film gates change.
_last_proof = None


def configure_runtime():
    cache = ROOT / ".cache"
    for key, folder in {
        "MPLCONFIGDIR": "matplotlib",
        "NUMBA_CACHE_DIR": "numba-canonical",
        "XDG_CACHE_HOME": "user-cache",
        "TEMP": "tmp",
        "TMP": "tmp",
        "TMPDIR": "tmp",
    }.items():
        path = cache / folder
        path.mkdir(exist_ok=True, parents=True)
        os.environ[key] = str(path)


@lru_cache(maxsize=1)
def profiles():
    # Reading the bundled metadata also works before starting the numerical runtime.
    folder = distribution("spektrafilm").locate_file("spektrafilm/data/profiles")
    from bridge.stock_data import merged_profiles
    entries = {}
    for path in sorted(folder.glob("*.json")):
        entries[path.stem] = json.loads(path.read_text(encoding="utf-8"))["info"]
    entries.update(merged_profiles())
    catalog = {"film": {}, "paper": {}}
    for stock, info in sorted(entries.items()):
        if info["support"] == "film" and info["stage"] == "filming":
            catalog["film"][stock] = info
        elif info["stage"] == "printing":
            # Cine negatives name positive print film rather than photographic paper.
            catalog["paper"][stock] = info
    if not all(catalog.values()):
        raise ValueError("The installed engine has no usable film or paper profiles.")
    return catalog


@contextmanager
def new_output(destination):
    """Publish a complete file without replacing an existing result, even on a race."""
    if destination.exists():
        raise FileExistsError(f"The output already exists: {destination}")
    fd, tmp = tempfile.mkstemp(dir=destination.parent, suffix=destination.suffix)
    os.close(fd)
    partial = Path(tmp)
    try:
        yield partial
        if os.name == "nt":
            os.rename(partial, destination)
        else:
            os.link(partial, destination)
    finally:
        partial.unlink(missing_ok=True)


def read_input(path, expected_space="srgb"):
    import numpy as np
    import tifffile

    with tifffile.TiffFile(path) as photo:
        page = photo.pages[0]
        tag = page.tags.get(34675)
        icc = tag.value if tag is not None else None
        if page.photometric.name != "RGB" or page.bitspersample != 16 or page.samplesperpixel != 3:
            raise ValueError("Input must be a 16-bit RGB TIFF rendered by Lightroom.")
        if page.sampleformat != 1:
            raise ValueError("Input samples must be unsigned 16-bit integers.")
        rgb = page.asarray()
        if page.planarconfig == 2:
            rgb = np.moveaxis(rgb, 0, -1)
        orientation = page.tags.get("Orientation")
        direction = orientation.value if orientation else 1
        if direction not in range(1, 9):
            raise ValueError("Invalid TIFF orientation.")
        if direction >= 5:
            rgb = rgb.swapaxes(0, 1)
        if direction in (2, 3, 6, 7):
            rgb = rgb[:, ::-1]
        if direction in (3, 4, 7, 8):
            rgb = rgb[::-1]
    rgb = np.ascontiguousarray(rgb, dtype=np.float32)
    rgb /= 65535.0
    from bridge.print_output import honor_input_profile
    return honor_input_profile(rgb, icc, expected_space)


@lru_cache(maxsize=4)
def simulator(film, paper, preview, physical=Physical(), input_space="sRGB",
              output_space="sRGB", frame_fraction=1):
    from bridge.physical import PhysicalSimulator
    from bridge.scanner import make_pipeline

    params = make_params(film, paper, physical, preview=preview, input_space=input_space,
                         output_space=output_space, frame_fraction=frame_fraction)
    return PhysicalSimulator(params, pipeline_factory=make_pipeline)


def resolve_paper(catalog, film_name, paper):
    if film_name in catalog["film"] and paper == "auto":
        film = catalog["film"][film_name]
        available = [name for name, stock in catalog["paper"].items()
                     if stock["channel_model"] == film["channel_model"]]
        paper = next((name for name in [film.get("target_print"), "kodak_portra_endura", *available]
                      if name in available), "kodak_portra_endura")
    if film_name not in catalog["film"] or paper not in catalog["paper"]:
        raise ValueError("Unknown film or paper. Use the 'profiles' command for valid IDs.")
    return paper


@lru_cache(maxsize=2)
def cineon_renderer(film, paper, physical, src, dst, frame_fraction):
    from bridge.cineon import build_renderer
    params = make_params(film, paper, physical, input_space=src, output_space=dst,
                         frame_fraction=frame_fraction)
    return build_renderer(params)


def render(args, catalog):
    global _last_proof
    import numpy as np
    from bridge import grade, print_output

    if not 1 <= args.quality <= 100:
        raise ValueError("JPEG quality must be between 1 and 100.")
    if not 0 < args.frame_fraction <= 1:
        raise ValueError("frame-fraction must be > 0 and <= 1.")
    if args.output.exists() and args.collision != "overwrite":
        raise FileExistsError(f"Output exists: {args.output}")
    src = print_output.colour_name(args.input_space)
    dst = print_output.colour_name(args.output_space)

    def frame(path, ev, film, paper, recipe, mode, diagnostic_path=None):
        paper = resolve_paper(catalog, film, paper)
        physical, post = parse_recipe(json.loads(recipe))
        rgb = print_output.expose(read_input(path, args.input_space), ev, args.input_space)
        if diagnostic_path:
            values = grade.diagnostics(rgb, film, paper, physical, src, post)
            with new_output(diagnostic_path) as tmp:
                tmp.write_text("".join(f"{k}\t{v:.6f}\n" for k, v in values.items()), encoding="utf-8")
        rgb = grade.placement(rgb, post, src)
        if args.cineon:
            try:
                result = cineon_renderer(film,paper,physical,src,dst,args.frame_fraction)(rgb)
            except Exception:
                cineon_renderer.cache_clear()
                raise
            if catalog["film"][film]["channel_model"] == "bw":
                result = np.repeat(result.mean(axis=-1, keepdims=True), 3, axis=-1)
            return result, False
        if mode == "fast-color":
            from bridge.fast_color import apply
            result = apply(rgb, film, paper, physical, src, dst)
        else:
            try:
                result = simulator(film, paper, mode == "preview", physical, src,
                                   dst, args.frame_fraction).process(rgb)
            except Exception:
                # Discard partially populated engine caches after a failed frame.
                simulator.cache_clear()
                raise
        if result.shape != rgb.shape or not np.isfinite(result).all():
            raise ValueError("The engine returned an invalid RGB image.")
        if catalog["film"][film]["channel_model"] == "bw":
            result = grade.silver_output(result, dst)
        printed = not (physical.scan or catalog["film"][film]["type"] == "positive")
        return grade.grade(result, post, dst), printed

    mode = "fast-color" if args.fast_color else "preview" if args.preview else "full"
    proof_key = None
    if args.display_proof and not args.pair_input:
        stat = args.input.stat()
        proof_key = (args.input.resolve(), stat.st_ino, stat.st_mtime_ns, stat.st_size,
                     args.film, args.paper, args.recipe, mode, args.input_space, args.output_space,
                     args.frame_fraction, args.first_ev, args.cineon, bool(args.diagnostics))
    if proof_key is not None and _last_proof is not None and _last_proof[0] == proof_key:
        _, result, printed, diagnostics = _last_proof
        if args.diagnostics:
            with new_output(args.diagnostics) as tmp:
                tmp.write_bytes(diagnostics)
    else:
        _last_proof = None
        result, printed = frame(args.input, args.first_ev, args.film, args.paper, args.recipe, mode, args.diagnostics)
        if proof_key is not None and result.nbytes <= 128 * 1024 * 1024:
            diagnostics = args.diagnostics.read_bytes() if args.diagnostics else None
            _last_proof = (proof_key, result, printed, diagnostics)
    second = None
    if args.pair_input:
        second, mate_printed = frame(args.pair_input, args.second_ev, args.pair_film or args.film,
                                     args.pair_paper or args.paper, args.pair_recipe or args.recipe,
                                     args.pair_mode or mode)
        printed = printed and mate_printed
    print_output.publish(args.output, result, args, second=second, printed=printed)


def main():
    from bridge import inspection, print_output
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("profiles")
    listing.add_argument("--output", type=Path, required=True)
    listing.add_argument("--details", action="store_true")
    job = commands.add_parser("render")
    job.add_argument("--input", type=Path, required=True)
    job.add_argument("--output", type=Path, required=True)
    job.add_argument("--film", required=True)
    job.add_argument("--paper", required=True)
    job.add_argument("--quality", type=int, default=90)
    job.add_argument("--recipe", default="{}")
    job.add_argument("--diagnostics", type=Path)
    job.add_argument("--frame-fraction", type=float, default=1.0)
    print_output.add_arguments(job)
    inspection.configure_parser(commands)
    modes = job.add_mutually_exclusive_group()
    modes.add_argument("--preview", action="store_true")
    modes.add_argument("--fast-color", action="store_true")
    server = commands.add_parser("serve")
    server.add_argument("--session", type=Path, required=True)
    args = parser.parse_args()

    configure_runtime()
    catalog = profiles()
    if args.command == "serve":
        def run(fields):
            if not fields or fields[0] not in ("render", "profiles", "inspect", "crop-input"):
                raise ValueError("Invalid worker command.")
            execute(parser.parse_args(fields), catalog)

        serve(args.session, run)
    else:
        execute(args, catalog)


def execute(args, catalog):
    if args.command == "profiles":
        rows = []
        for kind, stocks in catalog.items():
            for stock, info in stocks.items():
                fields = [kind, stock]
                if args.details:
                    fields.extend([info["type"], info["channel_model"], info.get("target_print") or "",
                                   info["name"], info["support"]])
                rows.append("\t".join(fields) + "\n")
        with new_output(args.output) as destination:
            destination.write_text("".join(rows), encoding="utf-8")
    elif args.command == "render":
        render(args, catalog)
    else:
        from bridge import inspection
        inspection.run(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Spektrafilm: {error}", file=sys.stderr)
        sys.exit(1)
