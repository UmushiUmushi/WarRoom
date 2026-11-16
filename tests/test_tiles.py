"""The terrain tile tool: fade keys, fade masks and the generated Data/Tiles.lua."""

import struct

import pytest

from lua_env import CORE, LuaEnv
from warroom_tools import tiles
from warroom_tools.tiles import E, N, NE, NW, S, SE, SW, W

# A plus-shaped island with a notch: tiles present at these (tx, ty).
ISLAND = {(x, y) for x in range(2, 7) for y in range(2, 7)} - {(2, 2), (6, 6)}


def test_fade_key_sides_and_corners():
    assert tiles.fade_key(ISLAND, 4, 4) == 0
    assert tiles.fade_key(ISLAND, 4, 2) == N
    assert tiles.fade_key(ISLAND, 3, 2) == N | W  # (2, 2) is missing beside it
    # (3, 3): all four sides present, the north-west corner (2, 2) missing.
    assert tiles.fade_key(ISLAND, 3, 3) == NW
    assert tiles.fade_key(ISLAND, 5, 5) == SE
    # A lone tile is open on every side; corners only count when both sides beside them are present.
    assert tiles.fade_key({(0, 0)}, 0, 0) == N | E | S | W


def test_fade_alpha_ends():
    assert tiles.fade_alpha(0, 0.3, 0.7) == 1
    assert tiles.fade_alpha(N, 0.5, 0.0) == 0
    assert tiles.fade_alpha(N, 0.5, 1.0) == 1
    assert tiles.fade_alpha(SW, 0.0, 1.0) == 0
    assert tiles.fade_alpha(SW, 1.0, 0.0) == 1


@pytest.mark.parametrize("t", [0.0, 0.1, 0.37, 0.5, 0.8, 1.0])
def test_fade_matches_across_shared_edges(t):
    """Every pair of neighbouring tiles has the same opacity along the edge they share."""
    for (tx, ty) in ISLAND:
        here = tiles.fade_key(ISLAND, tx, ty)
        if (tx + 1, ty) in ISLAND:  # east neighbour: our u=1 is its u=0
            there = tiles.fade_key(ISLAND, tx + 1, ty)
            assert tiles.fade_alpha(here, 1.0, t) == pytest.approx(tiles.fade_alpha(there, 0.0, t))
        if (tx, ty + 1) in ISLAND:  # south neighbour: our v=1 is its v=0
            there = tiles.fade_key(ISLAND, tx, ty + 1)
            assert tiles.fade_alpha(here, t, 1.0) == pytest.approx(tiles.fade_alpha(there, t, 0.0))


def test_mask_tga_layout():
    data = tiles.mask_tga(N, size=8)
    assert len(data) == 18 + 8 * 8 * 4
    _, _, kind = struct.unpack("<BBB", data[:3])
    width, height, bits, descriptor = struct.unpack("<HHBB", data[12:18])
    assert (kind, width, height, bits) == (2, 8, 8, 32)
    assert descriptor & 0x20  # top row first
    top, bottom = data[18 + 3], data[18 + 7 * 8 * 4 + 3]  # alpha of the first pixel of the top and bottom rows
    assert top < 20 and bottom > 235


def test_generated_tiles_lua():
    env = LuaEnv().load("Data/Tiles.lua")
    data = env.ns.TileData
    assert data is not None, "run `warroom tiles`"
    kalimdor = data[1]
    assert kalimdor.dir == "kalimdor"
    assert kalimdor.files[31 * 64 + 20] == 207922  # the tile checked in game with /wrprobe tile
    masks = CORE / "Media" / "Fade"
    for continent in data.keys():
        if continent == "build":
            continue
        for _, key in data[continent].fade.items():
            assert (masks / f"fade_{key}.tga").exists(), f"missing mask {key}"


def test_in_zones():
    # One zone covering world x 0..1000 (north), y -500..500 (west).
    regions = [(1000, 500, 0, -500)]
    assert not tiles.in_zones(regions, 32, 29)  # x 1066..1600: north of the zone
    assert tiles.in_zones(regions, 32, 30)  # x 533..1066 overlaps 0..1000, y -533..0 overlaps
    assert not tiles.in_zones(regions, 34, 30)  # y -1600..-1066: east of the zone


