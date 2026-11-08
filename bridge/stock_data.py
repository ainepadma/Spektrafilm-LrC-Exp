"""Load SpektraLab product stocks alongside the unmodified spektrafilm package."""

from dataclasses import fields
from functools import lru_cache
from importlib.metadata import distribution
import json
from pathlib import Path


PRODUCT = Path(__file__).resolve().parents[1] / "assets" / "stocks"
PACKAGE = distribution("spektrafilm").locate_file("spektrafilm/data/profiles")


@lru_cache(maxsize=1)
def product_records():
    return {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in PRODUCT.glob("*.json")
            if p.name != "neutral_print_filters.json"}


def merged_profiles():
    profiles = {}
    for key, record in product_records().items():
        base = {}
        if "derived_from" in record:
            base = json.loads((PACKAGE / (record["derived_from"] + ".json")).read_text(encoding="utf-8"))["info"]
        profiles[key] = {**base, **record["info"], "stock": key}
    return profiles


def load_stock(name):
    from spektrafilm import load_profile
    from spektrafilm.profiles.io import ProfileMetadata, profile_from_dict

    record = product_records().get(name)
    if record is None:
        return load_profile(name)
    if "derived_from" in record:
        profile = load_profile(record["derived_from"])
        for attr, value in record["info"].items():
            setattr(profile.info, attr, value)
        profile.info.stock = name
        return profile
    # The original metadata also carries source digitization and fit provenance.
    # Preserve it in assets; the engine's metadata dataclass accepts a subset.
    metadata = {k.name: record["metadata"][k.name] for k in fields(ProfileMetadata)
                if k.name in record["metadata"]}
    return profile_from_dict({**record, "metadata": metadata})


def make_stock_params(film, paper):
    from spektrafilm.runtime.params_schema import RuntimePhotoParams
    from spektrafilm.runtime.params_builder import apply_database_neutral_print_filters

    params = RuntimePhotoParams(film=load_stock(film), print=load_stock(paper))
    if params.print.is_bw:
        database = json.loads((PRODUCT / "neutral_print_filters.json").read_text(encoding="utf-8"))
        apply_database_neutral_print_filters(params, database=database, warn_missing=False)
        params.settings.neutral_print_filters_from_database = False
    elif film in product_records() and "derived_from" in product_records()[film]:
        # Use the base stock's neutral printer pack, while keeping this film's
        # anti-halation profile for image formation.
        params.film.info.stock = product_records()[film]["derived_from"]
        apply_database_neutral_print_filters(params, warn_missing=False)
        params.film.info.stock = film
        params.settings.neutral_print_filters_from_database = False
    return params
