-- Pins: the one list of everything drawn on the maps (vendors, herbs, bosses, route stops, labels...).
-- Each pin can show on the main map, the minimap, or both. Renderers ask for the pins in view with Pins.Query and
-- redraw on WR_PINS_CHANGED.
--
-- A pin: { continent, x, y (world yards), category, layer?, icon?, label?, key?, source?, show?, minZoom?, ... }
--   category  a name from Pins.DefineCategory; its settings are the pin's defaults
--   layer     floor or cave layer (default 0, the ground)
--   key       a stable name (e.g. "npc:3312") so the user's per-pin choices survive a reload
--   source    who added it (e.g. "Gathering"), for Pins.Clear(source)
--   show      { map = bool, minimap = bool }: this pin's own surfaces, overriding its category's
--   minZoom   hide on maps zoomed out further than this
-- Anything else on the pin is the owner's own data.
--
-- Which surfaces a pin shows on, first answer wins: the user's choice for that pin, the user's choice for its
-- category, the pin's own `show`, its category's default, then shown.
--
-- Pure Lua apart from WR.Fire and WR.Defer, so it is unit-tested outside the game.
local _, ns = ...
local WR = ns.WR

local Pins = {}
ns.Pins = Pins
WR.Pins = Pins

local floor, min, max = math.floor, math.min, math.max

local BUCKET = 256 -- yards per side of a spatial bucket

Pins.SURFACES = { map = true, minimap = true }

-- The user's choices: categories[name] = { enabled?, map?, minimap? }, pins[key] = { map?, minimap? }.
-- DB.lua points this at the saved profile.
Pins.settings = { categories = {}, pins = {} }

local pins = {} -- id -> pin
local buckets = {} -- continent -> bucket key -> { [id] = true }
local categories = {} -- name -> definition
local nextID = 0
local count = 0

---------------------------------------------------------------------------------------------------
-- Change notification: one WR_PINS_CHANGED per frame, with the set of continents that changed (all = true when
-- a setting changed what every pin shows).
---------------------------------------------------------------------------------------------------
local dirty, scheduled = {}, false

local function Flush()
	scheduled = false
	local changed = dirty
	dirty = {}
	WR.Fire("WR_PINS_CHANGED", changed)
end

local function MarkDirty(continent)
	dirty[continent] = true
	if not scheduled then
		scheduled = true
		WR.Defer(Flush)
	end
end

local function BucketKey(x, y)
	return floor(x / BUCKET) * 65536 + floor(y / BUCKET)
end

local function Insert(pin)
	local byContinent = buckets[pin.continent]
	if not byContinent then
		byContinent = {}
		buckets[pin.continent] = byContinent
	end
	local key = BucketKey(pin.x, pin.y)
	local bucket = byContinent[key]
	if not bucket then
		bucket = {}
		byContinent[key] = bucket
	end
	bucket[pin.id] = true
end

local function Unlink(pin)
	local byContinent = buckets[pin.continent]
	local key = BucketKey(pin.x, pin.y)
	local bucket = byContinent and byContinent[key]
	if bucket then
		bucket[pin.id] = nil
		if next(bucket) == nil then
			byContinent[key] = nil
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Categories
---------------------------------------------------------------------------------------------------

-- def: { label, icon, map = bool, minimap = bool, enabled = bool, minZoom }
function Pins.DefineCategory(name, def)
	def = def or {}
	def.name = name
	categories[name] = def
	MarkDirty("all")
	return def
end

function Pins.GetCategory(name)
	return categories[name]
end

-- The user's choice for a category: surface is "map", "minimap" or "enabled"; value nil returns to the default.
function Pins.SetCategoryOption(name, surface, value)
	local user = Pins.settings.categories[name]
	if not user then
		user = {}
		Pins.settings.categories[name] = user
	end
	user[surface] = value
	MarkDirty("all")
end

