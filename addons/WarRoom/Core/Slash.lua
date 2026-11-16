-- /warroom (or /wr): developer commands until the options panel exists.
local _, ns = ...
local WR = ns.WR

-- commands[name] = function(rest) where rest is the text after the command. Other files add their own.
local commands = {}
WR.SlashCommands = commands

commands.version = function()
	WR.Print("version %s", WR.version)
end

commands.debug = function()
	WR.db.profile.debug = not WR.db.profile.debug
	WR.Print("debug %s", WR.db.profile.debug and "on" or "off")
end

commands.pos = function()
	local s = WR.Position.state
	if not s.known then
		WR.Print("position unknown (in instance: %s)", tostring(s.inInstance))
		return
	end
	local tx, ty, fx, fy = WR.Coords.WorldToTile(s.x, s.y)
	WR.Print(
		"continent %d  x %.1f  y %.1f  (%s)  tile %d_%d (%.2f, %.2f)  map %s",
		s.continent,
		s.x,
		s.y,
		s.source,
		tx,
		ty,
		fx,
		fy,
		tostring(s.mapID)
	)
	WR.Print("zone %s / %s / %s  indoors %s", tostring(s.zone), tostring(s.subzone), tostring(s.minimapZone), tostring(s.indoors))
end

commands.pins = function()
	WR.Print("%d pins", WR.Pins.Count())
end

commands.help = function()
	local names = {}
	for name in pairs(commands) do
		if name ~= "help" then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	WR.Print("/wr " .. table.concat(names, " | "))
end

SLASH_WARROOM1 = "/warroom"
SLASH_WARROOM2 = "/wr"
SlashCmdList.WARROOM = function(input)
	local command, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	local handler = commands[command:lower()] or commands.help
	handler(rest)
end