def test_generated_map_art():
    """Each continent's baked tiles exist at every size, each finer tile is a quarter of a coarser one, and the sea's
    textures and the cities' cuts and banners are there."""
    art = LuaEnv().load("Data/MapArt.lua").ns.MapArt
    assert art is not None, "run `warroom mapart`"
    bake = CORE / "Media" / "Bake"
    assert art.continents[1].art == 1414 and art.continents[0].art == 1415
    levels = [art.levels[n][1] for n in range(1, len(art.levels) + 1)]
    assert levels == ["far", "near", "fine"]
    for continent in (0, 1):
        entry = art.continents[continent]
        assert entry.sea.tile > 0 and entry.sea.hatch[1] > 0
        for name in (f"sea_{entry.art}.tga", f"coast_{entry.art}.tga"):
            assert (bake / name).exists()
        coarser = None
        for kind in levels:
            keys = [entry[kind][i] for i in range(1, len(entry[kind]) + 1)]
            assert keys, f"no {kind} tiles for {continent}"
            for key in keys:
                i, j = key // 256, key % 256
                assert (bake / f"{kind}_{i}_{j}.blp").exists(), f"missing {kind}_{i}_{j}"
                if coarser is not None:
                    assert (i // 2) * 256 + j // 2 in coarser, f"{kind}_{i}_{j} has no coarser tile"
            coarser = set(keys)
    for name in ("sea_dark.tga", "sea_light.tga", "sea_out.tga", "sea_947.tga", "hatch.tga", "feather_wide.tga"):
        assert (bake / name).exists()
    for city in art.cities.keys():
        entry = art.cities[city]
        assert (bake / (f"cut_{city}.tga" if entry.cut else "round.tga")).exists()
        if entry.banner:
            assert (bake / f"banner_{city}.tga").exists()
    assert set(art.cities.keys()) == {1453, 1454, 1456, 1457}  # Ironforge and Undercity are underground


def test_baked_tiles_are_dxt_blps():
    """Tiles are mipmapped DXT BLPs: DXT1 where all land, DXT5 (8-bit alpha) where they fade out over the sea."""
    from PIL import Image

    kinds = set()
    for tile in sorted((CORE / "Media" / "Bake").glob("near_*.blp")):
        data = tile.read_bytes()
        assert data[:4] == b"BLP2" and data[8] == 2 and data[11] == 1  # DXT, mipmapped
        kinds.add((data[9], data[10]))
        if len(kinds) == 2:
            break
    assert kinds == {(0, 0), (8, 7)}  # (alpha bits, alpha type): DXT1 and DXT5 both
    assert Image.open(tile).size == (512, 512)


def test_continent_units_match_the_world_map():
    """Azeroth's map's own corners (UiMin, UiMax of its assignment) land on the corners of the region it shows."""
    from warroom_tools import mapart, wago

    build = LuaEnv().load("Data/MapArt.lua").ns.MapArt.build
    units = mapart.continent_units(build)
    for row in wago.read_db2("UiMapAssignment", build):
        if row["UiMapID"] != "947":
            continue
        y0, ky, x0, kx = units[int(row["MapID"])]
        ux, uy = float(row["UiMin_0"]) * 1002, float(row["UiMin_1"]) * 668
        assert y0 - ux * ky == pytest.approx(float(row["Region_4"]), abs=0.01)
        assert x0 - uy * kx == pytest.approx(float(row["Region_3"]), abs=0.01)


def test_flood_follows_land_only():
    np = pytest.importorskip("numpy")
    from warroom_tools import areas

    inside = np.zeros((5, 7), dtype=bool)
    inside[2, 0:3] = True  # a strip joined to the seed
    inside[2, 4:7] = True  # an island past the gap at column 3
    seed = np.zeros_like(inside)
    seed[2, 0] = True
    out = areas._flood(seed, inside)
    assert out[2, 0:3].all() and not out[2, 4:7].any()
