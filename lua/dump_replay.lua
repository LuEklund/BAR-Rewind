function widget:GetInfo()
	return {
		name = "Replay Dump v2",
		desc = "Dumps a replay to bardump.jsonl for bar-replay. Idle unless bardump.request exists.",
		author = "lucas",
		date = "2026-09-27",
		license = "GPL v2",
		layer = 0,
		enabled = true,
	}
end

-- Protocol: tools/pipeline.py writes bardump.request (first line = output path), launches the
-- replay; this widget dumps every SAMPLE_EVERY frames and quits the engine at GameOver.

local SAMPLE_EVERY = 3 -- sim is 30 Hz, so 10 Hz
local HEIGHT_STEP = 64
local REQUEST = "bardump.request"

local format, concat, abs = string.format, table.concat, math.abs
local S = Spring

local file = nil
local lastPiece = {} -- [unitID][piece] = last written matrix, only changes are written
local seenPieces = {} -- [defID] = true once its piece tree is written
local features = {} -- [featureID] = true

-- json -----------------------------------------------------------------------------------------

local function jstr(s)
	return '"' .. s:gsub('[%c"\\]', function(c) return format("\\u%04x", c:byte()) end) .. '"'
end

local function json(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "0" end
		if v == math.floor(v) and math.abs(v) < 2^53 then return format("%d", v) end
		return format("%.6g", v)
	elseif t == "string" then return jstr(v)
	elseif t == "boolean" then return tostring(v)
	elseif t ~= "table" or depth > 6 then return "null" end
	if #v > 0 then
		local out = {}
		for i = 1, #v do out[i] = json(v[i], depth + 1) end
		return "[" .. concat(out, ",") .. "]"
	end
	local out = {}
	local ok = pcall(function()
		for k, x in pairs(v) do
			local tx = type(x)
			if tx ~= "function" and tx ~= "userdata" then
				out[#out + 1] = jstr(tostring(k)) .. ":" .. json(x, depth + 1)
			end
		end
	end)
	if not ok then return "null" end
	return "{" .. concat(out, ",") .. "}"
end

local function line(key, value) file:write('{"', key, '":', json(value), "}\n") end

-- one-time headers -----------------------------------------------------------------------------

local function modelOf(def)
	local out = {}
	pcall(function() out.modelname = def.modelname end)
	local m = def.model
	if type(m) == "table" then
		pcall(function()
			for k, v in pairs(m) do
				local t = type(v)
				if t == "string" or t == "number" or t == "boolean" then out[k] = v end
			end
		end)
		local tex = m.textures or {}
		out.tex1 = tex.tex1
		out.tex2 = tex.tex2
	end
	return out
end

local function sunState()
	local out = {}
	local function grab(key, ...)
		local r = { pcall(...) }
		if r[1] then table.remove(r, 1); out[key] = r end
	end
	grab("pos", gl.GetSun, "pos")
	for _, mode in ipairs({ "ground", "unit" }) do
		for _, p in ipairs({ "ambient", "diffuse", "specular", "shadowDensity" }) do
			grab(mode .. "_" .. p, gl.GetSun, p, mode)
		end
	end
	for _, p in ipairs({ "fogStart", "fogEnd", "fogColor", "skyColor", "sunColor", "cloudColor", "skyAxisAngle" }) do
		grab(p, gl.GetAtmosphere, p)
	end
	for _, p in ipairs({ "splatTexScales", "splatTexMults", "voidWater", "voidGround", "splatDetailNormalDiffuseAlpha" }) do
		grab(p, gl.GetMapRendering, p)
	end
	for _, p in ipairs({ "absorb", "baseColor", "minColor", "surfaceColor", "surfaceAlpha", "diffuseColor", "specularColor",
		"planeColor", "ambientFactor", "diffuseFactor", "specularFactor", "specularPower", "fresnelMin", "fresnelMax",
		"fresnelPower", "reflectionDistortion", "blurBase", "blurExponent", "perlinStartFreq", "perlinLacunarity",
		"perlinAmplitude", "numTiles", "texture", "foamTexture", "normalTexture", "shoreWaves", "hasWaterPlane", "forceRendering" }) do
		grab("water_" .. p, gl.GetWaterRendering, p)
	end
	return out
end

local function writeHeaders()
	local mapinfo = nil
	pcall(function() mapinfo = VFS.Include("mapinfo.lua") end)
	line("map", {
		name = Game.mapName, file = Game.mapFileName, sizeX = Game.mapSizeX, sizeZ = Game.mapSizeZ,
		gravity = Game.gravity, waterLevel = 0, info = mapinfo, render = sunState(),
		game = Game.gameName, gameVersion = Game.gameVersion,
	})

	local rows = {}
	for z = 0, Game.mapSizeZ, HEIGHT_STEP do
		local row = {}
		for x = 0, Game.mapSizeX, HEIGHT_STEP do row[#row + 1] = format("%.1f", S.GetGroundHeight(x, z)) end
		rows[#rows + 1] = "[" .. concat(row, ",") .. "]"
	end
	file:write(format('{"terrain":{"sizeX":%d,"sizeZ":%d,"step":%d,"h":[%s]}}\n',
		Game.mapSizeX, Game.mapSizeZ, HEIGHT_STEP, concat(rows, ",")))

	local defs = {}
	for id, d in pairs(UnitDefs) do
		defs[tostring(id)] = { name = d.name, radius = d.radius, height = d.height, model = modelOf(d) }
	end
	line("defs", defs)

	local fdefs = {}
	for id, d in pairs(FeatureDefs) do
		fdefs[tostring(id)] = { name = d.name, radius = d.radius, height = d.height, model = modelOf(d),
			drawType = d.drawType, tree = d.customParams and d.customParams.treeshader }
	end
	line("fdefs", fdefs)

	local wdefs = {}
	for id, d in pairs(WeaponDefs) do
		local w = {}
		pcall(function()
			for k, v in d:pairs() do
				local t = type(v)
				if t == "number" or t == "string" or t == "boolean" then w[k] = v end
			end
		end)
		w.visuals = d.visuals
		wdefs[tostring(id)] = w
	end
	line("wdefs", wdefs)

	local teams = {}
	for _, id in ipairs(S.GetTeamList()) do
		local r, g, b = S.GetTeamColor(id)
		local _, leader, _, isAI, side, ally = S.GetTeamInfo(id)
		local name = leader and S.GetPlayerInfo(leader) or nil
		teams[tostring(id)] = { color = { r, g, b }, ally = ally, side = side, ai = isAI, leader = name }
	end
	line("teams", teams)
end

local function writePieces(u, def)
	seenPieces[def] = true
	local names = S.GetUnitPieceList(u) or {}
	local parents, offsets = {}, {}
	for i = 1, #names do
		local info = S.GetUnitPieceInfo(u, i) or {}
		parents[i] = info.parent or ""
		offsets[i] = info.offset or { 0, 0, 0 }
	end
	line("pieces", { def = def, names = names, parents = parents, offsets = offsets })
end

-- per-frame: binary, into bardump.bin ------------------------------------------------------------
-- Record: u32 frame, u32 counts {units, pieces, features added, features removed, projectiles,
-- terrain, queue floats}, then f32 rows: unit 23 (.., on/off, weapon target type + unit id or ground
-- xyz, worker cmd, worker target (unit id, or -(feature id + 1)), build power), piece 14 (unit,
-- piece, 12 matrix values), feature 8, removed 1, projectile 10 (id, def, team, xyz, velocity,
-- owner unit or -1), terrain 4 (heightmap x, z, new height, previous height), queues (builder,
-- team, n, then n x (def, x, z, facing)). Projectiles and terrain every frame, the rest every
-- SAMPLE_EVERY frames, queues every QUEUE_EVERY.
-- Recoil's Lua numbers are 32-bit floats, so f32 loses nothing.

local isBuilder = {}
for id, d in pairs(UnitDefs) do isBuilder[id] = d.isBuilder end

local UNIT_ROW, PIECE_ROW, FEATURE_ROW, PROJECTILE_ROW, TERRAIN_ROW = 23, 14, 8, 10, 4
local QUEUE_EVERY = 30

-- every piece whose model-space matrix moved since it was last written; returns the new row end
local function recordPieces(u, ps, np)
	local last = lastPiece[u]
	if not last then last = {}; lastPiece[u] = last end
	local n = #(S.GetUnitPieceList(u) or {})
	for p = 1, n do
		local m11, m21, m31, _, m12, m22, m32, _, m13, m23, m33, _, tx, ty, tz = S.GetUnitPieceMatrix(u, p)
		if m11 then
			local l = last[p]
			-- only real motion: rotation terms beyond 0.004, translation beyond 0.05 elmo
			if not l or abs(l[1] - m11) > 0.004 or abs(l[2] - m21) > 0.004 or abs(l[3] - m31) > 0.004
				or abs(l[4] - m12) > 0.004 or abs(l[5] - m22) > 0.004 or abs(l[6] - m32) > 0.004
				or abs(l[7] - m13) > 0.004 or abs(l[8] - m23) > 0.004 or abs(l[9] - m33) > 0.004
				or abs(l[10] - tx) > 0.05 or abs(l[11] - ty) > 0.05 or abs(l[12] - tz) > 0.05 then
				last[p] = { m11, m21, m31, m12, m22, m32, m13, m23, m33, tx, ty, tz }
				ps[np + 1], ps[np + 2] = u, p
				ps[np + 3], ps[np + 4], ps[np + 5], ps[np + 6] = m11, m21, m31, m12
				ps[np + 7], ps[np + 8], ps[np + 9], ps[np + 10] = m22, m32, m13, m23
				ps[np + 11], ps[np + 12], ps[np + 13], ps[np + 14] = m33, tx, ty, tz
				np = np + PIECE_ROW
			end
		end
	end
	return np
end

local function unitsSample(us, ps)
	local units = S.GetAllUnits()
	local alive = {}
	local nu, np = #us, #ps
	for i = 1, #units do
		local u = units[i]
		local x, y, z = S.GetUnitPosition(u)
		if x then
			alive[u] = true
			local def = S.GetUnitDefID(u) or 0
			local fx, fy, fz, _, _, _, ux, uy, uz = S.GetUnitDirection(u)
			local hp, maxHp, _, _, build = S.GetUnitHealth(u)
			local states = S.GetUnitStates(u)
			us[nu + 1], us[nu + 2], us[nu + 3] = u, def, S.GetUnitTeam(u) or 0
			us[nu + 4], us[nu + 5], us[nu + 6] = x, y, z
			us[nu + 7], us[nu + 8], us[nu + 9] = fx or 0, fy or 0, fz or 1
			us[nu + 10], us[nu + 11], us[nu + 12] = ux or 0, uy or 1, uz or 0
			us[nu + 13], us[nu + 14], us[nu + 15] = hp or 0, maxHp or 0, build or 1
			us[nu + 16] = (states and states.active == false) and 0 or 1
			-- what the first weapon aims at: 0 nothing, 1 unit (id), 2 ground (xyz), 3 projectile
			local tt, _, target = S.GetUnitWeaponTarget(u, 1)
			local ta, tb, tc = 0, 0, 0
			if tt == 1 or tt == 3 then
				ta = target or 0
			elseif tt == 2 and type(target) == "table" then
				ta, tb, tc = target[1] or 0, target[2] or 0, target[3] or 0
			end
			us[nu + 17], us[nu + 18], us[nu + 19], us[nu + 20] = tt or 0, ta, tb, tc
			-- what a builder works on (build, repair, reclaim, ...) and how hard: drives BAR's nano spray
			local wc, wt, bp = 0, 0, 0
			if isBuilder[def] then
				local cmd, id = S.GetUnitWorkerTask(u)
				bp = S.GetUnitCurrentBuildPower(u) or 0
				if cmd and id then
					wc, wt = cmd, id >= Game.maxUnits and -(id - Game.maxUnits + 1) or id
				end
			end
			us[nu + 21], us[nu + 22], us[nu + 23] = wc, wt, bp
			nu = nu + UNIT_ROW

			if not seenPieces[def] then writePieces(u, def) end
			-- every piece's motion: the player sets pieces from these curves, so turrets point right
			-- after a seek and walk cycles play in reverse
			np = recordPieces(u, ps, np)
		end
	end
	for u in pairs(lastPiece) do if not alive[u] then lastPiece[u] = nil end end
end

local function featuresSample(added, removed)
	local now = {}
	local all = S.GetAllFeatures()
	local n = 0
	for i = 1, #all do
		local f = all[i]
		now[f] = true
		if not features[f] then
			local x, y, z = S.GetFeaturePosition(f)
			local dx, dy, dz = S.GetFeatureDirection(f)
			added[n + 1], added[n + 2] = f, S.GetFeatureDefID(f) or 0
			added[n + 3], added[n + 4], added[n + 5] = x or 0, y or 0, z or 0
			added[n + 6], added[n + 7], added[n + 8] = dx or 0, dy or 0, dz or 1
			n = n + FEATURE_ROW
		end
	end
	for f in pairs(features) do if not now[f] then removed[#removed + 1] = f end end
	features = now
end

local function projectileRow(p, rows, n)
	local x, y, z = S.GetProjectilePosition(p)
	if not x then return n end
	local vx, vy, vz = S.GetProjectileVelocity(p)
	local weapon = S.GetProjectileType(p)
	rows[n + 1], rows[n + 2] = p, weapon and (S.GetProjectileDefID(p) or -1) or -2 -- -2 = piece debris
	rows[n + 3] = S.GetProjectileTeamID(p) or -1
	rows[n + 4], rows[n + 5], rows[n + 6] = x, y, z
	rows[n + 7], rows[n + 8], rows[n + 9] = vx or 0, vy or 0, vz or 0
	rows[n + 10] = S.GetProjectileOwnerID(p) or -1
	return n + PROJECTILE_ROW
end

local function projectilesSample(ps)
	local all = S.GetAllProjectiles and S.GetAllProjectiles(false, false)
		or S.GetProjectilesInRectangle(0, 0, Game.mapSizeX, Game.mapSizeZ, false, false)
	local n = 0
	for i = 1, #all do n = projectileRow(all[i], ps, n) end
end

-- terrain: heightmap points inside the rectangles the engine reports as changed, written when they
-- really moved, with the height they had before (the map's original height the first time)
local SQUARE = Game.squareSize
local dirty = {} -- flat x1, z1, x2, z2 lists
local heights = {} -- [z * (mapx + 1) + x] = last written height
local terrain_updates = 0

function widget:UnsyncedHeightMapUpdate(x1, z1, x2, z2)
	local n = #dirty
	dirty[n + 1], dirty[n + 2], dirty[n + 3], dirty[n + 4] = x1, z1, x2, z2
	terrain_updates = terrain_updates + 1
end

local function terrainSample(ts)
	local stride = Game.mapSizeX / SQUARE + 1
	local n = 0
	for r = 1, #dirty, 4 do
		for z = dirty[r + 1], dirty[r + 3] do
			for x = dirty[r], dirty[r + 2] do
				local key = z * stride + x
				local h = S.GetGroundHeight(x * SQUARE, z * SQUARE)
				local last = heights[key] or S.GetGroundOrigHeight(x * SQUARE, z * SQUARE)
				if abs(h - last) > 0.01 then
					heights[key] = h
					ts[n + 1], ts[n + 2], ts[n + 3], ts[n + 4] = x, z, h, last
					n = n + TERRAIN_ROW
				end
			end
		end
	end
	dirty = {}
end

-- what each builder plans to build: its queued build orders, written when they change
local lastQueue = {} -- [unitID] = string of the last written queue
local function queuesSample(qs)
	local units = S.GetAllUnits()
	local n = 0
	local alive = {}
	for i = 1, #units do
		local u = units[i]
		if isBuilder[S.GetUnitDefID(u) or 0] then
			alive[u] = true
			local cmds = S.GetUnitCommands(u, 200) or {}
			local items = {}
			for k = 1, #cmds do
				local c = cmds[k]
				if c.id < 0 and c.params[3] then
					items[#items + 1] = format("%d %d %d %d", -c.id, c.params[1], c.params[3], c.params[4] or 0)
				end
			end
			local key = concat(items, ",")
			if key ~= (lastQueue[u] or "") then
				lastQueue[u] = key
				qs[n + 1], qs[n + 2], qs[n + 3] = u, S.GetUnitTeam(u) or 0, #items
				n = n + 3
				for k = 1, #cmds do
					local c = cmds[k]
					if c.id < 0 and c.params[3] then
						qs[n + 1], qs[n + 2], qs[n + 3], qs[n + 4] = -c.id, c.params[1], c.params[3], c.params[4] or 0
						n = n + 4
					end
				end
			end
		end
	end
	for u in pairs(lastQueue) do if not alive[u] then lastQueue[u] = nil end end
end

local bin = nil

local function writeFrame(frame)
	local us, ps, fa, fr, pr, ts, qs = {}, {}, {}, {}, {}, {}, {}
	if frame % SAMPLE_EVERY == 0 then
		unitsSample(us, ps)
		featuresSample(fa, fr)
	end
	if frame % QUEUE_EVERY == 0 then queuesSample(qs) end
	projectilesSample(pr)
	terrainSample(ts)
	bin:write(VFS.PackU32(frame, #us / UNIT_ROW, #ps / PIECE_ROW, #fa / FEATURE_ROW, #fr, #pr / PROJECTILE_ROW,
		#ts / TERRAIN_ROW, #qs))
	for _, rows in ipairs({ us, ps, fa, fr, pr, ts, qs }) do
		if #rows > 0 then bin:write(VFS.PackF32(rows)) end
	end
end

-- lifecycle ------------------------------------------------------------------------------------

-- first line: "dump <last frame>"
-- or "shot <frame> <x> <z>" for a reference screenshot
local function readRequest()
	local f = io.open(REQUEST, "r")
	if not f then return nil end
	local line = f:read("*l") or ""
	f:close()
	local frame, x, z = line:match("^shot (%d+) ([%d%.]+) ([%d%.]+)")
	if frame then return { shot = tonumber(frame), x = tonumber(x), z = tonumber(z) } end
	-- io.open is sandboxed to the write dir; pipeline.py moves the files out
	return { path = "bardump.jsonl", last = tonumber(line:match("(%d+)$")) }
end

-- reference screenshot mode ---------------------------------------------------------------------

local shot = nil -- { frame, x, z, state = nil | "aimed" | draw frames counted }

local function shotFrame(frame)
	if frame < shot.shot or shot.state then return end
	S.SendCommands("pause 1", "hideinterface 1")
	local ok, state = pcall(VFS.Include, "barshot_camera_in.lua", nil, VFS.RAW)
	if ok and type(state) == "table" then
		S.SetCameraState(state, 0)
	else
		local y = S.GetGroundHeight(shot.x, shot.z)
		S.SetCameraTarget(shot.x, y, shot.z, 0)
	end
	shot.state = 0
end

function widget:Update()
	if not shot or not shot.state then return end
	shot.state = shot.state + 1
	if shot.state == 30 then
		S.SendCommands("screenshot png")
	elseif shot.state == 31 then
		local px, py, pz = S.GetCameraPosition()
		local dx, dy, dz = S.GetCameraDirection()
		local vfov = S.GetCameraFOV()
		local vx, vy = S.GetViewGeometry()
		local f = io.open("barshot_camera.json", "w")
		f:write(format('{"frame":%d,"pos":[%f,%f,%f],"dir":[%f,%f,%f],"vfov":%f,"size":[%d,%d],"state":%s}\n',
			S.GetGameFrame(), px, py, pz, dx, dy, dz, vfov, vx, vy, json(S.GetCameraState())))
		f:close()
	elseif shot.state == 60 then
		os.remove(REQUEST)
		S.SendCommands("quitforce")
	end
end

local function stop(quit)
	if bin then
		bin:close()
		bin = nil
	end
	if file then
		file:write('{"end":true}\n')
		file:close()
		file = nil
		S.Echo("Replay Dump v2: done")
	end
	if quit then
		os.remove(REQUEST)
		S.SendCommands("quitforce")
	end
end

local started = false
local last_frame = nil -- the replay's last keyframe: an unfinished replay never reaches GameOver
local path = nil

function widget:GameFrame(frame)
	if not started then
		started = true
		local request = S.IsReplay() and readRequest()
		if not request then
			widgetHandler:RemoveWidget()
			return
		end
		if request.shot then
			shot = request
			S.SendCommands("specfullview 1", "setminspeed 100", "setmaxspeed 100", "setspeed 100")
		else
			path = request.path
			last_frame = request.last
		end
	end
	if shot then
		shotFrame(frame)
		return
	end
	if not file and path then
		file = io.open(path, "w")
		bin = io.open("bardump.bin", "wb")
		-- file header: magic, format version, floats per unit row
		if bin then bin:write("BRDB", VFS.PackU32(3, UNIT_ROW)) end
		if not file or not bin then
			S.Echo("Replay Dump v2: cannot open " .. path)
			return
		end
		S.SendCommands("specfullview 1", "setminspeed 100", "setmaxspeed 100", "setspeed 100")
		writeHeaders()
		S.Echo("Replay Dump v2: recording to " .. path)
		path = nil
	end
	if frame % 300 == 0 then S.Echo("Replay Dump v2: frame " .. frame .. ", terrain updates " .. terrain_updates) end
	if last_frame and last_frame > 0 and frame > last_frame then return stop(true) end
	if not bin then return end
	writeFrame(frame)
end

-- the replay's pre-game lobby (start positions) plays in real time unless sped up before frame 0
function widget:Initialize()
	if S.IsReplay() and io.open(REQUEST, "r") then
		S.SendCommands("setminspeed 100", "setmaxspeed 100", "setspeed 100")
	end
end

function widget:GameOver()
	stop(true)
end

function widget:Shutdown()
	stop(false)
end
