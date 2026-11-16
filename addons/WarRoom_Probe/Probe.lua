-- WarRoom Probe: checks what the WoW Forever client lets addons do, for designing WarRoom. Not for release.
-- Runs quietly each time you enter the world (login, reload, entering or leaving a dungeon) and keeps the last
-- 30 runs in WarRoomProbeDB (written to disk on /reload or logout).
--   /wrprobe        run now and print every result
--   /wrprobe tile [fileID]  show the minimap terrain tile you stand on, with a red dot where you are
--                           (by path, or by file ID when given)
--   /wrprobe pins   list other addons' map icons (HereBeDragons-Pins copies, who adds what, how they look)
--   /wrprobe clear  forget stored runs
local addonName = ...

local canaccess = canaccessvalue or function()
	return true
end

local TILE = 1600 / 3
local TILE_FOLDERS = { [0] = "Azeroth", [1] = "Kalimdor" }

local function Show(v)
	if not canaccess(v) then
		return "<secret>"
	end
	if type(v) == "number" then
		return (v == math.floor(v)) and tostring(v) or string.format("%.3f", v)
	end
	return tostring(v)
end

local function Join(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = Show((select(i, ...)))
	end
	return table.concat(parts, ", ")
end

-- Each check returns ok (true, false, or nil for information only) and a detail string.
local checks = {}
local function Check(name, fn)
	checks[#checks + 1] = { name = name, fn = fn }
end

Check("build", function()
	local version, build, date, interface = GetBuildInfo()
	return nil, Join(version, build, date, interface)
end)

Check("saved variables", function()
	local db = WarRoomProbeDB
	return db.loads > 1, string.format("loaded %d times; first %s", db.loads, tostring(db.firstLoad))
end)

Check("secret value API", function()
	return nil, string.format("canaccessvalue %s, issecretvalue %s", type(canaccessvalue), type(issecretvalue))
end)

Check("context", function()
	local inInstance, instanceType = IsInInstance()
	local name, iType, difficulty, _, _, _, _, instanceID = GetInstanceInfo()
	return nil,
		string.format(
			"zone %s / %s / minimap %s; indoors %s; instance %s (%s) %s id %s diff %s",
			Show(GetRealZoneText()),
			Show(GetSubZoneText()),
			Show(GetMinimapZoneText()),
			Show(IsIndoors()),
			Show(inInstance),
			Show(instanceType),
			Show(name),
			Show(instanceID),
			Show(difficulty)
		)
end)

Check("UnitPosition", function()
	local x, y, z, continent = UnitPosition("player")
	local ok = canaccess(x) and x ~= nil
	return ok, "x, y, z, continent = " .. Join(x, y, z, continent)
end)

Check("map position", function()
	local uiMap = C_Map.GetBestMapForUnit("player")
	if not uiMap or not canaccess(uiMap) then
		return false, "no best map: " .. Show(uiMap)
	end
	local info = C_Map.GetMapInfo(uiMap)
	local position = C_Map.GetPlayerMapPosition(uiMap, "player")
	if not position then
		return false, string.format("map %s (%s, type %s): no position", Show(uiMap), Show(info and info.name), Show(info and info.mapType))
	end
	local u, v = position:GetXY()
	return canaccess(u) and u ~= nil,
		string.format("map %s (%s, type %s) u, v = %s", Show(uiMap), Show(info and info.name), Show(info and info.mapType), Join(u, v))
end)

-- Our conversion: map position -> world yards via the map's corners, compared with UnitPosition.
Check("map to world matches UnitPosition", function()
	local x, y, _, continent = UnitPosition("player")
	local uiMap = C_Map.GetBestMapForUnit("player")
	local position = uiMap and C_Map.GetPlayerMapPosition(uiMap, "player")
	if not (x and position and canaccess(x)) then
		return nil, "skipped: needs both positions"
	end
	local c1, tl = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(0, 0))
	local c2, br = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(1, 1))
	if not (tl and br) then
		return false, "map has no world rectangle"
	end
	local top, left = tl:GetXY()
	local bottom, right = br:GetXY()
	local u, v = position:GetXY()
	local wx, wy = top - v * (top - bottom), left - u * (left - right)
	local off = math.sqrt((wx - x) ^ 2 + (wy - y) ^ 2)
	return off < 2 and c1 == continent,
		string.format("off by %.2f yd; continents %s/%s vs %s; rect top %.1f left %.1f bottom %.1f right %.1f", off, Show(c1), Show(c2), Show(continent), top, left, bottom, right)
end)

