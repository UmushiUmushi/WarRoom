-- Zones: which map (zone or city) owns a point of ground, the zone a city lies in, and each zone's outline, from
-- Data/Zones.lua (`warroom zones`: the terrain's own area for every 33-yard chunk). Pure Lua (unit-tested outside
-- the game).
local _, ns = ...

local Zones = {}
ns.Zones = Zones
if ns.WR then
	ns.WR.Zones = Zones
end

local floor = math.floor
local TILE = 1600 / 3
local CHUNK = TILE / 16
local EDGE = 32 * TILE -- world x (and y) of the continent's north (and west) edge
local SIZE = 64 * 16 -- chunks per side

-- The map owning world (x, y) of a continent: a zone or a city, nil out at sea or off the data.
function Zones.At(continent, x, y)
	local data = ns.ZoneData
	local map = data and data.maps[continent]
	if not map or not x then
		return nil
	end
	local row, col = floor((EDGE - x) / CHUNK), floor((EDGE - y) / CHUNK)
	local runs = map.rows[row]
	if not runs or col < 0 or col >= SIZE then
		return nil
	end
	-- the last run starting at or before the column (runs[2k - 1] = its first column, runs[2k] = its map)
	local lo, hi = 1, #runs / 2
	while lo < hi do
		local mid = floor((lo + hi + 1) / 2)
		if runs[mid * 2 - 1] <= col then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local index = runs[lo * 2]
	return index > 0 and map.ids[index] or nil
end

-- The zone a map lies in: a city's zone, else the map itself.
function Zones.ZoneOf(mapID)
	local data = ns.ZoneData
	return data and data.cities[mapID] or mapID
end

function Zones.IsCity(mapID)
	local data = ns.ZoneData
	return data and data.cities[mapID] ~= nil or false
end

-- The zones of Kalimdor and the Eastern Kingdoms (not the cities).
function Zones.List()
	local data = ns.ZoneData
	return data and data.zones or {}
end

-- A map's outline: its continent and { { x, y, x, y, ... }, ... } rings of world yards round its dry ground; nil
-- when there is none.
function Zones.Outline(mapID)
	local data = ns.ZoneData
	for continent, map in pairs(data and data.maps or {}) do
		local rings = map.borders[mapID]
		if rings then
			return continent, rings
		end
	end
end

-- A map's hover glow: its continent, { north, west, south, east } world rectangle and texture (Media/Glow, in the
-- game's highlight style over the map's own ground); nil when it has none.
function Zones.Glow(mapID)
	local data = ns.ZoneData
	for continent, map in pairs(data and data.maps or {}) do
		local rect = map.glows and map.glows[mapID]
		if rect then
			return continent, rect, ("Interface\\AddOns\\WarRoom\\Media\\Glow\\glow_%d"):format(mapID)
		end
	end
end

-- The veil round a map once the view is on it: its continent, { north, west, south, east } world rectangle and
-- texture (Media/Veil: white, clear over the map's ground, its cities and lakes, opaque round it, feathered
-- between); nil when it has none.
function Zones.Veil(mapID)
	local data = ns.ZoneData
	for continent, map in pairs(data and data.maps or {}) do
		local rect = map.veils and map.veils[mapID]
		if rect then
			return continent, rect, ("Interface\\AddOns\\WarRoom\\Media\\Veil\\veil_%d"):format(mapID)
		end
	end
end

-- The pieces of a continent's zone maps the player explores: { { uiMapID, key, overlayID, north, west, south, east },
-- ... }, key "w:h:x:y" as C_MapExplorationInfo.GetExploredMapTextures gives them, and the world rectangle of the dark
-- over each until it is (Media/Fog/fog_<overlayID>: white, its alpha the piece's share of the dark, baked so that
-- any of them laid together darken as one).
function Zones.Pieces(continent)
	local data = ns.ZoneData
	local map = data and data.maps[continent]
	return map and map.pieces or {}
end

-- The cities drawn on the surface, and the zone each lies in: for city, zone in Zones.Cities() do ... end
function Zones.Cities()
	local data = ns.ZoneData
	return pairs(data and data.cities or {})
end
