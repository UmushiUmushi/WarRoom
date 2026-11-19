-- WarRoom World Map (module 2): WarRoom's map inside the game's own world map window, in place of the map in it.
-- The window stays the game's: its breadcrumb and zone menus, quest log, maximise button, close key and its fade
-- while the player moves. It opens on the player, close in; picking a map in the game's breadcrumb or menus frames
-- that map on ours; clicking a zone on ours frames it, right-clicking goes back out. The map the view is on (its
-- scope: the zone at its centre while zoomed in on it, else the continent, else Azeroth) stands out (the map round it dimmed), and the game's
-- window is kept on it (out of combat; in a fight, once it ends).
--
-- How much of each layer shows is set from the window's size: all of Azeroth is one painted sheet; a continent fit
-- to the window, its own painting (the zones' borders at a glance); zoomed on into the continent, the detailed
-- painted map with the zones' big banners for their cities; nearing a city's zone framed, the city maps in place of
-- those banners; and only closer in than a city framed, the terrain.
--
-- Of the game's map only two things are changed: its map (WorldMapFrame:SetMapID, as its own buttons do) and the
-- frame level of its buttons over the map, raised over ours. Its map still draws under ours, and a map ours can't
-- draw (one with no place in the world) shows the game's own.
--   /wr map    WarRoom's map or the game's in the world map window
local WR = WarRoom
local Canvas, Coords, Zones = WR.Canvas, WR.Coords, WR.Zones

local Map = WR.NewModule("Map")
WR.Map = Map

local abs, max, min, huge = math.abs, math.max, math.min, math.huge

local defaults = { profile = { replace = true, canvas = {}, fades = {}, terrainAlways = false, unexplored = true } }

-- Over the game's map icons (their frame levels start at 2000) and under its buttons, raised to BUTTON_LEVEL.
local HOST_LEVEL, BUTTON_LEVEL = 6000, 6100
local ZOOM_STEP = 1.2
local MIN_YPP = 0.3
local FIT_PAD = 1.04 -- a framed map's margin
local OUT_OF_SCOPE = 1.25 -- zoomed out this many times past a map's fit: no longer on it
local CLICK_SLOP = 4 -- UI units the pointer may move and still click
-- Azeroth's painting has a torn parchment border: this much of its width and height on each side stays out of view.
local WORLD_INSET_U, WORLD_INSET_V = 0.03, 0.045

local host, canvas
local scope -- the uiMap the view is on (the game's map too, once it could be set)
local fitted -- the view is still the framed one (not zoomed or panned since): kept framed as the window resizes
local fresh = true -- the game's window has just opened: ours opens on the player
local ourChange -- the map we are setting the game's map to (its OnMapChanged is ours, not the player's)
local drag -- { x, y, lastX, lastY, moved } while the left button is down
local coordsPanel -- the game's coordinates under its map (for its own map's position): hidden under ours

function Map:OnEnable()
	self.db = WR.db:RegisterNamespace("Map", defaults)
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_WorldMap")
	if WorldMapFrame or loaded then
		Map.Hook()
	else
		WR.OnEvent("ADDON_LOADED", function(_, name)
			if name == "Blizzard_WorldMap" then
				Map.Hook()
			end
		end)
	end
end

---------------------------------------------------------------------------------------------------
-- Maps and views
---------------------------------------------------------------------------------------------------

-- Whether the view is on Azeroth's map (both continents in one view).
local function OnWorld()
	return canvas.continent and Canvas.WorldRect(canvas.continent) ~= nil
end

-- The part of Azeroth's painting that may show (its torn border never), in the yards of continent `c`.
local function InnerWorld(c)
	local rect = Canvas.WorldRect(c)
	if not rect then
		return nil
	end
	local du, dv = rect.width * WORLD_INSET_U, rect.height * WORLD_INSET_V
	return Coords.NewRect(c, rect.top - dv, rect.left - du, rect.bottom + dv, rect.right + du)
end
Map.InnerWorld = InnerWorld

-- The world rectangle a map is framed on: its own; for Azeroth's map, Azeroth's in the yards of the continent shown.
local function MapRect(mapID)
	if mapID == Canvas.WORLD_MAP then
		local c = canvas and canvas.continent
		if not (c and Canvas.WorldRect(c)) then
			c = Canvas.WorldContinents()[1]
		end
		return c and InnerWorld(c)
	end
	return mapID and Coords.GetMapRect(mapID)
end

-- Whether ours can draw a map: one with a world rectangle on a continent there is terrain or a painting of.
local function Drawable(mapID)
	local rect = MapRect(mapID)
	return rect and (Canvas.TileData(rect.continent) or Canvas.ArtMapFor(rect.continent)) and true or false
