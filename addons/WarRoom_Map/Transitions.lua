-- The transitions bar: where the world map's phases hand over to each other, set by the player. Zooming in, the
-- phases are:
--   1 Azeroth's one sheet
--   2 the continents' own paintings (the zones' borders at a glance)
--   3 the detailed painted map, with the zones' big banners for their cities
--   4 the city maps in place of those banners (each with its own small name)
--   5 the terrain
-- The bar runs from as far out as the map goes (left) to as close in (right), on a log scale. Each handover is a pair
-- of coloured stops, where it starts and where it is done, the stretch between shaded; the phase numbers sit
-- between them and a white line marks the zoom the map is at. Drag a stop to move it (it can't pass its
-- neighbours); click the bar to zoom the map there. The stops are kept as multiples of the zoom each is keyed to
-- (Map.FADES: Azeroth covering the window, a continent framed, a city's zone framed, a city framed), so they hold at
-- any window size; saved (WarRoomDB, the Map namespace's `fades`) until "Defaults"; "Print" lists them.
--   /wr transitions    the bar (also in the map's settings, Settings.lua)
local WR = WarRoom
local Map = WR.Map

local PANEL_LEVEL = 6200 -- over the map's host and the game's buttons
local BAR_WIDTH, BAR_HEIGHT = 600, 14
local STOP_WIDTH, STOP_HEIGHT = 8, 26

-- The handovers, in order zooming in; each sets these layers' fades together (the sea paper comes with the
-- detailed map).
local STEPS = {
	{ layers = { "continent" }, label = "1 > 2  Azeroth's sheet > continent paintings", color = { 0.35, 0.6, 1 } },
	{ layers = { "zones", "sea" }, label = "2 > 3  continent paintings > detailed map, big city banners", color = { 0.4, 0.85, 0.4 } },
	{ layers = { "cities" }, label = "3 > 4  big city banners > city maps", color = { 1, 0.7, 0.2 } },
	{ layers = { "terrain" }, label = "4 > 5  detailed map > terrain", color = { 1, 0.4, 0.45 } },
}
local PHASES = { "1", "2", "3", "4", "5" }

local panel, bar, nowLine
local stops = {} -- in order zooming in: { step, part ("None" starts, "Full" done), button }
local segments, phaseLabels, legend = {}, {}, {}
local dragging -- the stop being dragged

local function FadeOf(key)
	for _, fade in ipairs(Map.FADES) do
		if fade.key == key then
			return fade
		end
	end
end

local function Key(stop)
	return stop.step.layers[1] .. stop.part
end

-- A zoom's place along the bar (0 = furthest out, 1 = closest in), and back.
local function ToBar(ypp)
	local far, near = Map.ZoomRange()
	return math.min(1, math.max(0, math.log(far / ypp) / math.log(far / near)))
end

local function FromBar(t)
	local far, near = Map.ZoomRange()
	return far * (near / far) ^ t
end

-- The zoom a stop is at now (yards per UI unit).
local function StopYpp(stop)
	return Map.fades[Key(stop)]
end

-- Moves a stop to a zoom, kept between its neighbours': stored as a multiple of the zoom it is keyed to.
local function SetStop(i, ypp)
	local stop = stops[i]
	local before, after = stops[i - 1], stops[i + 1]
	if before then
		ypp = math.min(ypp, StopYpp(before))
	end
	if after then
		ypp = math.max(ypp, StopYpp(after))
	end
	local refs = Map.FadeRefs()
	local ref = refs and refs[FadeOf(Key(stop)).ref]
	if not ref then
		return
	end
	local factor = tonumber(("%.3g"):format(ypp / ref))
	for _, layer in ipairs(stop.step.layers) do
		Map.db.profile.fades[layer .. stop.part] = factor
	end
	Map.ApplyFades()
end

-- The cursor's place along the bar (0 to 1).
local function CursorOnBar()
	local x = GetCursorPosition() / bar:GetEffectiveScale()
	return math.min(1, math.max(0, (x - (bar:GetLeft() or 0)) / BAR_WIDTH))
end

-- How far through a layer's fade a zoom is: 0 before it starts, 1 once done.
local function Progress(layer, ypp)
	local o = Map.fades
	local none, full = o[layer .. "None"], o[layer .. "Full"]
	if not (none and full) or ypp >= none then
		return 0
	elseif ypp <= full then
		return 1
	end
	return (none - ypp) / (none - full)
end

-- Lays the stops, the shaded stretches, the phase numbers and the zoom-now line out on the bar; the legend's text.
local function Layout()
	local x = {}
	for i, stop in ipairs(stops) do
		x[i] = ToBar(StopYpp(stop)) * BAR_WIDTH
		stop.button:ClearAllPoints()
		stop.button:SetPoint("CENTER", bar, "LEFT", x[i], 0)
	end
	for s, seg in ipairs(segments) do
		local a, b = x[s * 2 - 1], x[s * 2]
		seg:ClearAllPoints()
		seg:SetPoint("TOPLEFT", bar, "TOPLEFT", a, 0)
		seg:SetSize(math.max(b - a, 1), BAR_HEIGHT)
	end
	-- (each phase number in the middle of the stretch it holds alone)
	for p, label in ipairs(phaseLabels) do
		local from = p == 1 and 0 or x[(p - 1) * 2]
		local to = p == #phaseLabels and BAR_WIDTH or x[p * 2 - 1]
		label:ClearAllPoints()
		label:SetPoint("BOTTOM", bar, "TOPLEFT", (from + to) / 2, 4)
	end
	local ypp = Map.canvas.ypp
	nowLine:ClearAllPoints()
	nowLine:SetPoint("CENTER", bar, "LEFT", ToBar(ypp) * BAR_WIDTH, 0)
	panel.now:SetText(("Now %.3g yd per unit (smaller = closer in)"):format(ypp))
	for s, step in ipairs(STEPS) do
		local o = Map.fades
		local layer = step.layers[1]
		legend[s]:SetText(("%s:  starts %.3g, done %.3g  (%d%% now)"):format(step.label, o[layer .. "None"] or 0,
			o[layer .. "Full"] or 0, Progress(layer, ypp) * 100 + 0.5))
	end
end

local function SmallButton(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 18)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function CreatePanel(host)
	panel = CreateFrame("Frame", nil, host, "BackdropTemplate")
	panel:SetSize(BAR_WIDTH + 40, 120 + #STEPS * 14)
	panel:SetPoint("TOPRIGHT", host, "TOPRIGHT", -8, -36)
	panel:SetFrameLevel(PANEL_LEVEL)
	panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	panel:SetBackdropColor(0.05, 0.05, 0.06, 0.92)
	panel:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
	-- (clicks and the wheel over the panel never reach the map; drag it by its edges)
	panel:EnableMouse(true)
	panel:EnableMouseWheel(true)
	panel:SetScript("OnMouseWheel", function() end)
	panel:SetMovable(true)
	panel:SetClampedToScreen(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", panel.StopMovingOrSizing)

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText("Transitions")
	local help = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	help:SetPoint("TOPLEFT", 10, -24)
	help:SetText("Drag a stop to move a handover; click the bar to zoom the map there. Left: zoomed out.")

	-- the bar: clicking it zooms the map there
	bar = CreateFrame("Frame", nil, panel)
	bar:SetSize(BAR_WIDTH, BAR_HEIGHT)
	bar:SetPoint("TOPLEFT", 20, -62)
	bar:EnableMouse(true)
	bar:SetScript("OnMouseDown", function()
		Map.ZoomTo(FromBar(CursorOnBar()))
	end)
	local back = bar:CreateTexture(nil, "BACKGROUND")
	back:SetAllPoints()
	back:SetColorTexture(0.18, 0.18, 0.2, 1)
	for s, step in ipairs(STEPS) do
		local seg = bar:CreateTexture(nil, "ARTWORK")
		seg:SetColorTexture(step.color[1], step.color[2], step.color[3], 0.45)
		segments[s] = seg
	end
	for p, text in ipairs(PHASES) do
		local label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetText(text)
		phaseLabels[p] = label
	end
	nowLine = bar:CreateTexture(nil, "OVERLAY", nil, 7)
	nowLine:SetColorTexture(1, 1, 1, 0.9)
	nowLine:SetSize(2, STOP_HEIGHT + 6)

	-- the stops: drag to move
	for _, step in ipairs(STEPS) do
		for _, part in ipairs({ "None", "Full" }) do
			local i = #stops + 1
			local button = CreateFrame("Button", nil, bar)
			button:SetSize(STOP_WIDTH, STOP_HEIGHT)
			button:SetFrameLevel(bar:GetFrameLevel() + 2)
			local tex = button:CreateTexture(nil, "ARTWORK")
			tex:SetAllPoints()
			local shade = part == "None" and 0.75 or 1
			tex:SetColorTexture(step.color[1] * shade, step.color[2] * shade, step.color[3] * shade, 1)
			button:SetScript("OnMouseDown", function()
				dragging = i
			end)
			button:SetScript("OnMouseUp", function()
				dragging = nil
			end)
			button:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:SetText(("%s %s at %.3g"):format(step.label, part == "None" and "starts" or "done",
					StopYpp(stops[i])))
				GameTooltip:Show()
			end)
			button:SetScript("OnLeave", GameTooltip_Hide)
			stops[i] = { step = step, part = part, button = button }
		end
	end

	-- the legend: each handover's zooms, and how far through it the map is now
	local now = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	now:SetPoint("TOPLEFT", 10, -86)
	panel.now = now
	for s, step in ipairs(STEPS) do
		local line = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		line:SetPoint("TOPLEFT", 10, -86 - s * 14)
		line:SetTextColor(step.color[1], step.color[2], step.color[3])
		legend[s] = line
	end

	SmallButton(panel, "Defaults", 80, function()
		wipe(Map.db.profile.fades)
		Map.ApplyFades()
		Layout()
	end):SetPoint("BOTTOMRIGHT", -8, 8)
	SmallButton(panel, "Print", 60, function()
		local parts = {}
		for _, fade in ipairs(Map.FADES) do
			parts[#parts + 1] = ("%s=%g"):format(fade.key, Map.FadeFactor(fade))
		end
		WR.Print("fades: %s", table.concat(parts, " "))
	end):SetPoint("BOTTOMRIGHT", -94, 8)

	-- a stop follows the cursor while dragged; the rest is laid out again a few times a second
	local since = 0
	panel:SetScript("OnUpdate", function(_, elapsed)
		if dragging then
			if not IsMouseButtonDown("LeftButton") then
				dragging = nil
			else
				SetStop(dragging, FromBar(CursorOnBar()))
				Layout()
				return
			end
		end
		since = since + elapsed
		if since >= 0.1 then
			since = 0
			Layout()
		end
	end)
	panel:SetScript("OnShow", Layout)
	panel:Hide()
end

local function Toggle()
	if not panel then
		WR.Print("open the world map first")
		return
	end
	panel:SetShown(not panel:IsShown())
end

-- Called by Map.lua as it makes its host over the game's map.
function Map.CreateTransitions(host)
	CreatePanel(host)
end

Map.ToggleTransitions = Toggle

function Map.TransitionsShown()
	return panel and panel:IsShown() or false
end

WR.SlashCommands.transitions = Toggle
