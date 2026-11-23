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
local uiRows = {}
local craftStatus = {} -- name -> string
local craftPending = {} -- name -> { count=, expires=, grace= } local reserve until AE reports the job
local moonHostId = cfg.moon_id
local lastCraftAt = 0
local lastFullUiAt = 0
local uiLoadersFull = 0
local uiLoadersTotal = 0
local uiTimerEnd = nil -- os.clock deadline → craft_left on monitor
local CRAFT_PENDING_S = 180
local CRAFT_GRACE_S = 15
local UI_FULL_REFRESH_S = 2.5
local UI_PAINT_S = 0.25

local function setError(msg)
    lastError = tostring(msg or "")
end

local function shortErr(name, err)
    return monitor_ui.itemLabel(name) .. ": " .. tostring(err)
end

local function openModem()
    local side = discover.modem(cfg)
    if not side or not peripheral.isPresent(side) then
        error("moon_supply earth: no modem on " .. tostring(cfg.modem))
    end
    rednet.open(side)
    print("moon_supply earth: modem " .. tostring(side))
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
    mon = monitor_ui.wrap(net.monitor or cfg.monitor)
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

local function refreshUiRows(rows, earthBridge)
    uiRows = {}
    local stagedMap, bufMap = stagedCounts()
    local now = os.clock()
    for i = 1, #rows do
        local r = rows[i]
        local name = r.name
        local craftingAmt, craftKnown = ae_bridge.craftingAmount(earthBridge, name)
        local reserved = pendingCover(name, now)
        craftingAmt = math.max(tonumber(craftingAmt) or 0, reserved)
        -- Job visible to AE but amount opaque: still show Крафт (n).
        if not craftKnown and craftingAmt < 1 then
            craftingAmt = 1
        end
        local stagedAmt = countOf(stagedMap, name) + countOf(bufMap, name)
        local ae = craftStatus[name]
        if ae == "ok" or ae == "req" then
            ae = nil
        end
        uiRows[i] = {
            name = name,
            moon = r.moon,
            target = r.target,
            zone = r.zone,
            earth = ae_bridge.getItemAmount(earthBridge, name),
            crafting = craftingAmt,
            staged = stagedAmt,
            ae = ae,
        }
        -- Yield often so the parallel UI coroutine can paint.
        if i % 2 == 0 then
            sleep(0)
        end
    end
    lastFullUiAt = os.clock()
end

--- Fast path: only recount loader/buffer cargo into existing uiRows.
local function patchStagedIntoUi()
    local staged, buf = stagedCounts()
    for i = 1, #uiRows do
        local name = uiRows[i].name
        uiRows[i].staged = countOf(staged, name) + countOf(buf, name)
    end
    return staged, buf
end

local function refreshUiRowsMaybe(rows, earthBridge, force)
    local now = os.clock()
    if force or (now - lastFullUiAt) >= UI_FULL_REFRESH_S or #uiRows == 0 then
        refreshUiRows(rows, earthBridge)
        return
    end
    patchStagedIntoUi()
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

local lastPaintKey = nil

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
    local key = table.concat({
        tostring(phase),
        tostring(mode),
        tostring(lastError),
        tostring(uiLoadersFull),
        tostring(uiLoadersTotal),
        tostring(craftLeft or "-"),
        tostring(craftTotal),
        tostring(stagedTotal),
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
        rows = uiRows,
        loaders_full = uiLoadersFull,
        loaders_total = uiLoadersTotal,
        craft_left = craftLeft,
        craft_total = craftTotal,
        staged_total = stagedTotal,
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
                    local okCraft, why = ae_bridge.isItemCraftable(bridge, name, missing)
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

local function runShotCycle(rows, shotMode)
    mode = shotMode
    local wants, order = planner.packageWants(rows, shotMode)
    if #order == 0 then
        phase = "idle"
        uiTimerEnd = nil
        return
    end

    craftStatus = {}
    local waitS = planner.craftWaitSeconds(cfg, shotMode)
    local waitDeadline = os.clock() + waitS
    uiTimerEnd = waitDeadline

    phase = "craft_wait"
    requestCrafts(wants, order, true)
    refreshUiRows(rows, bridge)
    snapshotLoaders()

    while true do
        if dirty then
            rescan("hotplug")
            if not bridge then
                setError("нет ME-моста")
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
            phase = "loading"
            uiTimerEnd = nil
        end

        local okExport = exportAndPush(wants, order)
        local staged, buf = patchStagedIntoUi()
        local satisfied = planner.packageDone(wants, staged)
        local full = railgun_hw.allFull(net.loaders, cfg.expected)
        snapshotLoaders()
        refreshUiRowsMaybe(rows, bridge, false)

        if planner.shouldFire(satisfied, full) then
            if tryFire() then
                return
            end
        else
            settleSince = nil
            if not okExport then
                phase = "poll"
                uiTimerEnd = nil
                return
            end
            if planner.shouldYield(inCraftWait, canLoadMore(wants, order, staged, buf), satisfied, full) then
                phase = "hold"
                uiTimerEnd = nil
                return
            end
        end

        if net_watch.sleepWatch(0.5) then
            dirty = true
        end
    end
end

local function tick()
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
        -- still show cfg items with unknown moon
        local rows = {}
        for i = 1, #cfg.items do
            local it = cfg.items[i]
            rows[i] = {
                name = it.name,
                moon = 0,
                target = it.target,
                zone = "?",
            }
        end
        refreshUiRows(rows, bridge)
        snapshotLoaders()
        return
    end

    local rows, shotMode = planner.assess(cfg.items, stocks, cfg.red_frac)
    mode = shotMode
    refreshUiRows(rows, bridge)
    snapshotLoaders()

    if shotMode == planner.ZONE_OK then
        phase = "idle"
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
        if net_watch.sleepWatch(cfg.poll) then
            dirty = true
        end
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
pcall(drawUi)

print("moon_supply earth: parallel UI + control")
parallel.waitForAny(controlLoop, uiLoop)
