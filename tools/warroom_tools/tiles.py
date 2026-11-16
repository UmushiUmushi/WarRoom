"""Terrain tiles for the Canvas: which minimap texture covers each tile, and the fade masks for the coast.

A continent is a 64 x 64 grid of tiles (see Core/Coords.lua). The game's minimap texture for tile (tx, ty) is
world/minimaps/<map directory>/map<tx>_<ty>.blp; addons can only load it by file ID, so this writes the IDs into
addons/WarRoom/Data/Tiles.lua.

Tiles are drawn where they overlap a zone the world map shows, or hold land joined to a zone's ground (the dunes
south of Silithus, northern Hyjal): areas.ground_tiles, which reads the terrain files' areas (cached). Islands with no
zone ground (GM Island, Blizzard's placeholder sketch island) and open ocean are left out. Tiles of one flat colour
(Blizzard's teal and grey placeholders) are left out too: checking them downloads the tiles (cached), which needs
Pillow and numpy. A tile
on the edge of the land we have (a neighbour missing) gets a fade mask that
takes it from opaque on its inner side to clear on its open sides, so the terrain melts into the sea instead of
ending in square steps. Masks multiply a smooth fade per open side, and per open corner whose two sides are both
present, so neighbouring tiles agree along their shared edge.
"""

import math
import re
import struct
from pathlib import Path

from . import wago

ROOT = Path(__file__).resolve().parents[2]
DATA_FILE = ROOT / "addons" / "WarRoom" / "Data" / "Tiles.lua"
MASK_DIR = ROOT / "addons" / "WarRoom" / "Media" / "Fade"
MASK_SIZE = 64
TILE_YARDS = 1600 / 3

# Open-side bits of a fade key. Corner bits count only when both sides next to the corner are present.
N, E, S, W = 1, 2, 4, 8
NE, SE, SW, NW = 16, 32, 64, 128
_SIDES = ((N, 0, -1), (E, 1, 0), (S, 0, 1), (W, -1, 0))  # bit, dx (east), dy (south)
_CORNERS = ((NE, N, E, 1, -1), (SE, S, E, 1, 1), (SW, S, W, -1, 1), (NW, N, W, -1, -1))

_TILE_NAME = re.compile(r"/map(\d+)_(\d+)\.blp$")


def tile_files(directory, build, refresh=False):
    """{(tx, ty): fileID} of a map's minimap tiles (not the noliquid_ variants)."""
    prefix = f"world/minimaps/{directory.lower()}/"
    tiles = {}
    for file_id, path in wago.list_files(prefix, build, refresh).items():
        path = path.lower()
        if not path.startswith(prefix) or "/" in path[len(prefix):]:
            continue
        match = _TILE_NAME.search(path)
        if match and path[len(prefix):].startswith("map"):
            tiles[int(match.group(1)), int(match.group(2))] = file_id
    return tiles


def is_placeholder(blp_bytes):
    """Whether a minimap texture is one flat colour other than the deep ocean's near-black."""
    import io

    import numpy as np
    from PIL import Image

    rgb = np.asarray(Image.open(io.BytesIO(blp_bytes)).convert("RGB"), dtype=np.float64)
    return bool(rgb.std(axis=(0, 1)).max() < 1.0 and rgb.mean(axis=(0, 1)).sum() > 40)


def fade_key(tiles, tx, ty):
    """Which sides and corners of tile (tx, ty) open onto missing tiles (0: none, no mask needed)."""
    key = 0
    for bit, dx, dy in _SIDES:
        if (tx + dx, ty + dy) not in tiles:
            key |= bit
    for bit, side_a, side_b, dx, dy in _CORNERS:
        if not key & (side_a | side_b) and (tx + dx, ty + dy) not in tiles:
            key |= bit
    return key


def _smooth(t):
    t = min(max(t, 0.0), 1.0)
    return t * t * (3 - 2 * t)


def fade_alpha(key, u, v):
    """Opacity at (u, v) across a tile (u east, v south, 0 to 1) for a fade key."""
    a = 1.0
    if key & N:
        a *= _smooth(v)
    if key & S:
        a *= _smooth(1 - v)
    if key & W:
        a *= _smooth(u)
    if key & E:
        a *= _smooth(1 - u)
    for bit, _, _, cx, cy in _CORNERS:
        if key & bit:
            corner_u, corner_v = (1 if cx > 0 else 0), (1 if cy > 0 else 0)
            a *= _smooth(math.hypot(u - corner_u, v - corner_v))
    return a


def mask_tga(key, size=MASK_SIZE):
    """An uncompressed 32-bit TGA (top row first) whose colour and alpha both hold the fade."""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 0x28)
    pixels = bytearray()
    for row in range(size):
        v = (row + 0.5) / size
        for col in range(size):
            value = round(255 * fade_alpha(key, (col + 0.5) / size, v))
            pixels += bytes((value, value, value, value))
    return header + bytes(pixels)


