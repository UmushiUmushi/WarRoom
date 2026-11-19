-- What the world map draws over the Canvas: the dark over unexplored ground, the veil round the zone the view is on, the glow over the zone a click
-- would go to, the player's arrow, party and raid members, the pins of Core's list that show on the map, the name of the zone under the pointer, and coordinates (the game's own line under its map
-- is hidden while ours shows: it would read its own map's position).
local WR = WarRoom
local Canvas, Coords, Pins, Position, Zones = WR.Canvas, WR.Coords, WR.Pins, WR.Position, WR.Zones
local Map = WR.Map
local abs, max = math.abs, math.max

local GROUP_INTERVAL = 0.1 -- seconds between moves of the party's dots
local HOVER_INTERVAL = 0.05
local PIN_SIZE = 16

local canvas, overlay
local arrow, label, levels, coords
local dots, pins = {}, {}
local pinList = {}
local sinceGroup, sinceHover = 0, 0

local canaccess = canaccessvalue or function()
	return true
end

-- A texture at a point of a continent's world on the canvas, hidden when it can't be shown there.
local function PlaceAt(region, continent, x, y)
	local dx, dy = canvas:WorldToFrame(x, y, continent)
	local w, h = canvas.frame:GetSize()
	if not dx or abs(dx) > w / 2 + 16 or abs(dy) > h / 2 + 16 then
		region:Hide()
		return false
	end
	region:ClearAllPoints()
	region:SetPoint("CENTER", overlay, "CENTER", dx, dy)
	region:Show()
	return true
end

local function PlaceArrow()
	local s = Position.state
	if not s.known or not PlaceAt(arrow, s.continent, s.x, s.y) then
		arrow:Hide()
		return
	end
	local facing = GetPlayerFacing and GetPlayerFacing()
	if facing and canaccess(facing) then
		arrow:SetRotation(facing)
	end
end

---------------------------------------------------------------------------------------------------
-- The veil round the map the view is on (a zone or city): everything outside it softly dimmed, so its confines
-- show without a line. Media/Veil follows the game's own borders (Data/Zones.lua: the same ground hovering and
-- clicking go by), the zone's cities and lakes inside, pushed out a little so the zone's own edge stays clear and
-- feathered; plain dimming carries on round the texture to past the view. Over the paintings and under the names
-- and the glow, on the world frame so it pans with it, laid out again only when the zoom changes; when the view
-- moves on to another map the old veil fades out as the new one fades in.
---------------------------------------------------------------------------------------------------

local VEIL_COLOR = { 0.05, 0.035, 0.02, 0.45 } -- a dark umber, as much as dims the map outside
local VEIL_FADE = 0.3 -- seconds to fade a veil in or out

local outlineFrame -- (over the paintings: the glow)
local veilFrame
local veils = {} -- two sheets, the one now and the one fading out: { frame, tex, bands, map, target }
local veilKey -- what the veil was last laid out for

local function VeilSheet()
	local sheet = { target = 0 }
	sheet.frame = CreateFrame("Frame", nil, veilFrame)
	sheet.frame:SetAllPoints(veilFrame)
	sheet.frame:SetAlpha(0)
	local r, g, b, a = unpack(VEIL_COLOR)
	sheet.tex = sheet.frame:CreateTexture(nil, "ARTWORK")
	sheet.tex:SetVertexColor(r, g, b, a)
	sheet.bands = {}
	for i = 1, 4 do
		local band = sheet.frame:CreateTexture(nil, "ARTWORK")
		band:SetColorTexture(r, g, b, a)
		sheet.bands[i] = band
	end
	return sheet
end

