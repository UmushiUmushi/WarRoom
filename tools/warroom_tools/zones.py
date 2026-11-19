"""Which zone each patch of ground belongs to, and each zone's outline: addons/WarRoom/Data/Zones.lua.

The game's own borders. The terrain names an area for every chunk (33 1/3 yards: areas.py), and the game walks that
area up to its zone (AreaTable parents) to name where the player is; its world map then shows that zone's map, but
only where the player stands inside the map's rectangle (UiMapAssignment), else the continent's. So:

  - a chunk is the zone its area resolves to, if it lies in that zone's map or is joined to the zone's ground there
    (Forever's terrain tags some unused ground far from its zone with its area: a strip of Dun Morogh's western
    mountains is Westfall's, the game's map doesn't show it as Westfall's);
  - land the game leaves to no zone (unused ground of area 0, and those strays) goes to the zone whose ground grows
    to it first over land, so no land between zones is left out (cities claim none); ground the game names as a place of no zone's (Gilneas, GM Island) stays out, but a small
    one inside a zone's land (the Gates of Ahn'Qiraj, in Silithus) is that zone's;
  - water close to the coast goes with the land nearest it (the painted coasts stray from the terrain's), open
    water to no zone.

The map modules ask the grid which zone a point is in, and draw a zone's outline round the same chunks (its land,
lakes included), so what is outlined, hovered and clicked is what the game says. The continent paintings draw
their zone borders by hand, up to a few hundred yards off the game's in places; the game wins. An island the game
puts on Azeroth's map (Zephras Isle), whose terrain is ground all over, is the island found in its own painting
(worldart.py). The rings get their corners rounded and are thinned to a few yards.

Each zone also gets the glow the world map shows over it under the pointer (Media/Glow), in the style of the game's
own highlight textures but the shape of its land as above, and the veil the map lays round it once the view is on
it (Media/Veil): a soft dimming of everything outside the zone, its cities and lakes and near water included.

And each piece of a zone's map the player explores (WorldMapOverlay: the game shows a zone's map piece by piece as
it is explored) gets the dark the map lays over it until it is (Media/Fog). Its shape is the game's own drawing of
the piece (its tiles' alpha, as Veilmap darkens them on the game's map), laid where the zone's map lies, so it
follows the mountains and coasts the painted map does; a city's ground is under its zone's piece of it. The pieces
overlap, so they are composed together, a continent at a time, as one shape: where several draw the same ground
they share it out (the one drawing it most deeply in has the most of it, handing over softly), and each piece's
dark is baked so that any of them laid together darken exactly as one sheet would: all of a zone unexplored is one
even dark, with no darker bands where pieces overlap, and an explored piece leaves a soft hole.
"""

import numpy as np

from . import areas, tiles, wago

DATA_FILE = tiles.ROOT / "addons" / "WarRoom" / "Data" / "Zones.lua"
GLOW_DIR = tiles.ROOT / "addons" / "WarRoom" / "Media" / "Glow"
# The glow over a zone under the pointer, styled on the game's own (its UiMapArt highlight textures: the zone's
# shape in a dim olive on black, added onto the map, its edge feathered over a few hundredths of the zone's size),
# but cut to the game's borders.
GLOW_COLOR = (30, 48, 0)
GLOW_SOFT = 0.02  # the edge's blur (sigma) as a share of the zone's larger side ...
GLOW_SOFT_MIN = 1.5  # ... and at least this many chunks (50 yards)
GLOW_MAX = 128  # pixels on a glow's longer side (the game's are 128)
VEIL_DIR = tiles.ROOT / "addons" / "WarRoom" / "Media" / "Veil"
# The veil round the zone the view is on: white, clear over the zone and opaque outside (the map tints and fades
# it), its edge pushed out a little (so the zone's own edge stays clear) and feathered.
VEIL_SOFT = 0.015  # the edge's blur (sigma) as a share of the zone's larger side ...
VEIL_SOFT_MIN = 2  # ... and at least this many chunks
VEIL_MAX = 256  # pixels on a veil's longer side
FOG_DIR = tiles.ROOT / "addons" / "WarRoom" / "Media" / "Fog"
# The dark over the pieces not yet explored: white BLPs, the dark's own alpha (the map tints them near black).
FOG_DARK = 0.55  # how dark unexplored ground is (the alpha over it, however many pieces draw it)
FOG_YARDS = 5.0  # yards to a texel of the grid a continent's pieces are composed on
FOG_SPLIT = 8.0  # texels: how far in a piece's drawing reaches when overlapping pieces share out ground (blur sigma)
FOG_SHARP = 6.0  # how sharply they hand over (power)
FOG_FAINT = 0.1  # a drawing's alpha up to this is none (some tiles carry a faint haze over their whole square)
FOG_FRAME = 16  # art pixels: a drawing fades out over this much before its zone map's frame (the art cuts it straight)
FOG_GAP = 5  # texels: hairline gaps between pieces' drawings narrower than this are filled (grey closing)
FOG_MAX = 256  # texels on a piece's texture's longer side (larger ones are halved)
ART_SIZE = (1002, 668)  # a zone map's art, pixels
CHUNKS = areas.CHUNKS
SIZE = 64 * CHUNKS  # chunks per side of a continent
CHUNK_YARDS = tiles.TILE_YARDS / CHUNKS
EDGE = tiles.TILE_YARDS * 32  # world x (and y) of a continent's north (and west) edge
# The capital cities: maps of their own, inside a zone (in Forever's data their parent is the continent).
CITIES = {1453, 1454, 1455, 1456, 1457, 1458}
SMOOTH = 2  # rounds of corner cutting on the outlines
TOLERANCE = 0.12  # chunks an outline may stray when thinned (about 4 yards)
MIN_AREA = 3  # chunks: smaller islands and specks of a zone get no outline
FILL_REACH = 400  # chunks: how far a zone's ground may grow over land no zone holds
POCKET = 600  # chunks: a place of no zone's this small, inside one zone's land, is that zone's
SEA_REACH = 6  # chunks (200 yards) off the coast that still go with the land
# Zephras Isle's outline, traced round its painting at PAINT_SCALE times its pixels.
PAINT_SCALE = 4
PAINT_SMOOTH = 3
PAINT_TOLERANCE = 0.6  # traced pixels an outline may stray when thinned (about 5 yards)
PAINT_MIN_AREA = 16  # painting pixels


