-- The player's position, the one place WarRoom asks the game for it.
-- Fires WR_POSITION(continent, x, y) when the player moves, WR_POSITION_LOST when the game stops giving a
-- position (inside instances), and WR_ZONE(state) on zone, subzone and indoor changes.
-- The game gives no usable height, so floors are worked out by the Layers module, not here.
local _, ns = ...
local WR = ns.WR

local Position = {}
WR.Position = Position

local abs = math.abs
-- Forever can hide some values from addons ("secret" values); older clients have no such check.
local canaccess = canaccessvalue or function()
	return true
end

local MOVING_INTERVAL = 0.1 -- seconds between samples while moving
local IDLE_INTERVAL = 1.0 -- and while standing still
local MIN_MOVE = 0.05 -- yards; smaller changes are not a move

-- Everything known about where the player is. Read it; don't change it.
-- known, continent, x, y, source ("unit" or "map"), mapID, inInstance (type or nil), zone, subzone,
-- minimapZone, indoors
local state = { known = false }
Position.state = state

-- A unit's position: continent, x, y, source; nil where the game withholds it.
-- UnitPosition first; when its values are hidden, the unit's map position converted to world yards.
function Position.Read(unit)
	unit = unit or "player"
	local x, y, _, continent = UnitPosition(unit)
	if canaccess(x) and canaccess(y) and canaccess(continent) and x and y and continent then
		return continent, x, y, "unit"
	end
	local uiMap = C_Map.GetBestMapForUnit(unit)
	if not (uiMap and canaccess(uiMap)) then
		return nil
	end
	local position = C_Map.GetPlayerMapPosition(uiMap, unit)
	if not (position and canaccess(position)) then
		return nil
	end
	local u, v = position:GetXY()
	if not (u and v and canaccess(u) and canaccess(v)) then
		return nil
	end
	local c, wx, wy = WR.Coords.MapToWorld(uiMap, u, v)
	if not c then
		return nil
	end
	return c, wx, wy, "map"
end

-- The player's last known continent, x, y, or nil.
function Position.Get()
	if state.known then
		return state.continent, state.x, state.y
	end
end

local function Sample()
	local continent, x, y, source = Position.Read("player")
	if not continent then
		if state.known then
			state.known = false
			WR.Fire("WR_POSITION_LOST")
		end
		return
	end
	local moved = not state.known
		or continent ~= state.continent
		or abs(x - state.x) > MIN_MOVE
		or abs(y - state.y) > MIN_MOVE
	state.known, state.continent, state.x, state.y, state.source = true, continent, x, y, source
	if moved then
		WR.Fire("WR_POSITION", continent, x, y)
	end
end
Position.Sample = Sample

local function IsMoving()
	local speed = GetUnitSpeed("player")
	if not canaccess(speed) then
		return true
	end
	return (speed and speed > 0) or UnitOnTaxi("player")
end

local elapsed = 0
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, dt)
	elapsed = elapsed + dt
	if elapsed >= (IsMoving() and MOVING_INTERVAL or IDLE_INTERVAL) then
		elapsed = 0
		Sample()
	end
end)

local function ZoneChanged()
	local mapID = C_Map.GetBestMapForUnit("player")
	state.mapID = canaccess(mapID) and mapID or nil
	local inInstance, instanceType = IsInInstance()
	state.inInstance = inInstance and instanceType or nil
	state.zone = GetRealZoneText()
	state.subzone = GetSubZoneText()
	state.minimapZone = GetMinimapZoneText()
	state.indoors = IsIndoors()
	WR.Fire("WR_ZONE", state)
	Sample()
end

for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA" }) do
	WR.OnEvent(event, ZoneChanged)
end
WR.OnEvent("PLAYER_STARTED_MOVING", Sample)
