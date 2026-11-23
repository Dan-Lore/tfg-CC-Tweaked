-- Earth controller: Moon stock → craft/export → fire when the package is loaded or the loaders are full.
--
-- Bundle:  python tools/bundle_project.py moon_supply moon_supply_E_ctrl
-- Deploy:  dist/moon_supply_E_ctrl.lua + moon_supply_E_ctrl.cfg

package.path = package.path
    .. ";/projects/moon_supply/?.lua;projects/moon_supply/?.lua"
    .. ";/projects/shared/?.lua;projects/shared/?.lua"

local configMod = require("config")
local protocol = require("protocol")
local ae_bridge = require("ae_bridge")
local discover = require("discover")
local railgun_hw = require("railgun_hw")
local planner = require("planner")
local monitor_ui = require("monitor_ui")
local transfer = require("transfer")
local net_watch = require("net_watch")

local cfg = configMod.loadEarth()
local net = {}
local bridge = nil
local mon = nil
local dirty = false

local phase = "poll"
local mode = planner.ZONE_OK
local lastError = ""
local lastFireAt = 0
local settleSince = nil
local uiRows = {} -- fixed skeleton from cfg.items; only statuses mutate
local uiItemsSig = nil
local craftStatus = {} -- name -> string
local craftPending = {} -- name -> { count=, expires=, grace= } local reserve until AE reports the job
local moonHostId = cfg.moon_id
local lastCraftAt = 0
local uiLoadersFull = 0
local uiLoadersTotal = 0
local uiTimerEnd = nil -- os.clock deadline → craft_left on monitor
local uiWaitName = nil -- obtainable item still short (status line, not title)
local uiStatusLines = {} -- extra program status lines under the header
local lastPaintKey = nil
local CRAFT_PENDING_S = 180
local CRAFT_GRACE_S = 15
local UI_PAINT_S = 0.25

