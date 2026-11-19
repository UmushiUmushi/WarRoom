"""The world map module (WarRoom_Map) run outside the game against a stand-in for the game's world map window:
it covers the window's map, frames the map the game's window is on, follows the game's breadcrumb, and its own
clicks, right-clicks and zooming out pick maps in the game's window."""

from lua_env import ADDONS, compile_file
from test_canvas import _env

_MORE_WOW = """
lines, fontStrings = 0, 0
glowTextures = {}
buttons = {}
function IsMouseButtonDown() return true end
EXPLORED = {}
C_MapExplorationInfo = { GetExploredMapTextures = function(mapID) return EXPLORED[mapID] end }
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
CURSOR_X, CURSOR_Y = 600, 400
local base = CreateFrame
local function Extend(f)
    function f:CreateFontString() local s = Extend(base("FontString", nil, self)) function s:SetText(t) self.text = t end
        function s:GetText() return self.text end function s:SetShadowOffset() end function s:SetShadowColor() end
        function s:SetFont(_, size) self.size = size end function s:SetTextColor() end
        function s:GetStringWidth() return (self.size or 10) * 0.6 * #(self.text or "") end
        fontStrings = fontStrings + 1 return s end
    function f:SetScale(s) self.scale = s end
    function f:GetAlpha() return self.alpha end
    local createTexture = f.CreateTexture
    function f:CreateTexture(...) local t = Extend(createTexture(self, ...)) glowTextures[#glowTextures + 1] = t return t end
    function f:SetBlendMode(m) self.blend = m end
    function f:EnableMouse() end
    function f:EnableMouseWheel() end
    function f:HookScript(event, fn) self.hooks = self.hooks or {} self.hooks[event] = fn end
    function f:IsMouseOver() return true end
    function f:IsVisible() return self.shown end
    function f:GetFrameStrata() return "MEDIUM" end
    function f:SetRotation() end
    function f:GetSize() return 1200, 800 end
    function f:SetScript(event, fn) self.scripts = self.scripts or {} self.scripts[event] = fn end
    function f:SetValue(v) self.value = v if self.scripts and self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end end
    function f:GetValue() return self.value or 0 end
    function f:Click() self.scripts.OnClick(self) end
    function f:SetText(t) self.text = t end
    function f:GetText() return self.text end
    function f:GetLeft() return 0 end
    -- (the rest of a slider's, a button's and a backdrop's setup: nothing to remember)
    for _, m in ipairs({ "SetOrientation", "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor", "SetThumbTexture",
        "SetMinMaxValues", "SetValueStep", "SetObeyStepOnDrag", "SetHitRectInsets", "SetMovable", "SetClampedToScreen",
        "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetJustifyH", "SetHighlightTexture", "SetDesaturated" }) do f[m] = f[m] or function() end end
    function f:CreateLine() local l = Extend(base("Line", nil, self)) lines = lines + 1
        function l:SetThickness() end function l:SetStartPoint(...) self.start = { ... } end
        function l:SetEndPoint(...) self.stop = { ... } end return l end
    return f
end
function CreateFrame(kind, name, parent, template)
    local f = Extend(base(kind, name, parent, template))
    if kind == "Button" then buttons[#buttons + 1] = f end
    return f
end
function GetCursorPosition() return CURSOR_X, CURSOR_Y end
function hooksecurefunc(t, name, fn) t.posthooks = t.posthooks or {} t.posthooks[name] = fn end
function InCombatLockdown() return false end
function IsInRaid() return false end
function GetNumSubgroupMembers() return 0 end
function GetPlayerFacing() return 0 end
GameTooltip_Hide = function() end
RAID_CLASS_COLORS = {}
C_Map.GetMapLevels = function() return 10, 20 end

-- The game's world map window: on Mulgore.
WorldMapFrame = CreateFrame("Frame")
WorldMapFrame.ScrollContainer = CreateFrame("Frame", nil, WorldMapFrame)
local coordsPanel = CreateFrame("Frame", nil, WorldMapFrame)
coordsPanel.PlayerCoords, coordsPanel.CursorCoords = {}, {}
WorldMapFrame.overlayFrames = { coordsPanel, CreateFrame("Frame", nil, WorldMapFrame) }
WorldMapFrame.mapID, WorldMapFrame.sets = 1412, {}
function WorldMapFrame:GetMapID() return self.mapID end
function WorldMapFrame:OnMapChanged() if self.posthooks and self.posthooks.OnMapChanged then self.posthooks.OnMapChanged(self) end end
function WorldMapFrame:SetMapID(id) self.mapID = id; table.insert(self.sets, id); self:OnMapChanged() end
"""


