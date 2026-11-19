"""The minimap module (WarRoom_Minimap) run outside the game against a stand-in for the game's Minimap: our map goes
under it on the player at its zoom, its ground hidden, all terrain; the wheel steps through its zooms and then a
little past them (ours lifted a strata over the game's, covering its icons and arrow, its ring drawn again over ours,
taking the mouse); a drag moves ours off the player without a ping,
and it comes back by itself; indoors and in instances the game's own minimap is given back whole."""

from lua_env import ADDONS, compile_file
from test_canvas import _env

_MINIMAP_WOW = """
UPDATERS = {}
SIZE = 140
MOUSE_OVER, INDOORS, CURSOR_X, CURSOR_Y, BUTTON_DOWN = true, false, 70, 70, true
GROUND = {}
PINGS = 0
local base = CreateFrame
local function Extend(f)
    function f:GetSize() return SIZE, SIZE end
    function f:GetWidth() return SIZE end
    function f:GetCenter() return SIZE / 2, SIZE / 2 end
    -- (as the game may: a frame put in another strata goes up it, over other addons' buttons at level 8)
    function f:SetFrameStrata(s) self.strata = s self.level = 50 end
    function f:GetFrameStrata() return self.strata or "MEDIUM" end
    function f:IsVisible() return self.shown end
    function f:IsMouseOver() return MOUSE_OVER end
    function f:SetRotation() end
    function f:SetHighlightTexture() end
    function f:EnableMouseWheel(on) self.wheel = on end
    function f:EnableMouse(on) self.mouse = on end
    function f:SetFixedFrameLevel(on) self.fixed = on end
    function f:SetFixedFrameStrata(on) self.fixedStrata = on end
    function f:SetNormalAtlas(a) self.atlas = a end
    function f:SetPushedAtlas() end
    function f:SetHighlightAtlas() end
    function f:SetDisabledAtlas() end
    function f:GetDisabledTexture() return nil end
    function f:SetEnabled(on) self.enabled = on end
    function f:SetParent(p) self.parent = p end
    function f:SetHeight(h) self.height = h end
    function f:SetWidth() end
    function f:SetClampedToScreen() end
    function f:RegisterForClicks() end
    function f:RegisterForDrag(...) self.drag = select("#", ...) > 0 end
    function f:SetPoint(...) self.point = { ... } end
    function f:GetNumPoints() return self.point and 1 or 0 end
    function f:GetPoint() return unpack(self.point) end
    function f:IsObjectType(t) return self.objType == t end
    function f:GetName() return self.name end
    function f:IsProtected() return false end
    function f:GetChildren() return unpack(self.children or {}) end
    function f:SetNormalTexture(file) self.file = file end
    function f:SetPushedTexture() end
    function f:SetDisabledTexture() end
    function f:SetScale(s) self.scale = s end
    function f:GetScale() return self.scale or 1 end
    function f:SetAtlas(a) self.atlas = a end
    function f:GetAtlas() return self.atlas end
    function f:GetVertexColor() return 1, 1, 1, 1 end
    function f:GetAlpha() return self.alpha end
    function f:SetScript(event, fn) self.scripts = self.scripts or {} self.scripts[event] = fn
        if event == "OnUpdate" then UPDATERS[#UPDATERS + 1] = self end end
    function f:GetScript(event) return self.scripts and self.scripts[event] end
    function f:HookScript(event, fn) self.hooks = self.hooks or {} self.hooks[event] = fn end
    function f:CreateFontString() local s = Extend(base("FontString", nil, self))
        function s:SetText(t) self.text = t end function s:SetShadowOffset() end function s:SetShadowColor() end return s end
    local createTexture = f.CreateTexture
    function f:CreateTexture(...) return Extend(createTexture(self, ...)) end
    return f
end
function CreateFrame(kind, name, parent)
    local f = Extend(base(kind, name, parent))
    f.objType, f.name = kind, name
    if name then _G[name] = f end
    if parent then parent.children = parent.children or {} table.insert(parent.children, f) end
    return f
end
UIParent = CreateFrame("Frame")

-- The game's minimap: 6 zooms, 0 the furthest, on zoom 2.
Minimap = CreateFrame("Frame", nil, UIParent)
Minimap.strata, Minimap.zoom = "LOW", 2
function Minimap:GetZoom() return self.zoom end
function Minimap:SetZoom(z) self.zoom = z end
function Minimap:GetZoomLevels() return 6 end
Minimap:SetScript("OnMouseUp", function() PINGS = PINGS + 1 end)
-- its own + and - (Minimap.ZoomIn/ZoomOut), where the game's XML puts them off its centre
for key, spec in pairs({ ZoomIn = { 88, -68 }, ZoomOut = { 72, -84 } }) do
    local b = CreateFrame("Button", nil, Minimap)
    function b:GetCenter() return SIZE / 2 + spec[1], SIZE / 2 + spec[2] end
    Minimap[key] = b
end
-- (an error anywhere fails the test: the game would show it, or count it toward "a large number of errors")
function geterrorhandler() return function(err) error(err, 0) end end
-- its ring (this client's art on MinimapBackdrop)
MinimapCompassTexture = Minimap:CreateTexture()
MinimapCompassTexture:SetAtlas("ui-hud-minimap-frame")
local DIAMETERS = { [0] = 1400 / 3, 400, 1000 / 3, 800 / 3, 200, 400 / 3 }
C_Minimap = {
    GetViewRadius = function() return DIAMETERS[Minimap.zoom] / 2 end,
    SetDrawGroundTextures = function(on) GROUND[#GROUND + 1] = on end,
}
function hooksecurefunc(t, name, fn) local orig = t[name] t[name] = function(...) local r = orig(...) fn(...) return r end end
function IsIndoors() return INDOORS end
function GetCVar() return "0" end
function GetCursorPosition() return CURSOR_X, CURSOR_Y end
function IsMouseButtonDown() return BUTTON_DOWN end
C_Timer = { After = function() end }
function IsInRaid() return false end
function GetNumSubgroupMembers() return 0 end
function GetPlayerFacing() return 0 end
GameTooltip_Hide = function() end
RAID_CLASS_COLORS = {}
-- the game's settings panel: WarRoom's page and its checkboxes
OPTIONS = { headers = {}, checkboxes = {} }
Settings = { VarType = { Boolean = "boolean" } }
function Settings.RegisterVerticalLayoutCategory(name)
    OPTIONS.page = name
    return { GetID = function() return 1 end }, { AddInitializer = function(_, i) table.insert(OPTIONS.headers, i) end }
end
function Settings.RegisterAddOnCategory(c) OPTIONS.registered = true end
function Settings.RegisterProxySetting(_, variable, _, name, default, get, set)
    local s = { variable = variable, name = name, default = default }
    function s:GetValue() return get() end
    function s:SetValue(v) set(v) end
    return s
end
function Settings.CreateCheckbox(_, setting) OPTIONS.checkboxes[setting.variable] = setting end
function CreateSettingsListSectionHeaderInitializer(name) return name end
function Tick(seconds)
    local step = 0.05
    for _ = 1, math.max(1, math.floor(seconds / step + 0.5)) do
        for _, f in ipairs(UPDATERS) do if f.scripts.OnUpdate then f.scripts.OnUpdate(f, step) end end
    end
end
"""


