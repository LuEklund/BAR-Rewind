function gadget:GetInfo()
	return {
		name = "Replay Player",
		desc = "Plays bar-rewind curves: every unit, piece and feature is placed from the curves at time t",
		author = "lucas",
		license = "GPL v2",
		layer = 0,
		enabled = true,
	}
end

-- Data: replay/meta.lua + replay/<section>_<chunk>.bin, written by `bake export-lua`, zlib-compressed.
-- Pieces are posed through the unit's own script (Turn/Move, instant) from the curves' pose keys:
-- Spring.SetUnitPieceMatrix only freezes a piece, it does not set it.
-- Recoil's Lua numbers are 32-bit floats, so records are addressed as (chunk, index in chunk);
-- no byte offset ever exceeds one chunk (8 MB).
--
-- Time: game rules param "replay_t" (sim frame of the replay, fractional). The timeline widget
-- sends "replay:<cmd>" messages: seek <frame>, play, pause, speed <x>.

if not gadgetHandler:IsSyncedCode() then
	-- synced Lua has no clock: synced reports each step of a frame here, and frames slower than
	-- SLOW_FRAME_MS are logged (infolog.txt / play.log) with where the time went and Lua memory
	local SLOW_FRAME_MS = 50
	local GetTimer, DiffTimers = Spring.GetTimer, Spring.DiffTimers
	local start, last, took = nil, nil, {}
	local function prof(_, step, t)
		local now = GetTimer()
		if step == "start" then start, last = now, now return end
		if not start then return end
		took[step], last = DiffTimers(now, last, true), now
		if step ~= "terrain" then return end
		local total = DiffTimers(now, start, true)
		if total > SLOW_FRAME_MS then
			Spring.Echo(string.format("Replay Player: slow frame t=%d %.0f ms (features %.0f, units %.0f, projectiles %.0f, terrain %.0f) lua %.0f MB",
				t, total, took.features, took.units, took.projectiles, took.terrain, (Spring.GetLuaMemUsage() or 0) / 1024))
		end
	end

	-- SpawnProjectile skips the weapon's fire sound: synced sends each live shot here to play it
	function gadget:Initialize()
		gadgetHandler:AddSyncAction("replay_prof", prof)
		gadgetHandler:AddSyncAction("replay_fire", function(_, weaponDefID, x, y, z)
			local sound = (WeaponDefs[weaponDefID].fireSound or {})[1]
			if sound then Spring.PlaySoundFile(sound.name, sound.volume or 1, x, y, z, "battle") end
		end)
	end
	return
end

local M = VFS.Include("replay/meta.lua")
local floor = math.floor
local U32, F32 = VFS.UnpackU32, VFS.UnpackF32
local CreateUnit, DestroyUnit = Spring.CreateUnit, Spring.DestroyUnit
local MoveCtrl = Spring.MoveCtrl
local SetUnitDirection, SetUnitHealth = Spring.SetUnitDirection, Spring.SetUnitHealth
local CallAsUnit = Spring.UnitScript.CallAsUnit
local Turn, Move = Spring.UnitScript.Turn, Spring.UnitScript.Move
local ALIVE_FOREVER = 4294967295

-- every data file is zlib-compressed; empty files stay empty
local function loadData(path)
	local z = VFS.LoadFile(path)
	if not z or #z == 0 then return "" end
	return VFS.ZlibDecompress(z)
end

-- binary sections -------------------------------------------------------------------------------

-- chunks load on first use
local data = {}
local function chunk(name, c)
	local chunks = data[name]
	if not chunks then chunks = {}; data[name] = chunks end
	local str = chunks[c]
	if not str then
		str = loadData("replay/" .. name .. "_" .. c .. ".bin")
		chunks[c] = str
	end
	return str
end

-- chunk string and 1-based byte position of record `index` (0-based) + `field` bytes
local function locate(name, index, field)
	local s = M.sections[name]
	local c = floor(index / s.per_chunk)
	local local_index = index - c * s.per_chunk
	return chunk(name, c), local_index * s.size + field + 1
end

local function u32(name, index, field)
	local str, pos = locate(name, index, field)
	return U32(str, pos)
end

-- Samplers write into caller-owned buffers and read single values: Recoil's synced Lua cannot
-- collect garbage fast enough for a fresh table per key at 30 frames a second.

-- per-curve cursor so sequential playback does no binary search
local cursors = {}