end

local function Parent(mapID)
	local info = mapID and C_Map.GetMapInfo(mapID)
	local parent = info and info.parentMapID
	return parent and parent ~= 0 and parent or nil
end

-- Yards per UI unit that show a whole rectangle in the canvas.
local function FitYpp(rect)
	local w, h = canvas.frame:GetSize()
	return max(rect.width / max(w, 1), rect.height / max(h, 1)) * FIT_PAD
end

-- Yards per UI unit at which a rectangle covers the whole canvas.
local function CoverYpp(rect)
	local w, h = canvas.frame:GetSize()
	return min(rect.width / max(w, 1), rect.height / max(h, 1))
end

-- Zoomed out no further than Azeroth's painting covering the window (or, off it, the continent's map and a bit):
-- in a continent's yards (the view's by default; each is at its own scale on Azeroth's map).
local function MaxYpp(continent)
	continent = continent or canvas.continent
	local world = continent and InnerWorld(continent)
	if world then
		return CoverYpp(world)
	end
	local art = continent and Canvas.ArtMapFor(continent)
	local rect = art and Coords.GetMapRect(art)
	return rect and FitYpp(rect) * 1.5 or 200
end

-- Shows (x, y) of a continent at `ypp`, kept inside Azeroth's painting on the world map.
local function SetView(continent, x, y, ypp)
	ypp = min(MaxYpp(continent), max(MIN_YPP, ypp or canvas.ypp))
	local inner = InnerWorld(continent)
	if inner then
		local w, h = canvas.frame:GetSize()
		local halfH, halfW = h / 2 * ypp, w / 2 * ypp
		local function Clamp(v, low, high)
			return low > high and (low + high) / 2 or min(high, max(low, v))
		end
		x = Clamp(x, inner.bottom + halfH, inner.top - halfH)
		y = Clamp(y, inner.right + halfW, inner.left - halfW)
	end
	canvas:SetView(continent, x, y, ypp)
end

