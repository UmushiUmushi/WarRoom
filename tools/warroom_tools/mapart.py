"""The painted map for the Canvas's middle zoom: addons/WarRoom/Data/MapArt.lua and the textures in Media/Bake.

Each of the game's zone maps paints one zone on its own sheet of parchment, with a burnt edge. OpenMap
(https://github.com/openmap-world/openmap, MIT licence) stitches them into one seamless map from the game's own
art: each zone's painting shown over its territory (its own land, the sea off its coasts and the land round it
that it paints, shared with its neighbours by nearness and faded inside its frame, colour-matched along its
borders), the land no zone map paints filled from Blizzard's older classic maps of it (which paint the land round
their zone) or blank map paper, and the city banners cut out so a city's own map can take over.

We run OpenMap's out-of-game renderer (tools/map-preview/render.py, which draws what its addon draws, from its
masks and tables and the game's files) at full zone detail, sampling every layer at each pixel's own world
position, and keep the pictures as tiles on Azeroth's map (uiMap 947, whose units are about 45 yards), at three
sizes (LEVELS), the Canvas showing the coarsest that is still as sharp as the screen:
  far   6 px a unit, over each continent's map
  near  12 px a unit, where the far tiles have anything
  fine  24 px a unit, over the zones whose own art is finer than FINE_FROM px a unit (the small zones)
A tile is a mipmapped BLP, 512 px a side, whose outermost pixel on each side repeats its neighbour's, so filtering
never shows a seam: DXT1 where it is all land, DXT5 where it fades out over the sea. The sea itself (the sea's
paper and the coasts' hatching) is left out, as are the cities and their banners: the Canvas draws those live, so
the continent's own ocean can show over the sea until you are close, and a city's own map can take over from its
banner. The sea's textures are OpenMap's (MIT), copied next to the tiles.
"""

import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import client, tiles, wago
from .tiles import ZONE_TYPES

ROOT = Path(__file__).resolve().parents[2]
DATA_FILE = ROOT / "addons" / "WarRoom" / "Data" / "MapArt.lua"
BAKE_DIR = ROOT / "addons" / "WarRoom" / "Media" / "Bake"
CACHE = wago.CACHE.parent

OPENMAP_URL = "https://github.com/openmap-world/openmap.git"
OPENMAP_COMMIT = "9ebb7d382a7513d981310aa077e2bd00069a2355"
OPENMAP_DIR = CACHE / "openmap"
OPENMAP_TEX = CACHE / "openmap-tex"  # the game's textures OpenMap's renderer reads, by file ID

WORLD = 947
WORLD_W, WORLD_H = 1002.0, 668.0  # Azeroth's map in its own units
TILE = 512  # px a tile side...
STEP = TILE - 2  # ...of which these show the tile's own part of the world (the rest: its neighbours' edge)
# The tile sizes, coarse to fine: (name, px a unit). Each is twice the last, so a tile's four children are its four
# quarters. (A zone map's own art is 4 px a unit in the Barrens, 11 most, 22 the smallest zones.)
LEVELS = (("far", 6), ("near", 12), ("fine", 24))
FINE_FROM = 9.5  # a zone whose art is finer than this many px a unit gets fine tiles
EMPTY = 2 / 255  # a tile (or a quarter of one) with no more alpha than this anywhere is left out
OCTAVE_PX = 12  # (the renderer's own sizes for its textures that scale with zoom, fixed at this resolution)
WORKERS = max(1, min(8, (os.cpu_count() or 2) - 2))  # renderers drawing tiles side by side
# The live sea (Stitch.lua's, in the Canvas): OpenMap's textures, sizes in continent-art px, and the zoom at which
# each starts halving to keep its size on screen.
SEA_TILE, HATCH_TILE = 128, (34, 84)
SEA_OCTAVE, HATCH_OCTAVE = 4, 7  # OpenMap's zoom: 1 = Azeroth's map across the map's frame (~1002 UI units)
HATCH_ALPHA = 0.6
SEA_REACH = 1.5  # how far past Azeroth's map (its sizes) the sea runs
SEA_COLOR = (0.50, 0.49, 0.41)  # under everything else of the sea
FADE_ZOOM = 8.0  # OpenMap's zoom (its fades) the tiles are drawn at: every zone at full detail
UNDERGROUND = (1455, 1458)  # Ironforge, Undercity: under their zones' surface (their maps show from inside)
# City banners painted into a zone's own art, not only its overlays (Teldrassil's DARNASSUS): the client still has
# the classic copy of that map, the same drawing without the banner, so the box (left, top, right, bottom art px of
# 1002 x 668) is taken from it, fading in over CLEAN_FEATHER px. The Canvas draws the banner itself over the tiles,
# so it can give way to the city's own map. (Elwynn's classic copy has STORMWIND lettered on it too.)
CLEAN_BANNERS = {1438: ("teldrassil", (95, 405, 425, 500))}
CLEAN_FEATHER = 16
CLEAN_RING = 40  # art px round the box over which the classic copy's colours are matched to the new art's
# City maps OpenMap draws whole (a round fade over their parchment card): cut down to the city's plan and its own
# name plate instead, outlines traced on their art (1002 x 668 px), as OpenMap's banners.py does for the others.
CITY_CUTS = {
    1457: [  # Darnassus: the terraces, the Enclave, the Temple Gardens and the Temple of the Moon, the roads out
        [(60, 225), (250, 175), (290, 120), (290, 50), (330, 25), (450, 35), (500, 45), (560, 20), (650, 30),
         (720, 70), (730, 180), (720, 200), (860, 200), (870, 175), (920, 180), (920, 300), (860, 300), (850, 270),
         (730, 275), (735, 330), (750, 420), (745, 520), (690, 580), (520, 590), (520, 640), (270, 640), (270, 550),
         (240, 500), (240, 300), (100, 300), (60, 280)],
        [(320, 605), (340, 585), (400, 580), (620, 580), (680, 590), (705, 610), (690, 640), (640, 648), (400, 645),
         (340, 645)],  # its name plate
    ],
    1453: [  # Stormwind: the harbour's docks and walls, the districts, the Keep (not the lion emblem)
        [(170, 60), (330, 40), (460, 50), (470, 120), (600, 150), (700, 160), (760, 200), (850, 210), (910, 260),
         (880, 300), (820, 330), (830, 420), (870, 450), (830, 500), (790, 520), (800, 600), (720, 620), (560, 610),
         (400, 590), (330, 540), (270, 480), (250, 400), (200, 380), (170, 300), (160, 120)],
        [(530, 70), (560, 50), (600, 45), (820, 45), (850, 55), (865, 70), (850, 90), (820, 95), (600, 95),
         (560, 92)],  # its name plate
    ],
    # Thunder Bluff: OpenMap's cut keeps a band right across the card to hide its banner's hole in Mulgore, which
    # _clean_over now fills: the four rises, their bridges and its name plate only.
    1456: [
        [(170, 80), (230, 45), (320, 60), (345, 120), (330, 200), (300, 250), (220, 260), (170, 220), (160, 150)],
        [(690, 140), (760, 105), (840, 120), (860, 190), (840, 270), (760, 290), (700, 260), (680, 200)],
        [(330, 250), (390, 200), (470, 160), (560, 170), (640, 230), (680, 300), (660, 380), (600, 430), (520, 470),
         (440, 460), (370, 430), (320, 380), (300, 300)],
        [(510, 500), (560, 470), (640, 490), (665, 560), (640, 630), (560, 640), (520, 600)],
        [(330, 40), (400, 25), (640, 25), (660, 60), (640, 90), (400, 90), (340, 85)],  # its name plate
        [(290, 225), (305, 215), (390, 295), (375, 305)],  # the bridges
        [(555, 225), (695, 170), (702, 185), (562, 240)],
        [(600, 275), (715, 195), (725, 208), (610, 288)],
        [(495, 440), (510, 435), (548, 492), (533, 497)],
        [(612, 420), (627, 418), (637, 500), (622, 502)],
    ],
}
CITY_SOFT = 30  # art px over which a city's cut fades out past its outline
# Cities whose ground the tiles leave as blank paper (OpenMap cuts their zones' overlay pieces of them out, banner and
# all, for its cities' own maps): their "banner" is that whole piece instead (the city drawn as its zone's map draws
# it, with its big banner), so they show as the other cities do: their zone's drawing of them on the detailed map,
# giving way to their own maps closer in. {city: the area of its zone's overlay piece}
CITY_PIECES = {1454: 1637, 1456: 1638}  # Orgrimmar, Thunder Bluff
CITY_FRAME = (12, 40)  # art px in from its map's edge where a cut is gone / whole (the card's burnt edge)


