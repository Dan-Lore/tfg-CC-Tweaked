-- GTCEU large gas turbine controller for power substations (CC: Tweaked / TFG).
-- Keeps stored energy in 60–90%, respects rotor ramp inertia, minimizes switches.

-- ========================= CONFIG =========================
local SUBSTATION_NAME = "gtceu:power_substation_0"
local MONITOR_SIDE = "right"
local TURBINE_SUBSTR = "gas_large_turbine"
local SUBSTATION_SUBSTR = "power_substation"

local THRESHOLD_LOW = 0.60
local THRESHOLD_HIGH = 0.90
local THRESHOLD_CRITICAL = 0.95
local THRESHOLD_WARN = 0.75
local THRESHOLD_EMERGENCY = 0.40

-- Rotor still spinning up below this % — do not pile on more turbines
local RAMP_SPEED_PCT = 60
-- Severe drain (FE/s) overrides ramp hold
local DRAIN_OVERRIDE_FE_S = -80000

local COOLDOWN_TIME = 20
local MEASURE_INTERVAL = 5
local MAX_HISTORY = 4

-- ========================= STATE =========================
local turbines = {}
local substation = nil
local substationName = nil
local monitor = nil

local energyHistory = {}
local tickCounter = 0
local cooldownCounter = 0
local lastDelta = 0 -- FE/s over the history window

-- ========================= HELPERS =========================
local function safeCall(name, method, ...)
    local ok, a, b, c = pcall(peripheral.call, name, method, ...)
    if not ok then
        return nil
    end
    return a, b, c
end

local function indexFromName(name)
    return tonumber(name:match("_(%d+)$"))
end

local function discoverSubstation()
    if SUBSTATION_NAME and peripheral.isPresent(SUBSTATION_NAME) then
        return peripheral.wrap(SUBSTATION_NAME), SUBSTATION_NAME
    end
    for _, name in ipairs(peripheral.getNames()) do
        if name:find(SUBSTATION_SUBSTR, 1, true) then
            return peripheral.wrap(name), name
        end
    end
    return nil, nil
end

local function discoverMonitor()
    if MONITOR_SIDE and peripheral.isPresent(MONITOR_SIDE) then
        local m = peripheral.wrap(MONITOR_SIDE)
        if m and m.clear then
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

