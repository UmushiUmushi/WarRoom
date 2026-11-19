-- The map's settings: a round button at the map's bottom left; clicking it slides the settings out above it, each a
-- smaller round button (lit while it is on):
--   Transitions   the transitions bar (Transitions.lua)
--   Terrain       the terrain at every zoom, in place of the paintings
--   Unexplored    the dark over the places not yet explored (Marks.lua)
--   /wr terrain, /wr unexplored   the same
local WR = WarRoom
local Map = WR.Map

local LEVEL = 6200 -- over the map's host and the game's buttons
local SIZE, SMALL = 31, 0.8 -- the buttons' size (a minimap button's), the settings' scale
local GAP = 2 -- UI units between the settings
local SLIDE = 0.15 -- seconds to slide them out or in

local main
local items = {} -- the settings' buttons, bottom up
local open, shown = false, 0 -- whether they are out; how far (0 in, 1 out)

-- The settings, bottom up.
local SETTINGS = {
	{
		key = "transitions",
		icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
		title = "Transitions",
		text = "Where each of the map's phases gives way to the next as you zoom.",
		click = function()
			Map.ToggleTransitions()
		end,
		on = function()
			return Map.TransitionsShown()
		end,
	},
	{
		key = "terrain",
		icon = "Interface\\Icons\\Spell_Nature_EarthBind",
		title = "Terrain",
		text = "The terrain at every zoom, in place of the painted maps.",
		click = function()
			Map.db.profile.terrainAlways = not Map.db.profile.terrainAlways
			Map.ApplyFades()
		end,
		on = function()
			return Map.db.profile.terrainAlways
		end,
	},
	{
		key = "unexplored",
		icon = "Interface\\Icons\\INV_Misc_Map_01",
		title = "Unexplored",
		text = "The dark over the places you haven't explored yet.",
		click = function()
			Map.db.profile.unexplored = not Map.db.profile.unexplored
			Map.RefreshFog()
		end,
		on = function()
			return Map.db.profile.unexplored
		end,
	},
}

-- A round button in the style of the minimap's.
local function RoundButton(parent, icon)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(SIZE, SIZE)
	b:SetFrameLevel(LEVEL)
	local back = b:CreateTexture(nil, "BACKGROUND")
	back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	back:SetSize(20, 20)
	back:SetPoint("TOPLEFT", 7, -5)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetTexture(icon)
	b.icon:SetSize(17, 17)
	b.icon:SetPoint("TOPLEFT", 7, -6)
	b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local mask = b:CreateMaskTexture()
	mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	mask:SetAllPoints(b.icon)
	b.icon:AddMaskTexture(mask)
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	return b
end

-- Lights a setting that is on, dims one that is off.
local function Refresh()
	for _, b in ipairs(items) do
		local on = b.setting.on() and true or false
		b.icon:SetDesaturated(not on)
		b.icon:SetVertexColor(on and 1 or 0.6, on and 1 or 0.6, on and 1 or 0.6)
	end
end

-- Lays the settings out `shown` of the way up from the main button.
local function Slide()
	for i, b in ipairs(items) do
		b:ClearAllPoints()
		b:SetPoint("BOTTOM", main, "TOP", 0, ((i - 1) * (SIZE * SMALL + GAP) + GAP) * shown / SMALL)
		b:SetAlpha(shown)
		b:SetShown(shown > 0)
	end
end

local function Toggle()
	open = not open
	Refresh()
end

local function Tooltip(self, title, text)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(title)
	if text then
		GameTooltip:AddLine(text, 1, 1, 1, true)
	end
	GameTooltip:Show()
end

-- Called by Map.lua as it makes its host over the game's map.
function Map.CreateSettings(host)
	main = RoundButton(host, "Interface\\Icons\\INV_Misc_Gear_01")
	main:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 6, 6)
	main.key = "settings"
	main:SetScript("OnClick", Toggle)
	main:SetScript("OnEnter", function(self)
		Tooltip(self, "WarRoom map settings")
	end)
	main:SetScript("OnLeave", GameTooltip_Hide)
	for i, setting in ipairs(SETTINGS) do
		local b = RoundButton(host, setting.icon)
		b:SetScale(SMALL)
		b:SetFrameLevel(LEVEL + 1)
		b.key, b.setting = setting.key, setting
		b:SetScript("OnClick", function()
			setting.click()
			Refresh()
		end)
		b:SetScript("OnEnter", function(self)
			Tooltip(self, setting.title, setting.text)
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		items[i] = b
	end
	Slide()
	main:SetScript("OnUpdate", function(_, elapsed)
		local target = open and 1 or 0
		if shown ~= target then
			local step = elapsed / SLIDE
			shown = open and math.min(1, shown + step) or math.max(0, shown - step)
			Slide()
		end
	end)
end

Map.RefreshSettings = Refresh

-- A setting from the chat: switched as its button would, then said.
local function Slash(key, say)
	for _, setting in ipairs(SETTINGS) do
		if setting.key == key then
			setting.click()
			if main then
				Refresh()
			end
			WR.Print("%s: %s", say, setting.on() and "on" or "off")
		end
	end
end

WR.SlashCommands.terrain = function()
	Slash("terrain", "terrain at every zoom")
end

WR.SlashCommands.unexplored = function()
	Slash("unexplored", "the dark over unexplored places")
end