# ---------------------------------------------------------------------------------------------------------------
# OpenMap's renderer
# ---------------------------------------------------------------------------------------------------------------
def openmap_checkout():
    """OpenMap's repository at OPENMAP_COMMIT (cloned into the cache the first time)."""
    head = None
    if (OPENMAP_DIR / ".git").exists():
        head = subprocess.run(["git", "-C", str(OPENMAP_DIR), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if head != OPENMAP_COMMIT:
        OPENMAP_DIR.mkdir(parents=True, exist_ok=True)
        git = ["git", "-C", str(OPENMAP_DIR)]
        if not (OPENMAP_DIR / ".git").exists():
            subprocess.run(git + ["init", "-q"], check=True)
            subprocess.run(git + ["remote", "add", "origin", OPENMAP_URL], check=True)
        subprocess.run(git + ["fetch", "-q", "--depth", "1", "origin", OPENMAP_COMMIT], check=True)
        subprocess.run(git + ["checkout", "-q", "--force", OPENMAP_COMMIT], check=True)
    return OPENMAP_DIR


# Replaces render.py's place(), which crops and resizes each map to whole output pixels (fine for one picture, but
# tiles side by side would each round differently): every layer is sampled at each pixel's own world position, and
# laid over the picture with its alpha (the picture is premultiplied RGBA: see _ALPHA).
_PLACE = '''    def place(m, img, alpha_mask, tint=(1, 1, 1), dsat=0.0, alpha=1.0):
        if alpha <= 0.001: return
        l, r, t, b = m["rect"]
        wx = (np.arange(OW) - OW / 2) / px + cu * W
        wy = (np.arange(OH) - OH / 2) / px + cv * H
        ix = np.nonzero((wx >= l * W) & (wx <= r * W))[0]
        iy = np.nonzero((wy >= t * H) & (wy <= b * H))[0]
        if len(ix) == 0 or len(iy) == 0: return
        if callable(img): img = img(m)
        if img is None: return
        def grid(shape):
            sx = (wx[ix] / W - l) / (r - l) * shape[1] - 0.5
            sy = (wy[iy] / H - t) / (b - t) * shape[0] - 0.5
            return np.meshgrid(sy, sx, indexing="ij")
        G = grid(img.shape)
        samp = lambda ch, g=G: ndimage.map_coordinates(ch, list(g), order=1, mode="nearest")
        a = samp(img[..., 3]) * alpha
        if alpha_mask is not None and not np.isscalar(alpha_mask):
            a = a * samp(alpha_mask, grid(alpha_mask.shape))
        elif alpha_mask is not None:
            a = a * alpha_mask
        if a.max() <= 0: return
        rgb = desat(np.dstack([samp(img[..., c]) for c in range(3)]), dsat) * np.array(tint, np.float32)
        dst = out[iy[0]:iy[-1] + 1, ix[0]:ix[-1] + 1]
        dst[:] = dst * (1 - a[..., None]) + np.dstack([rgb, np.ones_like(a)]) * a[..., None]

'''


# render.py draws onto its sea; for tiles it draws onto nothing instead, keeping each pixel's alpha (premultiplied
# RGBA), without the sea (its field, paper and hatching: the Canvas draws them) and saving the picture with its alpha.
_ALPHA = [
    ("    out = np.zeros((OH, OW, 3), np.float32)\n    out[:] = SEA\n", "    out = np.zeros((OH, OW, 4), np.float32)\n"),
    ('    fo = tex_rgba("MapSeaFieldOut") if USE_SEA and not ZONES_ONLY and not USE_CHART else None', "    fo = None"),
    ("                    dst[:] = dst * (1 - aa) + col * aa",
     "                    dst[:] = dst * (1 - aa) + np.dstack([col, np.ones(col.shape[:2], np.float32)]) * aa"),
    ("            out[:] = out * (1 - a[..., None]) + g[gy, gx, :3] * a[..., None]",
     "            out[:] = out * (1 - a[..., None]) + np.dstack([g[gy, gx, :3], np.ones_like(a)]) * a[..., None]"),
    ("    if USE_SEA and not ZONES_ONLY: sea_field()", "    pass"),
    ("    if USE_SEA and ws_ > 0 and not ZONES_ONLY: sea_over(ws_)", "    pass"),
    ("            if USE_SEA and max(m_, sm_) > 0: hatch_over(", "            if False: hatch_over("),
    ("    Image.fromarray((np.clip(out * BRIGHTNESS, 0, 1) * 255).astype(np.uint8)).save(path)",
     "    a_ = out[..., 3:4]\n"
     "    rgb_ = np.where(a_ > 1e-6, out[..., :3] / np.maximum(a_, 1e-6), 0)\n"
     "    Image.fromarray((np.clip(np.concatenate([rgb_ * BRIGHTNESS, a_], 2), 0, 1) * 255 + 0.5).astype(np.uint8), \"RGBA\").save(path)"),
]


def renderer(build, refresh=False):
    """OpenMap's render.py, loaded as a module (a dict of its globals) and set up to draw tiles: TILE px square, every
    fade at FADE_ZOOM, without the sea, cities or banners, onto nothing (RGBA)."""
    repo = openmap_checkout()
    for table in ("UiMap", "UiMapXMapArt", "UiMapArt", "UiMapArtTile", "UiMapAssignment", "WorldMapOverlay", "WorldMapOverlayTile"):
        wago.read_db2(table, build, refresh)
    os.environ["OPENMAP_SIZE"] = f"{TILE}x{TILE}"
    root = client.find_install()
    if root and (root / client.FOREVER_FOLDER).exists():
        os.environ.setdefault("OPENMAP_WOW", str(root))  # the game's files read from the install, not downloaded
    path = repo / "tools" / "map-preview" / "render.py"
    src = path.read_text(encoding="utf-8").split("\nviews = sys.argv[4:]")[0]
    a, b = src.index("    def place(m, img, alpha_mask,"), src.index("    def gap_over(")
    src = src[:a] + _PLACE + src[b:]
    src = src.replace("o = max(0.0, math.log(zoom / zoom_from, 2))", "o = max(0.0, math.log(OCTAVE_ZOOM / zoom_from, 2))")
    for old, new in _ALPHA:
        assert src.count(old) == 1, old
        src = src.replace(old, new)
    OPENMAP_TEX.mkdir(parents=True, exist_ok=True)
    argv = sys.argv
    sys.argv = [str(path), str(wago.CACHE / build), str(OPENMAP_TEX), str(OPENMAP_TEX / "_renders")]
    try:
        g = {"__file__": str(path), "__name__": "openmap_render"}
        exec(compile(src, str(path), "exec"), g)
    finally:
        sys.argv = argv
    g["FADE_ZOOM"] = FADE_ZOOM
    g["OCTAVE_ZOOM"] = OCTAVE_PX / min(TILE / WORLD_W, TILE / WORLD_H)
    g["CITY_FADE"], g["CITY_FADE_OF"] = (1e9, 2e9), {}
    g["banner"] = lambda city: None
    g["base"] = _clean_base(g["base"], g["fetch"], build)
    g["over"] = _clean_over(g["over"], g["base"], g["overlay_canvas"])
    return g


def classic_art(fetch, name, build):
    """A zone's classic base map (interface/worldmap/<name>/<name>1..12.blp) as a 668 x 1002 x 4 float array."""
    import numpy as np
    from PIL import Image

    files = wago.list_files(f"interface/worldmap/{name}/{name}", build)
    by_name = {p.rsplit("/", 1)[1]: f for f, p in files.items()}
    img = Image.new("RGBA", (1024, 768))
    for k in range(12):
        fid = by_name.get(f"{name}{k + 1}.blp")
        tile = fetch(fid) if fid else None
        if tile is not None:
            img.paste(tile, ((k % 4) * 256, (k // 4) * 256))
    return np.asarray(img.crop((0, 0, 1002, 668))).astype(np.float32) / 255


def _clean_base(base, fetch, build):
    """render.py's base(m), with CLEAN_BANNERS painted out from their maps' classic copies."""
    import numpy as np

    done = {}

    def clean(m):
        art = base(m)
        if m["id"] not in CLEAN_BANNERS:
            return art
        if m["id"] not in done:
            name, (left, top, right, bottom) = CLEAN_BANNERS[m["id"]]
            classic = classic_art(fetch, name, build)
            ys, xs = np.mgrid[0:668, 0:1002].astype(np.float32) + 0.5
            inside = np.minimum(np.minimum(xs - left, right - xs), np.minimum(ys - top, bottom - ys))
            # The classic copy's colours differ a little: matched to the new art's (gain and offset per channel)
            # over a ring round the box, where both show the same drawing.
            ring = (inside < 0) & (inside > -CLEAN_RING)
            for c in range(3):
                a, b = classic[..., c][ring], art[..., c][ring]
                gain = np.std(b) / max(np.std(a), 1e-6)
                classic[..., c] = (classic[..., c] - a.mean()) * gain + b.mean()
            t = np.clip(inside / CLEAN_FEATHER, 0, 1)[..., None]
            out = art.copy()
            out[..., :3] = art[..., :3] * (1 - t * t * (3 - 2 * t)) + classic[..., :3] * (t * t * (3 - 2 * t))
            done[m["id"]] = out
        return done[m["id"]]

    return clean


def _clean_over(over, base, overlay_canvas):
    """render.py's over(m), whose banner hole (MapBannerHole: Durotar, Mulgore, Tirisfal, Teldrassil) would show the
    plain base art (blank parchment where the banner was) through the explored overlay: the hole is filled with the
    (cleaned) base art tinted as the overlay tints it round the hole (overlay / base, averaged over a ring and spread
    across), so the ground under a city's own map is the zone's colour, not a banner-shaped smudge."""
    import numpy as np
    from scipy import ndimage

    done = {}

    def clean(m):
        o = over(m)
        if m["id"] not in done:
            full, b = overlay_canvas(m["art"]), base(m)
            if not (full[..., 3] - o[..., 3] > 0.01).any():  # (no banner hole)
                done[m["id"]] = o
                return o
            removed = np.clip(full[..., 3] - o[..., 3], 0, 1)
            hole = removed > 0.01
            near = ndimage.binary_dilation(hole, iterations=CLEAN_RING) & ~ndimage.binary_dilation(hole, iterations=2)
            ring = near & (full[..., 3] > 0.9)
            out = o.copy()
            fill = np.empty_like(b[..., :3])
            for c in range(3):
                ratio = np.where(ring, full[..., c] / np.maximum(b[..., c], 0.02), 0)
                num = ndimage.gaussian_filter(ratio, CLEAN_RING / 3)
                den = ndimage.gaussian_filter(ring.astype(np.float32), CLEAN_RING / 3)
                # (far from any of the ring, the tint goes to none: the cleaned base art as it is)
                fill[..., c] = np.clip(b[..., c] * np.clip((num + 0.05) / (den + 0.05), 0.3, 3), 0, 1)
            # Over that, the overlay's own texture round the hole, reflected in across its edge (each pixel from as far
            # outside its nearest edge as it is inside), so the ground keeps its grain; it gives way to the tinted
            # base where the reflection lands on more hole or on the overlay's own edge. (Not where the base is the
            # classic copy, CLEAN_BANNERS: that has the drawing's own grain, and the reflection would bring back the
            # banner's shadow from round the hole.)
            valid = ~ndimage.binary_dilation(hole, iterations=3) & (full[..., 3] > 0.9) & (m["id"] not in CLEAN_BANNERS)
            _, (ny, nx) = ndimage.distance_transform_edt(~valid, return_indices=True)
            ys, xs = np.mgrid[0 : hole.shape[0], 0 : hole.shape[1]]
            ry, rx = 2 * ny - ys, 2 * nx - xs
            inside = (ry >= 0) & (ry < hole.shape[0]) & (rx >= 0) & (rx < hole.shape[1])
            ry, rx = np.clip(ry, 0, hole.shape[0] - 1), np.clip(rx, 0, hole.shape[1] - 1)
            w = ndimage.gaussian_filter((valid[ry, rx] & inside).astype(np.float32), 2)[..., None]
            # (only its grain: the tinted base's colour, plus the reflection less its own blur, so what lies by the
            # edge, a mesa's bright top, doesn't come back as a copy)
            mirrored = full[ry, rx, :3]
            grain = mirrored - np.dstack([ndimage.gaussian_filter(mirrored[..., c], 4) for c in range(3)])
            fill = np.clip(fill + grain * w, 0, 1)
            a = np.maximum(full[..., 3], 1e-6)[..., None]
            out[..., :3] = np.where(hole[..., None], (o[..., :3] * o[..., 3:4] + fill * removed[..., None]) / a, o[..., :3])
            out[..., 3] = np.where(hole, full[..., 3], o[..., 3])
            done[m["id"]] = out
        return done[m["id"]]

    return clean


def recipe():
    """A short hash of everything that changes how the tiles are drawn: their cache's folder name."""
    import hashlib

    parts = (OPENMAP_COMMIT, TILE, OCTAVE_PX, FADE_ZOOM, sorted(CLEAN_BANNERS.items()), CLEAN_FEATHER, CLEAN_RING, "holes-reflect", _PLACE, _ALPHA)
    return hashlib.sha1(repr(parts).encode("utf-8")).hexdigest()[:10]


def render_tile(g, px, i, j, path):
    """Tile (i, j) of the px-a-unit grid as a TILE x TILE PNG at `path`."""
    t = STEP / px
    x0, y0 = i * t - 1 / px, j * t - 1 / px  # (its first and last pixel are its neighbours' edge)
    cu, cv = (x0 + TILE / 2 / px) / WORLD_W, (y0 + TILE / 2 / px) / WORLD_H
    g["render"](cu, cv, px / min(TILE / WORLD_W, TILE / WORLD_H), str(path))


# ---------------------------------------------------------------------------------------------------------------
# Placing the tiles
# ---------------------------------------------------------------------------------------------------------------
def continent_units(build, refresh=False):
    """{mapID: (y0, ky, x0, kx)}: world yards of Azeroth's map units on each continent:
    y = y0 - ux * ky (west), x = x0 - uy * kx (north)."""
    out = {}
    for row in wago.read_db2("UiMapAssignment", build, refresh):
        if row["UiMapID"] != str(WORLD):
            continue
        u0, v0, u1, v1 = (float(row[k]) for k in ("UiMin_0", "UiMin_1", "UiMax_0", "UiMax_1"))
        r0, r1, r3, r4 = (float(row[f"Region_{k}"]) for k in (0, 1, 3, 4))
        ky = (r4 - r1) / ((u1 - u0) * WORLD_W)
        kx = (r3 - r0) / ((v1 - v0) * WORLD_H)
        out[int(row["MapID"])] = (r4 + u0 * WORLD_W * ky, ky, r3 + v0 * WORLD_H * kx, kx)
    return out


def tile_yards(units, px, i, j):
    """(north, west, south, east) world yards a tile shows (its own part of the world)."""
    y0, ky, x0, kx = units
    t = STEP / px
    return x0 - j * t * kx, y0 - i * t * ky, x0 - (j + 1) * t * kx, y0 - (i + 1) * t * ky


def tile_range(g, art_map, px):
    """(i0, j0, i1, j1): the tiles covering a continent map's rectangle on Azeroth's map."""
    l, r, t, b = g["rect"](art_map)
    step = STEP / px
    return int(l * WORLD_W // step), int(t * WORLD_H // step), int(r * WORLD_W // step), int(b * WORLD_H // step)


def quarter_alpha(png, qi, qj):
    """The most alpha in quarter (qi, qj) of a tile's own part (each 0 or 1), from its PNG: a child tile there would
    show anything (with a pixel of the neighbours' edge, which filtering reaches)."""
    import numpy as np
    from PIL import Image

    a = np.asarray(Image.open(png).getchannel("A"))
    half = STEP // 2
    y0, x0 = 1 + qj * half, 1 + qi * half
    return a[max(0, y0 - 1) : y0 + half + 1, max(0, x0 - 1) : x0 + half + 1].max() / 255


def fine_zones(g):
    """The zones (with overlays: not the cities, drawn live) whose own art is finer than FINE_FROM px a unit, as
    (left, top, right, bottom) units on Azeroth's map."""
    out = []
    for m in g["zones"]:
        l, r, t, b = m["rect"]
        if g["reveal"].get(m["art"]) and 1 / (r - l) > FINE_FROM:
            out.append((l * WORLD_W, t * WORLD_H, r * WORLD_W, b * WORLD_H))
    return out


# ---------------------------------------------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------------------------------------------
def map_rects(build, refresh=False):
    """{uiMapID: (mapID, top, left, bottom, right)}: the world rectangle each zone or city map's art covers."""
    types = {row["ID"]: row["Type"] for row in wago.read_db2("UiMap", build, refresh)}
    out = {}
    for row in sorted(wago.read_db2("UiMapAssignment", build, refresh), key=lambda r: int(r["OrderIndex"])):
        ui_map = int(row["UiMapID"])
        if ui_map not in out and types.get(row["UiMapID"]) in ZONE_TYPES:
            x0, y0, x1, y1 = (float(row[f"Region_{i}"]) for i in (0, 1, 3, 4))
            out[ui_map] = (int(row["MapID"]), x1, y1, x0, y0)
    return out


def continent_art(build, refresh=False):
    """{mapID: uiMapID} of each continent's own map (the Canvas's continent art when zoomed out)."""
    maps = {row["ID"]: row for row in wago.read_db2("UiMap", build, refresh)}
    out = {}
    for row in wago.read_db2("UiMapAssignment", build, refresh):
        if maps.get(row["UiMapID"], {}).get("Type") == "2":
            out.setdefault(int(row["MapID"]), int(row["UiMapID"]))
    return out


def openmap_cities(repo):
    """{city uiMapID: {"zone", "banner": (zone, x, y, w, h) or None, "cut": bool, "title": bool}} from OpenMap's
    Data/Forever/Banners.lua, the cities on their zone's surface (not UNDERGROUND)."""
    src = (repo / "OpenMap" / "Data" / "Forever" / "Banners.lua").read_text(encoding="utf-8")

    def table(name):
        m = re.search(r"ns\.%s = \{(.*?)\n\}" % name, src, re.S)
        return m.group(1) if m else ""

    banners = {int(c): tuple(map(int, v)) for c, *v in re.findall(r"\[(\d+)\] = \{ (\d+), (\d+), (\d+), (\d+), (\d+) \}", table("MapBanners"))}
    cuts = {int(c) for c in re.findall(r"\[(\d+)\] = true", table("MapCityCuts"))}
    titles = {int(c) for c in re.findall(r"\[(\d+)\] = true", table("MapCityTitles"))}
    zones = {int(c): int(z) for c, z in re.findall(r"\[(\d+)\] = (\d+)", table("MapCityZones"))}
    out = {}
    for city, zone in zones.items():
        out[city] = {"zone": zone, "banner": banners.get(city), "cut": city in cuts, "title": city in titles}
    return out


# ---------------------------------------------------------------------------------------------------------------
# Textures
# ---------------------------------------------------------------------------------------------------------------
def blp_write(path, rgba):
    """A BLP2 of an h x w x 4 uint8 image (sides powers of two) with every mip level: DXT1 when it is opaque, else DXT5.
    Clear pixels take the colour of the nearest seen ones first, so filtering and the smaller mips don't darken edges."""
    import struct

    import numpy as np
    from scipy import ndimage

    sys.path.insert(0, str(OPENMAP_DIR / "tools" / "map-textures"))
    try:
        import blp  # OpenMap's DXT encoder (MIT)
    finally:
        sys.path.pop(0)
    h, w = rgba.shape[:2]
    opaque = rgba[..., 3].min() >= 254
    if opaque:
        rgba = rgba.copy()
        rgba[..., 3] = 255
    else:
        seen = rgba[..., 3] > 0
        if seen.any():
            _, (ny, nx) = ndimage.distance_transform_edt(~seen, return_indices=True)
            rgba = rgba.copy()
            rgba[..., :3] = rgba[ny, nx, :3]
    levels = []
    for m in blp.mips(rgba)[:16]:
        b = blp._blocks(m)
        colour = blp._color(b[..., :3], np.full_like(b[..., 3], 255) if opaque else b[..., 3])
        levels.append(colour.tobytes() if opaque else np.concatenate([blp._alpha(b[..., 3]), colour], 1).tobytes())
    offsets, sizes, at = [], [], blp.HEADER
    for data in levels:
        offsets.append(at)
        sizes.append(len(data))
        at += len(data)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))
    head = b"BLP2" + struct.pack("<I4B2I", 1, 2, 0 if opaque else 8, 0 if opaque else 7, 1, w, h)
    Path(path).write_bytes(head + struct.pack("<16I", *offsets) + struct.pack("<16I", *sizes) + bytes(1024) + b"".join(levels))


def city_piece(build_id, zone, area, refresh=False):
    """(image, (zone, x, y, w, h)) of the overlay piece of a zone's map for an area (WorldMapOverlay), padded to powers
    of two with clear pixels: w x h art px at x, y on the zone's map (1002 x 668). None without one."""
    import io

    from PIL import Image

    arts = {int(r["UiMapID"]): int(r["UiMapArtID"]) for r in wago.read_db2("UiMapXMapArt", build_id, refresh)}
    row = next((r for r in wago.read_db2("WorldMapOverlay", build_id, refresh)
                if int(r["UiMapArtID"]) == arts.get(zone) and int(r["AreaID_0"]) == area), None)
    if not row:
        return None
    tiles = [t for t in wago.read_db2("WorldMapOverlayTile", build_id, refresh) if t["WorldMapOverlayID"] == row["ID"]]
    w, h = int(row["TextureWidth"]), int(row["TextureHeight"])
    pw, ph = (1 << (w - 1).bit_length()), (1 << (h - 1).bit_length())
    img = Image.new("RGBA", (max(pw, 256), max(ph, 256)), (0, 0, 0, 0))
    for t in tiles:
        tile = Image.open(io.BytesIO(wago.casc_file(int(t["FileDataID"])))).convert("RGBA")
        img.paste(tile, (int(t["ColIndex"]) * 256, int(t["RowIndex"]) * 256))
    img = img.crop((0, 0, pw, ph))
    clear = Image.new("RGBA", img.size, (0, 0, 0, 0))
    clear.paste(img.crop((0, 0, w, h)), (0, 0))
    return clear, (zone, int(row["OffsetX"]), int(row["OffsetY"]), pw, ph)


def city_cut(outlines, size=256):
    """size x size RGBA (white, the cut in alpha) over a city map's art: each outline filled, grown and blurred, whole
    inside and fading out over CITY_SOFT past it, and gone by CITY_FRAME from the art's edge."""
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter

    cut = np.zeros((668, 1002), np.float32)
    for poly in outlines:
        mask = Image.new("L", (1002, 668), 0)
        ImageDraw.Draw(mask).polygon(poly, fill=255)
        mask = mask.filter(ImageFilter.MaxFilter(2 * (CITY_SOFT // 3) + 1)).filter(ImageFilter.GaussianBlur(CITY_SOFT / 3))
        cut = np.maximum(cut, np.asarray(mask).astype(np.float32))
    ys, xs = np.mgrid[0:668, 0:1002].astype(np.float32) + 0.5
    edge = np.minimum(np.minimum(xs, 1002 - xs), np.minimum(ys, 668 - ys))
    cut *= np.clip((edge - CITY_FRAME[0]) / (CITY_FRAME[1] - CITY_FRAME[0]), 0, 1)
    alpha = Image.fromarray(cut.astype(np.uint8)).resize((size, size), Image.LANCZOS)
    return Image.merge("RGBA", (Image.new("L", (size, size), 255),) * 3 + (alpha,))


# ---------------------------------------------------------------------------------------------------------------
# Drawing the tiles, side by side
# ---------------------------------------------------------------------------------------------------------------
_worker = {}


def _init_worker(build_id):
    sys.stdout = open(os.devnull, "w")  # (the renderer reports every picture)
    _worker["build"] = build_id


def _job(job):
    """One job of a worker: ("render", px, i, j, png) or ("encode", png, blp)."""
    import numpy as np
    from PIL import Image

    if job[0] == "render":
        if "g" not in _worker:
            _worker["g"] = renderer(_worker["build"])
        _, px, i, j, png = job
        render_tile(_worker["g"], px, i, j, png)
    else:
        _, png, out = job
        blp_write(out, np.asarray(Image.open(png).convert("RGBA")))
    return job


def _run(jobs, build_id, progress, label):
    """Runs jobs on WORKERS processes (each with its own renderer), reporting progress."""
    if not jobs:
        return
    from concurrent.futures import ProcessPoolExecutor, as_completed

    started = time.time()
    with ProcessPoolExecutor(min(WORKERS, len(jobs)), initializer=_init_worker, initargs=(build_id,)) as pool:
        futures = [pool.submit(_job, job) for job in jobs]
        for n, f in enumerate(as_completed(futures)):
            f.result()
            if progress and (n % 25 == 0 or n == len(jobs) - 1):
                progress(f"  {label} {n + 1}/{len(jobs)} ({time.time() - started:.0f}s)")


def _alpha_max(png):
    import numpy as np
    from PIL import Image

    return np.asarray(Image.open(png).getchannel("A")).max() / 255


# ---------------------------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------------------------
def build(build_id, refresh=False, data_file=DATA_FILE, bake_dir=BAKE_DIR, progress=print, only=None):
    """Bakes the tiles and writes Data/MapArt.lua. Returns ({mapID: {level: tiles}}, cities).

    `only`: a list of (level, i, j) tiles to draw again (a preview); the others are kept from the cache."""
    g = renderer(build_id, refresh)
    repo = OPENMAP_DIR
    work = CACHE / "bake" / build_id / recipe()
    work.mkdir(parents=True, exist_ok=True)
    rects = map_rects(build_id, refresh)
    units = continent_units(build_id, refresh)
    art = continent_art(build_id, refresh)
    names = {int(row["ID"]): row["Name_lang"] for row in wago.read_db2("UiMap", build_id, refresh)}
    for level, i, j in only or ():
        (work / f"{level}_{i}_{j}.png").unlink(missing_ok=True)

    def png(level, i, j):
        return work / f"{level}_{i}_{j}.png"

    # Level by level: the far tiles over each continent's map, then each tile's quarters that show anything, one size
    # finer (the fine ones only over the small zones). A tile with nothing in it is left out.
    fine = fine_zones(g)
    plan = {}  # mapID: {level: [(i, j)]}
    for map_id, _, _ in tiles.world_maps(build_id, refresh):
        if map_id in art and map_id in units:
            plan[map_id] = {}
    for n, (level, px) in enumerate(LEVELS):
        wanted = {}
        for map_id in plan:
            if n == 0:
                i0, j0, i1, j1 = tile_range(g, art[map_id], px)
                wanted[map_id] = [(i, j) for j in range(j0, j1 + 1) for i in range(i0, i1 + 1)]
                continue
            # (a tile is split into all its quarters that show anything, or none: the Canvas shows a tile or its
            # children, so the children must cover all of it)
            parent, step = LEVELS[n - 1][0], STEP / LEVELS[n - 1][1]
            out = []
            for pi, pj in plan[map_id][parent]:
                if level == "fine" and not any(
                    l < (pi + 1) * step and r > pi * step and t < (pj + 1) * step and b > pj * step for l, t, r, b in fine
                ):
                    continue
                for qj in (0, 1):
                    for qi in (0, 1):
                        if quarter_alpha(png(parent, pi, pj), qi, qj) > EMPTY:
                            out.append((2 * pi + qi, 2 * pj + qj))
            wanted[map_id] = out
        jobs = [("render", px, i, j, png(level, i, j)) for keys in wanted.values() for i, j in keys if not png(level, i, j).exists()]
        _run(jobs, build_id, progress, f"{level} tiles")
        for map_id, keys in wanted.items():
            plan[map_id][level] = [(i, j) for i, j in keys if _alpha_max(png(level, i, j)) > EMPTY]
            assert all(0 <= j < 256 for _, j in plan[map_id][level])

    bake_dir.mkdir(parents=True, exist_ok=True)
    files, jobs = set(), []
    for p in plan.values():
        for level, keys in p.items():
            for i, j in keys:
                src, out = png(level, i, j), bake_dir / f"{level}_{i}_{j}.blp"
                files.add(out.name)
                if not out.exists() or out.stat().st_mtime < src.stat().st_mtime:
                    jobs.append(("encode", src, out))
    _run(jobs, build_id, progress, "textures")

    # The live sea's textures (OpenMap's), and the cities on their zones' surface: their maps' cuts (or a round
    # feather) and their zones' banners for them.
    tex = repo / "OpenMap" / "Media" / "Textures" / "Forever"
    copies = {
        "round.tga": tex / "MapFeatherRound.tga",
        "feather_wide.tga": tex / "MapFeatherWide.tga",
        "sea_dark.tga": tex / "MapSeaDark.tga",
        "sea_light.tga": tex / "MapSeaLight.tga",
        "sea_out.tga": tex / "MapSeaFieldOut.tga",
        f"sea_{WORLD}.tga": tex / "MapSeaField" / f"{WORLD}.tga",
        "hatch.tga": tex / "MapHatch.tga",
    }
    for map_id in plan:
        copies[f"sea_{art[map_id]}.tga"] = tex / "MapSeaField" / f"{art[map_id]}.tga"
        copies[f"coast_{art[map_id]}.tga"] = tex / "MapCoast" / f"{art[map_id]}.tga"
    cities = {c: v for c, v in openmap_cities(repo).items() if c in rects and c not in UNDERGROUND}
    underground = {c: v for c, v in openmap_cities(repo).items() if c in UNDERGROUND and v["banner"]}
    for city, v in list(cities.items()) + list(underground.items()):
        if v["cut"] and city in cities:
            copies[f"cut_{city}.tga"] = tex / "MapCityMask" / f"{city}.tga"
        if v["banner"] and city not in CITY_PIECES:
            copies[f"banner_{city}.tga"] = tex / "MapBanner" / f"{city}.tga"
    for city, area in CITY_PIECES.items():
        piece = city in cities and city_piece(build_id, cities[city]["zone"], area, refresh)
        if piece:
            img, cities[city]["banner"] = piece
            img.save(bake_dir / f"banner_{city}.tga")
            files.add(f"banner_{city}.tga")
    for name, src in copies.items():
        shutil.copyfile(src, bake_dir / name)
        files.add(name)
    for city, outlines in CITY_CUTS.items():
        if city in cities:
            city_cut(outlines).save(bake_dir / f"cut_{city}.tga")
            files.add(f"cut_{city}.tga")
            cities[city]["cut"] = True
    for old in bake_dir.iterdir():
        if old.name not in files:
            old.unlink()

    # The sea's sizes: its paper tiles at the Eastern Kingdoms' art's scale on every continent (Stitch.lua's), the
    # hatching at each continent's own; in yards, and the size on screen (UI units) past which each halves.
    def art_px(map_id):  # Azeroth's map units a px of a continent's art
        l, r, _, _ = g["rect"](map_id)
        return (r - l) * WORLD_W / 1002

    ek = art_px(1415)
    lines = [
        f"-- Generated by `warroom mapart` from build {build_id} with OpenMap {OPENMAP_COMMIT[:10]} (MIT). Do not edit.",
        "-- The detailed painted map, baked into tiles on Azeroth's map (uiMap 947) by OpenMap's renderer:",
        "-- levels = { { name, px a unit }, ... } coarse to fine, each twice the last",
        "-- continents[mapID] = { art = uiMap of the continent's own map (drawn when zoomed out),",
        "--   units = { y0, ky, x0, kx }: a point ux, uy units across and down Azeroth's map is world y = y0 - ux * ky,",
        "--   x = x0 - uy * kx,",
        "--   sea = { tile = yards of a sea paper tile, tileMax = UI units on screen past which it halves, hatch = { w, h }",
        "--     yards of a hatching tile, hatchMax = the same for it },",
        "--   <level> = { i * 256 + j, ... }: Media/Bake/<level>_<i>_<j>.blp }",
        "--   A tile is size px square; its own part of the world is units (i to i + 1) * step / px across and",
        "--   (j to j + 1) * step / px down, its outermost pixel on each side its neighbours'. Its four quarters are the",
        "--   next level's tiles (2i, 2j) to (2i + 1, 2j + 1), where that level has them.",
        "-- sea = { color, hatchAlpha, reach }: under the tiles, drawn live (Media/Bake/sea_*, hatch, coast_*)",
        "-- cities[uiMapID] = { zone = uiMapID, cut = true (Media/Bake/cut_<city> cuts its map down to the city; else",
        "--   Media/Bake/round), banner = { zone, x, y, w, h }: Media/Bake/banner_<city>, w x h art px at x, y on its",
        "--   zone's map, title = true when the city's map has its own banner (Orgrimmar's and Thunder Bluff's",
        "--   \"banners\" are their zones' whole drawings of them, which the tiles leave out) }",
        "-- underground[uiMapID]: cities under their zone's surface, only their banners drawn.",
        "local _, ns = ...",
        "ns.MapArt = {",
        f'\tbuild = "{build_id}",',
        f"\tsize = {TILE}, step = {STEP},",
        "\tlevels = { " + ", ".join(f'{{ "{name}", {px} }}' for name, px in LEVELS) + " },",
        "\tsea = { color = { %g, %g, %g }, hatchAlpha = %g, reach = %g }," % (*SEA_COLOR, HATCH_ALPHA, SEA_REACH),
        "\tcontinents = {",
    ]
    for map_id, p in sorted(plan.items()):
        y0, ky, x0, kx = units[map_id]
        k = art_px(art[map_id])
        lines.append(f"\t\t[{map_id}] = {{ -- {names.get(art[map_id], '?')}")
        lines.append(f"\t\t\tart = {art[map_id]}, units = {{ {y0:.4f}, {ky:.6f}, {x0:.4f}, {kx:.6f} }},")
        lines.append(
            "\t\t\tsea = { tile = %.1f, tileMax = %.1f, hatch = { %.1f, %.1f }, hatchMax = %.1f },"
            % (SEA_TILE * ek * ky, SEA_TILE * ek * SEA_OCTAVE, HATCH_TILE[0] * k * ky, HATCH_TILE[1] * k * kx, HATCH_TILE[0] * k * HATCH_OCTAVE)
        )
        for level, _ in LEVELS:
            keys = [str(i * 256 + j) for i, j in p[level]]
            lines.append(f"\t\t\t{level} = {{")
            for n in range(0, len(keys), 16):
                lines.append("\t\t\t\t" + ", ".join(keys[n : n + 16]) + ",")
            lines.append("\t\t\t},")
        lines.append("\t\t},")
    lines.append("\t},")

    def city_lines(table, entries):
        lines.append(f"\t{table} = {{")
        for city, v in sorted(entries.items()):
            parts = [f"zone = {v['zone']}"]
            if v["cut"] and table == "cities":
                parts.append("cut = true")
            if v["banner"]:
                parts.append("banner = { " + ", ".join(str(x) for x in v["banner"]) + " }")
            if v["title"]:
                parts.append("title = true")
            lines.append(f"\t\t[{city}] = {{ {', '.join(parts)} }}, -- {names.get(city, '?')}")
        lines.append("\t},")

    city_lines("cities", cities)
    city_lines("underground", underground)
    lines.append("}")
    data_file.parent.mkdir(parents=True, exist_ok=True)
    data_file.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return {m: {level: len(keys) for level, keys in p.items()} for m, p in plan.items()}, cities
