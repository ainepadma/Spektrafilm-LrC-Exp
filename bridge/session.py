"""One serial render queue per Lightroom floating window."""

import base64
import re
import shutil
import time


REQUEST = re.compile(r"request-(\d{8})\.job")


def arguments(job):
    if job.is_dir():
        # The SDK can create Unicode paths but Lua's native file streams use
        # the Windows code page. Safe directory names carry the UTF-8 data.
        chunks = []
        for index, child in enumerate(sorted(p for p in job.iterdir() if p.name != "complete"), 1):
            match = re.fullmatch(rf"{index:04d}_([A-Za-z0-9_=-]{{1,80}})", child.name)
            if not match or index > 1100:
                raise ValueError("Invalid request fragments.")
            chunks.append(match[1])
        encoded = "".join(chunks)
        payload = base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True)
    else:
        with job.open("rb") as stream:
            payload = stream.read(65537)
    if not payload or len(payload) > 65536:
        raise ValueError("Invalid request size.")
    return payload.decode("utf-8").split("\0")


def run_job(job, request_id, execute):
    session = job.parent
    claimed = job.with_suffix(".running")
    job.rename(claimed)
    try:
        execute(arguments(claimed))
        message = "ok\n"
    except (Exception, SystemExit) as error:
        message = f"error\n{error}"
        print(f"Request {request_id}: {error}", flush=True)
    finally:
        if claimed.is_dir():
            shutil.rmtree(claimed)
        else:
            claimed.unlink(missing_ok=True)
    # Lua may close the window after an error. Do not recreate a deleted session.
    if session.is_dir():
        response = session / f"response-{request_id}.txt"
        temporary = response.with_suffix(".tmp")
        temporary.write_text(message, encoding="utf-8")
        temporary.replace(response)


def serve(session, execute):
    started = time.time()
    # Claim this freshly-created session before servicing jobs. A crashed
    # worker's request is never replayed into what could be an existing export.
    ready = session / "ready.txt"
    with ready.open("x", encoding="ascii") as marker:
        marker.write("ready\n")
    heartbeat = session / "heartbeat.txt"
    try:
        while session.is_dir() and not (session / "stop.txt").exists():
            try:
                last_seen = heartbeat.stat().st_mtime
            except FileNotFoundError:
                last_seen = started
            if time.time() - last_seen > 120:
                break
            for job in sorted(session.glob("request-*.job")):
                match = REQUEST.fullmatch(job.name)
                if match and (job.is_file() or (job / "complete").is_dir()):
                    run_job(job, match[1], execute)
                    break
            else:
                time.sleep(0.04)
    finally:
        ready.unlink(missing_ok=True)
