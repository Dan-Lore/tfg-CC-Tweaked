-- GTCEU Distillation Tower controller (CC: Tweaked / TFG).
-- Smart maintain: per-tank % from recipe cycles × output / capacity (+ floor/cap + CD).
-- Bundle:  python tools/bundle_project.py distill
-- Deploy:  dist/distill.lua + distill.cfg

package.path = package.path
    .. ";/distill/?.lua;distill/?.lua;/shared/?.lua;shared/?.lua"

local configMod = require("config")
local towerMod = require("tower")
local tanksMod = require("tanks")
local ui = require("ui")

local cfg, cfgPath, cfgLoaded = configMod.load()

-- ========================= STATE =========================
local tower = nil
local towerName = nil
local towerState = towerMod.newState()
local tanks = {} -- { name, index, amount, capacity, ratio, fluid, capacitySrc }
local monitor = nil
local netDirty = false
local lastMinRatio = 1
local lastReason = "init"
local lastBindLabel = "-"
local lastBindDeficit = 0

-- ========================= HELPERS =========================
local function networkSummary()
    return table.concat(peripheral.getNames(), ", ")
end

local function flushEvents()
    os.queueEvent("distill_ctrl_flush")
    while true do
        local ev = os.pullEvent()
        if ev == "distill_ctrl_flush" then
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

local function shortFluid(name, maxLen)
    maxLen = maxLen or 14
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
        return string.format("%.1fk", n / 1000)
    end
    return tostring(math.floor(n))
end

local function discoverMonitor()
    local want = cfg.monitor
    if want and peripheral.isPresent(want) then
        local m = peripheral.wrap(want)
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

-- ========================= SMART THRESHOLDS =========================
local function clamp(v, lo, hi)
    if v < lo then
        return lo
    end
    if v > hi then
        return hi
    end
    return v
end

local function fluidKey(fluid)
    if not fluid then
        return nil
    end
    return (fluid:match("([^:/]+)$") or fluid):gsub(" ", "_")
end

--- low/high fill ratios from recipe output + tank capacity.
local function tankThresholds(t)
    local fk = fluidKey(t.fluid)
    if t.index ~= nil and cfg.tank_index_ratio[t.index] then
        local o = cfg.tank_index_ratio[t.index]
        return o.low or cfg.threshold_low, o.high or cfg.threshold_high, "idx"
    end
    if fk and cfg.fluid_ratio[fk] then
        local o = cfg.fluid_ratio[fk]
        return o.low or cfg.threshold_low, o.high or cfg.threshold_high, "ovr"
    end

    local out = fk and cfg.recipe_output[fk]
    if cfg.smart_maintain and out and out > 0 and t.capacity and t.capacity > 0 then
        local low = (cfg.cycles_low * out) / t.capacity
        local high = (cfg.cycles_high * out) / t.capacity
        low = clamp(low, cfg.min_ratio, cfg.max_ratio)
        high = clamp(high, cfg.min_ratio, cfg.max_ratio)
        if high < low + cfg.hyst_min then
            high = math.min(1, low + cfg.hyst_min)
        end
        return low, high, "cyc"
    end

    local low = cfg.threshold_low
    local high = cfg.threshold_high
    if high < low + cfg.hyst_min then
        high = math.min(1, low + cfg.hyst_min)
    end
    return low, high, "flat"
end

local function enrichTank(t)
    local low, high, src = tankThresholds(t)
    t.lowTh = low
    t.highTh = high
    t.thSrc = src
    local out = fluidKey(t.fluid)
    out = out and cfg.recipe_output[out]
    t.outMb = out
    if out and out > 0 then
        t.cycles = t.amount / out
        t.coeff = out / 1000 -- display: relative to 1 bucket/cycle
    else
        t.cycles = nil
        t.coeff = 1
    end
    t.needOn = t.ratio < t.lowTh
    t.okOff = t.ratio >= t.highTh
    t.emergency = t.ratio < (t.lowTh * cfg.emergency_frac)
    if t.lowTh > 0 then
        t.relFill = t.ratio / t.lowTh
    else
        t.relFill = 1
    end
    return t
