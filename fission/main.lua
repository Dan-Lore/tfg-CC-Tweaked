-- Dea's Fission dual-reactor fuel maintain (TFG).
-- Bundle:  python tools/bundle_project.py fission
-- Deploy:  dist/fission.lua + fission.cfg

package.path = package.path
    .. ";/fission/?.lua;fission/?.lua;/shared/?.lua;shared/?.lua"

local configMod = require("config")
local fuels = require("fuels")
local inv = require("inv")
local ui = require("ui")
local net_watch = require("net_watch")

local cfg = configMod.load()
local mon = nil

local function readReactor(r)
    local state = {
        label = r.label,
        primary = r.primary,
        ok = false,
        running = false,
        heat = 0,
        maxHeat = 0,
        rods = 0,
        heatSum = 0,
        target = 0,
        stock = 0,
        needed = 0,
        alert = nil,
        err = nil,
        temperatureMax = 0,
    }

    if not peripheral.isPresent(r.controller) then
        state.err = "нет контроллера"
        return state
    end

    local okM, metrics = pcall(peripheral.call, r.controller, "getMetrics")
    if not okM then
        state.err = "getMetrics: " .. tostring(metrics)
        return state
    end
    if type(metrics) ~= "table" then
        state.err = "getMetrics пусто"
        return state
    end

    local okF, fuelList = pcall(peripheral.call, r.controller, "getFuels")
    if not okF then
        state.err = "getFuels: " .. tostring(fuelList)
        return state
    end

    local rods, heatSum = fuels.summarizeInstalled(fuelList)
    local wear = fuels.wearEntries(fuelList)
    local remain, maxDur = fuels.durabilityTotals(fuelList)
    local fuelDmg = tonumber(metrics.fuelDamage) or 0
    local tMax = tonumber(metrics.temperatureMax) or 0
    local heat = tonumber(metrics.heatPost) or tonumber(metrics.heatPre) or 0
    local heating = tonumber(metrics.heating) or 0
    local primaryHeat = fuels.heatOf(cfg, r.primary) or 0
    local target = fuels.targetN(tMax, primaryHeat, cfg.rod_cap)
    local mode = tostring(metrics.mode or "DEFAULT"):upper()

    local pending = inv.countPending(r.input, r.allowSet)

    -- Feed only in normal operation. COOLDOWN = post-overheat; do not add rods.
    local canFeed = (mode == "DEFAULT")

    local status, statusColor
    if mode == "COOLDOWN" then
        status, statusColor = "Охлаждение", "orange"
    elseif mode == "INCOMPLETE" then
        status, statusColor = "Не собран", "red"
        canFeed = false
    elseif rods > 0 and heating > 0 then
        status, statusColor = "Работает", "lime"
    elseif rods > 0 then
        status, statusColor = "Пауза", "yellow"
    else
        status, statusColor = "Простой", "orange"
    end

    state.ok = true
    state.rods = rods
    state.heatSum = heatSum
    state.wear = wear
    state.heat = heat
    state.maxHeat = tMax
    state.temperatureMax = tMax
    state.target = target
    state.mode = mode
    state.canFeed = canFeed
    state.status = status
    state.statusColor = statusColor
    state.running = (mode == "DEFAULT" and rods > 0 and heating > 0)
    state.pending = pending
    state.fuelDamage = fuelDmg
    state.remainDur = remain
    state.maxDur = maxDur
    state.lifePct = (maxDur > 0) and (100 * remain / maxDur) or 0
    if mode == "COOLDOWN" then
        state.etaSec = nil
        state.etaNote = "охлаждение после перегрева"
    else
        state.etaSec = fuels.etaSeconds(remain, fuelDmg)
        state.etaNote = nil
    end
    -- Do not double-feed rods waiting on the input hatch.
    state.needed = math.max(0, target - rods - pending)

    state.stock = inv.countStock(r.stock, r.allow)
    if state.needed > 0 and state.stock < state.needed then
        state.alert = "hard"
    elseif state.stock < target then
        state.alert = "soft"
    end

    return state
end

local function tickOne(r)
    local notes = {}

    -- Always drain output → AE first (depleted / spit items).
    if peripheral.isPresent(r.output) and peripheral.isPresent(cfg.ae) then
        local n = inv.drainAll(r.output, cfg.ae)
        if n > 0 then
            notes[#notes + 1] = "out→AE " .. n
        end
    end

    -- Scrub wrong fuel from input → AE (never into crates).
    if peripheral.isPresent(r.input) and peripheral.isPresent(cfg.ae) then
        local n = inv.scrubInput(r.input, r.allowSet, cfg.ae)
        if n > 0 then
            notes[#notes + 1] = "scrub→AE " .. n
        end
    end

    local state = readReactor(r)

    -- Feed only in DEFAULT mode; never during COOLDOWN (overheat recovery).
    if state.ok and state.canFeed and state.needed > 0 then
        local pushed = inv.feedRods(cfg, r, state)
        if pushed > 0 then
            notes[#notes + 1] = "feed +" .. pushed
            state = readReactor(r)
        end
    elseif state.ok and state.mode == "COOLDOWN" then
        notes[#notes + 1] = "cooldown: no feed"
    end

    state.notes = notes
    return state
end

local function main()
    print("fission: start, reactors=" .. tostring(#cfg.reactors))
    mon = select(1, ui.find(cfg))

    while true do
        local globalErr = nil
        if not peripheral.isPresent(cfg.ae) then
            globalErr = "Нет AE: " .. tostring(cfg.ae)
        end

        local states = {}
        for i = 1, #cfg.reactors do
            local r = cfg.reactors[i]
            local st = tickOne(r)
            states[i] = st
            local msg = string.format(
                "fission R%d %s rods=%d/%d heat=%.1f/%s stock=%d %s",
                i - 1,
                r.label or "",
                st.rods or 0,
                st.target or 0,
                tonumber(st.heat) or 0,
                tostring(st.maxHeat or "?"),
                st.stock or 0,
                st.alert or (st.err or "ok")
            )
            if st.notes and #st.notes > 0 then
                msg = msg .. " [" .. table.concat(st.notes, ", ") .. "]"
            end
            print(msg)
            net_watch.yieldWatch()
        end

        if not mon or not mon.getSize then
            mon = select(1, ui.find(cfg))
        end
        ui.draw(mon, cfg, states, globalErr)

        if net_watch.sleepWatch(cfg.poll) then
            mon = select(1, ui.find(cfg))
        end
    end
end

main()
