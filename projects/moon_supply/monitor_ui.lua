-- Earth monitor: Russian labels, fixed columns, per-column colors.

local monitor_ui = {}

local NAMES = {
    ["gtceu:mv_conveyor_module"] = "конвейер MV",
    ["gtceu:aluminium_ingot"] = "слиток алюминия",
    ["gtceu:hv_robot_arm"] = "роборука HV",
    ["gtceu:cpu_chip"] = "процессор",
    ["gtceu:stainless_steel_ingot"] = "слиток нерж. стали",
    ["gtceu:polyethylene_foil"] = "фольга ПЭ",
    ["minecraft:redstone"] = "редстоун",
    ["tfg:hv_universal_circuit"] = "схема HV",
    ["tfg:lv_universal_circuit"] = "схема LV",
    ["gtceu:mv_robot_arm"] = "роборука MV",
    ["gtceu:ram_chip"] = "ОЗУ",
    ["gtceu:polyvinyl_chloride_foil"] = "фольга ПВХ",
    ["tfg:ev_universal_circuit"] = "схема EV",
    ["tfg:iv_universal_circuit"] = "схема IV",
    ["gtceu:exquisite_quartzite_gem"] = "Кварц (Изыск.)",
    ["gtceu:exquisite_nether_quartz_gem"] = "Дымч. кварц (Изыск.)",
    ["gtceu:exquisite_certus_quartz_gem"] = "Истин. кварц (Изыск.)",
    ["gtceu:diamond_plate"] = "пластина алмаз",
    ["gtceu:silicon_plate"] = "пластина кремний",
    ["minecraft:gold_ingot"] = "слиток золота",
    ["gtceu:dense_silicon_plate"] = "плотн. пластина кремний",
    ["tfg:silica_aerogel"] = "аэрогель",
}

-- Display only. group = block on the monitor; rank = smaller→larger inside the group.
local ORDER = {
    ["tfg:lv_universal_circuit"] = { 1, 1 },
    ["tfg:hv_universal_circuit"] = { 1, 2 },
    ["tfg:ev_universal_circuit"] = { 1, 3 },
    ["tfg:iv_universal_circuit"] = { 1, 4 },
    ["gtceu:mv_conveyor_module"] = { 2, 1 },
    ["gtceu:mv_robot_arm"] = { 2, 2 },
    ["gtceu:hv_robot_arm"] = { 2, 3 },
    ["gtceu:cpu_chip"] = { 2, 4 },
    ["gtceu:ram_chip"] = { 2, 5 },
    ["minecraft:gold_ingot"] = { 3, 1 },
    ["gtceu:aluminium_ingot"] = { 3, 2 },
    ["gtceu:stainless_steel_ingot"] = { 3, 3 },
    ["gtceu:polyethylene_foil"] = { 4, 1 },
    ["gtceu:polyvinyl_chloride_foil"] = { 4, 2 },
    ["gtceu:silicon_plate"] = { 5, 1 },
    ["gtceu:dense_silicon_plate"] = { 5, 2 },
    ["gtceu:diamond_plate"] = { 5, 3 },
    ["gtceu:exquisite_quartzite_gem"] = { 6, 1 },
    ["gtceu:exquisite_nether_quartz_gem"] = { 6, 2 },
    ["gtceu:exquisite_certus_quartz_gem"] = { 6, 3 },
    ["minecraft:redstone"] = { 7, 1 },
    ["tfg:silica_aerogel"] = { 7, 2 },
}

local function sortKey(name)
    local o = ORDER[tostring(name or "")]
    if o then
        return o[1] * 100 + o[2]
    end
    return 9000
end

function monitor_ui.sortRows(rows)
    rows = rows or {}
    local out = {}
    for i = 1, #rows do
        out[i] = rows[i]
    end
    table.sort(out, function(a, b)
        local ka, kb = sortKey(a and a.name), sortKey(b and b.name)
        if ka ~= kb then
            return ka < kb
        end
        return tostring(a and a.name or "") < tostring(b and b.name or "")
    end)
    return out
end

