-- Bucket + interpolate AE amount series for monitor plotting.

local util = require("util")

local graph = {}

graph.WINDOWS = {
    { id = "5m", label = "5m", sec = 5 * 60 },
    { id = "10m", label = "10m", sec = 10 * 60 },
    { id = "30m", label = "30m", sec = 30 * 60 },
    { id = "1h", label = "1h", sec = 60 * 60 },
    { id = "2h", label = "2h", sec = 2 * 60 * 60 },
}

graph.STEPS = {
    { id = "1m", label = "1m", sec = 60 },
    { id = "5m", label = "5m", sec = 5 * 60 },
    { id = "10m", label = "10m", sec = 10 * 60 },
    { id = "30m", label = "30m", sec = 30 * 60 },
}

graph.INTERPS = {
    { id = "off", label = "off" },
    { id = "i1", label = "i1" },
    { id = "i2", label = "i2" },
}

function graph.findWindow(id)
    for i = 1, #graph.WINDOWS do
        if graph.WINDOWS[i].id == id then
            return graph.WINDOWS[i]
        end
    end
    return graph.WINDOWS[1]
end

function graph.findStep(id)
    for i = 1, #graph.STEPS do
        if graph.STEPS[i].id == id then
            return graph.STEPS[i]
        end
    end
    return graph.STEPS[2]
end