Check("HereBeDragons", function()
	local LibStub = _G.LibStub
	if not LibStub then
		return false, "no LibStub: no installed addon loaded HereBeDragons"
	end
	local hbd, minor = LibStub("HereBeDragons-2.0", true)
	if not hbd then
		return false, "not loaded by any installed addon"
	end
	local _, pinsMinor = LibStub("HereBeDragons-Pins-2.0", true)
	local wx, wy, instance = hbd:GetPlayerWorldPosition()
	local zx, zy, zoneMap = hbd:GetPlayerZonePosition()
	return wx ~= nil,
		string.format("minor %s, pins minor %s; world %s; zone %s", Show(minor), Show(pinsMinor), Join(wx, wy, instance), Join(zx, zy, zoneMap))
end)

Check("zlib + base64", function()
	if not C_EncodingUtil then
		return false, "no C_EncodingUtil"
	end
	local text = string.rep("WarRoom probe ", 50)
	local packed = C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(text, Enum.CompressionMethod.Zlib))
	local back = C_EncodingUtil.DecompressString(C_EncodingUtil.DecodeBase64(packed), Enum.CompressionMethod.Zlib)
	return back == text, string.format("%d bytes -> %d base64 chars", #text, #packed)
end)

Check("minimap API", function()
	local zoom = Minimap.GetZoom and Minimap:GetZoom()
	local levels = Minimap.GetZoomLevels and Minimap:GetZoomLevels()
	return nil,
		string.format(
			"C_Minimap.SetDrawGroundTextures %s, Minimap:SetMaskTexture %s, GetMinimapShape %s (%s), zoom %s of %s, rotate %s",
			type(C_Minimap and C_Minimap.SetDrawGroundTextures),
			type(Minimap.SetMaskTexture),
			type(GetMinimapShape),
			Show(GetMinimapShape and GetMinimapShape()),
			Show(zoom),
			Show(levels),
			Show(GetCVar("rotateMinimap"))
		)
end)