-- value of the curve (keys `first .. first+count-1` in section `name`) at frame t, into `out`
local function sample(name, first, count, n, t, out)
	if count == 0 then return nil end
	local str0, p0 = locate(name, first + 0, 0)
	if t <= U32(str0, p0) then
		for i = 1, n do out[i] = F32(str0, p0 + 4 * i) end
		return out
	end
	local strl, pl = locate(name, first + count - 1, 0)
	if t >= U32(strl, pl) then
		for i = 1, n do out[i] = F32(strl, pl + 4 * i) end
		return out
	end
	local by = cursors[name]
	if not by then by = {}; cursors[name] = by end
	local lo = by[first]
	if not (lo and lo < count - 1 and U32(locate(name, first + lo, 0)) <= t and t < U32(locate(name, first + lo + 1, 0))) then
		local a, b = 0, count - 1
		while b - a > 1 do
			local mid = floor((a + b) / 2)
			if U32(locate(name, first + mid, 0)) <= t then a = mid else b = mid end
		end
		lo = a
		by[first] = lo
	end
	local sa, pa = locate(name, first + lo, 0)
	local sb, pb = locate(name, first + lo + 1, 0)
	local ta, tb = U32(sa, pa), U32(sb, pb)
	local f = tb > ta and (t - ta) / (tb - ta) or 0
	for i = 1, n do
		local va = F32(sa, pa + 4 * i)
		out[i] = va + (F32(sb, pb + 4 * i) - va) * f
	end
	return out
end

-- windowed curves (transforms, statuses, pose_keys): one 30 s window of keys in memory ------------

local win = nil

