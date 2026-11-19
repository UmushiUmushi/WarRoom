"""The world map's painted sheets and its lettered names: addons/WarRoom/Media/Map and Data/Labels.lua.

Far out, the world map is one sheet: Azeroth's painting. Zoomed in on a continent, its own painting comes in over it,
cut down to its land and coast (the sea stays Azeroth's, so the two never show a seam or a second sheet). Both are
OpenMap's copies of the game's paintings, cleaned of their lettering (art/edits); the continents' and seas' names
are lettered live instead, from OpenMap's Labels.lua (MIT), so they stay put and never show twice as the sheets
cross. An island the game links onto Azeroth's map from a map of its own (Zephras Isle) is its own map's painting,
cut down to the island and its coast: its terrain can't say where (it is ground all over, clouds and all), so the
island is found in the painting, inside its grey stone coast.

Each sheet is a 1024 x 1024 BLP stretched over its map's rectangle.
"""

import io

import numpy as np

from . import mapart, tiles, wago, zones

OUT_DIR = tiles.ROOT / "addons" / "WarRoom" / "Media" / "Map"
LABELS_FILE = tiles.ROOT / "addons" / "WarRoom" / "Data" / "Labels.lua"
WORLD = 947
SIZE = 1024
COAST_GROW = 180  # yards of sea past the terrain's coast kept with the land (the painted coast and its pale band)
COAST_SOFT = 110  # yards over which that fades out into Azeroth's sea


def sheet(img, alpha=None):
    """A SIZE x SIZE x 4 uint8 array of a picture stretched square, with `alpha` (0 to 1, the picture's size) or
    opaque."""
    from PIL import Image

    rgba = img.convert("RGBA")
    if alpha is not None:
        rgba.putalpha(Image.fromarray((np.clip(alpha, 0, 1) * 255).astype(np.uint8)))
    return np.asarray(rgba.resize((SIZE, SIZE), Image.LANCZOS))


def land_alpha(dry, rect, width, height):
    """How much of each pixel of a width x height picture of rect (north, west, south, east) is land or its coast:
    1 on dry ground (lakes included) and COAST_GROW yards past it, fading out over COAST_SOFT."""
    from scipy import ndimage

    r, c = zones.art_chunks(rect, width, height)
    land = ndimage.binary_fill_holes(dry)[r, c]
    yards = (rect[1] - rect[3]) / width
    dist = ndimage.distance_transform_edt(~land) * yards
    return np.clip((COAST_GROW + COAST_SOFT - dist) / COAST_SOFT, 0, 1)


ISLE_COAST = 0.26  # the painted coast's stone is greyer than this (saturation); parchment and land are not
ISLE_LAND = 0.55  # the island's paint is more saturated than this; the parchment round it is not
ISLE_PIECE = 150  # pixels: smaller grey specks are no part of the coast
ISLE_MIDDLE = (0.26, 0.76)  # across the painting: the coast's pieces lie between these (its clouds and towers don't)
ISLE_SOFT = 5  # pixels the cut fades over


def island_alpha(art):
    """How much of each pixel of an island map's painting is the island or its coast: the coast's grey pieces near
    the middle, and the land's saturated paint inside their hull, joined and filled."""
    from PIL import Image, ImageDraw
    from scipy import ndimage
    from scipy.spatial import ConvexHull

    a = np.asarray(art).astype(np.float32)
    top, bottom = a.max(2), a.min(2)
    sat = (top - bottom) / (top + 1)
    grey = ndimage.binary_dilation(sat < ISLE_COAST)
    label, n = ndimage.label(grey)
    index = np.arange(1, n + 1)
    size = ndimage.sum(grey, label, index)
    cy, cx = np.array(ndimage.center_of_mass(grey, label, index)).T
    w, h = art.size
    keep = index[(size >= ISLE_PIECE) & (cx > ISLE_MIDDLE[0] * w) & (cx < ISLE_MIDDLE[1] * w)
                 & (cy > 0.03 * h) & (cy < 0.97 * h)]
    coast = np.isin(label, keep)
    yy, xx = np.nonzero(coast)
    pts = np.c_[xx, yy]
    hull = Image.new("L", (w, h))
    ImageDraw.Draw(hull).polygon([tuple(map(int, pts[i])) for i in ConvexHull(pts).vertices], fill=1)
    land = np.asarray(hull).astype(bool) & ndimage.binary_opening(ndimage.gaussian_filter(sat, 2) > ISLE_LAND, iterations=2)
    island = ndimage.binary_fill_holes(ndimage.binary_closing(coast | land, iterations=4))
    parts, _ = ndimage.label(island)
    island = parts == np.bincount(parts.ravel())[1:].argmax() + 1
    return np.clip((ISLE_SOFT - ndimage.distance_transform_edt(~island)) / ISLE_SOFT, 0, 1)


