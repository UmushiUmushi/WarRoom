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
-- Panning moves one frame (`world`) that holds the layers. Textures are laid out again only when the zoom changes.
-- Every edge lands on a whole screen pixel (the world frame too), so neighbouring textures never show a seam.
local _, ns = ...
local WR = ns.WR
local Coords = ns.Coords

local Canvas = {}
ns.Canvas = Canvas
WR.Canvas = Canvas

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
}

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

	self.tiles = {} -- [tile key] = { tex, mask, stamp }
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
	if continent ~= self.continent then
		self:ReleaseTiles()
		local old = self.groups[self.continent]
		if old then
			old.root:Hide()
		end
		self.continent = continent
		self.layoutYpp = nil
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

-- World (x, y) to an offset from the canvas's centre in its UI units (right and up positive).
function Proto:WorldToFrame(x, y)
	return (self.cy - y) / self.ypp, (x - self.cx) / self.ypp
end

-- An offset from the canvas's centre (right and up positive) to world (x, y).
function Proto:FrameToWorld(dx, dy)
	return self.cx + dy * self.ypp, self.cy - dx * self.ypp
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
-- relative to the layout's anchor. Its parent must cover the world frame.
function Proto:Place(tex, x0, y0, x1, y1)
	local ax, ay, ypp, px = self.anchorX, self.anchorY, self.layoutYpp, self.pixel
	local left = Snap((ay - y0) / ypp, px)
	local right = Snap((ay - y1) / ypp, px)
	local top = Snap((x0 - ax) / ypp, px)
	local bottom = Snap((x1 - ax) / ypp, px)
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", tex:GetParent(), "CENTER", left, top)
	tex:SetSize(max(right - left, px), max(top - bottom, px))
end

function Proto:PlaceTile(key, rec)
	local tx, ty = floor(key / 64), key % 64
	local x0, y0 = Coords.TileToWorld(tx, ty)
	self:Place(rec.tex, x0, y0, x0 - TILE, y0 - TILE)
end

-- Lays out a list of { region, x0, y0, x1, y1 } placements.
function Proto:PlaceAll(list)
	for _, p in ipairs(list) do
		self:Place(p[1], p[2], p[3], p[4], p[5])
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
	local group = self.groups[self.continent]

	-- A new zoom: lay everything out again around the current centre.
	if self.layoutYpp ~= ypp then
		self.anchorX, self.anchorY, self.layoutYpp = self.cx, self.cy, ypp
		for key, rec in pairs(self.tiles) do
			self:PlaceTile(key, rec)
		end
		if group then
			self:PlaceAll(group.placed)
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
	-- Cities whose ground the painted map leaves blank (Orgrimmar, Thunder Bluff) come in with it, under their banners.
	local early = options.cities and Ramp(ypp, options.citiesNone, options.zonesFull) or 0

	if (mix < 1 and options.art) or mix > 0 then
		if not group then
			group = self:BuildPaint()
		end
	end
	self.stats.zones, self.stats.level = 0, nil
	if group then
		-- The continent's painting stays under the detailed map (its ocean shows through the tiles' clear sea) until
		-- the sea's paper takes over; the sea shows under it only once it starts to go (or without it).
		local art = options.art and 1 - paper or 0
		local sea = group.sea ~= nil and options.zones and options.sea and mix > 0 and art < 1
		local showPaint = mix > 0 and group.hasPaint
		group.root:SetShown(detail > 0 and (art > 0 or sea or showPaint))
		group.root:SetAlpha(detail)
		group.art:SetShown(art > 0)
		group.art:SetAlpha(art)
		if group.sea then
			group.sea:SetShown(sea)
		end
		group.paint:SetShown(showPaint)
		group.paint:SetAlpha(mix)
		if detail > 0 and (sea or showPaint) and group.seaInfo then
			self:UpdateSea(group, w, h)
		end
		if detail > 0 and showPaint then
			self:UpdatePaint(group, w, h, city, early)
		end
	end

	-- The terrain is loaded a little before the paintings start to fade, so it is there when they do.
	local wantTerrain = options.terrain and ypp < options.terrainNone * 1.25
	if wantTerrain then
		self:UpdateTiles(w, h)
	else
		self:ReleaseTiles()
		self.pending = false
	end

	local stats = self.stats
	stats.alpha, stats.zoneAlpha, stats.cityAlpha, stats.pending = 1 - detail, mix, city, self.pending
	stats.art = group and #group.artPlaced or 0
	stats.cities = group and #group.cities or 0
	stats.ms = debugprofilestop() - started
	if self.onUpdate then
		self.onUpdate(self)
	end
end

