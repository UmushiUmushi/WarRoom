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
