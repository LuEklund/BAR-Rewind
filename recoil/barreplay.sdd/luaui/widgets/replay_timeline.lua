function widget:GetInfo()
	return {
		name = "Replay Timeline",
		desc = "Scrub bar for BAR Replay: drag to seek, << / >> buttons rewind and fast-forward (click again: 2x faster), Space play/pause, R reverse, Left/Right 10 s, Up/Down speed",
		author = "lucas",
		license = "GPL v2",
		layer = 10000,
		enabled = true,
		handler = true,
	}
end

-- The Replay Player gadget owns time; this widget only reads it and sends replay:<cmd> messages.

local GetParam = Spring.GetGameRulesParam
local Send = Spring.SendLuaRulesMsg
local KEY_SPACE, KEY_R = 32, 114
local KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN = 276, 275, 273, 274

local height = 36
local dragging = false

-- under BAR's top bar, clear of the minimap (left) and the menu buttons (right)
-- the panel starts with the buttons and the speed label, then the track
local BUTTON, GAP, LABEL = 34, 6, 90
local function bar()
	local vsx, vsy = Spring.GetViewGeometry()
	local y2 = vsy - vsy * 0.075
	return vsx * 0.34 + 3 * (BUTTON + GAP) + LABEL, y2 - height, vsx * 0.82, y2
end

local function state()
	return GetParam("replay_t") or 0, GetParam("replay_first") or 0, GetParam("replay_last") or 1,
		(GetParam("replay_playing") or 0) == 1, GetParam("replay_speed") or 1
end

local function clock(frame)
	local s = math.floor(frame / 30)
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- buttons left of the bar: reverse/rewind faster, play/pause, forward faster
local function buttons()
	local x1, y1, _, y2 = bar()
	local left = x1 - LABEL - 3 * (BUTTON + GAP)
	local list = {}
	for i = 1, 3 do
		local bx = left + (i - 1) * (BUTTON + GAP)
		list[i] = { bx, y1 + 4, bx + BUTTON, y2 - 4 }
	end
	return list
end

local MAX_SPEED = 64
-- << : reverse at 1x, or reverse twice as fast; >> : the same forward
local function faster(direction)
	local _, _, _, playing, speed = state()
	if not playing or (speed > 0) ~= (direction > 0) then
		Send("replay:speed " .. direction)
	else
		Send("replay:speed " .. math.min(math.abs(speed) * 2, MAX_SPEED) * direction)
	end
end

local function press(i)
	local _, _, _, playing = state()
	if i == 1 then
		faster(-1)
	elseif i == 2 then
		Send(playing and "replay:pause" or "replay:play")
	else
		faster(1)
	end
end

local function seekTo(mx)
	local x1, _, x2 = bar()
	local _, first, last = state()
	local f = math.max(0, math.min(1, (mx - x1) / (x2 - x1)))
	Send("replay:seek " .. math.floor(first + f * (last - first)))
end

function widget:DrawScreen()
	local t, first, last, playing, speed = state()
	local x1, y1, x2, y2 = bar()
	local b = buttons()
	gl.Color(0, 0, 0, 0.6)
	gl.Rect(b[1][1] - 10, y1 - 6, x2 + 120, y2 + 6)
	local labels = { "<<", playing and "||" or ">", ">>" }
	for i = 1, 3 do
		local r = b[i]
		local active = playing and ((i == 1 and speed < 0) or (i == 3 and speed > 0))
		if active then gl.Color(0.3, 0.6, 1, 0.9) else gl.Color(0.25, 0.25, 0.28, 1) end
		gl.Rect(r[1], r[2], r[3], r[4])
		gl.Color(1, 1, 1, 1)
		gl.Text(labels[i], (r[1] + r[3]) / 2, r[2] + 7, 16, "oc")
	end
	gl.Color(0.25, 0.25, 0.28, 1)
	gl.Rect(x1, y1 + 12, x2, y2 - 12)
	local f = (t - first) / math.max(last - first, 1)
	gl.Color(0.3, 0.6, 1, 1)
	gl.Rect(x1, y1 + 12, x1 + (x2 - x1) * f, y2 - 12)
	gl.Color(1, 1, 1, 1)
	local knob = x1 + (x2 - x1) * f
	gl.Rect(knob - 3, y1 + 4, knob + 3, y2 - 4)
	local mode = playing and ((speed < 0 and "-" or "+") .. math.abs(speed) .. "x") or "paused"
	gl.Text(mode, x1 - LABEL + 4, y1 + 11, 16, "o")
	gl.Text(clock(t) .. " / " .. clock(last), x2 + 14, y1 + 11, 16, "o")
end

function widget:IsAbove(mx, my)
	local _, y1, _, y2 = bar()
	return my >= y1 - 6 and my <= y2 + 6
end

function widget:MousePress(mx, my, button)
	local x1, y1, x2, y2 = bar()
	if button == 1 then
		for i, r in ipairs(buttons()) do
			if mx >= r[1] and mx <= r[3] and my >= r[2] and my <= r[4] then
				press(i)
				return true
			end
		end
	end
	if button == 1 and mx >= x1 and mx <= x2 and my >= y1 and my <= y2 then
		dragging = true
		seekTo(mx)
		return true
	end
	return false
end

function widget:MouseMove(mx, my)
	if dragging then seekTo(mx) end
end

function widget:MouseRelease()
	dragging = false
	return false
end

function widget:KeyPress(key)
	local t, _, _, playing, speed = state()
	if key == KEY_SPACE then
		Send(playing and "replay:pause" or "replay:play")
	elseif key == KEY_R then
		Send("replay:speed " .. -speed)
	elseif key == KEY_LEFT then
		Send("replay:seek " .. (t - 300))
	elseif key == KEY_RIGHT then
		Send("replay:seek " .. (t + 300))
	elseif key == KEY_UP then
		Send("replay:speed " .. math.min(math.abs(speed) * 2, MAX_SPEED) * (speed < 0 and -1 or 1))
	elseif key == KEY_DOWN then
		Send("replay:speed " .. math.max(math.abs(speed) / 2, 0.25) * (speed < 0 and -1 or 1))
	else
		return false
	end
	return true
end
