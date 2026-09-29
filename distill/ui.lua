-- Distillation tower monitor UI (CC: Tweaked / TFG).
-- One gas per full-width row (no 2-col clip). Copy next to main.lua.

local ui = {}

local function clip(text, maxLen)
    text = tostring(text or "")
    if maxLen <= 0 or #text <= maxLen then
        return text
    end
    if maxLen == 1 then
        return "…"
    end
    return text:sub(1, maxLen - 1) .. "…"
end

local function padRight(text, width)
    text = tostring(text or "")
    if #text >= width then
        return text:sub(1, width)
    end
    return text .. string.rep(" ", width - #text)
end

local function shortFluid(name, maxLen)
    maxLen = maxLen or 18
    if not name then
        return "-"
    end
    local short = name:match("([^:/]+)$") or name
    short = short:gsub("_", " ")
    if #short > maxLen then
        return short:sub(1, maxLen - 1) .. "…"
    end
    return short
end

local function formatMb(n)
    n = tonumber(n) or 0
    if n >= 1000000 then
        return string.format("%.2fM", n / 1000000)
    elseif n >= 1000 then
        return string.format("%.0fk", n / 1000)
    end
    return tostring(math.floor(n))
end

local function tankColor(t)
    if t.needOn then
        return colors.red
    elseif not t.okOff then
        return colors.yellow
    end
    return colors.lime
end

--- Plain fill bar only (# / -). Markers live in the text columns.
local function drawLevelBar(ratio, width)
    width = math.max(4, math.floor(width or 1))
    local filled = math.floor((tonumber(ratio) or 0) * width + 1e-9)
    if filled > width then
        filled = width
    end
    if filled < 0 then
        filled = 0
    end
    return string.rep("#", filled) .. string.rep("-", width - filled)
end

local function writeAt(mon, x, y, text, color, maxW)
    mon.setCursorPos(x, y)
    if color then
        mon.setTextColor(color)
    else
        mon.setTextColor(colors.white)
    end
    mon.write(clip(text, maxW))
end

local function writeLine(mon, y, text, color, maxW)
    writeAt(mon, 1, y, text, color, maxW)
end

--- One gas = two full-width lines:
---   # name………………  now% → until%   amount/cap
---   [##############--------]
local function drawTankRow(mon, y, w, t)
    local color = tankColor(t)
    local now = string.format("%5.1f%%", (t.ratio or 0) * 100)
    local untilPct = string.format("%4.0f%%", (t.highTh or 0) * 100)
    local vol = formatMb(t.amount) .. "/" .. formatMb(t.capacity)
    local arrow = " → "

    -- Right block fixed: " 21.0% →  30%  6.69M/32.00M"
    local right = now .. arrow .. untilPct .. "  " .. vol
    local rightW = #right
    local leftBudget = math.max(8, w - rightW - 1)
    local idx = string.format("%d ", t.index or 0)
    local nameW = math.max(4, leftBudget - #idx)
    local name = padRight(shortFluid(t.fluid, nameW), nameW)

    writeLine(mon, y, clip(idx .. name .. right, w), color, w)
    writeLine(mon, y + 1, drawLevelBar(t.ratio, w), color, w)
    return 2
end

function ui.boot(mon, text)
    if not mon then
        return
    end
    mon.clear()
    mon.setTextScale(0.5)
    mon.setCursorPos(1, 1)
    mon.setTextColor(colors.white)
    mon.write(tostring(text or "…"))
end

--- view: tanks, towerEnabled, cooldownLeft, lastBindLabel, lastMinRatio,
--- lastReason, cyclesLow, cyclesHigh, minRatio, maxRatio, networkSummary
function ui.draw(mon, view)
    if not mon or not view then
        return
    end

    mon.clear()
    mon.setTextScale(0.5)
    local w, h = mon.getSize()
    if not w or w < 1 then
        w = 26
    end
    if not h or h < 1 then
        h = 15
    end

    local tanks = view.tanks or {}
    local y = 1

    local status = view.towerEnabled and "ON" or "OFF"
    local statusColor = view.towerEnabled and colors.lime or colors.gray
    local cd = tonumber(view.cooldownLeft) or 0
    if cd > 0 and not view.towerEnabled then
        status = string.format("CD %ds", math.ceil(cd))
        statusColor = colors.orange
    end

    writeLine(
        mon,
        y,
        clip(string.format("DISTILL  %s    limiter: %s", status, tostring(view.lastBindLabel or "-")), w),
        statusColor,
        w
    )
    y = y + 1

    writeLine(
        mon,
        y,
        clip(string.format(
            "Fill until OFF%%   stock %d..%d cycles   floor %.0f%%  ceil %.0f%%",
            tonumber(view.cyclesLow) or 0,
            tonumber(view.cyclesHigh) or 0,
            (tonumber(view.minRatio) or 0) * 100,
            (tonumber(view.maxRatio) or 0) * 100
        ), w),
        colors.lightGray,
        w
    )
    y = y + 1

    -- Column legend
    writeLine(
        mon,
        y,
        clip("id fluid                  now% → until%   amount/cap", w),
        colors.gray,
        w
    )
    y = y + 1

    if #tanks == 0 then
        writeLine(mon, y, "no tanks on network", colors.yellow, w)
        writeLine(mon, y + 1, clip(view.networkSummary or "", w), colors.white, w)
        return
    end

    local blockH = 2
    local footerReserve = 1
    local maxRows = math.floor((h - y + 1 - footerReserve) / blockH)

    for idx, t in ipairs(tanks) do
        if idx > maxRows then
            writeLine(mon, y, clip(string.format("… +%d more tanks", #tanks - maxRows), w), colors.yellow, w)
            y = y + 1
            break
        end
        drawTankRow(mon, y, w, t)
        y = y + blockH
    end

    writeLine(mon, math.min(h, y), clip(view.lastReason or "", w), colors.lightGray, w)
    mon.setTextColor(colors.white)
end

return ui
