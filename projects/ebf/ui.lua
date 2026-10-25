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
    writeAt(mon, 1, 1, "EBF", loadColor("cyan", 1), w)
    writeAt(mon, 1, 2, "SCAN", loadColor("yellow", 1), w)
    writeAt(mon, 1, 4, msg or "boot", loadColor("gray", 1), w)
end

local STATUS_LABEL = {
    empty = "-",
    busy = "busy",
    warn_item = "WARN item",
    warn_fluid = "WARN fluid",
    err_no_fluid_in = "ERR no fluid in",
    err_no_item_out = "ERR no item out",
    err_no_fluid_out = "ERR no fluid out",
    err_no_item_in = "ERR no item in",
    err = "ERR",
}

local STATUS_COLOR = {
    empty = "gray",
    busy = "lime",
    warn_item = "orange",
    warn_fluid = "orange",
    err_no_fluid_in = "red",
    err_no_item_out = "red",
    err_no_fluid_out = "red",
    err_no_item_in = "red",
    err = "red",
}

--- Compact status board (no recipes / inflight fractions).
-- state: mode, packs, suppliers, hotPct, rows[{index,status}]
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
    local red = loadColor("red", 1)
    local cyan = loadColor("cyan", 1)
    local orange = loadColor("orange", 1)

    local mode = tostring(state.mode or "IDLE"):upper()
    local modeColor = white
    if mode == "WORK" then
        modeColor = lime
    elseif mode == "WAIT" or mode == "FULL" or mode == "WARN" then
        modeColor = yellow
    elseif mode == "SCAN" then
        modeColor = cyan
    elseif mode == "ERR" then
        modeColor = red
    end

    writeAt(mon, 1, 1, clip("EBF " .. mode, w), modeColor, w)
    writeAt(
        mon,
        1,
        2,
        clip(("packs %d"):format(tonumber(state.packs) or 0), w),
        white,
        w
    )
    writeAt(
        mon,
        1,
        3,
        clip(("supp  %d"):format(tonumber(state.suppliers) or 0), w),
        white,
        w
    )

    local hot = state.hotPct
    if hot == nil then
        writeAt(mon, 1, 4, clip("hot   ?", w), gray, w)
    else
        local hotColor = lime
        if hot >= 90 then
            hotColor = red
        elseif hot >= 70 then
            hotColor = orange
        elseif hot >= 40 then
            hotColor = yellow
        end
        writeAt(mon, 1, 4, clip(("hot   %d%%"):format(hot), w), hotColor, w)
    end

    local rows = state.rows or {}
    local y = 5
    local show = math.min(#rows, math.max(0, h - y + 1))
    for i = 1, show do
        local row = rows[i]
        local stName = row.status or "empty"
        local label = STATUS_LABEL[stName] or stName
        local cname = STATUS_COLOR[stName] or "gray"
        local color = loadColor(cname, gray)
        writeAt(
            mon,
            1,
            y,
            clip(("%d %s"):format(row.index or i, label), w),
            color,
            w
        )
        y = y + 1
    end
    if #rows > show and y <= h then
        writeAt(mon, 1, y, clip(("+ %d"):format(#rows - show), w), yellow, w)
    end
end

return ui