def grids(build, refresh=False):
    """{mapID: (zone grid, dry grid, elsewhere grid, area grid)} for every map with terrain areas cached or fetched:
    SIZE x SIZE arrays, row = chunk row from the north (ty * 16 + iy), column = chunk column from the west; zone = the
    uiMapID its area resolves to (0: none), dry = not sea, elsewhere = its area is a place of no zone's (Gilneas, GM
    Island...), area = the terrain's own area."""
    zone_of = areas.zone_of_area(build, refresh)
    out = {}
    for map_id, directory, _ in tiles.world_maps(build, refresh):
        found = tiles.tile_files(directory, build, refresh)
        info = areas.tile_areas(directory, list(found), build, refresh)
        if not info:
            continue
        zone = np.zeros((SIZE, SIZE), np.int32)
        dry = np.zeros((SIZE, SIZE), bool)
        elsewhere = np.zeros((SIZE, SIZE), bool)
        area = np.zeros((SIZE, SIZE), np.int32)
        for (tx, ty), (chunk_area, below) in info.items():
            rows, cols = slice(ty * CHUNKS, (ty + 1) * CHUNKS), slice(tx * CHUNKS, (tx + 1) * CHUNKS)
            zone[rows, cols] = np.array([zone_of.get(a, 0) for a in chunk_area]).reshape(CHUNKS, CHUNKS)
            dry[rows, cols] = np.array(below).reshape(CHUNKS, CHUNKS) < areas.SEA_POINTS
            elsewhere[rows, cols] = np.array([a != 0 and a not in zone_of for a in chunk_area]).reshape(CHUNKS, CHUNKS)
            area[rows, cols] = np.array(chunk_area).reshape(CHUNKS, CHUNKS)
        if zone.any():
            out[map_id] = (zone, dry, elsewhere, area)
    return out


def runs(row):
    """A grid row as [(first column, value), ...], each run lasting to the next's first column; the row starts at 0."""
    change = np.nonzero(np.diff(row))[0] + 1
    starts = np.concatenate([[0], change])
    return [(int(c), int(row[c])) for c in starts]


def trace(mask):
    """The outlines of a boolean grid as closed rings of chunk corners (x = column, y = row), the inside always on
    the right going round (so on the left for a hole's)."""
    out = {}
    m = np.pad(mask, 1)
    inner = m[:-2, 1:-1] & m[2:, 1:-1] & m[1:-1, :-2] & m[1:-1, 2:]
    rr, cc = np.nonzero(mask & ~inner)  # (cells with a side on the edge)
    for r, c in zip(rr.tolist(), cc.tolist()):
        R, C = r + 1, c + 1
        if not m[R - 1, C]:
            out.setdefault((c, r), []).append((c + 1, r))
        if not m[R, C + 1]:
            out.setdefault((c + 1, r), []).append((c + 1, r + 1))
        if not m[R + 1, C]:
            out.setdefault((c + 1, r + 1), []).append((c, r + 1))
        if not m[R, C - 1]:
            out.setdefault((c, r + 1), []).append((c, r))
    rings = []
    while out:
        start = next(iter(out))
        ring, v, d = [start], start, None
        while True:
            nexts = out.get(v)
            if not nexts:
                break
            if len(nexts) > 1 and d:  # a corner two of its cells share: turn right, keeping them apart
                right = (-d[1], d[0])
                pick = next((n for n in nexts if (n[0] - v[0], n[1] - v[1]) == right), nexts[0])
            else:
                pick = nexts[0]
            nexts.remove(pick)
            if not nexts:
                del out[v]
            d = (pick[0] - v[0], pick[1] - v[1])
            v = pick
            if v == start:
                break
            ring.append(v)
        if len(ring) >= 4:
            rings.append(ring)
    return rings


def area(ring):
    """Signed area (shoelace) of a ring."""
    a = 0.0
    for (x0, y0), (x1, y1) in zip(ring, ring[1:] + ring[:1]):
        a += x0 * y1 - x1 * y0
    return a / 2


def chaikin(ring, rounds=SMOOTH):
    """Corner cutting on a closed ring: each round puts two points a quarter of the way in from each end of every
    side, rounding the chunk steps."""
    pts = [tuple(map(float, p)) for p in ring]
    for _ in range(rounds):
        nxt = []
        for (x0, y0), (x1, y1) in zip(pts, pts[1:] + pts[:1]):
            nxt.append((0.75 * x0 + 0.25 * x1, 0.75 * y0 + 0.25 * y1))
            nxt.append((0.25 * x0 + 0.75 * x1, 0.25 * y0 + 0.75 * y1))
        pts = nxt
    return pts


