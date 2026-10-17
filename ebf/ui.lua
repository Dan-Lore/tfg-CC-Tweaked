-- 2-high × 1-wide monitor UI for EBF feeder (ASCII, text scale 0.5).

local ui = {}

local function clip(text, maxLen)
    text = tostring(text or "")
    if maxLen <= 0 or #text <= maxLen then
        return text
    end
    if maxLen <= 1 then
        return "."
    end
    return text:sub(1, maxLen - 1) .. "."
end

local function writeAt(mon, x, y, text, color, maxW)
    mon.setCursorPos(x, y)
    if color and colors then
        mon.setTextColor(color)
    elseif colors then
        mon.setTextColor(colors.white)
    end
    mon.write(clip(text, maxW or 99))
end

local function loadColor(name, fallback)
    if colors and colors[name] ~= nil then
        return colors[name]
    end
    return fallback
end

function ui.boot(mon, msg)
    if not mon then
        return
    end
    if mon.setTextScale then
        mon.setTextScale(0.5)
    end
    mon.clear()
    local w = select(1, mon.getSize())
    writeAt(mon, 1, 1, "EBF FEED", loadColor("cyan", 1), w)
    writeAt(mon, 1, 3, msg or "boot...", loadColor("yellow", 1), w)
end

--- state: furnaces (sorted), buffers, status, fedTotal, drainedTotal, queueLabel
function ui.draw(mon, state)
    if not mon then
        return
    end
    state = state or {}
    if mon.setTextScale then
        mon.setTextScale(0.5)
    end
    local w, h = mon.getSize()
    if not w or w < 1 then
        w = 15
    end
    if not h or h < 1 then
        h = 10
    end
    mon.clear()

    local white = loadColor("white", 1)
    local lime = loadColor("lime", 1)
    local yellow = loadColor("yellow", 1)
    local gray = loadColor("gray", 1)
    local orange = loadColor("orange", 1)
    local lightBlue = loadColor("lightBlue", 1)

    local furnaces = state.furnaces or {}
    local bufN = tonumber(state.bufferCount) or 0
    local maxInf = tonumber(state.maxInflight) or 6

    writeAt(mon, 1, 1, clip("EBF  q:" .. tostring(bufN), w), lightBlue, w)

    local idle = 0
    local room = 0
    for i = 1, #furnaces do
        local inf = furnaces[i].inflight or 0
        if inf == 0 then
            idle = idle + 1
        end
        if inf < maxInf then
            room = room + 1
        end
    end
    -- Each hatch pack feeds 2 paired EBFs.
    writeAt(
        mon,
        1,
        2,
        clip(string.format("p:%d idle:%d", #furnaces, idle), w),
        white,
        w
    )

    local y = 3
    local status = state.status or ""
    if status ~= "" then
        writeAt(mon, 1, y, clip(status, w), yellow, w)
        y = y + 1
    end

    local recipe = state.queueLabel
    if recipe and recipe ~= "" and recipe ~= "-" then
        writeAt(mon, 1, y, clip(">" .. recipe, w), lime, w)
        y = y + 1
    end

    writeAt(
        mon,
        1,
        y,
        clip(string.format("in:%d out:%d", state.fedTotal or 0, state.drainedTotal or 0), w),
        gray,
        w
    )
    y = y + 1

    -- Per-furnace lines: "#0 2/3 steel"
    local rowsLeft = h - y + 1
    local show = math.min(#furnaces, math.max(0, rowsLeft))
    for i = 1, show do
        local st = furnaces[i]
        local inf = st.inflight or 0
        local color = gray
        if inf >= maxInf then
            color = orange
        elseif inf > 0 then
            color = lime
        end
        local label = st.lastRecipe or "-"
        -- index is pair id (1,2,3…) = NL+NR sharing one hatch set
        local line = string.format("%d %d/%d %s", st.index or i, inf, maxInf, label)
        writeAt(mon, 1, y, clip(line, w), color, w)
        y = y + 1
    end
    if #furnaces > show and y <= h then
        writeAt(mon, 1, y, clip(("+ %d more"):format(#furnaces - show), w), yellow, w)
    end
end

return ui
