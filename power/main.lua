-- GTCEU large gas turbine controller for power substations (CC: Tweaked / TFG).
-- Bundle:  python tools/bundle_project.py power
-- Deploy:  dist/power.lua + power.cfg

package.path = package.path
    .. ";/power/?.lua;power/?.lua;/shared/?.lua;shared/?.lua"

local configMod = require("config")

local cfg, cfgPath, cfgLoaded = configMod.load()

-- ========================= STATE =========================
local turbines = {} -- gas_large_turbine
local engines = {}  -- extreme_combustion_engine
local substation = nil
local substationName = nil
local monitor = nil
local monW, monH = 0, 0
local textScale = 0.5
local netDirty = false

local energyHistory = {}
local tickCounter = 0
local cooldownCounter = 0
local lastNetEuT = 0 -- preferred: input - output from substation
local lastInputEuT = 0
local lastOutputEuT = 0
local netFromApi = false -- true when getInput/OutputPerSec worked

-- ========================= HELPERS =========================
local function safeCall(name, method, ...)
    local ok, a, b, c = pcall(peripheral.call, name, method, ...)
    if not ok then
        return nil
    end
    return a, b, c
end

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

local function indexFromName(name)
    return tonumber(name:match("_(%d+)$"))
end

local function networkSummary()
    return table.concat(peripheral.getNames(), ", ")
end

local function fmtNum(n)
    n = tonumber(n) or 0
    local sign = n < 0 and "-" or ""
    local a = math.abs(n)
    if a >= 1e9 then
        return sign .. string.format("%.2fG", a / 1e9)
    elseif a >= 1e6 then
        return sign .. string.format("%.2fM", a / 1e6)
    elseif a >= 1e4 then
        return sign .. string.format("%.1fk", a / 1e3)
    end
    return sign .. string.format("%.0f", a)
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

local function discoverBySubstr(substr, kind)
    local list = {}
    if not substr or substr == "" then
        return list
    end
    for _, name in ipairs(peripheral.getNames()) do
        if name:find(substr, 1, true) then
            local idx = indexFromName(name)
            if idx == nil then
                idx = #list
            end
            list[#list + 1] = {
                name = name,
                index = idx,
                kind = kind, -- "turbine" | "engine"
                totalRunTime = 0,
                lastSpeed = 0,
                lastProduction = 0,
                lastDurability = 100,
                hasRotor = true,
                isActive = false,
                workingEnabled = false,
                enabledAt = nil,
            }
        end
    end
    table.sort(list, function(a, b)
        if a.index == b.index then
            return a.name < b.name
        end
        return a.index < b.index
    end)
    return list
end

local function syncWorkingFlags(list)
    for _, t in ipairs(list) do
        t.workingEnabled = safeCall(t.name, "isWorkingEnabled") == true
        if t.workingEnabled and not t.enabledAt then
            t.enabledAt = os.clock()
        elseif not t.workingEnabled then
            t.enabledAt = nil
        end
    end
end

local function applyGenList(list, prevList)
    local prev = {}
    for _, t in ipairs(prevList) do
        prev[t.name] = t
    end
    for _, t in ipairs(list) do
        local old = prev[t.name]
        if old then
            t.totalRunTime = old.totalRunTime
            t.lastSpeed = old.lastSpeed
            t.lastProduction = old.lastProduction
            t.lastDurability = old.lastDurability
            t.enabledAt = old.enabledAt
        end
    end
    syncWorkingFlags(list)
    for i, t in ipairs(list) do
        t.slot = i
    end
    return list
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

local function discoverAllGens()
    return discoverBySubstr(cfg.turbine_substr, "turbine"),
        discoverBySubstr(cfg.engine_substr, "engine")
end

local function applyAllGens(tList, eList)
    turbines = applyGenList(tList, turbines)
    engines = applyGenList(eList, engines)
    netDirty = false
end

-- ========================= MONITOR SCALE / LAYOUT =========================
local TURBINE_COL_W = 28
local TURBINE_COL_GAP = 4
-- Status block ends at line 8; tables start at 10
local TABLES_START_Y = 10

local function tableRows(n)
    n = math.max(n, 0)
    if n == 0 then
        return 0, 1
    end
    local cols = (n >= 2) and 2 or 1
    return math.ceil(n / cols), cols
end

