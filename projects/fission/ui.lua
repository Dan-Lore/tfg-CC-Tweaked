-- Russian status monitor + touch buttons (mode / one-cycle).

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
    return s:match("([^:/]+)$") or s
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

local function truncateCols(text, maxCols)
    text = tostring(text or "")
    maxCols = tonumber(maxCols) or 0
    if maxCols <= 0 then
        return ""
    end
    if utf8 and utf8.len and utf8.offset then
        local n = utf8.len(text)
        if not n then
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

local function writeAt(mon, x, y, text, color)
    mon.setCursorPos(x, y)
    if color then
        mon.setTextColor(color)
    else
        mon.setTextColor(colors.white)
    end
    mon.write(tostring(text or ""))
end

local function cols(text)
    text = tostring(text or "")
    if utf8 and utf8.len then
        local n = utf8.len(text)
        if n then
            return n
        end
    end
    return #text
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

--- Solid button via blit; label centered in [x1..x2].
local function paintButton(mon, btn, fg, bg)
    local mw = mon.getSize()
    if btn.x1 > mw or btn.x1 > btn.x2 then
        return
    end
    local width = btn.x2 - btn.x1 + 1
    local label = truncateCols(tostring(btn.label or ""), width)
    local len = cols(label)
    local padL = math.max(0, math.floor((width - len) / 2))
    local padR = math.max(0, width - len - padL)
    local text = string.rep(" ", padL) .. label .. string.rep(" ", padR)
    local n = cols(text)
    if n < width then
        text = text .. string.rep(" ", width - n)
    elseif n > width then
        text = truncateCols(text, width)
    end
    local f = colors.toBlit(fg or colors.white)
    local b = colors.toBlit(bg or colors.gray)
    mon.setCursorPos(btn.x1, btn.y)
    mon.blit(text, string.rep(f, width), string.rep(b, width))
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
end

function ui.find(cfg)
    return discoverMonitor(cfg and cfg.monitor)
end

--- Draw UI; return hitboxes { {x1,x2,y, action, index}, ... }
function ui.draw(mon, cfg, states, globalErr)
    local hits = {}
    if not mon then
        return hits
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
    mon.setTextColor(colors.white)
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

        -- Buttons on the title row: Авто/Ручн share the same right edge;
        -- «Запуск 1 цикла» sits to the left of Ручн (not flush to monitor edge).
        local btnY = y
        local isManual = s.control == "manual"
        local armed = s.cycle == true
        local modeLabel = isManual and "Ручн" or "Авто"
        local cycleLabel = armed and "Запуск 1 цикла*" or "Запуск 1 цикла"
        local modeW = cols(modeLabel) + 2 -- 1 col pad each side
        local cycleW = cols(cycleLabel) + 2
        local gap = 1
        local edgePad = 1 -- leave a column so buttons don't stick to the rim
        local modeX2 = w - edgePad
        local modeX1 = modeX2 - modeW + 1
        local cycleX1, cycleX2
        if isManual then
            cycleX2 = modeX1 - gap - 1
            cycleX1 = cycleX2 - cycleW + 1
        end
        local titleCols = cols(title)
        local leftMost = (cycleX1 and cycleX1 < modeX1) and cycleX1 or modeX1
        if leftMost > titleCols + 2 then
            if isManual and cycleX1 then
                local cycleBtn = {
                    x1 = cycleX1,
                    x2 = cycleX2,
                    y = btnY,
                    label = cycleLabel,
                    action = "one_cycle",
                    index = i,
                }
                paintButton(
                    mon,
                    cycleBtn,
                    colors.black,
                    armed and colors.lime or colors.lightBlue
                )
                hits[#hits + 1] = cycleBtn
            end

            local modeBtn = {
                x1 = modeX1,
                x2 = modeX2,
                y = btnY,
                label = modeLabel,
                action = "toggle_mode",
                index = i,
            }
            paintButton(
                mon,
                modeBtn,
                colors.white,
                isManual and colors.orange or colors.green
            )
            hits[#hits + 1] = modeBtn
        end

        y = y + 1
        if y > h then
            break
        end

        if s.err then
            writeLine(mon, y, "  Ошибка: " .. tostring(s.err), colors.red)
            y = y + 1
        else
            local runText = s.status or "Простой"
            local runColor = colors.orange
            local sc = s.statusColor
            if sc == "lime" then
                runColor = colors.lime
            elseif sc == "red" then
                runColor = colors.red
            elseif sc == "yellow" then
                runColor = colors.yellow
            end
            local ctrlNote = (s.control == "manual") and " [ручн]" or " [авто]"
            if s.cycle then
                ctrlNote = ctrlNote .. " цикл"
            end
            writeLine(mon, y, "  " .. runText .. ctrlNote, runColor)
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

            writeLine(mon, y, string.format("  Запас: %d", tonumber(s.stock) or 0), colors.white)
            y = y + 1
            if y > h then
                break
            end

            if s.pellets_need and s.pellets_need > 0 then
                writeLine(mon, y, string.format(
                    "  Гранулы: %d / нужно %d",
                    tonumber(s.pellets) or 0,
                    tonumber(s.pellets_need) or 0
                ), ((tonumber(s.pellets) or 0) >= (tonumber(s.pellets_need) or 0)) and colors.lime or colors.orange)
                y = y + 1
                if y > h then
                    break
                end
            end

            local lifePct = tonumber(s.lifePct) or 0
            local rodsNow = tonumber(s.rods) or 0
            -- Empty / idle: gray, not red (red = fuel almost gone while running).
            local barColor = (rodsNow <= 0) and colors.gray or lifeColor(lifePct)
            local eta = formatDuration(s.etaSec)
            local etaLine
            if s.etaNote then
                etaLine = "  Осталось: " .. tostring(s.etaNote)
            elseif eta then
                etaLine = "  Осталось: " .. eta
            elseif rodsNow <= 0 then
                etaLine = "  Осталось: —"
            else
                etaLine = "  Осталось: ? (нет износа/тик)"
            end
            writeLine(mon, y, etaLine, barColor)
            y = y + 1
            if y > h then
                break
            end

            local barInner = math.max(8, w - 8)
            writeLine(mon, y, string.format(
                "  %s %d%%",
                progressBar(barInner, lifePct),
                math.floor(lifePct + 0.5)
            ), barColor)
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
            elseif s.alert == "pellets" then
                writeLine(mon, y, "  Тревога: мало гранул для цикла", colors.red)
                y = y + 1
            end
            if s.feedErr and y <= h then
                writeLine(mon, y, "  Подача: " .. tostring(s.feedErr), colors.red)
                y = y + 1
            end
        end

        if y <= h then
            writeLine(mon, y, "", colors.white)
            y = y + 1
        end
    end

    return hits
end

function ui.hit(hits, x, y)
    for i = 1, #(hits or {}) do
        local b = hits[i]
        if b.y == y and x >= b.x1 and x <= b.x2 then
            return b
        end
    end
    return nil
end

return ui