local MODE_RU = {
    OK = "норма",
    WARN = "внимание",
    ALARM = "тревога",
    GREEN = "внимание",
    RED = "тревога",
}

local ERROR_RU = {
    ["no moon host"] = "луна не в сети",
    ["no stock_res"] = "луна не ответила",
    ["moon unreachable"] = "луна недоступна",
    ["no meBridge"] = "нет ME-моста",
    ["no loaders"] = "нет лоадеров",
    ["no relay"] = "нет реле",
    ["no relay pulse"] = "реле не сработало",
    ["ITEM_NOT_FOUND"] = "нет такого предмета",
    ["not craftable"] = "нельзя скрафтить",
}

local function ulen(s)
    s = tostring(s or "")
    if utf8 and utf8.len then
        local n = utf8.len(s)
        if n then
            return n
        end
    end
    local n, i = 0, 1
    local len = #s
    while i <= len do
        local b = s:byte(i)
        if not b or b < 128 then
            i = i + 1
        elseif b < 224 then
            i = i + 2
        elseif b < 240 then
            i = i + 3
        else
            i = i + 4
        end
        n = n + 1
    end
    return n
end

local function usub(s, count)
    if count <= 0 then
        return ""
    end
    if utf8 and utf8.offset then
        local i = utf8.offset(s, count + 1)
        if not i then
            return s
        end
        return s:sub(1, i - 1)
    end
    local n, i = 0, 1
    local len = #s
    while i <= len and n < count do
        local b = s:byte(i)
        if not b or b < 128 then
            i = i + 1
        elseif b < 224 then
            i = i + 2
        elseif b < 240 then
            i = i + 3
        else
            i = i + 4
        end
        n = n + 1
    end
    return s:sub(1, i - 1)
end

local function fit(s, width)
    s = tostring(s or "")
    if ulen(s) <= width then
        return s
    end
    if width <= 1 then
        return usub(s, width)
    end
    return usub(s, width - 1) .. "…"
end

local function ljust(s, width)
    s = fit(s, width)
    return s .. string.rep(" ", width - ulen(s))
end

local function rjust(s, width)
    s = fit(s, width)
    return string.rep(" ", width - ulen(s)) .. s
end

function monitor_ui.itemLabel(id)
    id = tostring(id or "")
    local known = NAMES[id]
    if known then
        return known
    end
    local short = id:match("([^:/]+)$") or id
    short = short:gsub("_", " ")
    return short
end

local function errorLabel(err)
    err = tostring(err or "")
    if ERROR_RU[err] then
        return ERROR_RU[err]
    end
    local pulse = err:match("^импульс: (.+)$") or err:match("^pulse: (.+)$")
    if pulse then
        return "импульс: " .. (ERROR_RU[pulse] or pulse)
    end
    local buffer = err:match("^буфер пропал: (.+)$") or err:match("^buffer missing: (.+)$")
    if buffer then
        return "буфер пропал: " .. buffer
    end
    -- "золото: ITEM_NOT_FOUND" → "золото: нет такого предмета"
    local prefix, code = err:match("^(.+): ([%w_]+)$")
    if prefix and code and ERROR_RU[code] then
        return prefix .. ": " .. ERROR_RU[code]
    end
    if err:find("ITEM_NOT_FOUND", 1, true) then
        return err:gsub("ITEM_NOT_FOUND", ERROR_RU.ITEM_NOT_FOUND)
    end
    return err
end