def game_art(ui_map, build, refresh=False):
    """A map's own painting (its first art layer) as an RGB image, from the game's files."""
    from PIL import Image

    art_ids = [r["UiMapArtID"] for r in wago.read_db2("UiMapXMapArt", build, refresh) if int(r["UiMapID"]) == ui_map]
    if not art_ids:
        return None
    style = next(r["UiMapArtStyleID"] for r in wago.read_db2("UiMapArt", build, refresh) if r["ID"] == art_ids[0])
    layer = next(r for r in wago.read_db2("UiMapArtStyleLayer", build, refresh)
                 if r["UiMapArtStyleID"] == style and r["LayerIndex"] == "0")
    w, h = int(layer["LayerWidth"]), int(layer["LayerHeight"])
    tw, th = int(layer["TileWidth"]), int(layer["TileHeight"])
    img = Image.new("RGB", (-(-w // tw) * tw, -(-h // th) * th))
    for row in wago.read_db2("UiMapArtTile", build, refresh):
        if row["UiMapArtID"] == art_ids[0] and row["LayerIndex"] == "0":
            tile = Image.open(io.BytesIO(wago.casc_file(int(row["FileDataID"])))).convert("RGB")
            img.paste(tile, (int(row["ColIndex"]) * tw, int(row["RowIndex"]) * th))
    return img.crop((0, 0, w, h))


def islands(build, refresh=False):
    """{mapID: uiMapID} of the maps of their own the game puts on Azeroth's map (a zone whose parent is it)."""
    linked = {int(r["ID"]) for r in wago.read_db2("UiMap", build, refresh)
              if r["ParentUiMapID"] == str(WORLD) and r["Type"] == "3"}
    continents = set(zones.continent_maps(build, refresh))
    out = {}
    for row in wago.read_db2("UiMapAssignment", build, refresh):
        map_id, ui_map = int(row["MapID"]), int(row["UiMapID"])
        if ui_map in linked and map_id not in continents:
            out.setdefault(map_id, ui_map)
    return out


def build(build_id, refresh=False, out_dir=OUT_DIR, labels_file=LABELS_FILE):
    """Bakes the sheets and copies the labels. Returns [(file, what)]."""
    out_dir.mkdir(parents=True, exist_ok=True)
    made, files = [], set()

    def write(name, rgba, what):
        mapart.blp_write(out_dir / name, rgba)
        files.add(name)
        made.append((name, what))

    write("world.blp", sheet(zones.painted_art(WORLD)), "Azeroth")
    grids = zones.grids(build_id, refresh)
    for map_id, art_map in sorted(zones.continent_maps(build_id, refresh).items()):
        art = zones.painted_art(art_map)
        rect = zones.map_rects(map_id, build_id, refresh).get(art_map)
        if art is None or rect is None or map_id not in grids:
            continue
        alpha = land_alpha(grids[map_id][1], rect, *art.size)
        write(f"land_{art_map}.blp", sheet(art, alpha), f"continent {map_id}'s land")
    for map_id, ui_map in sorted(islands(build_id, refresh).items()):
        art = game_art(ui_map, build_id, refresh)
        if art is not None:
            write(f"isle_{ui_map}.blp", sheet(art, island_alpha(art)), f"island {ui_map} (map {map_id})")
    for old in out_dir.iterdir():
        if old.name not in files:
            old.unlink()

    repo = mapart.openmap_checkout()
    src = repo / "OpenMap" / "Data" / "Forever" / "Labels.lua"
    body = src.read_text(encoding="utf-8")
    licence = (repo / "LICENSE").read_text(encoding="utf-8").strip().splitlines()
    labels_file.write_text(
        f"-- Copied by `warroom worldart` from OpenMap {mapart.OPENMAP_COMMIT[:10]}: OpenMap/Data/Forever/Labels.lua.\n"
        "-- Do not edit. Drawn by WarRoom_Map/Labels.lua. OpenMap's licence:\n"
        + "".join(f"--   {line}".rstrip() + "\n" for line in licence)
        + "\n" + body,
        encoding="utf-8",
        newline="\n",
    )
    made.append((labels_file.name, "names"))
    return made
