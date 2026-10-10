-- GTCEU power substation controller (CC: Tweaked / TFG).
-- Bundle:  python tools/bundle_project.py power
-- Deploy:  dist/power.lua + power.cfg
--
-- Machine APIs live in adapters:
--   gas_turbine.lua, combustion_engine.lua (+ machine_common.lua)

package.path = package.path
    .. ";/power/?.lua;power/?.lua;/shared/?.lua;shared/?.lua"

local configMod = require("config")
local gasTurbine = require("gas_turbine")
local combustion = require("combustion_engine")
local common = require("machine_common")

local cfg, cfgPath, cfgLoaded = configMod.load()

-- ========================= STATE =========================
local turbines = {}
local engines = {}
local substation = nil
local substationName = nil
local monitor = nil
local monW, monH = 0, 0
local textScale = 0.5
local netDirty = false

local energyHistory = {}
local tickCounter = 0
local cooldownCounter = 0
local lastNetEuT = 0
local lastInputEuT = 0
local lastOutputEuT = 0
local netFromApi = false
-- Fill mode: enter at threshold_low (60%), exit at engine_target (95%).
-- Outside fill: turbines keep a mild deficit; ДГ only for consumption spikes.
local fillMode = false

-- ========================= HELPERS =========================
local function safeMethod(obj, method, ...)
    if not obj or type(obj[method]) ~= "function" then
        return nil
    end
    local ok, a, b, c = pcall(obj[method], obj, ...)
    if not ok then
        return nil
    end
    return a, b, c
end

local function networkSummary()
    return table.concat(peripheral.getNames(), ", ")
end

local function fmtNum(n)
    return common.fmtNum(n)
end

local function flushEvents()
    os.queueEvent("power_ctrl_flush")
    while true do
        local ev = os.pullEvent()
        if ev == "power_ctrl_flush" then
            return
        end
    end
end

local function sleepWatch(seconds)
    local timer = os.startTimer(seconds)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            return false
        elseif ev == "peripheral" or ev == "peripheral_detach" then
            netDirty = true
            return true
        end
    end
end

local function adapterFor(unit)
    if unit.kind == combustion.kind then
        return combustion
    end
    return gasTurbine
end

local function eachGen(fn)
    for _, t in ipairs(turbines) do
        fn(t)
    end
    for _, t in ipairs(engines) do
        fn(t)
    end
end

local function genCount()
    return #turbines + #engines
end

local function genLabel(unit)
    return adapterFor(unit).label(unit)
end

-- ========================= DISCOVERY =========================
local function discoverSubstation()
    if cfg.substation and peripheral.isPresent(cfg.substation) then
        return peripheral.wrap(cfg.substation), cfg.substation
    end
    for _, name in ipairs(peripheral.getNames()) do
        if name:find(cfg.substation_substr, 1, true) then
            return peripheral.wrap(name), name
        end
    end
    return nil, nil
end

local function discoverMonitor()
    local want = cfg.monitor
    if want and peripheral.isPresent(want) then
        local m = peripheral.wrap(want)
        if m and m.getSize then
            return m
        end
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            return peripheral.wrap(name)
        end
    end
    return nil
end

local function discoverAllGens()
    return gasTurbine.discover(cfg.turbine_substr),
        combustion.discover(cfg.engine_substr)
end

local function applyAllGens(tList, eList)
    turbines = gasTurbine.apply(tList, turbines)
    engines = combustion.apply(eList, engines)
    netDirty = false
end

-- ========================= MONITOR LAYOUT =========================
local COL_W = 28
local COL_GAP = 4
local TABLES_START_Y = 10

local function tableRows(n)
    n = math.max(n, 0)
    if n == 0 then
        return 0, 1
    end
    local cols = (n >= 2) and 2 or 1
    return math.ceil(n / cols), cols
end