local function fmtNum(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(n)
    if #s <= 6 then
        return s
    end
    if n >= 1000000 then
        return string.format("%.1fм", n / 1000000)
    end
    return string.format("%.0fк", n / 1000)
end

local function colWidth(header, values, minW)
    local w = math.max(minW or 1, ulen(header))
    for i = 1, #values do
        local n = ulen(values[i])
        if n > w then
            w = n
        end
    end
    return w
end

--- Moon stock color for item/Луна/Цель: ALARM <25%, WARN <100%, OK >=100%.
function monitor_ui.stockColor(moon, target, zone)
    if zone == "?" then
        return colors.lightGray
    end
    moon = tonumber(moon) or 0
    target = tonumber(target) or 0
    if target <= 0 then
        return colors.lime
    end
    if moon >= target then
        return colors.lime
    end
    if moon < math.floor(target * 0.25) then
        return colors.red
    end
    return colors.yellow
end

-- Soft bounce for live phases so the header does not look frozen.
-- Fixed width (4 cells) keeps the rest of the title from shifting.
local PULSE_FRAMES = { " ·  ", " ·· ", " ···", " ·· " }

function monitor_ui.phasePulseIndex(phase, clock)
    phase = tostring(phase or "")
    if phase ~= "poll" and phase ~= "idle" then
        return nil
    end
    clock = tonumber(clock) or os.clock()
    return (math.floor(clock * 2.5) % #PULSE_FRAMES) + 1
end

function monitor_ui.phasePulseSuffix(phase, clock)
    local i = monitor_ui.phasePulseIndex(phase, clock)
    if not i then
        return ""
    end
    return PULSE_FRAMES[i]
end

--- Status cell text + color from crafting / staged / AE availability.
-- phase "cooldown" (пауза): staged cargo was fired → «Отправлено», same yellow.
function monitor_ui.statusCell(row, phase)
    row = row or {}
    local staged = math.max(0, math.floor(tonumber(row.staged) or 0))
    local crafting = math.max(0, math.floor(tonumber(row.crafting) or 0))
    local ae = tostring(row.ae or row.craft or "")
    if staged > 0 then
        if phase == "cooldown" then
            return ("Отправлено (%d)"):format(staged), colors.yellow
        end
        return ("Загрузка (%d)"):format(staged), colors.yellow
    end
    if crafting > 0 then
        return ("Крафт (%d)"):format(crafting), colors.yellow
    end
    if ae == "no" or ae == "fail" then
        return "Нет в AE", colors.red
    end
    return "-", colors.white
end

-- setTextScale clears the monitor in CC — call once per peripheral name, never on rescan/rewrap.
local scaledNames = {}

function monitor_ui.wrap(name)
    if not name or not peripheral.isPresent(name) then
        return nil
    end
    local mon = peripheral.wrap(name)
    if not mon or type(mon.setCursorPos) ~= "function" then
        return nil
    end
    name = tostring(name)
    if not scaledNames[name] then
        pcall(function()
            mon.setTextScale(0.5)
        end)
        scaledNames[name] = true
    end
    mon._moonSupplyScale = 0.5
    mon._moonSupplyName = name
    return mon
end

-- Fixed band under the program header so the item table never jumps when messages appear.
local SYS_LINES = 2
local SYS_Y0 = 3 -- lines 3..4; table header at 5

--- state: { phase, mode, error, messages={...}, wait_item, rows=[...],
--          loaders_full, loaders_total, craft_left, craft_total, staged_total }
function monitor_ui.draw(mon, state)
    if not mon then
        return
    end
    state = state or {}
    local w, h = mon.getSize()
    w = tonumber(w) or 0
    h = tonumber(h) or 0

    -- Skip rewriting lines that did not change (avoids visible "rebuild" flash).
    local lineCache = mon._moonSupplyLineCache
    if not lineCache or lineCache.w ~= w or lineCache.h ~= h then
        lineCache = { w = w, h = h }
        mon._moonSupplyLineCache = lineCache
    end

    local function writeSeg(x, y, text, fg)
        if y < 1 or y > h or w < 1 or x > w then
            return x
        end
        mon.setCursorPos(x, y)
        mon.setTextColor(fg or colors.white)
        mon.setBackgroundColor(colors.black)
        local room = w - x + 1
        local s = fit(tostring(text or ""), room)
        mon.write(s)
        return x + ulen(s)
    end

    -- Overwrite in place (no mon.clear) — clears remainder of the line to kill flicker.
    local function finishLine(x, y)
        if y < 1 or y > h or x > w then
            return
        end
        if x < 1 then
            x = 1
        end
        mon.setCursorPos(x, y)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.black)
        mon.write(string.rep(" ", w - x + 1))
    end

    local function writeParts(y, parts)
        local fp = tostring(y)
        for i = 1, #parts do
            local p = parts[i]
            fp = fp .. "\0" .. tostring(p[1]) .. "\0" .. tostring(p[2] or "")
        end
        if lineCache[y] == fp then
            return
        end
        lineCache[y] = fp
        local x = 1
        for i = 1, #parts do
            local p = parts[i]
            x = writeSeg(x, y, p[1], p[2])
            if x > w then
                break
            end
        end
        finishLine(x, y)
    end

    local function blankLine(y)
        local fp = tostring(y) .. "\0"
        if lineCache[y] == fp then
            return
        end
        lineCache[y] = fp
        finishLine(1, y)
    end

    local modeKey = state.mode or "OK"
    local mode = MODE_RU[modeKey] or tostring(modeKey)
    local phaseKey = state.phase or "poll"
    -- Title stays short. Craft timer / blockers / skip notes live in the sys status band.
    local title = { { "снабжение [" .. mode .. "] ", colors.white } }
    if phaseKey == "craft_wait" then
        title[#title + 1] = { "ожидание", colors.yellow }
        title[#title + 1] = { monitor_ui.phasePulseSuffix("poll", state.clock), colors.lightGray }
    elseif phaseKey == "loading" then
        title[#title + 1] = { "загрузка", colors.yellow }
    elseif phaseKey == "settle" then
        title[#title + 1] = { "пуск", colors.yellow }
    elseif phaseKey == "fire" then
        title[#title + 1] = { "выстрел", colors.yellow }
    elseif phaseKey == "cooldown" then
        title[#title + 1] = { "пауза", colors.white }
        if state.craft_left then
            title[#title + 1] = { (" %.0f с"):format(state.craft_left), colors.lightGray }
        end
    elseif phaseKey == "idle" then
        title[#title + 1] = { "покой", colors.white }
        title[#title + 1] = { monitor_ui.phasePulseSuffix(phaseKey, state.clock), colors.lightGray }
    else
        title[#title + 1] = { "опрос", colors.white }
        title[#title + 1] = { monitor_ui.phasePulseSuffix(phaseKey, state.clock), colors.lightGray }
    end
    writeParts(1, title)

    local craftTotal = math.floor(tonumber(state.craft_total) or 0)
    local stagedTotal = math.floor(tonumber(state.staged_total) or 0)
    local meta = {
        {
            ("лоадеры %s/%s  "):format(
                tostring(state.loaders_full or "?"),
                tostring(state.loaders_total or "?")
            ),
            colors.lightGray,
        },
        { "крафт", colors.yellow },
        { (" %d  "):format(craftTotal), colors.lightGray },
        { "к запуску", colors.yellow },
        { (" %d"):format(stagedTotal), colors.lightGray },
    }
    writeParts(2, meta)

    -- Reserved STATUS band (always SYS_LINES tall): phase detail, blockers, errors.
    local msgs = {}
    local seen = {}
    local function pushMsg(raw, keepRaw)
        raw = tostring(raw or "")
        if raw == "" or seen[raw] then
            return
        end
        seen[raw] = true
        msgs[#msgs + 1] = keepRaw and raw or errorLabel(raw)
    end
    if type(state.messages) == "table" then
        for i = 1, #state.messages do
            pushMsg(state.messages[i], true)
        end
    end
    -- craft_wait timer also mirrored here when controller did not push messages yet
    if phaseKey == "craft_wait" and state.craft_left and #msgs < SYS_LINES then
        pushMsg(("ожидание AE %d с"):format(state.craft_left), true)
    end
    if state.wait_item and tostring(state.wait_item) ~= "" and #msgs < SYS_LINES then
        pushMsg("ждём: " .. monitor_ui.itemLabel(state.wait_item), true)
    end
    pushMsg(state.error, false)
    for i = 1, SYS_LINES do
        local ySys = SYS_Y0 + i - 1
        local text = msgs[i]
        if text then
            local fg = colors.lightGray
            if state.error and errorLabel(state.error) == text then
                fg = colors.orange
            elseif text:find("нет в AE", 1, true) or text:find("не шлём", 1, true) then
                fg = colors.orange
            end
            writeParts(ySys, { { text, fg } })
        else
            blankLine(ySys)
        end
    end

    -- Caller owns order (cfg skeleton sorted once). Do not re-sort every paint.
    local rows = state.rows or {}
    local labels, moons, targets, earths, statuses, stockColors, statusColors =
        {}, {}, {}, {}, {}, {}, {}
    for i = 1, #rows do
        local r = rows[i]
        labels[i] = r.label or monitor_ui.itemLabel(r.name)
        if r.zone == "?" then
            moons[i] = "н/д"
        else
            moons[i] = fmtNum(r.moon)
        end
        targets[i] = fmtNum(r.target)
        earths[i] = fmtNum(r.earth)
        local st, sc = monitor_ui.statusCell(r, phaseKey)
        statuses[i] = st
        statusColors[i] = sc
        stockColors[i] = monitor_ui.stockColor(r.moon, r.target, r.zone)
    end

    local headName = "Предмет"
    local headMoon = "Луна"
    local headTarget = "Цель"
    local headEarth = "Земля"
    local headStatus = "Статус"
    local moonW = colWidth(headMoon, moons, 4)
    local targetW = colWidth(headTarget, targets, 4)
    local earthW = colWidth(headEarth, earths, 5)
    -- Floor status width so short/long labels do not shift columns every paint.
    local statusW = colWidth(headStatus, statuses, ulen("Отправлено (9999)"))
    -- Sticky widths: expand only, never shrink mid-session (column dance looks like rebuild).
    local layout = mon._moonSupplyLayout
    if not layout or layout.monW ~= w then
        layout = {
            monW = w,
            moonW = moonW,
            targetW = targetW,
            earthW = earthW,
            statusW = statusW,
        }
        mon._moonSupplyLayout = layout
    else
        layout.moonW = math.max(layout.moonW, moonW)
        layout.targetW = math.max(layout.targetW, targetW)
        layout.earthW = math.max(layout.earthW, earthW)
        layout.statusW = math.max(layout.statusW, statusW)
    end
    moonW, targetW, earthW, statusW =
        layout.moonW, layout.targetW, layout.earthW, layout.statusW
    local gaps = 4
    local nameW = w - moonW - targetW - earthW - statusW - gaps
    if nameW < 8 then
        nameW = 8
    end

    local function writeProps(y, name, moon, target, earth, status, cName, cMoon, cTarget, cEarth, cStatus)
        local fp = table.concat({
            tostring(y),
            tostring(name), tostring(moon), tostring(target), tostring(earth), tostring(status),
            tostring(cName), tostring(cMoon), tostring(cTarget), tostring(cEarth), tostring(cStatus),
            tostring(nameW), tostring(moonW), tostring(targetW), tostring(earthW), tostring(statusW),
        }, "\0")
        if lineCache[y] == fp then
            return
        end
        lineCache[y] = fp
        local x = 1
        x = writeSeg(x, y, ljust(name, nameW), cName)
        x = writeSeg(x, y, " ", cName)
        x = writeSeg(x, y, rjust(moon, moonW), cMoon)
        x = writeSeg(x, y, " ", cMoon)
        x = writeSeg(x, y, rjust(target, targetW), cTarget)
        x = writeSeg(x, y, " ", cTarget)
        x = writeSeg(x, y, rjust(earth, earthW), cEarth)
        x = writeSeg(x, y, " ", cEarth)
        x = writeSeg(x, y, ljust(status, statusW), cStatus)
        finishLine(x, y)
    end

    local y = SYS_Y0 + SYS_LINES
    writeProps(
        y,
        headName, headMoon, headTarget, headEarth, headStatus,
        colors.gray, colors.gray, colors.gray, colors.gray, colors.gray
    )
    y = y + 1

    for i = 1, #rows do
        if y > h then
            break
        end
        local sc = stockColors[i]
        writeProps(
            y,
            labels[i], moons[i], targets[i], earths[i], statuses[i],
            sc, sc, sc, colors.white, statusColors[i]
        )
        y = y + 1
    end
    while y <= h do
        blankLine(y)
        y = y + 1
    end
end

return monitor_ui
