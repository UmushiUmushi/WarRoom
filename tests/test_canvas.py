"""The Canvas's painted layers built and zoomed through outside the game, with a stand-in for WoW's frames: every
size of tile shows at its zoom (and only near the view), the sea and the continent's ocean trade places, and
nothing is nil on the way."""

from lua_env import LuaEnv

# Just enough of WoW's frame API: frames and textures that remember what was done to them.
_WOW = """
local function Region(kind, parent)
    local r = { kind = kind, parent = parent, shown = true, alpha = 1 }
    function r:SetAllPoints() end
    function r:SetPoint() end
    function r:ClearAllPoints() end
    function r:SetSize() end
    function r:SetFrameLevel(l) self.level = l end
    function r:GetFrameLevel() return self.level or 0 end
    function r:SetClipsChildren() end
    function r:SetScript(_, fn) self.script = fn end
    function r:SetShown(v) self.shown = v and true or false end
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    function r:IsShown() return self.shown end
    function r:SetAlpha(a) self.alpha = a end
    function r:GetSize() return 1200, 800 end
    function r:GetCenter() return 600, 400 end
    function r:GetEffectiveScale() return 1 end
    function r:GetParent() return self.parent end
    function r:SetTexture(file) self.file = file; textures[self] = file end
    function r:SetColorTexture() end
    function r:SetTexCoord() end
    function r:AddMaskTexture(m) self.masks = (self.masks or 0) + 1 end
    function r:SetVertexColor() end
    function r:CreateTexture() return Region("texture", self) end
    function r:CreateMaskTexture() return Region("mask", self) end
    return r
end
textures = {}
function CreateFrame(_, _, parent) return Region("frame", parent) end
function GetPhysicalScreenSize() return 1920, 1080 end
function debugprofilestop() return 0 end
C_Map = {
    GetMapArtLayers = function() return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } } end,
    GetMapArtLayerTextures = function() local t = {} for i = 1, 12 do t[i] = 1000 + i end return t end,
    GetMapInfo = function() return nil end,
}
unpack = unpack or table.unpack
"""


def _env():
    from warroom_tools import mapart, wago

    env = LuaEnv()
    env.lua.execute(_WOW)
    env.load("Core/Coords.lua").load("Data/MapArt.lua").load("Core/Canvas.lua")
    build = env.ns.MapArt.build
    rects = mapart.map_rects(build)
    for row in wago.read_db2("UiMapAssignment", build):  # (the continents' own maps too)
        if row["UiMapID"] in ("1414", "1415"):
            rects[int(row["UiMapID"])] = (int(row["MapID"]), float(row["Region_3"]), float(row["Region_4"]),
                                          float(row["Region_0"]), float(row["Region_1"]))
    table = env.lua.table()
    for ui_map, (cont, top, left, bottom, right) in rects.items():
        table[ui_map] = env.ns.Coords.NewRect(cont, top, left, bottom, right)
    env.lua.execute("return function(ns, rects) ns.Coords.GetMapRect = function(id) return rects[id] end end")(env.ns, table)
    return env


def test_painted_layers_through_every_zoom():
    env = _env()
    run = env.lua.execute("""return function(ns)
        local Canvas = ns.Canvas
        local canvas = Canvas.New(CreateFrame("Frame"))
        -- Thunder Bluff, from the whole continent in to the terrain
        local out = {}
        for _, ypp in ipairs({ 40, 25, 15, 10, 7, 5, 3, 2, 1.5 }) do
            canvas:SetView(1, -1150, -5, ypp)
            local g = canvas.groups[1]
            local s = canvas.stats
            out[#out + 1] = { ypp = ypp, level = s.level or "none", tiles = s.zones, art = g and g.art.shown and g.art.alpha or 0,
                sea = g and g.sea and g.sea.shown or false, paint = g and g.paint.shown or false }
        end
        local loaded = 0
        for _, level in ipairs(canvas.groups[1].levels) do
            for _, t in ipairs(level.list) do
                if t.loaded then loaded = loaded + 1 end
            end
        end
        return out, loaded
    end""")
    rows, loaded = run(env.ns)
    rows = [rows[i] for i in range(1, len(rows) + 1)]
    by = {r.ypp: r for r in rows}
    assert not by[40].paint and by[40].art == 1  # zoomed far out: the continent's painting alone
    assert by[15].paint and by[15].art == 1 and not by[15].sea  # its ocean over the clear sea of the tiles
    assert by[10].sea and 0 < by[10].art < 1  # the sea's paper coming in under it
    assert by[5].sea and by[5].art == 0
    drawn = [r for r in rows if r.level != "none"]  # (from 3 yards a unit in, the terrain has taken over)
    assert [r.level for r in drawn] == ["far", "far", "near", "near", "fine"]
    assert all(0 < r.tiles < 60 for r in drawn)
    assert loaded < 120  # only tiles near the view hold their files


