-- The continents' and seas' names, lettered live over the world map's painted sheets (which are cleaned of their
-- own): where Blizzard's art lettered them, in the client's font, dark ink in small capitals under a capital
-- initial, set wide, in a soft light halo. The names and their places are OpenMap's (Data/Labels.lua), and so is
-- this way of lettering them (OpenMap's Map/Stitch.lua, MIT, Copyright (c) 2026 OpenMap contributors). A sea named
-- at the edge of a continent's map (the Veiled Sea, the Forbidding Sea) would lie under the torn border of Azeroth's,
-- which never shows: it is moved in, just inside.
--
-- Each name is built once, in "font units" on a frame of its own, NAME_UNITS a pixel of the art it was measured on;
-- the frame is scaled and placed again only when the zoom changes, and pans with the Canvas's world frame. The
-- continents' names show until the detailed map comes in, the seas' until the sea paper does.
local WR = WarRoom
local Canvas, Coords = WR.Canvas, WR.Coords
local Map = WR.Map

local ART_W = 1002 -- the art the lines are measured on: its pixels across (and 668 down)
local NAME_UNITS = 4 -- font units per art pixel
local NAME_CAP = 0.69 -- Friz Quadrata's capital height, in font sizes
local NAME_MIDDLE = 0.36 -- ... and the middle of its letters' box, above the baseline
local NAME_SMALL = 0.78 -- small capitals, to the capitals (as measured on the art)
local NAME_TRACK = 0.1 -- the least letter spacing, in cap heights (a longer name in another language)
local NAME_SPACE = 0.4 -- a word space, in cap heights
local HALO = { { 0.07, 1 }, { 0.15, 0.45 } } -- copies behind the ink: { ring radius (cap heights), strength }
local HALO_TAPS = 8
local INK_ALPHA = 0.9
local EDGE_MARGIN = 0.01 -- of Azeroth's painting's width: room left between a name and the edge of what shows of it

local canvas, root
local names -- { { frame, label, continent, top, left, yards a pixel }, ... }, built when first shown
local laidOut -- the layout they were last placed for

-- The client's name for a label (localized), else its own.
local function NameOf(label)
	local n, text = label.name, nil
	if n.map then
		local info = C_Map.GetMapInfo(n.map)
		text = info and info.name
	elseif n.area and C_Map.GetAreaInfo then
		text = C_Map.GetAreaInfo(n.area)
	end
	return (text and text ~= "") and text or n.text
end

-- The name's words onto the art's lines: one each, as the art sets them, or (another language's name, with more or
-- fewer words) all on its widest.
local function SetLines(label, text)
	local words = {}
	for word in text:gmatch("%S+") do
		words[#words + 1] = word
	end
	local lines = label.lines
	if #words == #lines then
		local out = {}
		for i, line in ipairs(lines) do
			out[i] = { line, words[i] }
		end
		return out
	end
	local widest = lines[1]
	for _, line in ipairs(lines) do
		if line[2] - line[1] > widest[2] - widest[1] then
			widest = line
		end
	end
	return { { widest, text } }
end

-- Letters a label on `f`, in font units from the top left of the art it was measured on. Returns the box its
-- letters fill: left, right, top, bottom (font units, down positive).
local function Letter(f, label)
	local ink, glow = label.ink, label.glow
	local font = STANDARD_TEXT_FONT
	local u = NAME_UNITS
	local boxL, boxR, boxT, boxB = math.huge, -math.huge, math.huge, -math.huge
	for _, set in ipairs(SetLines(label, NameOf(label))) do
		local line, text = set[1], set[2]
		local left, right = line[1] * u, line[2] * u
		local base, cap = line[3] * u, line[4] * u
		-- a capital starting each word, small capitals after (a line set all small is measured at their size)
		local glyphs, width, wordStart = {}, 0, true
		for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			if ch == " " then
				glyphs[#glyphs + 1] = { w = NAME_SPACE * cap }
				width = width + NAME_SPACE * cap
				wordStart = true
			else
				local size = cap / NAME_CAP * ((wordStart or line[5]) and 1 or NAME_SMALL)
				local fs = f:CreateFontString(nil, "OVERLAY")
				fs:SetFont(font, size, "")
				fs:SetText(#ch == 1 and ch:upper() or ch)
				fs:SetTextColor(ink[1] / 255, ink[2] / 255, ink[3] / 255, INK_ALPHA)
				fs:SetShadowOffset(0, 0)
				local w = fs:GetStringWidth()
				glyphs[#glyphs + 1] = { fs = fs, size = size, w = w }
				width = width + w
				wordStart = false
			end
		end
		-- set wide across the art's line, centred on it
		local gaps = #glyphs - 1
		local track = gaps > 0 and math.max(NAME_TRACK * cap, (right - left - width) / gaps) or 0
		local x = (left + right) / 2 - (width + track * gaps) / 2
		boxL, boxR = math.min(boxL, x), math.max(boxR, x + width + track * gaps)
		boxT, boxB = math.min(boxT, base - cap), math.max(boxB, base)
		for _, g in ipairs(glyphs) do
			if g.fs then
				local y = -base + NAME_MIDDLE * g.size
				g.fs:SetPoint("LEFT", f, "TOPLEFT", x, y)
				-- the halo: copies in a ring round it in the glow's colour, each one's shadow the tap opposite it
				for _, ring in ipairs(HALO) do
					local r, a = ring[1] * cap, math.min(1, ring[2] * label.glowA / HALO_TAPS * 2)
					for i = 1, HALO_TAPS / 2 do
						local angle = (i - 1) / HALO_TAPS * 2 * math.pi
						local dx, dy = r * math.cos(angle), r * math.sin(angle)
						local copy = f:CreateFontString(nil, "ARTWORK")
						copy:SetFont(font, g.size, "")
						copy:SetText(g.fs:GetText())
						copy:SetTextColor(glow[1] / 255, glow[2] / 255, glow[3] / 255, a)
						copy:SetShadowColor(glow[1] / 255, glow[2] / 255, glow[3] / 255, a)
						copy:SetShadowOffset(-2 * dx, -2 * dy)
						copy:SetPoint("LEFT", f, "TOPLEFT", x + dx, y + dy)
					end
				end
			end
			x = x + g.w + track
		end
	end
	return boxL, boxR, boxT, boxB
end

-- Where the art a label was measured on lies: its continent, top, left, and yards a pixel; nil when not drawn.
local function ArtPlace(mapID)
	local rect
	if mapID == Canvas.WORLD_MAP then
		rect = Canvas.WorldRect(Canvas.WorldContinents()[1])
	else
		rect = Coords.GetMapRect(mapID)
	end
	if rect then
		return rect.continent, rect.top, rect.left, rect.width / ART_W
	end
end

-- How far (yards north, yards west) a name lettered at top, left must move to lie inside the part of Azeroth's
-- painting that shows (the seas named at a continent map's edge are past it, under the torn border); its letters'
-- box in font units.
local function Inside(continent, top, left, yards, boxL, boxR, boxT, boxB)
	local inner = Map.InnerWorld and Map.InnerWorld(continent)
	if not (inner and boxL < boxR) then
		return 0, 0
	end
	local k = yards / NAME_UNITS
	local margin = inner.width * EDGE_MARGIN
	local west, east = left - boxL * k, left - boxR * k
	local north, south = top - boxT * k, top - boxB * k
	local dy, dx = 0, 0
	if west > inner.left - margin then
		dy = inner.left - margin - west
	elseif east < inner.right + margin then
		dy = inner.right + margin - east
	end
	if north > inner.top - margin then
		dx = inner.top - margin - north
	elseif south < inner.bottom + margin then
		dx = inner.bottom + margin - south
	end
	return dx, dy
end

local function Build()
	names = {}
	for _, label in ipairs(WR.MapLabels or {}) do
		local continent, top, left, yards = ArtPlace(label.map)
		if continent then
			local f = CreateFrame("Frame", nil, root)
			f:SetSize(1, 1)
			local dx, dy = Inside(continent, top, left, yards, Letter(f, label))
			names[#names + 1] = { f, label, continent, top + dx, left + dy, yards }
		end
	end
end

function Map.CreateLabels(c, level)
	canvas = c
	root = CreateFrame("Frame", nil, canvas.world)
	root:SetAllPoints(canvas.world)
	root:SetFrameLevel(level)
end

-- After every redraw: each name's strength from the Canvas's fades, and its place when the zoom changed.
function Map.PlaceLabels()
	local stats = canvas.stats
	local onWorld = Canvas.WorldRect(canvas.continent) ~= nil
	local painted = 1 - (stats.alpha or 0)
	local land = onWorld and painted * (1 - (stats.zoneAlpha or 0)) or 0
	local sea = onWorld and painted * (1 - (stats.paperAlpha or 0)) or 0
	if land <= 0.01 and sea <= 0.01 then
		root:Hide()
		return
	end
	root:Show()
	if not names then
		Build()
	end
	local key = canvas.layout .. ":" .. canvas.continent
	for _, n in ipairs(names) do
		local f, label = n[1], n[2]
		local alpha = label.fade == "land" and land or sea
		f:SetShown(alpha > 0.01)
		f:SetAlpha(alpha)
		if laidOut ~= key then
			local x, y = canvas:ToLayout(n[4], n[5], n[3])
			if x then
				local scale = n[6] / (NAME_UNITS * canvas.layoutYpp)
				f:SetScale(scale)
				f:ClearAllPoints()
				f:SetPoint("TOPLEFT", root, "CENTER", x / scale, y / scale)
			else
				f:Hide()
			end
		end
	end
	laidOut = key
end