end

local function analyzeTanks()
    local needOn = false
    local allOkOff = true
    local anyEmergency = false
    local bindTank = nil
    local bindDeficit = -1
    local worstRel = 2

    for _, t in ipairs(tanks) do
        enrichTank(t)
        if t.needOn then
            needOn = true
        end
        if t.emergency then
            anyEmergency = true
        end
        if not t.okOff then
            allOkOff = false
        end
        if t.relFill < worstRel then
            worstRel = t.relFill
        end
        local deficit = t.lowTh - t.ratio
        if deficit > bindDeficit then
            bindDeficit = deficit
            bindTank = t
        end
    end

    if #tanks == 0 then
        worstRel = 1
    end
    return needOn, allOkOff, bindTank, worstRel, anyEmergency
end

-- ========================= WAIT / RESCAN =========================
local function waitForTower(timeoutSec)
    local deadline = os.clock() + timeoutSec
    while true do
        tower, towerName = towerMod.discover(cfg)
        if tower then
            return true
        end
        if os.clock() >= deadline then
            return false
        end
        print("Ждём колонну... " .. networkSummary())
        sleepWatch(cfg.boot_poll)
    end
end

local function waitForTanks(timeoutSec)
    local deadline = os.clock() + timeoutSec
    local lastPrint = 0
    while true do
        local list = tanksMod.discover(cfg, tanks)
        if #list > 0 then
            tanks = list
            netDirty = false
            return true
        end
        if os.clock() >= deadline then
            return false
        end
        local now = os.clock()
        if now - lastPrint >= 5 then
            print("Ждём танки (*" .. tostring(cfg.tank_substr) .. "* / *"
                .. tostring(cfg.tank_also) .. "*)... " .. networkSummary())
            lastPrint = now
        end
        sleepWatch(cfg.boot_poll)
    end
end