def _map_env():
    env = _env()
    env.lua.execute(_MORE_WOW)
    env.load("Core/Pins.lua").load("Data/Zones.lua").load("Core/Zones.lua").load("Data/Labels.lua")
    env.lua.execute("""return function(ns)
        local WR = ns.WR
        WarRoom = WR
        WR.MapLabels = ns.MapLabels
        WR.modules, WR.SlashCommands = {}, {}
        function WR.NewModule(name) local m = { name = name } WR.modules[name] = m return m end
        function WR.OnEvent() end
        function WR.AfterCombat(_, fn) fn() return true end
        function WR.RegisterCallback() end
        function WR.Print() end
        WR.Position = { state = { known = true, continent = 1, x = -2400, y = -400, mapID = 1412 }, Read = function() end }
        WR.db = { RegisterNamespace = function(_, _, d) return { profile = d.profile } end }
        -- (the game's maps: continents under Azeroth, zones under their continent)
        C_Map.GetMapInfo = function(id)
            local parent = (id == 1414 or id == 1415) and 947 or nil
            local rect = ns.Coords.GetMapRect(id)
            if not parent and rect then parent = rect.continent == 1 and 1414 or 1415 end
            return { mapID = id, name = "map " .. id, mapType = (id == 1414 or id == 1415) and 2 or 3, parentMapID = parent or 0 }
        end
    end""")(env.ns)
    for name in ("Map.lua", "Marks.lua", "Labels.lua", "Transitions.lua", "Settings.lua"):
        chunk, err = compile_file(env.lua, ADDONS / "WarRoom_Map" / name)
        assert chunk is not None, err
        chunk("WarRoom_Map", env.lua.table())
    return env


def test_zones_name_the_ground_and_outline_it():
    env = _map_env()
    run = env.lua.execute("""return function(ns)
        local Zones, Coords = ns.Zones, ns.Coords
        local function Middle(id) local r = Coords.GetMapRect(id) return r.continent, (r.top + r.bottom) / 2, (r.left + r.right) / 2 end
        local out = {}
        out.redridge = Zones.At(Middle(1433))
        out.mulgore = Zones.At(Middle(1412))
        local c, x, y = Middle(1415)
        out.sea = Zones.At(0, 30000, 30000)
        out.stormwind = Zones.ZoneOf(1453)
        local continent, rings = Zones.Outline(1433)
        out.outline = continent == 0 and #rings > 0 and #rings[1] > 20
        -- the top of Redridge is Riverglades's in game (its continent's map paints it as Redridge's)
        out.redridgeTop = Zones.At(0, -8728.2, -3233.5)
        -- a strip of Dun Morogh's western mountains the terrain tags as Westfall's, off Westfall's map: not Westfall
        out.strip = Zones.At(0, -6750, 1083)
        out.coldridge = Zones.At(0, -6230, 330)
        -- Zephras Isle: the island as painted on its map, not the clouds round it (its terrain is ground all over)
        out.isle = Zones.At(2991, 3124, 1456)
        out.clouds = Zones.At(2991, 2458, 3399)
        local isleContinent, isleRings = Zones.Outline(2521)
        out.isleOutline = isleContinent == 2991 and #isleRings == 1
        return out
    end""")
    out = run(env.ns)
    assert out.redridge == 1433 and out.mulgore == 1412
    assert out.sea is None
    assert out.stormwind == 1429
    assert out.outline
    assert out.redridgeTop == 2548
    assert out.strip == 1426 and out.coldridge == 1426
    assert out.isle == 2521 and out.clouds is None and out.isleOutline