-- The user's choice for one pin (by its key) on a surface; value nil returns to the default.
function Pins.SetPinOption(key, surface, value)
	local user = Pins.settings.pins[key]
	if not user then
		user = {}
		Pins.settings.pins[key] = user
	end
	user[surface] = value
	MarkDirty("all")
end

-- Call after replacing Pins.settings (a profile change).
function Pins.SettingsChanged()
	MarkDirty("all")
end

---------------------------------------------------------------------------------------------------
-- Pins
---------------------------------------------------------------------------------------------------

function Pins.Add(pin)
	assert(pin.continent and pin.x and pin.y, "a pin needs continent, x and y")
	assert(pin.category, "a pin needs a category")
	nextID = nextID + 1
	pin.id = nextID
	pin.layer = pin.layer or 0
	pins[pin.id] = pin
	count = count + 1
	Insert(pin)
	MarkDirty(pin.continent)
	return pin.id
end

function Pins.Get(id)
	return pins[id]
end

function Pins.Remove(id)
	local pin = pins[id]
	if not pin then
		return false
	end
	Unlink(pin)
	pins[id] = nil
	count = count - 1
	MarkDirty(pin.continent)
	return true
end

function Pins.Move(id, continent, x, y)
	local pin = pins[id]
	if not pin then
		return false
	end
	Unlink(pin)
	MarkDirty(pin.continent)
	pin.continent, pin.x, pin.y = continent, x, y
	Insert(pin)
	MarkDirty(continent)
	return true
end

-- Removes every pin a source added. Returns how many.
function Pins.Clear(source)
	local removed = 0
	for id, pin in pairs(pins) do
		if pin.source == source then
			Pins.Remove(id)
			removed = removed + 1
		end
	end
	return removed
end

function Pins.Count()
	return count
end

-- Whether a pin shows on a surface ("map" or "minimap") at a zoom (nil: any zoom).
function Pins.IsShown(pin, surface, zoom)
	local category = categories[pin.category]
	local userCategory = Pins.settings.categories[pin.category]

	local enabled
	if userCategory and userCategory.enabled ~= nil then
		enabled = userCategory.enabled
	else
		enabled = not (category and category.enabled == false)
	end
	if not enabled then
		return false
	end

	local minZoom = pin.minZoom or (category and category.minZoom)
	if zoom and minZoom and zoom < minZoom then
		return false
	end

	local userPin = pin.key and Pins.settings.pins[pin.key]
	if userPin and userPin[surface] ~= nil then
		return userPin[surface]
	end
	if userCategory and userCategory[surface] ~= nil then
		return userCategory[surface]
	end
	if pin.show and pin.show[surface] ~= nil then
		return pin.show[surface]
	end
	if category and category[surface] ~= nil then
		return category[surface]
	end
	return true
end

-- The pins shown on a surface inside a world rectangle (corners in any order) on a continent.
-- layer: only that layer (nil: every layer). zoom: for minZoom. out: optional table to fill (it is cleared).
function Pins.Query(continent, x1, y1, x2, y2, surface, zoom, layer, out)
	out = out or {}
	for i = #out, 1, -1 do
		out[i] = nil
	end
	local byContinent = buckets[continent]
	if not byContinent then
		return out
	end
	local minX, maxX, minY, maxY = min(x1, x2), max(x1, x2), min(y1, y2), max(y1, y2)
	for bx = floor(minX / BUCKET), floor(maxX / BUCKET) do
		for by = floor(minY / BUCKET), floor(maxY / BUCKET) do
			local bucket = byContinent[bx * 65536 + by]
			if bucket then
				for id in pairs(bucket) do
					local pin = pins[id]
					if
						pin.x >= minX
						and pin.x <= maxX
						and pin.y >= minY
						and pin.y <= maxY
						and (layer == nil or pin.layer == layer)
						and Pins.IsShown(pin, surface, zoom)
					then
						out[#out + 1] = pin
					end
				end
			end
		end
	end
	return out
end
