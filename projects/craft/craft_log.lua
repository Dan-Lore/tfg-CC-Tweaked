-- Tiny scrolling log for a side monitor (default: left).
-- Mirrors to the computer terminal via print (always immediate).
-- Monitor redraw is NEVER done inside write() — workers/run paths only print.
-- Main thread calls flush() after waves so a 100x67 monitor cannot freeze craft.

local craft_log = {}

local state = {
    mon = nil,
    lines = {}, -- { text=, color= }
    maxLines = 50,
    w = 10,
    h = 5,
    t0 = 0,
    dirty = false,
    lastFlush = 0,
}

local COL = {
    white = colors.white,
    green = colors.green,
    yellow = colors.yellow,
    red = colors.red,
}

local function resolveColor(nameOrColor)
    if type(nameOrColor) == "number" then
        if nameOrColor == COL.white or nameOrColor == COL.green
            or nameOrColor == COL.yellow or nameOrColor == COL.red then
            return nameOrColor
        end
        return COL.white
    end
    if type(nameOrColor) == "string" then
        local c = COL[nameOrColor:lower()]
        if c then
            return c
        end
    end
    return nil
end

local function colorForMsg(msg)
    local m = tostring(msg or ""):lower()
    if m:find("fail", 1, true)
        or m:find("err", 1, true)
        or m:find("stall", 1, true)
        or m:find("timeout", 1, true)
        or m:find("stuck", 1, true)
        or m:find("missing", 1, true)
        or m:find("nosink", 1, true)
        or m:find("die ", 1, true)
        or m:find("run miss", 1, true)
        or m:find("need ", 1, true)
    then
        return COL.red
    end
    if m:sub(1, 4) == "wait"
        or m:sub(1, 4) == "skip"
        or m:sub(1, 4) == "noop"
        or m:find("planning", 1, true)
    then
        return COL.yellow
    end
    if m:sub(1, 3) == "ok "
        or m:sub(1, 4) == "out "
        or m:find("run ok", 1, true)
        or m:sub(1, 5) == "done "
        or m == "done"
        or m:find("machines ok", 1, true)
        or m:find("pizza ok", 1, true)
        or (m:sub(1, 4) == "clr " and m:find("+", 1, true))
    then
        return COL.green
    end
    return COL.white
end

local function redraw()
    local mon = state.mon
    if not mon then
        state.dirty = false
        return
    end
    local t0 = os.clock()
    local ok = pcall(function()
        mon.setBackgroundColor(colors.black)
        mon.clear()
        -- Cap rows drawn: huge advanced monitors (100x67) are too slow to full-repaint often.
        local maxRows = math.min(state.h, 40)
        local start = math.max(1, #state.lines - maxRows + 1)
        local row = 1
        for i = start, #state.lines do
            if (os.clock() - t0) > 0.25 then
                break -- never block craft longer than 250ms on paint
            end
            local entry = state.lines[i]
            local line = entry.text or ""
            if #line > state.w then
                line = line:sub(1, state.w)
            end
            mon.setCursorPos(1, row)
            mon.setTextColor(entry.color or COL.white)
            mon.write(line)
            row = row + 1
            if row > maxRows then
                break
            end
        end
    end)
    state.dirty = false
    state.lastFlush = os.clock()
    if not ok then
        state.mon = nil
    end
end

function craft_log.open(sideOrName, textScale)
    sideOrName = sideOrName or "left"
    local mon = peripheral.wrap(sideOrName)
    if not mon or not mon.clear then
        state.mon = nil
        print("craft_log: no monitor on " .. tostring(sideOrName))
        return false
    end
    pcall(function()
        mon.setTextScale(tonumber(textScale) or 0.5)
    end)
    local w, h = mon.getSize()
    state.mon = mon
    state.w = w
    state.h = h
    state.lines = {}
    state.maxLines = math.max(math.min(h, 40) * 3, 40)
    state.t0 = os.clock()
    state.dirty = false
    state.lastFlush = 0
    craft_log.write("log " .. tostring(w) .. "x" .. tostring(h))
    craft_log.flush(true)
    return true
end

--- Paint monitor. force=true bypasses rate limit (wave end / open).
function craft_log.flush(force)
    if not state.dirty and not force then
        return
    end
    if not force then
        local now = os.clock()
        if state.lastFlush and (now - state.lastFlush) < 0.4 then
            return
        end
    end
    redraw()
end

--- Append line + print. Does not paint the monitor (safe from worker coroutines).
function craft_log.write(msg, color)
    msg = tostring(msg or "")
    msg = msg:gsub("[\r\n]", " ")
    local dt = os.clock() - (state.t0 or os.clock())
    local stamped = string.format("%.1f %s", dt, msg)
    local col = resolveColor(color) or colorForMsg(msg)
    state.lines[#state.lines + 1] = { text = stamped, color = col }
    while #state.lines > state.maxLines do
        table.remove(state.lines, 1)
    end
    local old = nil
    if term and term.getTextColor and term.setTextColor then
        old = term.getTextColor()
        pcall(term.setTextColor, col)
    end
    print("[craft] " .. stamped)
    if old ~= nil then
        pcall(term.setTextColor, old)
    end
    state.dirty = true
end

function craft_log.step(label)
    craft_log.write(">" .. tostring(label))
end

function craft_log.msSince(t0)
    return math.floor((os.clock() - (t0 or 0)) * 1000 + 0.5)
end

craft_log.colors = COL

return craft_log