def test_world_map_follows_and_drives_the_games_window():
    env = _map_env()
    run = env.lua.execute("""return function(ns)
        local Map, Zones, Coords = ns.WR.modules.Map, ns.Zones, ns.Coords
        Map.enabled = true
        Map:OnEnable() -- (the game's window is open on Mulgore)
        local canvas, wm, host = Map.canvas, WorldMapFrame, Map.host
        local out = {}
        -- opened on the player, close in (all terrain), on the zone they stand in
        out.open = host.shown and canvas.continent == 1 and math.abs(canvas.cx + 2400) < 1 and math.abs(canvas.cy + 400) < 1
            and canvas.ypp == canvas.options.terrainFull and canvas.ypp < canvas.options.terrainNone
        out.openScope = Map.GetScope() == Zones.At(1, -2400, -400)
        out.coordsHidden = not wm.overlayFrames[1].shown
        out.raised = wm.overlayFrames[2]:GetFrameLevel() >= 6100
        -- fades from the window, one phase after another going in: all of Azeroth one sheet; about a continent framed
        -- its own painting; on into it the detailed map with the banners; then the city maps; closer than a city
        -- framed the terrain
        local o = canvas.options
        local function Fit(id) local r = Coords.GetMapRect(id) return math.max(r.width / 1200, r.height / 800) * 1.04 end
        out.fades = o.continentNone > o.continentFull and o.continentFull >= Fit(1415) * 0.85
            and o.zonesNone < o.continentFull and o.zonesFull < o.zonesNone and o.seaFull == o.zonesFull
            and o.seaNone == o.zonesNone and o.citiesNone < o.zonesFull and o.citiesFull < o.citiesNone
            and o.terrainNone < o.citiesFull and o.terrainNone < Fit(1456) and o.terrainNone < Fit(1453)
            and o.terrainFull < o.terrainNone
        -- the player picks Azeroth in the game's breadcrumb: all of it, as far out as it goes
        wm.mapID = 947
        wm:OnMapChanged()
        out.world = Map.GetScope() == 947 and canvas.ypp > o.continentNone
        -- the continents' and seas' names lettered over Azeroth's sheet
        out.names = fontStrings > 100
        -- on Kalimdor, a click in the middle of Mulgore: Mulgore, framed and picked in the game's window
        Map.Frame(1414)
        local m = Coords.GetMapRect(1412)
        local mx, my = canvas:WorldToFrame((m.top + m.bottom) / 2, (m.left + m.right) / 2, 1)
        CURSOR_X, CURSOR_Y = 600 + mx, 400 + my
        host.scripts.OnMouseDown(host, "LeftButton")
        host.scripts.OnMouseUp(host, "LeftButton")
        CURSOR_X, CURSOR_Y = 600, 400
        out.click = Map.GetScope() == 1412 and wm.mapID == 1412 and canvas.ypp <= o.zonesFull
            and canvas.ypp <= Fit(1412)
        -- a zone too big to frame with the detailed map all in (the Barrens): as close as that, still on it
        Map.Frame(1413)
        out.bigZone = canvas.ypp == o.zonesFull and Map.GetScope() == 1413
        Map.Frame(1412)
        -- the pointer over the Barrens from Mulgore: the Barrens glow (added on, as the game's), Mulgore itself doesn't
        local b = Coords.GetMapRect(1413)
        local bx, by = canvas:WorldToFrame(-450, -2650, 1)
        CURSOR_X, CURSOR_Y = 600 + bx, 400 + by
        local target = Map.MapAt(bx, by)
        host.scripts.OnUpdate(host, 1)
        local glow
        for _, t in ipairs(glowTextures) do if t.blend then glow = t end end
        out.glow = target ~= 1412 and glow and glow.shown and glow.blend == "ADD" and glow.file:find("glow_" .. target) and true
        local vx, vy = canvas:WorldToFrame(-2400, -400, 1) -- (Bloodhoof Village, in Mulgore)
        CURSOR_X, CURSOR_Y = 600 + vx, 400 + vy
        host.scripts.OnUpdate(host, 1)
        out.noSelfGlow = Map.MapAt(vx, vy) == 1412 and not (glow and glow.shown)
        CURSOR_X, CURSOR_Y = 600, 400
        -- the veil round the map the view is on (Mulgore), faded in; the ground outside it dimmed round it
        local veil
        for _, t in ipairs(glowTextures) do
            if type(t.file) == "string" and t.file:find("veil_" .. Map.GetScope()) and t.shown then veil = t end
        end
        out.outlined = veil and veil.parent.alpha == 1 and true
        -- a right-click: back out to Kalimdor
        host.scripts.OnMouseUp(host, "RightButton")
        out.back = Map.GetScope() == 1414 and wm.mapID == 1414
        -- zoomed out all the way: on Azeroth's map
        for _ = 1, 30 do
            host.scripts.OnMouseWheel(host, -1)
        end
        out.out = Map.GetScope() == 947 and wm.mapID == 947
        -- on Shen'dralas, dragged over to Mulgore: on Mulgore now
        Map.Frame(2652)
        local r = Coords.GetMapRect(1412)
        local dx, dy = canvas:WorldToFrame((r.top + r.bottom) / 2, (r.left + r.right) / 2, 1)
        host.scripts.OnMouseDown(host, "LeftButton")
        CURSOR_X, CURSOR_Y = 600 - dx, 400 - dy
        host.scripts.OnUpdate(host, 0.01)
        host.scripts.OnMouseUp(host, "LeftButton")
        CURSOR_X, CURSOR_Y = 600, 400
        out.followed = Map.GetScope() == 1412 and wm.mapID == 1412
        -- hovering
        host.scripts.OnUpdate(host, 1)
        -- the game's map turned back on
        ns.WR.SlashCommands.map()
        out.off = not host.shown and wm.overlayFrames[1].shown
        return out
    end""")
    out = run(env.ns)
    assert out.open and out.openScope
    assert out.coordsHidden and out.raised
    assert out.fades
    assert out.world and out.names
    assert out.click and out.bigZone and out.outlined and out.back and out.out
    assert out.glow and out.noSelfGlow
    assert out.followed
    assert out.off


