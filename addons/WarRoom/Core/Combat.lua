-- Combat queue. During combat the game locks some of Blizzard's frames (the game minimap's position, size and
-- mask among them). Anything that changes those goes through WR.AfterCombat: it runs at once out of combat, or
-- when combat ends. Our own frames don't need this.
local _, ns = ...
local WR = ns.WR

local queue, order = {}, {}

function WR.InCombat()
	return InCombatLockdown()
end

-- Runs fn now, or once combat ends. Calls sharing a key replace each other, so only the latest is applied.
-- Returns true when fn ran now.
function WR.AfterCombat(key, fn)
	if not InCombatLockdown() then
		fn()
		return true
	end
	key = key or fn
	if not queue[key] then
		order[#order + 1] = key
	end
	queue[key] = fn
	return false
end

WR.OnEvent("PLAYER_REGEN_ENABLED", function()
	local keys, fns = order, queue
	order, queue = {}, {}
	for i = 1, #keys do
		WR.SafeCall(fns[keys[i]])
	end
end)
