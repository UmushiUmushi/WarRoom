-- Canvas: draws a view of one continent into a frame. The world map, the minimap and the cave and dungeon views
-- are all canvases with different views.
--
-- A view is a continent, a centre (world x, y) and a zoom in yards per UI unit ("ypp"). Layers, bottom to top:
--   sea       a plain colour under everything: the terrain's own deep-ocean colour, so faded coasts melt into it
--   terrain   the minimap textures (Data/Tiles.lua); tiles on the edge of the land fade into the sea through the
--             masks in Media/Fade. Always opaque: the paintings above fade out to show it, so the land and the
--             sea beyond it change together at every zoom.
--   painted   everything painted, faded out over the terrain as you zoom in close:
--     sea       the map's sea (Data/MapArt.lua's, OpenMap's textures): its colour, and its paper tiled live so it
--               stays sharp at every zoom; shown as the continent's own ocean fades off it
--     art       the game's painted continent map: all of it when zoomed far out; its ocean stays over the sea
--               until you are close
--     detailed  the detailed painted map (Media/Bake), faded in over the continent map as you zoom in:
--                 hatching  the coasts' wave strokes, tiled live through each continent's coastal band
--                 tiles     every zone's painting stitched into one seamless map, baked offline by OpenMap's renderer
--                           (tools/warroom_tools/mapart.py), clear over the open sea; at three sizes, the coarsest
--                           that is as sharp as the screen shown, each file loaded only while it is in view
--                 cities    the city maps, cut down to the city, faded in by a zoom of their own
--                 banners   the zones' name banners for their cities, over those, giving way to the city maps
--                           as they come in
--   overlay   a frame over the rest for whatever the owner adds (lines, pins), placed with WorldToFrame
--
-- With the `world` option (the world map), the continents of Azeroth's map (uiMap 947) are drawn side by side as
-- they lie on it, each through a scale and shift from its own yards into the view's continent's (Canvas.Convert),
-- and the view's continent becomes whichever one its centre is over. Far out, Azeroth's own painting is the one sheet
-- for the whole world; zoomed in, each continent's own painting comes in over it, cut down to its land and coast (the
-- sea stays Azeroth's). Both are OpenMap's copies cleaned of their lettering (Media/Map: `warroom worldart`), the
-- names lettered live by the world map. An island the game puts on Azeroth's map from a map of its own (Zephras
-- Isle) is drawn with them, its painting cut down to the island, at every zoom.
--
-- Panning moves one frame (`world`) that holds the layers. Textures are laid out again only when the zoom changes.
-- Every edge lands on a whole screen pixel (the world frame too), so neighbouring textures never show a seam.
local _, ns = ...
local WR = ns.WR
local Coords = ns.Coords

local Canvas = {}
ns.Canvas = Canvas
WR.Canvas = Canvas
-- The names the world map letters over its painted sheets (Data/Labels.lua, OpenMap's).
WR.MapLabels = ns.MapLabels

local floor, ceil, max, min, huge = math.floor, math.ceil, math.max, math.min, math.huge
local TILE = Coords.TILE_YARDS
local MEDIA = "Interface\\AddOns\\WarRoom\\Media\\"
local FADE_PATH = MEDIA .. "Fade\\fade_"
-- Terrain textures (512 px) are sampled half a texel in from their edges, so filtering never reaches past them.
local INSET = 0.5 / 512

-- The minimap textures' deep ocean (sampled from the game's files: about 3, 5, 6 of 255).
Canvas.SEA_COLOR = { 0.012, 0.02, 0.024 }
-- Tiles started per frame; the rest follow on the next frames.
Canvas.NEW_TILES_PER_FRAME = 96
-- The painted map's tiles: a size shows once its pixels are no bigger than this many screen pixels (else the next
-- finer one does), and the next finer one is loaded (hidden) from this many times that, so it is in when it shows.
Canvas.PAINT_LOD = 1
Canvas.PAINT_WARM = 1.5