def simplify(pts, tolerance=TOLERANCE):
    """Douglas-Peucker on a closed ring (split at its first point and the point farthest from it)."""
    if len(pts) < 4:
        return pts
    far = max(range(len(pts)), key=lambda i: (pts[i][0] - pts[0][0]) ** 2 + (pts[i][1] - pts[0][1]) ** 2)

    def dp(seq):
        keep = [True] * len(seq)
        stack = [(0, len(seq) - 1)]
        while stack:
            a, b = stack.pop()
            if b <= a + 1:
                continue
            (ax, ay), (bx, by) = seq[a], seq[b]
            dx, dy = bx - ax, by - ay
            length = (dx * dx + dy * dy) ** 0.5 or 1e-9
            best, at = -1.0, a
            for i in range(a + 1, b):
                px, py = seq[i]
                dist = abs(dy * (px - ax) - dx * (py - ay)) / length
                if dist > best:
                    best, at = dist, i
            if best > tolerance:
                stack += [(a, at), (at, b)]
            else:
                for i in range(a + 1, b):
                    keep[i] = False
        return [p for p, k in zip(seq, keep) if k]

    first = dp(pts[: far + 1])
    second = dp(pts[far:] + pts[:1])
    return first[:-1] + second[:-1]


def to_world(ring):
    """Chunk corners (column, row) to world (x, y) yards, as a flat list."""
    flat = []
    for c, r in ring:
        flat += [round(tiles.TILE_YARDS * 32 - r * CHUNK_YARDS, 1), round(tiles.TILE_YARDS * 32 - c * CHUNK_YARDS, 1)]
    return flat


def outlines(zone, land, ui_map):
    """A zone's outline rings in world yards (round its land, lakes included)."""
    rings = []
    for ring in trace((zone == ui_map) & land):
        if abs(area(ring)) >= MIN_AREA:
            rings.append(to_world(simplify(chaikin(ring))))
    return rings


def chunk_middles():
    """(x, y) world yards of every chunk's middle, as SIZE x SIZE arrays."""
    rows, cols = np.mgrid[0:SIZE, 0:SIZE]
    return EDGE - (rows + 0.5) * CHUNK_YARDS, EDGE - (cols + 0.5) * CHUNK_YARDS


def game_zones(zone, dry, elsewhere, rects):
    """(zone, land): the terrain's zone grid as the game's world map has it (see the module's notes), and the land
    (dry ground, lakes filled). `elsewhere`: the chunks the game names as places of no zone's, left out."""
    from scipy import ndimage

    land = ndimage.binary_fill_holes(dry)
    x, y = chunk_middles()
    ids = sorted(int(v) for v in np.unique(zone) if v)
    # each id's map rectangle, looked up by its index (0: none, nowhere)
    bounds = np.full((len(ids) + 1, 4), np.nan)
    for i, v in enumerate(ids, 1):
        if v in rects:
            bounds[i] = rects[v]
    index = {v: i for i, v in enumerate(ids, 1)}
    coded = np.vectorize(lambda v: index.get(int(v), 0))(zone) if ids else np.zeros_like(zone)

    def inside(code):
        north, west, south, east = (bounds[code, k] for k in range(4))
        return (x <= north) & (x >= south) & (y <= west) & (y >= east)  # (nan: never)

    # the game's rule, an area's zone is where its map is. Past its map's edge, a piece of its ground stays its only
    # where the zone's own ground is most of what the piece borders (Silithus's dunes south of its map); a stray
    # strip along other zones (Westfall's up the coast to Dun Morogh) is theirs to share, not its again
    grows = np.array([0] + [0 if v in CITIES else 1 for v in ids], bool)
    barred = np.zeros_like(coded)  # (the zone a freed piece was: it can't grow back in)
    outside = (coded != 0) & ~inside(coded)
    for i in range(1, len(ids) + 1):
        pieces, n = ndimage.label(outside & (coded == i))
        for where in ndimage.find_objects(pieces):
            box = tuple(slice(max(s.start - 1, 0), s.stop + 1) for s in where)
            piece = (pieces[box] != 0) & (coded[box] == i) & outside[box]
            rim = ndimage.binary_dilation(piece) & ~piece & land[box]
            near = coded[box][rim]
            near = near[(near != 0) & ~outside[box][rim]]
            values, counts = np.unique(near, return_counts=True)
            if values.size and values[counts.argmax()] != i:
                coded[box][piece] = 0
                barred[box][piece] = i

    # land no zone holds: grown over from its neighbours, all at once (cities claim none)
    open_land = land & ~elsewhere
    for _ in range(FILL_REACH):
        empty = open_land & (coded == 0)
        if not empty.any():
            break
        grown = coded.copy()
        for axis, step in ((0, 1), (0, -1), (1, 1), (1, -1)):
            near = np.roll(coded, step, axis)
            if axis == 0:  # (no wrapping round the grid's edge)
                near[0 if step == 1 else -1, :] = 0
            else:
                near[:, 0 if step == 1 else -1] = 0
            take = empty & (grown == 0) & (near != 0) & grows[near] & (near != barred)
            grown[take] = near[take]
        if np.array_equal(grown, coded):
            break
        coded = grown

    # a small place of no zone's inside one zone's land (the Gates of Ahn'Qiraj in Silithus) is that zone's
    pockets, n = ndimage.label(elsewhere & land)
    for i in range(1, n + 1):
        pocket = pockets == i
        if pocket.sum() > POCKET:
            continue
        rim = coded[ndimage.binary_dilation(pocket) & ~pocket & land]
        values, counts = np.unique(rim[rim != 0], return_counts=True)
        if values.size and counts.max() >= 0.8 * rim.size:
            coded[pocket] = values[counts.argmax()]

    # water: near the coast, its own zone else the nearest land's; open water, none
    held = land & (coded != 0)
    dist, (nr, nc) = ndimage.distance_transform_edt(~held, return_indices=True)
    wet = ~land & ~elsewhere
    free = wet & (coded == 0)
    coded[free] = coded[nr, nc][free]
    coded[~land & (dist > SEA_REACH)] = 0
    lookup = np.array([0] + ids, np.int32)
    return lookup[coded], land