Check("flight paths without a flight master", function()
	local uiMap = C_Map.GetBestMapForUnit("player")
	if not (C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap and uiMap) then
		return false, "no C_TaxiMap.GetTaxiNodesForMap"
	end
	local states = {}
	local continent = uiMap
	local info = C_Map.GetMapInfo(uiMap)
	while info and info.mapType and info.mapType > Enum.UIMapType.Continent and info.parentMapID do
		continent = info.parentMapID
		info = C_Map.GetMapInfo(continent)
	end
	local nodes = C_TaxiMap.GetTaxiNodesForMap(continent) or {}
	for _, node in ipairs(nodes) do
		local state = node.state == nil and "none" or Show(node.state)
		states[state] = (states[state] or 0) + 1
	end
	local parts = {}
	for state, n in pairs(states) do
		parts[#parts + 1] = state .. "=" .. n
	end
	-- What one node carries, to learn the shape of the data.
	local fields = {}
	for key, value in pairs(nodes[1] or {}) do
		fields[#fields + 1] = tostring(key) .. "=" .. (type(value) == "table" and "{}" or Show(value))
	end
	table.sort(fields)
	-- Every node as name(faction, undiscovered flag, atlas): does isUndiscovered mean "not learned by you"?
	local list = {}
	for _, node in ipairs(nodes) do
		list[#list + 1] = string.format(
			"%s(%s,%s,%s)",
			Show(node.name):match("^[^,]+") or "?",
			Show(node.faction),
			node.isUndiscovered and "U" or "-",
			(Show(node.atlasName):gsub("^TaxiNode_", ""))
		)
	end
	WarRoomProbeDB.taxiNodes = table.concat(list, "; ")
	return #nodes > 0,
		string.format(
			"map %s: %d nodes; by state %s; GetAllTaxiNodes %s; first node: %s",
			Show(continent),
			#nodes,
			table.concat(parts, " "),
			type(C_TaxiMap.GetAllTaxiNodes),
			table.concat(fields, ", ")
		)
end)

Check("explored areas", function()
	local uiMap = C_Map.GetBestMapForUnit("player")
	local list = uiMap and C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures(uiMap)
	return list ~= nil, string.format("map %s: %s explored overlays", Show(uiMap), Show(list and #list))
end)

Check("minimap tile file", function()
	local x, y, _, continent = UnitPosition("player")
	local folder = continent and canaccess(continent) and TILE_FOLDERS[continent]
	if not (folder and canaccess(x)) then
		return nil, "skipped: not on Azeroth or Kalimdor, or no position"
	end
	local tx, ty = math.floor(32 - y / TILE), math.floor(32 - x / TILE)
	local path = string.format("World\\Minimaps\\%s\\map%d_%d.blp", folder, tx, ty)
	local fileID = GetFileIDFromPath and GetFileIDFromPath(path)
	return fileID ~= nil, string.format("%s -> GetFileIDFromPath %s (function %s)", path, Show(fileID), type(GetFileIDFromPath))
end)

---------------------------------------------------------------------------------------------------

local function Run(print)
	local run = { time = date("%Y-%m-%d %H:%M:%S"), results = {} }
	for _, check in ipairs(checks) do
		local okCall, ok, detail = pcall(check.fn)
		if not okCall then
			ok, detail = false, "error: " .. tostring(ok)
		end
		run.results[#run.results + 1] = { name = check.name, ok = ok, detail = detail }
		if print then
			local tag = ok == true and "|cff44ff44ok|r" or ok == false and "|cffff5555no|r" or "|cffaaaaaainfo|r"
			DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff4fc3f7Probe|r [%s] %s: %s", tag, check.name, tostring(detail)))
		end
	end
	local runs = WarRoomProbeDB.runs
	table.insert(runs, run)
	while #runs > 30 do
		table.remove(runs, 1)
	end
	return run
end

-- The tile under the player, with a dot where the player stands. Shows whether minimap tiles load by path and
-- whether our tile maths puts you in the right place.
-- fileID: load the tile by file ID instead of by path (look IDs up on wago.tools).
local tileFrame
local function ShowTile(fileID)
	local x, y, _, continent = UnitPosition("player")
	local folder = continent and canaccess(continent) and TILE_FOLDERS[continent]
	if not (folder and canaccess(x)) then
		DEFAULT_CHAT_FRAME:AddMessage("|cff4fc3f7Probe|r: needs a position on Azeroth or Kalimdor")
		return
	end
	local gx, gy = 32 - y / TILE, 32 - x / TILE
	local tx, ty = math.floor(gx), math.floor(gy)
	if not tileFrame then
		tileFrame = CreateFrame("Frame", "WarRoomProbeTile", UIParent, "BackdropTemplate")
		tileFrame:SetSize(276, 300)
		tileFrame:SetPoint("CENTER")
		tileFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
		tileFrame:SetBackdropColor(0, 0, 0, 0.85)
		tileFrame:EnableMouse(true)
		tileFrame:SetScript("OnMouseDown", tileFrame.Hide)
		tileFrame.title = tileFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		tileFrame.title:SetPoint("TOP", 0, -6)
		tileFrame.tex = tileFrame:CreateTexture(nil, "ARTWORK")
		tileFrame.tex:SetSize(256, 256)
		tileFrame.tex:SetPoint("TOPLEFT", 10, -32)
		tileFrame.dot = tileFrame:CreateTexture(nil, "OVERLAY")
		tileFrame.dot:SetSize(6, 6)
		tileFrame.dot:SetColorTexture(1, 0, 0, 1)
	end
	local path = string.format("World\\Minimaps\\%s\\map%d_%d.blp", folder, tx, ty)
	local loaded = tileFrame.tex:SetTexture(fileID or path)
	local name = path:match("[^\\]+$") .. (fileID and (" as file " .. fileID) or " by path")
	tileFrame.title:SetText(string.format("%s  (SetTexture %s)  click to close", name, tostring(loaded)))
	tileFrame.dot:SetPoint("CENTER", tileFrame.tex, "TOPLEFT", (gx - tx) * 256, -(gy - ty) * 256)
	tileFrame:Show()
	DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff4fc3f7Probe|r: %s, SetTexture returned %s, texture %s", path, tostring(loaded), tostring(tileFrame.tex:GetTexture())))
end

-- At a flight master: the classic slot list (TaxiNodeGetType: CURRENT/REACHABLE = learned, DISTANT = not, per
-- Shortest Path Forever's notes) next to the newer C_TaxiMap query, to see which one tells learned points apart.
local function CaptureFlightMaster()
	local slots = {}
	local byType = {}
	for i = 1, NumTaxiNodes() do
		local kind = Show(TaxiNodeGetType(i))
		byType[kind] = (byType[kind] or 0) + 1
		slots[#slots + 1] = string.format("%s(%s)", Show(TaxiNodeName(i)):match("^[^,]+") or "?", kind)
	end
	local uiMap = GetTaxiMapID and GetTaxiMapID() or C_Map.GetBestMapForUnit("player")
	local states = {}
	for _, node in ipairs(C_TaxiMap.GetAllTaxiNodes(uiMap) or {}) do
		local state = node.state == nil and "none" or Show(node.state)
		states[state] = (states[state] or 0) + 1
	end
	local function Summary(counts)
		local parts = {}
		for k, n in pairs(counts) do
			parts[#parts + 1] = k .. "=" .. n
		end
		table.sort(parts)
		return table.concat(parts, " ")
	end
	WarRoomProbeDB.flightMaster = {
		time = date("%Y-%m-%d %H:%M:%S"),
		map = uiMap,
		slotTypes = Summary(byType),
		allTaxiNodesStates = Summary(states),
		slots = table.concat(slots, "; "),
	}
	DEFAULT_CHAT_FRAME:AddMessage(
		string.format("|cff4fc3f7Probe|r: flight master captured (%d slots: %s). /reload to save.", #slots, Summary(byType))
	)
end

---------------------------------------------------------------------------------------------------
-- Other addons' map icons: every copy of HereBeDragons-Pins (LibStub's, renamed ones, Questie's private module),
-- who adds icons through it, how many, and what they look like. Read only, apart from post-hooks that watch the
-- Add functions (they run after the original, which is unchanged).
---------------------------------------------------------------------------------------------------
local pinCallers = {} -- [library name][ref name] = addon folder that called Add...
local hooked = {}

local function RefName(ref)
	if type(ref) == "string" then
		return ref
	elseif type(ref) == "table" then
		local name = rawget(ref, "name") or rawget(ref, "baseName") or rawget(ref, "moduleName")
		if type(name) == "string" then
			return name
		end
	end
	return type(ref)
end

local function PinLibraries()
	local found = {}
	if LibStub and LibStub.IterateLibraries then
		for name, lib in LibStub:IterateLibraries() do
			if type(name) == "string" and name:find("HereBeDragons") and name:find("Pins") then
				found[#found + 1] = { name = name .. " r" .. tostring(LibStub.minors[name]), lib = lib }
			end
		end
	end
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	if QuestieLoader and loaded and loaded("Questie") then
		local ok, lib = pcall(QuestieLoader.ImportModule, QuestieLoader, "HBDPins")
		if ok and type(lib) == "table" and rawget(lib, "minimapPins") then
			found[#found + 1] = { name = "Questie HBDPins", lib = lib }
		end
	end
	return found
end

-- The addon folder in the call stack that called into the library (not the library file, not the probe).
local function CallerAddon()
	local stack = debugstack(3, 12, 0) or ""
	for line in stack:gmatch("[^\n]+") do
		local addon = line:match("AddOns[/\\]([^/\\]+)[/\\]")
		if addon and addon ~= addonName and not line:find("HereBeDragons") then
			return addon
		end
	end
	return "?"
end

local function HookPinLibraries()
	for _, entry in ipairs(PinLibraries()) do
		local lib = entry.lib
		if not hooked[lib] then
			hooked[lib] = true
			local callers = {}
			pinCallers[entry.name] = callers
			for _, fn in ipairs({ "AddWorldMapIconWorld", "AddWorldMapIconMap", "AddMinimapIconWorld", "AddMinimapIconMap" }) do
				if type(lib[fn]) == "function" then
					hooksecurefunc(lib, fn, function(_, ref)
						local name = RefName(ref)
						if not callers[name] then
							callers[name] = CallerAddon()
						end
					end)
				end
			end
		end
	end
end

-- How an icon frame looks: its main texture's file or atlas, else "text" or "?".
local function IconLook(icon)
	if type(icon) ~= "table" or not icon.GetRegions then
		return "?"
	end
	for _, field in ipairs({ "texture", "icon", "Icon", "Texture", "tex" }) do
		local region = rawget(icon, field)
		if type(region) == "table" and region.GetTexture then
			return tostring(region.GetAtlas and region:GetAtlas() or region:GetTexture())
		end
	end
	for _, region in ipairs({ icon:GetRegions() }) do
		if region.GetObjectType and region:GetObjectType() == "Texture" then
			return tostring(region.GetAtlas and region:GetAtlas() or region:GetTexture())
		end
	end
	return "text?"
end

local function PinCensus()
	local lines = {}
	for _, entry in ipairs(PinLibraries()) do
		local lib = entry.lib
		local callers = pinCallers[entry.name] or {}
		for _, kind in ipairs({ "worldmap", "minimap" }) do
			local registry, pins = rawget(lib, kind .. "PinRegistry"), rawget(lib, kind .. "Pins")
			local total, sample = 0, nil
			for icon, data in pairs(pins or {}) do
				total = total + 1
				if not sample and type(data) == "table" then
					local fields = {}
					for k, v in pairs(data) do
						fields[#fields + 1] = k .. "=" .. Show(v)
					end
					table.sort(fields)
					sample = table.concat(fields, " ")
				end
			end
			local refs = {}
			for ref, icons in pairs(registry or {}) do
				local n, looks, lookCount = 0, {}, 0
				for icon in pairs(icons) do
					n = n + 1
					local look = IconLook(icon)
					if not looks[look] then
						looks[look] = 0
						lookCount = lookCount + 1
					end
					looks[look] = looks[look] + 1
				end
				if n > 0 then
					local name = RefName(ref)
					local top = {}
					for look, c in pairs(looks) do
						top[#top + 1] = { look, c }
					end
					table.sort(top, function(p, q)
						return p[2] > q[2]
					end)
					local shown = {}
					for i = 1, math.min(4, #top) do
						shown[i] = top[i][1] .. " x" .. top[i][2]
					end
					refs[#refs + 1] = string.format("%s (from %s): %d icons, %d looks [%s]", name, callers[name] or "not seen adding", n, lookCount, table.concat(shown, ", "))
				end
			end
			table.sort(refs)
			lines[#lines + 1] = string.format("%s %s: %d icons%s", entry.name, kind, total, sample and (" e.g. {" .. sample .. "}") or "")
			for _, r in ipairs(refs) do
				lines[#lines + 1] = "    " .. r
			end
		end
	end
	if #lines == 0 then
		lines[1] = "no HereBeDragons-Pins found"
	end
	WarRoomProbeDB.pinCensus = { time = date("%Y-%m-%d %H:%M:%S"), lines = lines }
	return lines
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("TAXIMAP_OPENED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "PLAYER_LOGIN" then
		HookPinLibraries()
	elseif event == "TAXIMAP_OPENED" then
		local ok, err = pcall(CaptureFlightMaster)
		if not ok then
			WarRoomProbeDB.flightMaster = { error = tostring(err) }
			DEFAULT_CHAT_FRAME:AddMessage("|cff4fc3f7Probe|r: flight master capture failed: " .. tostring(err))
		end
	elseif event == "ADDON_LOADED" and arg1 == addonName then
		WarRoomProbeDB = WarRoomProbeDB or {}
		local db = WarRoomProbeDB
		db.loads = (db.loads or 0) + 1
		db.firstLoad = db.firstLoad or date("%Y-%m-%d %H:%M:%S")
		db.runs = db.runs or {}
	elseif event == "PLAYER_ENTERING_WORLD" then
		C_Timer.After(3, function()
			local run = Run(false)
			local yes, no = 0, 0
			for _, r in ipairs(run.results) do
				if r.ok == true then
					yes = yes + 1
				elseif r.ok == false then
					no = no + 1
				end
			end
			DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff4fc3f7WarRoom Probe|r: %d ok, %d no (stored; /wrprobe prints them)", yes, no))
		end)
	end
end)

SLASH_WARROOMPROBE1 = "/wrprobe"
SlashCmdList.WARROOMPROBE = function(input)
	local command, arg = (input or ""):lower():match("^%s*(%S*)%s*(%S*)")
	input = command
	if input == "tile" then
		ShowTile(tonumber(arg))
	elseif input == "pins" then
		for _, line in ipairs(PinCensus()) do
			DEFAULT_CHAT_FRAME:AddMessage("|cff4fc3f7Probe|r: " .. line)
		end
		DEFAULT_CHAT_FRAME:AddMessage("|cff4fc3f7Probe|r: stored; /reload to save")
	elseif input == "clear" then
		wipe(WarRoomProbeDB.runs)
		DEFAULT_CHAT_FRAME:AddMessage("|cff4fc3f7Probe|r: cleared")
	else
		Run(true)
	end
end