def _minimap_env():
    env = _env()
    env.lua.execute(_MINIMAP_WOW)
    env.load("Data/Tiles.lua").load("Core/Pins.lua")
    env.lua.execute("""return function(ns)
        local WR = ns.WR
        WarRoom = WR
        WR.Canvas, WR.Coords, WR.Pins = ns.Canvas, ns.Coords, ns.Pins
        WR.modules, WR.SlashCommands = {}, {}
        function WR.NewModule(name) local m = { name = name } WR.modules[name] = m return m end
        function WR.OnEvent() end
        function WR.AfterCombat(_, fn) fn() return true end
        function WR.RegisterCallback() end
        function WR.Print() end
        function WR.SafeCall(fn, ...) return fn(...) end
        local state = { known = true, continent = 1, x = -2400, y = -400, mapID = 1412 }
        WR.Position = { state = state, Read = function(unit)
            if unit == "player" and state.known then return state.continent, state.x, state.y, "unit" end end }
        WR.db = { global = {}, RegisterNamespace = function(_, _, d) return { profile = d.profile } end }
    end""")(env.ns)
    chunk, err = compile_file(env.lua, ADDONS / "WarRoom" / "Core" / "Options.lua")
    assert chunk is not None, err
    chunk("WarRoom", env.ns)
    for name in ("Minimap.lua", "Marks.lua", "Hub.lua"):
        chunk, err = compile_file(env.lua, ADDONS / "WarRoom_Minimap" / name)
        assert chunk is not None, err
        chunk("WarRoom_Minimap", env.lua.table())
    return env