-- Lays a sheet's veil over a rectangle of the layout, its bands round it out to `reach` past it on every side.
local function LayVeil(sheet, file, left, top, right, bottom, reach)
	local tex, bands = sheet.tex, sheet.bands
	tex:SetTexture(file)
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", veilFrame, "CENTER", left, top)
	tex:SetPoint("BOTTOMRIGHT", veilFrame, "CENTER", right, bottom)
	for _, band in ipairs(bands) do
		band:ClearAllPoints()
	end
	-- (above and below, the full width; left and right, between them: they meet the texture's edges exactly)
	bands[1]:SetPoint("BOTTOMLEFT", tex, "TOPLEFT", -reach, 0)
	bands[1]:SetPoint("TOPRIGHT", tex, "TOPRIGHT", reach, reach)
	bands[2]:SetPoint("TOPLEFT", tex, "BOTTOMLEFT", -reach, 0)
	bands[2]:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", reach, -reach)
	bands[3]:SetPoint("TOPRIGHT", tex, "TOPLEFT")
	bands[3]:SetPoint("BOTTOMLEFT", tex, "BOTTOMLEFT", -reach, 0)
	bands[4]:SetPoint("TOPLEFT", tex, "TOPRIGHT")
	bands[4]:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", reach, 0)
end

local function PlaceVeil()
	local scope = Map.GetScope()
	local continent, rect, file = Zones.Veil(scope or 0)
	local left, top, right, bottom
	if rect then
		left, top = canvas:ToLayout(rect[1], rect[2], continent)
		right, bottom = canvas:ToLayout(rect[3], rect[4], continent)
	end
	local key = left and right and ("%d:%d:%d"):format(scope, canvas.layout, canvas.continent) or "none"
	if key == veilKey then
		return
	end
	veilKey = key
	local now, other = veils[1], veils[2]
	if key == "none" then
		now.target = 0
		return
	end
	if now.map ~= scope then
		-- (another map: the one now fades out, the other sheet fades in over it)
		now.target = 0
		veils[1], veils[2] = other, now
		now = other
		now.map = scope
		now.frame:SetAlpha(0)
	end
	now.target = 1
	local w, h = canvas.frame:GetSize()
	LayVeil(now, file, left, top, right, bottom, 2 * max(w, h) + 64)
end

local function FadeVeils(elapsed)
	for _, sheet in ipairs(veils) do
		local alpha = sheet.frame:GetAlpha()
		if alpha ~= sheet.target then
			local step = elapsed / VEIL_FADE
			alpha = sheet.target > alpha and math.min(sheet.target, alpha + step) or max(sheet.target, alpha - step)
			sheet.frame:SetAlpha(alpha)
			if alpha == 0 then
				sheet.map = nil
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- The glow over the map under the pointer that a click would go to (not the one the view is on), as the game's
-- world map shows it: a dim olive picture of the map's ground added onto the map (Media/Glow, cut to the game's own
-- borders like the veil), over the veil.
---------------------------------------------------------------------------------------------------

local glowTex
local glowMap -- the map glowing (nil: none)
local glowKey -- what the glow was last laid out for

local function PlaceGlow()
	local continent, rect, file
	if glowMap and glowMap ~= Map.GetScope() then
		continent, rect, file = Zones.Glow(glowMap)
	end
	local key = rect and ("%d:%d:%d"):format(glowMap, canvas.layout, canvas.continent) or "none"
	if key == glowKey then
		return
	end
	glowKey = key
	local left, top = rect and canvas:ToLayout(rect[1], rect[2], continent)
	local right, bottom = rect and canvas:ToLayout(rect[3], rect[4], continent)
	if not (left and right) then
		glowTex:Hide()
		return
	end
	glowTex:SetTexture(file)
	glowTex:ClearAllPoints()
	glowTex:SetPoint("TOPLEFT", outlineFrame, "CENTER", left, top)
	glowTex:SetPoint("BOTTOMRIGHT", outlineFrame, "CENTER", right, bottom)
	glowTex:Show()
end

local function SetGlow(mapID)
	if mapID ~= glowMap then
		glowMap = mapID
		PlaceGlow()
	end
end

