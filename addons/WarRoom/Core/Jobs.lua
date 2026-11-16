-- Background jobs. Heavy work (unpacking data, route searches, rebuilding pins) runs as a coroutine that calls
-- Jobs.Checkpoint() in its loops; all jobs together get at most Jobs.budgetMs of each frame, so nothing stutters.
local _, ns = ...
local WR = ns.WR

local Jobs = {}
WR.Jobs = Jobs

Jobs.budgetMs = 4

local running = {}
local deadline = 0
local clock = debugprofilestop
local frame = CreateFrame("Frame")
frame:Hide()

-- Inside a job: true when this frame's time is used up.
function Jobs.ShouldYield()
	return clock() >= deadline
end

-- Inside a job: pauses until the next frame when this frame's time is used up.
function Jobs.Checkpoint()
	if clock() >= deadline then
		coroutine.yield()
	end
end

-- Starts fn as a job. A named job replaces a running one of the same name. onDone(result) gets fn's return value.
function Jobs.Start(name, fn, onDone)
	if name then
		Jobs.Cancel(name)
	end
	local job = { name = name, co = coroutine.create(fn), onDone = onDone }
	running[#running + 1] = job
	frame:Show()
	return job
end

function Jobs.Cancel(name)
	for i = #running, 1, -1 do
		if running[i].name == name then
			table.remove(running, i)
		end
	end
end

function Jobs.IsRunning(name)
	for i = 1, #running do
		if running[i].name == name then
			return true
		end
	end
	return false
end

frame:SetScript("OnUpdate", function()
	deadline = clock() + Jobs.budgetMs
	local i = 1
	while i <= #running and clock() < deadline do
		local job = running[i]
		local ok, result = coroutine.resume(job.co)
		if not ok then
			table.remove(running, i)
			geterrorhandler()(result)
		elseif coroutine.status(job.co) == "dead" then
			table.remove(running, i)
			if job.onDone then
				WR.SafeCall(job.onDone, result)
			end
		else
			i = i + 1
		end
	end
	if #running == 0 then
		frame:Hide()
	end
end)
