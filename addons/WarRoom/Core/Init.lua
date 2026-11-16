-- WarRoom Core: the shared namespace, internal events, game events and the module registry.
-- Feature modules are separate addons; they reach Core through the global `WarRoom`.
local addonName, ns = ...

---@class WarRoom
local WR = {}
_G.WarRoom = WR
ns.WR = WR

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
WR.name = addonName
WR.version = (GetMeta and GetMeta(addonName, "Version")) or "dev"

-- Calls fn(...) and reports an error without stopping the caller, so one broken handler can't break the rest.
local function SafeCall(fn, ...)
	if securecallfunction then
		return securecallfunction(fn, ...)
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		geterrorhandler()(err)
	end
end
WR.SafeCall = SafeCall

-- Runs fn on the next frame.
function WR.Defer(fn)
	C_Timer.After(0, fn)
end

---------------------------------------------------------------------------------------------------
-- Internal events (all named WR_*). Listen with WarRoom.RegisterCallback(owner, "WR_POSITION", handler);
-- a function handler is called as handler(event, ...).
---------------------------------------------------------------------------------------------------
local registry = LibStub("CallbackHandler-1.0"):New(WR, "RegisterCallback", "UnregisterCallback", "UnregisterAllCallbacks")

function WR.Fire(event, ...)
	registry:Fire(event, ...)
end

---------------------------------------------------------------------------------------------------
-- Game events: WR.OnEvent("ZONE_CHANGED", handler) calls handler(event, ...). Several handlers may share an event.
---------------------------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local gameHandlers = {}

function WR.OnEvent(event, handler)
	local list = gameHandlers[event]
	if not list then
		list = {}
		gameHandlers[event] = list
		eventFrame:RegisterEvent(event)
	end
	list[#list + 1] = handler
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = gameHandlers[event]
	for i = 1, #list do
		SafeCall(list[i], event, ...)
	end
end)

---------------------------------------------------------------------------------------------------
-- Chat output
---------------------------------------------------------------------------------------------------
local PREFIX = "|cff4fc3f7WarRoom|r: "

function WR.Print(fmt, ...)
	local text = select("#", ...) > 0 and fmt:format(...) or tostring(fmt)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

function WR.Debug(fmt, ...)
	if WR.db and WR.db.profile.debug then
		WR.Print("|cff999999" .. fmt .. "|r", ...)
	end
end

---------------------------------------------------------------------------------------------------
-- Modules. A module (usually its own load-on-demand addon) calls WarRoom.NewModule("Map", tbl) and may define
-- tbl:OnEnable(). Modules are enabled at login, or at once when registered after login. The user can turn one
-- off in the profile (profile.modules[name] = false).
---------------------------------------------------------------------------------------------------
WR.modules = {}
local moduleOrder = {}

local function EnableModule(module)
	if module.enabled or (WR.db and WR.db.profile.modules[module.name] == false) then
		return
	end
	module.enabled = true
	if module.OnEnable then
		SafeCall(module.OnEnable, module)
	end
end

function WR.NewModule(name, module)
	assert(not WR.modules[name], "WarRoom module registered twice: " .. tostring(name))
	module = module or {}
	module.name = name
	WR.modules[name] = module
	moduleOrder[#moduleOrder + 1] = module
	if WR.ready then
		EnableModule(module)
	end
	return module
end

function WR.GetModule(name)
	return WR.modules[name]
end

---------------------------------------------------------------------------------------------------
-- Startup: saved variables (ADDON_LOADED), then modules (PLAYER_LOGIN).
---------------------------------------------------------------------------------------------------
WR.OnEvent("ADDON_LOADED", function(_, loaded)
	if loaded ~= addonName or WR.db then
		return
	end
	ns.InitDB()
	WR.Fire("WR_DB_READY")
end)

WR.OnEvent("PLAYER_LOGIN", function()
	WR.ready = true
	for i = 1, #moduleOrder do
		EnableModule(moduleOrder[i])
	end
	WR.Fire("WR_READY")
end)
