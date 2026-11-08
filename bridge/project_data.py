"""Publish project-local Lua settings using Unicode-safe, atomic replacements."""

import base64
import json
import os
from pathlib import Path
import re
import sys
from tempfile import NamedTemporaryFile


def publish(folder, staging):
    runtime = Path(__file__).resolve().parents[1] / ".runtime"
    if not folder.is_relative_to(runtime) or staging.parent != folder:
        raise ValueError("Settings must be stored inside the project runtime.")
    payload = staging / "records"
    if payload.exists():
        data = payload.read_bytes()
    else:
        chunks = sorted(path.name for path in staging.iterdir())
        data = base64.b64decode("".join(s.split("_", 1)[1] for s in chunks),
                                altchars=b"-_", validate=True)
    records = json.loads(data)
    if not isinstance(records, dict) or not all(re.fullmatch(r"[A-Za-z0-9_-]{1,120}", k)
                                                 for k in records):
        raise ValueError("Invalid settings record key.")
    for key, record in records.items():
        with NamedTemporaryFile(dir=staging, delete=False, mode="w", encoding="utf-8") as file:
            json.dump(record, file, ensure_ascii=False, allow_nan=False)
        os.replace(file.name, folder / f"{key}.json")


if __name__ == "__main__":
    publish(*(Path(arg).resolve() for arg in sys.argv[1:]))