---------------------------------------------------------------------------------------------------
-- Unexplored ground: the lights out over each piece of a zone's map the player hasn't explored yet (the game hides
-- those pieces; ours stay there to read, in the dark). Each is the game's own drawing of the piece (Veilmap darkens
-- its tiles on the game's map), placed where its zone's map lies, so it follows the mountains and coasts the painted
-- map does; a city's ground is under its zone's piece of it. Media/Fog has them baked together, a continent at a
-- time, so any laid side by side or over each other darken as one sheet: an unexplored zone is one even dark, with
-- no darker bands where pieces overlap (the darkness is in the textures: tinted here, never faded but by the zones'
-- fade). It comes in with the detailed map, over the paintings and the terrain, under the veil. Every continent on
-- Azeroth's map has its own laid, the view's and the others (an island with a map of its own, Zephras Isle, among
-- them). The map's Unexplored setting (Settings.lua) turns it off.
---------------------------------------------------------------------------------------------------

local FOG_TINT = { 0.02, 0.015, 0.01 } -- near black (how dark: zones.py FOG_DARK)
local FOG_PATH = "Interface\\AddOns\\WarRoom\\Media\\Fog\\fog_%d"
local fogFrame
local fogTex = {} -- [overlayID] = texture
local explored = {} -- [uiMapID] = { [key] = true }: the pieces explored (asked of the game once, again on news)
local fogKey -- what the dark was last laid out for

local function Explored(mapID)
	local set = explored[mapID]
	if not set then
		set = {}
		local get = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures
		local ok, list = pcall(get or error, mapID)
		if not ok then
			set.all = true -- (no word from the game: nothing darkened)
		else
			-- (nil for a zone the player has never set foot in: none of it explored)
			for _, info in ipairs(type(list) == "table" and list or {}) do
				local key = info.textureWidth and ("%d:%d:%d:%d"):format(info.textureWidth, info.textureHeight,
					info.offsetX, info.offsetY)
				if key then
					set[key] = true
				end
			end
		end
		explored[mapID] = set
	end
	return set
end

