import math

import pytest

TILE = 1600 / 3


def test_origin_is_corner_of_tile_32_32(coords):
    tx, ty, fx, fy = coords.run("return Coords.WorldToTile(0, 0)")
    assert (tx, ty) == (32, 32)
    assert fx == pytest.approx(0) and fy == pytest.approx(0)


def test_north_is_up_and_west_is_left(coords):
    # One tile north (x grows north) is the row above; one tile west (y grows west) is the column to the left.
    _, ty, _, _ = coords.run(f"return Coords.WorldToTile({TILE * 1.5}, 0)")
    tx, _, _, _ = coords.run(f"return Coords.WorldToTile(0, {TILE * 1.5})")
    assert ty == 30
    assert tx == 30


def test_fraction_grows_east_and_south(coords):
    # A quarter tile south and a quarter tile east of tile (32, 32)'s corner.
    tx, ty, fx, fy = coords.run(f"return Coords.WorldToTile({-TILE / 4}, {-TILE / 4})")
    assert (tx, ty) == (32, 32)
    assert fx == pytest.approx(0.25) and fy == pytest.approx(0.25)


@pytest.mark.parametrize("x, y", [(0, 0), (-8949.95, -132.493), (1633.75, 240.17), (-2917.58, -257.98), (16000, -16000)])
def test_tile_round_trip(coords, x, y):
    wx, wy = coords.run(
        f"local tx, ty, fx, fy = Coords.WorldToTile({x}, {y}); return Coords.TileToWorld(tx, ty, fx, fy)"
    )
    assert wx == pytest.approx(x) and wy == pytest.approx(y)


def test_rect_corners_and_round_trip(coords):
    # A map 1000 yd tall and 1500 yd wide, north-west corner at x=500, y=700.
    setup = "local r = Coords.NewRect(0, 500, 700, -500, -800) "
    assert coords.run(setup + "return Coords.WorldToRect(r, 500, 700)") == (0, 0)
    assert coords.run(setup + "return Coords.WorldToRect(r, -500, -800)") == (1, 1)
    u, v = coords.run(setup + "return Coords.WorldToRect(r, 0, -50)")
    assert u == pytest.approx(0.5) and v == pytest.approx(0.5)
    x, y = coords.run(setup + "return Coords.RectToWorld(r, 0.25, 0.75)")
    assert coords.run(setup + f"return Coords.WorldToRect(r, {x}, {y})") == pytest.approx((0.25, 0.75))


@pytest.mark.parametrize(
    "dx, dy, expected",
    [(10, 0, 0), (0, 10, math.pi / 2), (-10, 0, math.pi), (0, -10, 3 * math.pi / 2)],
    ids=["north", "west", "south", "east"],
)
def test_bearing_counter_clockwise_from_north(coords, dx, dy, expected):
    assert coords.run(f"return Coords.Bearing(0, 0, {dx}, {dy})") == pytest.approx(expected)


def test_distance(coords):
    assert coords.run("return Coords.Distance(1, 1, 4, 5)") == pytest.approx(5)
