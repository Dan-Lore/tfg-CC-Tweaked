-- GTCEU Distillation Tower controller (CC: Tweaked / TFG).
-- Smart maintain: per-tank % from recipe cycles × output / capacity (+ floor/cap + CD).
-- Copy main.lua + ui.lua onto the computer (same folder).

local ui = require("ui")

-- ========================= CONFIG =========================
local TOWER_NAME = "gtceu:distillation_tower_0"
local TOWER_SUBSTR = "distillation_tower"
local TANK_SUBSTR = "super_tank" -- also matches mv_/hv_…; quantum_tank via TANK_ALSO
local TANK_ALSO = "quantum_tank"
local MONITOR_SIDE = "top"

-- Fallback flat band if fluid has no recipe entry.
local THRESHOLD_LOW = 0.12
local THRESHOLD_HIGH = 0.18

-- Smart: target_mB = cycles * recipe_out, then / capacity → %, clamp [MIN, MAX].
-- Rare gases (1k/cycle) → low %; bulk CO2 (80k) → higher % of its tank.
local SMART_MAINTAIN = true
local CYCLES_LOW = 100   -- turn ON if any tank below this many cycles of stock
local CYCLES_HIGH = 160  -- turn OFF when every tank has at least this many
local MIN_RATIO = 0.08   -- never keep tanks emptier than 8% (visible buffer)
local MAX_RATIO = 0.30   -- never demand more than 30% (avoids endless fill)
local HYST_MIN = 0.05    -- highTh at least lowTh + 5%

-- After OFF: wait before re-enable (unless emergency < 40% of lowTh).
local COOLDOWN_SEC = 90
local MIN_RUN_SEC = 110  -- stay ON at least ~1 recipe (100s) once started
local EMERGENCY_FRAC = 0.40

-- mB per distillation cycle (your tower recipe).
local RECIPE_OUTPUT_MB = {
    carbon_dioxide = 80000,
    nitrogen = 7000,
    argon = 5000,
    oxygen = 3000,
    krypton = 1000,
    neon = 1000,
    xenon = 1000,
}

-- Optional absolute ratio overrides (fluid suffix or tank index _N).
-- Rare gases: keep only a thin buffer — don't chase 13%.
local FLUID_RATIO_OVERRIDE = {
    krypton = { low = 0.015, high = 0.02 },
    neon = { low = 0.015, high = 0.02 },
    xenon = { low = 0.015, high = 0.02 },
}
local TANK_INDEX_RATIO = {}

local POLL_SEC = 2
local BOOT_WAIT_SEC = 120
local BOOT_POLL_SEC = 2

-- GT Super/Quantum tank: 4000 * 1000 * 2^(tier-1) mB (GTCEu Modern)
local TIER_BASE_MB = 4000 * 1000
local TIER_FROM_NAME = {
    ulv = 0, lv = 1, mv = 2, hv = 3, ev = 4, iv = 5,
    luv = 6, zpm = 7, uv = 8, uhv = 9, uev = 10, uiv = 11,
    uxv = 12, opv = 13, max = 14,
}

-- ========================= STATE =========================
local tower = nil
local towerName = nil
local tanks = {} -- { name, index, amount, capacity, ratio, fluid, capacitySrc }
local monitor = nil
local netDirty = false
local towerEnabled = false
local lastMinRatio = 1
local lastReason = "init"
local lastBindLabel = "-"
local lastBindDeficit = 0
local cooldownLeft = 0
local enabledAt = nil
local offAt = nil

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

-- ========================= CAPACITY =========================
local function capacityFromTierName(name)
    local lower = name:lower()
    local tierName = lower:match("^gtceu:(%w+)_super_tank")
        or lower:match("^gtceu:(%w+)_quantum_tank")
        or lower:match(":(%w+)_super_tank")
        or lower:match(":(%w+)_quantum_tank")
    if not tierName then
        return nil
    end
    local tier = TIER_FROM_NAME[tierName]
    if tier == nil then
        return nil
    end
    if tier < 1 then
        return TIER_BASE_MB -- ULV edge: treat as base
    end
    return TIER_BASE_MB * (2 ^ (tier - 1))
end