def test_minimap_under_the_games_on_the_player_at_its_zoom():
    env = _minimap_env()
    run = env.lua.execute("""return function(ns)
        local WR = ns.WR
        local Mini = WR.modules.Minimap
        local out = {}
        WR.Pins.DefineCategory("test", { minimap = true })
        WR.Pins.Add({ continent = 1, x = -2380, y = -400, category = "test", icon = "PIN" })
        Mini.enabled = true
        Mini:OnEnable()
        Tick(0.1)
        local canvas, host = Mini.canvas, Mini.host
        out.shown = host.shown and GROUND[#GROUND] == false and WR.db.global.minimapGroundHidden == true
        out.under = host.strata == "BACKGROUND"
        -- on the player, at the game's zoom: its radius across half the width
        out.view = canvas.continent == 1 and math.abs(canvas.cx + 2400) < 1e-6 and math.abs(canvas.cy + 400) < 1e-6
            and math.abs(canvas.ypp - 2 * (1000 / 3 / 2) / 140) < 1e-9
        -- the terrain drawn through the round shape's mask
        local masked, tiles = 0, 0
        for _, rec in pairs(canvas.tiles) do tiles = tiles + 1 if (rec.tex.masks or 0) >= 1 then masked = masked + 1 end end
        out.masked = tiles > 0 and masked == tiles
        out.pin = false
        for t, file in pairs(textures) do if file == "PIN" and t.shown then out.pin = true end end

        -- (the ring's copy, when ours covers the game's)
        made = {}
        local create = Mini.top.CreateTexture
        Mini.top.CreateTexture = function(...) local t = create(...) made[#made + 1] = t return t end
        -- the wheel out: the game's zooms first, then ours past its furthest, covering the game's
        local wheel = Minimap.scripts.OnMouseWheel
        wheel(Minimap, -1) wheel(Minimap, -1)
        Tick(0.5)
        out.gameOut = Minimap.zoom == 0 and host.strata == "BACKGROUND"
        wheel(Minimap, -1) wheel(Minimap, -1) wheel(Minimap, -1)
        Tick(0.5)
        -- (two steps past the game's furthest, no more; still all terrain; over the game's Minimap, never faded)
        local ring
        for _, t in ipairs(made) do if t.atlas == "ui-hud-minimap-frame" then ring = t end end
        out.ring = ring and ring.shown
        out.oursOut = Minimap.zoom == 0 and Mini.Away() and host.strata == "MEDIUM" and Minimap.alpha == 1
            and host.mouse and host.wheel and host.parent == Minimap and host.level == 2 and host.fixed
            -- (all of ours under LibDBIcon's buttons, MEDIUM 8: map, marks, the ring's copy)
            and canvas.frame.level == 3 and canvas.terrainLayer.level == 4 and canvas.overlay.level == 5
            and Mini.top.level == 6 and canvas.overlay.fixed and Mini.top.fixed
            and math.abs(canvas.ypp - 2 * (1400 / 3 / 2) * 1.25 ^ 2 / 140) < 1e-9 and next(canvas.groups) == nil
        wheel(Minimap, 1) wheel(Minimap, 1)
        Tick(0.5)
        out.backIn = not Mini.Away() and host.strata == "BACKGROUND" and Minimap.zoom == 0 and not host.mouse
            and not ring.shown

        -- a drag: ours off the player, no ping; let go and the pointer away, back by itself
        CURSOR_X, CURSOR_Y = 70, 70
        Minimap.hooks.OnMouseDown(Minimap, "LeftButton")
        CURSOR_X = 100
        Tick(0.05)
        out.dragged = Mini.Away() and canvas.cy > -400
        Minimap.scripts.OnMouseUp(Minimap, "LeftButton")
        out.noPing = PINGS == 0
        Tick(0.5)
        out.stays = Mini.Away() and host.strata == "MEDIUM"
        MOUSE_OVER = false
        Tick(7)
        out.snapped = not Mini.Away() and math.abs(canvas.cy + 400) < 1e-6 and host.strata == "BACKGROUND"
        -- a click on it at the player: the game's own (its ping)
        Minimap.hooks.OnMouseDown(Minimap, "LeftButton")
        Minimap.scripts.OnMouseUp(Minimap, "LeftButton")
        out.ping = PINGS == 1

        -- indoors: the game's own minimap, ground and all
        INDOORS = true
        Tick(0.3)
        out.indoors = not host.shown and GROUND[#GROUND] == true and not WR.db.global.minimapGroundHidden
        INDOORS = false
        Tick(0.3)
        out.outdoors = host.shown and GROUND[#GROUND] == false
        -- the game's minimap hidden: its ground given back at once
        Minimap:Hide() Minimap.hooks.OnHide(Minimap)
        out.hidden = not host.shown and GROUND[#GROUND] == true
        Minimap:Show() Minimap.hooks.OnShow(Minimap)
        out.again = host.shown and GROUND[#GROUND] == false
        -- in an instance (no position)
        WR.Position.state.known, WR.Position.state.inInstance = false, "party"
        Tick(0.3)
        out.instance = not host.shown and GROUND[#GROUND] == true
        return out
    end""")
    out = run(env.ns)
    for key in ("shown", "under", "view", "masked", "pin", "gameOut", "oursOut", "ring", "backIn", "dragged", "noPing", "stays",
                "snapped", "ping", "indoors", "outdoors", "hidden", "again", "instance"):
        assert out[key], key


