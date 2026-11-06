-- 1-block monitor UI for fluid_feed (minimal + alarm).

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
    writeAt(mon, 1, 1, "FLUID", loadColor("cyan", 1), w)
    writeAt(mon, 1, 2, "FEED", loadColor("cyan", 1), w)
    writeAt(mon, 1, 4, msg or "boot", loadColor("yellow", 1), w)
end

--- state: total, ok, empty, bad, amount, status, lastFluid, alarm
function ui.draw(mon, state)
    if not mon then
        return
    end
    state = state or {}
    if mon.setTextScale then
        mon.setTextScale(0.5)
    end
    local w, h = mon.getSize()
    mon.clear()

    local total = tonumber(state.total) or 0
    local okN = tonumber(state.ok) or 0
    local emptyN = tonumber(state.empty) or 0
    local badN = tonumber(state.bad) or 0
    -- Alarm only on bad (non-empty and != amount). Empty counts as normal.
    local alarm = state.alarm
    if alarm == nil then
        alarm = badN > 0
    end

    writeAt(mon, 1, 1, "FLUID", loadColor("cyan", 1), w)

    local okStr = ("%d/%d"):format(okN + emptyN, total)
    local okColor = alarm and loadColor("red", 1) or loadColor("lime", 1)
    writeAt(mon, math.max(1, w - #okStr + 1), 1, okStr, okColor, #okStr)

    if alarm then
        writeAt(mon, 1, 2, "ALARM", loadColor("red", 1), w)
    else
        writeAt(mon, 1, 2, "ok", loadColor("lime", 1), w)
    end

    if h >= 3 then
        writeAt(mon, 1, 3, ("e%d !%d"):format(emptyN, badN), loadColor("white", 1), w)
    end

    if h >= 4 then
        local amt = tonumber(state.amount) or 144
        writeAt(mon, 1, 4, ("x%d mb"):format(amt), loadColor("lightGray", 1), w)
    end

    if h >= 5 and state.lastFluid then
        writeAt(mon, 1, 5, tostring(state.lastFluid), loadColor("yellow", 1), w)
    end

    if h >= 6 then
        local status = tostring(state.status or "-")
        local sc = loadColor("white", 1)
        if alarm then
            sc = loadColor("red", 1)
        elseif status:find("push", 1, true) then
            sc = loadColor("lime", 1)
        elseif status:find("wait", 1, true) or status:find("idle", 1, true) then
            sc = loadColor("lightGray", 1)
        elseif status:find("no ", 1, true) then
            sc = loadColor("orange", 1)
        end
        writeAt(mon, 1, 6, status, sc, w)
    end
end

return ui