def art_chunks(rect, width, height):
    """The chunk (row, column) arrays under each pixel of a width x height picture of a map's rectangle
    (north, west, south, east), clipped to the grid."""
    north, west, south, east = rect
    jj, ii = np.mgrid[0:height, 0:width]
    x = north - (jj + 0.5) / height * (north - south)
    y = west - (ii + 0.5) / width * (west - east)
    r = np.clip(((EDGE - x) / CHUNK_YARDS).astype(int), 0, SIZE - 1)
    c = np.clip(((EDGE - y) / CHUNK_YARDS).astype(int), 0, SIZE - 1)
    return r, c


def painted_art(art_map):
    """OpenMap's copy of a continent's map cleaned of its lettering (a 668 x 1002 RGB image), or None."""
    from PIL import Image

    from . import mapart

    found = sorted((mapart.openmap_checkout() / "art" / "edits" / "edited").glob(f"{art_map} *.png"))
    return Image.open(found[0]).convert("RGB") if found else None


def mask_rings(mask, rect):
    """The outline rings of a pixel mask over a world rectangle (north, west, south, east), in world yards: corners
    rounded, thinned to PAINT_TOLERANCE pixels."""
    north, west, south, east = rect
    h, w = mask.shape
    rings = []
    for ring in trace(mask):
        if abs(area(ring)) < PAINT_MIN_AREA * PAINT_SCALE * PAINT_SCALE:
            continue
        flat = []
        for px, py in simplify(chaikin(ring, PAINT_SMOOTH), PAINT_TOLERANCE):
            flat += [round(north - py / h * (north - south), 1), round(west - px / w * (west - east), 1)]
        rings.append(flat)
    return rings


def chunk_pixels(rect, width, height):
    """(row, column, inside) arrays over the chunk grid: the pixel of a width x height picture of a map's rectangle
    (north, west, south, east) under each chunk's middle, and whether it is on the picture."""
    north, west, south, east = rect
    rows, cols = np.mgrid[0:SIZE, 0:SIZE]
    x = EDGE - (rows + 0.5) * CHUNK_YARDS
    y = EDGE - (cols + 0.5) * CHUNK_YARDS
    py = np.floor((north - x) / (north - south) * height).astype(int)
    px = np.floor((west - y) / (west - east) * width).astype(int)
    inside = (py >= 0) & (py < height) & (px >= 0) & (px < width)
    return np.clip(py, 0, height - 1), np.clip(px, 0, width - 1), inside


def island_zone(zone, dry, ui_map, rect, build, refresh=False):
    """(zone, rings) of an island map: its zone's ground is the island found in its own painting (its terrain is
    ground all over, clouds and all), the rest no zone's; rings its outline in world yards (None without a
    painting)."""
    from PIL import Image

    from . import worldart

    art = worldart.game_art(ui_map, build, refresh)
    if art is None:
        return zone, None
    island = worldart.island_alpha(art) > 0.5
    w, h = art.size
    py, px, inside = chunk_pixels(rect, w, h)
    on = inside & island[py, px]
    zone = np.where((zone == ui_map) & ~on, 0, zone)
    k = PAINT_SCALE
    big = np.asarray(Image.fromarray(island).resize((w * k, h * k), Image.NEAREST))
    return zone, mask_rings(big, rect)


def continent_maps(build, refresh=False):
    """{mapID: uiMapID} of each continent's own map (its painting): the widest continent map on it."""
    types = {row["ID"]: row["Type"] for row in wago.read_db2("UiMap", build, refresh)}
    out, widest = {}, {}
    for row in wago.read_db2("UiMapAssignment", build, refresh):
        if types.get(row["UiMapID"]) == "2":
            map_id, width = int(row["MapID"]), float(row["Region_4"]) - float(row["Region_1"])
            if width > widest.get(map_id, 0):
                out[map_id], widest[map_id] = int(row["UiMapID"]), width
    return out


def map_rects(map_id, build, refresh=False):
    """{uiMapID: (north, west, south, east)} world rectangles of the maps on a continent."""
    out = {}
    for row in wago.read_db2("UiMapAssignment", build, refresh):
        if int(row["MapID"]) == map_id:
            x0, y0, x1, y1 = (float(row[f"Region_{i}"]) for i in (0, 1, 3, 4))
            out.setdefault(int(row["UiMapID"]), (x1, y1, x0, y0))
    return out