local function layoutPlan()
    local tRows, tCols = tableRows(#turbines)
    local eRows, eCols = tableRows(#engines)
    local y = TABLES_START_Y
    local turbineHeaderY, turbineFirstY = nil, nil
    local engineHeaderY, engineFirstY = nil, nil

    if #turbines > 0 then
        turbineHeaderY = y
        turbineFirstY = y + 1
        y = turbineFirstY + tRows
    end
    if #engines > 0 then
        if #turbines > 0 then
            y = y + 1
        end
        engineHeaderY = y
        engineFirstY = y + 1
        y = engineFirstY + eRows
    end

    local useTwo = (tCols == 2) or (eCols == 2)
    return {
        tCols = tCols,
        eCols = eCols,
        colW = COL_W,
        gap = COL_GAP,
        turbineHeaderY = turbineHeaderY,
        turbineFirstY = turbineFirstY,
        engineHeaderY = engineHeaderY,
        engineFirstY = engineFirstY,
        needH = math.max(y - 1, TABLES_START_Y),
        needW = useTwo and (COL_W * 2 + COL_GAP) or 40,
    }
end

local function applyMonitorScale()
    if not monitor then
        return
    end
    local plan = layoutPlan()
    local chosen = 0.5
    if cfg.text_scale == "auto" then
        for scale = 5, 0.5, -0.5 do
            monitor.setTextScale(scale)
            local w, h = monitor.getSize()
            if w >= plan.needW and h >= plan.needH then
                chosen = scale
                break
            end
        end
    else
        chosen = cfg.text_scale
    end
    monitor.setTextScale(chosen)
    textScale = chosen
    monW, monH = monitor.getSize()
end

-- ========================= WAIT / RESCAN =========================
local function waitForSubstation(timeoutSec)
    local deadline = os.clock() + timeoutSec
    while true do
        substation, substationName = discoverSubstation()
        if substation then
            return true
        end
        if os.clock() >= deadline then
            return false
        end
        print("Ждём подстанцию... " .. networkSummary())
        sleepWatch(cfg.boot_poll)
    end
end

local function waitForGens(timeoutSec)
    local deadline = os.clock() + timeoutSec
    local lastPrint = 0
    while true do
        local tList, eList = discoverAllGens()
        if #tList > 0 or #eList > 0 then
            applyAllGens(tList, eList)
            return true
        end
        if os.clock() >= deadline then
            return false
        end
        local now = os.clock()
        if now - lastPrint >= 5 then
            print("Ждём генераторы (*" .. tostring(cfg.turbine_substr)
                .. "* / *" .. tostring(cfg.engine_substr) .. "*)... " .. networkSummary())
            lastPrint = now
        end
        sleepWatch(cfg.boot_poll)
    end
end

local function rescanNetwork(reason)
    local tList, eList = discoverAllGens()
    if #tList == 0 and #eList == 0 then
        if genCount() > 0 then
            print("Генераторы пропали из сети, ждём...")
            turbines = {}
            engines = {}
        end
        netDirty = false
        return false
    end
    local beforeT, beforeE = #turbines, #engines
    applyAllGens(tList, eList)
    if #tList ~= beforeT or #eList ~= beforeE then
        applyMonitorScale()
        if reason then
            print(("Рескан (%s): турбин %d, двигателей %d"):format(
                tostring(reason), #turbines, #engines))
        end
    end
    return true
end

local function init()
    flushEvents()
    netDirty = false

    if not waitForSubstation(cfg.boot_wait) then
        error("Подстанция не найдена. Сеть: " .. networkSummary())
    end

    monitor = discoverMonitor()
    if monitor then
        applyMonitorScale()
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.write("Ждём генераторы...")
    end

    if not waitForGens(cfg.boot_wait) then
        print("Генераторы ещё не в сети после " .. cfg.boot_wait
            .. "с — ждём дальше. Сеть: " .. networkSummary())
        turbines = {}
        engines = {}
    else
        applyMonitorScale()
    end
end

-- ========================= ENERGY =========================
local function getEnergy()
    return safeMethod(substation, "getEnergyStored") or 0
end

local function getEnergyCapacity()
    local cap = safeMethod(substation, "getEnergyCapacity") or 1
    if cap == 0 then
        return 1
    end
    return cap
end

local function getEnergyRatio()
    local energy = getEnergy()
    local capacity = getEnergyCapacity()
    return energy / capacity, energy, capacity
end

local function readSubstationFlowEuT()
    local inp = safeMethod(substation, "getInputPerSec")
    local out = safeMethod(substation, "getOutputPerSec")
    if inp == nil or out == nil then
        return nil
    end
    return inp / 20 - out / 20, inp / 20, out / 20
end

local function etaSeconds(energy, capacity, netEuT)
    if not netEuT or netEuT == 0 then
        return nil, nil
    end
    if netEuT < 0 then
        if energy <= 0 then
            return 0, "empty"
        end
        return (energy / -netEuT) / 20, "empty"
    end
    local room = capacity - energy
    if room <= 0 then
        return 0, "full"
    end
    return (room / netEuT) / 20, "full"
end

local function fmtDuration(sec)
    if sec == nil then
        return "—"
    end
    sec = math.max(0, math.floor(sec + 0.5))
    if sec < 60 then
        return sec .. "с"
    end
    if sec < 3600 then
        return math.floor(sec / 60) .. "м"
    end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if m > 0 then
        return string.format("%dч %dм", h, m)
    end
    return h .. "ч"
end

local function addEnergyMeasurement()
    local flow, inp, out = readSubstationFlowEuT()
    if flow ~= nil then
        lastNetEuT = flow
        lastInputEuT = inp
        lastOutputEuT = out
        netFromApi = true
    else
        netFromApi = false
    end

    local energy = getEnergy()
    tickCounter = tickCounter + 1
    energyHistory[#energyHistory + 1] = { energy = energy, tick = tickCounter }
    while #energyHistory > cfg.max_history do
        table.remove(energyHistory, 1)
    end

    if not netFromApi and #energyHistory >= 2 then
        local oldest = energyHistory[1]
        local newest = energyHistory[#energyHistory]
        local timeDiff = (newest.tick - oldest.tick) * cfg.measure_interval
        if timeDiff > 0 then
            lastNetEuT = ((newest.energy - oldest.energy) / timeDiff) / 20
        end
    end
end

-- ========================= CONTROL =========================
local function setWorking(unit, state, graceful, cooldownOverride)
    adapterFor(unit).setWorking(unit, state, graceful)
    if cooldownOverride ~= nil then
        cooldownCounter = cooldownOverride
    elseif unit.kind == combustion.kind then
        cooldownCounter = cfg.engine_cooldown or 2
    else
        cooldownCounter = cfg.cooldown or 20
    end
end

local function updateAllStats()
    for _, t in ipairs(turbines) do
        gasTurbine.updateStats(t, cfg.measure_interval)
    end
    for _, t in ipairs(engines) do
        combustion.updateStats(t, cfg.measure_interval, cfg.engine_rated_eut)
    end
end

local function anyEnabledStillRamping()
    for _, t in ipairs(turbines) do
        if gasTurbine.isRamping(t, cfg.ramp_speed_pct) then
            return true, t
        end
    end
    return false, nil
end

local function totalProduction()
    local sum = 0
    eachGen(function(t)
        sum = sum + (t.lastProduction or 0)
    end)
    return sum
end

--- Pick best unit from list (enable: speed/runtime/dur; disable: low prod/runtime).
local function selectBest(list, forEnable)
    local best, bestA, bestB, bestC = nil, nil, nil, nil
    for _, t in ipairs(list) do
        local mod = adapterFor(t)
        if forEnable then
            if mod.canEnable(t) then
                local speed, run, dur = t.lastSpeed or 0, t.totalRunTime or 0, t.lastDurability or 0
                if not best
                    or speed > bestA
                    or (speed == bestA and run > bestB)
                    or (speed == bestA and run == bestB and dur > bestC)
                then
                    best, bestA, bestB, bestC = t, speed, run, dur
                end
            end
        else
            if mod.isWorking(t) then
                local prod, run = t.lastProduction or 0, t.totalRunTime or 0
                if not best or prod < bestA or (prod == bestA and run < bestB) then
                    best, bestA, bestB = t, prod, run
                end
            end
        end
    end
    return best
end

local function selectTurbineToEnable()
    return selectBest(turbines, true)
end

local function selectEngineToEnable()
    return selectBest(engines, true)
end

--- Prefer shutting engines before turbines (peaker off first, base load stays).
local function selectToDisable()
    local e = selectBest(engines, false)
    if e then
        return e
    end
    return selectBest(turbines, false)
end

local function canEnableDespiteRamp(ratio, netEuT)
    return ratio < cfg.threshold_emergency or netEuT < cfg.drain_override_eut
end

local function updateCritical(ratio)
    if ratio <= cfg.threshold_critical then
        return false
    end
    -- Past target — never re-enter fill until threshold_low again
    fillMode = false
    local unit = selectToDisable()
    if unit then
        setWorking(unit, false, false)
        print("КРИТИЧНО: выключен " .. genLabel(unit))
        return true
    end
    return false
end

--- Fill mode (60%→95%): all turbines + ДГ catch-up.
--- Maintain: turbines hold a slight deficit; ДГ only when turbines can't cover.
local function updateControl()
    local ratio = getEnergyRatio()
    local net = lastNetEuT
    local fillEnter = cfg.threshold_low or 0.60
    local fillExit = cfg.engine_target or cfg.threshold_critical or 0.95
    local turbineRated = cfg.turbine_rated_eut or 9012
    local turbineDiff = turbineRated * (cfg.turbine_diff_mult or 2)
    local spikeNet = cfg.drain_override_eut or -4000
    local fillCd = cfg.fill_enable_cooldown or 2
    -- After shutting a maintain/spike ДГ, stay quiet so net wobble can't re-toggle
    local dgOffCd = cfg.engine_off_cooldown or 15

    if updateCritical(ratio) then
        return
    end
    if cooldownCounter > 0 then
        return
    end

    -- Enter fill at 60%. Exit immediately on first touch of 95% (no re-enable if we dip).
    if not fillMode and ratio <= fillEnter then
        fillMode = true
        print(("Режим заполнения (%.0f%%)"):format(ratio * 100))
    elseif fillMode and ratio >= fillExit then
        fillMode = false
        print("Заполнение завершено")
    end

    if fillMode then
        local turbineWindDown = ratio >= (cfg.threshold_high or 0.90)

        -- From 90%: start killing turbines early (cooldown + rotor inertia)
        if turbineWindDown then
            local t = selectBest(turbines, false)
            if t then
                setWorking(t, false, true, fillCd)
                print("Выключен " .. genLabel(t) .. " (с 90%)")
                return
            end
        else
            local t = selectTurbineToEnable()
            if t then
                local rampBlocked = anyEnabledStillRamping()
                    and not canEnableDespiteRamp(ratio, net)
                if not rampBlocked then
                    setWorking(t, true, nil, fillCd)
                    print("Включен " .. genLabel(t) .. " (заполнение)")
                    return
                end
            end
        end

        -- ДГ догоняют до 95%
        local e = selectEngineToEnable()
        if e then
            setWorking(e, true)
            print("Включен " .. genLabel(e) .. " (догон)")
            return
        end
        return
    end

    -- ===== MAINTAIN (outside fill) =====
    -- Turbines are base load. ДГ only if emergency / turbines exhausted.

    -- Leftover ДГ after fill or spike → park them (long cooldown = no chatter)
    local canAddTurbine = selectTurbineToEnable() ~= nil
    local needPeak = ratio < (cfg.threshold_emergency or 0.40)
        or (net < spikeNet and not canAddTurbine)

    if not needPeak then
        local e = selectBest(engines, false)
        if e then
            setWorking(e, false, true, dgOffCd)
            print("Выключен " .. genLabel(e) .. " (не нужен)")
            return
        end
    end

    -- Turbines: only step when |net| > 2× rated (avoids 9k flip-flop around 0)
    if net > turbineDiff then
        local t = selectBest(turbines, false)
        if t then
            setWorking(t, false, true)
            print("Выключен " .. genLabel(t) .. " (избыток)")
            return
        end
    elseif net < -turbineDiff then
        local rampBlocked = anyEnabledStillRamping()
            and not canEnableDespiteRamp(ratio, net)
        if not rampBlocked then
            local t = selectTurbineToEnable()
            if t then
                setWorking(t, true)
                print("Включен " .. genLabel(t) .. " (база)")
                return
            end
        end
    end

    -- Peak: turbines already maxed (or emergency) and still draining hard
    if needPeak then
        local e = selectEngineToEnable()
        if e then
            setWorking(e, true)
            print("Включен " .. genLabel(e) .. " (скачок)")
            return
        end
    end
end

-- ========================= DRAW =========================
local function writeAt(x, y, text, color)
    if y < 1 or y > monH or x > monW then
        return
    end
    if color then
        monitor.setTextColor(color)
    end
    monitor.setCursorPos(x, y)
    local room = monW - x + 1
    if #text > room then
        text = text:sub(1, room)
    end
    monitor.write(text)
    if color then
        monitor.setTextColor(colors.white)
    end
end

local function drawBar(ratio, y)
    local label = string.format("Уровень: %5.1f%% ", ratio * 100)
    local barRoom = math.max(4, monW - #label)
    local filled = math.floor(ratio * (barRoom - 2) + 1e-9)
    filled = math.max(0, math.min(barRoom - 2, filled))
    local bar = "[" .. string.rep("#", filled) .. string.rep("-", barRoom - 2 - filled) .. "]"
    writeAt(1, y, label .. bar)
end

local function drawGenTable(list, mod, headerY, firstY, cols, colW, gap)
    if #list == 0 or not headerY or not firstY then
        return
    end
    if cols == 2 and monW < (colW * 2 + gap) then
        cols = 1
    end
    writeAt(1, headerY, mod.title(cols >= 2))
    local rowsPerCol = math.ceil(#list / cols)

    for i, unit in ipairs(list) do
        local col = math.floor((i - 1) / rowsPerCol)
        local row = (i - 1) % rowsPerCol
        if col >= cols then
            break
        end
        local x = 1 + col * (colW + gap)
        local y = firstY + row
        if y > monH then
            break
        end
        local status, color = mod.status(unit, cfg.ramp_speed_pct, cfg.rotor_warn_pct)
        writeAt(x, y, mod.formatLine(unit, status), color)
    end
end

local function draw()
    if not monitor then
        return
    end

    local w, h = monitor.getSize()
    if w ~= monW or h ~= monH then
        applyMonitorScale()
    end

    monitor.clear()
    monitor.setTextColor(colors.white)

    if genCount() == 0 then
        writeAt(1, 1, "=== GTCEU POWER CTRL ===")
        writeAt(1, 3, "Ждём генераторы...", colors.yellow)
        writeAt(1, 5, networkSummary())
        return
    end

    local ratio, energy, capacity = getEnergyRatio()
    local net = lastNetEuT
    local etaSec, etaKind = etaSeconds(energy, capacity, net)

    writeAt(1, 1, "=== GTCEU POWER CTRL ===")
    writeAt(1, 3, string.format("Энергия: %s / %s EU", fmtNum(energy), fmtNum(capacity)))
    drawBar(ratio, 4)

    local netColor = colors.white
    if net > 0 then
        netColor = colors.green
    elseif net < 0 then
        netColor = colors.red
    end
    if netFromApi then
        writeAt(1, 5, string.format(
            "Баланс: %s EU/t (вход %s / выход %s)",
            fmtNum(net), fmtNum(lastInputEuT), fmtNum(lastOutputEuT)
        ), netColor)
    else
        writeAt(1, 5, string.format("Баланс: %s EU/t (история)", fmtNum(net)), netColor)
    end

    if etaKind == "empty" then
        writeAt(1, 6, "До опустошения: " .. fmtDuration(etaSec), colors.red)
    elseif etaKind == "full" then
        writeAt(1, 6, "До заполнения: " .. fmtDuration(etaSec), colors.green)
    else
        writeAt(1, 6, "Баланс стабилен", colors.white)
    end

    if fillMode then
        local tgt = (cfg.engine_target or cfg.threshold_critical or 0.95) * 100
        writeAt(1, 7, string.format("Заполнение → %.0f%%", tgt), colors.yellow)
    elseif cooldownCounter > 0 then
        writeAt(1, 7, string.format("Пауза: %dс", cooldownCounter), colors.gray)
    elseif anyEnabledStillRamping() then
        writeAt(1, 7, "Разгон (ждём)", colors.yellow)
    else
        writeAt(1, 7, "Поддержание")
    end

    writeAt(1, 8, string.format(
        "Выработка: %s EU/t  scale:%s",
        fmtNum(totalProduction()),
        tostring(textScale)
    ))

    local plan = layoutPlan()
    drawGenTable(
        turbines, gasTurbine,
        plan.turbineHeaderY, plan.turbineFirstY,
        plan.tCols, plan.colW, plan.gap
    )
    drawGenTable(
        engines, combustion,
        plan.engineHeaderY, plan.engineFirstY,
        plan.eCols, plan.colW, plan.gap
    )
end

-- ========================= MAIN =========================
local function main()
    print("power: cfg " .. tostring(cfgPath) .. (cfgLoaded and " (loaded)" or " (defaults)"))
    print("power: ждём периферию до " .. cfg.boot_wait .. "с...")
    init()
    print("Подстанция: " .. tostring(substationName))
    print(("Турбин: %d  двигателей: %d  scale:%s (%sx%s)"):format(
        #turbines, #engines, tostring(textScale), tostring(monW), tostring(monH)))
    eachGen(function(t)
        print(string.format(
            "  %s %s (id %s) enabled=%s",
            genLabel(t), t.name, tostring(t.index), tostring(t.workingEnabled)
        ))
    end)

    addEnergyMeasurement()
    updateAllStats()

    local measureCounter = 0
    while true do
        if netDirty or genCount() == 0 then
            if not rescanNetwork(netDirty and "hotplug" or "retry") then
                draw()
                sleepWatch(cfg.boot_poll)
            end
        end

        if genCount() > 0 then
            if not substation or not peripheral.isPresent(substationName) then
                substation, substationName = discoverSubstation()
            end

            if substation then
                local ratio = getEnergyRatio()
                if ratio > cfg.threshold_critical then
                    updateCritical(ratio)
                end

                -- Energy + turbine stats on measure_interval; engines every second (2s recipes)
                measureCounter = measureCounter + 1
                if measureCounter >= cfg.measure_interval then
                    addEnergyMeasurement()
                    for _, t in ipairs(turbines) do
                        gasTurbine.updateStats(t, cfg.measure_interval)
                    end
                    measureCounter = 0
                end
                for _, t in ipairs(engines) do
                    combustion.updateStats(t, 1, cfg.engine_rated_eut)
                end

                -- Control every second so engine_cooldown (~2s) can actually fire
                if ratio <= cfg.threshold_critical then
                    updateControl()
                end
            end
        end

        if cooldownCounter > 0 then
            cooldownCounter = cooldownCounter - 1
        end

        draw()
        sleepWatch(1)
    end
end

local ok, err = pcall(main)
if not ok then
    print("Критическая ошибка: " .. tostring(err))
end