def test_transitions_bar_moves_the_handovers():
    env = _map_env()
    run = env.lua.execute("""return function(ns)
        local Map = ns.WR.modules.Map
        Map.enabled = true
        Map:OnEnable()
        local canvas, o = Map.canvas, Map.canvas.options
        local refs = Map.FadeRefs()
        local out = {}
        -- the defaults: each fade its multiple of the zoom it is keyed to
        out.defaults = math.abs(o.zonesNone - refs.continent * 0.352) < 1e-6 and math.abs(o.terrainNone - refs.city * 0.98) < 1e-6
            and refs.world > refs.continent and refs.continent > refs.cityZone and refs.cityZone > refs.city
        -- the bar: as far out as the map goes on the left, as close in on the right, on a log scale
        local far, near = Map.ZoomRange()
        local function At(ypp) return math.log(far / ypp) / math.log(far / near) * 600 end
        local stops, panel = {}, nil
        for _, b in ipairs(buttons) do
            if not b:GetText() and b.scripts and b.scripts.OnMouseDown then stops[#stops + 1] = b end
        end
        -- (the bar opens from the map's settings: the round button at its bottom left, then Transitions)
        local function Setting(key) for _, b in ipairs(buttons) do if b.key == key then return b end end end
        Setting("settings"):Click()
        Setting("transitions"):Click()
        for _, b in ipairs(buttons) do if b:GetText() == "Defaults" then panel = b.parent end end
        out.stops = #stops == 8 and panel.shown and Map.TransitionsShown()
        -- the terrain setting: the terrain at every zoom (the paintings never over it), the bar's stops as set
        Setting("terrain"):Click()
        out.terrain = Map.db.profile.terrainAlways and o.terrainNone == math.huge and o.terrainFull == math.huge
            and Map.fades.terrainNone < 10 and canvas.ypp < o.terrainNone
        Setting("terrain"):Click()
        out.terrainOff = not Map.db.profile.terrainAlways and o.terrainNone == Map.fades.terrainNone
        -- drag the third stop (2 > 3 starts) to 20: the detailed map and its sea paper start there
        local function Drag(stop, ypp)
            CURSOR_X = At(ypp)
            stop.scripts.OnMouseDown(stop)
            panel.scripts.OnUpdate(panel, 0.01)
            stop.scripts.OnMouseUp(stop)
        end
        Drag(stops[3], 20)
        out.drag = math.abs(o.zonesNone - 20) < 0.1 and o.seaNone == o.zonesNone
            and math.abs(Map.db.profile.fades.zonesNone - 20 / refs.continent) < 0.01
        -- a stop never passes its neighbours (2 > 3 done is closer in)
        Drag(stops[3], 2)
        out.clamped = math.abs(o.zonesNone - o.zonesFull) < 0.05
        -- a click on the bar zooms the map there
        CURSOR_X = At(10)
        local bar = stops[1].parent
        bar.scripts.OnMouseDown(bar)
        out.zoom = math.abs(canvas.ypp - 10) < 0.05
        -- "Defaults": back to the built-in multiples
        for _, b in ipairs(buttons) do if b:GetText() == "Defaults" then b:Click() end end
        out.reset = next(Map.db.profile.fades) == nil and math.abs(o.zonesNone - refs.continent * 0.352) < 1e-6
        CURSOR_X = 600
        return out
    end""")
    out = run(env.ns)
    assert out.defaults and out.stops
    assert out.terrain and out.terrainOff
    assert out.drag and out.clamped and out.zoom and out.reset