def city_zones(zone, rects):
    """{city: the zone it lies in}: of the zones around its ground, the one whose map holds the city's middle (the
    terrain gives some of Stormwind's surroundings to Westfall, but its map is in Elwynn's), else the one most of
    the ground around it belongs to."""
    from scipy import ndimage

    out = {}
    for city in CITIES:
        mask = zone == city
        if not mask.any() or city not in rects:
            continue
        ring = ndimage.binary_dilation(mask, iterations=3) & ~mask
        around = zone[ring]
        around = around[(around != 0) & ~np.isin(around, list(CITIES))]
        if not around.size:
            continue
        values, counts = np.unique(around, return_counts=True)
        north, west, south, east = rects[city]
        x, y = (north + south) / 2, (west + east) / 2

        def holds(z):
            r = rects.get(int(z))
            return r is not None and r[2] <= x <= r[0] and r[3] <= y <= r[1]

        ranked = sorted(zip(values.tolist(), counts.tolist()), key=lambda vc: (holds(vc[0]), vc[1]), reverse=True)
        out[city] = int(ranked[0][0])
    return out


def _soft(mask, share, least, longest):
    """(field, rect) of a mask blurred at the edge (sigma `share` of its larger side, at least `least` chunks) and
    resized to at most `longest` pixels a side (powers of two), over its box and the blur's reach; rect = (north,
    west, south, east) in world yards; None for an empty mask."""
    from PIL import Image
    from scipy import ndimage

    rows, cols = np.nonzero(mask)
    if not rows.size:
        return None
    soft = max(least, share * max(np.ptp(rows) + 1, np.ptp(cols) + 1))
    pad = int(np.ceil(soft * 3))
    r0, r1 = max(rows.min() - pad, 0), min(rows.max() + 1 + pad, SIZE)
    c0, c1 = max(cols.min() - pad, 0), min(cols.max() + 1 + pad, SIZE)
    field = ndimage.gaussian_filter(mask[r0:r1, c0:c1].astype(np.float32), soft)

    def side(n):
        return int(min(longest, max(16, 2 ** int(np.ceil(np.log2(n * 2))))))

    w, h = side(c1 - c0), side(r1 - r0)
    field = np.clip(np.asarray(Image.fromarray(field).resize((w, h), Image.BILINEAR)), 0, 1)
    rect = (round(EDGE - r0 * CHUNK_YARDS, 1), round(EDGE - c0 * CHUNK_YARDS, 1),
            round(EDGE - r1 * CHUNK_YARDS, 1), round(EDGE - c1 * CHUNK_YARDS, 1))
    return field, rect


def glow(zone, land, ui_map):
    """(image, (north, west, south, east)) of a zone's glow: its land blurred at the edge, in GLOW_COLOR on black,
    over its land's box and the blur's reach, both sides a power of two pixels; None without land."""
    from PIL import Image

    made = _soft((zone == ui_map) & land, GLOW_SOFT, GLOW_SOFT_MIN, GLOW_MAX)
    if not made:
        return None
    field, rect = made
    rgb = (field[..., None] * np.array(GLOW_COLOR, np.float32)).round().astype(np.uint8)
    return Image.fromarray(rgb, "RGB"), rect


def veil(zone, ui_map, inside=()):
    """(image, (north, west, south, east)) of the veil round a map: white, its alpha 0 over the map's chunks (with
    the maps `inside` it, its cities, and its lakes) pushed out a little, 255 outside, feathered between; the
    texture's edge is all 255, so plain dimming carries on round it. None without ground."""
    from PIL import Image
    from scipy import ndimage

    mask = np.isin(zone, [ui_map, *inside])
    rows, cols = np.nonzero(mask)
    if not rows.size:
        return None
    soft = max(VEIL_SOFT_MIN, VEIL_SOFT * max(np.ptp(rows) + 1, np.ptp(cols) + 1))
    grown = ndimage.binary_dilation(mask, iterations=max(1, int(round(soft))))
    field, rect = _soft(ndimage.binary_fill_holes(grown), VEIL_SOFT, VEIL_SOFT_MIN, VEIL_MAX)
    alpha = ((1 - field) * 255).round().astype(np.uint8)
    alpha[0, :] = alpha[-1, :] = alpha[:, 0] = alpha[:, -1] = 255
    rgba = np.dstack([np.full_like(alpha, 255)] * 3 + [alpha])
    return Image.fromarray(rgba, "RGBA"), rect


def map_pieces(build, refresh=False):
    """{uiMapID: [(overlay row, "w:h:x:y", {areaID, ...}), ...]}: the pieces of each map's art the player explores
    (WorldMapOverlay; keyed as C_MapExplorationInfo.GetExploredMapTextures gives them) and the areas each is for,
    in the table's order."""
    arts = {}
    for row in wago.read_db2("UiMapXMapArt", build, refresh):
        arts.setdefault(int(row["UiMapArtID"]), []).append(int(row["UiMapID"]))
    out = {}
    for row in wago.read_db2("WorldMapOverlay", build, refresh):
        found = {int(row[f"AreaID_{i}"]) for i in range(4)} - {0}
        if not found:
            continue
        key = f"{row['TextureWidth']}:{row['TextureHeight']}:{row['OffsetX']}:{row['OffsetY']}"
        for ui_map in arts.get(int(row["UiMapArtID"]), ()):
            out.setdefault(ui_map, []).append((row, key, found))
    return out


