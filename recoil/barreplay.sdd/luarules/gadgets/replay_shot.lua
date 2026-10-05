function gadget:GetInfo()
	return { name = "Replay Shot", desc = "Check mode: replay/shot.lua -> jump, frame the camera, screenshot, quit", layer = 1, enabled = true }
end

-- replay/shot.lua: return { frame = <frame>, state = <Spring.GetCameraState()> }, written by tools/pipeline.py play ... camera.json out.png
if not VFS.FileExists("replay/shot.lua") then return end
local shot = VFS.Include("replay/shot.lua")
local frame = shot.frame

-- the Replay Player gadget starts paused at shot.frame on its own
if gadgetHandler:IsSyncedCode() then return end

local ticks = 0
function gadget:Update()
	if (Spring.GetGameFrame() or 0) < 2 then return end
	ticks = ticks + 1
	if ticks == 2 and not shot.ui then Spring.SendCommands("hideinterface 1") end
	-- exercises the widget -> gadget message path the timeline uses
	if ticks == 20 and shot.seek then Spring.SendLuaRulesMsg("replay:seek " .. shot.seek) end
	if ticks == 20 and shot.speed then Spring.SendLuaRulesMsg("replay:speed " .. shot.speed) end
	if ticks == 10 then
		local look = shot.state.look -- { x, y, z, distance }: centre the current camera there instead
		if look then
			local s = Spring.GetCameraState()
			s.px, s.py, s.pz = look[1], look[2], look[3]
			if s.dist then s.dist = look[4] end
			if s.height then s.height = look[4] end
			Spring.SetCameraState(s, 0)
		else
			Spring.SetCameraState(shot.state, 0)
		end
	end
	-- bench: ask for 10x sim speed during the lead-in and log what the engine achieves
	if shot.bench then
		if ticks == 12 then Spring.SendCommands("setmaxspeed 10", "setspeed 10") end
		if ticks % 60 == 0 then
			local user, actual = Spring.GetGameSpeed()
			Spring.Echo("replay bench", Spring.GetGameFrame(), "wanted", user, "actual", actual, "units", #Spring.GetAllUnits(),
				"lua mem (MB, allocs; rules, all)", Spring.GetLuaMemUsage())
		end
	end
	-- with a lead-in, shoot as soon as the player reaches the frame
	local reached = shot.speed or (Spring.GetGameRulesParam("replay_t") or 0) >= frame
	if ticks >= 400 and reached and not shot.taken then
		shot.taken = true
		Spring.SendCommands("screenshot png")
		shot.quit_at = ticks + 20
	end
	if shot.quit_at and ticks == shot.quit_at then Spring.SendCommands("quitforce") end
end
