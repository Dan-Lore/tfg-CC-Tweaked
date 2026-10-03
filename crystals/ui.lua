-- 1-block monitor UI for crystal engraver controller (ASCII only).

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
    mon.setTextColor(color or colors.white)
    mon.write(clip(text, maxW or 99))
end

local function pad(text, width)
    text = tostring(text or "")
    if #text >= width then
        return text:sub(1, width)
    end
    return text .. string.rep(" ", width - #text)
end

function ui.boot(mon, msg)
    if not mon then
        return
    end
    mon.setTextScale(0.5)
    mon.clear()
    local w = select(1, mon.getSize())
    writeAt(mon, 1, 1, "CRYSTALS", colors.cyan, w)
    writeAt(mon, 1, 3, msg or "boot...", colors.yellow, w)
end

local function stockStats(stockMap)
    local pcs = { 0, 0, 0, 0, 0 }
    local pairCount = 0
    local oddNames = 0
    if stockMap then
        for _, s in pairs(stockMap) do
            local tier = s.tier
            if tier and pcs[tier] then
                pcs[tier] = pcs[tier] + (s.count or 0)
            end
            pairCount = pairCount + math.floor((s.even or 0) / 2)
            if (s.count or 0) % 2 == 1 then
                oddNames = oddNames + 1
            end
        end
    end
    return pcs, pairCount, oddNames
end

--- Two columns with a 1-char gap so "gem 159" + "fls 62" never merge.
local function dual(mon, y, left, right, w, color)
    local gap = 1
    local inner = w - gap
    if inner < 2 then
        writeAt(mon, 1, y, left, color, w)
        return
    end
    local leftW = math.floor(inner / 2)
    local rightW = inner - leftW
    writeAt(mon, 1, y, pad(left, leftW), color, leftW)
    writeAt(mon, leftW + gap + 1, y, pad(right, rightW), color, rightW)
end

--- Compact "tag N" that fits half-width (~6-7 chars on 1x1 @0.5).
local function cell(tag, n, maxW)
    maxW = maxW or 7
    n = tonumber(n) or 0
    local s = tostring(n)
    local room = maxW - #tag - 1
    if room < 1 then
        return clip(tag, maxW)
    end
    if #s > room then
        if n >= 1000 and room >= 3 then
            s = string.format("%dk", math.floor(n / 1000 + 0.5))
        end
        if #s > room then
            s = s:sub(1, room)
        end
    end
    return tag .. " " .. s
end

function ui.draw(mon, state)
    if not mon then
        return
    end
    state = state or {}
    mon.setTextScale(0.5)
    local w, h = mon.getSize()
    mon.clear()

    local live = state.engravers or 0
    local total = state.engraverTotal or live
    local busy = state.busy or 0
    local empty = state.empty or 0
    local pcs, pairCount, oddNames = stockStats(state.stock)
    local colW = math.max(4, math.floor((w - 1) / 2))

    writeAt(mon, 1, 1, "CRYSTALS", colors.cyan, w)
    local engStr
    if total > 0 and live ~= total then
        engStr = live .. "/" .. total
    else
        engStr = tostring(live)
    end
    writeAt(mon, math.max(1, w - #engStr + 1), 1, engStr, colors.white, #engStr)
    writeAt(mon, 1, 2, ("busy %d free %d"):format(busy, empty), colors.white, w)

    writeAt(mon, 1, 3, "buffer pcs", colors.yellow, w)
    dual(mon, 4, cell("chi", pcs[1], colW), cell("flw", pcs[2], colW), w, colors.white)
    dual(mon, 5, cell("gem", pcs[3], colW), cell("fls", pcs[4], colW), w, colors.white)

    local pairColor = pairCount > 0 and colors.lime or colors.lightGray
    dual(mon, 6, cell("pr", pairCount, colW), cell("so", oddNames, colW), w, pairColor)

    local status = tostring(state.status or "-")
    local sc = colors.white
    if state.moved and state.moved > 0 then
        sc = colors.lime
    elseif status:find("sort", 1, true) then
        sc = colors.yellow
    elseif status:find("no live", 1, true) or status:find("no engraver", 1, true) then
        sc = colors.red
    elseif status:find("wait", 1, true) or status:find("idle", 1, true) or status:find("full", 1, true) then
        sc = colors.lightGray
    end
    if h >= 7 then
        writeAt(mon, 1, 7, status, sc, w)
    end
end

return ui