--- Probe capacity: tanks().capacity → getTankCapacity/getCapacity → GT tier from name → cache.
local function resolveCapacity(name, tanksTable, cached)
    if cached and cached > 0 then
        return cached, "cache"
    end

    if type(tanksTable) == "table" then
        for _, slot in pairs(tanksTable) do
            if type(slot) == "table" then
                local cap = tonumber(slot.capacity) or tonumber(slot.maxAmount) or tonumber(slot.max_amount)
                if cap and cap > 0 then
                    return cap, "tanks()"
                end
            end
        end
    end

    local methods = {
        { "getTankCapacity", 1 },
        { "getTankCapacity", 0 },
        { "getCapacity" },
        { "getFluidCapacity" },
        { "getMaxFluidAmount" },
    }
    for i = 1, #methods do
        local m = methods[i]
        local v
        if m[2] ~= nil then
            v = safeCall(name, m[1], m[2])
        else
            v = safeCall(name, m[1])
        end
        v = tonumber(v)
        if v and v > 0 then
            return v, m[1]
        end
    end

    local fromTier = capacityFromTierName(name)
    if fromTier and fromTier > 0 then
        return fromTier, "tier"
    end

    return nil, "unknown"
end

local function readTank(name, prev)
    local amount, fluid = 0, nil
    local ok, list = pcall(function()
        return peripheral.call(name, "tanks")
    end)
    if ok and type(list) == "table" then
        for _, slot in pairs(list) do
            if type(slot) == "table" and slot.amount then
                amount = amount + (tonumber(slot.amount) or 0)
                if not fluid and slot.name then
                    fluid = slot.name
                end
            end
        end
    end

    local prevCap = prev and prev.capacity or nil
    local capacity, src = resolveCapacity(name, ok and list or nil, prevCap)
    if not capacity or capacity <= 0 then
        capacity = math.max(amount, 1)
        src = src or "fallback"
    end

    local ratio = amount / capacity
    if ratio > 1 then
        ratio = 1
    end
    if ratio < 0 then
        ratio = 0
    end

    return {
        name = name,
        index = indexFromName(name) or 0,
        amount = amount,
        capacity = capacity,
        capacitySrc = src,
        ratio = ratio,
        fluid = fluid or (prev and prev.fluid) or nil,
    }
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
    if t.index ~= nil and TANK_INDEX_RATIO[t.index] then
        local o = TANK_INDEX_RATIO[t.index]
        return o.low or THRESHOLD_LOW, o.high or THRESHOLD_HIGH, "idx"
    end
    if fk and FLUID_RATIO_OVERRIDE[fk] then
        local o = FLUID_RATIO_OVERRIDE[fk]
        return o.low or THRESHOLD_LOW, o.high or THRESHOLD_HIGH, "ovr"
    end

    local out = fk and RECIPE_OUTPUT_MB[fk]
    if SMART_MAINTAIN and out and out > 0 and t.capacity and t.capacity > 0 then
        local low = (CYCLES_LOW * out) / t.capacity
        local high = (CYCLES_HIGH * out) / t.capacity
        low = clamp(low, MIN_RATIO, MAX_RATIO)
        high = clamp(high, MIN_RATIO, MAX_RATIO)
        if high < low + HYST_MIN then
            high = math.min(1, low + HYST_MIN)
        end
        return low, high, "cyc"
    end

    local low = THRESHOLD_LOW
    local high = THRESHOLD_HIGH
    if high < low + HYST_MIN then
        high = math.min(1, low + HYST_MIN)
    end
    return low, high, "flat"
end

local function enrichTank(t)
    local low, high, src = tankThresholds(t)
    t.lowTh = low
    t.highTh = high
    t.thSrc = src
    local out = fluidKey(t.fluid)
    out = out and RECIPE_OUTPUT_MB[out]
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
    t.emergency = t.ratio < (t.lowTh * EMERGENCY_FRAC)
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

-- ========================= DISCOVERY =========================
local function isProductTank(name)
    if name:find(TANK_SUBSTR, 1, true) then
        return true
    end
    if TANK_ALSO and name:find(TANK_ALSO, 1, true) then
        return true
    end
    return false
end

local function discoverTower()
    if TOWER_NAME and peripheral.isPresent(TOWER_NAME) then
        return peripheral.wrap(TOWER_NAME), TOWER_NAME
    end
    for _, name in ipairs(peripheral.getNames()) do
        if name:find(TOWER_SUBSTR, 1, true) then
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

