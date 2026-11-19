-- WarRoom's page in the game's options (Esc > Options > AddOns > WarRoom): each module's settings under its own
-- header, drawn by the game's own settings list (its checkboxes, tooltips, Defaults button). A setting reads and
-- writes the module's own saved value through the module's get and set, so the page, the slash commands and the
-- map's quick buttons all change the same thing.
--   WarRoom.Options.AddCheckbox{ section = "Minimap", key = "MINIMAP_HUB", name = "...", tooltip = "...",
--     default = true, get = function() ... end, set = function(value) ... end }  -> the setting (setting:SetValue)
--   /wr options    opens the page
local _, ns = ...
local WR = ns.WR

local Options = {}
WR.Options = Options

local category, layout
local headers = {}

-- The page, made the first time a setting is added (the game's settings code is loaded by then: modules add theirs
-- as they start, at login). Nil when this client has no such settings panel.
local function Page()
	if not category and Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting then
		category, layout = Settings.RegisterVerticalLayoutCategory("WarRoom")
		Settings.RegisterAddOnCategory(category)
	end
	return category
end

local function Header(section)
	if section and not headers[section] and layout and CreateSettingsListSectionHeaderInitializer then
		headers[section] = true
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(section))
	end
end

-- A checkbox on the page. Returns the game's setting (its SetValue also ticks the box), or nil without a page.
function Options.AddCheckbox(spec)
	if not Page() then
		return nil
	end
	Header(spec.section)
	local setting = Settings.RegisterProxySetting(category, "WARROOM_" .. spec.key, Settings.VarType.Boolean, spec.name,
		spec.default and true or false, function()
			return spec.get() and true or false
		end, spec.set)
	Settings.CreateCheckbox(category, setting, spec.tooltip)
	return setting
end

-- Sets a value through its setting when the page has one (so an open page shows it), else directly.
function Options.Set(setting, set, value)
	if setting then
		setting:SetValue(value)
	else
		set(value)
	end
end

function Options.Open()
	if Page() and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	else
		WR.Print("this client has no options panel for addons")
	end
end

WR.SlashCommands.options = Options.Open
