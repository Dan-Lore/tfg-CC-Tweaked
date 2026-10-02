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

--- Two cells; left keeps room for a 3-letter tag + number.
local function dual(mon, y, left, right, w, color)
    local minLeft = math.min(w - 1, math.max(#tostring(left), 7))
    local mid = math.max(math.floor(w / 2), minLeft + 1)
    if mid >= w then
        mid = w - 1
    end
    local leftW = mid - 1
    local rightW = w - mid
    writeAt(mon, 1, y, pad(left, leftW), color, leftW)
    writeAt(mon, mid + 1, y, pad(right, rightW), color, rightW)
end

local function cell(tag3, n)
    return tag3 .. " " .. tostring(n or 0)
end

function ui.draw(mon, state)
    if not mon then
        return
    end
    state = state or {}
    mon.setTextScale(0.5)
    local w, h = mon.getSize()
    mon.clear()

    local eng = state.engravers or 0
    local busy = state.busy or 0
    local empty = state.empty or 0
    local pcs, pairCount, oddNames = stockStats(state.stock)

    writeAt(mon, 1, 1, "CRYSTALS", colors.cyan, w)
    local engStr = tostring(eng)
    writeAt(mon, math.max(1, w - #engStr + 1), 1, engStr, colors.white, #engStr)
    writeAt(mon, 1, 2, ("busy %d  free %d"):format(busy, empty), colors.white, w)

    writeAt(mon, 1, 3, "buffer pcs", colors.yellow, w)
    -- grouping: chipped|flawed, gem|flawless
    dual(mon, 4, cell("chi", pcs[1]), cell("flw", pcs[2]), w, colors.white)
    dual(mon, 5, cell("gem", pcs[3]), cell("fls", pcs[4]), w, colors.white)

    local pairColor = pairCount > 0 and colors.lime or colors.lightGray
    dual(mon, 6, "pairs " .. pairCount, "solo " .. oddNames, w, pairColor)

    local status = tostring(state.status or "-")
    local sc = colors.white
    if state.moved and state.moved > 0 then
        sc = colors.lime
    elseif status:find("sort", 1, true) then
        sc = colors.yellow
    elseif status:find("wait", 1, true) or status:find("idle", 1, true) then
        sc = colors.lightGray
    end
    if h >= 7 then
        writeAt(mon, 1, 7, status, sc, w)
    end
    if h >= 8 and state.detail then
        writeAt(mon, 1, 8, state.detail, colors.lightGray, w)
    end
end

return ui