def _game_file(fid):
    """A game file's bytes: from the caches (OpenMap's textures, ours), else the install's own files, else wago.tools."""
    for path in (wago.CACHE.parent / "openmap-tex" / f"{fid}.blp", wago.CASC_CACHE / str(fid)):
        if path.exists() and path.stat().st_size:
            return path.read_bytes()
    try:
        if "casc" not in _game_file.__dict__:
            import sys

            from . import client, mapart

            sys.path.insert(0, str(mapart.OPENMAP_DIR / "tools" / "casc"))
            import casc

            _game_file.casc = casc.Casc(str(client.find_install(None)), client.FOREVER_PRODUCT)
        data = _game_file.casc.read(fid)
        if data:
            path = wago.CASC_CACHE / str(fid)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            return data
    except Exception:
        pass
    return wago.casc_file(fid)


def piece_alpha(overlay, tiles, size=256):
    """A piece's drawing as alpha (h x w, 0 to 1): its tiles, as the game lays them. None when it has none."""
    import io

    from PIL import Image

    w, h = int(overlay["TextureWidth"]), int(overlay["TextureHeight"])
    if w <= 0 or h <= 0 or not tiles:
        return None
    img = Image.new("RGBA", (-(-w // size) * size, -(-h // size) * size), (0, 0, 0, 0))
    for t in tiles:
        tile = Image.open(io.BytesIO(_game_file(int(t["FileDataID"])))).convert("RGBA")
        img.paste(tile, (int(t["ColIndex"]) * size, int(t["RowIndex"]) * size))
    alpha = np.asarray(img.getchannel("A"), np.float32)[:h, :w] / 255
    return alpha if alpha.max() > 0 else None


def art_rects(build, refresh=False):
    """{uiMapID: (north, west, south, east)}: the world rectangle each map's whole art (1002 x 668) covers."""
    out = {}
    for row in sorted(wago.read_db2("UiMapAssignment", build, refresh), key=lambda r: int(r["OrderIndex"])):
        ui_map = int(row["UiMapID"])
        if ui_map in out:
            continue
        south, east, north, west = (float(row[f"Region_{i}"]) for i in (0, 1, 3, 4))
        u0, v0, u1, v1 = (float(row[k]) for k in ("UiMin_0", "UiMin_1", "UiMax_0", "UiMax_1"))
        if u1 <= u0 or v1 <= v0:
            continue
        ky, kx = (west - east) / (u1 - u0), (north - south) / (v1 - v0)
        out[ui_map] = (north + v0 * kx, west + u0 * ky, north + v0 * kx - kx, west + u0 * ky - ky)
    return out


def fog(placed):
    """The dark over each piece, the pieces of a continent composed as one: `placed` = [(art rectangle (north, west,
    south, east), (w, h, x, y) on the art, alpha (piece_alpha))]. Returns [(image, (north, west, south, east)) or
    None, ...] in the same order: white, its alpha the piece's share of the dark. Laid together (alpha blending),
    any of them darken as 1 - prod(1 - alpha_i); over all of them that is FOG_DARK x the union of their drawings."""
    from scipy import ndimage

    if not placed:
        return []
    aw, ah = ART_SIZE
    rects = []
    for (north, west, south, east), (w, h, x, y), _ in placed:
        kx, ky = (north - south) / ah, (west - east) / aw  # (yards to an art pixel, down and across)
        rects.append((north - y * kx, west - x * ky, north - (y + h) * kx, west - (x + w) * ky, kx, ky))
    margin = int(4 * FOG_SPLIT) + 4
    top = max(r[0] for r in rects) + margin * FOG_YARDS
    left = max(r[1] for r in rects) + margin * FOG_YARDS
    rows = int(np.ceil((top - min(r[2] for r in rects)) / FOG_YARDS)) + margin
    cols = int(np.ceil((left - min(r[3] for r in rects)) / FOG_YARDS)) + margin
    drawn = np.zeros((rows, cols), np.float32)  # sum of the drawings (their feathered edges cross-fade: 1 where two meet)
    reach = np.zeros((rows, cols), np.float32)  # sum of each piece's reach ** FOG_SHARP
    windows = []
    for (n, w_, s_, e_, kx, ky), (_, (_, _, x, y), alpha) in zip(rects, placed):
        r0 = max(0, int((top - n) / FOG_YARDS) - margin)
        c0 = max(0, int((left - w_) / FOG_YARDS) - margin)
        r1 = min(rows, int(np.ceil((top - s_) / FOG_YARDS)) + margin)
        c1 = min(cols, int(np.ceil((left - e_) / FOG_YARDS)) + margin)
        # (each texel's middle, in the piece's own pixels)
        gx = top - (np.arange(r0, r1) + 0.5) * FOG_YARDS
        gy = left - (np.arange(c0, c1) + 0.5) * FOG_YARDS
        py, px = (n - gx) / kx - 0.5, (w_ - gy) / ky - 0.5
        src = alpha
        shrink = FOG_YARDS / min(kx, ky)  # (art pixels to a texel: blurred to it first)
        if shrink > 1.5:
            src = ndimage.gaussian_filter(alpha, 0.4 * shrink)
        a = ndimage.map_coordinates(src, np.meshgrid(py, px, indexing="ij"), order=1, cval=0.0).astype(np.float32)
        a = np.clip((a - FOG_FAINT) / (1 - FOG_FAINT), 0, 1)
        frame = np.minimum.outer(np.minimum(py + y, ah - py - y), np.minimum(px + x, aw - px - x))
        a *= np.clip(frame / FOG_FRAME, 0, 1).astype(np.float32)
        own = ndimage.gaussian_filter(a, FOG_SPLIT) ** FOG_SHARP
        drawn[r0:r1, c0:c1] += a
        reach[r0:r1, c0:c1] += own
        windows.append((r0, c0, own))
    # (each piece's share w of the ground; its alpha 1 - (1 - FOG_DARK * union) ** w, so the shares multiply back)
    union = ndimage.grey_closing(np.minimum(drawn, 1), size=(FOG_GAP, FOG_GAP))
    log_dark = np.log1p(-FOG_DARK * union)
    out = []
    for r0, c0, own in windows:
        h, w = own.shape
        share = own / np.maximum(reach[r0:r0 + h, c0:c0 + w], 1e-30)
        alpha = 1 - np.exp(share * log_dark[r0:r0 + h, c0:c0 + w])
        hit = np.nonzero(alpha >= 0.5 / 255)
        if not len(hit[0]):
            out.append(None)
            continue
        y0, y1, x0, x1 = hit[0].min(), hit[0].max() + 1, hit[1].min(), hit[1].max() + 1
        th, tw = 1 << int(np.ceil(np.log2(y1 - y0 + 2))), 1 << int(np.ceil(np.log2(x1 - x0 + 2)))
        th, tw = max(th, 8), max(tw, 8)
        # (centred in its power-of-two texture, the edge clear)
        oy, ox = y0 - (th - (y1 - y0)) // 2, x0 - (tw - (x1 - x0)) // 2
        tex = np.zeros((th, tw), np.float32)
        tex[y0 - oy:y1 - oy, x0 - ox:x1 - ox] = alpha[y0:y1, x0:x1]
        while max(tex.shape) > FOG_MAX:
            tex = tex.reshape(tex.shape[0] // 2, 2, tex.shape[1] // 2, 2).mean((1, 3))
        rgba = np.zeros(tex.shape + (4,), np.uint8)
        rgba[..., :3] = 255
        rgba[..., 3] = np.round(tex * 255).astype(np.uint8)
        north, west = top - (r0 + oy) * FOG_YARDS, left - (c0 + ox) * FOG_YARDS
        out.append((rgba, (round(north, 1), round(west, 1), round(north - th * FOG_YARDS, 1),
                           round(west - tw * FOG_YARDS, 1))))
    return out


def _numbers(values, per_line=24, indent="\t\t\t\t"):
    lines = []
    for i in range(0, len(values), per_line):
        lines.append(indent + ", ".join(str(v) for v in values[i : i + per_line]) + ",")
    return "\n".join(lines)


def build(build_id, refresh=False, data_file=DATA_FILE):
    """Writes Data/Zones.lua. Returns {mapID: (name, zones, runs, outline points)}."""
    from . import mapart, worldart  # (which import this module)

    names = {int(r["ID"]): r["Name_lang"] for r in wago.read_db2("UiMap", build_id, refresh)}
    types = {int(r["ID"]): r["Type"] for r in wago.read_db2("UiMap", build_id, refresh)}
    map_names = {m: n for m, _, n in tiles.world_maps(build_id, refresh)}
    summary, blocks, cities, zone_list = {}, [], {}, set()
    islands = worldart.islands(build_id, refresh)
    for old in [*GLOW_DIR.glob("glow_*.tga"), *VEIL_DIR.glob("veil_*.tga"), *FOG_DIR.glob("fog_*.*")]:
        old.unlink()  # (a zone gone since leaves none)
    pieces = map_pieces(build_id, refresh)
    overlay_tiles = {}
    for t in wago.read_db2("WorldMapOverlayTile", build_id, refresh):
        overlay_tiles.setdefault(t["WorldMapOverlayID"], []).append(t)
    arts = art_rects(build_id, refresh)
    for map_id, (zone, dry, elsewhere, area) in sorted(grids(build_id, refresh).items()):
        rects = map_rects(map_id, build_id, refresh)
        here = city_zones(zone, rects)
        cities.update(here)
        zone, land = game_zones(zone, dry, elsewhere, rects)
        painted = {}
        island = islands.get(map_id)
        if island in rects:
            zone, rings = island_zone(zone, dry, island, rects[island], build_id, refresh)
            if rings:
                painted[island] = rings
        ids = sorted(int(v) for v in np.unique(zone) if v)
        index = {v: i + 1 for i, v in enumerate(ids)}
        coded = np.vectorize(lambda v: index.get(int(v), 0))(zone) if ids else zone
        row_lines, n_runs = [], 0
        for r in range(SIZE):
            if not coded[r].any():
                continue
            rr = runs(coded[r])
            n_runs += len(rr)
            row_lines.append(f"\t\t\t[{r}] = {{ " + ", ".join(f"{c}, {v}" for c, v in rr) + " },")
        glow_lines = []
        for ui_map in ids:
            made = glow(zone, land, ui_map)
            if made:
                img, rect = made
                GLOW_DIR.mkdir(parents=True, exist_ok=True)
                img.save(GLOW_DIR / f"glow_{ui_map}.tga")
                glow_lines.append(f"\t\t\t\t[{ui_map}] = {{ {', '.join(str(v) for v in rect)} }},")
        veil_lines = []
        for ui_map in ids:
            made = veil(zone, ui_map, [c for c, z in here.items() if z == ui_map])
            if made:
                img, rect = made
                VEIL_DIR.mkdir(parents=True, exist_ok=True)
                img.save(VEIL_DIR / f"veil_{ui_map}.tga")
                veil_lines.append(f"\t\t\t\t[{ui_map}] = {{ {', '.join(str(v) for v in rect)} }},")
        fog_lines, placed, named = [], [], []
        for ui_map in ids:
            for row, key, _ in pieces.get(ui_map, []) if ui_map in arts else ():
                alpha = piece_alpha(row, overlay_tiles.get(row["ID"], []))
                if alpha is not None:  # (not an empty placeholder)
                    dims = tuple(int(row[k]) for k in ("TextureWidth", "TextureHeight", "OffsetX", "OffsetY"))
                    placed.append((arts[ui_map], dims, alpha))
                    named.append((ui_map, key, int(row["ID"])))
        for (ui_map, key, overlay), made in zip(named, fog(placed)):
            if made:
                rgba, rect = made
                FOG_DIR.mkdir(parents=True, exist_ok=True)
                mapart.blp_write(FOG_DIR / f"fog_{overlay}.blp", rgba)
                fog_lines.append(f'\t\t\t\t{{ {ui_map}, "{key}", {overlay}, {", ".join(str(v) for v in rect)} }},')
        border_lines, points = [], 0
        for ui_map in ids:
            rings = painted.get(ui_map) or outlines(zone, land, ui_map)
            if not rings:
                continue
            points += sum(len(r) // 2 for r in rings)
            body = "\n".join("\t\t\t\t{\n" + _numbers(r, 24, "\t\t\t\t\t") + "\n\t\t\t\t}," for r in rings)
            border_lines.append(f"\t\t\t[{ui_map}] = {{ -- {names.get(ui_map, '?')}\n{body}\n\t\t\t}},")
        if map_id in (0, 1):
            zone_list.update(v for v in ids if v not in CITIES and types.get(v) == "3")
        summary[map_id] = (map_names.get(map_id, "?"), len(ids), n_runs, points)
        blocks.append(
            f"\t\t[{map_id}] = {{ -- {map_names.get(map_id, '?')}\n"
            f"\t\t\tids = {{ {', '.join(str(v) for v in ids)} }},\n"
            f"\t\t\trows = {{\n" + "\n".join("\t" + line for line in row_lines) + "\n\t\t\t},\n"
            f"\t\t\tborders = {{\n" + "\n".join("\t" + line.replace("\n", "\n\t") for line in border_lines) + "\n\t\t\t},\n"
            f"\t\t\tglows = {{\n" + "\n".join(glow_lines) + "\n\t\t\t},\n"
            f"\t\t\tveils = {{\n" + "\n".join(veil_lines) + "\n\t\t\t},\n"
            f"\t\t\tpieces = {{\n" + "\n".join(fog_lines) + "\n\t\t\t},\n"
            "\t\t},"
        )

    data_file.write_text(
        f"-- Generated by `warroom zones` from build {build_id}. Do not edit.\n"
        "-- Which map owns each chunk of ground (33 1/3 yards), as the game has it: the terrain's area, walked up to its\n"
        "-- zone, where that zone's map is (land no zone holds goes to a neighbour); and each zone's outline.\n"
        "-- zones = { uiMapID, ... }: the zones of Kalimdor and the Eastern Kingdoms (not the cities)\n"
        "-- cities = { [city] = the zone it lies in }\n"
        "-- maps[mapID] = { ids = { uiMapID, ... },\n"
        "--   rows = { [chunk row] = { column, index, column, index, ... } }: from each column on, ids[index] owns the\n"
        "--     chunks (0: none) up to the next column given; rows count from the north, columns from the west (tile\n"
        "--     tx, ty holds rows ty * 16 to ty * 16 + 15, columns tx * 16 to tx * 16 + 15)\n"
        "--   borders = { [uiMapID] = { { x, y, x, y, ... }, ... } }: its outline rings in world yards, round the\n"
        "--     same chunks' land (an island's round it as painted on its own map)\n"
        "--   glows = { [uiMapID] = { north, west, south, east } }: the world rectangle of its hover glow,\n"
        "--     Media/Glow/glow_<uiMapID>.tga (in the game's style, the shape of its land)\n"
        "--   veils = { [uiMapID] = { north, west, south, east } }: the world rectangle of the veil round it once the\n"
        "--     view is on it, Media/Veil/veil_<uiMapID>.tga (white; clear over it, opaque round it)\n"
        "--   pieces = { { uiMapID, key, overlayID, north, west, south, east }, ... }: the pieces of its zones' maps to\n"
        "--     explore (key = \"w:h:x:y\", as C_MapExplorationInfo.GetExploredMapTextures gives them) and the world\n"
        "--     rectangle of the dark over each until it is, Media/Fog/fog_<overlayID>.blp (white; its alpha the\n"
        "--     piece's share of the dark, so any of them laid together darken as one) }\n"
        "local _, ns = ...\n"
        "ns.ZoneData = {\n"
        f'\tbuild = "{build_id}",\n'
        f"\tzones = {{ {', '.join(str(v) for v in sorted(zone_list))} }},\n"
        f"\tcities = {{ {', '.join(f'[{c}] = {z}' for c, z in sorted(cities.items()))} }},\n"
        "\tmaps = {\n" + "\n".join(blocks) + "\n\t},\n}\n",
        encoding="utf-8",
        newline="\n",
    )
    return summary
