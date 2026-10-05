function widget:GetInfo()
	return {
		name = "Replay Build Queues",
		desc = "BAR Rewind: every builder's queued buildings at the replay time, drawn as blueprints",
		author = "lucas",
		license = "GPL v2",
		layer = 56,
		enabled = true,
	}
end

-- Reads replay/queues + queue_items (written by `bake export-lua`) and draws them through BAR's
-- DrawUnitShapeGL4 API, as BAR's own Show Builder Queue does for live games.

local M = VFS.Include("replay/meta.lua")
local U32, F32 = VFS.UnpackU32, VFS.UnpackF32
local floor = math.floor
local OPACITY = 0.3
local REFRESH = 15 -- frames of replay time between rebuilds

local function section(name)
	local s = M.sections[name]
	local parts = {}
	for c = 0, (s and s.chunks or 0) - 1 do
		local z = VFS.LoadFile("replay/" .. name .. "_" .. c .. ".bin")
		parts[#parts + 1] = z and #z > 0 and VFS.ZlibDecompress(z) or ""
	end
	return table.concat(parts), s
end

-- per builder (unit record index): t, first item, item count, ... in time order
local plans = {}
local items, units

local function load()
	local q, qs = section("queues")
	if not qs then return false end
	for i = 0, qs.count - 1 do
		local v = U32(q, i * qs.size + 1, 4)
		local unit, t, first, count = v[1], v[2], v[3], v[4]
		local p = plans[unit]
		if not p then p = {}; plans[unit] = p end
		p[#p + 1], p[#p + 2], p[#p + 3] = t, first, count
	end
	items = { section("queue_items") }
	units = { section("units") }
	return true
end

local function item(i)
	local str, s = items[1], items[2]
	local pos = i * s.size + 1
	return U32(str, pos), F32(str, pos + 4), F32(str, pos + 8), F32(str, pos + 12)
end

local function unitTeam(index)
	return U32(units[1], index * units[2].size + 9)
end

local shapes = {} -- [item index] = shape handle
local last_refresh = nil

local function refresh(t)
	local want = {}
	for unit, p in pairs(plans) do
		-- the last record at or before t
		local k = nil
		for j = 1, #p, 3 do
			if p[j] <= t then k = j else break end
		end
		if k then
			for i = p[k + 1], p[k + 1] + p[k + 2] - 1 do want[i] = unit end
		end
	end
	for i, shape in pairs(shapes) do
		if not want[i] then
			WG.StopDrawUnitShapeGL4(shape)
			shapes[i] = nil
		end
	end
	for i, unit in pairs(want) do
		if not shapes[i] then
			local def, x, z, facing = item(i)
			local ud = UnitDefNames[M.defs[def] or ""]
			if ud then
				local y = math.max(Spring.GetGroundHeight(x, z), -(ud.waterline or 0))
				shapes[i] = WG.DrawUnitShapeGL4(ud.id, x, y - 0.01, z, facing * math.pi / 2, OPACITY, unitTeam(unit))
			end
		end
	end
end

function widget:Initialize()
	if not WG.DrawUnitShapeGL4 or not load() then widgetHandler:RemoveWidget() end
end

function widget:Update()
	local t = Spring.GetGameRulesParam("replay_t")
	if not t then return end
	if last_refresh and math.abs(t - last_refresh) < REFRESH then return end
	last_refresh = t
	refresh(t)
end

function widget:Shutdown()
	if not WG.StopDrawUnitShapeGL4 then return end
	for _, shape in pairs(shapes) do WG.StopDrawUnitShapeGL4(shape) end
	shapes = {}
end