local function rescanNetwork(reason)
    local list = tanksMod.discover(cfg, tanks)
    if #list == 0 then
        if #tanks > 0 then
            print("Танки пропали из сети, ждём...")
            tanks = {}
        end
        netDirty = false
        return false
    end
    local before = #tanks
    tanks = list
    netDirty = false
    if reason and #list ~= before then
        print(("Рескан (%s): танков %d"):format(tostring(reason), #list))
    end
    return true
end

local function refreshTanks()
    if tanksMod.refresh(tanks, cfg) then
        netDirty = true
    end
end

-- ========================= CONTROL =========================
local function updateTower()
    if not towerName or not peripheral.isPresent(towerName) then
        return
    end

    local needOn, allOkOff, bindTank, worstRel, anyEmergency = analyzeTanks()
    lastMinRatio = worstRel
    if bindTank then
        lastBindLabel = shortFluid(bindTank.fluid, 12)
        lastBindDeficit = bindTank.lowTh - bindTank.ratio
    else
        lastBindLabel = "-"
        lastBindDeficit = 0
    end

    local enabled = towerMod.isWorking(towerName, towerState)

    if needOn then
        local blockedByCd = towerState.cooldownLeft > 0 and not anyEmergency
        local canStart = not enabled and not blockedByCd
        if canStart then
            towerMod.setWorking(towerName, towerState, true, cfg.cooldown)
            if bindTank then
                lastReason = string.format(
                    "ON %s %.0f%%<t%.0f%%",
                    lastBindLabel,
                    bindTank.ratio * 100,
                    bindTank.lowTh * 100
                )
            else
                lastReason = "ON need fill"
            end
            print(lastReason)
        elseif enabled then
            lastReason = "run " .. lastBindLabel
        elseif blockedByCd then
            lastReason = string.format(
                "CD %ds lim %s",
                math.ceil(towerState.cooldownLeft),
                lastBindLabel
            )
        end
    elseif allOkOff then
        if enabled then
            local age = towerMod.runAge(towerState)
            if age < cfg.min_run then
                lastReason = string.format("min-run %ds", math.ceil(cfg.min_run - age))
            else
                towerMod.setWorking(towerName, towerState, false, cfg.cooldown)
                lastReason = "OFF stock ok"
                print(lastReason)
            end
        else
            lastReason = "idle ok"
        end
    else
        -- hysteresis band: some above low, not all above high
        if enabled then
            lastReason = "hold ON " .. lastBindLabel
        else
            lastReason = "hold OFF"
        end
    end
end

-- ========================= UI =========================
local function draw()
    for i = 1, #tanks do
        enrichTank(tanks[i])
    end
    ui.draw(monitor, {
        tanks = tanks,
        towerEnabled = towerState.enabled,
        cooldownLeft = towerState.cooldownLeft,
        lastBindLabel = lastBindLabel,
        lastMinRatio = lastMinRatio,
        lastReason = lastReason,
        cyclesLow = cfg.cycles_low,
        cyclesHigh = cfg.cycles_high,
        minRatio = cfg.min_ratio,
        maxRatio = cfg.max_ratio,
        networkSummary = networkSummary(),
    })
end

-- ========================= MAIN =========================
local function init()
    flushEvents()
    netDirty = false

    if not waitForTower(cfg.boot_wait) then
        error("Колонна не найдена (искали " .. tostring(cfg.tower)
            .. " / *" .. tostring(cfg.tower_substr) .. "*). Сеть: " .. networkSummary())
    end

    monitor = discoverMonitor()
    ui.boot(monitor, "Waiting for tanks...")

    if not waitForTanks(cfg.boot_wait) then
        print("Танки ещё не в сети после " .. cfg.boot_wait
            .. "с — ждём дальше. Сеть: " .. networkSummary())
        tanks = {}
    end

    towerMod.isWorking(towerName, towerState)
    local _, allOkOff, _, worstRel = analyzeTanks()
    lastMinRatio = worstRel
    if towerState.enabled and allOkOff then
        towerMod.setWorking(towerName, towerState, false, cfg.cooldown)
        lastReason = "boot OFF (targets ok)"
    end
end

local function main()
    print("distill: cfg " .. tostring(cfgPath) .. (cfgLoaded and " (loaded)" or " (defaults)"))
    print("Старт distill ctrl, ждём периферию до " .. cfg.boot_wait .. "с...")
    init()
    print("Колонна: " .. tostring(towerName))
    print("Танков: " .. #tanks)
    for _, t in ipairs(tanks) do
        enrichTank(t)
        print(string.format(
            "  #%d %s %s/%s  %.1f%% → low%.1f%%/high%.1f%% (%s) out=%s",
            t.index,
            shortFluid(t.fluid),
            formatMb(t.amount),
            formatMb(t.capacity),
            t.ratio * 100,
            t.lowTh * 100,
            t.highTh * 100,
            tostring(t.thSrc),
            t.outMb and formatMb(t.outMb) or "?"
        ))
    end

    while true do
        if towerState.cooldownLeft > 0 then
            towerState.cooldownLeft = math.max(0, towerState.cooldownLeft - cfg.poll)
        end

        if netDirty or #tanks == 0 then
            if not rescanNetwork(netDirty and "hotplug" or "retry") then
                draw()
                sleepWatch(cfg.boot_poll)
            end
        end

        if not tower or not towerName or not peripheral.isPresent(towerName) then
            tower, towerName = towerMod.discover(cfg)
        end

        if #tanks > 0 and tower then
            refreshTanks()
            updateTower()
        end

        draw()
        sleepWatch(cfg.poll)
    end
end

local ok, err = pcall(main)
if not ok then
    print("Критическая ошибка: " .. tostring(err))
end
