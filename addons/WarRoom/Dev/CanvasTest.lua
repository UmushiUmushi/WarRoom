-- /wr canvas: a test window for the Canvas (drag to pan, wheel to zoom), with live numbers. While it is open it
-- keeps the worst numbers seen at each zoom in WarRoomDB.global.dev.canvas (saved on /reload), so the cost of
-- drawing terrain far out can be read afterwards.
-- The "Fades" button opens sliders for every layer's zooms (the same numbers as the commands below).
--   /wr canvas                    open or close
--   /wr canvas terrain <none> [full]   terrain hidden at <none> yards per UI unit, full at [full] (100 = always)
--   /wr canvas zones <none> [full]     the same for the detailed painted map (over the continent's painting)
--   /wr canvas sea <none> [full]       the same for the sea's paper (in place of the continent's ocean)
--   /wr canvas cities <none> [full]    the same for the city maps (over their zones' banners)
--   /wr canvas fade | art | zones | sea | terrain | cities   turn the coast fade or a layer on or off
--   /wr canvas map <id | kalimdor | ek>   show another continent (1, 0, 2991, ...)
--   /wr canvas defaults           forget the options set here
--   /wr canvas stats | reset      print or forget the stored numbers
local _, ns = ...
local WR = ns.WR
local Canvas = ns.Canvas

local Test = {}
WR.CanvasTest = Test

local ZOOM_STEP = 1.25
local MIN_YPP, MAX_YPP = 0.5, 200
-- Saved options from an older layout of the canvas are forgotten (their numbers meant something else).
local OPTIONS_VERSION = 2

local window, canvas, arrow, statsText, followButton, fadesPanel
local follow = true
local dragging, lastX, lastY
local sinceStats = 0

local function Dev()
	local global = WR.db.global
	global.dev = global.dev or {}
	global.dev.canvas = global.dev.canvas or {}
	if global.dev.canvasOptionsVersion ~= OPTIONS_VERSION then
		global.dev.canvasOptions = {}
		global.dev.canvasOptionsVersion = OPTIONS_VERSION
	end
	return global.dev
end

local function CursorOffset()
	local x, y = GetCursorPosition()
	local scale = canvas.frame:GetEffectiveScale()
	local cx, cy = canvas.frame:GetCenter()
	return x / scale - cx, y / scale - cy
end

local function CenterOnPlayer()
	local s = WR.Position.state
	if s.known and Canvas.TileData(s.continent) then
		canvas:SetView(s.continent, s.x, s.y)
		return true
	end
end

local function PlaceArrow()
	local s = WR.Position.state
	if not s.known or s.continent ~= canvas.continent then
		arrow:Hide()
		return
	end
	local dx, dy = canvas:WorldToFrame(s.x, s.y)
	arrow:ClearAllPoints()
	arrow:SetPoint("CENTER", canvas.overlay, "CENTER", dx, dy)
	local facing = GetPlayerFacing and GetPlayerFacing()
	if facing and (not canaccessvalue or canaccessvalue(facing)) then
		arrow:SetRotation(facing)
	end
	arrow:Show()
end

-- Keeps the worst numbers per zoom step: most tiles, slowest redraw, lowest frame rate.
local function Record()
	local stats = canvas.stats
	if stats.pending then
		return
	end
	local step = math.floor(math.log(canvas.ypp) / math.log(ZOOM_STEP) + 0.5)
	local list = Dev().canvas
	local key = tostring(step)
	local row = list[key] or { ypp = ZOOM_STEP ^ step, tiles = 0, msMax = 0, fpsMin = 999, samples = 0 }
	list[key] = row
	row.tiles = math.max(row.tiles, stats.tiles)
	row.msMax = math.max(row.msMax, stats.ms)
	row.fpsMin = math.min(row.fpsMin, GetFramerate())
	row.samples = row.samples + 1
	row.alpha = stats.alpha
end

local function ShowStats()
	local s = canvas.stats
	statsText:SetFormattedText(
		"%.1f yd/unit   detail %d%% (%d %s map tiles)   cities %d%%   terrain %d%%   tiles %d (fading %d)   redraw %.2f ms   %.0f fps   Lua %.0f MB%s",
		canvas.ypp,
		s.zoneAlpha * 100,
		s.zones,
		s.level or "no",
		s.cityAlpha * 100,
		s.alpha * 100,
		s.tiles,
		s.masks,
		s.ms,
		GetFramerate(),
		collectgarbage("count") / 1024,
		s.pending and "   loading..." or ""
	)
end

---------------------------------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------------------------------

-- The options in force: those set here, else the canvas's defaults.
local function Options()
	local saved = Dev().canvasOptions
	return setmetatable({}, {
		__index = function(_, k)
			if saved[k] ~= nil then
				return saved[k]
			end
			return Canvas.defaults[k]
		end,
	})
end

local function SetOptions(changes)
	local saved = Dev().canvasOptions
	for k, v in pairs(changes) do
		saved[k] = v
	end
	if canvas then
		canvas:SetOptions(changes)
	end
	if fadesPanel and fadesPanel:IsShown() then
		fadesPanel:Refresh()
	end
end

-- A layer's zooms: it starts to show at `none` yards per unit, and is full at `full` and closer.
local function SetFade(layer, none, full)
	SetOptions({ [layer .. "None"] = none, [layer .. "Full"] = math.min(full, none) })
end

-- The fades panel: two sliders per layer, on a log scale from LOW to HIGH yards per unit.
local LOW, HIGH = 0.5, 100
local FADES = {
	{ layer = "cities", label = "City maps (in place of the zone's banner)" },
	{ layer = "zones", label = "Detailed painted map (over the continent's)" },
	{ layer = "sea", label = "Sea paper (in place of the continent's ocean)" },
	{ layer = "terrain", label = "Terrain (the paintings fade out over it)" },
}

local function ToSlider(ypp)
	return math.log(ypp / LOW) / math.log(HIGH / LOW)
end

-- Two significant figures: 0.55, 3.3, 12, 100.
local function FromSlider(t)
	return tonumber(("%.2g"):format(LOW * (HIGH / LOW) ^ t))
end

local function NewSlider(parent, label)
	local slider = CreateFrame("Slider", nil, parent, "BackdropTemplate")
	slider:SetOrientation("HORIZONTAL")
	slider:SetSize(180, 16)
	slider:SetHitRectInsets(0, 0, -6, -6)
	slider:SetBackdrop({
		bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
		edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = { left = 3, right = 3, top = 6, bottom = 6 },
	})
	slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	slider:SetMinMaxValues(0, 1)
	slider:SetValueStep(0.002)
	slider:SetObeyStepOnDrag(true)
	slider.value = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	slider.value:SetPoint("LEFT", slider, "RIGHT", 8, 0)
	local name = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	name:SetPoint("RIGHT", slider, "LEFT", -8, 0)
	name:SetText(label)
	return slider
end

local function CreateFadesPanel()
	local panel = CreateFrame("Frame", nil, window, "BackdropTemplate")
	panel:SetSize(330, 74 + #FADES * 70)
	panel:SetPoint("TOPRIGHT", window, "TOPRIGHT", -8, -28)
	panel:SetFrameLevel(canvas.overlay:GetFrameLevel() + 10)
	panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	panel:SetBackdropColor(0.05, 0.05, 0.06, 0.92)
	panel:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
	-- Clicks and the wheel over the panel never reach the map under it.
	panel:EnableMouse(true)
	panel:EnableMouseWheel(true)
	panel:SetScript("OnMouseWheel", function() end)

	local help = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", 10, -8)
	help:SetPoint("TOPRIGHT", -10, -8)
	help:SetJustifyH("LEFT")
	help:SetText("Yards per unit, like the first number under the map (smaller = closer in).")

	local sliders, syncing = {}, false
	local y = -44
	for _, fade in ipairs(FADES) do
		local layer = fade.layer
		local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOPLEFT", 10, y)
		title:SetText(fade.label)
		local none = NewSlider(panel, "starts at")
		none:SetPoint("TOPLEFT", 80, y - 22)
		local full = NewSlider(panel, "full at")
		full:SetPoint("TOPLEFT", 80, y - 44)
		none:SetScript("OnValueChanged", function(_, t)
			if not syncing then
				local v = FromSlider(t)
				SetFade(layer, v, math.min(Options()[layer .. "Full"], v))
			end
		end)
		full:SetScript("OnValueChanged", function(_, t)
			if not syncing then
				local v = FromSlider(t)
				SetFade(layer, math.max(Options()[layer .. "None"], v), v)
			end
		end)
		sliders[layer] = { None = none, Full = full }
		y = y - 70
	end

	-- Shows the numbers in force; a slider only jumps when it is off by more than the rounding.
	function panel:Refresh()
		local o = Options()
		syncing = true
		for layer, pair in pairs(sliders) do
			for part, slider in pairs(pair) do
				local v = o[layer .. part]
				if math.abs(slider:GetValue() - ToSlider(v)) > 0.02 then
					slider:SetValue(ToSlider(v))
				end
				slider.value:SetText(("%g"):format(v))
			end
		end
		syncing = false
	end
	panel:SetScript("OnShow", panel.Refresh)

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(90, 20)
	reset:SetPoint("BOTTOMRIGHT", -8, 8)
	reset:SetText("Defaults")
	reset:SetScript("OnClick", function()
		local changes = {}
		for _, fade in ipairs(FADES) do
			for _, part in ipairs({ "None", "Full" }) do
				changes[fade.layer .. part] = Canvas.defaults[fade.layer .. part]
			end
		end
		SetOptions(changes)
		local saved = Dev().canvasOptions
		for k in pairs(changes) do
			saved[k] = nil
		end
	end)

	panel:Hide()
	return panel
end

local CONTINENTS = { kalimdor = 1, kal = 1, ek = 0, eastern = 0, azeroth = 0 }

-- Shows a continent from its middle and stops following the player.
local function ShowMap(continent)
	if not Canvas.TileData(continent) then
		WR.Print("no terrain for map %d", continent)
		return
	end
	if not window or not window:IsShown() then
		Test.Toggle()
	end
	follow = false
	Test.ShowFollow()
	local x, y = Canvas.ContinentCenter(continent)
	canvas:SetView(continent, x, y, 30)
end

---------------------------------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------------------------------

local function Create()
	window = CreateFrame("Frame", "WarRoomCanvasTest", UIParent, "BackdropTemplate")
	window:SetSize(900, 640)
	window:SetPoint("CENTER")
	window:SetFrameStrata("HIGH")
	window:SetMovable(true)
	window:SetClampedToScreen(true)
	window:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	window:SetBackdropColor(0.05, 0.05, 0.06, 0.95)
	window:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
	tinsert(UISpecialFrames, "WarRoomCanvasTest") -- Escape closes it

	local title = CreateFrame("Frame", nil, window)
	title:SetPoint("TOPLEFT")
	title:SetPoint("TOPRIGHT")
	title:SetHeight(26)
	title:EnableMouse(true)
	title:RegisterForDrag("LeftButton")
	title:SetScript("OnDragStart", function()
		window:StartMoving()
	end)
	title:SetScript("OnDragStop", function()
		window:StopMovingOrSizing()
	end)
	local label = title:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("LEFT", 10, 0)
	label:SetText("WarRoom canvas test   (drag to pan, wheel to zoom)")

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	-- Title bar buttons, right to left.
	local anchor = close
	local function TitleButton(text, width, onClick)
		local button = CreateFrame("Button", nil, title, "UIPanelButtonTemplate")
		button:SetSize(width, 20)
		button:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
		button:SetText(text)
		button:SetScript("OnClick", onClick)
		anchor = button
		return button
	end
	TitleButton("Fades", 70, function()
		fadesPanel:SetShown(not fadesPanel:IsShown())
	end)
	TitleButton("Eastern Kingdoms", 130, function()
		ShowMap(0)
	end)
	TitleButton("Kalimdor", 80, function()
		ShowMap(1)
	end)

	local view = CreateFrame("Frame", nil, window)
	view:SetPoint("TOPLEFT", 8, -28)
	view:SetPoint("BOTTOMRIGHT", -8, 30)
	canvas = Canvas.New(view, Dev().canvasOptions)

	arrow = canvas.overlay:CreateTexture(nil, "OVERLAY")
	arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
	arrow:SetSize(28, 28)

	statsText = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	statsText:SetPoint("BOTTOMLEFT", 10, 10)

	followButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	followButton:SetSize(90, 22)
	followButton:SetPoint("BOTTOMRIGHT", -8, 4)
	local function ShowFollow()
		followButton:SetText(follow and "Following" or "Follow me")
	end
	followButton:SetScript("OnClick", function()
		follow = not follow
		if follow then
			CenterOnPlayer()
		end
		ShowFollow()
	end)
	ShowFollow()
	Test.ShowFollow = ShowFollow

	view:EnableMouse(true)
	view:EnableMouseWheel(true)
	view:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" then
			dragging = true
			lastX, lastY = CursorOffset()
			follow = false
			ShowFollow()
		end
	end)
	view:SetScript("OnMouseUp", function(_, button)
		if button == "LeftButton" then
			dragging = false
		end
	end)
	view:SetScript("OnMouseWheel", function(_, delta)
		local ypp = canvas.ypp * (delta > 0 and 1 / ZOOM_STEP or ZOOM_STEP)
		ypp = math.min(MAX_YPP, math.max(MIN_YPP, ypp))
		if follow then
			canvas:SetView(canvas.continent, canvas.cx, canvas.cy, ypp)
			return
		end
		-- Keep the point under the cursor where it is.
		local mx, my = CursorOffset()
		local wx, wy = canvas:FrameToWorld(mx, my)
		canvas:SetView(canvas.continent, wx - my * ypp, wy + mx * ypp, ypp)
	end)

	canvas:SetOnUpdate(PlaceArrow)
	fadesPanel = CreateFadesPanel()

	window:SetScript("OnUpdate", function(_, elapsed)
		if dragging then
			local x, y = CursorOffset()
			if x ~= lastX or y ~= lastY then
				local cx, cy = canvas:FrameToWorld(lastX - x, lastY - y)
				lastX, lastY = x, y
				canvas:SetView(canvas.continent, cx, cy)
			end
		end
		sinceStats = sinceStats + elapsed
		if sinceStats > 0.25 then
			sinceStats = 0
			ShowStats()
			Record()
		end
	end)

	WR.RegisterCallback(Test, "WR_POSITION", function()
		if not window:IsShown() then
			return
		end
		if follow then
			CenterOnPlayer()
		else
			PlaceArrow()
		end
	end)
end

function Test.Toggle()
	if not window then
		Create()
	elseif window:IsShown() then
		window:Hide()
		return
	end
	window:Show()
	if not canvas.continent and not CenterOnPlayer() then
		local x, y = Canvas.ContinentCenter(1)
		canvas:SetView(1, x, y, 30)
	end
end

local LAYERS = { terrain = true, zones = true, sea = true, cities = true }

WR.SlashCommands.canvas = function(rest)
	local command, a, b = rest:lower():match("^(%S*)%s*(%S*)%s*(%S*)")
	if command == "" then
		Test.Toggle()
	elseif LAYERS[command] and tonumber(a) then
		local none = tonumber(a)
		local full = tonumber(b) or math.min(Options()[command .. "Full"], none * 0.6)
		SetFade(command, none, full)
		local o = Options()
		WR.Print("%s starts at %g, full at %g yards per unit", command, o[command .. "None"], o[command .. "Full"])
	elseif LAYERS[command] or command == "fade" or command == "art" then
		local on = not Options()[command]
		SetOptions({ [command] = on })
		WR.Print("%s %s", command, on and "on" or "off")
	elseif command == "map" and (tonumber(a) or CONTINENTS[a]) then
		ShowMap(tonumber(a) or CONTINENTS[a])
	elseif command == "stats" then
		local rows = {}
		for _, row in pairs(Dev().canvas) do
			rows[#rows + 1] = row
		end
		table.sort(rows, function(p, q)
			return p.ypp < q.ypp
		end)
		for _, row in ipairs(rows) do
			WR.Print("%6.1f yd/unit  terrain %3d%%  tiles %4d  redraw max %.2f ms  fps min %.0f", row.ypp, (row.alpha or 0) * 100, row.tiles, row.msMax, row.fpsMin)
		end
	elseif command == "defaults" then
		wipe(Dev().canvasOptions)
		if canvas then
			canvas:SetOptions(Canvas.defaults)
		end
		if fadesPanel and fadesPanel:IsShown() then
			fadesPanel:Refresh()
		end
		WR.Print("canvas options back to defaults")
	elseif command == "reset" then
		wipe(Dev().canvas)
		WR.Print("canvas numbers forgotten")
	else
		WR.Print("/wr canvas [terrain|zones|cities [<starts> [full]] | fade | art | map <id|kalimdor|ek> | defaults | stats | reset]")
	end
end