-- A zone's or city's own ground (its outline's box), as a map rect; nil for other maps.
local groundRects = {}
local function GroundRect(mapID)
	if groundRects[mapID] == nil then
		local continent, rings = Zones.Outline(mapID)
		local rect = false
		if rings then
			local top, bottom, left, right = -huge, huge, -huge, huge
			for _, ring in ipairs(rings) do
				for i = 1, #ring, 2 do
					top, bottom = max(top, ring[i]), min(bottom, ring[i])
					left, right = max(left, ring[i + 1]), min(right, ring[i + 1])
				end
			end
			rect = { continent = continent, top = top, bottom = bottom, left = left, right = right,
				width = left - right, height = top - bottom }
		end
		groundRects[mapID] = rect
	end
	return groundRects[mapID] or nil
end

-- Frames a map: the view shows all of it. A zone or city is framed by its own ground, and never further out than
-- where the detailed map is all in (a big zone, the Barrens, then fills the window instead, from its middle).
function Map.Frame(mapID)
	local rect = MapRect(mapID)
	if not rect then
		return
	end
	scope, fitted = mapID, true
	local w, h = canvas.frame:GetSize()
	if w <= 1 or h <= 1 then
		return -- (not laid out yet: OnSizeChanged frames it)
	end
	local ground = GroundRect(mapID)
	if ground and ground.continent == rect.continent then
		local o = canvas.options
		local ypp = min(FitYpp(ground), o.zonesFull or huge, o.seaFull or huge)
		SetView(rect.continent, (ground.top + ground.bottom) / 2, (ground.left + ground.right) / 2, ypp)
		return
	end
	SetView(rect.continent, (rect.top + rect.bottom) / 2, (rect.left + rect.right) / 2, FitYpp(rect))
end

-- The continent map (Kalimdor's, the Eastern Kingdoms'...) holding a point of a continent, or nil.
local function ContinentMapAt(c, x, y)
	local cont = Canvas.ArtMapFor(c)
	local rect = cont and Coords.GetMapRect(cont)
	if rect and x <= rect.top and x >= rect.bottom and y <= rect.left and y >= rect.right then
		return cont
	end
end

-- The map at an offset from the canvas's centre: the deepest one (its zone or city, else its continent) with
-- `deepest`, else the one a click there goes to from the map the view is on (a continent from Azeroth's map, else
-- the zone or city). nil out at sea.
function Map.MapAt(dx, dy, deepest)
	local c, x, y = canvas:FrameToContinent(dx, dy)
	local zone = Zones.At(c, x, y)
	if deepest then
		return zone or ContinentMapAt(c, x, y)
	end
	if scope == Canvas.WORLD_MAP then
		return ContinentMapAt(c, x, y)
	end
	return zone
end

-- The map the view is on now: Azeroth while its one sheet shows, else the zone (or city) at its centre while
-- zoomed in on it, else its continent. Out at sea, a zone it was on is kept while zoomed in on it.
local function ScopeOfView()
	local c, x, y = canvas:FrameToContinent(0, 0)
	local ypp = canvas.ypp
	local function Fits(id)
		local rect = id and MapRect(id)
		return rect and ypp <= FitYpp(rect) * OUT_OF_SCOPE
	end
	if OnWorld() and ypp >= (canvas.options.continentNone or huge) then
		return Canvas.WORLD_MAP -- (Azeroth's one sheet showing)
	end
	local zone = Zones.At(c, x, y)
	if zone then
		if Fits(zone) then
			return zone
		end
		local outer = Zones.ZoneOf(zone)
		if outer ~= zone and Fits(outer) then
			return outer
		end
	elseif scope and scope ~= Canvas.WORLD_MAP and Zones.Outline(scope) and Fits(scope) then
		return scope
	end
	local cont = ContinentMapAt(c, x, y) or Canvas.ArtMapFor(canvas.continent)
	if cont and (Fits(cont) or not OnWorld()) then
		return cont
	end
	return OnWorld() and Canvas.WORLD_MAP or cont
end

---------------------------------------------------------------------------------------------------
-- How much of each layer shows, from the window's size
---------------------------------------------------------------------------------------------------

-- Each fade is a multiple of a zoom the window gives (yards per UI unit that fit something to it), so the same
-- multiples hold at any window size:
--   world      Azeroth's painting covering the window (as far out as the map goes)
--   continent  a continent framed (the smallest such zoom of them)
--   cityZone   the zone holding a city framed (the largest such zoom of them: Mulgore)
--   city       a city framed (the smallest: Thunder Bluff)
-- The phases going in: Azeroth's one sheet; the continent's own painting (the zones at a glance); on into the
-- continent, the detailed painted map with its sea paper and the zones' big banners for their cities; nearing a
-- city's zone, the city maps in place of those banners; closer than a city, the terrain.
Map.FADES = {
	{ key = "continentNone", ref = "world", factor = 0.871 },
	{ key = "continentFull", ref = "continent", factor = 0.888 },
	{ key = "zonesNone", ref = "continent", factor = 0.352 },
	{ key = "zonesFull", ref = "continent", factor = 0.228 },
	{ key = "seaNone", ref = "continent", factor = 0.352 },
	{ key = "seaFull", ref = "continent", factor = 0.228 },
	{ key = "citiesNone", ref = "cityZone", factor = 0.595 },
	{ key = "citiesFull", ref = "cityZone", factor = 0.387 },
	{ key = "terrainNone", ref = "city", factor = 0.98 },
	{ key = "terrainFull", ref = "city", factor = 0.59 },
}

-- The zooms the fades are multiples of (see Map.FADES), for the window as it is; nil before it is laid out.
function Map.FadeRefs()
	if not canvas then
		return nil
	end
	local w, h = canvas.frame:GetSize()
	if w <= 1 or h <= 1 then
		return nil
	end
	local function Fit(id)
		local rect = id and Coords.GetMapRect(id)
		return rect and FitYpp(rect)
	end
	local refs = { world = huge, continent = huge, cityZone = 0, city = huge }
	for _, c in ipairs(Canvas.WorldContinents()) do
		local inner = InnerWorld(c)
		refs.world = min(refs.world, inner and CoverYpp(inner) or huge)
		local art = not Canvas.IsIsland(c) and Canvas.ArtMapFor(c)
		refs.continent = min(refs.continent, Fit(art) or huge)
	end
	for cityID, zoneID in Zones.Cities() do
		refs.cityZone = max(refs.cityZone, Fit(zoneID) or 0)
		refs.city = min(refs.city, Fit(cityID) or huge)
	end
	for k, v in pairs(refs) do
		if v == huge or v == 0 then
			refs[k] = nil
		end
	end
	return refs
end

-- A fade's multiple: the player's (the transitions bar's, saved), else the default.
function Map.FadeFactor(fade)
	local own = Map.db.profile.fades
	return own and own[fade.key] or fade.factor
end

local function ApplyFades()
	local refs = Map.FadeRefs()
	if not refs then
		return
	end
	local fades = {}
	for _, fade in ipairs(Map.FADES) do
		local ref = refs[fade.ref]
		if ref then
			fades[fade.key] = ref * Map.FadeFactor(fade)
		end
	end
	-- (a layer is never full further out than it starts)
	for _, layer in ipairs({ "continent", "zones", "sea", "cities", "terrain" }) do
		local none, full = fades[layer .. "None"], fades[layer .. "Full"]
		if none and full and full > none then
			fades[layer .. "Full"] = none
		end
	end
	-- (the player's own numbers, when set, win)
	for k, v in pairs(Map.db.profile.canvas) do
		fades[k] = v
	end
	-- (the transitions as set, for the transitions bar; the terrain setting puts the terrain in at every zoom)
	Map.fades = fades
	if Map.db.profile.terrainAlways then
		local forced = {}
		for k, v in pairs(fades) do
			forced[k] = v
		end
		forced.terrainFull, forced.terrainNone = huge, huge
		fades = forced
	end
	canvas:SetOptions(fades)
end
Map.ApplyFades = ApplyFades

---------------------------------------------------------------------------------------------------
-- The game's map
---------------------------------------------------------------------------------------------------

local function GamepadUI()
	return InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled()
end

-- Sets the game's map to the one ours is on, now or once a fight ends (the game's map, its breadcrumb and quest log
-- follow it). Never with the game's controller UI on, where an addon changing it is blocked.
local function SetGameMap(id)
	if not id or GamepadUI() then
		return
	end
	WR.AfterCombat("map:game", function()
		local wm = WorldMapFrame
		if wm:IsShown() and scope == id and wm:GetMapID() ~= id then
			ourChange = id
			pcall(wm.SetMapID, wm, id)
			ourChange = nil
		end
	end)
end

-- The view moved by the player (dragged or zoomed): on the map at its centre now.
local function FollowView()
	local now = ScopeOfView()
	if now and now ~= scope then
		scope = now
		SetGameMap(now)
		Map.PlaceMarks()
	end
end

-- The zooms the map goes between: (furthest out, closest in) in yards per UI unit.
function Map.ZoomRange()
	return MaxYpp(), MIN_YPP
end

-- Zooms the map to `ypp`, about the view's centre.
function Map.ZoomTo(ypp)
	if canvas and canvas.continent then
		fitted = false
		SetView(canvas.continent, canvas.cx, canvas.cy, ypp)
		FollowView()
	end
end

-- The game's buttons over its map (the floor menu, quest log toggle...) over ours. Never a protected one, never in
-- a fight.
local function RaiseButtons()
	WR.AfterCombat("map:buttons", function()
		local strata = host:GetFrameStrata()
		for _, f in ipairs(WorldMapFrame.overlayFrames or {}) do
			if not (f.IsProtected and f:IsProtected()) and f:GetFrameStrata() == strata and f:GetFrameLevel() < BUTTON_LEVEL then
				f:SetFrameLevel(BUTTON_LEVEL)
			end
			if f.PlayerCoords and f.CursorCoords then
				coordsPanel = f
			end
		end
		if coordsPanel then
			coordsPanel:SetShown(not host:IsShown())
		end
	end)
end

local function Active()
	return Map.enabled and Map.db.profile.replace
end

local CreateHost

-- Opens on the player, close in: all terrain (on the map the game opened on, the player's zone), if the player is somewhere ours
-- draws; else frames the game's map.
local function OpenOnPlayer(id)
	local s = WR.Position.state
	if s.known and (Canvas.TileData(s.continent) or Canvas.ArtMapFor(s.continent)) then
		scope, fitted = id, false
		SetView(s.continent, s.x, s.y, canvas.options.terrainFull)
		FollowView()
		return
	end
	Map.Frame(id)
end

-- Ours over the game's map, or not, for the map the game's window is on: opened on the player when the window has
-- just opened, else framed on the map picked there.
local function Refresh()
	local wm = WorldMapFrame
	if not (wm and wm:IsShown()) then
		return
	end
	local id = wm:GetMapID()
	local on = Active() and Drawable(id)
	if on and not host then
		CreateHost()
	end
	if not host then
		return
	end
	host:SetShown(on)
	RaiseButtons()
	if on then
		ApplyFades()
		if fresh then
			fresh = false
			OpenOnPlayer(id)
		else
			Map.Frame(id)
		end
	end
end
Map.Refresh = Refresh

function Map.Hook()
	local wm = WorldMapFrame
	if Map.hooked or not wm then
		return
	end
	Map.hooked = true
	wm:HookScript("OnShow", Refresh)
	wm:HookScript("OnHide", function()
		fresh = true
	end)
	hooksecurefunc(wm, "OnMapChanged", function()
		-- (the game sets its map as its window opens, before OnShow: that one is the opening's)
		if wm:GetMapID() ~= ourChange and not fresh then
			Refresh()
		end
	end)
	Refresh()
end

---------------------------------------------------------------------------------------------------
-- Pointer
---------------------------------------------------------------------------------------------------

local function CursorOffset()
	local x, y = GetCursorPosition()
	local scale = canvas.frame:GetEffectiveScale()
	local cx, cy = canvas.frame:GetCenter()
	return x / scale - cx, y / scale - cy
end
Map.CursorOffset = CursorOffset

local function ClickAt(dx, dy)
	local target = Map.MapAt(dx, dy)
	if target and target ~= scope and Drawable(target) then
		Map.Frame(target)
		SetGameMap(target)
		Map.PlaceMarks()
	end
end

-- Back out: from a city to its zone, a zone to its continent, a continent to Azeroth.
local function GoUp()
	local parent = scope and Zones.ZoneOf(scope)
	if parent == scope then
		parent = Parent(scope)
	end
	if parent and Drawable(parent) then
		Map.Frame(parent)
		SetGameMap(parent)
		Map.PlaceMarks()
	end
end

local function OnMouseDown(_, button)
	if button == "LeftButton" then
		local x, y = CursorOffset()
		drag = { x = x, y = y, lastX = x, lastY = y, moved = false }
	end
end

local function OnMouseUp(_, button)
	if button == "LeftButton" then
		local d = drag
		drag = nil
		if d and not d.moved then
			ClickAt(CursorOffset())
		elseif d then
			FollowView()
		end
	elseif button == "RightButton" then
		GoUp()
	end
end

local function OnMouseWheel(_, delta)
	local ypp = canvas.ypp * (delta > 0 and 1 / ZOOM_STEP or ZOOM_STEP)
	ypp = min(MaxYpp(), max(MIN_YPP, ypp))
	-- (the point under the pointer stays there)
	local mx, my = CursorOffset()
	local wx, wy = canvas:FrameToWorld(mx, my)
	fitted = false
	SetView(canvas.continent, wx - my * ypp, wy + mx * ypp, ypp)
	FollowView()
end

local function OnUpdate(_, elapsed)
	local d = drag
	if d then
		local x, y = CursorOffset()
		if not d.moved and abs(x - d.x) + abs(y - d.y) > CLICK_SLOP then
			d.moved, fitted = true, false
		end
		if d.moved and (x ~= d.lastX or y ~= d.lastY) then
			local cx, cy = canvas:FrameToWorld(d.lastX - x, d.lastY - y)
			d.lastX, d.lastY = x, y
			SetView(canvas.continent, cx, cy)
		end
	end
	Map.TickMarks(elapsed)
end

---------------------------------------------------------------------------------------------------
-- The frame over the game's map
---------------------------------------------------------------------------------------------------

function CreateHost()
	local wm = WorldMapFrame
	local box = wm.ScrollContainer or (wm.GetCanvasContainer and wm:GetCanvasContainer()) or wm
	host = CreateFrame("Frame", nil, box)
	host:SetAllPoints(box)
	host:SetFrameLevel(HOST_LEVEL)
	host:EnableMouse(true)
	host:EnableMouseWheel(true)
	Map.host = host

	local options = { world = true }
	for k, v in pairs(Map.db.profile.canvas) do
		options[k] = v
	end
	canvas = Canvas.New(host, options)
	Map.canvas = canvas
	canvas:SetOnUpdate(function()
		Map.PlaceMarks()
	end)

	host:SetScript("OnMouseDown", OnMouseDown)
	host:SetScript("OnMouseUp", OnMouseUp)
	host:SetScript("OnMouseWheel", OnMouseWheel)
	host:SetScript("OnUpdate", OnUpdate)
	host:SetScript("OnSizeChanged", function()
		ApplyFades()
		if fitted and scope then
			Map.Frame(scope)
		elseif canvas.continent then
			SetView(canvas.continent, canvas.cx, canvas.cy)
		end
	end)
	host:SetScript("OnHide", function()
		drag = nil
	end)
	Map.CreateMarks(host, canvas)
	Map.CreateTransitions(host)
	Map.CreateSettings(host)
end

function Map.GetScope()
	return scope
end

WR.SlashCommands.map = function()
	local profile = Map.db.profile
	profile.replace = not profile.replace
	WR.Print("world map: %s", profile.replace and "WarRoom's" or "the game's")
	if host and not profile.replace then
		host:Hide()
		if coordsPanel then
			coordsPanel:Show()
		end
	end
	Refresh()
end
