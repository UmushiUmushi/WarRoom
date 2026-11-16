-- Data loading. Large data sets made by the Python tools ship as base64 + zlib strings in their own
-- load-on-demand addons, and are unpacked here only when a module needs them.
local _, ns = ...
local WR = ns.WR

local Data = {}
WR.Data = Data

local IsLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
local LoadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn

-- Unpacks a base64 + zlib blob into the original string, or nil if it is damaged.
function Data.Inflate(blob)
	local raw = C_EncodingUtil.DecodeBase64(blob)
	return raw and C_EncodingUtil.DecompressString(raw, Enum.CompressionMethod.Zlib)
end

-- Loads a load-on-demand addon (a data set or a feature module). Returns true when it is loaded.
function Data.Load(name)
	if IsLoaded(name) then
		return true
	end
	local loaded, reason = LoadAddOn(name)
	if not loaded then
		WR.Debug("could not load %s: %s", name, tostring(reason))
	end
	return loaded and true or false
end
