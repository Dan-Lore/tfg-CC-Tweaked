-- Tiny scrolling log for a side monitor (default: left).
-- Also mirrors to the computer terminal via print.

local craft_log = {}

local state = {
    mon = nil,
    lines = {},
    maxLines = 50,
    w = 10,
    h = 5,
}

local function redraw()
    local mon = state.mon
    if not mon then
        return
    end
    local ok = pcall(function()
        mon.setBackgroundColor(colors.black)
        mon.clear()
        mon.setTextColor(colors.lime)
        local start = math.max(1, #state.lines - state.h + 1)
        local row = 1
        for i = start, #state.lines do
            local line = state.lines[i]
            if #line > state.w then
                line = line:sub(1, state.w)
            end
            mon.setCursorPos(1, row)
            mon.write(line)
            row = row + 1
            if row > state.h then
                break
            end
        end
    end)
    if not ok then
        state.mon = nil
    end
end

--- Bind log monitor. sideOrName e.g. "left" or peripheral name. Optional textScale.
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
    state.maxLines = math.max(h * 4, 40)
    craft_log.write("log " .. tostring(w) .. "x" .. tostring(h))
    return true
end

function craft_log.write(msg)
    msg = tostring(msg or "")
    -- Strip newlines for one-line log rows.
    msg = msg:gsub("[\r\n]", " ")
    state.lines[#state.lines + 1] = msg
    while #state.lines > state.maxLines do
        table.remove(state.lines, 1)
    end
    print("[craft] " .. msg)
    redraw()
    -- Yield so the log monitor paints and CC budget resets.
    sleep(0)
end

function craft_log.step(label)
    craft_log.write(">" .. tostring(label))
end

return craft_log
