-- WarRoom Minimap (module 3): WarRoom's map in the minimap's place.
--
-- Addons can't read where the game minimap's icons are (herbs, ore, mailboxes, party, quest areas), so the game's own
-- Minimap is kept where it is, its ground hidden (C_Minimap.SetDrawGroundTextures(false)), and our Canvas draws the
-- ground under it: a frame of its own just under the Minimap's strata, on the Minimap's rectangle, at the same centre
-- (the player) and the same zoom (C_Minimap.GetViewRadius over the Minimap's width), cut to the Minimap's shape
-- (round, or square when another addon has made it square: GetMinimapShape). The game's icons then sit on our map.
--
-- It is all terrain, as the game's is, and follows the player smoothly (by fractions of a pixel, as the game's does).
--
-- The map can be dragged away from the player and zoomed out a little past the game's furthest zoom (the mouse wheel
-- steps through the game's own zooms first). The game's icons and arrow can only show round the player at its own
-- zooms, and the game never says where they are, so while ours is away from either it is lifted a strata over the
-- game's Minimap and covers them, other addons' icons on it too (a fade of the Minimap takes its border with it and
-- leaves its icons and arrow drawn; the game draws them over frames of any level in the Minimap's strata), the ring
-- drawn again over ours, and the marks we know stand in: the player's arrow, the party, our pins. (Other addons' icons
-- in their places come with Module 10's bridge.) A few seconds after the pointer leaves, it goes
-- back to the player at the game's zoom (`idle`). Right-click while away, or the reset button over the + and -: back
-- at once. The + and - (ours over the game's) zoom ours as the wheel does.
--
-- The game's minimap is given back whole (its ground drawn, its icons shown) where ours has nothing to draw: in
-- instances (no position), indoors (the game draws the building's or cave's own floor plan: Module 4 will), with the
-- rotating minimap on, and on ground with no terrain data.
--
-- Of the game's Minimap only these change, all allowed in combat: whether its ground is drawn, its zoom (the wheel, as
-- its own buttons do) and its mouse-up and wheel scripts (wrapped: a drag never pings, and the game's own handler runs
-- for every other click). Nothing is moved, sized, faded or re-masked.
--   /wr minimap          WarRoom's minimap or the game's
--   /wr minimap status   why it is (or isn't) showing, and the view
--   /wr minimap idle N   seconds before it goes back to the player (0: never)
--   /wr minimap layers   where ours and the minimap's buttons sit (strata, level, size)
--   /wr minimap hub      other addons' minimap buttons in WarRoom's hub (Hub.lua) or on the minimap (also on
--                        WarRoom's options page: /wr options)
local WR = WarRoom
local Canvas, Position = WR.Canvas, WR.Position

local Mini = WR.NewModule("Minimap")
WR.Minimap = Mini

local defaults = { profile = { enabled = true, idle = 6, hub = true } }

local huge, max, min, abs = math.huge, math.max, math.min, math.abs
local atan2 = math.atan2 or math.atan

local ROUND = "Interface\\AddOns\\WarRoom\\Media\\Shape\\round"
-- The game minimap's view (diameters in yards) at each of its zooms, 0 the furthest, when the client won't say
-- (C_Minimap.GetViewRadius is asked first).
local DIAMETERS = {
	outdoor = { [0] = 1400 / 3, 400, 1000 / 3, 800 / 3, 200, 400 / 3 },
	indoor = { [0] = 300, 240, 180, 120, 80, 50 },
}
local STEP = 1.25 -- each zoom out past the game's furthest shows this much more
local MAX_OUT = 2 -- zooms out past the game's furthest (about 730 yards across, to the game's 467)
local CLICK_SLOP = 3 -- UI units the pointer may move and still click
-- Our frame's level. While it covers the Minimap it is a strata over it, and everything of ours stays a few levels
-- above this one, under the minimap buttons of other addons (LibDBIcon's: MEDIUM, level 8). Our frames are the
-- Minimap's children (its scale, shown with it) with fixed levels and strata, as LibDBIcon's buttons are: else a
-- click on the minimap (its cluster is "toplevel") raises them all up the strata with it.
local HOST_LEVEL = 2
local CHECK_INTERVAL = 0.25 -- seconds between checks of whether ours can show (indoors, instances...)
-- The strata just under each: our map's frame sits there, under the whole Minimap with its icons.
local BELOW = { LOW = "BACKGROUND", MEDIUM = "LOW", HIGH = "MEDIUM", DIALOG = "HIGH", FULLSCREEN = "DIALOG",
	FULLSCREEN_DIALOG = "FULLSCREEN", TOOLTIP = "FULLSCREEN_DIALOG" }
-- And just over each: there while away, over everything the game and other addons draw on the Minimap (its arrow,
-- its icons and quest areas are drawn over frames of any level in its strata; Questie's pins sit at level 2016+).
local ABOVE = { BACKGROUND = "LOW", LOW = "MEDIUM", MEDIUM = "HIGH", HIGH = "DIALOG", DIALOG = "FULLSCREEN",
	FULLSCREEN = "FULLSCREEN_DIALOG", FULLSCREEN_DIALOG = "TOOLTIP" }

local canaccess = canaccessvalue or function()
	return true
end

local host, canvas
local active = false -- ours shows (else the game's own minimap, ground and all)
local reason = "not started" -- why it doesn't
local groundHidden = false
local free -- { continent, x, y }: the view's centre while dragged away from the player
local out = 0 -- zooms out past the game's furthest
local drag -- { x, y, lastX, lastY, moved } while the left button is down on the minimap
local idle = 0 -- seconds since the view was last moved by hand (with the pointer off the minimap)
local covering = false -- ours lifted over the game's Minimap
local redrawing -- (our own zoom changes to make the game redraw its minimap: not the player's)
local last = {} -- the view last set: continent, x, y, ypp
Mini.player = {} -- the player where the view last put them: continent, x, y

---------------------------------------------------------------------------------------------------
-- The game's minimap
---------------------------------------------------------------------------------------------------

local function ZoomLevels()
	local n = Minimap.GetZoomLevels and Minimap:GetZoomLevels()
	return type(n) == "number" and n > 1 and n or 6
end

-- The game minimap's radius in yards now: the client's own, else its zoom's.
local function GameRadius()
	local get = C_Minimap and C_Minimap.GetViewRadius
	if get then
		local ok, r = pcall(get)
		if ok and canaccess(r) and type(r) == "number" and r > 0 then
			return r
		end
	end
	local t = IsIndoors() and DIAMETERS.indoor or DIAMETERS.outdoor
	return (t[Minimap:GetZoom()] or t[0]) / 2
end

-- Makes the game draw its minimap again (it may stay black until the player moves once its ground is back): a zoom
-- there and back.
local function Redraw()
	local z, n = Minimap:GetZoom(), ZoomLevels()
	local other = z + 1 < n and z + 1 or z - 1
	if other < 0 then
		return
	end
	redrawing = true
	pcall(Minimap.SetZoom, Minimap, other)
	pcall(Minimap.SetZoom, Minimap, z)
	redrawing = nil
end

local function SetGround(hidden)
	if hidden == groundHidden then
		return
	end
	groundHidden = hidden
	pcall(C_Minimap.SetDrawGroundTextures, not hidden)
	-- (noted, so Core gives it back at the next login should this module be gone by then)
	WR.db.global.minimapGroundHidden = hidden or nil
	if not hidden then
		Redraw()
		C_Timer.After(0.5, function()
			if not groundHidden then
				Redraw()
			end
		end)
	end
end

-- The shape the game's minimap is cut to: round, unless another addon made it square.
local function Shape()
	local ok, shape = pcall(GetMinimapShape or error)
	return ok and shape == "SQUARE" and Canvas.SQUARE or ROUND
end
Mini.Shape = Shape

-- Why ours can't show now, or nil when it can.
local function Blocker()
	if not (Mini.enabled and Mini.db.profile.enabled) then
		return "turned off (/wr minimap)"
	end
	if not Minimap:IsVisible() then
		return "the game's minimap is hidden"
	end
	if not (C_Minimap and C_Minimap.SetDrawGroundTextures) then
		return "the game can't hide its minimap's ground"
	end
	local s = Position.state
	if s.inInstance then
		return "in an instance"
	end
	if not s.known then
		return "no position"
	end
	if IsIndoors() then
		return "indoors"
	end
	if GetCVar("rotateMinimap") == "1" then
		return "the rotating minimap is on"
	end
	if not Canvas.TileData(s.continent) then
		return "no terrain here"
	end
end

---------------------------------------------------------------------------------------------------
-- The view
---------------------------------------------------------------------------------------------------

-- Whether ours is away from the game's view (dragged off the player or zoomed out past it): its icons hidden.
function Mini.Away()
	return active and (free ~= nil or out > 0)
end

local function SnapBack()
	free, out, idle = nil, 0, 0
end
Mini.SnapBack = SnapBack

-- Every frame: the view on the player (or where it was dragged to) at the game's zoom (or ours past it).
local function UpdateView()
	local w = canvas.frame:GetWidth()
	if not w or w <= 1 then
		return
	end
	local ypp = 2 * GameRadius() * STEP ^ out / w
	local c, x, y = Position.Read("player")
	local p = Mini.player
	p.continent, p.x, p.y = c, x, y
	if free then
		c, x, y = free.continent, free.x, free.y
	end
	if not c then
		return
	end
	if c ~= last.continent or x ~= last.x or y ~= last.y or ypp ~= last.ypp then
		last.continent, last.x, last.y, last.ypp = c, x, y, ypp
		canvas:SetView(c, x, y, ypp)
	end
end

-- Zooms in (delta > 0) or out a step: through the game's own zooms, then ours past its furthest.
local function Zoom(delta)
	local z, n = Minimap:GetZoom(), ZoomLevels()
	if delta > 0 then
		if out > 0 then
			out = out - 1
		elseif z < n - 1 then
			Minimap:SetZoom(z + 1)
		end
	elseif out == 0 and z > 0 then
		Minimap:SetZoom(z - 1)
	elseif active and out < MAX_OUT then
		out = out + 1
	end
	idle = 0
end
Mini.Zoom = Zoom

-- Whether a step in (delta > 0) or out is there to take.
local function CanZoom(delta)
	local z, n = Minimap:GetZoom(), ZoomLevels()
	if delta > 0 then
		return out > 0 or z < n - 1
	end
	return z > 0 or out < MAX_OUT
end

---------------------------------------------------------------------------------------------------
-- The zoom buttons
---------------------------------------------------------------------------------------------------

-- The game's + and - (Minimap.ZoomIn and ZoomOut, shown while the pointer is on the minimap) stop at its furthest
-- zoom and lie under ours while it covers the Minimap. While ours shows, a pair of ours sits over them, in their
-- place with their art, and drives our view as the wheel does: the game's zooms, ours past its furthest, and in or
-- out while panned away.
local ZOOM_LEVEL = 9 -- (over other addons' minimap buttons, LibDBIcon's at 8, as the game's are)
local ZOOM_BUTTONS = {
	{ delta = 1, key = "ZoomIn", art = "ui-hud-minimap-zoom-in", x = 88, y = -68, w = 17, h = 17, sound = "IG_MINIMAP_ZOOM_IN",
		text = "ZOOM_IN" },
	{ delta = -1, key = "ZoomOut", art = "ui-hud-minimap-zoom-out", x = 72, y = -84, w = 17, h = 9,
		sound = "IG_MINIMAP_ZOOM_OUT", text = "ZOOM_OUT" },
}
local zoomButtons = {}
Mini.zoomButtons = zoomButtons
-- And over them, a step further round the ring's curve, ours back to the player at the game's zoom (as right-click
-- does): our own art in the style of theirs (`warroom buttons`).
local RESET_ART = "Interface\\AddOns\\WarRoom_Minimap\\Media\\reset"
local RESET_SIZE = 17
local resetButton

-- A frame of ours on the Minimap in a strata of our choosing, kept there (as LibDBIcon's buttons are).
local function FixStrata(frame, strata)
	if frame.SetFixedFrameStrata then
		frame:SetFixedFrameStrata(false)
	end
	frame:SetFrameStrata(strata)
	if frame.SetFixedFrameStrata then
		frame:SetFixedFrameStrata(true)
	end
end
Mini.FixStrata = FixStrata

local function CreateZoomButtons()
	local strata = ABOVE[Minimap:GetFrameStrata()] or "MEDIUM"
	for _, spec in ipairs(ZOOM_BUTTONS) do
		local b = CreateFrame("Button", nil, Minimap)
		FixStrata(b, strata)
		Canvas.FixLevel(b, ZOOM_LEVEL)
		local game = Minimap[spec.key]
		if game then
			b:SetAllPoints(game)
		else
			b:SetSize(spec.w, spec.h)
			b:SetPoint("CENTER", Minimap, "CENTER", spec.x, spec.y)
		end
		b:SetNormalAtlas(spec.art)
		b:SetPushedAtlas(spec.art .. "-down")
		b:SetHighlightAtlas(spec.art .. "-mouseover")
		b:SetDisabledAtlas(spec.art)
		local disabled = b:GetDisabledTexture()
		if disabled then
			disabled:SetDesaturated(true)
		end
		b:SetScript("OnClick", function()
			if PlaySound and SOUNDKIT and SOUNDKIT[spec.sound] then
				PlaySound(SOUNDKIT[spec.sound])
			end
			Zoom(spec.delta)
		end)
		b:SetScript("OnEnter", function()
			if GetCVar("UberTooltips") == "1" and _G[spec.text] then
				GameTooltip_SetDefaultAnchor(GameTooltip, UIParent)
				GameTooltip:SetText(_G[spec.text])
			end
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		b:Hide()
		b.delta = spec.delta
		zoomButtons[#zoomButtons + 1] = b
	end

	local b = CreateFrame("Button", nil, Minimap)
	FixStrata(b, strata)
	Canvas.FixLevel(b, ZOOM_LEVEL)
	b:SetSize(RESET_SIZE, RESET_SIZE)
	b:SetNormalTexture(RESET_ART)
	b:SetPushedTexture(RESET_ART .. "-down")
	b:SetHighlightTexture(RESET_ART .. "-mouseover", "ADD")
	b:SetDisabledTexture(RESET_ART)
	local disabled = b:GetDisabledTexture()
	if disabled then
		disabled:SetDesaturated(true)
	end
	b:SetScript("OnClick", function()
		if PlaySound and SOUNDKIT and SOUNDKIT.IG_MINIMAP_ZOOM_OUT then
			PlaySound(SOUNDKIT.IG_MINIMAP_ZOOM_OUT)
		end
		SnapBack()
	end)
	b:SetScript("OnEnter", function()
		GameTooltip_SetDefaultAnchor(GameTooltip, UIParent)
		GameTooltip:SetText("Back to you")
		GameTooltip:AddLine("The map on you again, at the game's zoom. (Right-click on the map does the same.)", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	b:Hide()
	resetButton = b
	Mini.resetButton = b
end

-- The reset button's place: the game's + and - lie on the ring's curve a step apart, so it goes a step on from the +,
-- the same way round, at the +'s distance from the centre (else where the game's XML puts them).
local function PlaceReset()
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local function Offset(frame, spec)
		local x, y
		if frame then
			x, y = frame:GetCenter()
		end
		if x and y and mx and my and canaccess(x) and canaccess(mx) then
			local s = frame:GetEffectiveScale() / scale
			return x * s - mx, y * s - my
		end
		return spec.x, spec.y
	end
	local ix, iy = Offset(Minimap.ZoomIn, ZOOM_BUTTONS[1])
	local ox, oy = Offset(Minimap.ZoomOut, ZOOM_BUTTONS[2])
	local a = atan2(iy, ix)
	local step = a - atan2(oy, ox)
	local r = math.sqrt(ix * ix + iy * iy)
	a = a + step * 1.1 -- (a touch further: the reset is taller than the -)
	resetButton:ClearAllPoints()
	resetButton:SetPoint("CENTER", Minimap, "CENTER", r * math.cos(a), r * math.sin(a))
end

-- Ours shown while ours is and the pointer is on the minimap (as the game shows its own), each greyed when it has no
-- step left to take (the reset when the map is on the player at the game's zoom already).
local function UpdateZoomButtons()
	local hover = active and Minimap:IsMouseOver()
	for _, b in ipairs(zoomButtons) do
		hover = hover or (active and b:IsShown() and b:IsMouseOver())
	end
	hover = hover or (active and resetButton:IsShown() and resetButton:IsMouseOver())
	hover = hover and true or false
	for _, b in ipairs(zoomButtons) do
		b:SetShown(hover)
		if hover then
			b:SetEnabled(CanZoom(b.delta))
		end
	end
	if hover and not resetButton:IsShown() then
		PlaceReset()
	end
	resetButton:SetShown(hover)
	if hover then
		resetButton:SetEnabled(Mini.Away())
	end
end

---------------------------------------------------------------------------------------------------
-- Pointer (on the game's Minimap, which keeps the mouse: its icons' tooltips work as ever)
---------------------------------------------------------------------------------------------------

local function CursorOffset()
	local x, y = GetCursorPosition()
	local frame = canvas.frame
	local scale = frame:GetEffectiveScale()
	local cx, cy = frame:GetCenter()
	return x / scale - cx, y / scale - cy
end

local function OnMouseDown(_, button)
	if active and button == "LeftButton" then
		local x, y = CursorOffset()
		drag = { x = x, y = y, lastX = x, lastY = y, moved = false }
	end
end

-- The game's own handler (its ping, its menus) for every click but ours: a drag, a left click while ours is away (it
-- would ping the wrong place) and a right click while away (back to the player).
local function WrapMouseUp(original)
	return function(self, button, ...)
		local d = drag
		if button == "LeftButton" then
			drag = nil
		end
		if active then
			if button == "LeftButton" and ((d and d.moved) or Mini.Away()) then
				return
			end
			if button == "RightButton" and Mini.Away() then
				SnapBack()
				return
			end
		end
		if original then
			return original(self, button, ...)
		end
	end
end

local function WrapMouseWheel(original)
	return function(self, delta, ...)
		if active or not original then
			Zoom(delta)
		else
			return original(self, delta, ...)
		end
	end
end

local function UpdateDrag()
	local d = drag
	if not d then
		return
	end
	if not IsMouseButtonDown("LeftButton") then
		drag = nil -- (let go off the minimap)
		return
	end
	local x, y = CursorOffset()
	if not d.moved and abs(x - d.x) + abs(y - d.y) > CLICK_SLOP then
		d.moved = true
	end
	if d.moved and (x ~= d.lastX or y ~= d.lastY) then
		local cx, cy = canvas:FrameToWorld(d.lastX - x, d.lastY - y)
		d.lastX, d.lastY = x, y
		free = { continent = canvas.continent, x = cx, y = cy }
		idle = 0
	end
end

-- Back to the player once the pointer has been off the minimap for `idle` seconds.
local function UpdateIdle(elapsed)
	if not Mini.Away() or drag then
		idle = 0
		return
	end
	local limit = Mini.db.profile.idle
	if Minimap:IsMouseOver() or not limit or limit <= 0 then
		idle = 0
		return
	end
	idle = idle + elapsed
	if idle >= limit then
		SnapBack()
	end
end

-- Ours under the game's Minimap (its icons on our map), or a strata over it while away: covering its arrow, its icons
-- and its quest areas, and other addons' icons on it, which would all be in the wrong place. Meanwhile ours takes the
-- mouse (no tooltips of hidden icons) and draws the minimap's ring again over its map. Our frames only: allowed in
-- combat.
-- Our frames at their levels again, fixed: a change of strata may move a frame's level (and its children's) up the
-- new strata, over other addons' minimap buttons.
local function Level()
	Canvas.FixLevel(host, HOST_LEVEL)
	canvas:SetLevel(HOST_LEVEL + 1, true)
	Canvas.FixLevel(Mini.top, HOST_LEVEL + 4)
end

local function UpdateCover()
	if not host then
		return
	end
	local cover = Mini.Away()
	if cover == covering then
		if cover and host:GetFrameLevel() ~= HOST_LEVEL then
			Level()
		end
		return
	end
	covering = cover
	local strata = Minimap:GetFrameStrata()
	FixStrata(host, cover and (ABOVE[strata] or "MEDIUM") or BELOW[strata] or "BACKGROUND")
	Level()
	host:EnableMouse(cover)
	host:EnableMouseWheel(cover)
	Mini.CoverMarks(cover)
end


---------------------------------------------------------------------------------------------------
-- Ours or the game's
---------------------------------------------------------------------------------------------------

local function CreateHost()
	local strata = Minimap:GetFrameStrata()
	if not BELOW[strata] then
		-- (the Minimap at the very bottom: lifted a strata, so ours fits under it)
		strata = "LOW"
		WR.AfterCombat("minimap:strata", function()
			Minimap:SetFrameStrata(strata)
		end)
	end
	host = CreateFrame("Frame", nil, Minimap)
	FixStrata(host, BELOW[strata])
	Canvas.FixLevel(host, HOST_LEVEL)
	host:SetAllPoints(Minimap)
	host:Hide()
	Mini.host = host
	-- (the mouse while it covers the Minimap: a drag, the wheel, right-click back to the player)
	host:SetScript("OnMouseDown", OnMouseDown)
	host:SetScript("OnMouseUp", function(_, button)
		if button == "LeftButton" then
			drag = nil
		elseif button == "RightButton" then
			SnapBack()
		end
	end)
	host:SetScript("OnMouseWheel", function(_, delta)
		Zoom(delta)
	end)
	host:EnableMouse(false)
	host:EnableMouseWheel(false)

	-- (all terrain, as the game's minimap: no paintings; terrain and pins a level or two over our frame)
	canvas = Canvas.New(host, { shape = Shape(), smooth = true, art = false, zones = false, cities = false,
		terrainFull = huge, terrainNone = huge, overlayLevel = 2 })
	Mini.canvas = canvas
	canvas:SetOnUpdate(function()
		Mini.PlaceMarks()
	end)
	host:SetScript("OnSizeChanged", function()
		last.ypp = nil
	end)
	Mini.CreateMarks(host, canvas)
end

-- Ours or the game's own, for where the player is now.
local function Evaluate()
	local why = Blocker()
	local on = why == nil
	reason = why or "showing"
	if on and not host then
		CreateHost()
	end
	if on ~= active then
		active = on
		host:SetShown(on)
		drag = nil
		if not on then
			free, out = nil, 0
		end
		last.ypp = nil
	end
	SetGround(on)
	if on then
		canvas:SetShape(Shape())
	end
end
Mini.Evaluate = Evaluate

local sinceCheck = 0
local buttonsBroken -- (an error in the buttons: reported once, and the map goes on without them)
local function OnUpdate(_, elapsed)
	sinceCheck = sinceCheck + elapsed
	if sinceCheck >= CHECK_INTERVAL then
		sinceCheck = 0
		Evaluate()
	end
	if active then
		UpdateDrag()
		UpdateIdle(elapsed)
		UpdateCover()
		UpdateView()
		Mini.TickMarks(elapsed)
	end
	if not buttonsBroken then
		local ok, err = pcall(UpdateZoomButtons)
		if not ok then
			buttonsBroken = true
			geterrorhandler()(err)
		end
	end
end

local function Hook()
	local up = Minimap:GetScript("OnMouseUp")
	Minimap:SetScript("OnMouseUp", WrapMouseUp(up))
	local wheel = Minimap:GetScript("OnMouseWheel")
	Minimap:EnableMouseWheel(true)
	Minimap:SetScript("OnMouseWheel", WrapMouseWheel(wheel))
	Minimap:HookScript("OnMouseDown", OnMouseDown)
	-- (hidden by the game or another addon: its ground given back at once)
	local function Now()
		Evaluate()
	end
	Minimap:HookScript("OnShow", Now)
	Minimap:HookScript("OnHide", Now)
	-- (the game's zoom buttons, or another addon: on its zoom, ours too)
	hooksecurefunc(Minimap, "SetZoom", function()
		if not redrawing then
			out = 0
		end
	end)
end

function Mini:OnEnable()
	self.db = WR.db:RegisterNamespace("Minimap", defaults)
	if not Minimap then
		reason = "no game minimap"
		return
	end
	WR.AfterCombat("minimap:hook", Hook)
	local driver = CreateFrame("Frame")
	driver:SetScript("OnUpdate", OnUpdate)
	local function Now()
		sinceCheck = CHECK_INTERVAL
	end
	WR.RegisterCallback(Mini, "WR_ZONE", Now)
	WR.RegisterCallback(Mini, "WR_POSITION_LOST", Now)
	WR.OnEvent("MINIMAP_UPDATE_ZOOM", Now)
	WR.OnEvent("CVAR_UPDATE", Now)
	Evaluate()
	-- (the extras last, each on its own: a fault in one never stops the map)
	WR.SafeCall(CreateZoomButtons)
	if Mini.CreateHub then
		WR.SafeCall(Mini.CreateHub)
	end
	WR.SafeCall(function()
		-- (WarRoom's options page)
		Mini.hubSetting = WR.Options and WR.Options.AddCheckbox({
			section = "Minimap",
			key = "MINIMAP_HUB",
			name = "Minimap button hub",
			tooltip = "Gathers other addons' minimap buttons off the minimap's ring into one column, opened from WarRoom's "
				.. "button right of the minimap. Off: each button goes back on the ring where it was.",
			default = true,
			get = function()
				return Mini.db.profile.hub
			end,
			set = function(value)
				Mini.SetHub(value)
			end,
		})
	end)
end

function Mini.Status()
	return active, reason, free ~= nil, out
end

WR.SlashCommands.minimap = function(rest)
	local profile = Mini.db.profile
	local command, value = (rest or ""):match("^(%S*)%s*(.-)$")
	if command == "status" then
		local w = canvas and canvas.frame:GetWidth()
		WR.Print("minimap: %s; zoom %d of %d%s, radius %.0f yd, %s%s", reason, Minimap:GetZoom(), ZoomLevels(),
			out > 0 and (" +" .. out .. " out") or "", GameRadius() * STEP ^ out, Shape() == ROUND and "round" or "square",
			free and ", dragged away" or "")
		if canvas and canvas.ypp then
			WR.Print("view: continent %s, %.1f, %.1f, %.2f yd per unit over %.0f units", tostring(canvas.continent),
				canvas.cx, canvas.cy, canvas.ypp, w or 0)
		end
	elseif command == "layers" then
		-- (where ours and the minimap's buttons sit: strata, level, size)
		local function Show(label, f)
			if f then
				local w, h = f:GetSize()
				WR.Print("%s: %s %d, %.0fx%.0f, scale %.2f%s", label, f:GetFrameStrata(), f:GetFrameLevel(), w or 0, h or 0,
					f:GetEffectiveScale(), f.IsVisible and not f:IsVisible() and ", hidden" or "")
			end
		end
		Show("Minimap", Minimap)
		Show("ours", host)
		Show("our map", canvas and canvas.frame)
		Show("our marks", canvas and canvas.overlay)
		Show("our ring", Mini.top)
		local n = 0
		for _, child in ipairs({ Minimap:GetChildren() }) do
			local name = child.GetName and child:GetName()
			if name and n < 4 and not name:find("^Minimap") then
				n = n + 1
				Show(name, child)
			end
		end
	elseif command == "hub" then
		WR.Options.Set(Mini.hubSetting, Mini.SetHub, not profile.hub)
		WR.Print("minimap: addon buttons %s", profile.hub and "in WarRoom's hub" or "back on the minimap")
	elseif command == "idle" then
		local n = tonumber(value)
		if n then
			profile.idle = max(0, n)
		end
		WR.Print("minimap: back to you %s", profile.idle > 0 and ("after " .. profile.idle .. " s") or "never (right-click)")
	else
		profile.enabled = not profile.enabled
		WR.Print("minimap: %s", profile.enabled and "WarRoom's" or "the game's")
		Evaluate()
	end
end