Canvas.defaults = {
	art = true, -- the painted continent map when zoomed far out
	continentFull = 28, -- world map: the continents' own paintings fully over Azeroth's at this zoom and closer
	continentNone = 33, -- world map: Azeroth's painting alone at this zoom and further out
	zones = true, -- the detailed painted map
	zonesFull = 20, -- detailed map fully shown at this zoom (yards per UI unit) and closer
	zonesNone = 32, -- detailed map gone at this zoom and further out
	sea = true, -- the map's sea paper, in place of the continent's ocean when zoomed in
	seaFull = 8, -- the continent's ocean gone (the sea paper in its place) at this zoom and closer
	seaNone = 12, -- the continent's ocean whole at this zoom and further out
	terrain = true,
	fade = true, -- soften the land's outer edge into the sea
	terrainFull = 3, -- terrain fully shown at this zoom and closer (the paintings gone)
	terrainNone = 6, -- terrain hidden under the paintings at this zoom and further out
	cities = true, -- the city maps
	citiesFull = 8, -- city maps fully shown at this zoom and closer (in place of their zone's banner)
	citiesNone = 12, -- city maps gone at this zoom and further out
	margin = 1, -- extra tiles kept around the view
	world = false, -- every continent on Azeroth's map in one view, with Azeroth's painting under them
}

-- Azeroth's map: the world's painting, and the map the painted tiles are baked on.
Canvas.WORLD_MAP = 947
-- Azeroth's map's art in its own units (its art pixels), which MapArt's `units` are counted in.
local WORLD_W, WORLD_H = 1002, 668

---------------------------------------------------------------------------------------------------
-- Game data lookups
---------------------------------------------------------------------------------------------------
function Canvas.TileData(continent)
	return ns.TileData and ns.TileData[continent]
end

local function PaintData(continent)
	local art = ns.MapArt
	return art and art.continents and art.continents[continent]
end

-- Where a continent of Azeroth's map's own lies on it: { y0, ky, x0, kx } (MapArt's `units`), or nil.
local function OwnUnits(continent)
	local paint = PaintData(continent)
	return paint and paint.units
end

local linked -- [map] = units of a map of its own the game puts on Azeroth's map (an island: Zephras Isle)

-- Where such an island's map lies on Azeroth's map when the game won't say (its painting doesn't show it, and
-- C_Map.GetMapRectOnMap has no answer): [uiMap] = the middle of its map, across and down Azeroth's (0 to 1). Ours:
-- Zephras Isle out in the north of the Great Sea, between Kalimdor and the isles off Lordaeron.
local ISLAND_PLACES = {
	[2521] = { 0.482, 0.13 },
}

-- The game places such an island's zone on Azeroth's map (C_Map.GetMapRectOnMap), else ISLAND_PLACES at the
-- continents' scale; its map's world rectangle then gives the same scale and shift as a continent's.
local function Linked()
	if linked then
		return linked
	end
	linked = {}
	if not ns.TileData then
		return linked
	end
	local scale, first -- the first continent's { ky, kx }: yards an art pixel of Azeroth's map
	for c, paint in pairs(ns.MapArt and ns.MapArt.continents or {}) do
		if paint.units and (not first or c < first) then
			scale, first = { paint.units[2], paint.units[4] }, c
		end
	end
	for continent in pairs(ns.TileData) do
		if type(continent) == "number" and not OwnUnits(continent) then
			local id = Canvas.ArtMapFor(continent)
			local info = id and C_Map.GetMapInfo(id)
			local rect = info and info.parentMapID == Canvas.WORLD_MAP and Coords.GetMapRect(id)
			if rect then
				local minX, maxX, minY, maxY
				if C_Map.GetMapRectOnMap then
					minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(id, Canvas.WORLD_MAP)
				end
				local place = ISLAND_PLACES[id]
				if minX and maxX and minY and maxY and maxX > minX and maxY > minY then
					local ky = rect.width / ((maxX - minX) * WORLD_W)
					local kx = rect.height / ((maxY - minY) * WORLD_H)
					linked[continent] = { rect.left + minX * WORLD_W * ky, ky, rect.top + minY * WORLD_H * kx, kx }
				elseif place and scale then
					local ky, kx = scale[1], scale[2]
					local midY, midX = (rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2
					linked[continent] = { midY + place[1] * WORLD_W * ky, ky, midX + place[2] * WORLD_H * kx, kx }
				end
			end
		end
	end
	return linked
end

-- Where a continent lies on Azeroth's map: { y0, ky, x0, kx }, or nil when it isn't on it.
local function Units(continent)
	return OwnUnits(continent) or Linked()[continent]
end

-- (x, y) in continent `from`'s yards to continent `to`'s, the two laid out as on Azeroth's map; nil when either
-- isn't on it.
function Canvas.Convert(from, to, x, y)
	if from == to then
		return x, y
	end
	local a, b = Units(from), Units(to)
	if not (a and b and x) then
		return nil
	end
	local ux, uy = (a[1] - y) / a[2], (a[3] - x) / a[4]
	return b[3] - uy * b[4], b[1] - ux * b[2]
end

-- The same as a scale and a shift, x' = ox + sx * x and y' = oy + sy * y; nil for none (or no way across).
local function Transform(from, to)
	local a, b = Units(from), Units(to)
	if from == to or not (a and b) then
		return nil
	end
	local sx, sy = b[4] / a[4], b[2] / a[2]
	return { sx = sx, ox = b[3] - a[3] * sx, sy = sy, oy = b[1] - a[1] * sy }
end

-- Azeroth's map's rectangle in a continent's yards, or nil when the continent isn't on it.
function Canvas.WorldRect(continent)
	local u = Units(continent)
	if not u then
		return nil
	end
	local y0, ky, x0, kx = u[1], u[2], u[3], u[4]
	return Coords.NewRect(continent, x0, y0, x0 - WORLD_H * kx, y0 - WORLD_W * ky)
end

local worldList -- the continents on Azeroth's map, in order: its own first, then the islands put on it

function Canvas.WorldContinents()
	if not worldList then
		worldList = {}
		for continent, paint in pairs(ns.MapArt and ns.MapArt.continents or {}) do
			if paint.units then
				worldList[#worldList + 1] = continent
			end
		end
		table.sort(worldList)
		local islands = {}
		for continent in pairs(Linked()) do
			islands[#islands + 1] = continent
		end
		table.sort(islands)
		for _, continent in ipairs(islands) do
			worldList[#worldList + 1] = continent
		end
	end
	return worldList
end

-- Whether a continent is an island put on Azeroth's map (not one of its own, with a painting and sea of its own).
function Canvas.IsIsland(continent)
	return Linked()[continent] ~= nil
end

-- Whether a point lies in a world rectangle.
local function InRect(rect, x, y)
	return rect and x <= rect.top and x >= rect.bottom and y <= rect.left and y >= rect.right
end

-- The continent of Azeroth's map whose own map's rectangle holds (x, y) of continent `from`, and the point in its
-- yards; nil when none does (out at sea between them).
local function ArtRect(continent)
	local id = Canvas.ArtMapFor(continent)
	return id and Coords.GetMapRect(id)
end

-- The islands come first (they lie in the sea of a continent's map). With `own`, only Azeroth's own continents
-- (the ones a view can be in the yards of): a point on none of their maps is given in the first one's yards.
function Canvas.ContinentAt(from, x, y, own)
	local list = Canvas.WorldContinents()
	if not own then
		for _, c in ipairs(list) do
			if Linked()[c] then
				local cx, cy = Canvas.Convert(from, c, x, y)
				if cx and InRect(ArtRect(c), cx, cy) then
					return c, cx, cy
				end
			end
		end
	end
	if OwnUnits(from) and InRect(ArtRect(from), x, y) then
		return from, x, y
	end
	for _, c in ipairs(list) do
		if c ~= from and OwnUnits(c) then
			local cx, cy = Canvas.Convert(from, c, x, y)
			if cx and InRect(ArtRect(c), cx, cy) then
				return c, cx, cy
			end
		end
	end
	if own and not OwnUnits(from) and Units(from) and OwnUnits(list[1]) then
		return list[1], Canvas.Convert(from, list[1], x, y)
	end
end

-- Centre (x, y) of a continent's terrain, for opening a view where there is something to see.
function Canvas.ContinentCenter(continent)
	local data = Canvas.TileData(continent)
	if not data then
		return 0, 0
	end
	local x1, y1, x2, y2 = huge, huge, -huge, -huge
	for key in pairs(data.files) do
		local tx, ty = floor(key / 64), key % 64
		x1, x2, y1, y2 = min(x1, tx), max(x2, tx), min(y1, ty), max(y2, ty)
	end
	return Coords.TileToWorld((x1 + x2 + 1) / 2, (y1 + y2 + 1) / 2)
end

local artMaps -- [continent] = uiMapID of the largest map with a world rectangle on it

-- The uiMap whose painted art is drawn under a continent: the one covering the most ground there.
function Canvas.ArtMapFor(continent)
	local paint = PaintData(continent)
	if paint and paint.art then
		return paint.art
	end
	if not artMaps then
		artMaps = {}
		local best = {}
		for id = 1, 4000 do
			if C_Map.GetMapInfo(id) then
				local rect = Coords.GetMapRect(id)
				if rect then
					local area = rect.width * rect.height
					if area > (best[rect.continent] or 0) then
						best[rect.continent] = area
						artMaps[rect.continent] = id
					end
				end
			end
		end
	end
	return artMaps[continent]
end

-- 1 at `full` and closer, 0 at `none` and further out, in between in between.
local function Ramp(ypp, full, none)
	if ypp <= full then
		return 1
	elseif ypp >= none then
		return 0
	end
	return (none - ypp) / (none - full)
end

---------------------------------------------------------------------------------------------------
-- Canvas objects
---------------------------------------------------------------------------------------------------
local Proto = {}
local Meta = { __index = Proto }

-- A canvas filling `parent`. options: any of Canvas.defaults.
function Canvas.New(parent, options)
	local self = setmetatable({}, Meta)
	self.options = {}
	for k, v in pairs(Canvas.defaults) do
		self.options[k] = v
	end
	for k, v in pairs(options or {}) do
		self.options[k] = v
	end

	local clip = CreateFrame("Frame", nil, parent)
	clip:SetAllPoints(parent)
	clip:SetClipsChildren(true)
	self.frame = clip

	local sea = clip:CreateTexture(nil, "BACKGROUND")
	sea:SetAllPoints()
	sea:SetColorTexture(unpack(Canvas.SEA_COLOR))

	local world = CreateFrame("Frame", nil, clip)
	world:SetSize(1, 1)
	world:SetPoint("CENTER")
	self.world = world

	self.level = clip:GetFrameLevel()
	self.terrainLayer = self:Layer(1)
	-- For the owner's lines and pins: same size as the canvas, offsets from its centre (WorldToFrame).
	self.overlay = CreateFrame("Frame", nil, clip)
	self.overlay:SetAllPoints(clip)
	self.overlay:SetFrameLevel(self.level + 20)

	self.tiles = {} -- [continent * 4096 + tile key] = { tex, mask, stamp, continent, key }
	self.xfs = {} -- [continent] = its Transform into the view's continent (false: none)
	self.layout = 0 -- counts layouts, so a group laid out under an older one is laid out again as it shows
	self.freeTiles = {}
	self.freeMasks = {}
	self.groups = {} -- [continent] = the painted layers built for it (BuildPaint)
	self.stamp = 0
	self.stats = { tiles = 0, masks = 0, art = 0, zones = 0, cities = 0, pending = false, ms = 0, alpha = 0, zoneAlpha = 0, cityAlpha = 0 }

	clip:SetScript("OnSizeChanged", function()
		self.layoutYpp = nil
		self:Update()
	end)
	clip:SetScript("OnUpdate", function()
		if self.pending then
			self:Update()
		end
	end)
	return self
end

-- A frame covering the world frame (so its centre is the layout's anchor), drawn `offset` levels above the canvas.
function Proto:Layer(offset, parent)
	local layer = CreateFrame("Frame", nil, parent or self.world)
	layer:SetAllPoints(self.world)
	layer:SetFrameLevel(self.level + offset)
	return layer
end

-- Shows (x, y) of a continent at the canvas's centre, `ypp` yards per UI unit (default: keep the zoom).
function Proto:SetView(continent, x, y, ypp)
	ypp = ypp or self.ypp or 10
	-- On the world map the view's continent is the one under its centre (kept while out at sea; never an island,
	-- which has no sea or Azeroth's painting of its own to draw under the rest).
	if self.options.world then
		local c, cx, cy = Canvas.ContinentAt(continent, x, y, true)
		if c then
			continent, x, y = c, cx, cy
		end
	end
	if continent ~= self.continent then
		local across = self.options.world and Units(continent) and self.continent and Units(self.continent)
		if not across then
			self:ReleaseTiles()
		end
		self.continent = continent
		self.layoutYpp = nil
		self.xfs = {}
	end
	self.cx, self.cy, self.ypp = x, y, ypp
	self:Update()
end

function Proto:GetView()
	return self.continent, self.cx, self.cy, self.ypp
end

-- Options that change how terrain tiles are drawn: the tiles are made again when one changes.
local TILE_OPTIONS = { terrain = true, fade = true, margin = true }

-- Changes options (a table of Canvas.defaults keys) and redraws.
function Proto:SetOptions(changes)
	local tiles = false
	for k, v in pairs(changes) do
		tiles = tiles or (TILE_OPTIONS[k] and self.options[k] ~= v)
		self.options[k] = v
	end
	if tiles then
		self:ReleaseTiles()
		self.layoutYpp = nil
	end
	self:Update()
end

-- World (x, y) to an offset from the centre of the world frame (self.world) at the current layout: for the owner's
-- own regions on a frame over it, which then pan with it and need placing again only when self.layout changes.
-- nil for a point of another continent that can't be carried across.
function Proto:ToLayout(x, y, continent)
	if continent and continent ~= self.continent then
		x, y = Canvas.Convert(continent, self.continent, x, y)
		if not x then
			return nil
		end
	end
	return (self.anchorY - y) / self.layoutYpp, (x - self.anchorX) / self.layoutYpp
end

-- World (x, y) to an offset from the canvas's centre in its UI units (right and up positive). A point of another
-- continent (`continent`) is carried across Azeroth's map; nil when it can't be.
function Proto:WorldToFrame(x, y, continent)
	if continent and continent ~= self.continent then
		x, y = Canvas.Convert(continent, self.continent, x, y)
		if not x then
			return nil
		end
	end
	return (self.cy - y) / self.ypp, (x - self.cx) / self.ypp
end

-- An offset from the canvas's centre (right and up positive) to world (x, y) of the view's continent.
function Proto:FrameToWorld(dx, dy)
	return self.cx + dy * self.ypp, self.cy - dx * self.ypp
end

-- The same as continent, x, y: on the world map, of the continent whose map holds the point.
function Proto:FrameToContinent(dx, dy)
	local x, y = self:FrameToWorld(dx, dy)
	if self.options.world then
		local c, cx, cy = Canvas.ContinentAt(self.continent, x, y)
		if c then
			return c, cx, cy
		end
	end
	return self.continent, x, y
end

-- The Transform from a continent's yards into the view's continent's (nil: the same yards).
function Proto:Xf(continent)
	local xf = self.xfs[continent]
	if xf == nil then
		xf = Transform(continent, self.continent) or false
		self.xfs[continent] = xf
	end
	return xf or nil
end

-- The continents drawn: the view's own, and on the world map every one on Azeroth's map with it.
function Proto:DrawList()
	if self.options.world and Units(self.continent) then
		return Canvas.WorldContinents()
	end
	self.single = self.single or {}
	self.single[1] = self.continent
	return self.single
end

-- The view's rectangle (north, south, west, east) in a continent's own yards, `grow` times its size.
function Proto:ViewIn(continent, w, h, grow)
	local halfW, halfH = w / 2 * self.ypp * grow, h / 2 * self.ypp * grow
	local north, west = self.cx + halfH, self.cy + halfW
	local south, east = self.cx - halfH, self.cy - halfW
	if continent ~= self.continent then
		north, west = Canvas.Convert(self.continent, continent, north, west)
		south, east = Canvas.Convert(self.continent, continent, south, east)
	end
	return north, south, west, east
end

-- Called with (canvas) after every redraw, so the owner can place its overlay.
function Proto:SetOnUpdate(fn)
	self.onUpdate = fn
end

---------------------------------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------------------------------

-- UI units of the canvas per screen pixel.
local function PixelSize(frame)
	local _, physicalHeight = GetPhysicalScreenSize()
	return (768 / physicalHeight) / frame:GetEffectiveScale()
end

local function Snap(v, px)
	return floor(v / px + 0.5) * px
end

-- Places a texture (or mask) over world rectangle (x0, y0) north-west to (x1, y1) south-east, snapped to pixels,
-- relative to the layout's anchor; `xf` carries a rectangle of another continent across. Its parent must cover the
-- world frame.
function Proto:Place(tex, x0, y0, x1, y1, xf)
	if xf then
		x0, x1 = xf.ox + xf.sx * x0, xf.ox + xf.sx * x1
		y0, y1 = xf.oy + xf.sy * y0, xf.oy + xf.sy * y1
	end
	local ax, ay, ypp, px = self.anchorX, self.anchorY, self.layoutYpp, self.pixel
	local left = Snap((ay - y0) / ypp, px)
	local right = Snap((ay - y1) / ypp, px)
	local top = Snap((x0 - ax) / ypp, px)
	local bottom = Snap((x1 - ax) / ypp, px)
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", tex:GetParent(), "CENTER", left, top)
	tex:SetSize(max(right - left, px), max(top - bottom, px))
end

function Proto:PlaceTile(rec)
	local key = rec.key
	local tx, ty = floor(key / 64), key % 64
	local x0, y0 = Coords.TileToWorld(tx, ty)
	self:Place(rec.tex, x0, y0, x0 - TILE, y0 - TILE, self:Xf(rec.continent))
end

-- Lays out a list of { region, x0, y0, x1, y1 } placements.
function Proto:PlaceAll(list, xf)
	for _, p in ipairs(list) do
		self:Place(p[1], p[2], p[3], p[4], p[5], xf)
	end
end

-- A group of painted layers (a continent's, or Azeroth's painting) laid out for the current layout, if it isn't.
function Proto:LayOut(group)
	if group.layout ~= self.layout or group.ref ~= self.continent then
		group.layout, group.ref = self.layout, self.continent
		group.xf = self:Xf(group.continent)
		group.seaBox = nil
		self:PlaceAll(group.placed, group.xf)
	end
end

function Proto:Update()
	local clip = self.frame
	local w, h = clip:GetSize()
	if not self.continent or not self.ypp or w <= 0 or h <= 0 then
		return
	end
	local started = debugprofilestop()
	local ypp, options = self.ypp, self.options
	self.pixel = PixelSize(clip)

	-- A new zoom: lay everything out again around the current centre (the painted groups as they show: LayOut).
	if self.layoutYpp ~= ypp then
		self.anchorX, self.anchorY, self.layoutYpp = self.cx, self.cy, ypp
		self.layout = self.layout + 1
		for _, rec in pairs(self.tiles) do
			self:PlaceTile(rec)
		end
	end

	-- Panning: move the layout so its anchor sits where it belongs, on a whole screen pixel (measured from the
	-- screen's corner, so every texture edge inside it is on one too).
	local px = self.pixel
	local centerX, centerY = clip:GetCenter()
	local east = Snap(centerX + (self.cy - self.anchorY) / ypp, px) - centerX
	local north = Snap(centerY + (self.anchorX - self.cx) / ypp, px) - centerY
	self.world:ClearAllPoints()
	self.world:SetPoint("CENTER", clip, "CENTER", east, north)

	-- How much of each layer shows: `detail` is the paintings over the terrain, `mix` the detailed painted map over
	-- the continent's painting, `paper` the sea's paper in place of the continent's ocean, `city` the city maps over
	-- their zones' banners.
	local detail = options.terrain and 1 - Ramp(ypp, options.terrainFull, options.terrainNone) or 1
	local mix = options.zones and Ramp(ypp, options.zonesFull, options.zonesNone) or 0
	local paper = options.zones and options.sea and Ramp(ypp, options.seaFull, options.seaNone) or 0
	local city = options.cities and Ramp(ypp, options.citiesFull, options.citiesNone) or 0

	-- The continent's painting stays under the detailed map (its ocean shows through the tiles' clear sea) until
	-- the sea's paper takes over; the sea shows under it only once it starts to go (or without it). On the world
	-- map the view's continent's sea is everyone's, always under them (Azeroth's painting on it, going as the
	-- continents' paintings go), and the other continents draw none.
	local world = options.world and Units(self.continent) and true
	local art = options.art and 1 - paper or 0
	-- (world map: the continents' own paintings over Azeroth's)
	local land = world and Ramp(ypp, options.continentFull, options.continentNone) or 1
	local list, drawn = self:DrawList(), {}
	self.stats.zones, self.stats.level = 0, nil
	local stats = self.stats
	stats.art, stats.cities = 0, 0
	for _, continent in ipairs(list) do
		local group = self.groups[continent]
		if not group and ((mix < 1 and options.art) or mix > 0 or world) then
			group = self:BuildPaint(continent)
		end
		if group then
			drawn[group] = true
			self:LayOut(group)
			local owner = continent == self.continent
			local sea = owner and group.sea ~= nil and (world or (options.zones and options.sea and mix > 0 and art < 1))
			local showPaint = mix > 0 and group.hasPaint
			-- (an island's painting is all it has until its terrain: it stays as the sea paper comes in)
			local artAlpha = group.fades and art * land or art
			if world and Canvas.IsIsland(continent) then
				artAlpha = options.art and 1 or 0
			end
			group.root:SetShown(detail > 0 and (artAlpha > 0 or art > 0 or sea or showPaint))
			group.root:SetAlpha(detail)
			group.art:SetShown(artAlpha > 0)
			group.art:SetAlpha(artAlpha)
			if group.sea then
				group.sea:SetShown(sea)
				for _, p in ipairs(group.worldArt) do
					p[1]:SetShown(art > 0)
					p[1]:SetAlpha(art)
				end
			end
			group.paint:SetShown(showPaint)
			group.paint:SetAlpha(mix)
			if detail > 0 and (sea or showPaint) and group.seaInfo then
				self:UpdateSea(group, w, h, sea)
			end
			if detail > 0 and showPaint then
				self:UpdatePaint(group, w, h, city)
			end
			stats.art = stats.art + #group.artPlaced
			stats.cities = stats.cities + #group.cities
		end
	end
	for _, group in pairs(self.groups) do
		if not drawn[group] then
			group.root:Hide()
		end
	end

	-- The terrain is loaded a little before the paintings start to fade, so it is there when they do.
	local wantTerrain = options.terrain and ypp < options.terrainNone * 1.25
	if wantTerrain then
		self:UpdateTiles(w, h, list)
	else
		self:ReleaseTiles()
		self.pending = false
	end

	stats.alpha, stats.zoneAlpha, stats.cityAlpha, stats.pending = 1 - detail, mix, city, self.pending
	stats.landAlpha, stats.paperAlpha = land, paper
	stats.ms = debugprofilestop() - started
	if self.onUpdate then
		self.onUpdate(self)
	end
end

-- The terrain tiles in view of every continent drawn (`list`), each continent's in its own yards.
function Proto:UpdateTiles(w, h, list)
	local stamp = self.stamp + 1
	self.stamp = stamp
	local tiles, started, pending = self.tiles, 0, false
	local margin = self.options.margin
	for _, continent in ipairs(list) do
		local data = Canvas.TileData(continent)
		if data then
			local files, fades = data.files, self.options.fade and data.fade or nil
			local north, south, west, east = self:ViewIn(continent, w, h, 1)
			local txMin = max(0, floor(32 - west / TILE) - margin)
			local txMax = min(63, floor(32 - east / TILE) + margin)
			local tyMin = max(0, floor(32 - north / TILE) - margin)
			local tyMax = min(63, floor(32 - south / TILE) + margin)
			for tx = txMin, txMax do
				for ty = tyMin, tyMax do
					local key = tx * 64 + ty
					local fileID = files[key]
					if fileID then
						local id = continent * 4096 + key
						local rec = tiles[id]
						if rec then
							rec.stamp = stamp
						elseif started < Canvas.NEW_TILES_PER_FRAME then
							started = started + 1
							rec = self:AcquireTile(fileID, fades and fades[key])
							rec.stamp, rec.continent, rec.key = stamp, continent, key
							tiles[id] = rec
							self:PlaceTile(rec)
						else
							pending = true
						end
					end
				end
			end
		end
	end

	local count, masks = 0, 0
	for key, rec in pairs(tiles) do
		if rec.stamp ~= stamp then
			self:ReleaseTile(key, rec)
		else
			count = count + 1
			if rec.mask then
				masks = masks + 1
			end
		end
	end
	self.pending = pending
	self.stats.tiles, self.stats.masks = count, masks
end

function Proto:AcquireTile(fileID, fadeKey)
	local rec = table.remove(self.freeTiles)
	if not rec then
		rec = { tex = self.terrainLayer:CreateTexture(nil, "ARTWORK") }
		rec.tex:SetTexCoord(INSET, 1 - INSET, INSET, 1 - INSET)
	end
	rec.tex:SetTexture(fileID, "CLAMP", "CLAMP", "TRILINEAR")
	if fadeKey then
		local mask = table.remove(self.freeMasks) or self.terrainLayer:CreateMaskTexture()
		-- (clamped to its own edge: clamped to black, the outer half of its edge texels, a few screen pixels of a
		-- 64-texel mask stretched over a tile, faded every side into the sea, even the sides with land beside them)
		mask:SetTexture(FADE_PATH .. fadeKey, "CLAMP", "CLAMP")
		mask:SetAllPoints(rec.tex)
		mask:Show()
		rec.tex:AddMaskTexture(mask)
		rec.mask = mask
	end
	rec.tex:Show()
	return rec
end

function Proto:ReleaseTile(key, rec)
	local tex = rec.tex
	if rec.mask then
		tex:RemoveMaskTexture(rec.mask)
		rec.mask:Hide()
		rec.mask:ClearAllPoints()
		self.freeMasks[#self.freeMasks + 1] = rec.mask
		rec.mask = nil
	end
	tex:Hide()
	tex:SetTexture(nil)
	self.tiles[key] = nil
	self.freeTiles[#self.freeTiles + 1] = rec
end

function Proto:ReleaseTiles()
	for key, rec in pairs(self.tiles) do
		self:ReleaseTile(key, rec)
	end
	self.stats.tiles, self.stats.masks = 0, 0
end

---------------------------------------------------------------------------------------------------
-- The paintings (built once per continent, then only shown, hidden and laid out)
---------------------------------------------------------------------------------------------------

-- A texture on `frame` showing (0, 0)-(u1, v1) of a file over world rectangle (x0, y0)-(x1, y1).
local function AddTexture(group, list, frame, file, x0, y0, x1, y1, u1, v1, layer, sublevel)
	local tex = frame:CreateTexture(nil, layer or "ARTWORK", nil, sublevel)
	tex:SetTexture(file, "CLAMP", "CLAMP", "TRILINEAR")
	tex:SetTexCoord(0, u1 or 1, 0, v1 or 1)
	local p = { tex, x0, y0, x1, y1 }
	group.placed[#group.placed + 1] = p
	if list then
		list[#list + 1] = p
	end
	return tex
end

-- A mask over a map's whole rectangle, for the textures drawn through it.
local function AddMask(group, frame, path, rect)
	local mask = frame:CreateMaskTexture()
	mask:SetTexture(path, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	local x0, y0 = Coords.RectToWorld(rect, 0, 0)
	local x1, y1 = Coords.RectToWorld(rect, 1, 1)
	group.placed[#group.placed + 1] = { mask, x0, y0, x1, y1 }
	return mask
end

-- A map's base painting (C_Map's art layer 1) as textures on `frame`, each drawn through `mask` if given. The last
-- row and column of files run past the map's own size; they are cut half a texel short so filtering never shows
-- what lies past it.
local function AddBaseArt(group, list, frame, mapID, rect, mask)
	local layers = C_Map.GetMapArtLayers(mapID)
	local layer = layers and layers[1]
	local textures = layer and C_Map.GetMapArtLayerTextures(mapID, 1)
	if not textures then
		return
	end
	local lw, lh, tw, th = layer.layerWidth, layer.layerHeight, layer.tileWidth, layer.tileHeight
	local cols, rows = ceil(lw / tw), ceil(lh / th)
	for row = 0, rows - 1 do
		for col = 0, cols - 1 do
			local fileID = textures[row * cols + col + 1]
			if fileID then
				local pw, ph = min(tw, lw - col * tw), min(th, lh - row * th)
				local x0, y0 = Coords.RectToWorld(rect, col * tw / lw, row * th / lh)
				local x1, y1 = Coords.RectToWorld(rect, (col * tw + pw) / lw, (row * th + ph) / lh)
				local u1 = pw < tw and (pw - 0.5) / tw or 1
				local v1 = ph < th and (ph - 0.5) / th or 1
				local tex = AddTexture(group, list, frame, fileID, x0, y0, x1, y1, u1, v1)
				if mask then
					tex:AddMaskTexture(mask)
				end
			end
		end
	end
end

-- The baked tiles of one size (Data/MapArt.lua's levels[n]) on `frame`: each over its own part of the world, its
-- texture made and its file loaded the first time it is wanted (UpdatePaint). A tile one size coarser that has
-- these as its quarters is marked `split`: these stand in for it once they show.
local function AddTiles(group, frame, data, paint, n)
	local kind, px = data.levels[n][1], data.levels[n][2]
	local y0, ky, x0, kx = unpack(paint.units)
	local step = data.step / px
	local level = { list = {}, texel = ky / px, kind = kind }
	local parents = group.levels[n - 1]
	for _, key in ipairs(paint[kind] or {}) do
		local i, j = floor(key / 256), key % 256 -- (i can be negative: west of Azeroth's map)
		local t = {
			frame = frame,
			path = ("%sBake\\%s_%d_%d"):format(MEDIA, kind, i, j),
			north = x0 - j * step * kx,
			west = y0 - i * step * ky,
			south = x0 - (j + 1) * step * kx,
			east = y0 - (i + 1) * step * ky,
		}
		level.list[#level.list + 1] = t
		local parent = parents and parents.byKey[floor(i / 2) * 256 + floor(j / 2)]
		if parent then
			parent.split = true
		end
	end
	level.byKey = {}
	for index, key in ipairs(paint[kind] or {}) do
		level.byKey[key] = level.list[index]
	end
	group.levels[n] = level
end

-- Whether a world rectangle (north, west, south, east) meets the view's.
local function InView(r, north, south, west, east)
	return r.north > south and r.south < north and r.west > east and r.east < west
end

-- The sea under the paintings, on its own frame: its colour, its colour fields (the world's, carried past its map,
-- and the continent's, faded into it at its edges) and its paper, two textures (dark and light) for each of two
-- sizes, laid by UpdateSea. And the coasts' hatching on `hatchFrame`, through the continent's coastal band.
function Proto:BuildSea(group, data, paint, artMap, artRect, hatchFrame)
	local sea = self:Layer(2, group.root)
	local y0, ky, x0, kx = unpack(paint.units)
	-- (u, v) of Azeroth's map, 0 to 1 across and down, to this continent's world (x, y)
	local function Azeroth(u, v)
		return x0 - v * WORLD_H * kx, y0 - u * WORLD_W * ky
	end
	local color = sea:CreateTexture(nil, "BACKGROUND", nil, -8)
	color:SetAllPoints(self.frame)
	color:SetColorTexture(unpack(data.sea.color))
	local reach = data.sea.reach
	local n0, w0 = Azeroth(-reach, -reach)
	local s0, e0 = Azeroth(1 + reach, 1 + reach)
	AddTexture(group, nil, sea, MEDIA .. "Bake\\sea_out", n0, w0, s0, e0, nil, nil, "BACKGROUND", -7)
	n0, w0 = Azeroth(0, 0)
	s0, e0 = Azeroth(1, 1)
	AddTexture(group, nil, sea, MEDIA .. "Bake\\sea_947", n0, w0, s0, e0, nil, nil, "BACKGROUND", -6)
	if artRect then
		local field = AddTexture(group, nil, sea, ("%sBake\\sea_%d"):format(MEDIA, artMap), artRect.top, artRect.left,
			artRect.top - artRect.height, artRect.left - artRect.width, nil, nil, "BACKGROUND", -5)
		field:AddMaskTexture(AddMask(group, sea, MEDIA .. "Bake\\feather_wide", artRect))
	end
	group.paper = {}
	for i = 1, 4 do
		local tex = sea:CreateTexture(nil, "BACKGROUND", nil, -5 + i)
		tex:SetTexture(MEDIA .. "Bake\\" .. (i % 2 == 1 and "sea_dark" or "sea_light"), "REPEAT", "REPEAT", "TRILINEAR")
		tex:Hide()
		group.paper[i] = tex
	end
	-- On the world map, Azeroth's own painting over it all: the ocean between and around the continents' maps.
	group.worldArt = {}
	if self.options.world then
		local north, west = Azeroth(0, 0)
		local south, east = Azeroth(1, 1)
		AddTexture(group, group.worldArt, sea, MEDIA .. "Map\\world", north, west, south, east)
	end
	group.hatch = {}
	if artRect then
		local coast = AddMask(group, hatchFrame, ("%sBake\\coast_%d"):format(MEDIA, artMap), artRect)
		for i = 1, 2 do
			local tex = hatchFrame:CreateTexture(nil, "ARTWORK")
			tex:SetTexture(MEDIA .. "Bake\\hatch", "REPEAT", "REPEAT", "TRILINEAR")
			tex:AddMaskTexture(coast)
			tex:Hide()
			group.hatch[i] = tex
		end
	end
	group.seaInfo = paint.sea
	return sea
end

function Proto:BuildPaint(continent)
	local group = { continent = continent, placed = {}, artPlaced = {}, levels = {}, cities = {}, banners = {}, worldArt = {} }
	self.groups[continent] = group
	local data, paint = ns.MapArt, PaintData(continent)

	-- Everything painted, in one frame that fades out over the terrain.
	group.root = self:Layer(2)
	group.art = self:Layer(3, group.root)
	group.paint = self:Layer(4, group.root)

	-- The continent's own painting. On the world map, its land and coast, coming in over Azeroth's painting as you
	-- zoom in (`fades`); an island's, cut down to the island.
	local artMap = Canvas.ArtMapFor(continent)
	local artRect = artMap and Coords.GetMapRect(artMap)
	if artRect and self.options.world and Units(continent) then
		local file = ("%sMap\\%s_%d"):format(MEDIA, OwnUnits(continent) and "land" or "isle", artMap)
		AddTexture(group, group.artPlaced, group.art, file, artRect.top, artRect.left, artRect.bottom, artRect.right)
		group.fades = OwnUnits(continent) ~= nil
	elseif artRect then
		AddBaseArt(group, group.artPlaced, group.art, artMap, artRect)
	end

	-- The sea under it, the coasts' hatching and the tiles over it, each size on its own frame.
	if paint then
		if paint.sea and data.sea then
			group.sea = self:BuildSea(group, data, paint, artMap, artRect, self:Layer(4, group.paint))
		end
		for n = 1, #data.levels do
			AddTiles(group, self:Layer(4 + n, group.paint), data, paint, n)
		end
	end

	-- Cities: their own maps, cut down to the city, over the zones; and their zones' banners for them, over those.
	local cityLayer = self:Layer(9, group.paint)
	local bannerLayer = self:Layer(10, group.paint)
	local function AddBanner(cityID, entry, fades)
		local b = entry.banner
		local rect = b and Coords.GetMapRect(b[1])
		if not rect or rect.continent ~= continent then
			return
		end
		local frame = CreateFrame("Frame", nil, bannerLayer)
		frame:SetAllPoints(bannerLayer)
		local x0, y0 = Coords.RectToWorld(rect, b[2] / 1002, b[3] / 668)
		local x1, y1 = Coords.RectToWorld(rect, (b[2] + b[4]) / 1002, (b[3] + b[5]) / 668)
		AddTexture(group, nil, frame, ("%sBake\\banner_%d"):format(MEDIA, cityID), x0, y0, x1, y1)
		group.banners[#group.banners + 1] = { frame = frame, fades = fades, north = x0, west = y0, south = x1, east = y1 }
	end
	for cityID, entry in pairs(data and data.cities or {}) do
		local rect = Coords.GetMapRect(cityID)
		if rect and rect.continent == continent then
			local frame = CreateFrame("Frame", nil, cityLayer)
			frame:SetAllPoints(cityLayer)
			local mask = AddMask(group, frame, ("%sBake\\%s"):format(MEDIA, entry.cut and ("cut_" .. cityID) or "round"), rect)
			AddBaseArt(group, nil, frame, cityID, rect, mask)
			local x0, y0 = Coords.RectToWorld(rect, 0, 0)
			local x1, y1 = Coords.RectToWorld(rect, 1, 1)
			group.cities[#group.cities + 1] = { frame = frame, north = x0, west = y0, south = x1, east = y1 }
			-- The zone's banner for the city gives way to the city's own map (which has its own small label).
			AddBanner(cityID, entry, true)
		end
	end
	for cityID, entry in pairs(data and data.underground or {}) do
		AddBanner(cityID, entry, false)
	end

	group.hasPaint = #group.levels > 0 or #group.cities > 0
	return group
end

-- A repeating texture over world rectangle `box`, a tile every sx by sy yards, fixed on the world (shifted by
-- `shift` tiles, so two sizes of one pattern don't line up).
function Proto:TileOver(tex, box, sx, sy, alpha, shift, xf)
	if not tex then
		return
	end
	if alpha <= 0.01 then
		tex:Hide()
		return
	end
	local o = shift or 0
	tex:SetTexCoord(-box.west / sx + o, -box.east / sx + o, -box.north / sy + o * 1.6, -box.south / sy + o * 1.6)
	self:Place(tex, box.north, box.west, box.south, box.east, xf)
	tex:SetAlpha(alpha)
	tex:Show()
end

-- Stitch.lua's octaves: a pattern `size` UI units on screen halves each time it grows past `most` again, crossfading
-- into the half size as it goes. Returns the halvings and how far into the next.
local function Octaves(size, most)
	local o = max(0, math.log(size / most) / math.log(2))
	local n = floor(o)
	return n, o - n
end

-- Per redraw (when the zoom changes or the view nears its edge): the sea's paper and the hatching laid over a box
-- round the view, the size each is drawn at kept on screen (Stitch.lua's S.SetSea).
function Proto:UpdateSea(group, w, h)
	local ypp, c = self.ypp, group.continent
	local box = group.seaBox
	local north, south, west, east = self:ViewIn(c, w, h, 1.2)
	if box and box.ypp == ypp and box.layout == self.layout and north < box.north and south > box.south
		and west < box.west and east > box.east then
		return
	end
	north, south, west, east = self:ViewIn(c, w, h, 1.8)
	box = { ypp = ypp, layout = self.layout, north = north, south = south, west = west, east = east }
	group.seaBox = box
	local info, xf = group.seaInfo, group.xf
	local n, f = Octaves(info.tile / ypp, info.tileMax)
	local size = info.tile / 2 ^ n
	for i = 1, 2 do
		self:TileOver(group.paper[i], box, size, size, 1 - f, (n * 0.37) % 1, xf)
		self:TileOver(group.paper[i + 2], box, size / 2, size / 2, f, ((n + 1) * 0.37) % 1, xf)
	end
	local a = ns.MapArt.sea.hatchAlpha
	n, f = Octaves(info.hatch[1] / ypp, info.hatchMax)
	local hw, hh = info.hatch[1] / 2 ^ n, info.hatch[2] / 2 ^ n
	self:TileOver(group.hatch[1], box, hw, hh, a * math.sqrt(1 - f), nil, xf)
	self:TileOver(group.hatch[2], box, hw / 2, hh / 2, a * math.sqrt(f), nil, xf)
end

-- Per redraw: the tiles of the size that shows (and of each coarser one where there are no finer ones) in view, the
-- next finer size's loaded as it nears, every other tile's file let go; cities out of view hidden, and the city maps
-- and their zones' banners trading places by `city` (0 = banners, 1 = city maps).
function Proto:UpdatePaint(group, w, h, city)
	local ypp = self.ypp
	local north, south, west, east = self:ViewIn(group.continent, w, h, 1)
	-- (tiles a little past the view count as in it, so they are loaded before they scroll in)
	local mh, mw = (north - south) * 0.125, (west - east) * 0.125
	local levels, screen = group.levels, ypp * self.pixel -- yards a screen pixel
	local show = #levels
	for n, level in ipairs(levels) do
		if level.texel <= screen * Canvas.PAINT_LOD then
			show = n
			break
		end
	end
	local warm = levels[show + 1] and levels[show + 1].texel <= screen * Canvas.PAINT_LOD * Canvas.PAINT_WARM and show + 1
	local inset = 1 / ns.MapArt.size -- the outermost pixel on each side is the neighbour's
	local shown = 0
	for n, level in ipairs(levels) do
		for _, t in ipairs(level.list) do
			local near = InView(t, north + mh, south - mh, west + mw, east - mw)
			local visible = near and n <= show and (n == show or not t.split)
			local keep = visible or (near and n == warm)
			if keep and not t.loaded then
				if not t.tex then
					t.tex = t.frame:CreateTexture(nil, "ARTWORK")
					t.tex:SetTexCoord(inset, 1 - inset, inset, 1 - inset)
					local p = { t.tex, t.north, t.west, t.south, t.east }
					group.placed[#group.placed + 1] = p
					self:Place(t.tex, t.north, t.west, t.south, t.east, group.xf)
				end
				t.tex:SetTexture(t.path, "CLAMP", "CLAMP", "TRILINEAR")
				t.loaded = true
			end
			if t.tex then
				t.tex:SetShown(visible)
				if t.loaded and not keep then
					t.tex:SetTexture(nil)
					t.loaded = false
				end
			end
			if visible then
				shown = shown + 1
			end
		end
	end
	for _, c in ipairs(group.cities) do
		c.frame:SetShown(city > 0 and InView(c, north, south, west, east))
		c.frame:SetAlpha(city)
	end
	for _, b in ipairs(group.banners) do
		local alpha = b.fades and 1 - city or 1
		b.frame:SetShown(alpha > 0 and InView(b, north, south, west, east))
		b.frame:SetAlpha(alpha)
	end
	self.stats.zones = self.stats.zones + shown
	if shown > 0 or group.continent == self.continent then
		self.stats.level = levels[show] and levels[show].kind
	end
end