def test_zoom_buttons_drive_ours_and_the_hub_gathers_addon_buttons():
    env = _minimap_env()
    run = env.lua.execute("""return function(ns)
        local WR = ns.WR
        local Mini = WR.modules.Minimap
        local out = {}
        -- two addons' LibDBIcon buttons on the ring, one hidden by its addon
        local made = {}
        local lib = { objects = {} }
        function lib.RegisterCallback(_, event, fn) made.callback = fn end
        for _, name in ipairs({ "Zeta", "Alpha", "Hidden" }) do
            local b = CreateFrame("Button", nil, Minimap)
            lib.objects[name] = b
            if name == "Hidden" then b:Hide() end
        end
        function LibStub(major) if major == "LibDBIcon-1.0" then return lib end end
        GameTooltip = CreateFrame("Frame")

        Mini.enabled = true
        Mini:OnEnable()
        MOUSE_OVER = true
        Tick(0.1)
        local zin, zout = Mini.zoomButtons[1], Mini.zoomButtons[2]
        out.shown = zin.shown and zout.shown and zin.strata == "MEDIUM" and zin.level == 9
        -- out past the game's furthest with the - button, and back in with the +
        Minimap.zoom = 0
        zout.scripts.OnClick(zout) Tick(0.1)
        out.past = Mini.Away() and zout.enabled
        zout.scripts.OnClick(zout) Tick(0.1)
        out.greyed = Mini.Away() and zout.enabled == false and zin.enabled
        zin.scripts.OnClick(zin) zin.scripts.OnClick(zin) Tick(0.1)
        out.backIn = not Mini.Away() and Minimap.zoom == 0
        zin.scripts.OnClick(zin)
        out.gameIn = Minimap.zoom == 1
        -- the reset: over the +, a step on round the ring; greyed on the player, back from away
        local reset = Mini.resetButton
        local p = reset.point
        local r = math.sqrt(p[4] ^ 2 + p[5] ^ 2)
        out.reset = reset.shown and reset.enabled == false and p[2] == Minimap and p[4] > 88 and p[5] > -68
            and math.abs(r - math.sqrt(88 ^ 2 + 68 ^ 2)) < 0.01
        Minimap.zoom = 0
        zout.scripts.OnClick(zout) Tick(0.1)
        out.resetAway = Mini.Away() and reset.enabled
        reset.scripts.OnClick(reset) Tick(0.1)
        out.resetBack = not Mini.Away() and Minimap.zoom == 0 and reset.enabled == false
        Minimap.zoom = 1
        MOUSE_OVER = false
        Tick(0.1)
        out.hidden = not zin.shown and not zout.shown and not reset.shown

        -- the hub: every button in its column, by name, the hidden one leaving no gap, none put back on the ring
        local column = Mini.hubColumn
        local a, z, h = lib.objects.Alpha, lib.objects.Zeta, lib.objects.Hidden
        out.taken = a.parent == column and z.parent == column and h.parent == column and not a.drag
        out.order = a.point[5] == -2 and z.point[5] == -2 - 33 and column.count == 2
        a:SetPoint("CENTER", Minimap, "CENTER", 100, 0) -- (LibDBIcon putting it back on the ring)
        out.kept = a.point[2] == column
        h:Show()
        out.room = column.count == 3
        -- a button made later
        local late = CreateFrame("Button", nil, Minimap)
        made.callback(nil, late, "Late")
        out.late = late.parent == column and column.count == 4
        -- the hub's own button opens and closes the column
        local hub = Mini.hub
        hub.scripts.OnClick(hub)
        out.open = column.shown
        hub.scripts.OnClick(hub)
        out.closed = not column.shown
        return out
    end""")
    out = run(env.ns)
    for key in ("shown", "past", "greyed", "backIn", "gameIn", "reset", "resetAway", "resetBack", "hidden", "taken", "order", "kept", "room", "late", "open",
                "closed"):
        assert out[key], key


