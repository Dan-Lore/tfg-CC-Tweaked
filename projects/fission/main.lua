-- Dea's Fission multi-reactor fuel maintain (TFG).
-- Bundle:  python tools/bundle_project.py fission
-- Deploy:  dist/fission.lua + fission.cfg
-- Runtime: fission_state.txt (modes / one-cycle; overrides cfg)

package.path = package.path
    .. ";/projects/fission/?.lua;projects/fission/?.lua;/projects/shared/?.lua;projects/shared/?.lua"

local configMod = require("config")
local fuels = require("fuels")
local inv = require("inv")
local ui = require("ui")
local stateMod = require("state")
local net_watch = require("net_watch")

local cfg = configMod.load()
local runtime, statePath, loadedDump = stateMod.load(cfg)
local mon, monName = nil, nil
local hitboxes = {}
local dirtyState = false

print("fission: reactors=" .. tostring(#cfg.reactors)
    .. " dump=" .. tostring(statePath)
    .. (loadedDump and " (loaded)" or " (defaults)"))

local function saveRuntime()
    local ok, path = stateMod.save(cfg, runtime)
    if ok then
        dirtyState = false
        print("fission: saved " .. tostring(path))
    else
        print("fission: FAILED save " .. tostring(path))
    end
end

local function rtFor(r)
    local row = runtime[r.controller]
    if not row then
        row = {
            controller = r.controller,
            label = r.label,
            control = r.control or "auto",
            cycle = false,
        }
        runtime[r.controller] = row
    end
    return row
end

local function wantsFeed(r, st)
    local row = rtFor(r)
    if not st.canFeed then
        return false
    end
    if row.control == "auto" then
        return st.needed > 0
    end
    -- manual: only while one-cycle is armed
    return row.cycle and st.needed > 0
end

local function needsPelletCheck(r)
    return (tonumber(r.pellets_need) or 0) > 0 and r.pellet_bus ~= nil
end

local function pelletsOk(r)
    if not needsPelletCheck(r) then
        return true, 0
    end
    -- pellet_bus + AE interface buffer; all cfg.pellets ids (PA6 / refrigerant).
    local n = inv.countPellets(cfg, r)
    return n >= (r.pellets_need or 0), n
end

local function readReactor(r)
    local row = rtFor(r)
    local state = {
        label = r.label,
        primary = r.primary,
        ok = false,
        control = row.control,
        cycle = row.cycle,
        pellets_need = tonumber(r.pellets_need) or 0,
        pellets = 0,
        rods = 0,
        needed = 0,
        alert = nil,
        err = nil,
    }

    if not peripheral.isPresent(r.controller) then
        state.err = "нет контроллера"
        return state
    end

    local okM, metrics = pcall(peripheral.call, r.controller, "getMetrics")
    if not okM or type(metrics) ~= "table" then
        state.err = "getMetrics: " .. tostring(metrics)
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
    -- Mode from Dea's Fission enum toString(); tolerate junk whitespace.
    local mode = tostring(metrics.mode or "DEFAULT"):upper():gsub("%s+", "")
    local pending = inv.countPending(r.input, r.allowSet)

    local canFeed = (mode == "DEFAULT")
    local status, statusColor
    if mode == "COOLDOWN" then
        status, statusColor = "Охлаждение", "orange"
        canFeed = false
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
    -- Unknown mode: do not feed, but say so (avoids silent idle).
    if mode ~= "DEFAULT" and mode ~= "COOLDOWN" and mode ~= "INCOMPLETE" then
        canFeed = false
        status, statusColor = "Режим " .. mode, "red"
    end

    local pok, pelletCount = pelletsOk(r)

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
    state.pellets = pelletCount
    if mode == "COOLDOWN" then
        state.etaSec = nil
        state.etaNote = "охлаждение после перегрева"
    else
        -- Rate at heat_ss (not live heat): while warming up, live fuelDamage is
        -- low and "Осталось" looked way too long, then collapsed as heat rose.
        local etaRate = fuels.etaDamageRate(rods, heatSum, heat, fuelDmg)
        state.etaSec = fuels.etaSeconds(remain, etaRate)
        state.etaNote = nil
    end
    state.needed = math.max(0, target - rods - pending)

    state.stock = inv.countStock(r.stock, r.allow)
    if state.needed > 0 and state.stock < state.needed then
        state.alert = "hard"
    elseif state.stock < target then
        state.alert = "soft"
    end
    if needsPelletCheck(r) and not pok and (row.control == "auto" or row.cycle) then
        state.alert = "pellets"
    end

    -- Peripheral presence (stock count can be 0 when missing — surface it).
    if not peripheral.isPresent(r.stock) then
        state.feedErr = "нет склада " .. tostring(r.stock)
    elseif not peripheral.isPresent(r.input) then
        state.feedErr = "нет входа " .. tostring(r.input)
    end

    -- Manual one-cycle: disarm as soon as enough rods are in (core + input pending).
    -- Do not wait for burnout — pellets sit with spare and are unrelated to cycle end.
    if row.control == "manual" and row.cycle and target > 0
        and (rods + pending) >= target
    then
        row.cycle = false
        row._cycleStarted = false
        state.cycle = false
        dirtyState = true
    end

    return state
end

local function tickOne(r)
    local notes = {}
    local row = rtFor(r)

    if peripheral.isPresent(r.output) and peripheral.isPresent(cfg.ae) then
        local n = inv.drainAll(r.output, cfg.ae)
        if n > 0 then
            notes[#notes + 1] = "out→AE " .. n
        end
    end

    if peripheral.isPresent(r.input) and peripheral.isPresent(cfg.ae) then
        local n = inv.scrubInput(r.input, r.allowSet, cfg.ae)
        if n > 0 then
            notes[#notes + 1] = "scrub→AE " .. n
        end
    end

    local st = readReactor(r)

    -- Top up pellets while auto-running or manual cycle armed / rods present.
    local pelletActive = needsPelletCheck(r)
        and st.ok
        and (row.control == "auto" or row.cycle or (st.rods or 0) > 0)
    if pelletActive then
        local moved = inv.feedPellets(cfg, r, 16)
        if moved > 0 then
            notes[#notes + 1] = "pellet +" .. moved
            st.pellets = inv.countPellets(cfg, r)
        end
    end

    local allowRods = wantsFeed(r, st)
    if allowRods and needsPelletCheck(r) then
        local okP = select(1, pelletsOk(r))
        if not okP then
            allowRods = false
            st.alert = "pellets"
            notes[#notes + 1] = "wait pellets"
        end
    end

    if allowRods then
        local pushed = inv.feedRods(cfg, r, st)
        if pushed > 0 then
            notes[#notes + 1] = "feed +" .. pushed
            local feedErr = st.feedErr
            st = readReactor(r) -- may clear cycle once target rods are in
            st.feedErr = feedErr
        elseif st.feedErr then
            notes[#notes + 1] = "feed fail: " .. tostring(st.feedErr)
            print("fission: " .. tostring(r.label) .. " " .. tostring(st.feedErr))
        end
    elseif st.ok and st.mode == "COOLDOWN" then
        notes[#notes + 1] = "cooldown: no feed"
        if (st.needed or 0) > 0 then
            st.feedErr = st.feedErr or "охлаждение — не подаём"
        end
    elseif st.ok and not st.canFeed and (st.needed or 0) > 0 then
        st.feedErr = st.feedErr or ("режим " .. tostring(st.mode) .. " — не подаём")
    end

    st.notes = notes
    st.control = row.control
    st.cycle = row.cycle
    return st
end

local function onToggleMode(index)
    local r = cfg.reactors[index]
    if not r then
        return
    end
    local row = rtFor(r)
    if row.control == "auto" then
        row.control = "manual"
        row.cycle = false
        row._cycleStarted = false
    else
        row.control = "auto"
        row.cycle = false
        row._cycleStarted = false
    end
    dirtyState = true
    saveRuntime()
    print("fission: " .. r.label .. " → " .. row.control)
end

local function onOneCycle(index)
    local r = cfg.reactors[index]
    if not r then
        return
    end
    local row = rtFor(r)
    if row.control ~= "manual" then
        return
    end
    if row.cycle then
        -- cancel armed cycle if idle
        row.cycle = false
        row._cycleStarted = false
        dirtyState = true
        saveRuntime()
        print("fission: " .. r.label .. " цикл отменён")
        return
    end
    if needsPelletCheck(r) then
        local okP, n = pelletsOk(r)
        if not okP then
            print("fission: " .. r.label .. " мало гранул ("
                .. tostring(n) .. "/" .. tostring(r.pellets_need) .. ")")
            return
        end
    end
    local stock = inv.countStock(r.stock, r.allow)
    if stock < 1 then
        print("fission: " .. r.label .. " нет стержней в запасе")
        return
    end
    row.cycle = true
    row._cycleStarted = false
    dirtyState = true
    saveRuntime()
    print("fission: " .. r.label .. " цикл вооружён")
    -- If target already met, readReactor will disarm immediately.
end

local function handleTouch(x, y)
    local hit = ui.hit(hitboxes, x, y)
    if not hit then
        return
    end
    if hit.action == "toggle_mode" then
        onToggleMode(hit.index)
    elseif hit.action == "one_cycle" then
        onOneCycle(hit.index)
    end
end

local function redraw(states, globalErr)
    if not mon or not mon.getSize then
        mon, monName = ui.find(cfg)
    end
    hitboxes = ui.draw(mon, cfg, states, globalErr)
end

local function main()
    mon, monName = ui.find(cfg)
    if not loadedDump then
        saveRuntime()
    end

    -- Event loop matches origin/main: tick → draw → sleepWatch(poll).
    -- Do NOT start the poll timer before tickOne: yieldWatch/sleep inside
    -- inv/transfer would swallow that timer id and the UI hangs forever on
    -- a stale frame (looks like "wrong rod count").
    while true do
        local globalErr = nil
        if not peripheral.isPresent(cfg.ae) then
            globalErr = "Нет AE: " .. tostring(cfg.ae)
        end

        local states = {}
        for i = 1, #cfg.reactors do
            states[i] = tickOne(cfg.reactors[i])
            local st = states[i]
            if st.err or st.feedErr or st.alert == "hard" or st.alert == "pellets" then
                print(string.format(
                    "fission R%d %s rods=%d/%d %s",
                    i - 1,
                    st.label or "",
                    st.rods or 0,
                    st.target or 0,
                    st.feedErr or st.alert or st.err or "?"
                ))
            end
            net_watch.yieldWatch()
        end

        if dirtyState then
            saveRuntime()
        end

        redraw(states, globalErr)

        -- Wait poll interval. On touch: apply action and break into a full tick.
        -- Do NOT readReactor/count here — transfer.countItem uses sleep(0), which
        -- discards our poll timer and freezes the UI on a stale frame.
        local timer = os.startTimer(cfg.poll)
        while true do
            local ev, a, b, c = os.pullEvent()
            if ev == "timer" and a == timer then
                break
            elseif ev == "monitor_touch" and (not monName or a == monName or a == cfg.monitor) then
                handleTouch(b, c)
                break
            elseif ev == "peripheral" or ev == "peripheral_detach" then
                mon, monName = ui.find(cfg)
            end
        end
    end
end

main()