local function discoverTanks()
    local prev = {}
    for _, t in ipairs(tanks) do
        prev[t.name] = t
    end

    local list = {}
    for _, name in ipairs(peripheral.getNames()) do
        if isProductTank(name) then
            list[#list + 1] = readTank(name, prev[name])
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

local function waitForTower(timeoutSec)
    local deadline = os.clock() + timeoutSec
    while true do
        tower, towerName = discoverTower()
        if tower then
            return true
        end
        if os.clock() >= deadline then
            return false
        end
        print("Ждём колонну... " .. networkSummary())
        sleepWatch(BOOT_POLL_SEC)
    end
end

local function waitForTanks(timeoutSec)
    local deadline = os.clock() + timeoutSec
    local lastPrint = 0
    while true do
        local list = discoverTanks()
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
            print("Ждём танки (*" .. TANK_SUBSTR .. "* / *" .. tostring(TANK_ALSO) .. "*)... "
                .. networkSummary())
            lastPrint = now
        end
        sleepWatch(BOOT_POLL_SEC)
    end
end

local function rescanNetwork(reason)
    local list = discoverTanks()
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
    local prev = {}
    for _, t in ipairs(tanks) do
        prev[t.name] = t
    end
    for i, t in ipairs(tanks) do
        if peripheral.isPresent(t.name) then
            tanks[i] = readTank(t.name, prev[t.name])
        else
            netDirty = true
        end
    end
end

-- ========================= CONTROL =========================
local function isWorking()
    local v = safeCall(towerName, "isWorkingEnabled")
    if v == nil then
        return towerEnabled
    end
    towerEnabled = v and true or false
    return towerEnabled
end

local function setWorking(state)
    safeCall(towerName, "setWorkingEnabled", state and true or false)
    local was = towerEnabled
    towerEnabled = state and true or false
    if towerEnabled and not was then
        enabledAt = os.clock()
        offAt = nil
    elseif not towerEnabled and was then
        enabledAt = nil
        offAt = os.clock()
        cooldownLeft = COOLDOWN_SEC
    end
end

local function runAge()
    if not enabledAt then
        return 0
    end
    return os.clock() - enabledAt
end

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

    local enabled = isWorking()

    if needOn then
        local blockedByCd = cooldownLeft > 0 and not anyEmergency
        local canStart = not enabled and not blockedByCd
        if canStart then
            setWorking(true)
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
            lastReason = string.format("CD %ds lim %s", math.ceil(cooldownLeft), lastBindLabel)
        end
    elseif allOkOff then
        if enabled then
            if runAge() < MIN_RUN_SEC then
                lastReason = string.format("min-run %ds", math.ceil(MIN_RUN_SEC - runAge()))
            else
                setWorking(false)
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
        towerEnabled = towerEnabled,
        cooldownLeft = cooldownLeft,
        lastBindLabel = lastBindLabel,
        lastMinRatio = lastMinRatio,
        lastReason = lastReason,
        cyclesLow = CYCLES_LOW,
        cyclesHigh = CYCLES_HIGH,
        minRatio = MIN_RATIO,
        maxRatio = MAX_RATIO,
        networkSummary = networkSummary(),
    })
end

-- ========================= MAIN =========================
local function init()
    flushEvents()
    netDirty = false

    if not waitForTower(BOOT_WAIT_SEC) then
        error("Колонна не найдена (искали " .. tostring(TOWER_NAME)
            .. " / *" .. TOWER_SUBSTR .. "*). Сеть: " .. networkSummary())
    end

    monitor = discoverMonitor()
    ui.boot(monitor, "Waiting for tanks...")

    if not waitForTanks(BOOT_WAIT_SEC) then
        print("Танки ещё не в сети после " .. BOOT_WAIT_SEC
            .. "с — ждём дальше. Сеть: " .. networkSummary())
        tanks = {}
    end

    isWorking()
    local _, allOkOff, _, worstRel = analyzeTanks()
    lastMinRatio = worstRel
    if towerEnabled and allOkOff then
        setWorking(false)
        lastReason = "boot OFF (targets ok)"
    end
end

local function main()
    print("Старт distill ctrl, ждём периферию до " .. BOOT_WAIT_SEC .. "с...")
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
        if cooldownLeft > 0 then
            cooldownLeft = math.max(0, cooldownLeft - POLL_SEC)
        end

        if netDirty or #tanks == 0 then
            if not rescanNetwork(netDirty and "hotplug" or "retry") then
                draw()
                sleepWatch(BOOT_POLL_SEC)
            end
        end

        if not tower or not towerName or not peripheral.isPresent(towerName) then
            tower, towerName = discoverTower()
        end

        if #tanks > 0 and tower then
            refreshTanks()
            updateTower()
        end

        draw()
        sleepWatch(POLL_SEC)
    end
end

local ok, err = pcall(main)
if not ok then
    print("Критическая ошибка: " .. tostring(err))
end
