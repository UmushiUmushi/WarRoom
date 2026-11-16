-- Coordinates. Everything in WarRoom is stored once, in world yards on a continent (the game's instance ID), and
-- converted to a map, minimap or tile position only when it is drawn.
--
-- World frame (the game's, as UnitPosition returns it): x grows north, y grows west.
-- Terrain tiles: a continent is 64 x 64 tiles of 1600/3 yards. Tile column tx grows east and row ty grows south;
-- tile (32, 32) starts at world (0, 0). Minimap textures are named after the same grid (mapTX_TY).
-- Map rectangles: a uiMap covers world x from `top` (north edge) down to `bottom`, and world y from `left` (west
-- edge) down to `right`; map u grows east (0 at the west edge) and v grows south (0 at the north edge).
--
-- The top half is pure Lua (unit-tested outside the game); the bottom half uses the game's map API.
local _, ns = ...

local Coords = {}
ns.Coords = Coords
if ns.WR then
	ns.WR.Coords = Coords
end

local floor, sqrt, atan2, pi = math.floor, math.sqrt, math.atan2, math.pi

local TILE = 1600 / 3
Coords.TILE_YARDS = TILE
Coords.TILES = 64

---------------------------------------------------------------------------------------------------
-- Pure maths
---------------------------------------------------------------------------------------------------

-- World (x, y) to its terrain tile and the fraction across it: fx grows east, fy grows south (0 to 1).
function Coords.WorldToTile(x, y)
	local gx, gy = 32 - y / TILE, 32 - x / TILE
	local tx, ty = floor(gx), floor(gy)
	return tx, ty, gx - tx, gy - ty
end

-- A point in tile (tx, ty), fx/fy across it (default its north-west corner), to world (x, y).
function Coords.TileToWorld(tx, ty, fx, fy)
	return (32 - (ty + (fy or 0))) * TILE, (32 - (tx + (fx or 0))) * TILE
end

-- One number per tile, for tables keyed by tile.
function Coords.TileKey(tx, ty)
	return tx * 64 + ty
end

function Coords.NewRect(continent, top, left, bottom, right)
	return {
		continent = continent,
		top = top,
		left = left,
		bottom = bottom,
		right = right,
		height = top - bottom,
		width = left - right,
	}
end

-- World (x, y) to (u, v) in a rectangle (0 to 1 inside it).
function Coords.WorldToRect(rect, x, y)
	return (rect.left - y) / rect.width, (rect.top - x) / rect.height
end

-- (u, v) in a rectangle to world (x, y).
function Coords.RectToWorld(rect, u, v)
	return rect.top - v * rect.height, rect.left - u * rect.width
end

function Coords.Distance(x1, y1, x2, y2)
	local dx, dy = x2 - x1, y2 - y1
	return sqrt(dx * dx + dy * dy)
end

-- Direction from point 1 to point 2 in radians, counter-clockwise from north (as GetPlayerFacing), 0 to 2*pi.
function Coords.Bearing(x1, y1, x2, y2)
	local angle = atan2(y2 - y1, x2 - x1)
	if angle < 0 then
		angle = angle + 2 * pi
	end
	return angle
end

---------------------------------------------------------------------------------------------------
-- Game map API (in game only)
---------------------------------------------------------------------------------------------------
local rectCache = {}

-- The world rectangle a uiMap covers, or nil when it has none (the world map, some dungeons).
function Coords.GetMapRect(uiMapID)
	local cached = rectCache[uiMapID]
	if cached ~= nil then
		return cached or nil
	end
	local rect = false
	local c1, topLeft = C_Map.GetWorldPosFromMapPos(uiMapID, CreateVector2D(0, 0))
	local c2, bottomRight = C_Map.GetWorldPosFromMapPos(uiMapID, CreateVector2D(1, 1))
	if c1 and c1 == c2 and topLeft and bottomRight then
		local top, left = topLeft:GetXY()
		local bottom, right = bottomRight:GetXY()
		if top ~= bottom and left ~= right then
			rect = Coords.NewRect(c1, top, left, bottom, right)
		end
	end
	rectCache[uiMapID] = rect
	return rect or nil
end

-- World position to (u, v) on a uiMap, or nil when the map is on another continent or has no rectangle.
function Coords.WorldToMap(uiMapID, continent, x, y)
	local rect = Coords.GetMapRect(uiMapID)
	if not rect or rect.continent ~= continent then
		return nil
	end
	return Coords.WorldToRect(rect, x, y)
end

-- (u, v) on a uiMap to continent, x, y; nil when the map has no rectangle.
function Coords.MapToWorld(uiMapID, u, v)
	local rect = Coords.GetMapRect(uiMapID)
	if not rect then
		return nil
	end
	local x, y = Coords.RectToWorld(rect, u, v)
	return rect.continent, x, y
end