def test_unexplored_ground_is_misted():
    env = _map_env()
    run = env.lua.execute("""return function(ns)
        local Map, Zones = ns.WR.modules.Map, ns.WR.Zones
        -- (Zephras Isle's zone under Azeroth's map, as the game has it, which places it there)
        local info = C_Map.GetMapInfo
        C_Map.GetMapInfo = function(id)
            if id == 2521 then return { mapID = id, name = "Zephras Isle", mapType = 3, parentMapID = 947 } end
            return info(id)
        end
        C_Map.GetMapRectOnMap = function(id, on)
            if id == 2521 and on == 947 then return 0.42, 0.544, 0.05, 0.174 end
        end
        -- the player has explored Bloodhoof Village's piece of Mulgore, nothing else of it
        EXPLORED[1412] = { { textureWidth = 238, textureHeight = 206, offsetX = 357, offsetY = 328 } }
        Map.enabled = true
        Map:OnEnable()
        local canvas, o = Map.canvas, Map.canvas.options
        -- (the pieces laid in the dark: { [overlayID] = true })
        local function Shown()
            local out = {}
            for _, t in ipairs(glowTextures) do
                local id = type(t.file) == "string" and t.file:match("fog_(%d+)$")
                if id and t.shown and t.parent.shown then out[tonumber(id)] = true end
            end
            return out
        end
        local out = {}
        -- Mulgore framed (the detailed map all in): its other pieces dark, Bloodhoof Village's not
        Map.Frame(1412)
        local shown, mulgore, misted, barrens, dark, bloodhoof = Shown(), 0, 0, 0, 0, nil
        for _, piece in ipairs(Zones.Pieces(1)) do
            if piece[1] == 1412 then
                mulgore = mulgore + 1
                if shown[piece[3]] then misted = misted + 1 end
                if piece[2] == "238:206:357:328" then bloodhoof = piece[3] end
            elseif piece[1] == 1413 then
                barrens = barrens + 1
                if shown[piece[3]] then dark = dark + 1 end
            end
        end
        out.zoomedIn = canvas.ypp <= o.zonesFull and mulgore > 5 and misted == mulgore - 1 and bloodhoof
            and not shown[bloodhoof]
        -- the Barrens, never set foot in (the game gives nothing for it): all of it dark
        out.never = barrens > 5 and dark == barrens
        -- the Unexplored setting off: no dark; on again: back as it was
        local function Setting(key) for _, b in ipairs(buttons) do if b.key == key then return b end end end
        Setting("unexplored"):Click()
        out.off = not Map.db.profile.unexplored and next(Shown()) == nil
        Setting("unexplored"):Click()
        local again = Shown()
        out.on = Map.db.profile.unexplored and bloodhoof and not again[bloodhoof] and again[(next(shown))] == true
        -- Zephras Isle (a map of its own the game puts on Azeroth's), never been to, framed: its pieces dark too
        local isle, isleDark = 0, 0
        Map.Frame(2521)
        shown = Shown()
        for _, piece in ipairs(Zones.Pieces(2991)) do
            isle = isle + 1
            if shown[piece[3]] then isleDark = isleDark + 1 end
        end
        out.isle = isle > 5 and isleDark == isle
        -- Kalimdor framed (its own painting): no dark
        Map.Frame(1414)
        out.zoomedOut = next(Shown()) == nil
        return out
    end""")
    out = run(env.ns)
    assert out.zoomedIn
    assert out.never
    assert out.off and out.on
    assert out.isle
    assert out.zoomedOut