local function setStatusLines(a, b, c)
    -- Accept a list table or up to 3 string args (CC-safe, no table.unpack).
    uiStatusLines = {}
    local function push(s)
        if s and tostring(s) ~= "" then
            uiStatusLines[#uiStatusLines + 1] = tostring(s)
        end
    end
    if type(a) == "table" then
        for i = 1, #a do
            push(a[i])
        end
        return
    end
    push(a)
    push(b)
    push(c)
end

local function clearStatusLines()
    uiStatusLines = {}
end

local function setError(msg)
    lastError = tostring(msg or "")
end

local function shortErr(name, err)
    return monitor_ui.itemLabel(name) .. ": " .. tostring(err)
end

--- Build the monitor row list once from cfg. Rebuild only if the watchlist fingerprint changes.
local function ensureUiSkeleton()
    local sig = configMod.itemsFingerprint(cfg.items)
    if uiItemsSig == sig and #uiRows > 0 then
        return false
    end
    local base = {}
    for i = 1, #cfg.items do
        local it = cfg.items[i]
        base[i] = {
            name = it.name,
            label = monitor_ui.itemLabel(it.name),
            moon = 0,
            target = it.target,
            zone = "?",
            earth = 0,
            crafting = 0,
            staged = 0,
            ae = nil,
        }
    end
    uiRows = monitor_ui.sortRows(base)
    uiItemsSig = sig
    lastPaintKey = nil
    if mon then
        mon._moonSupplyLineCache = nil
        mon._moonSupplyLayout = nil
    end
    return true
end

--- Re-read moon_supply_E_ctrl.cfg from disk. Safe to call every poll / shot loop.
-- Watchlist change → rebuild UI skeleton. Hardware change → rescan peripherals.
-- Returns itemsChanged, ok.
local function reloadCfg()
    local ok, fresh = pcall(configMod.loadEarth)
    if not ok then
        setError("cfg: " .. tostring(fresh))
        return false, false
    end
    if type(fresh) ~= "table" or type(fresh.items) ~= "table" then
        setError("cfg: bad earth config")
        return false, false
    end

    local oldItems = configMod.itemsFingerprint(cfg.items)
    local oldHw = configMod.hwFingerprint(cfg)
    local newItems = configMod.itemsFingerprint(fresh.items)
    local newHw = configMod.hwFingerprint(fresh)
    local itemsChanged = newItems ~= oldItems

    cfg = fresh
    if cfg.moon_id then
        moonHostId = cfg.moon_id
    end

    if newHw ~= oldHw then
        dirty = true
        print("moon_supply earth: cfg hardware changed — rescan")
    end

    if itemsChanged then
        craftStatus = {}
        craftPending = {}
        ensureUiSkeleton()
        print(("moon_supply earth: watchlist reloaded (%d items)"):format(#cfg.items))
    else
        ensureUiSkeleton()
    end
    return itemsChanged, true
end

local function openModem()
    local side = discover.modem(cfg)
    if not side or not peripheral.isPresent(side) then
        error("moon_supply earth: no modem on " .. tostring(cfg.modem))
    end
    rednet.open(side)
    print("moon_supply earth: modem " .. tostring(side))
end

--- Only railgun/ME/monitor peripherals should force a full rescan.
-- Random AE bus attach/detach otherwise re-wraps the monitor and setTextScale clears it.
local function relevantHotplug(name)
    name = tostring(name or "")
    if name == "" then
        return false
    end
    if name == (net.monitor or cfg.monitor) or name == cfg.monitor then
        return true
    end
    if name == (net.bridge or cfg.bridge) or name == cfg.bridge then
        return true
    end
    if name == (net.relay or "") or name == (cfg.relay or "") then
        return true
    end
    if name == (net.buffer or "") or name == (cfg.buffer or "") then
        return true
    end
    local prefix = tostring(cfg.loader_prefix or "")
    if prefix ~= "" and name:sub(1, #prefix) == prefix then
        return true
    end
    local modem = tostring(cfg.modem or "")
    if modem ~= "" and (name == modem or name:find(modem, 1, true)) then
        return true
    end
    return false
end

local function noteHotplug(name)
    if relevantHotplug(name) then
        dirty = true
    end
end

local function rescan(reason)
    net = discover.scanEarth(cfg)
    bridge = nil
    if net.bridge then
        bridge = peripheral.wrap(net.bridge)
    end
    if not bridge then
        local p, n = ae_bridge.wrap(cfg.bridge)
        bridge, net.bridge = p, n
    end
    local monName = net.monitor or cfg.monitor
    -- Re-wrap only when the monitor name changed or the old wrap is gone.
    -- monitor_ui.wrap never re-calls setTextScale for the same name (that wipes the screen).
    if not mon or mon._moonSupplyName ~= tostring(monName or "")
        or not peripheral.isPresent(monName) then
        mon = monitor_ui.wrap(monName)
        lastPaintKey = nil
    end
    dirty = false
    settleSince = nil
    if reason then
        print("moon_supply earth: rescan (" .. tostring(reason) .. ")")
    end
    discover.printEarthSummary(net, cfg)
end

local function ensureNet()
    if dirty or not net.loaders or #net.loaders == 0 then
        rescan(dirty and "hotplug" or "init")
    end
    return net.loaders and #net.loaders > 0
end

local function fetchMoon()
    local ids = configMod.itemIds(cfg)
    local stocks, err, hostId = protocol.requestStocks(ids, {
        timeout = cfg.stock_timeout,
        host_id = moonHostId or cfg.moon_id,
    })
    if hostId then
        moonHostId = hostId
    end
    if not stocks then
        setError(err or "луна недоступна")
        return nil
    end
    setError("")
    return stocks
end

local function countOf(map, name)
    return tonumber(map and map[name]) or 0
end

local function stagedCounts()
    local loaders = railgun_hw.cargoTotals(net.loaders)
    local buffer = {}
    if net.buffer and net.buffer ~= "" and peripheral.isPresent(net.buffer) then
        buffer = railgun_hw.cargoTotals({ net.buffer })
    end
    return loaders, buffer
end

local function pendingCover(name, now)
    local p = craftPending[name]
    if not p then
        return 0
    end
    if now > (tonumber(p.expires) or 0) then
        craftPending[name] = nil
        return 0
    end
    if ae_bridge.isItemCrafting(bridge, name) then
        return tonumber(p.count) or 0
    end
    -- AE may still be calculating; keep the reserve through the grace window.
    if now < (tonumber(p.grace) or 0) then
        return tonumber(p.count) or 0
    end
    craftPending[name] = nil
    return 0
end

local function noteCraftPending(name, count, now)
    count = math.max(0, math.floor(tonumber(count) or 0))
    if count < 1 then
        return
    end
    local prev = craftPending[name]
    local already = 0
    if prev and now <= (tonumber(prev.expires) or 0) then
        already = tonumber(prev.count) or 0
    end
    craftPending[name] = {
        count = already + count,
        expires = now + CRAFT_PENDING_S,
        grace = now + CRAFT_GRACE_S,
    }
end

--- Patch status fields in place. Never replaces uiRows (stable list for the monitor).
-- assessRows: optional planner.assess output (moon/target/zone). nil → leave moon fields.
-- opts.light: only refresh staged (tight export loop).
local function updateUiStatuses(assessRows, earthBridge, opts)
    opts = opts or {}
    ensureUiSkeleton()
    local byName = nil
    if assessRows then
        byName = {}
        for i = 1, #assessRows do
            local r = assessRows[i]
            byName[r.name] = r
        end
    end
    local stagedMap, bufMap = stagedCounts()
    local now = os.clock()
    local light = opts.light == true
    for i = 1, #uiRows do
        local row = uiRows[i]
        local name = row.name
        if byName and byName[name] then
            local a = byName[name]
            row.moon = a.moon
            row.target = a.target
            row.zone = a.zone
        end
        row.staged = countOf(stagedMap, name) + countOf(bufMap, name)
        if not light then
            local craftingAmt, craftKnown = ae_bridge.craftingAmount(earthBridge, name)
            local reserved = pendingCover(name, now)
            craftingAmt = math.max(tonumber(craftingAmt) or 0, reserved)
            if not craftKnown and craftingAmt < 1 then
                craftingAmt = 1
            end
            row.crafting = craftingAmt
            row.earth = ae_bridge.getItemAmount(earthBridge, name)
            local ae = craftStatus[name]
            if ae == "ok" or ae == "req" then
                ae = nil
            end
            row.ae = ae
        end
    end
    return stagedMap, bufMap
end

--- Items we cannot obtain right now must not block the shot forever.
local function unavailableSkip()
    local skip = {}
    for i = 1, #uiRows do
        local r = uiRows[i]
        local ae = tostring(r.ae or "")
        if ae == "no" or ae == "fail" then
            local crafting = math.floor(tonumber(r.crafting) or 0)
            local staged = math.floor(tonumber(r.staged) or 0)
            local earth = math.floor(tonumber(r.earth) or 0)
            if crafting < 1 and staged < 1 and earth < 1 then
                skip[r.name] = true
            end
        end
    end
    return skip
end

local function uiTotals()
    local craftTotal, stagedTotal = 0, 0
    for i = 1, #uiRows do
        craftTotal = craftTotal + (tonumber(uiRows[i].crafting) or 0)
        stagedTotal = stagedTotal + (tonumber(uiRows[i].staged) or 0)
    end
    return craftTotal, stagedTotal
end

local function snapshotLoaders()
    uiLoadersTotal = #(net.loaders or {})
    if uiLoadersTotal > 0 then
        uiLoadersFull = select(1, railgun_hw.fillSnapshot(net.loaders))
    else
        uiLoadersFull = 0
    end
end

--- Paint from shared state only (no AE). Safe to call from the UI coroutine.
local function drawUi()
    if not mon then
        return
    end
    local craftTotal, stagedTotal = uiTotals()
    local craftLeft = nil
    if uiTimerEnd then
        local left = uiTimerEnd - os.clock()
        if left > 0 then
            craftLeft = math.floor(left + 0.5)
        end
    end
    local now = os.clock()
    local pulsePhase = phase
    if phase == "craft_wait" then
        pulsePhase = "poll" -- reuse live pulse while waiting on AE
    end
    local pulse = monitor_ui.phasePulseIndex(pulsePhase, now) or "-"
    local statusKey = table.concat(uiStatusLines, "/")
    local key = table.concat({
        tostring(phase),
        tostring(mode),
        tostring(lastError),
        tostring(uiWaitName or ""),
        tostring(statusKey),
        tostring(uiLoadersFull),
        tostring(uiLoadersTotal),
        tostring(craftLeft or "-"),
        tostring(craftTotal),
        tostring(stagedTotal),
        tostring(pulse),
        tostring(#uiRows),
    }, "|")
    for i = 1, #uiRows do
        local r = uiRows[i]
        key = key .. ";" .. tostring(r.name)
            .. "," .. tostring(r.moon)
            .. "," .. tostring(r.earth)
            .. "," .. tostring(r.crafting)
            .. "," .. tostring(r.staged)
            .. "," .. tostring(r.ae or "-")
            .. "," .. tostring(r.zone)
    end
    if key == lastPaintKey then
        return
    end
    lastPaintKey = key
    monitor_ui.draw(mon, {
        phase = phase,
        mode = mode,
        error = lastError,
        wait_item = uiWaitName,
        messages = uiStatusLines,
        rows = uiRows,
        loaders_full = uiLoadersFull,
        loaders_total = uiLoadersTotal,
        craft_left = craftLeft,
        craft_total = craftTotal,
        staged_total = stagedTotal,
        clock = now,
    })
end

local function requestCrafts(wants, order, force)
    if not bridge then
        return
    end
    local now = os.clock()
    if not force and (now - lastCraftAt) < 5 then
        return
    end
    lastCraftAt = now
    local staged, buf = stagedCounts()
    for i = 1, #order do
        local name = order[i]
        local need = tonumber(wants[name]) or 0
        if need > 0 then
            local have = ae_bridge.getItemAmount(bridge, name)
            local crafting, craftKnown = ae_bridge.craftingAmount(bridge, name)
            local reserved = pendingCover(name, now)
            if not craftKnown then
                -- Active job for this id, amount opaque: do not stack another request.
                craftStatus[name] = "req"
            else
                local missing = need - have - countOf(staged, name) - countOf(buf, name)
                    - crafting - reserved
                if missing > 0 then
                    -- Some AP builds reject large craftable probes; fall back to count=1.
                    local okCraft, why = ae_bridge.isItemCraftable(bridge, name, missing)
                    if not okCraft and missing > 1 then
                        okCraft, why = ae_bridge.isItemCraftable(bridge, name, 1)
                    end
                    if not okCraft then
                        craftStatus[name] = "no"
                        -- Wrong id / no pattern: status column only (no orange banner spam).
                        local quiet = why == "unverified" or why == "ITEM_NOT_FOUND"
                            or why == "not craftable" or why == nil
                        if not quiet then
                            setError(shortErr(name, why))
                        end
                    else
                        local ok, err = ae_bridge.craftItem(bridge, name, missing)
                        craftStatus[name] = ok and "req" or "fail"
                        if ok then
                            noteCraftPending(name, missing, now)
                        else
                            local quiet = err == "ITEM_NOT_FOUND" or err == "not craftable"
                            if not quiet then
                                setError(shortErr(name, err))
                            end
                        end
                    end
                else
                    if crafting > 0 or reserved > 0 or ae_bridge.isItemCrafting(bridge, name) then
                        craftStatus[name] = "req"
                    else
                        craftStatus[name] = "ok"
                    end
                end
            end
        end
        if i % 4 == 0 then
            sleep(0)
        end
    end
end

--- Optional: drain a leftover buffer chest into loaders if one is configured.
local function pushBuffer(order)
    if not net.buffer or net.buffer == "" or not peripheral.isPresent(net.buffer) then
        return
    end
    local buf = railgun_hw.cargoTotals({ net.buffer })
    for i = 1, #order do
        local name = order[i]
        local n = countOf(buf, name)
        if n > 0 then
            transfer.toMany(net.buffer, net.loaders, name, n)
        end
        if i % 4 == 0 then
            sleep(0)
        end
    end
end

--- Export AE items straight into HV loaders (exportItemToPeripheral). Buffer optional.
local function exportAndPush(wants, order)
    if not bridge then
        setError("нет ME-моста")
        return false
    end
    if not net.loaders or #net.loaders == 0 then
        setError("нет лоадеров")
        return false
    end
    pushBuffer(order)
    local staged = select(1, stagedCounts())
    for i = 1, #order do
        local name = order[i]
        local rem = (tonumber(wants[name]) or 0) - countOf(staged, name)
        local li = 1
        while rem > 0 and li <= #net.loaders do
            local chunk = math.min(rem, 64)
            local n = ae_bridge.exportItemToPeripheral(bridge, name, chunk, net.loaders[li])
            n = tonumber(n) or 0
            if n > 0 then
                rem = rem - n
                staged[name] = countOf(staged, name) + n
            else
                li = li + 1
            end
            sleep(0)
        end
        sleep(0)
    end
    pushBuffer(order)
    return true
end

local function canLoadMore(wants, order, staged, buf)
    for i = 1, #order do
        local name = order[i]
        local want = tonumber(wants[name]) or 0
        if countOf(staged, name) < want then
            if countOf(buf, name) > 0 then
                return true
            end
            if bridge and ae_bridge.getItemAmount(bridge, name) > 0 then
                return true
            end
        end
    end
    return false
end

local function tryFire()
    local settleNeed = tonumber(cfg.settle) or 0
    local now = os.clock()
    if settleNeed > 0 then
        if not settleSince then
            settleSince = now
            phase = "settle"
            return false
        end
        if (now - settleSince) < settleNeed then
            phase = "settle"
            return false
        end
    end
    phase = "fire"
    local ok, err = railgun_hw.pulseRelay(net.relay, cfg)
    settleSince = nil
    if ok then
        lastFireAt = os.clock()
        phase = "cooldown"
        uiTimerEnd = lastFireAt + cfg.cooldown
        setError("")
    else
        setError("импульс: " .. tostring(err))
        phase = "poll"
        uiTimerEnd = nil
    end
    return true
end

local function formatSkipStatus(skipNames)
    if not skipNames or #skipNames == 0 then
        return nil
    end
    local labels = {}
    local n = math.min(#skipNames, 3)
    for i = 1, n do
        labels[i] = monitor_ui.itemLabel(skipNames[i])
    end
    -- Not "skipped somewhere" — excluded from this shot because AE has no stock/pattern.
    local s = "не шлём (нет в AE): " .. table.concat(labels, ", ")
    if #skipNames > 3 then
        s = s .. "…"
    end
    return s
end

local function runShotCycle(rows, shotMode)
    mode = shotMode
    local wants, order = planner.packageWants(rows, shotMode)
    if #order == 0 then
        phase = "idle"
        uiTimerEnd = nil
        uiWaitName = nil
        clearStatusLines()
        return
    end

    local fullOrder = {}
    for i = 1, #order do
        fullOrder[i] = order[i]
    end

    craftStatus = {}
    requestCrafts(wants, order, true)
    updateUiStatuses(rows, bridge)
    snapshotLoaders()

    local skip = unavailableSkip()
    local skipNames = planner.skippedNames(fullOrder, skip)
    wants, order = planner.filterObtainable(wants, order, skip)

    if #order == 0 then
        -- Nothing craftable/exportable — do not fake a craft-wait or launch prep.
        phase = "idle"
        uiTimerEnd = nil
        uiWaitName = nil
        setStatusLines(formatSkipStatus(skipNames) or "нечего отправить")
        return
    end

    local waitS = planner.craftWaitSeconds(cfg, shotMode)
    local waitDeadline = os.clock() + waitS
    uiTimerEnd = waitDeadline
    phase = "craft_wait"
    do
        local staged0 = select(1, stagedCounts())
        uiWaitName = planner.waitItem(wants, order, staged0, skip)
        local lines = {}
        if waitS > 0 then
            lines[#lines + 1] = ("ожидание AE до %.0f с"):format(waitS)
        end
        if uiWaitName then
            lines[#lines + 1] = "ждём: " .. monitor_ui.itemLabel(uiWaitName)
        end
        local skipLine = formatSkipStatus(skipNames)
        if skipLine then
            lines[#lines + 1] = skipLine
        end
        setStatusLines(lines)
    end

    while true do
        local itemsChanged = reloadCfg()
        if itemsChanged then
            phase = "poll"
            uiTimerEnd = nil
            uiWaitName = nil
            clearStatusLines()
            return
        end

        if dirty then
            rescan("hotplug")
            if not bridge then
                setError("нет ME-моста")
                uiWaitName = nil
                clearStatusLines()
                return
            end
        end

        local now = os.clock()
        local inCraftWait = now < waitDeadline
        if inCraftWait then
            phase = "craft_wait"
            uiTimerEnd = waitDeadline
            requestCrafts(wants, order, false)
        else
            uiTimerEnd = nil
        end

        local okExport = exportAndPush(wants, order)
        local staged, buf = updateUiStatuses(rows, bridge)
        skip = unavailableSkip()
        wants, order = planner.filterObtainable(wants, order, skip)
        if #order == 0 then
            phase = "idle"
            uiTimerEnd = nil
            uiWaitName = nil
            setStatusLines(formatSkipStatus(planner.skippedNames(fullOrder, skip)) or "нечего отправить")
            return
        end

        local satisfied = planner.packageDone(wants, staged, skip)
        uiWaitName = satisfied and nil or planner.waitItem(wants, order, staged, skip)
        local full = railgun_hw.allFull(net.loaders, cfg.expected)
        snapshotLoaders()

        local stagedTotal = 0
        for i = 1, #uiRows do
            stagedTotal = stagedTotal + (tonumber(uiRows[i].staged) or 0)
        end

        if not inCraftWait then
            if stagedTotal > 0 or full then
                phase = "loading"
            else
                phase = "poll"
            end
        end

        do
            local lines = {}
            if inCraftWait and uiTimerEnd then
                local left = math.max(0, math.floor(uiTimerEnd - os.clock() + 0.5))
                lines[#lines + 1] = ("ожидание AE %d с"):format(left)
            elseif phase == "loading" then
                lines[#lines + 1] = ("в лоадерах %d"):format(stagedTotal)
            end
            if uiWaitName then
                lines[#lines + 1] = "ждём: " .. monitor_ui.itemLabel(uiWaitName)
            end
            local skipLine = formatSkipStatus(planner.skippedNames(fullOrder, skip))
            if skipLine then
                lines[#lines + 1] = skipLine
            end
            setStatusLines(lines)
        end

        if planner.shouldFire(satisfied, full) then
            if tryFire() then
                uiWaitName = nil
                clearStatusLines()
                return
            end
        else
            settleSince = nil
            if not okExport then
                phase = "poll"
                uiTimerEnd = nil
                uiWaitName = nil
                clearStatusLines()
                return
            end
            if planner.shouldYield(inCraftWait, canLoadMore(wants, order, staged, buf), satisfied, full) then
                phase = "poll"
                uiTimerEnd = nil
                uiWaitName = nil
                setStatusLines("пакет не собран — в опросе", formatSkipStatus(planner.skippedNames(fullOrder, skip)))
                return
            end
        end

        net_watch.sleepWatch(0.5, noteHotplug)
    end
end

local function tick()
    reloadCfg()

    if not ensureNet() then
        phase = "poll"
        setError("нет лоадеров")
        snapshotLoaders()
        return
    end
    if not net.relay then
        setError("нет реле")
        snapshotLoaders()
        return
    end
    if not bridge then
        setError("нет ME-моста")
        snapshotLoaders()
        return
    end

    local now = os.clock()
    if lastFireAt > 0 and (now - lastFireAt) < cfg.cooldown then
        phase = "cooldown"
        uiTimerEnd = lastFireAt + cfg.cooldown
        snapshotLoaders()
        return
    end

    phase = "poll"
    uiTimerEnd = nil
    local stocks = fetchMoon()
    if not stocks then
        -- cfg skeleton stays; mark moon unknown and refresh Earth/craft statuses
        ensureUiSkeleton()
        for i = 1, #uiRows do
            uiRows[i].moon = 0
            uiRows[i].zone = "?"
        end
        updateUiStatuses(nil, bridge)
        snapshotLoaders()
        return
    end

    local rows, shotMode = planner.assess(cfg.items, stocks, cfg.red_frac)
    mode = shotMode
    updateUiStatuses(rows, bridge)
    snapshotLoaders()

    if shotMode == planner.ZONE_OK then
        phase = "idle"
        uiWaitName = nil
        clearStatusLines()
        return
    end

    runShotCycle(rows, shotMode)
end

local function controlLoop()
    while true do
        local ok, err = pcall(tick)
        if not ok then
            setError(tostring(err))
            print("moon_supply earth: " .. tostring(err))
        end
        net_watch.sleepWatch(cfg.poll, noteHotplug)
    end
end

--- Separate coroutine: paints even while control is blocked in AE/export/sleep.
local function uiLoop()
    while true do
        local ok, err = pcall(drawUi)
        if not ok then
            print("moon_supply ui: " .. tostring(err))
        end
        sleep(UI_PAINT_S)
    end
end

print(("moon_supply earth: items=%d red_frac=%s cooldown=%s"):format(
    #cfg.items,
    tostring(cfg.red_frac),
    tostring(cfg.cooldown)
))
openModem()
rescan("start")
net_watch.flushEvents("moon_supply_flush")
dirty = false
snapshotLoaders()
ensureUiSkeleton()
pcall(drawUi)

print("moon_supply earth: parallel UI + control")
parallel.waitForAny(controlLoop, uiLoop)