local function loadWindow(w)
	if win and win.w == w then return end
	win = { w = w, first = {}, count = {}, chunks = {}, cursors = {} }
	for kind, info in pairs(M.windows) do
		if type(info) == "table" then
			local idx = loadData("replay/" .. kind .. "_w" .. w .. "_index.bin")
			local records = floor(#idx / 12)
			local f, c = {}, {}
			if records > 0 then
				local v = U32(idx, 1, records * 3)
				for i = 0, records - 1 do
					f[v[i * 3 + 1]] = v[i * 3 + 2]
					c[v[i * 3 + 1]] = v[i * 3 + 3]
				end
			end
			win.first[kind], win.count[kind], win.chunks[kind], win.cursors[kind] = f, c, {}, {}
		end
	end
end

-- key `index` (0-based, inside the current window) of `kind`: its chunk string and byte position
local function wkey(kind, index)
	local info = M.windows[kind]
	local c = floor(index / info.per_chunk)
	local chunks = win.chunks[kind]
	local str = chunks[c]
	if not str then
		str = loadData("replay/" .. kind .. "_w" .. win.w .. "_" .. c .. ".bin")
		chunks[c] = str
	end
	return str, (index - c * info.per_chunk) * info.size + 1
end

local function wt(kind, index)
	return U32(wkey(kind, index))
end

local function windowFor(t)
	local w = floor((t - M.first_frame) / M.windows.size)
	loadWindow(math.max(0, math.min(M.windows.count - 1, w)))
end

-- value of curve `curve` (unit record for transforms/statuses, track for pose_keys) at frame t,
-- into `out`
local function sampleW(kind, curve, n, t, out)
	windowFor(t)
	local first = win.first[kind][curve]
	if not first then return nil end
	local count = win.count[kind][curve]
	local lo
	if t <= wt(kind, first) then
		lo = 0
	elseif t >= wt(kind, first + count - 1) then
		lo = count - 1
	end
	if lo then
		local str, pos = wkey(kind, first + lo)
		for i = 1, n do out[i] = F32(str, pos + 4 * i) end
		return out
	end
	local cursors = win.cursors[kind]
	lo = cursors[curve]
	if not (lo and lo < count - 1 and wt(kind, first + lo) <= t and t < wt(kind, first + lo + 1)) then
		local a, b = 0, count - 1
		while b - a > 1 do
			local mid = floor((a + b) / 2)
			if wt(kind, first + mid) <= t then a = mid else b = mid end
		end
		lo = a
		cursors[curve] = lo
	end
	local sa, pa = wkey(kind, first + lo)
	local sb, pb = wkey(kind, first + lo + 1)
	local ta, tb = U32(sa, pa), U32(sb, pb)
	local f = tb > ta and (t - ta) / (tb - ta) or 0
	for i = 1, n do
		local va = F32(sa, pa + 4 * i)
		out[i] = va + (F32(sb, pb + 4 * i) - va) * f
	end
	return out
end

-- step curve (targets): the last key at or before t, no interpolation, into `out`
local function sampleStepW(kind, curve, n, t, out)
	windowFor(t)
	local first = win.first[kind][curve]
	if not first then return nil end
	local count = win.count[kind][curve]
	if t < wt(kind, first) then return nil end
	local a, b = 0, count
	while b - a > 1 do
		local mid = floor((a + b) / 2)
		if wt(kind, first + mid) <= t then a = mid else b = mid end
	end
	local str, pos = wkey(kind, first + a)
	for i = 1, n do out[i] = F32(str, pos + 4 * i) end
	return out
end

-- sample buffers, reused every frame
local TF, TF_PREV, ST, TG, TG_AHEAD, POSE, PK = {}, {}, {}, {}, {}, {}, {}
local AIM_LEAD = 15

-- records ---------------------------------------------------------------------------------------

local units, features, projectiles = {}, {}, {}
local byDied = {} -- projectiles sorted by death
local max_life = 0

local function loadRecords()
	for i = 0, M.sections.units.count - 1 do
		local u = {
			index = i,
			id = u32("units", i, 0), def = u32("units", i, 4), team = u32("units", i, 8),
			born = u32("units", i, 12), died = u32("units", i, 16),
			tf = u32("units", i, 20), tfn = u32("units", i, 24),
			st = u32("units", i, 28), stn = u32("units", i, 32),
			tr = u32("units", i, 44), trn = u32("units", i, 48),
			tracks = {},
		}
		local ud = UnitDefNames[M.defs[u.def] or ""]
		u.commander = ud and ud.customParams and ud.customParams.iscommander ~= nil
		for k = 0, u.trn - 1 do
			local ti = u.tr + k
			u.tracks[#u.tracks + 1] = { piece = u32("tracks", ti, 0), index = ti }
		end
		units[#units + 1] = u
	end
	for i = 0, M.sections.projectiles.count - 1 do
		local str, pos = locate("projectiles", i, 0)
		local def = U32(str, pos + 4)
		if def < 2147483648 then -- negative ids are piece debris; the engine makes its own
			local died = U32(str, pos + 16)
			local owner = U32(str, pos + 28)
			projectiles[#projectiles + 1] = {
				def = def, team = U32(str, pos + 8), born = U32(str, pos + 12),
				died = died == ALIVE_FOREVER and M.last_frame + 1 or died,
				first = U32(str, pos + 20), count = U32(str, pos + 24),
				owner = owner < 2147483648 and owner or nil,
			}
		end
	end
	table.sort(projectiles, function(a, b) return a.born < b.born end)
	for i = 1, #projectiles do
		local r = projectiles[i]
		byDied[i] = r
		max_life = math.max(max_life, r.died - r.born)
	end
	table.sort(byDied, function(a, b) return a.died < b.died end)
	for i = 0, M.sections.features.count - 1 do
		local str, pos = locate("features", i, 0)
		local f = F32(str, pos + 16, 6)
		features[#features + 1] = {
			id = U32(str, pos), def = U32(str, pos + 4), born = U32(str, pos + 8), died = U32(str, pos + 12),
			x = f[1], y = f[2], z = f[3], dx = f[4], dz = f[6],
		}
	end
end

local function alive(r, t)
	return r.born <= t and (r.died == ALIVE_FOREVER or t < r.died)
end

-- teams: replay team ids map onto the script's teams (pipeline.py's start script numbers them the same)
local gaia = Spring.GetGaiaTeamID()
local function teamOf(replayTeam)
	local info = M.teams[replayTeam]
	if not info or replayTeam >= gaia then return gaia end
	return replayTeam
end

-- playback --------------------------------------------------------------------------------------

local t = M.first_frame
local last_t = t
local shot = nil
local playing = true
local speed = 1

-- effects only play while watching forward at near real time; seeks and fast playback stay silent
local function watching()
	return playing and speed > 0 and speed <= 4 and t - last_t <= 8
end
local spawned = {} -- [record index] = unitID
local spawnedFeatures = {}

local animate

local warned = {}
local function warnOnce(msg)
	if not warned[msg] then warned[msg] = true; Spring.Echo("Replay Player: " .. msg) end
end

-- Legion's con turret mex is two recorded units: the turret, and an extractor BAR keeps invisible
local hiddenDefs = {}
for _, ud in pairs(UnitDefs) do
	local inner = ud.customParams and ud.customParams.attached_con_turret_mex
	if inner then hiddenDefs[inner] = true end
end

local function spawnUnit(i, r)
	local name = M.defs[r.def]
	if not name or not UnitDefNames[name] then return warnOnce("no unitdef " .. tostring(name)) end
	local v = sampleW("transforms", r.index, 7, t, TF)
	if not v then return nil end
	local u = CreateUnit(name, v[1], v[2], v[3], 0, teamOf(r.team))
	if not u then return warnOnce("CreateUnit failed: " .. name .. " team " .. r.team) end
	MoveCtrl.Enable(u)
	-- BAR's own script animates: weapons never fire
	for w = 1, #(UnitDefs[UnitDefNames[name].id].weapons or {}) do
		Spring.SetUnitWeaponState(u, w, "reloadState", 1e8)
	end
	Spring.SetUnitNoSelect(u, false)
	-- the engine asks a script for its nano pieces only when it really builds; replay builders
	-- never do, so BAR's nano spray would find no emitters
	if (UnitDefNames[name].buildSpeed or 0) > 0 then
		local nano = {}
		for piece, index in pairs(Spring.GetUnitPieceMap(u) or {}) do
			if piece:lower():find("nano") then nano[#nano + 1] = index end
		end
		if #nano > 0 then Spring.SetUnitNanoPieces(u, nano) end
	end
	Spring.GiveOrderToUnit(u, CMD.FIRE_STATE, { 0 }, 0)
	Spring.SetUnitAlwaysVisible(u, true)
	if hiddenDefs[name] then
		Spring.SetUnitNoDraw(u, true)
		Spring.SetUnitNoSelect(u, true)
		Spring.SetUnitNoMinimap(u, true)
		Spring.SetUnitIconDraw(u, false)
	end
	return u
end

-- model piece index -> unit script piece index (1-based, what Turn/Move take), per unit def
local script_pieces = {}
local function scriptPieces(u, def)
	local map = script_pieces[def]
	if not map then
		map = {}
		for sp, model in pairs(Spring.GetUnitScriptPiece(u) or {}) do map[model] = sp + 1 end
		script_pieces[def] = map
	end
	return map
end

-- runs inside the unit's script context (CallAsUnit): instant Turn/Move to the curve's pose
local pose_unit
local function applyPose()
	local r = pose_unit
	local map = scriptPieces(r.u, r.def)
	for k = 1, #r.tracks do
		local tr = r.tracks[k]
		local sp = map[tr.piece]
		local v = sp and sampleW("pose_keys", tr.index, 6, t, POSE)
		-- every frame: BAR's script runs too and would turn these pieces between keys
		if v then
			Turn(sp, 1, v[1]) Turn(sp, 2, v[2]) Turn(sp, 3, v[3])
			Move(sp, 1, v[4]) Move(sp, 2, v[5]) Move(sp, 3, v[6])
		end
	end
end

-- a unit script callin, COB or Lua. BAR's unit_script gadget adds Spring.UnitScript.GetScriptEnv
-- after this file loads, so it is looked up per call
local function GetScriptEnv(u)
	local get = Spring.UnitScript.GetScriptEnv
	return get and get(u)
end
local function callScript(u, name, ...)
	local env = GetScriptEnv(u)
	if env then
		local fn = env.script and env.script[name]
		if fn then CallAsUnit(u, fn, ...) end
	else
		-- units without a COB script (or a Lua one BAR does not track) have nothing to animate
		pcall(Spring.CallCOBScript, u, name, 0, ...)
	end
end

local live = {} -- replay unit id -> engine unit id, for targets
local liveFeatures = {} -- replay feature id -> engine feature id, for reclaim targets
-- the recorded target can miss a unit's shots: a shot fired with no target aims the unit along
-- the shot until this frame (engine unit id -> frame); a recorded target takes over at once
local shotUntil = {}
local SHOT_HOLD = 15

-- a builder's recorded work (task, target, build power) as unit rules params: BAR's nano spray
-- reads them through the Spring.GetUnitWorkerTask override in aaa_replay_worker_task.lua
local SetUnitRulesParam = Spring.SetUnitRulesParam
local PUBLIC = { public = true }

-- the engine calls StartBuilding(heading, pitch) when a builder starts work, and the script turns
-- the torso and arms towards the target; replay builders never really build, so it is called here
local function startBuilding(u, target)
	local x, y, z = Spring.GetUnitPosition(u)
	local tx, ty, tz
	if target >= Game.maxUnits then
		tx, ty, tz = Spring.GetFeaturePosition(target - Game.maxUnits)
	else
		tx, ty, tz = Spring.GetUnitPosition(target)
	end
	if not (x and tx) then return end
	local dx, dy, dz = tx - x, ty - y, tz - z
	local heading = math.atan2(dx, dz) - Spring.GetUnitHeading(u) * math.pi / 32768
	heading = (heading + math.pi) % (2 * math.pi) - math.pi
	local pitch = math.atan2(dy, math.sqrt(dx * dx + dz * dz))
	if GetScriptEnv(u) then
		callScript(u, "StartBuilding", heading, pitch)
	else
		-- COB angles: 65536 per turn
		pcall(Spring.CallCOBScript, u, "StartBuilding", 0, floor(heading * 32768 / math.pi), floor(pitch * 32768 / math.pi))
	end
end
local function work(u, r, g)
	local cmd, target, power = 0, 0, 0
	if g and g[5] ~= 0 and (playing or shot) then
		local id = g[6]
		if id > 0 then
			target = live[id] or 0
		elseif id < 0 then
			target = liveFeatures[-id - 1] and liveFeatures[-id - 1] + Game.maxUnits or 0
		end
		if target ~= 0 then cmd, power = g[5], g[7] end
	end
	if target ~= r.work_target then
		if target ~= 0 then
			startBuilding(u, target)
		elseif r.work_target and r.work_target ~= 0 then
			callScript(u, "StopBuilding")
		end
	end
	if cmd ~= r.work_cmd or target ~= r.work_target or power ~= r.work_power then
		r.work_cmd, r.work_target, r.work_power = cmd, target, power
		SetUnitRulesParam(u, "replay_work_cmd", cmd, PUBLIC)
		SetUnitRulesParam(u, "replay_work_target", target, PUBLIC)
		SetUnitRulesParam(u, "replay_work_power", power, PUBLIC)
	end
end

-- scripts animate from state, like PA: moving -> StartMoving (walk cycles), target -> weapons aim.
-- `posed` units have their aim pieces recorded: they get no target, the curves aim them
animate = function(u, r, v, posed)
	-- velocity from one frame back, inside the current window only: sampling t - 1 across a window
	-- boundary would swap windows once per unit. On the boundary frame the last motion carries on.
	local window_start = M.first_frame + win.w * M.windows.size
	local prev = t - 1 >= window_start and sampleW("transforms", r.index, 7, t - 1, TF_PREV)
	local moving = r.moving
	if prev then
		local vx, vy, vz = v[1] - prev[1], v[2] - prev[2], v[3] - prev[3]
		MoveCtrl.SetVelocity(u, vx, vy, vz)
		moving = vx * vx + vz * vz > 0.01
	end
	if moving ~= r.moving then
		r.moving = moving
		callScript(u, moving and "StartMoving" or "StopMoving", 0)
	end
	local g = sampleStepW("targets", r.index, 7, t, TG)
	work(u, r, g)
	if posed then return end
	-- scripts need time to turn towards a target: aim at the one recorded AIM_LEAD frames ahead (in
	-- playback direction), staying inside the loaded window
	local window_last = window_start + M.windows.size - 1
	local ahead = math.max(window_start, math.min(window_last, t + AIM_LEAD * speed))
	local a = sampleStepW("targets", r.index, 7, ahead, TG_AHEAD)
	if a and a[1] ~= 0 then g = a end
	-- the target in numbers (no strings: no garbage): type, unit id or ground cell
	local tt = g and g[1] or 0
	local ta = tt == 1 and g[2] or tt == 2 and floor(g[2] / 16) or 0
	local tb = tt == 2 and floor(g[4] / 16) or 0
	local held = shotUntil[u]
	if held and (tt ~= 0 or t >= held or t < held - SHOT_HOLD) then
		shotUntil[u], r.target_type = nil, nil
	end
	if not shotUntil[u] and (tt ~= r.target_type or ta ~= r.target_a or tb ~= r.target_b) then
		r.target_type, r.target_a, r.target_b = tt, ta, tb
		if g and g[1] == 1 and live[g[2]] then
			Spring.SetUnitTarget(u, live[g[2]], false, true)
		elseif g and g[1] == 2 then
			Spring.SetUnitTarget(u, g[2], g[3], g[4], false, true)
		else
			Spring.SetUnitTarget(u, nil)
		end
	end
end

local SPAWN_FRAME, WARP_IN_FRAME = Game.spawnInitialFrame or 0, Game.spawnWarpInFrame or 0

-- the start commanders' warp-in effect, as BAR's game_initial_spawn plays it
local function spawnEffects()
	if not (watching() and last_t < SPAWN_FRAME and t >= SPAWN_FRAME) then return end
	for i = 1, #units do
		local r = units[i]
		if r.commander and alive(r, t) and r.born <= SPAWN_FRAME then
			local v = sampleW("transforms", r.index, 7, t, TF)
			if v then
				Spring.SpawnCEG("commander-spawn", v[1], v[2], v[3], 0, 0, 0)
				if GG.SpawnEnvironmentalLightning then GG.SpawnEnvironmentalLightning("commanderspawn", v[1], v[2], v[3]) end
			end
		end
	end
end

local function place(u, r)
	local v = sampleW("transforms", r.index, 7, t, TF)
	if not v then return end
	MoveCtrl.SetPosition(u, v[1], v[2], v[3])
	-- rotation quaternion (lerped keys, the exporter keeps neighbours on the short way round):
	-- front and up are its rotation's 3rd and 2nd columns; right = front x up
	local x, y, z, w = v[4], v[5], v[6], v[7]
	local n = x * x + y * y + z * z + w * w
	if n > 0 then
		n = 1 / math.sqrt(n)
		x, y, z, w = x * n, y * n, z * n, w * n
	else
		x, y, z, w = 0, 0, 0, 1
	end
	local fx, fy, fz = 2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)
	local ux, uy, uz = 2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w)
	SetUnitDirection(u, fx, fy, fz, fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux)
	local s = sampleW("statuses", r.index, 4, t, ST)
	if s then
		SetUnitHealth(u, { health = math.max(s[1], 1), build = s[3] })
		local on = s[4] >= 0.5 and 1 or 0
		if r.on ~= on then
			r.on = on
			Spring.GiveOrderToUnit(u, CMD.ONOFF, { on }, 0)
		end
	end
	-- BAR keeps the start commanders hidden until they warp in (game_initial_spawn)
	if r.commander then
		local hidden = t < WARP_IN_FRAME
		if hidden ~= r.hidden then
			r.hidden = hidden
			Spring.SetUnitNoDraw(u, hidden)
		end
	end
	r.u = u
	-- recorded aim pieces: set straight from the curves (right after a seek and in reverse);
	-- BAR's script animates everything else
	local posed = #r.tracks > 0
	if posed then
		pose_unit = r
		CallAsUnit(u, applyPose)
	end
	animate(u, r, v, posed)
end

local function syncUnits()
	-- removals first: after a seek, a building that stood on a spot later must be gone before the
	-- one standing there at t spawns, or the spawn is blocked
	for i = 1, #units do
		local r = units[i]
		local u = spawned[i]
		if u and not alive(r, t) then
			if Spring.ValidUnitID(u) then
				-- died just now while watching: the engine's death explosion; otherwise vanish quietly
				local died_now = watching() and r.died > last_t and r.died <= t
				DestroyUnit(u, false, not died_now)
			end
			spawned[i] = nil
			if live[r.id] == u then live[r.id] = nil end
		end
	end
	for i = 1, #units do
		local r = units[i]
		if alive(r, t) then
			local u = spawned[i]
			if not u or not Spring.ValidUnitID(u) then
				u = spawnUnit(i, r)
				spawned[i] = u
				if u then live[r.id] = u end
				r.on, r.moving, r.target_type, r.hidden = nil, nil, nil, nil
				r.work_cmd, r.work_target, r.work_power = nil, nil, nil
			end
			if u then place(u, r) end
		end
	end
end

-- projectiles are recorded like units, every frame: each one alive at t is placed on its curve, at
-- any speed and in both directions. Playing forward, it is released for its last frames and the
-- engine flies it into what it hit, with BAR's own impact effect; otherwise it vanishes quietly.
-- Shots shorter than that (beams) are only fired when playback passes their birth going forward.
local RELEASE = 3
local SetProjectileTimeToLive = Spring.SetProjectileTimeToLive
local flying = {} -- [record] = engine projectile id, or false once the engine destroyed it early

local function steerEnd(r) return r.died - RELEASE end

local function spawnProjectile(r, release)
	local name = M.wdefs[r.def]
	local wd = name and WeaponDefNames[name]
	if not wd then return warnOnce("no weapondef " .. tostring(name)) end
	local v = sample("projectile_keys", r.first, r.count, 6, t, PK)
	local params = {
		pos = { v[1], v[2], v[3] },
		speed = { v[4], v[5], v[6] },
		team = teamOf(r.team),
		owner = r.owner and live[r.owner] or nil,
		ttl = math.max(1, r.died - t),
	}
	-- SpawnProjectile does not apply weapon gravity by itself
	if wd.gravityAffected or wd.type == "AircraftBomb" or wd.type == "Cannon" then
		params.gravity = -((wd.myGravity or 0) > 0 and wd.myGravity or Game.gravity / 900)
	end
	if wd.type == "BeamLaser" or wd.type == "LightningCannon" then
		params["end"] = { v[1] + v[4], v[2] + v[5], v[3] + v[6] }
	end
	local owner = params.owner
	if owner and r.born == t and (shotUntil[owner] or Spring.GetUnitWeaponTarget(owner, 1) == 0) then
		local len = math.sqrt(v[4] * v[4] + v[5] * v[5] + v[6] * v[6])
		if len > 0 then
			local k = 200 / len
			Spring.SetUnitTarget(owner, v[1] + v[4] * k, v[2] + v[5] * k, v[3] + v[6] * k, false, true)
			shotUntil[owner] = t + SHOT_HOLD
		end
	end
	local id = Spring.SpawnProjectile(wd.id, params)
	if not id then return nil end
	-- the curves own the terrain: impacts leave no engine craters
	Spring.SetProjectileDamages(id, 0, { craterMult = 0, craterBoost = 0 })
	if watching() and r.born > last_t then SendToUnsynced("replay_fire", wd.id, v[1], v[2], v[3]) end
	if not release then return id end
end

local function steerable(r) return r.born <= t and t <= steerEnd(r) end

local function track(r)
	if flying[r] == nil and steerable(r) then flying[r] = spawnProjectile(r) or false end
end

-- first index in `list` (sorted by `key`) whose key is > x
local function upper(list, key, x)
	local a, b = 1, #list + 1
	while a < b do
		local mid = floor((a + b) / 2)
		if list[mid][key] <= x then a = mid + 1 else b = mid end
	end
	return a
end

-- first index in `list` whose key is >= x
local function lower(list, key, x)
	local a, b = 1, #list + 1
	while a < b do
		local mid = floor((a + b) / 2)
		if list[mid][key] < x then a = mid + 1 else b = mid end
	end
	return a
end

local function syncProjectiles()
	local dt = t - last_t
	if math.abs(dt) > 64 then
		-- a seek: everything alive at t was born in the last max_life frames
		for r, id in pairs(flying) do
			if id then Spring.DeleteProjectile(id) end
			flying[r] = nil
		end
		for i = upper(projectiles, "born", t - max_life - 1), upper(projectiles, "born", t) - 1 do track(projectiles[i]) end
	elseif dt > 0 then
		for i = upper(projectiles, "born", last_t), upper(projectiles, "born", t) - 1 do
			local r = projectiles[i]
			if steerable(r) then
				track(r)
			elseif watching() and r.died > t then
				spawnProjectile(r, true) -- a beam or a shot about to land: fire and forget
			end
		end
	elseif dt < 0 then
		-- going back, a projectile enters its life span at its last steered frame
		for i = lower(byDied, "died", t + RELEASE), lower(byDied, "died", last_t + RELEASE) - 1 do track(byDied[i]) end
	end
	for r, id in pairs(flying) do
		if not steerable(r) then
			-- passing its last frames forward: the engine takes over
			if id and not (dt > 0 and t > steerEnd(r) and t < r.died) then Spring.DeleteProjectile(id) end
			flying[r] = nil
		elseif id then
			if Spring.GetProjectilePosition(id) then
				local v = sample("projectile_keys", r.first, r.count, 6, t, PK)
				Spring.SetProjectilePosition(id, v[1], v[2], v[3])
				Spring.SetProjectileVelocity(id, v[4], v[5], v[6])
				-- the engine's lifetime counts down in sim frames, whichever way the replay plays
				SetProjectileTimeToLive(id, r.died - t + RELEASE)
			else
				flying[r] = false -- hit something early: stays gone until it leaves its life span
			end
		end
	end
end

-- terrain: heightmap points changed by the replay's explosions. `applied` events are in the map.
-- They are applied RELEASE frames late, after the engine's own impact (if any) went off.
local terrain_count = M.sections.terrain and M.sections.terrain.count or 0
local applied = 0
local SQUARE = Game.squareSize
local SetHeightMap = Spring.SetHeightMap
local terrain_from, terrain_to

local function terrainKey(i)
	return locate("terrain", i, 0)
end

local function applyTerrain()
	if terrain_from < terrain_to then
		for i = terrain_from, terrain_to - 1 do
			local str, pos = terrainKey(i)
			local xz = U32(str, pos + 4)
			SetHeightMap((xz % 65536) * SQUARE, floor(xz / 65536) * SQUARE, F32(str, pos + 8))
		end
	else
		for i = terrain_from - 1, terrain_to, -1 do
			local str, pos = terrainKey(i)
			local xz = U32(str, pos + 4)
			SetHeightMap((xz % 65536) * SQUARE, floor(xz / 65536) * SQUARE, F32(str, pos + 12))
		end
	end
end

local function syncTerrain()
	local now = t - RELEASE
	local target = applied
	while target < terrain_count and U32(terrainKey(target)) <= now do target = target + 1 end
	while target > 0 and U32(terrainKey(target - 1)) > now do target = target - 1 end
	if target == applied then return end
	terrain_from, terrain_to = applied, target
	Spring.SetHeightMapFunc(applyTerrain)
	applied = target
end

local tombstones = {}
for _, ud in pairs(UnitDefs) do
	local stone = ud.customParams and ud.customParams.tombstone
	if stone then tombstones[stone] = true end
end

-- the curves own features: only the player creates them, engine-made wrecks are refused
local creating_feature = false

local function syncFeatures()
	-- removals first, as for units
	for i = 1, #features do
		local r = features[i]
		local f = spawnedFeatures[i]
		if f and not alive(r, t) then
			if Spring.ValidFeatureID(f) then Spring.DestroyFeature(f) end
			spawnedFeatures[i] = nil
			if liveFeatures[r.id] == f then liveFeatures[r.id] = nil end
		end
	end
	for i = 1, #features do
		local r = features[i]
		local f = spawnedFeatures[i]
		if alive(r, t) and (not f or not Spring.ValidFeatureID(f)) then
			local name = M.fdefs[r.def]
			if tombstones[name] then
				-- no RIP signs where commanders fell
			elseif name and FeatureDefNames[name] then
				local heading = floor(math.atan2(r.dx, r.dz) * 32768 / math.pi) % 65536
				creating_feature = true
				spawnedFeatures[i] = Spring.CreateFeature(name, r.x, r.y, r.z, heading, gaia)
				liveFeatures[r.id] = spawnedFeatures[i]
				creating_feature = false
			else
				warnOnce("no featuredef " .. tostring(name))
			end
		end
	end
end

function gadget:Initialize()
	loadRecords()
	if VFS.FileExists("replay/shot.lua") then
		shot = VFS.Include("replay/shot.lua")
		-- play in from `lead` frames before so effects are in flight when the frame is shot
		t = shot.frame - (shot.lead or 0)
		last_t = t
		playing = (shot.lead or 0) > 0
	end
	for id, team in pairs(M.teams) do
		if team.leader and team.leader ~= "" and id < gaia then Spring.SetGameRulesParam("ainame_" .. id, team.leader) end
	end
	Spring.SetGameRulesParam("replay_first", M.first_frame)
	Spring.SetGameRulesParam("replay_last", M.last_frame)
	Spring.Echo("Replay Player: " .. #units .. " units, " .. #features .. " features, frames " .. M.first_frame .. ".." .. M.last_frame)
end


-- unsynced times the steps of each frame (it has the clock) and logs slow ones
local function prof(step) SendToUnsynced("replay_prof", step, t) end

local started = false
function gadget:GameFrame(frame)
	if not started then
		started = true
		-- the map spawned its own features; the curves own them from now on
		for _, f in ipairs(Spring.GetAllFeatures()) do Spring.DestroyFeature(f) end
		for _, ally in ipairs(Spring.GetAllyTeamList()) do Spring.SetGlobalLos(ally, true) end
	end
	-- shots keep playing a second past their frame: pausing clears projectiles in flight
	if shot and t >= shot.frame + 30 then playing = false end
	if playing then
		t = t + speed
		if t >= M.last_frame then t = M.last_frame; playing = false end
		if t <= M.first_frame then t = M.first_frame; playing = false end
	end
	prof("start")
	syncFeatures()
	prof("features")
	syncUnits()
	spawnEffects()
	prof("units")
	syncProjectiles()
	prof("projectiles")
	syncTerrain()
	prof("terrain")
	last_t = t
	Spring.SetGameRulesParam("replay_t", t)
	Spring.SetGameRulesParam("replay_playing", playing and 1 or 0)
	Spring.SetGameRulesParam("replay_speed", speed)
end

function gadget:RecvLuaMsg(msg, player)
	if msg:sub(1, 7) ~= "replay:" then return end
	local cmd, arg = msg:match("^replay:(%a+)%s*(%S*)")
	if cmd == "seek" then
		t = math.max(M.first_frame, math.min(M.last_frame, tonumber(arg) or t))
	elseif cmd == "play" then
		playing = true
	elseif cmd == "pause" then
		playing = false
	elseif cmd == "speed" then
		speed = tonumber(arg) or speed
		playing = true
	end
	return true
end

-- the curves own health and features: engine damage and engine-made wrecks are visual only
function gadget:UnitPreDamaged() return 0, 0 end
function gadget:FeaturePreDamaged() return 0, 0 end

function gadget:AllowFeatureCreation()
	return creating_feature
end

