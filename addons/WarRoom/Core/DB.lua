-- Saved variables (AceDB). profile: settings (per profile); global: account-wide data such as gathered nodes
-- and boat timings; char: this character's data such as known flight paths.
-- Modules keep their own settings in a namespace: WarRoom.db:RegisterNamespace("Map", defaults).
local _, ns = ...
local WR = ns.WR

local defaults = {
	profile = {
		debug = false,
		modules = {}, -- [name] = false turns a module off
		pins = { categories = {}, pins = {} },
		jobs = { budgetMs = 4 },
	},
	global = {
		schema = 1,
	},
	char = {},
}

local function Apply()
	WR.Pins.settings = WR.db.profile.pins
	WR.Pins.SettingsChanged()
	WR.Jobs.budgetMs = WR.db.profile.jobs.budgetMs
	WR.Fire("WR_PROFILE_CHANGED")
end

function ns.InitDB()
	WR.db = LibStub("AceDB-3.0"):New("WarRoomDB", defaults, true)
	for _, event in ipairs({ "OnProfileChanged", "OnProfileCopied", "OnProfileReset" }) do
		WR.db.RegisterCallback(WR, event, Apply)
	end
	Apply()
end