--- Gas turbines table, then combustion engines table below (both 2-col).
local function layoutPlan()
    local tRows, tCols = tableRows(#turbines)
    local eRows, eCols = tableRows(#engines)
    local gap = TURBINE_COL_GAP
    local y = TABLES_START_Y
    local turbineHeaderY, turbineFirstY = nil, nil
    local engineHeaderY, engineFirstY = nil, nil

    if #turbines > 0 then
        turbineHeaderY = y
        turbineFirstY = y + 1
        y = turbineFirstY + tRows -- next free line after last turbine row
    end
    if #engines > 0 then
        if #turbines > 0 then
            y = y + 1 -- blank between tables
        end
        engineHeaderY = y
        engineFirstY = y + 1
        y = engineFirstY + eRows
    end

    local useTwo = (tCols == 2) or (eCols == 2)
    return {
        tCols = tCols,
        eCols = eCols,
        colW = TURBINE_COL_W,
        gap = gap,
        turbineHeaderY = turbineHeaderY,
        turbineFirstY = turbineFirstY,
        engineHeaderY = engineHeaderY,
        engineFirstY = engineFirstY,
        needH = math.max(y - 1, TABLES_START_Y),
        needW = useTwo and (TURBINE_COL_W * 2 + gap) or 40,
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
            print("Ждём генераторы (*" .. cfg.turbine_substr
                .. "* / *" .. cfg.engine_substr .. "*)... " .. networkSummary())
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

--- Substation getInput/OutputPerSec: name says PerSec; GT tooltips say EU/t,
--- but values match EU/s vs the cover UI (÷20 ≈ «Вывод в среднем» EU/t).
local function readSubstationFlowEuT()
    local inp = safeMethod(substation, "getInputPerSec")
    local out = safeMethod(substation, "getOutputPerSec")
    if inp == nil or out == nil then
        return nil
    end
    local inpT, outT = inp / 20, out / 20
    return inpT - outT, inpT, outT
end

--- Seconds until empty (net<0) or full (net>0), or nil if N/A.
local function etaSeconds(energy, capacity, netEuT)
    if not netEuT or netEuT == 0 then
        return nil, nil
    end
    if netEuT < 0 then
        if energy <= 0 then
            return 0, "empty"
        end
        -- EU / (EU/t) = ticks; ticks/20 = seconds
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
            -- ΔEU/s → EU/t
            lastNetEuT = ((newest.energy - oldest.energy) / timeDiff) / 20
        end
    end
end

-- ========================= TURBINES =========================
local function getRotorSpeed(t)
    local current = safeCall(t.name, "getRotorSpeed") or 0
    local max = safeCall(t.name, "getMaxRotorHolderSpeed") or 1
    if max == 0 then
        max = 1
    end
    return (current / max) * 100
end

local function isWorking(t)
    local v = safeCall(t.name, "isWorkingEnabled")
    if v == nil then
        return t.workingEnabled
    end
    t.workingEnabled = v and true or false
    return t.workingEnabled
end

local function setWorking(t, state, graceful)
    if state then
        safeCall(t.name, "setSuspendAfterFinish", false)
        safeCall(t.name, "setWorkingEnabled", true)
        t.workingEnabled = true
        t.enabledAt = os.clock()
    else
        if graceful then
            -- Finish current cycle before stopping (less thrash / fuel waste)
            safeCall(t.name, "setSuspendAfterFinish", true)
            safeCall(t.name, "setWorkingEnabled", false)
        else
            safeCall(t.name, "setWorkingEnabled", false)
        end
        t.workingEnabled = false
        t.enabledAt = nil
    end
    cooldownCounter = cfg.cooldown
end

local function updateOneGenStats(t)
    t.isActive = safeCall(t.name, "isActive") == true
    t.lastProduction = safeCall(t.name, "getCurrentProduction") or 0
    isWorking(t)

    if t.kind == "engine" then
        -- Combustion engines: no rotor; treat as ramped when actively producing
        t.hasRotor = true
        t.lastDurability = 100
        if t.workingEnabled and (t.isActive or (t.lastProduction or 0) > 0) then
            t.lastSpeed = 100
        else
            t.lastSpeed = 0
        end
    else
        local has = safeCall(t.name, "hasRotor")
        t.hasRotor = (has ~= false)
        t.lastSpeed = getRotorSpeed(t)
        t.lastDurability = safeCall(t.name, "getRotorDurabilityPercent") or t.lastDurability or 100
    end

    if t.isActive then
        t.totalRunTime = t.totalRunTime + cfg.measure_interval
    end
end

local function updateTurbineStats()
    eachGen(updateOneGenStats)
end

local function anyEnabledStillRamping()
    -- Only gas turbines have multi-minute rotor ramp
    for _, t in ipairs(turbines) do
        if t.workingEnabled and (t.lastSpeed or 0) < cfg.ramp_speed_pct then
            return true, t
        end
    end
    return false, nil
end

local function totalProduction()
    local sum = 0
    eachGen(function(t)
        if t.workingEnabled then
            sum = sum + (t.lastProduction or 0)
        end
    end)
    return sum
end

local function genLabel(t)
    if t.kind == "engine" then
        return "двигатель #" .. tostring(t.slot)
    end
    return "турбина #" .. tostring(t.slot)
end

local function selectTurbineToEnable()
    local best, bestSpeed, bestRun, bestDur = nil, -1, -1, -1
    eachGen(function(t)
        if not isWorking(t) and t.hasRotor ~= false then
            local speed = t.lastSpeed or 0
            local run = t.totalRunTime or 0
            local dur = t.lastDurability or 0
            -- Prefer spinning gas rotors; cold engines sort after (speed 0)
            if speed > bestSpeed
                or (speed == bestSpeed and run > bestRun)
                or (speed == bestSpeed and run == bestRun and dur > bestDur)
            then
                best, bestSpeed, bestRun, bestDur = t, speed, run, dur
            end
        end
    end)
    return best
end

local function selectTurbineToDisable()
    local best, bestProd, bestRun = nil, nil, nil
    eachGen(function(t)
        if isWorking(t) then
            local prod = t.lastProduction or 0
            local run = t.totalRunTime or 0
            if not best
                or prod < bestProd
                or (prod == bestProd and run < bestRun)
            then
                best, bestProd, bestRun = t, prod, run
            end
        end
    end)
    return best
end

local function canEnableDespiteRamp(ratio, netEuT)
    if ratio < cfg.threshold_emergency then
        return true
    end
    if netEuT < cfg.drain_override_eut then
        return true
    end
    return false
end

local function updateTurbinesCritical(ratio)
    if ratio <= cfg.threshold_critical then
        return false
    end
    local turbine = selectTurbineToDisable()
    if turbine then
        setWorking(turbine, false, false) -- immediate at critical
        print("КРИТИЧНО: выключен " .. genLabel(turbine))
        return true
    end
    return false
end

local function updateTurbines()
    local ratio = getEnergyRatio()
    local net = lastNetEuT

    if updateTurbinesCritical(ratio) then
        return
    end
    if cooldownCounter > 0 then
        return
    end

    local wantEnable = ratio < cfg.threshold_low
        or (ratio < cfg.threshold_warn and net < 0)
    local wantDisable = ratio > cfg.threshold_high and net > 0

    if wantEnable then
        local ramping = anyEnabledStillRamping()
        if ramping and not canEnableDespiteRamp(ratio, net) then
            return
        end
        if ramping and net >= 0 and ratio >= cfg.threshold_emergency then
            return
        end
        local turbine = selectTurbineToEnable()
        if turbine then
            setWorking(turbine, true)
            print("Включен " .. genLabel(turbine))
        end
    elseif wantDisable then
        local turbine = selectTurbineToDisable()
        if turbine then
            setWorking(turbine, false, true)
            print("Выключен " .. genLabel(turbine))
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

local function genStatus(t)
    if t.kind == "turbine" and not t.hasRotor then
        return "NOR", colors.red
    end
    if t.kind == "turbine" and t.workingEnabled and (t.lastSpeed or 0) < cfg.ramp_speed_pct then
        return "RMP", colors.yellow
    end
    if t.workingEnabled then
        return "ON ", colors.lime
    end
    return "OFF", colors.white
end

local function drawGenTable(list, headerY, firstY, titleFull, titleShort, cols, colW, gap, asEngine)
    if #list == 0 or not headerY or not firstY then
        return
    end
    if cols == 2 and monW < (colW * 2 + gap) then
        cols = 1
    end
    -- 2 columns → full labels; 1 column → abbreviated (fits narrow scale)
    writeAt(1, headerY, (cols >= 2) and titleFull or titleShort)
    local rowsPerCol = math.ceil(#list / cols)

    for i, t in ipairs(list) do
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

        local status, color = genStatus(t)
        local line
        if asEngine then
            line = string.format(
                "%2d:[%s] %5s %dm",
                t.slot or i,
                status,
                fmtNum(t.lastProduction or 0),
                math.floor((t.totalRunTime or 0) / 60)
            )
        else
            local dur = t.lastDurability or 0
            if t.hasRotor and dur <= cfg.rotor_warn_pct and color ~= colors.red then
                color = colors.orange
            end
            line = string.format(
                "%2d:[%s] %3.0f%% %5s %3.0f%% %dm",
                t.slot or i,
                status,
                t.lastSpeed or 0,
                fmtNum(t.lastProduction or 0),
                dur,
                math.floor((t.totalRunTime or 0) / 60)
            )
        end
        writeAt(x, y, line, color)
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

    if cooldownCounter > 0 then
        writeAt(1, 7, string.format("Пауза: %dс", cooldownCounter), colors.gray)
    else
        local ramping = anyEnabledStillRamping()
        if ramping then
            writeAt(1, 7, "Разгон (ждём)", colors.yellow)
        else
            writeAt(1, 7, "Готов")
        end
    end

    writeAt(1, 8, string.format(
        "Выработка: %s EU/t  scale:%s",
        fmtNum(totalProduction()),
        tostring(textScale)
    ))

    local plan = layoutPlan()
    drawGenTable(
        turbines,
        plan.turbineHeaderY,
        plan.turbineFirstY,
        "Турбины (скорость/EU/t/прочность/аптайм):",
        "Турбины (скр/EU/t/прч/раб):",
        plan.tCols,
        plan.colW,
        plan.gap,
        false
    )
    drawGenTable(
        engines,
        plan.engineHeaderY,
        plan.engineFirstY,
        "Двигатели (EU/t/аптайм):",
        "Двигатели (EU/t/раб):",
        plan.eCols,
        plan.colW,
        plan.gap,
        true
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
    updateTurbineStats()

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
                    updateTurbinesCritical(ratio)
                end

                measureCounter = measureCounter + 1
                if measureCounter >= cfg.measure_interval then
                    addEnergyMeasurement()
                    updateTurbineStats()
                    if ratio <= cfg.threshold_critical then
                        updateTurbines()
                    end
                    measureCounter = 0
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
