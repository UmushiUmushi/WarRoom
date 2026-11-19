-- What the minimap draws on its map: the pins of Core's list that show on the minimap (always: they are ours, placed
-- from their world position, right at any zoom and away from the player too), and, while the map is away from the
-- game's view (its own icons covered), the player's arrow and the party in their place, and the minimap's ring drawn
-- again over ours. (Back to the player: right-click, or by itself. The game's own coordinates line under the minimap
-- stays: none of ours.)
local WR = WarRoom
local Canvas, Pins, Position = WR.Canvas, WR.Pins, WR.Position
local Mini = WR.Minimap

local abs = math.abs

local PIN_SIZE = 12
local GROUP_INTERVAL = 0.1 -- seconds between moves of the party's dots

-- The game minimap's ring art, by the names it has had (this client draws MinimapCompassTexture).
local RING_ART = { "MinimapCompassTexture", "MinimapBorder", "MinimapBorderTop", "MinimapNorthTag" }

local canvas, overlay
local top, arrow
local dots, pins, pinList, rings = {}, {}, {}, {}
local sinceGroup = 0

local canaccess = canaccessvalue or function()
	return true
end

-- Whether an offset from the map's centre, `size` across, lies inside its shape.
local function Inside(dx, dy, size)
	local w, h = canvas.frame:GetSize()
	if Mini.Shape() == Canvas.SQUARE then
		return abs(dx) <= (w - size) / 2 and abs(dy) <= (h - size) / 2
	end
	local r = (math.min(w, h) - size) / 2
	return dx * dx + dy * dy <= r * r
end

-- A region at a point of a continent's world on the map, hidden when it can't be shown there.
local function PlaceAt(region, continent, x, y, size)
	local dx, dy = canvas:WorldToFrame(x, y, continent)
	if not dx or not Inside(dx, dy, size) then
		region:Hide()
		return false
	end
	region:ClearAllPoints()
	region:SetPoint("CENTER", overlay, "CENTER", dx, dy)
	region:Show()
	return true
end

local function PlaceArrow()
	local p = Mini.player
	if not (Mini.Away() and p.continent and PlaceAt(arrow, p.continent, p.x, p.y, 8)) then
		arrow:Hide()
		return
	end
	local facing = GetPlayerFacing and GetPlayerFacing()
	if facing and canaccess(facing) then
		arrow:SetRotation(facing)
	end
end

local function Dot(i)
	local dot = dots[i]
	if not dot then
		dot = overlay:CreateTexture(nil, "OVERLAY", nil, 1)
		dot:SetTexture("Interface\\COMMON\\Indicator-Gray")
		dot:SetSize(10, 10)
		Canvas.Unsnap(dot)
		dots[i] = dot
	end
	return dot
end

local function PlaceGroup()
	local n = 0
	if Mini.Away() then
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
					PlaceAt(dot, continent, x, y, 6)
				end
			end
		end
	end
	for i = n + 1, #dots do
		dots[i]:Hide()
	end
end

local function Pin(i)
	local t = pins[i]
	if not t then
		t = overlay:CreateTexture(nil, "ARTWORK")
		Canvas.Unsnap(t)
		pins[i] = t
	end
	return t
end

local function PlacePins()
	local n = 0
	local w, h = canvas.frame:GetSize()
	local zoom = 1 / canvas.ypp
	for _, continent in ipairs(canvas:DrawList()) do
		local north, south, west, east = canvas:ViewIn(continent, w, h, 1.05)
		if north then
			Pins.Query(continent, north, west, south, east, "minimap", zoom, nil, pinList)
			for _, pin in ipairs(pinList) do
				n = n + 1
				local t = Pin(n)
				local category = Pins.GetCategory(pin.category)
				t:SetTexture(pin.icon or (category and category.icon) or "Interface\\Minimap\\Tracking\\None")
				local size = pin.minimapSize or PIN_SIZE
				t:SetSize(size, size)
				PlaceAt(t, continent, pin.x, pin.y, size)
			end
		end
	end
	for i = n + 1, #pins do
		pins[i]:Hide()
	end
end

---------------------------------------------------------------------------------------------------
-- Made with the host (Minimap.lua), placed after every redraw, ticked while shown
---------------------------------------------------------------------------------------------------

function Mini.CreateMarks(host, c)
	canvas = c
	overlay = canvas.overlay

	arrow = overlay:CreateTexture(nil, "OVERLAY", nil, 7)
	arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
	arrow:SetSize(28, 28)
	arrow:Hide()
	Canvas.Unsnap(arrow)

	-- (the ring's copy: over our map and its marks, under other addons' minimap buttons: Minimap.lua's HOST_LEVEL)
	top = CreateFrame("Frame", nil, host)
	top:SetAllPoints(host)
	Canvas.FixLevel(top, host:GetFrameLevel() + 4)
	Mini.top = top

	WR.RegisterCallback(Mini, "WR_PINS_CHANGED", function()
		if host:IsVisible() then
			PlacePins()
		end
	end)
end

-- While ours covers the game's Minimap: the Minimap's ring (its border art, whichever this client draws) again over
-- our map, as it is over the game's. The same art in the same place: nothing of the game's is touched.
function Mini.CoverMarks(cover)
	for i, name in ipairs(RING_ART) do
		local art, copy = _G[name], rings[i]
		if cover and art and art.IsVisible and art:IsVisible() then
			if not copy then
				copy = top:CreateTexture(nil, "OVERLAY", nil, i)
				rings[i] = copy
			end
			local atlas = art.GetAtlas and art:GetAtlas()
			if atlas then
				copy:SetAtlas(atlas)
			else
				copy:SetTexture(art:GetTexture())
				copy:SetTexCoord(art:GetTexCoord())
			end
			copy:SetVertexColor(art:GetVertexColor())
			copy:SetAlpha(art:GetAlpha())
			copy:ClearAllPoints()
			copy:SetAllPoints(art)
			copy:Show()
		elseif copy then
			copy:Hide()
		end
	end
end

function Mini.PlaceMarks()
	PlacePins()
	PlaceArrow()
	PlaceGroup()
end

function Mini.TickMarks(elapsed)
	sinceGroup = sinceGroup + elapsed
	if sinceGroup >= GROUP_INTERVAL then
		sinceGroup = 0
		PlaceArrow() -- (turning in place moves no position)
		PlaceGroup()
	end
end
