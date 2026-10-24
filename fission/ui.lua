-- Russian status monitor for both reactors.

local ui = {}

local function discoverMonitor(want)
    if want and peripheral.isPresent(want) and peripheral.getType(want) == "monitor" then
        return peripheral.wrap(want), want
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            return peripheral.wrap(name), name
        end
    end
    return nil, nil
end

local function shortName(id)
    if not id then
        return "?"
    end
    local s = tostring(id)
    local leaf = s:match("([^:/]+)$") or s
    return leaf
end

local function fmtNum(n, digits)
    n = tonumber(n)
    if not n then
        return "?"
    end
    digits = digits or 1
    return string.format("%." .. tostring(digits) .. "f", n)
end

local function formatDuration(sec)
    sec = tonumber(sec)
    if not sec or sec < 0 then
        return nil
    end
    sec = math.floor(sec + 0.5)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then
        return string.format("%dч %dм %dс", h, m, s)
    elseif m > 0 then
        return string.format("%dм %dс", m, s)
    end
    return string.format("%dс", s)
end

local function progressBar(innerW, pct)
    pct = tonumber(pct) or 0
    if pct < 0 then
        pct = 0
    end
    if pct > 100 then
        pct = 100
    end
    innerW = math.max(4, tonumber(innerW) or 10)
    local filled = math.floor(innerW * pct / 100 + 0.5)
    if filled > innerW then
        filled = innerW
    end
    return "[" .. string.rep("#", filled) .. string.rep("-", innerW - filled) .. "]"
end

local function lifeColor(pct)
    pct = tonumber(pct) or 0
    if pct <= 20 then
        return colors.red
    elseif pct <= 50 then
        return colors.orange
    end
    return colors.lime
end

--- Truncate by display columns without splitting a UTF-8 codepoint (byte :sub
-- mid-character shows as mojibake on CC monitors).
local function truncateCols(text, maxCols)
    text = tostring(text or "")
    maxCols = tonumber(maxCols) or 0
    if maxCols <= 0 then
        return ""
    end
    if utf8 and utf8.len and utf8.offset then
        local n = utf8.len(text)
        if not n then
            -- invalid UTF-8; fall back to bytes
            if #text > maxCols then
                return text:sub(1, maxCols)
            end
            return text
        end
        if n <= maxCols then
            return text
        end
        local cut = utf8.offset(text, maxCols + 1)
        if cut then
            return text:sub(1, cut - 1)
        end
        return text
    end
    if #text > maxCols then
        return text:sub(1, maxCols)
    end
    return text
end

local function writeLine(mon, y, text, color)
    local w = mon.getSize()
    mon.setCursorPos(1, y)
    if color then
        mon.setTextColor(color)
    else
        mon.setTextColor(colors.white)
    end
    mon.clearLine()
    mon.write(truncateCols(text, w))
end

function ui.find(cfg)
    return discoverMonitor(cfg and cfg.monitor)
end

--- states: array of { label, ok, running, heat, maxHeat, rods, target, primary, stock, needed, alert, err }
function ui.draw(mon, cfg, states, globalErr)
    if not mon then
        return
    end
    local scale = tonumber(cfg and cfg.text_scale) or 0.5
    if scale < 0.5 then
        scale = 0.5
    elseif scale > 5 then
        scale = 5
    end
    mon.setTextScale(scale)
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    local y = 1
    writeLine(mon, y, "Деление — контроль топлива", colors.yellow)
    y = y + 1
    writeLine(mon, y, string.rep("-", math.min(w, 40)), colors.gray)
    y = y + 1

    if globalErr then
        writeLine(mon, y, tostring(globalErr), colors.red)
        y = y + 1
    end

    for i = 1, #(states or {}) do
        if y > h then
            break
        end
        local s = states[i]
        local title = string.format("R%d %s", i - 1, s.label or "")
        writeLine(mon, y, title, colors.lightBlue)
        y = y + 1
        if y > h then
            break
        end

        if s.err then
            writeLine(mon, y, "  Ошибка: " .. tostring(s.err), colors.red)
            y = y + 1
        else
            local runText = s.status or (s.running and "Работает" or "Простой")
            local runColor = colors.orange
            local sc = s.statusColor
            if sc == "lime" then
                runColor = colors.lime
            elseif sc == "red" then
                runColor = colors.red
            elseif sc == "yellow" then
                runColor = colors.yellow
            elseif sc == "orange" then
                runColor = colors.orange
            end
            writeLine(mon, y, "  " .. runText, runColor)
            y = y + 1
            if y > h then
                break
            end

            writeLine(mon, y, string.format(
                "  Нагрев: %s / %s",
                fmtNum(s.heat, 1),
                fmtNum(s.maxHeat, 0)
            ), colors.white)
            y = y + 1
            if y > h then
                break
            end

            local pending = tonumber(s.pending) or 0
            local rodLine = string.format(
                "  Стержни: %d / %d  (%s)",
                tonumber(s.rods) or 0,
                tonumber(s.target) or 0,
                shortName(s.primary)
            )
            if pending > 0 then
                rodLine = rodLine .. string.format(" +%d вх", pending)
            end
            writeLine(mon, y, rodLine, colors.white)
            y = y + 1
            if y > h then
                break
            end

            local wear = s.wear or {}
            if #wear == 0 then
                writeLine(mon, y, "  Износ: —", colors.gray)
                y = y + 1
            else
                for wi = 1, #wear do
                    if y > h then
                        break
                    end
                    local wentry = wear[wi]
                    local pct = tonumber(wentry.pct) or 0
                    local wcolor = colors.lime
                    if pct >= 80 then
                        wcolor = colors.red
                    elseif pct >= 50 then
                        wcolor = colors.orange
                    end
                    writeLine(mon, y, string.format(
                        "  #%d износ %d%% (%d/%d)",
                        tonumber(wentry.index) or wi,
                        math.floor(pct + 0.5),
                        tonumber(wentry.damage) or 0,
                        tonumber(wentry.maxDamage) or 0
                    ), wcolor)
                    y = y + 1
                end
            end
            if y > h then
                break
            end

            writeLine(mon, y, string.format(
                "  Запас: %d",
                tonumber(s.stock) or 0
            ), colors.white)
            y = y + 1
            if y > h then
                break
            end

            local lifePct = tonumber(s.lifePct) or 0
            local eta = formatDuration(s.etaSec)
            local etaLine
            if s.etaNote then
                etaLine = "  Осталось: " .. tostring(s.etaNote)
            elseif eta then
                etaLine = "  Осталось: " .. eta
            elseif (tonumber(s.rods) or 0) <= 0 then
                etaLine = "  Осталось: —"
            else
                etaLine = "  Осталось: ? (нет износа/тик)"
            end
            writeLine(mon, y, etaLine, lifeColor(lifePct))
            y = y + 1
            if y > h then
                break
            end

            local barInner = math.max(8, w - 8)
            local bar = progressBar(barInner, lifePct)
            writeLine(mon, y, string.format("  %s %d%%", bar, math.floor(lifePct + 0.5)), lifeColor(lifePct))
            y = y + 1
            if y > h then
                break
            end

            if s.alert == "hard" then
                writeLine(mon, y, "  Тревога: мало стержней, проверь AE", colors.red)
                y = y + 1
            elseif s.alert == "soft" then
                writeLine(mon, y, "  Предупреждение: мало стержней в запасе, проверь AE", colors.orange)
                y = y + 1
            end
        end

        if y <= h then
            writeLine(mon, y, "", colors.white)
            y = y + 1
        end
    end
end

return ui