def test_hub_takes_addons_own_buttons_and_its_option_turns_it_off_and_on():
    env = _minimap_env()
    run = env.lua.execute("""return function(ns)
        local WR = ns.WR
        local Mini = WR.modules.Minimap
        local out = {}
        -- a LibDBIcon button, an addon's own button on the rim, and what must stay: a map pin of HereBeDragons' on the
        -- rim, a small unnamed frame, the game's own tracking button
        local lib = { objects = {} }
        function lib.RegisterCallback() end
        function lib:Refresh(name) self.refreshed = name end
        local alpha = CreateFrame("Button", nil, Minimap)
        lib.objects.Alpha = alpha
        local rim = function() return SIZE / 2 + 65, SIZE / 2 end
        local buttonSize = function() return 32, 32 end
        local geared = CreateFrame("Button", "GearedForeverMinimapButton", Minimap)
        geared.GetCenter, geared.GetSize = rim, buttonSize
        geared:SetPoint("CENTER", Minimap, "CENTER", -60, -40)
        geared:RegisterForDrag("LeftButton")
        local pin = CreateFrame("Button", "GatherMatePin1", Minimap)
        pin.GetCenter, pin.GetSize = rim, buttonSize
        local hbd = { minimapPins = { [pin] = {} }, activeMinimapPins = {} }
        local tracking = CreateFrame("Button", "MiniMapTracking", Minimap)
        tracking.GetCenter, tracking.GetSize = rim, buttonSize
        local helper = CreateFrame("Frame", nil, Minimap)
        function LibStub(major, silent)
            if major == "LibDBIcon-1.0" then return lib end
            if major == "HereBeDragons-Pins-2.0" then return hbd end
        end
        GameTooltip = CreateFrame("Frame")

        Mini.enabled = true
        Mini:OnEnable()
        local column = Mini.hubColumn
        out.taken = alpha.parent == column and geared.parent == column and geared.strata == "MEDIUM" and not geared.drag
        out.left = pin.parent == Minimap and tracking.parent == Minimap and helper.parent == Minimap
        -- (Geared Forever placing it on the ring again, as it does when the minimap is resized)
        geared:ClearAllPoints() geared:SetPoint("CENTER", Minimap, "CENTER", 60, 40)
        out.kept = geared.point[2] == column and column.count == 2

        -- WarRoom's options page: a Minimap header and the hub's checkbox
        local setting = OPTIONS.checkboxes.WARROOM_MINIMAP_HUB
        out.page = OPTIONS.page == "WarRoom" and OPTIONS.registered and OPTIONS.headers[1] == "Minimap" and setting
            and setting.default == true and setting:GetValue() == true
        -- off: every button back where it was, at once
        setting:SetValue(false)
        out.off = Mini.db.profile.hub == false and not Mini.hub.shown and alpha.parent == Minimap and lib.refreshed == "Alpha"
            and geared.parent == Minimap and geared.point[4] == -60 and geared.point[5] == -40 and geared.drag
            and setting:GetValue() == false
        geared:SetPoint("CENTER", Minimap, "CENTER", 10, 10)
        out.free = geared.point[4] == 10
        -- on again, from the slash command too
        WR.SlashCommands.minimap("hub")
        out.on = Mini.db.profile.hub and Mini.hub.shown and alpha.parent == column and geared.parent == column
        return out
    end""")
    out = run(env.ns)
    for key in ("taken", "left", "kept", "page", "off", "free", "on"):
        assert out[key], key