local function discoverTurbines()
    local list = {}
    for _, name in ipairs(peripheral.getNames()) do
        if name:find(TURBINE_SUBSTR, 1, true) then
            local idx = indexFromName(name)
            if idx == nil then
                idx = #list
            end
            list[#list + 1] = {
                name = name,
                index = idx,
                totalRunTime = 0,
                lastSpeed = 0,
                lastProduction = 0,
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

local function init()
    substation, substationName = discoverSubstation()
    if not substation then
        error("Подстанция не найдена (искали " .. tostring(SUBSTATION_NAME) .. " / *" .. SUBSTATION_SUBSTR .. "*)")
    end

    monitor = discoverMonitor()
    if monitor then
        monitor.clear()
        monitor.setTextScale(0.5)
    end

    turbines = discoverTurbines()
    if #turbines == 0 then
        local names = table.concat(peripheral.getNames(), ", ")
        error("Турбины не найдены (*" .. TURBINE_SUBSTR .. "*). Сеть: " .. names)
    end

    for _, t in ipairs(turbines) do
        t.workingEnabled = safeCall(t.name, "isWorkingEnabled") == true
        t.lastSpeed = 0
        if t.workingEnabled then
            t.enabledAt = os.clock()
        end
    end
end

local function getEnergy()
    return substation.getEnergyStored and substation.getEnergyStored() or 0
end

local function getEnergyCapacity()
    local cap = substation.getEnergyCapacity and substation.getEnergyCapacity() or 1
    if not cap or cap == 0 then
        return 1
    end
    return cap
end

local function getEnergyRatio()
    local energy = getEnergy()
    local capacity = getEnergyCapacity()
    return energy / capacity, energy, capacity
end

local function addEnergyMeasurement()
    local energy = getEnergy()
    tickCounter = tickCounter + 1
    energyHistory[#energyHistory + 1] = { energy = energy, tick = tickCounter }
    while #energyHistory > MAX_HISTORY do
        table.remove(energyHistory, 1)
    end
    if #energyHistory >= 2 then
        local oldest = energyHistory[1]
        local newest = energyHistory[#energyHistory]
        local timeDiff = (newest.tick - oldest.tick) * MEASURE_INTERVAL
        if timeDiff > 0 then
            lastDelta = (newest.energy - oldest.energy) / timeDiff
        end
    end
end

local function getRotorSpeed(t)
    local current = safeCall(t.name, "getRotorSpeed") or 0
    local max = safeCall(t.name, "getMaxRotorHolderSpeed") or 1
    if max == 0 then
        max = 1
    end
    return (current / max) * 100
end

local function getCurrentProduction(t)
    return safeCall(t.name, "getCurrentProduction") or 0
end

local function isWorking(t)
    local v = safeCall(t.name, "isWorkingEnabled")
    if v == nil then
        return t.workingEnabled
    end
    t.workingEnabled = v and true or false
    return t.workingEnabled
end

local function setWorking(t, state)
    safeCall(t.name, "setWorkingEnabled", state)
    t.workingEnabled = state and true or false
    if state then
        t.enabledAt = os.clock()
    else
        t.enabledAt = nil
    end
    cooldownCounter = COOLDOWN_TIME
end

local function updateTurbineStats()
    for _, t in ipairs(turbines) do
        local speed = getRotorSpeed(t)
        local production = getCurrentProduction(t)
        local active = safeCall(t.name, "isActive") == true
        isWorking(t)

        if active then
            t.totalRunTime = t.totalRunTime + MEASURE_INTERVAL
        end
        t.lastSpeed = speed
        t.lastProduction = production
        t.isActive = active
    end
end

local function anyEnabledStillRamping()
    for _, t in ipairs(turbines) do
        if t.workingEnabled and (t.lastSpeed or 0) < RAMP_SPEED_PCT then
            return true, t
        end
    end
    return false, nil
end

local function totalProduction()
    local sum = 0
    for _, t in ipairs(turbines) do
        if t.workingEnabled then
            sum = sum + (t.lastProduction or 0)
        end
    end
    return sum
end

-- Prefer already-spinning (coast) rotors, then highest lifetime runtime.
local function selectTurbineToEnable()
    local best, bestSpeed, bestRun = nil, -1, -1
    for _, t in ipairs(turbines) do
        if not isWorking(t) then
            local speed = t.lastSpeed or 0
            local run = t.totalRunTime or 0
            if speed > bestSpeed or (speed == bestSpeed and run > bestRun) then
                best, bestSpeed, bestRun = t, speed, run
            end
        end
    end
    return best
end

-- Prefer lowest production (least useful / still ramping), then lowest runtime.
local function selectTurbineToDisable()
    local best, bestProd, bestRun = nil, nil, nil
    for _, t in ipairs(turbines) do
        if isWorking(t) then
            local prod = t.lastProduction or getCurrentProduction(t)
            local run = t.totalRunTime or 0
            if not best
                or prod < bestProd
                or (prod == bestProd and run < bestRun)
            then
                best, bestProd, bestRun = t, prod, run
            end
        end
    end
    return best
end

local function canEnableDespiteRamp(ratio, delta)
    if ratio < THRESHOLD_EMERGENCY then
        return true
    end
    if delta < DRAIN_OVERRIDE_FE_S then
        return true
    end
    return false
end

local function updateTurbinesCritical(ratio)
    if ratio <= THRESHOLD_CRITICAL then
        return false
    end
    local turbine = selectTurbineToDisable()
    if turbine then
        setWorking(turbine, false)
        print("КРИТИЧНО: выключена турбина " .. turbine.index)
        return true
    end
    return false
end

local function updateTurbines()
    local ratio = getEnergyRatio()
    local delta = lastDelta

    if updateTurbinesCritical(ratio) then
        return
    end
    if cooldownCounter > 0 then
        return
    end

    local wantEnable = ratio < THRESHOLD_LOW or (ratio < THRESHOLD_WARN and delta < 0)
    local wantDisable = ratio > THRESHOLD_HIGH and delta > 0

    if wantEnable then
        local ramping = anyEnabledStillRamping()
        if ramping and not canEnableDespiteRamp(ratio, delta) then
            return
        end
        -- If already net-positive and only slightly below band, wait for ramp.
        if ramping and delta >= 0 and ratio >= THRESHOLD_EMERGENCY then
            return
        end
        local turbine = selectTurbineToEnable()
        if turbine then
            setWorking(turbine, true)
            print("Включена турбина " .. turbine.index)
        end
    elseif wantDisable then
        local turbine = selectTurbineToDisable()
        if turbine then
            setWorking(turbine, false)
            print("Выключена турбина " .. turbine.index)
        end
    end
end

local function draw()
    if not monitor then
        return
    end
    monitor.clear()
    monitor.setCursorPos(1, 1)

    local ratio, energy, capacity = getEnergyRatio()
    local delta = lastDelta
    local deltaEuT = delta / 20

    monitor.write("=== GTCEU POWER CTRL ===")
    monitor.setCursorPos(1, 3)
    monitor.write(string.format("Energy: %d / %d FE", energy, capacity))

    local barLen = 20
    local filled = math.floor(ratio * barLen + 1e-9)
    if filled > barLen then
        filled = barLen
    end
    if filled < 0 then
        filled = 0
    end
    local bar = "[" .. string.rep("#", filled) .. string.rep("-", barLen - filled) .. "]"
    monitor.setCursorPos(1, 4)
    monitor.write(string.format("Level: %5.1f%% %s", ratio * 100, bar))

    monitor.setCursorPos(1, 5)
    if delta > 0 then
        monitor.setTextColor(colors.green)
    elseif delta < 0 then
        monitor.setTextColor(colors.red)
    else
        monitor.setTextColor(colors.white)
    end
    monitor.write(string.format("Delta: %+.0f FE/s (%+.0f EU/t)", delta, deltaEuT))
    monitor.setTextColor(colors.white)

    monitor.setCursorPos(1, 6)
    if cooldownCounter > 0 then
        monitor.setTextColor(colors.gray)
        monitor.write(string.format("Cooldown: %ds", cooldownCounter))
        monitor.setTextColor(colors.white)
    else
        local ramping = anyEnabledStillRamping()
        if ramping then
            monitor.setTextColor(colors.yellow)
            monitor.write("Ramping (hold)")
            monitor.setTextColor(colors.white)
        else
            monitor.write("Ready")
        end
    end

    monitor.setCursorPos(1, 7)
    -- getCurrentProduction is EU/t; delta is FE/s (≈ EU/s)
    monitor.write(string.format("Prod: %d EU/t", totalProduction()))

    monitor.setCursorPos(1, 9)
    monitor.write("Turbines (spd%%/EU/t/run):")

    for i, t in ipairs(turbines) do
        local status = t.workingEnabled and "ON " or "OFF"
        local speed = t.lastSpeed or 0
        local runtime = math.floor((t.totalRunTime or 0) / 60)
        local prod = t.lastProduction or 0
        local color = colors.white
        if t.workingEnabled and speed < RAMP_SPEED_PCT then
            color = colors.yellow
        elseif t.workingEnabled then
            color = colors.lime
        end
        monitor.setTextColor(color)
        monitor.setCursorPos(1, 9 + i)
        monitor.write(string.format(
            " %d:[%s] %3.0f%% %5d %dm",
            t.index, status, speed, prod, runtime
        ))
        monitor.setTextColor(colors.white)
    end
end

local function main()
    init()
    print("Подстанция: " .. tostring(substationName))
    print("Турбин: " .. #turbines)
    for _, t in ipairs(turbines) do
        print(string.format("  #%d %s enabled=%s", t.index, t.name, tostring(t.workingEnabled)))
    end

    addEnergyMeasurement()
    updateTurbineStats()

    local measureCounter = 0
    while true do
        local ratio = getEnergyRatio()

        -- Critical protection every second (not only on measure ticks)
        if ratio > THRESHOLD_CRITICAL then
            updateTurbinesCritical(ratio)
        end

        measureCounter = measureCounter + 1
        if measureCounter >= MEASURE_INTERVAL then
            addEnergyMeasurement()
            updateTurbineStats()
            if ratio <= THRESHOLD_CRITICAL then
                updateTurbines()
            end
            measureCounter = 0
        end

        if cooldownCounter > 0 then
            cooldownCounter = cooldownCounter - 1
        end

        draw()
        sleep(1)
    end
end

local ok, err = pcall(main)
if not ok then
    print("Критическая ошибка: " .. tostring(err))
end