--- Steps with sec <= window (s must not exceed w).
function graph.stepsForWindow(windowId)
    local win = graph.findWindow(windowId)
    local out = {}
    for i = 1, #graph.STEPS do
        if graph.STEPS[i].sec <= win.sec then
            out[#out + 1] = graph.STEPS[i]
        end
    end
    if #out == 0 then
        out[1] = graph.STEPS[1]
    end
    return out
end

function graph.clampStep(windowId, stepId)
    local steps = graph.stepsForWindow(windowId)
    for i = 1, #steps do
        if steps[i].id == stepId then
            return stepId
        end
    end
    return steps[1].id
end

--- Bucket raw points into step-sized bins (last sample wins).
function graph.bucket(points, windowSec, stepSec, nowT)
    nowT = nowT or (os.epoch("utc") / 1000)
    stepSec = math.max(1, tonumber(stepSec) or 1)
    if stepSec > windowSec then
        stepSec = windowSec
    end
    local startT = nowT - windowSec
    local n = math.max(1, math.floor(windowSec / stepSec + 1e-9))
    local buckets = {}
    for i = 1, n do
        buckets[i] = { t = startT + (i - 0.5) * stepSec, amount = nil }
    end
    for i = 1, #(points or {}) do
        local p = points[i]
        local t = tonumber(p.t)
        local amount = tonumber(p.amount)
        if t and amount ~= nil and t >= startT and t <= nowT + 1 then
            local idx = math.floor((t - startT) / stepSec) + 1
            idx = util.clamp(idx, 1, n)
            buckets[idx].amount = amount
            buckets[idx].t = t
        end
    end
    return buckets
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

--- Catmull-Rom between p1-p2 with neighbors p0,p3; t in [0,1].
local function catmull(p0, p1, p2, p3, t)
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * (
        (2 * p1)
        + (-p0 + p2) * t
        + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
        + (-p0 + 3 * p1 - 3 * p2 + p3) * t3
    )
end

--- Build dense Y values for width columns. Returns ys[1..width], ymin, ymax.
function graph.resample(buckets, width, interp)
    width = math.max(2, math.floor(width))
    local known = {}
    for i = 1, #buckets do
        if buckets[i].amount ~= nil then
            known[#known + 1] = { i = i, amount = buckets[i].amount }
        end
    end
    if #known == 0 then
        local ys = {}
        for x = 1, width do
            ys[x] = nil
        end
        return ys, 0, 1
    end

    local function bucketToX(bi)
        if #buckets <= 1 then
            return 1
        end
        return 1 + (bi - 1) * (width - 1) / (#buckets - 1)
    end

    local ys = {}
    for x = 1, width do
        ys[x] = nil
    end

    if interp == "off" then
        for k = 1, #known do
            local x = math.floor(bucketToX(known[k].i) + 0.5)
            x = util.clamp(x, 1, width)
            ys[x] = known[k].amount
        end
    elseif interp == "i2" and #known >= 2 then
        for x = 1, width do
            local pos = 1 + (x - 1) * (#buckets - 1) / (width - 1)
            -- find segment in known by bucket index
            local bi = pos
            local k = 1
            while k < #known and known[k + 1].i < bi do
                k = k + 1
            end
            local k0 = util.clamp(k - 1, 1, #known)
            local k1 = k
            local k2 = util.clamp(k + 1, 1, #known)
            local k3 = util.clamp(k + 2, 1, #known)
            local i1, i2 = known[k1].i, known[k2].i
            local t = 0
            if i2 ~= i1 then
                t = util.clamp((bi - i1) / (i2 - i1), 0, 1)
            end
            ys[x] = catmull(known[k0].amount, known[k1].amount, known[k2].amount, known[k3].amount, t)
        end
    else
        -- i1 linear (also fallback)
        for x = 1, width do
            local pos = 1 + (x - 1) * (#buckets - 1) / (width - 1)
            local k = 1
            while k < #known and known[k + 1].i < pos do
                k = k + 1
            end
            if k >= #known then
                ys[x] = known[#known].amount
            elseif known[k].i >= pos then
                ys[x] = known[k].amount
            else
                local a, b = known[k], known[k + 1]
                local t = (pos - a.i) / (b.i - a.i)
                ys[x] = lerp(a.amount, b.amount, t)
            end
        end
    end

    local ymin, ymax = nil, nil
    for x = 1, width do
        local v = ys[x]
        if v ~= nil then
            if not ymin or v < ymin then
                ymin = v
            end
            if not ymax or v > ymax then
                ymax = v
            end
        end
    end
    if not ymin then
        ymin, ymax = 0, 1
    end
    if ymax <= ymin then
        ymax = ymin + 1
    end
    local pad = (ymax - ymin) * 0.05
    return ys, ymin - pad, ymax + pad
end

--- Compact number with spaced unit: "2.3 k", "7.09 M", "130".
local function fmtNum(n)
    n = tonumber(n) or 0
    local a = math.abs(n)
    if a >= 1e9 then
        return string.format("%.2f G", n / 1e9)
    elseif a >= 1e6 then
        return string.format("%.2f M", n / 1e6)
    elseif a >= 1e3 then
        return string.format("%.1f k", n / 1e3)
    end
    return string.format("%.0f", n)
end

--- Item/fluid amount for lists: "2.3 k", "7.09 MmB", "371.5 kmB", "64 mB".
local function fmtAmount(n, isFluid)
    n = tonumber(n) or 0
    local a = math.abs(n)
    local num, pref
    if a >= 1e9 then
        num, pref = string.format("%.2f", n / 1e9), "G"
    elseif a >= 1e6 then
        num, pref = string.format("%.2f", n / 1e6), "M"
    elseif a >= 1e3 then
        num, pref = string.format("%.1f", n / 1e3), "k"
    else
        num, pref = string.format("%.0f", n), ""
    end
    if isFluid then
        if pref == "" then
            return num .. " mB"
        end
        return num .. " " .. pref .. "mB"
    end
    if pref == "" then
        return num
    end
    return num .. " " .. pref
end

--- Axis label: pick unit/decimals from (ymin..ymax) so top/mid/bot stay distinct.
local function fmtAmountAxis(n, isFluid, ymin, ymax)
    n = tonumber(n) or 0
    ymin = tonumber(ymin) or n
    ymax = tonumber(ymax) or n
    local span = math.abs(ymax - ymin)
    if span < 1e-9 then
        span = math.max(math.abs(n) * 0.01, 1)
    end
    local mag = math.max(math.abs(ymin), math.abs(ymax), math.abs(n))

    local div, pref
    if mag >= 1e9 then
        div, pref = 1e9, "G"
    elseif mag >= 1e6 then
        div, pref = 1e6, "M"
    elseif mag >= 1e3 then
        div, pref = 1e3, "k"
    else
        div, pref = 1, ""
    end

    -- decimals so one step of the axis (~span/2) changes the printed number
    local step = (span / div) / 2
    local decimals = 0
    if step > 0 and step < 1 then
        decimals = math.ceil(-math.log10(step)) + 1
    end
    decimals = util.clamp(decimals, 0, 3)
    -- tight zoom on large totals: need more digits (2.80 k vs 2.81 k)
    if pref ~= "" and span / mag < 0.05 then
        decimals = math.max(decimals, 2)
    end

    local num = string.format("%." .. tostring(decimals) .. "f", n / div)
    if isFluid then
        if pref == "" then
            return num .. " mB"
        end
        return num .. " " .. pref .. "mB"
    end
    if pref == "" then
        return num
    end
    return num .. " " .. pref
end

graph.fmtNum = fmtNum
graph.fmtAmount = fmtAmount
graph.fmtAmountAxis = fmtAmountAxis

local function toBlit(color)
    -- CC color bit -> blit hex digit
    local n = 0
    local c = color or 1
    while c > 1 do
        c = math.floor(c / 2)
        n = n + 1
    end
    return ("0123456789abcdef"):sub(n + 1, n + 1)
end

local BLIT_BLACK = toBlit(colors.black)
local BLIT_GRAY = toBlit(colors.gray)
local BLIT_LGRAY = toBlit(colors.lightGray)
local BLIT_LINE = toBlit(colors.lime)
local BLIT_LINE2 = toBlit(colors.cyan)
local BLIT_FILL = toBlit(colors.green)
local BLIT_WHITE = toBlit(colors.white)

--- Area + thin top-edge chart (no thick paintutils stairs).
-- Left gutter = Y labels; plot = fill under curve + ▀ edge.
-- isFluid selects mB axis units.
function graph.draw(mon, x0, y0, w, h, ys, ymin, ymax, interp, isFluid)
    if w < 8 or h < 3 then
        return
    end
    local span = ymax - ymin
    if span <= 0 then
        span = 1
    end

    local function axisLabel(v)
        return fmtAmountAxis(v, isFluid, ymin, ymax)
    end
    local topL = axisLabel(ymax)
    local midL = axisLabel((ymin + ymax) * 0.5)
    local botL = axisLabel(ymin)
    local labelW = math.max(#topL, #midL, #botL)

    local gutter = util.clamp(labelW + 1, 8, 14)
    local plotX = x0 + gutter
    local plotW = w - gutter
    local plotH = h
    if plotW < 4 then
        gutter = 6
        plotX = x0 + gutter
        plotW = w - gutter
    end

    -- ys may be sized to an earlier plotW estimate; remap by index
    local ysLen = #ys
    local function yAt(x)
        if ysLen <= 0 then
            return nil
        end
        if ysLen == plotW then
            return ys[x]
        end
        local idx = math.floor((x - 1) * (ysLen - 1) / math.max(1, plotW - 1) + 0.5) + 1
        return ys[util.clamp(idx, 1, ysLen)]
    end

    local lineBlit = (interp == "i2") and BLIT_LINE2 or BLIT_LINE
    local midRow = math.floor((plotH - 1) * 0.5)
    local q1 = math.floor((plotH - 1) * 0.25)
    local q3 = math.floor((plotH - 1) * 0.75)

    local cols = {}
    for x = 1, plotW do
        local v = yAt(x)
        if v ~= nil then
            local norm = (v - ymin) / span
            cols[x] = util.clamp((1 - norm) * (plotH - 1), 0, plotH - 1)
        end
    end

    for row = 0, plotH - 1 do
        local chars, fg, bg = {}, {}, {}
        local grid = (row == midRow or row == q1 or row == q3)
        for x = 1, plotW do
            local yv = cols[x]
            local ch, f, b = " ", BLIT_WHITE, BLIT_BLACK
            if grid and yv == nil then
                ch, f, b = "-", BLIT_GRAY, BLIT_BLACK
            elseif yv ~= nil then
                local yi = math.floor(yv + 1e-9)
                if interp == "off" then
                    if row == yi then
                        ch, f, b = "o", lineBlit, BLIT_BLACK
                    elseif grid and row < yi then
                        ch, f, b = "-", BLIT_GRAY, BLIT_BLACK
                    end
                else
                    if row > yi then
                        ch, f, b = " ", BLIT_WHITE, BLIT_FILL
                    elseif row == yi then
                        ch, f, b = "\143", lineBlit, BLIT_FILL
                    elseif grid then
                        ch, f, b = "-", BLIT_LGRAY, BLIT_BLACK
                    end
                end
            end
            chars[x], fg[x], bg[x] = ch, f, b
        end
        mon.setCursorPos(plotX, y0 + row)
        mon.blit(table.concat(chars), table.concat(fg), table.concat(bg))
    end

    local function fit(s)
        if #s > gutter - 1 then
            return s:sub(1, gutter - 1)
        end
        return s
    end
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.setCursorPos(x0, y0)
    mon.write(fit(topL))
    mon.setCursorPos(x0, y0 + midRow)
    mon.setTextColor(colors.lightGray)
    mon.write(fit(midL))
    mon.setCursorPos(x0, y0 + plotH - 1)
    mon.setTextColor(colors.white)
    mon.write(fit(botL))
end

return graph
