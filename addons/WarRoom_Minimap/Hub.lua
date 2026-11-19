-- The button hub: other addons' minimap buttons gathered off the minimap's ring into one column, opened downwards
-- from a button of ours to the right of the minimap.
--
-- Which buttons: LibDBIcon's (nearly every addon's: one shared copy through LibStub, its buttons in `objects`, new ones
-- announced by its "LibDBIcon_IconCreated" callback), and any other button an addon has put on the minimap itself
-- (Geared Forever's, AzerothGPS's), found as other button collectors find them: the Minimap's children that look like
-- a minimap button (a named Button, button sized, round the rim, not the game's own, not a map pin of HereBeDragons').
-- The minimap is looked over again a moment after login, ten seconds later and whenever the hub is opened, for buttons
-- made late.
--
-- Each is moved into the hub's column and kept there: addons put their buttons back on the ring with SetPoint (on a
-- refresh, at login, when shown, when the minimap is resized), so a taken button's own SetPoint and ClearAllPoints
-- become no-ops (ours places it through the originals), and it can't be dragged round the ring any more. A button its
-- addon hides (its "hide minimap button" option) leaves no gap. The game's own minimap buttons (calendar, tracking,
-- mail) stay where they are. Nothing here is protected (protected frames are left alone): fine in combat.
-- Turned off (WarRoom's options, /wr minimap hub), every button goes back where it was, at once.
local WR = WarRoom
local Canvas = WR.Canvas
local Mini = WR.Minimap

local max, abs = math.max, math.abs

local SIZE = 31 -- LibDBIcon's buttons
local GAP = 2 -- between buttons in the column
local OFFSET_X = 14 -- the hub's button right of the minimap's edge (clear of the ring)
local LEVEL = 8 -- LibDBIcon's buttons' (MEDIUM): the hub's button among them, its column's backing under them
local ICON = "Interface\\Icons\\INV_Misc_Map_01"
-- A minimap button of an addon's own: about a button's size, and on the rim (a centre past this share of the radius).
local MIN_SIZE, MAX_SIZE, MAX_UNSQUARE = 18, 48, 8
local RIM = 0.6
-- The game's own minimap buttons (beside every name starting with "Minimap"/"MiniMap"): left where they are.
local GAME_BUTTONS = {
	GameTimeFrame = true, TimeManagerClockButton = true, QueueStatusButton = true, QueueStatusMinimapButton = true,
	GarrisonLandingPageMinimapButton = true, ExpansionLandingPageMinimapButton = true, AddonCompartmentFrame = true,
	GuildInstanceDifficulty = true, FeedbackUIButton = true, HelpOpenTicketButton = true, HelpOpenWebTicketButton = true,
}

local hub, column
-- [button] = { name, lib, parent, strata, level, points, own placing (SetPoint, ClearAllPoints, and any of the
-- button's own fields they replaced) }: the buttons in the column
local taken = {}
local order = {} -- the same buttons, in the column's order
local hooked = {} -- buttons whose Show/Hide are hooked (once each, for good)
local function Noop() end

local function On()
	return hub ~= nil and Mini.db.profile.hub
end

-- The column from the top: the shown buttons by name, no gaps.
local function Layout()
	if not column then
		return
	end
	table.sort(order, function(a, b)
		return taken[a].name:lower() < taken[b].name:lower()
	end)
	local n = 0
	for _, button in ipairs(order) do
		if button:IsShown() then
			local own = taken[button]
			own.ClearAllPoints(button)
			own.SetPoint(button, "TOP", column, "TOP", 0, -GAP - n * (SIZE + GAP))
			n = n + 1
		end
	end
	column:SetHeight(max(1, GAP + n * (SIZE + GAP)))
	column.count = n
end

-- A button into the column, until the hub is turned off.
local function Take(button, name, lib)
	if not On() or not button or taken[button] or (button.IsProtected and button:IsProtected()) then
		return
	end
	local info = {
		name = tostring(name), lib = lib, parent = button:GetParent(), strata = button:GetFrameStrata(),
		level = button:GetFrameLevel(), points = {}, SetPoint = button.SetPoint, ClearAllPoints = button.ClearAllPoints,
		rawSetPoint = rawget(button, "SetPoint"), rawClearAllPoints = rawget(button, "ClearAllPoints"),
	}
	for i = 1, (button.GetNumPoints and button:GetNumPoints() or 0) do
		info.points[i] = { button:GetPoint(i) }
	end
	taken[button] = info
	order[#order + 1] = button
	button:SetParent(column)
	if not lib then
		-- (LibDBIcon's keep their own fixed MEDIUM 8; others are put there, over the column's backing)
		button:SetFrameStrata("MEDIUM")
		button:SetFrameLevel(LEVEL)
	end
	-- (its addon's placing round the ring: no more)
	button.SetPoint, button.ClearAllPoints = Noop, Noop
	if button.RegisterForDrag then
		button:RegisterForDrag()
	end
	-- (a button that fades out off the pointer: shown whole in the hub)
	if button.fadeOut then
		button.fadeOut:Stop()
	end
	button:SetAlpha(1)
	-- (hidden or shown by its addon: the column closes up or makes room)
	if not hooked[button] then
		hooked[button] = true
		local function Changed()
			if taken[button] then
				Layout()
			end
		end
		hooksecurefunc(button, "Show", Changed)
		hooksecurefunc(button, "Hide", Changed)
		hooksecurefunc(button, "SetShown", Changed)
	end
	Layout()
end

-- A button back where its addon had it.
local function Release(button)
	local info = taken[button]
	if not info then
		return
	end
	taken[button] = nil
	for i = #order, 1, -1 do
		if order[i] == button then
			table.remove(order, i)
		end
	end
	button.SetPoint, button.ClearAllPoints = info.rawSetPoint, info.rawClearAllPoints
	button:SetParent(info.parent)
	if not info.lib then
		button:SetFrameStrata(info.strata)
		button:SetFrameLevel(info.level)
	end
	button:ClearAllPoints()
	for _, point in ipairs(info.points) do
		button:SetPoint(unpack(point))
	end
	if button.RegisterForDrag then
		button:RegisterForDrag("LeftButton")
	end
	-- (LibDBIcon places its own again: on the ring where the player left it, shown or hidden as set)
	if info.lib and info.lib.Refresh then
		pcall(info.lib.Refresh, info.lib, info.name)
	end
end

---------------------------------------------------------------------------------------------------
-- Finding the buttons
---------------------------------------------------------------------------------------------------

-- Every HereBeDragons-Pins copy's minimap pins (they are the Minimap's children too, some on its rim).
local function IsMapPin(frame)
	local copies = {}
	if LibStub then
		copies[#copies + 1] = LibStub("HereBeDragons-Pins-2.0", true)
		copies[#copies + 1] = LibStub("HereBeDragons-Pins-1.0", true)
	end
	if QuestieLoader and QuestieLoader.ImportModule then
		local ok, pins = pcall(QuestieLoader.ImportModule, QuestieLoader, "HBDPins")
		copies[#copies + 1] = ok and pins or nil
	end
	for _, pins in pairs(copies) do
		if (pins.minimapPins and pins.minimapPins[frame]) or (pins.activeMinimapPins and pins.activeMinimapPins[frame]) then
			return true
		end
	end
	return false
end

-- Whether a child of the Minimap is an addon's own minimap button.
local function IsAddonButton(frame)
	if taken[frame] or frame == hub or (frame.IsForbidden and frame:IsForbidden()) then
		return false
	end
	if not (frame.IsObjectType and frame:IsObjectType("Button")) or (frame.IsProtected and frame:IsProtected()) then
		return false
	end
	local name = frame:GetName()
	if not name or name:find("^Mini[Mm]ap") or name:find("^WarRoom") or GAME_BUTTONS[name] then
		return false
	end
	local w, h = frame:GetSize()
	if not (w and h) or w < MIN_SIZE or h < MIN_SIZE or w > MAX_SIZE or h > MAX_SIZE or abs(w - h) > MAX_UNSQUARE then
		return false
	end
	local x, y = frame:GetCenter()
	local mx, my = Minimap:GetCenter()
	if x and mx then
		local scale = frame:GetEffectiveScale() / Minimap:GetEffectiveScale()
		local dx, dy = x * scale - mx, y * scale - my
		local r = Minimap:GetWidth() / 2
		if dx * dx + dy * dy < (RIM * r) ^ 2 then
			return false
		end
	end
	return not IsMapPin(frame)
end

-- A readable name for one found on the minimap ("GearedForeverMinimapButton": "GearedForever").
local function ButtonName(frame)
	local name = frame:GetName():gsub("Mini[Mm]ap", ""):gsub("Button$", ""):gsub("_$", "")
	return name ~= "" and name or frame:GetName()
end

local function TakeAll()
	if not On() then
		return
	end
	local lib = LibStub and LibStub("LibDBIcon-1.0", true)
	if lib then
		for name, button in pairs(lib.objects or {}) do
			Take(button, name, lib)
		end
	end
	for _, parent in ipairs({ Minimap, MinimapBackdrop }) do
		if parent and parent.GetChildren then
			for _, child in ipairs({ parent:GetChildren() }) do
				-- (another addon's odd frame can't break the look round)
				local ok, yes = pcall(IsAddonButton, child)
				if ok and yes then
					Take(child, ButtonName(child))
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- The hub's button and column
---------------------------------------------------------------------------------------------------

local function CreateButton()
	-- (a LibDBIcon-style round button: they sit together)
	hub = CreateFrame("Button", "WarRoomHubButton", Minimap)
	hub:SetSize(SIZE, SIZE)
	Mini.FixStrata(hub, "MEDIUM")
	Canvas.FixLevel(hub, LEVEL)
	hub:SetPoint("TOPLEFT", Minimap, "TOPRIGHT", OFFSET_X, 0)
	hub:SetClampedToScreen(true)
	hub:RegisterForClicks("AnyUp")
	local background = hub:CreateTexture(nil, "BACKGROUND")
	background:SetTexture(136467) -- Interface\Minimap\UI-Minimap-Background
	background:SetSize(24, 24)
	background:SetPoint("CENTER")
	local icon = hub:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	icon:SetSize(18, 18)
	icon:SetPoint("CENTER")
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
	local border = hub:CreateTexture(nil, "OVERLAY")
	border:SetTexture(136430) -- Interface\Minimap\MiniMap-TrackingBorder
	border:SetSize(50, 50)
	border:SetPoint("TOPLEFT")
	hub:SetHighlightTexture(136477) -- Interface\Minimap\UI-Minimap-ZoomButton-Highlight

	column = CreateFrame("Frame", nil, hub)
	Mini.FixStrata(column, "MEDIUM")
	Canvas.FixLevel(column, LEVEL - 1)
	column:SetWidth(SIZE + 2 * GAP)
	column:SetPoint("TOP", hub, "BOTTOM", 0, -GAP)
	column:SetClampedToScreen(true)
	local backing = column:CreateTexture(nil, "BACKGROUND")
	backing:SetAllPoints()
	backing:SetColorTexture(0, 0, 0, 0.45)
	column:Hide()
	Mini.hub, Mini.hubColumn = hub, column

	hub:SetScript("OnClick", function()
		TakeAll() -- (any made since)
		column:SetShown(not column:IsShown())
		GameTooltip_Hide()
	end)
	hub:SetScript("OnEnter", function(self)
		TakeAll()
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("WarRoom")
		GameTooltip:AddLine(string.format("%d addon buttons. Click to %s.", column.count or 0,
			column:IsShown() and "close" or "open"), 1, 1, 1)
		GameTooltip:Show()
	end)
	hub:SetScript("OnLeave", GameTooltip_Hide)

	-- (LibDBIcon's buttons made later, as they are made)
	local lib = LibStub and LibStub("LibDBIcon-1.0", true)
	if lib and lib.RegisterCallback then
		lib.RegisterCallback(Mini, "LibDBIcon_IconCreated", function(_, button, name)
			Take(button, name, lib)
		end)
	end
end

-- Made when the module starts, if the hub is on: every addon minimap button now and later.
function Mini.CreateHub()
	if hub or not Mini.db.profile.hub then
		return
	end
	CreateButton()
	TakeAll()
	-- (addons that make theirs a moment after login, or later still)
	C_Timer.After(2, TakeAll)
	C_Timer.After(10, TakeAll)
end

-- The hub on (the buttons gathered into it) or off (each back where it was, the hub's button gone).
function Mini.SetHub(on)
	Mini.db.profile.hub = on and true or false
	if on then
		if hub then
			hub:Show()
			TakeAll()
		else
			Mini.CreateHub()
		end
	elseif hub then
		column:Hide()
		hub:Hide()
		for i = #order, 1, -1 do
			Release(order[i])
		end
		column.count = 0
	end
end
