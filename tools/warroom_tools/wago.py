"""Game data tables (DB2) as CSV from wago.tools, cached on disk per build."""

import csv
import hashlib
import io
import json
import urllib.parse
import urllib.request
from pathlib import Path

CACHE = Path(__file__).resolve().parents[1] / ".cache" / "db2"
USER_AGENT = "warroom-tools"


def fetch_db2(table, build, refresh=False):
    """Path to the cached CSV of a DB2 table for a build, downloading it when missing."""
    if not table.isidentifier():
        raise ValueError(f"not a table name: {table!r}")
    path = CACHE / build / f"{table}.csv"
    if path.exists() and not refresh:
        return path
    query = urllib.parse.urlencode({"build": build})
    url = f"https://wago.tools/db2/{table}/csv?{query}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        text = response.read().decode("utf-8")
    if text.lstrip().startswith("{"):
        raise RuntimeError(f"{table}: wago.tools answered {text.strip()[:200]}")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)
    return path


def read_db2(table, build, refresh=False):
    """A DB2 table's rows as dicts."""
    text = fetch_db2(table, build, refresh).read_text(encoding="utf-8")
    return list(csv.DictReader(io.StringIO(text)))


FILES_CACHE = CACHE.parent / "files"


def list_files(search, build, refresh=False):
    """{fileID: path} of the game files whose path contains `search`, cached on disk per build."""
    name = hashlib.sha1(search.encode("utf-8")).hexdigest()[:16] + ".json"
    path = FILES_CACHE / build / name
    if path.exists() and not refresh:
        found = json.loads(path.read_text(encoding="utf-8"))["files"]
    else:
        query = urllib.parse.urlencode({"search": search, "build": build})
        request = urllib.request.Request(f"https://wago.tools/api/files?{query}", headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=120) as response:
            answer = json.loads(response.read().decode("utf-8"))
        # A search with hits answers {"fileID": "path", ...}; one without answers [].
        found = answer if isinstance(answer, dict) else {}
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"search": search, "files": found}), encoding="utf-8")
    return {int(file_id): file_path for file_id, file_path in found.items()}


CASC_CACHE = CACHE.parent / "casc"


def casc_file(file_id, cache=True, refresh=False):
    """A game file's raw bytes by file ID (wago.tools serves the current build's), cached on disk when `cache`."""
    path = CASC_CACHE / str(file_id)
    if cache and path.exists() and not refresh:
        return path.read_bytes()
    url = f"https://wago.tools/api/casc/{int(file_id)}?download"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                data = response.read()
            break
        except OSError:
            if attempt == 3:
                raise
    if cache:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_bytes(data)
        tmp.replace(path)
    return data
