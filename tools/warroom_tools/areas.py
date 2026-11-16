"""Which zone owns each patch of ground: the area IDs the terrain files (ADTs) carry per chunk.

Every terrain tile is 16 x 16 chunks of 33 1/3 yards, and each chunk names its area (a subzone such as Razor Hill,
whose parent is Durotar). Walking the areas up to their zone and the zone to its world map (UiMapAssignment) gives a
grid per continent of which map owns each chunk: the shape of every zone, down to 33 yards. The map art tool uses it
to cut each zone's painting to its own ground.

Forever's terrain files carry no water, so the sea is told from the heights: each chunk also records how many of its
145 height points lie below sea level (height 0).

Only the chunk headers and heights matter, so the ADTs are not kept: what they say is cached in tools/.cache/areas/.
"""

import json
import struct
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import wago

CACHE = wago.CACHE.parent / "areas"
CHUNKS = 16  # per tile side
HEIGHTS = 145  # height points per chunk
_MCNK, _MCVT = b"KNCM", b"TVCM"  # chunk tags are stored reversed


def chunk_info(adt):
    """([256 area IDs], [256 counts of height points below sea level]) of a root ADT's chunks, row by row from the
    north-west (index iy * 16 + ix)."""
    areas = [0] * (CHUNKS * CHUNKS)
    below = [0] * (CHUNKS * CHUNKS)
    pos = 0
    while pos + 8 <= len(adt):
        tag, size = adt[pos : pos + 4], struct.unpack_from("<I", adt, pos + 4)[0]
        if tag == _MCNK:
            ix, iy = struct.unpack_from("<II", adt, pos + 12)
            if ix < CHUNKS and iy < CHUNKS:
                i = iy * CHUNKS + ix
                areas[i] = struct.unpack_from("<I", adt, pos + 8 + 0x34)[0]
                base = struct.unpack_from("<f", adt, pos + 8 + 0x70)[0]
                sub, end = pos + 8 + 128, pos + 8 + size
                while sub + 8 <= end:
                    sub_tag, sub_size = adt[sub : sub + 4], struct.unpack_from("<I", adt, sub + 4)[0]
                    if sub_tag == _MCVT:
                        heights = struct.unpack_from(f"<{HEIGHTS}f", adt, sub + 8)
                        below[i] = sum(1 for h in heights if base + h < 0)
                        break
                    sub += 8 + sub_size
        pos += 8 + size
    return areas, below


def _root_adts(directory, build, refresh=False):
    """{(tx, ty): fileID} of a map's root terrain files."""
    prefix = f"world/maps/{directory.lower()}/{directory.lower()}_"
    found = {}
    for file_id, path in wago.list_files(f"world/maps/{directory.lower()}/", build, refresh).items():
        path = path.lower()
        if not path.startswith(prefix) or not path.endswith(".adt"):
            continue
        parts = path[len(prefix) : -4].split("_")
        if len(parts) == 2 and all(p.isdigit() for p in parts):
            found[int(parts[0]), int(parts[1])] = file_id
    return found


def tile_areas(directory, tiles, build, refresh=False, workers=6, progress=None):
    """{(tx, ty): ([256 area IDs], [256 below-sea counts])} for the given tiles of a map (see chunk_info),
    downloading what is not cached yet."""
    path = CACHE / build / f"{directory.lower()}.v2.json"
    cached = {}
    if path.exists() and not refresh:
        cached = {tuple(map(int, k.split("_"))): tuple(v) for k, v in json.loads(path.read_text(encoding="utf-8")).items()}
    adts = _root_adts(directory, build, refresh)
    wanted = [t for t in tiles if t not in cached and t in adts]
    if wanted:
        def fetch(tile):
            return tile, chunk_info(wago.casc_file(adts[tile], cache=False))

        with ThreadPoolExecutor(workers) as pool:
            for done, (tile, info) in enumerate(pool.map(fetch, wanted), 1):
                cached[tile] = info
                if progress and (done % 50 == 0 or done == len(wanted)):
                    progress(directory, done, len(wanted))
                if done % 100 == 0:
                    _save(path, cached)
        _save(path, cached)
    return {t: cached[t] for t in tiles if t in cached}


def _save(path, cached):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps({f"{tx}_{ty}": v for (tx, ty), v in sorted(cached.items())}), encoding="utf-8")
    tmp.replace(path)


def zone_of_area(build, refresh=False):
    """{areaID: uiMapID} for every area on a zone the world map shows (subzones resolve to their zone)."""
    from .tiles import ZONE_TYPES

    types = {row["ID"]: row["Type"] for row in wago.read_db2("UiMap", build, refresh)}
    by_area = {}
    for row in wago.read_db2("UiMapAssignment", build, refresh):
        if row["AreaID"] != "0" and types.get(row["UiMapID"]) in ZONE_TYPES:
            by_area.setdefault(int(row["AreaID"]), int(row["UiMapID"]))
    parent = {int(row["ID"]): int(row["ParentAreaID"]) for row in wago.read_db2("AreaTable", build, refresh)}
    out = {}
    for area in parent:
        seen, a = set(), area
        while a and a not in by_area and a not in seen:
            seen.add(a)
            a = parent.get(a, 0)
        if a in by_area:
            out[area] = by_area[a]
    return out


SEA_POINTS = 90  # a chunk with this many of its 145 height points below sea level is water


def ground_tiles(map_id, directory, build, refresh=False):
    """The terrain tiles of a map worth drawing: those overlapping a zone's map, and those holding land joined to
    a zone's own ground over land (chunk to chunk), like the dunes south of Silithus. Islands with no zone ground
    on them (GM Island, Blizzard's sketch island east of Kalimdor) are left out, and so is open ocean."""
    import numpy as np

    from . import tiles

    found = tiles.tile_files(directory, build, refresh)
    regions = tiles.zone_regions(map_id, build, refresh)
    keep = {p for p in found if tiles.in_zones(regions, *p)}
    zone_of = zone_of_area(build, refresh)
    size = 64 * CHUNKS
    land = np.zeros((size, size), dtype=bool)
    seed = np.zeros((size, size), dtype=bool)
    for (tx, ty), (chunk_area, below) in tile_areas(directory, list(found), build, refresh).items():
        rows, cols = slice(ty * CHUNKS, (ty + 1) * CHUNKS), slice(tx * CHUNKS, (tx + 1) * CHUNKS)
        dry = np.array(below).reshape(CHUNKS, CHUNKS) < SEA_POINTS
        land[rows, cols] = dry
        seed[rows, cols] = dry & np.array([a in zone_of for a in chunk_area]).reshape(CHUNKS, CHUNKS)
    joined = _flood(seed, land)
    for tx, ty in found:
        if joined[ty * CHUNKS : (ty + 1) * CHUNKS, tx * CHUNKS : (tx + 1) * CHUNKS].any():
            keep.add((tx, ty))
    return keep


def _flood(seed, inside):
    """The cells of `inside` joined to `seed` through `inside`, side to side."""
    import numpy as np

    out = seed & inside
    while True:
        grown = out.copy()
        grown[1:, :] |= out[:-1, :]
        grown[:-1, :] |= out[1:, :]
        grown[:, 1:] |= out[:, :-1]
        grown[:, :-1] |= out[:, 1:]
        grown &= inside
        if np.array_equal(grown, out):
            return out
        out = grown
