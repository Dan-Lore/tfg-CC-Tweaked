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
local uiSentFreeze = false -- after fire: keep «Отправлено» until loaders empty or a new shot loads
local lastCfgAt = 0
local lastFullAeAt = 0
local lastSnap = nil -- latest ae_bridge.snapshot (shared by UI + crafts)
local uiDebugLog = {} -- ring under the table
local CRAFT_PENDING_S = 180
local CRAFT_GRACE_S = 15
local UI_PAINT_S = 0.15
local CFG_RELOAD_S = 2
local AE_FULL_S = 2
local DEBUG_LOG_N = 4

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

local function dbg(msg)
    msg = tostring(msg or "")
    if msg == "" then
        return
    end
    local t = math.floor(os.clock() % 100000)
    uiDebugLog[#uiDebugLog + 1] = ("%05d %s"):format(t, msg)
    while #uiDebugLog > DEBUG_LOG_N do
        table.remove(uiDebugLog, 1)
    end
    lastPaintKey = nil -- force UI repaint for log
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

--- Re-read moon_supply_E_ctrl.cfg from disk (throttled; force=true bypasses).
-- Watchlist change → rebuild UI skeleton. Hardware change → rescan peripherals.
-- Returns itemsChanged, ok.
local function reloadCfg(force)
    local now = os.clock()
    if not force and (now - lastCfgAt) < CFG_RELOAD_S then
        return false, true
    end
    lastCfgAt = now

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

--- Local craft reserve. Prefer snapshot craftingAmt/craftKnown (no per-id AE call).
local function pendingCover(name, now, craftingAmt, craftKnown)
    local p = craftPending[name]
    if not p then
        return 0
    end
    if now > (tonumber(p.expires) or 0) then
        craftPending[name] = nil
        return 0
    end
    local active = (tonumber(craftingAmt) or 0) > 0 or craftKnown == false
    if active then
        return tonumber(p.count) or 0
    end
    if craftingAmt == nil and craftKnown == nil and bridge
        and ae_bridge.isItemCrafting(bridge, name) then
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
-- opts.light: only refresh staged (tight export loop) — no AE round-trip.
-- Full refresh uses one ae_bridge.snapshot (getItem×watchlist), then applies all rows
-- without yielding so the UI never paints a half-updated table.
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

    local snap = nil
    if not light and earthBridge then
        local names = {}
        for i = 1, #uiRows do
            names[i] = uiRows[i].name
        end
        snap = ae_bridge.snapshot(earthBridge, names)
        lastSnap = snap
        lastFullAeAt = now
        dbg(("AE snap %dms n=%d"):format(tonumber(snap.ms) or 0, #names))
    end

    -- Stage patches first, then commit — one coherent frame.
    local patch = {}
    for i = 1, #uiRows do
        local row = uiRows[i]
        local name = row.name
        local p = {
            moon = row.moon,
            target = row.target,
            zone = row.zone,
            staged = countOf(stagedMap, name) + countOf(bufMap, name),
            earth = row.earth,
            crafting = row.crafting,
            ae = row.ae,
        }
        if byName and byName[name] then
            local a = byName[name]
            p.moon = a.moon
            p.target = a.target
            p.zone = a.zone
        end
        if snap then
            local craftingAmt = tonumber(snap.crafting[name]) or 0
            local craftKnown = snap.craftKnown[name] ~= false
            local reserved = pendingCover(name, now, craftingAmt, craftKnown)
            craftingAmt = math.max(craftingAmt, reserved)
            if not craftKnown and craftingAmt < 1 then
                craftingAmt = 1
            end
            p.crafting = craftingAmt
            p.earth = tonumber(snap.amount[name]) or 0
            local craftable = snap.craftable[name]
            local ae = craftStatus[name]
            if ae == "ok" or ae == "req" then
                ae = nil
            elseif ae == nil and p.earth < 1 and craftable == false then
                ae = "no"
            end
            p.ae = ae
        end
        patch[i] = p
    end
    local stagedTotal = 0
    for i = 1, #uiRows do
        local row, p = uiRows[i], patch[i]
        row.moon = p.moon
        row.target = p.target
        row.zone = p.zone
        row.staged = p.staged
        row.earth = p.earth
        row.crafting = p.crafting
        row.ae = p.ae
        stagedTotal = stagedTotal + (tonumber(p.staged) or 0)
    end
    if uiSentFreeze and stagedTotal < 1 then
        uiSentFreeze = false
    end
    return stagedMap, bufMap
end

local function rowByName(name)
    for i = 1, #uiRows do
        if uiRows[i].name == name then
            return uiRows[i]
        end
    end
    return nil
end

--- Human status about why a package item is still short — never vague «ждём AE».
local function describeShortItem(name, want, stagedMap)
    local row = rowByName(name)
    local label = monitor_ui.itemLabel(name)
    local staged = countOf(stagedMap, name)
    if row then
        staged = math.max(staged, tonumber(row.staged) or 0)
    end
    want = math.max(0, math.floor(tonumber(want) or 0))
    local earth = row and tonumber(row.earth) or 0
    local crafting = row and tonumber(row.crafting) or 0
    local ae = row and tostring(row.ae or "") or ""
    local st = craftStatus[name]
    if crafting > 0 then
        return ("крафт %s %d"):format(label, crafting)
    end
    if st == "req" and earth < 1 and staged < want then
        return ("заказ принят: %s"):format(label)
    end
    if earth > 0 and staged < want then
        return ("выгрузка %s %d/%d"):format(label, staged, want)
    end
    if ae == "no" or ae == "fail" or st == "no" or st == "fail" then
        return ("нет в AE: %s"):format(label)
    end
    if earth < 1 and staged < want then
        return ("нет на Земле: %s"):format(label)
    end
    return ("ждём %s %d/%d"):format(label, staged, want)
end

local function anyActiveCraft(order)
    order = order or {}
    for i = 1, #order do
        local name = order[i]
        local row = rowByName(name)
        if row and (tonumber(row.crafting) or 0) > 0 then
            return true
        end
        if craftStatus[name] == "req" then
            return true
        end
        local p = craftPending[name]
        if p and os.clock() <= (tonumber(p.expires) or 0) then
            return true
        end
    end
    return false
end

--- Build the 2 sys status lines from live package state (replaces dead «ожидание AE»).
local function buildPackageStatus(opts)
    opts = opts or {}
    local lines = {}
    local left = opts.left
    local crafting = anyActiveCraft(opts.order)
    if opts.in_wait and left and left > 0 then
        if crafting then
            lines[#lines + 1] = ("крафт AE, ещё %d с"):format(left)
        else
            lines[#lines + 1] = ("сборка пакета %d с"):format(left)
        end
    elseif opts.phase == "loading" then
        lines[#lines + 1] = ("в лоадерах %d"):format(tonumber(opts.staged_total) or 0)
    end
    if opts.last_order then
        lines[#lines + 1] = opts.last_order
    elseif opts.wait_name and opts.wants then
        lines[#lines + 1] = describeShortItem(
            opts.wait_name,
            opts.wants[opts.wait_name],
            opts.staged_map
        )
    end
    if opts.skip_line then
        lines[#lines + 1] = opts.skip_line
    end
    -- Keep at most 2 for the fixed band; overflow goes to debug.
    if #lines > 2 then
        for i = 3, #lines do
            dbg(lines[i])
        end
        local kept = { lines[1], lines[2] }
        lines = kept
    end
    setStatusLines(lines)
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
        tostring(uiSentFreeze and "1" or "0"),
        tostring(#uiRows),
        tostring(#uiDebugLog),
        tostring(uiDebugLog[#uiDebugLog] or ""),
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
        sent_freeze = uiSentFreeze,
        debug = uiDebugLog,
        clock = now,
    })
end

--- Order AE crafts from an existing snapshot (no per-id getItem/craftingAmount).
-- Returns lastOrderLine or nil for status band.
local function requestCrafts(wants, order, force, snap)
    if not bridge then
        return nil
    end
    local now = os.clock()
    if not force and (now - lastCraftAt) < 5 then
        return nil
    end
    lastCraftAt = now
    snap = snap or lastSnap
    if not snap then
        local names = {}
        for i = 1, #order do
            names[i] = order[i]
        end
        snap = ae_bridge.snapshot(bridge, names)
        lastSnap = snap
        dbg(("AE snap(craft) %dms"):format(tonumber(snap.ms) or 0))
    end
    local staged, buf = stagedCounts()
    local t0 = os.clock()
    local ordered = 0
    local lastOrderLine = nil
    for i = 1, #order do
        local name = order[i]
        local need = tonumber(wants[name]) or 0
        if need > 0 then
            local have = tonumber(snap.amount[name]) or 0
            local crafting = tonumber(snap.crafting[name]) or 0
            local craftKnown = snap.craftKnown[name] ~= false
            local craftable = snap.craftable[name]
            local reserved = pendingCover(name, now, crafting, craftKnown)
            if not craftKnown then
                craftStatus[name] = "req"
            else
                local missing = need - have - countOf(staged, name) - countOf(buf, name)
                    - crafting - reserved
                if missing > 0 then
                    -- getItem.isCraftable=false is common for multi-step patterns (plate←gem)
                    -- even when a terminal craft works — never hard-skip on that flag alone.
                    -- AE expands the full recipe tree when craftItem(final) is accepted.
                    local why = "try"
                    if craftable == true then
                        why = "getItem"
                    else
                        local okProbe, probeWhy = ae_bridge.isItemCraftable(bridge, name, 1)
                        if okProbe then
                            why = probeWhy or "probe"
                        elseif probeWhy == "not craftable" or probeWhy == "ITEM_NOT_FOUND" then
                            -- Still try craftItem once; only mark «Нет в AE» if verify fails too.
                            why = "try:" .. tostring(probeWhy)
                        end
                    end
                    local ok, err, scheduled = ae_bridge.craftItem(bridge, name, missing)
                    scheduled = tonumber(scheduled) or 0
                    if ok and scheduled > 0 then
                        craftStatus[name] = "req"
                        noteCraftPending(name, scheduled, now)
                        ordered = ordered + 1
                        lastOrderLine = "заказ AE: "
                            .. monitor_ui.itemLabel(name)
                            .. (" ×%d"):format(scheduled)
                        dbg(lastOrderLine .. " (" .. tostring(why) .. ")")
                    else
                        -- Do not fake «заказ принят» / skip the item when no CPU job exists.
                        craftStatus[name] = nil
                        lastOrderLine = "AE не взял: " .. monitor_ui.itemLabel(name)
                        dbg(lastOrderLine .. " " .. tostring(err or why or ""))
                        if err and err ~= "API ok, no AE job" and err ~= "craft returned nil"
                            and err ~= "not craftable" and err ~= "ITEM_NOT_FOUND" then
                            setError(shortErr(name, err))
                        end
                    end
                else
                    if crafting > 0 or reserved > 0 then
                        craftStatus[name] = "req"
                    else
                        craftStatus[name] = "ok"
                    end
                end
            end
        end
    end
    dbg(("crafts %dms ordered=%d"):format(math.floor((os.clock() - t0) * 1000 + 0.5), ordered))
    return lastOrderLine
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
    local snap = lastSnap
    for i = 1, #order do
        local name = order[i]
        local rem = (tonumber(wants[name]) or 0) - countOf(staged, name)
        if rem > 0 then
            local earth = 0
            if snap and snap.amount then
                earth = tonumber(snap.amount[name]) or 0
            end
            -- Skip empty AE pulls — was ~10s of failed exportItem spam per shot loop.
            if earth < 1 then
                rem = 0
            else
                rem = math.min(rem, earth)
            end
        end
        local li = 1
        while rem > 0 and li <= #net.loaders do
            local chunk = math.min(rem, 64)
            local n = ae_bridge.exportItemToPeripheral(bridge, name, chunk, net.loaders[li])
            n = tonumber(n) or 0
            if n > 0 then
                rem = rem - n
                staged[name] = countOf(staged, name) + n
                if snap and snap.amount then
                    snap.amount[name] = math.max(0, (tonumber(snap.amount[name]) or 0) - n)
                end
            else
                li = li + 1
            end
            sleep(0)
        end
    end
    pushBuffer(order)
    return true
end

local function canLoadMore(wants, order, staged, buf, snap)
    snap = snap or lastSnap
    for i = 1, #order do
        local name = order[i]
        local want = tonumber(wants[name]) or 0
        if countOf(staged, name) < want then
            if countOf(buf, name) > 0 then
                return true
            end
            local earth = 0
            if snap and snap.amount then
                earth = tonumber(snap.amount[name]) or 0
            else
                local row = rowByName(name)
                earth = row and tonumber(row.earth) or 0
            end
            if earth > 0 then
                return true
            end
            if (tonumber(snap and snap.crafting and snap.crafting[name]) or 0) > 0 then
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
        uiSentFreeze = true
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

    -- New intentional load cycle — stop showing «Отправлено».
    uiSentFreeze = false
    craftStatus = {}
    updateUiStatuses(rows, bridge)
    local lastOrderLine = requestCrafts(wants, order, true, lastSnap)
    updateUiStatuses(rows, bridge) -- refresh crafting flags after orders
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
        dbg("shot abort: нечего отправить")
        return
    end

    -- Full craft-wait only when AE jobs are actually needed; otherwise short export settle.
    local waitS = planner.craftWaitSeconds(cfg, shotMode)
    if not anyActiveCraft(order) then
        waitS = math.min(waitS, 3)
        dbg(("shot: без крафта, пауза %ds"):format(waitS))
    else
        dbg(("shot: craft-wait %ds mode=%s"):format(waitS, tostring(shotMode)))
    end
    local waitDeadline = os.clock() + waitS
    uiTimerEnd = waitDeadline
    phase = "craft_wait"
    do
        local staged0 = select(1, stagedCounts())
        uiWaitName = planner.waitItem(wants, order, staged0, skip)
        buildPackageStatus({
            in_wait = waitS > 0,
            left = waitS,
            order = order,
            wait_name = uiWaitName,
            wants = wants,
            staged_map = staged0,
            last_order = lastOrderLine,
            skip_line = formatSkipStatus(skipNames),
        })
    end

    while true do
        local itemsChanged = reloadCfg()
        if itemsChanged then
            phase = "poll"
            uiTimerEnd = nil
            uiWaitName = nil
            clearStatusLines()
            dbg("cfg watchlist changed — abort shot")
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
        -- Collapse dead craft-wait: no jobs and Earth has stock → stop pretending we wait on AE.
        if now < waitDeadline and not anyActiveCraft(order) then
            local canExport = false
            for i = 1, #order do
                local name = order[i]
                local row = rowByName(name)
                if row and (tonumber(row.earth) or 0) > 0 then
                    canExport = true
                    break
                end
            end
            if canExport then
                waitDeadline = now
                dbg("wait collapse: есть склад, без крафта")
            end
        end

        local inCraftWait = now < waitDeadline
        if inCraftWait then
            phase = "craft_wait"
            uiTimerEnd = waitDeadline
            lastOrderLine = requestCrafts(wants, order, false, lastSnap) or lastOrderLine
        else
            uiTimerEnd = nil
        end

        local tExp = os.clock()
        local okExport = exportAndPush(wants, order)
        dbg(("export %dms"):format(math.floor((os.clock() - tExp) * 1000 + 0.5)))
        -- Staged every loop; full AE snapshot at most every AE_FULL_S (atomic apply).
        local needFull = itemsChanged or (now - lastFullAeAt) >= AE_FULL_S
        local staged, buf = updateUiStatuses(rows, bridge, needFull and {} or { light = true })
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

        local left = nil
        if inCraftWait and uiTimerEnd then
            left = math.max(0, math.floor(uiTimerEnd - os.clock() + 0.5))
        end
        buildPackageStatus({
            in_wait = inCraftWait,
            left = left,
            phase = phase,
            staged_total = stagedTotal,
            order = order,
            wait_name = uiWaitName,
            wants = wants,
            staged_map = staged,
            last_order = (lastOrderLine and os.clock() - lastCraftAt < 8) and lastOrderLine or nil,
            skip_line = formatSkipStatus(planner.skippedNames(fullOrder, skip)),
        })

        if planner.shouldFire(satisfied, full) then
            if tryFire() then
                uiWaitName = nil
                clearStatusLines()
                dbg("fire ok → cooldown")
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
            local more = canLoadMore(wants, order, staged, buf, lastSnap)
            if planner.shouldYield(inCraftWait, more, satisfied, full) then
                phase = "poll"
                uiTimerEnd = nil
                uiWaitName = nil
                setStatusLines(
                    "пакет не собран — в опросе",
                    formatSkipStatus(planner.skippedNames(fullOrder, skip))
                )
                dbg("yield → poll (нечего грузить)")
                return
            end
        end

        net_watch.sleepWatch(0.5, noteHotplug)
    end
end

local function tick()
    local tTick = os.clock()
    reloadCfg(true)

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
        -- Keep «Отправлено» counts live; do not flip to «Загрузка» (uiSentFreeze).
        updateUiStatuses(nil, bridge, { light = true })
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
    dbg(("poll %dms mode=%s"):format(
        math.floor((os.clock() - tTick) * 1000 + 0.5),
        tostring(shotMode)
    ))

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