local function PlaceFog()
	local o = canvas.options
	local ypp = canvas.ypp
	-- (with the detailed map: none further out than where it starts, all of it from where it is in)
	local alpha = 0
	if Map.db.profile.unexplored and o.zonesNone and o.zonesFull and ypp < o.zonesNone then
		alpha = ypp <= o.zonesFull and 1 or (o.zonesNone - ypp) / (o.zonesNone - o.zonesFull)
	end
	fogFrame:SetAlpha(alpha)
	fogFrame:SetShown(alpha > 0)
	if alpha <= 0 then
		return
	end
	local key = ("%d:%d"):format(canvas.layout, canvas.continent)
	if key == fogKey then
		return
	end
	fogKey = key
	local wanted = {}
	local continents = { canvas.continent }
	for _, c in ipairs(Canvas.WorldContinents()) do
		if c ~= canvas.continent then
			continents[#continents + 1] = c
		end
	end
	for _, continent in ipairs(continents) do
		for _, piece in ipairs(Zones.Pieces(continent)) do
			local mapID, pieceKey, overlayID = piece[1], piece[2], piece[3]
			local seen = Explored(mapID)
			if not (seen.all or seen[pieceKey]) then
				local left, top = canvas:ToLayout(piece[4], piece[5], continent)
				local right, bottom = canvas:ToLayout(piece[6], piece[7], continent)
				if left and right then
					local tex = fogTex[overlayID]
					if not tex then
						tex = fogFrame:CreateTexture(nil, "ARTWORK")
						tex:SetTexture(FOG_PATH:format(overlayID), nil, nil, "TRILINEAR")
						tex:SetVertexColor(FOG_TINT[1], FOG_TINT[2], FOG_TINT[3], 1)
						fogTex[overlayID] = tex
					end
					tex:ClearAllPoints()
					tex:SetPoint("TOPLEFT", fogFrame, "CENTER", left, top)
					tex:SetPoint("BOTTOMRIGHT", fogFrame, "CENTER", right, bottom)
					tex:Show()
					wanted[overlayID] = true
				end
			end
		end
	end
	for overlayID, tex in pairs(fogTex) do
		if not wanted[overlayID] then
			tex:Hide()
		end
	end
end

-- The Unexplored setting changed: laid out again (or put away).
function Map.RefreshFog()
	fogKey = nil
	if fogFrame then
		PlaceFog()
	end
end

-- The player explored somewhere: asked again, laid out again.
local function ExploredNews()
	wipe(explored)
	fogKey = nil
	if fogFrame and fogFrame:IsVisible() then
		PlaceFog()
	end
end

---------------------------------------------------------------------------------------------------
-- Party and raid
---------------------------------------------------------------------------------------------------

local function Dot(i)
	local dot = dots[i]
	if not dot then
		dot = overlay:CreateTexture(nil, "OVERLAY", nil, 1)
		dot:SetTexture("Interface\\COMMON\\Indicator-Gray")
		dot:SetSize(14, 14)
		dots[i] = dot
	end
	return dot
end

local function PlaceGroup()
	local n = 0
	local raid = IsInRaid()
	local count = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
	for i = 1, count do
		local unit = (raid and "raid" or "party") .. i
		if not UnitIsUnit(unit, "player") then
			local continent, x, y = Position.Read(unit)
			if continent then
				n = n + 1
				local dot = Dot(n)
				local _, class = UnitClass(unit)
				local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
				if color then
					dot:SetVertexColor(color.r, color.g, color.b)
				else
					dot:SetVertexColor(0.4, 0.8, 1)
				end
				PlaceAt(dot, continent, x, y)
			end
		end
	end
	for i = n + 1, #dots do
		dots[i]:Hide()
	end
end

---------------------------------------------------------------------------------------------------
-- Pins
---------------------------------------------------------------------------------------------------

local function PinButton(i)
	local b = pins[i]
	if not b then
		b = CreateFrame("Button", nil, overlay)
		b:SetFrameLevel(overlay:GetFrameLevel() + 1)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		b:SetScript("OnEnter", function(self)
			local pin = self.pin
			if pin and pin.label then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText(pin.label)
				GameTooltip:Show()
			end
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		pins[i] = b
	end
	return b
end

local function PlacePins()
	local n = 0
	local w, h = canvas.frame:GetSize()
	local zoom = 1 / canvas.ypp
	for _, continent in ipairs(canvas:DrawList()) do
		local north, south, west, east = canvas:ViewIn(continent, w, h, 1.05)
		if north then
			Pins.Query(continent, north, west, south, east, "map", zoom, nil, pinList)
			for _, pin in ipairs(pinList) do
				n = n + 1
				local b = PinButton(n)
				local category = Pins.GetCategory(pin.category)
				b.pin = pin
				b.icon:SetTexture(pin.icon or (category and category.icon) or "Interface\\Minimap\\Tracking\\None")
				local size = pin.size or PIN_SIZE
				b:SetSize(size, size)
				PlaceAt(b, continent, pin.x, pin.y)
			end
		end
	end
	for i = n + 1, #pins do
		pins[i]:Hide()
		pins[i].pin = nil
	end
end

---------------------------------------------------------------------------------------------------
-- The zone under the pointer, and coordinates
---------------------------------------------------------------------------------------------------

-- "52.3, 41.8" of world (x, y) on a map, or nil off it.
local function MapCoords(mapID, continent, x, y)
	local u, v = Coords.WorldToMap(mapID, continent, x, y)
	if u and u >= 0 and u <= 1 and v >= 0 and v <= 1 then
		return ("%.1f, %.1f"):format(u * 100, v * 100)
	end
end

local function Hover()
	local player = ""
	local s = Position.state
	if s.known and s.mapID then
		local text = MapCoords(s.mapID, s.continent, s.x, s.y)
		player = text and ("Player  " .. text) or ""
	end
	local mapID, target
	if Map.host:IsMouseOver() then
		local dx, dy = Map.CursorOffset()
		mapID = Map.MapAt(dx, dy, true)
		target = Map.MapAt(dx, dy)
		if mapID then
			local c, x, y = canvas:FrameToContinent(dx, dy)
			local info = C_Map.GetMapInfo(mapID)
			local text = MapCoords(mapID, c, x, y)
			if text then
				player = player .. ("     Cursor  %s  %s"):format(text, info and info.name or "")
			end
		end
	end
	coords:SetText(player)
	SetGlow(target)

	local info = mapID and C_Map.GetMapInfo(mapID)
	if info and info.mapType ~= 2 then -- (not a continent: the zone or city)
		label:SetText(info.name)
		local low, high = C_Map.GetMapLevels and C_Map.GetMapLevels(mapID)
		if low and high and low > 0 then
			levels:SetText(low == high and ("Level %d"):format(low) or ("Level %d-%d"):format(low, high))
		else
			levels:SetText("")
		end
	else
		label:SetText("")
		levels:SetText("")
	end
end

---------------------------------------------------------------------------------------------------
-- Made with the host (Map.lua), placed after every redraw, ticked while shown
---------------------------------------------------------------------------------------------------

function Map.CreateMarks(host, c)
	canvas = c
	overlay = canvas.overlay

	-- (over the paintings and terrain, under the overlay's marks; on the world frame, so it pans with it: the veil
	-- under the names, the glow over them)
	fogFrame = CreateFrame("Frame", nil, canvas.world)
	fogFrame:SetAllPoints(canvas.world)
	fogFrame:SetFrameLevel(overlay:GetFrameLevel() - 4)
	veilFrame = CreateFrame("Frame", nil, canvas.world)
	veilFrame:SetAllPoints(canvas.world)
	veilFrame:SetFrameLevel(overlay:GetFrameLevel() - 3)
	veils[1], veils[2] = VeilSheet(), VeilSheet()
	outlineFrame = CreateFrame("Frame", nil, canvas.world)
	outlineFrame:SetAllPoints(canvas.world)
	outlineFrame:SetFrameLevel(overlay:GetFrameLevel() - 1)
	glowTex = outlineFrame:CreateTexture(nil, "ARTWORK")
	glowTex:SetBlendMode("ADD")
	glowTex:Hide()
	Map.CreateLabels(canvas, overlay:GetFrameLevel() - 2)

	arrow = overlay:CreateTexture(nil, "OVERLAY", nil, 7)
	arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
	arrow:SetSize(32, 32)

	-- (above everything on the overlay, pins included)
	local text = CreateFrame("Frame", nil, overlay)
	text:SetAllPoints(overlay)
	text:SetFrameLevel(overlay:GetFrameLevel() + 10)
	label = text:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	label:SetPoint("TOP", 0, -14)
	label:SetShadowOffset(1, -1)
	levels = text:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	levels:SetPoint("TOP", label, "BOTTOM", 0, -2)
	coords = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	coords:SetPoint("BOTTOMLEFT", 44, 8) -- (right of the settings button)
	coords:SetShadowOffset(1, -1)

	WR.RegisterCallback(Map, "WR_POSITION", function()
		if host:IsVisible() then
			PlaceArrow()
		end
	end)
	WR.OnEvent("MAP_EXPLORATION_UPDATED", ExploredNews)
	WR.RegisterCallback(Map, "WR_PINS_CHANGED", function()
		if host:IsVisible() then
			PlacePins()
		end
	end)
end

function Map.PlaceMarks()
	Map.PlaceLabels()
	PlaceFog()
	PlaceVeil()
	PlaceGlow()
	PlaceArrow()
	PlaceGroup()
	PlacePins()
end

function Map.TickMarks(elapsed)
	FadeVeils(elapsed)
	sinceGroup = sinceGroup + elapsed
	if sinceGroup >= GROUP_INTERVAL then
		sinceGroup = 0
		PlaceArrow() -- (turning in place moves no position)
		PlaceGroup()
	end
	sinceHover = sinceHover + elapsed
	if sinceHover >= HOVER_INTERVAL then
		sinceHover = 0
		Hover()
	end
end