function Proto:UpdateTiles(w, h)
	local data = Canvas.TileData(self.continent)
	if not data then
		return
	end
	local files, fades = data.files, self.options.fade and data.fade or nil
	local ypp, cx, cy, margin = self.ypp, self.cx, self.cy, self.options.margin
	local halfW, halfH = w / 2 * ypp, h / 2 * ypp
	local txMin = max(0, floor(32 - (cy + halfW) / TILE) - margin)
	local txMax = min(63, floor(32 - (cy - halfW) / TILE) + margin)
	local tyMin = max(0, floor(32 - (cx + halfH) / TILE) - margin)
	local tyMax = min(63, floor(32 - (cx - halfH) / TILE) + margin)

	local stamp = self.stamp + 1
	self.stamp = stamp
	local tiles, started, pending = self.tiles, 0, false
	for tx = txMin, txMax do
		for ty = tyMin, tyMax do
			local key = tx * 64 + ty
			local fileID = files[key]
			if fileID then
				local rec = tiles[key]
				if rec then
					rec.stamp = stamp
				elseif started < Canvas.NEW_TILES_PER_FRAME then
					started = started + 1
					rec = self:AcquireTile(fileID, fades and fades[key])
					rec.stamp = stamp
					tiles[key] = rec
					self:PlaceTile(key, rec)
				else
					pending = true
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
		mask:SetTexture(FADE_PATH .. fadeKey, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
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
		return x0 - v * 668 * kx, y0 - u * 1002 * ky
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

function Proto:BuildPaint()
	local continent = self.continent
	local group = { placed = {}, artPlaced = {}, levels = {}, cities = {}, banners = {} }
	self.groups[continent] = group
	local data, paint = ns.MapArt, PaintData(continent)

	-- Everything painted, in one frame that fades out over the terrain.
	group.root = self:Layer(2)
	group.art = self:Layer(3, group.root)
	group.paint = self:Layer(4, group.root)

	-- The continent's own painting.
	local artMap = Canvas.ArtMapFor(continent)
	local artRect = artMap and Coords.GetMapRect(artMap)
	if artRect then
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
			group.cities[#group.cities + 1] = { frame = frame, early = entry.early, north = x0, west = y0, south = x1, east = y1 }
			-- The zone's banner for the city gives way to the city's own map (which has its own small label).
			AddBanner(cityID, entry, true)
		end
	end
	for cityID, entry in pairs(data and data.underground or {}) do
		AddBanner(cityID, entry, false)
	end

	group.hasPaint = #group.levels > 0 or #group.cities > 0
	if self.layoutYpp then
		self:PlaceAll(group.placed)
	end
	return group
end

-- A repeating texture over world rectangle `box`, a tile every sx by sy yards, fixed on the world (shifted by
-- `shift` tiles, so two sizes of one pattern don't line up).
function Proto:TileOver(tex, box, sx, sy, alpha, shift)
	if not tex then
		return
	end
	if alpha <= 0.01 then
		tex:Hide()
		return
	end
	local o = shift or 0
	tex:SetTexCoord(-box.west / sx + o, -box.east / sx + o, -box.north / sy + o * 1.6, -box.south / sy + o * 1.6)
	self:Place(tex, box.north, box.west, box.south, box.east)
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
	local ypp, cx, cy = self.ypp, self.cx, self.cy
	local halfW, halfH = w / 2 * ypp, h / 2 * ypp
	local box = group.seaBox
	if box and box.ypp == ypp and box.ax == self.anchorX and box.ay == self.anchorY and cx + halfH * 1.2 < box.north
		and cx - halfH * 1.2 > box.south and cy + halfW * 1.2 < box.west and cy - halfW * 1.2 > box.east then
		return
	end
	box = { ypp = ypp, ax = self.anchorX, ay = self.anchorY, north = cx + halfH * 1.8, south = cx - halfH * 1.8,
		west = cy + halfW * 1.8, east = cy - halfW * 1.8 }
	group.seaBox = box
	local info = group.seaInfo
	local n, f = Octaves(info.tile / ypp, info.tileMax)
	local size = info.tile / 2 ^ n
	for i = 1, 2 do
		self:TileOver(group.paper[i], box, size, size, 1 - f, (n * 0.37) % 1)
		self:TileOver(group.paper[i + 2], box, size / 2, size / 2, f, ((n + 1) * 0.37) % 1)
	end
	local a = ns.MapArt.sea.hatchAlpha
	n, f = Octaves(info.hatch[1] / ypp, info.hatchMax)
	local hw, hh = info.hatch[1] / 2 ^ n, info.hatch[2] / 2 ^ n
	self:TileOver(group.hatch[1], box, hw, hh, a * math.sqrt(1 - f))
	self:TileOver(group.hatch[2], box, hw / 2, hh / 2, a * math.sqrt(f))
end

-- Per redraw: the tiles of the size that shows (and of each coarser one where there are no finer ones) in view, the
-- next finer size's loaded as it nears, every other tile's file let go; cities out of view hidden, and the city maps
-- and their zones' banners trading places by `city` (0 = banners, 1 = city maps). An early city's map is in by
-- `early` already, under its banner.
function Proto:UpdatePaint(group, w, h, city, early)
	local ypp, cx, cy = self.ypp, self.cx, self.cy
	local halfW, halfH = w / 2 * ypp, h / 2 * ypp
	local north, south, west, east = cx + halfH, cx - halfH, cy + halfW, cy - halfW
	-- (tiles a little past the view count as in it, so they are loaded before they scroll in)
	local mh, mw = halfH * 0.25, halfW * 0.25
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
					self:Place(t.tex, t.north, t.west, t.south, t.east)
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
		local alpha = c.early and max(city, early) or city
		c.frame:SetShown(alpha > 0 and InView(c, north, south, west, east))
		c.frame:SetAlpha(alpha)
	end
	for _, b in ipairs(group.banners) do
		local alpha = b.fades and 1 - city or 1
		b.frame:SetShown(alpha > 0 and InView(b, north, south, west, east))
		b.frame:SetAlpha(alpha)
	end
	self.stats.zones = shown
	self.stats.level = levels[show] and levels[show].kind
end