def world_maps(build, refresh=False):
    """[(mapID, directory, name)] of the maps the game's world map shows (UiMapAssignment), in ID order."""
    assigned = {int(row["MapID"]) for row in wago.read_db2("UiMapAssignment", build, refresh)}
    maps = []
    for row in wago.read_db2("Map", build, refresh):
        if int(row["ID"]) in assigned:
            maps.append((int(row["ID"]), row["Directory"], row["MapName_lang"]))
    return sorted(maps)


# UiMap types whose area counts as playable ground: zone, dungeon, micro, orphan (battlegrounds). Not the world or
# continents, whose rectangles take in unreleased land and Blizzard's placeholder art.
ZONE_TYPES = {"3", "4", "5", "6"}


def zone_regions(map_id, build, refresh=False):
    """[(north, west, south, east)] world rectangles of the zones the world map shows on a map."""
    types = {row["ID"]: row["Type"] for row in wago.read_db2("UiMap", build, refresh)}
    regions = []
    for row in wago.read_db2("UiMapAssignment", build, refresh):
        if int(row["MapID"]) == map_id and types.get(row["UiMapID"]) in ZONE_TYPES:
            x0, y0, x1, y1 = (float(row[f"Region_{i}"]) for i in (0, 1, 3, 4))
            regions.append((x1, y1, x0, y0))
    return regions


def in_zones(regions, tx, ty):
    """Whether tile (tx, ty) overlaps any zone rectangle."""
    north, west = (32 - ty) * TILE_YARDS, (32 - tx) * TILE_YARDS
    south, east = north - TILE_YARDS, west - TILE_YARDS
    return any(r_south < north and r_north > south and r_east < west and r_west > east for r_north, r_west, r_south, r_east in regions)


def _lua_table(entries, per_line=12):
    lines = []
    for i in range(0, len(entries), per_line):
        lines.append("\t\t\t" + " ".join(f"[{k}]={v}," for k, v in entries[i : i + per_line]))
    return "\n".join(lines)


def build(build_id, refresh=False, data_file=DATA_FILE, mask_dir=MASK_DIR):
    """Writes Data/Tiles.lua and the fade masks it uses. Returns {mapID: (name, tiles, edge tiles, tiles left out)}."""
    summary = {}
    keys_used = set()
    blocks = []
    for map_id, directory, name in world_maps(build_id, refresh):
        found = tile_files(directory, build_id, refresh)
        from .areas import ground_tiles

        ground = ground_tiles(map_id, directory, build_id, refresh)
        tiles = {p: fid for p, fid in found.items() if p in ground}
        tiles = {p: fid for p, fid in tiles.items() if not is_placeholder(wago.casc_file(fid))}
        if not tiles:
            continue
        files = sorted((tx * 64 + ty, fid) for (tx, ty), fid in tiles.items())
        fades = []
        for (tx, ty) in tiles:
            key = fade_key(tiles, tx, ty)
            if key:
                fades.append((tx * 64 + ty, key))
                keys_used.add(key)
        fades.sort()
        summary[map_id] = (name, len(tiles), len(fades), len(found) - len(tiles))
        blocks.append(
            f"\t[{map_id}] = {{ -- {name}\n"
            f'\t\tdir = "{directory.lower()}",\n'
            f"\t\tfiles = {{\n{_lua_table(files, 8)}\n\t\t}},\n"
            f"\t\tfade = {{\n{_lua_table(fades, 12)}\n\t\t}},\n"
            f"\t}},"
        )

    data_file.parent.mkdir(parents=True, exist_ok=True)
    data_file.write_text(
        f"-- Generated by `warroom tiles` from build {build_id}. Do not edit.\n"
        "-- [mapID] = { dir, files = { [tx*64+ty] = minimap texture file ID }, fade = { [tx*64+ty] = fade key } }\n"
        "-- A fade key names Media/Fade/fade_<key>.tga (tools/warroom_tools/tiles.py says what the bits mean).\n"
        "local _, ns = ...\n"
        f'ns.TileData = {{\n\tbuild = "{build_id}",\n' + "\n".join(blocks) + "\n}\n",
        encoding="utf-8",
        newline="\n",
    )

    mask_dir.mkdir(parents=True, exist_ok=True)
    for old in mask_dir.glob("fade_*.tga"):
        if int(old.stem.split("_")[1]) not in keys_used:
            old.unlink()
    for key in sorted(keys_used):
        (mask_dir / f"fade_{key}.tga").write_bytes(mask_tga(key))
    return summary, keys_used