def test_world_map_draws_both_continents_as_on_azeroths_map():
    env = _env()
    run = env.lua.execute("""return function(ns)
        local Canvas = ns.Canvas
        -- a point carried from Kalimdor's yards into the Eastern Kingdoms' and back lands where it started
        local ex, ey = Canvas.Convert(1, 0, -1150, -5)
        local kx, ky = Canvas.Convert(0, 1, ex, ey)
        local canvas = Canvas.New(CreateFrame("Frame"), { world = true })
        -- Azeroth's whole map, seen from Kalimdor: both continents' paintings, Kalimdor's sea under them
        local world = Canvas.WorldRect(1)
        canvas:SetView(1, (world.top + world.bottom) / 2, (world.left + world.right) / 2, 50)
        local far = { continent = canvas.continent, k = canvas.groups[1] and canvas.groups[1].root.shown,
            e = canvas.groups[0] and canvas.groups[0].root.shown, sea = canvas.groups[1].sea.shown,
            worldArt = #canvas.groups[1].worldArt, land = canvas.groups[1].art.shown }
        -- panned over Stormwind: the view's continent is now the Eastern Kingdoms, still drawn with Kalimdor
        local sx, sy = Canvas.Convert(0, 1, -8900, 550)
        canvas:SetView(1, sx, sy, 20)
        local near = { continent = canvas.continent, x = canvas.cx, y = canvas.cy, sea0 = canvas.groups[0].sea.shown,
            sea1 = canvas.groups[1].sea.shown }
        local dx, dy = canvas:WorldToFrame(-8900, 550, 0)
        local fx, fy = canvas:WorldToFrame(sx, sy, 1)
        -- far out Azeroth's sheet alone; zoomed in, each continent's own painting over it
        far.sheet = textures[canvas.groups[1].worldArt[1][1]]
        near.land = canvas.groups[0].art.shown and canvas.groups[0].art.alpha == 1
            and textures[canvas.groups[0].artPlaced[1][1]]
        return ex, ey, kx, ky, far, near, dx, dy, fx, fy
    end""")
    ex, ey, kx, ky, far, near, dx, dy, fx, fy = run(env.ns)
    assert abs(kx + 1150) < 1e-6 and abs(ky + 5) < 1e-6
    assert (ex, ey) != (-1150, -5)
    assert far.k and far.e and far.sea and far.worldArt > 0
    assert near.continent == 0 and abs(near.x + 8900) < 1e-6 and abs(near.y - 550) < 1e-6
    assert near.sea0 and not near.sea1  # (one sea for the view: its continent's)
    assert abs(dx) < 1e-6 and abs(dy) < 1e-6 and abs(fx) < 1e-6 and abs(fy) < 1e-6
    assert far.sheet.endswith("Map\\world") and not far.land
    assert near.land.endswith("Map\\land_1415")


def test_an_island_the_game_puts_on_azeroths_map_is_drawn_with_it():
    env = _env()
    run = env.lua.execute("""return function(ns)
        local Canvas, Coords = ns.Canvas, ns.Coords
        -- Zephras Isle: a map of its own (2991), its zone's parent Azeroth's map, which the game places it on
        ns.TileData = { [2991] = { files = {} } }
        C_Map.GetMapInfo = function(id) return { mapID = id, parentMapID = id == 2521 and 947 or 0 } end
        C_Map.GetMapRectOnMap = function(id, on)
            if id == 2521 and on == 947 then return 0.42, 0.544, 0.05, 0.174 end
        end
        local out = { island = Canvas.IsIsland(2991), listed = Canvas.WorldContinents()[3] == 2991 }
        local r = Coords.GetMapRect(2521)
        local mx, my = (r.top + r.bottom) / 2, (r.left + r.right) / 2
        -- its middle carried onto Azeroth's map: about the middle of its place there
        local ex, ey = Canvas.Convert(2991, 0, mx, my)
        local u, v = Coords.WorldToRect(Canvas.WorldRect(0), ex, ey)
        out.u, out.v = u, v
        -- a view centred on it is in a continent's yards (an island has no sea of its own), with the island drawn
        local canvas = Canvas.New(CreateFrame("Frame"), { world = true })
        canvas:SetView(2991, mx, my, 20)
        out.continent = canvas.continent
        local g = canvas.groups[2991]
        out.drawn = g and g.root.shown and g.art.shown and textures[g.artPlaced[1][1]]
        out.at = canvas:FrameToContinent(0, 0)
        return out
    end""")
    out = run(env.ns)
    assert out.island and out.listed
    assert abs(out.u - 0.482) < 0.002 and abs(out.v - 0.112) < 0.002
    assert out.continent in (0, 1)
    assert out.drawn.endswith("Map\\isle_2521")
    assert out.at == 2991


def test_an_island_the_game_wont_place_is_put_where_ours_says():
    env = _env()
    run = env.lua.execute("""return function(ns)
        local Canvas, Coords = ns.Canvas, ns.Coords
        -- as in the game: Zephras Isle's zone is Azeroth's map's, but C_Map.GetMapRectOnMap has no answer for it
        ns.TileData = { [2991] = { files = {} } }
        C_Map.GetMapInfo = function(id) return { mapID = id, parentMapID = id == 2521 and 947 or 0 } end
        C_Map.GetMapRectOnMap = function() return nil end
        local r = Coords.GetMapRect(2521)
        local ex, ey = Canvas.Convert(2991, 0, (r.top + r.bottom) / 2, (r.left + r.right) / 2)
        local u, v = Coords.WorldToRect(Canvas.WorldRect(0), ex, ey)
        -- at the continents' scale: its map as wide on Azeroth's as its yards make it
        local w = Canvas.WorldRect(2991)
        return Canvas.IsIsland(2991), u, v, r.width / w.width
    end""")
    island, u, v, share = run(env.ns)
    assert island
    assert abs(u - 0.482) < 0.002 and abs(v - 0.13) < 0.002
    assert abs(share - 5562.5 / (1002 * 44.6)) < 0.002
