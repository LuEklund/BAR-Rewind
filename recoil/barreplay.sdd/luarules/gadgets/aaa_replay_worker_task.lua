function gadget:GetInfo()
	return {
		name = "Replay Worker Task",
		desc = "Replay units never build: report their recorded work so BAR's nano spray draws it",
		author = "lucas",
		license = "GPL v2",
		layer = -1000,
		enabled = true,
	}
end

-- The Replay Player gadget publishes each builder's recorded work as unit rules params. BAR's
-- Nano Particles GL4 gadget caches Spring.GetUnitWorkerTask and GetUnitCurrentBuildPower when its
-- file loads, so they are swapped here, in a file that loads first (gadgets load in file order).
if gadgetHandler:IsSyncedCode() then return end

local GetUnitRulesParam = Spring.GetUnitRulesParam
local workerTask, buildPower = Spring.GetUnitWorkerTask, Spring.GetUnitCurrentBuildPower

Spring.GetUnitWorkerTask = function(unitID)
	local cmd = GetUnitRulesParam(unitID, "replay_work_cmd")
	if not cmd then return workerTask(unitID) end
	if cmd == 0 then return nil end
	return cmd, GetUnitRulesParam(unitID, "replay_work_target")
end

Spring.GetUnitCurrentBuildPower = function(unitID)
	local p = GetUnitRulesParam(unitID, "replay_work_power")
	return p or buildPower(unitID)
end
