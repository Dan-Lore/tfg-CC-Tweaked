-- Electric blast furnace recipe feeder (CC: Tweaked / TFG).
-- Hatch index N = pair (N+1)L + (N+1)R sharing one set of 4 hatches.
--
-- Architecture: each pattern provider has a UNIQUE recipe set → one craft order
-- (e.g. 100 Al) lands sequentially in ONE hv_buffer. Stick to that buffer and
-- fan out to furnace packs; do not rescan every buffer/hatch every tick.
--
-- Bundle:  python tools/bundle_project.py ebf
-- Deploy:  dist/ebf.lua + ebf.cfg

package.path = package.path
    .. ";/ebf/?.lua;ebf/?.lua;/shared/?.lua;shared/?.lua"

local configMod = require("config")
local discover = require("discover")
local recipe = require("recipe")
local furnace = require("furnace")
local ui = require("ui")
local net_watch = require("net_watch")

local config, cfgPath, cfgLoaded = configMod.load()
local net = {
    buffers = {},
    furnaces = {},
    hotSink = nil,
    aeSink = nil,
    monitor = nil,
    monitorName = nil,
}
local states = {}
local packList = {}
local dirty = false
local lastStatus = ""
local lastStatusAt = 0
local lastUiAt = 0
local booted = false
local queueLabel = "-"
local quietFed = 0
local quietDone = 0
local packRr = 1
-- Sticky AE buffer: 100 identical crafts refill the same buffer one-by-one.
local activeBuf = nil
local drainSweep = 0

local function setStatus(msg, forcePrint)
    msg = msg or ""
    local now = os.clock()
    local same = msg == lastStatus
    lastStatus = msg
    if forcePrint or (not same and (now - lastStatusAt) >= 5) then
        lastStatusAt = now
        if msg ~= "" then
            print("ebf: " .. msg)
        end
    end
end

local function flushQuiet()
    if quietFed <= 0 and quietDone <= 0 then
        return
    end
    local msg = ("fed +%d  done +%d"):format(quietFed, quietDone)
    quietFed = 0
    quietDone = 0
    lastStatus = msg
    lastStatusAt = os.clock()
    print("ebf: " .. msg)
end

local function totals()
    local fed, drained = 0, 0
    for _, st in pairs(states) do
        fed = fed + (st.fed or 0)
        drained = drained + (st.drained or 0)
    end
    return fed, drained
end

local function anyInflight()
    for i = 1, #packList do
        if (packList[i].inflight or 0) > 0 then
            return true
        end
    end
    return false
end

local function refreshUi(force)
    local now = os.clock()
    if not force and (now - lastUiAt) < 2.0 then
        return
    end
    lastUiAt = now
    local itemsPer = tonumber(config.items_per_recipe) or 1
    local view = {}
    for i = 1, #packList do
        local st = packList[i]
        view[i] = {
            index = st.pair or ((st.index or 0) + 1),
            inflight = furnace.bufferedUnits(st, itemsPer),
            lastRecipe = st.lastRecipe,
        }
    end
    local fed, drained = totals()
    ui.draw(net.monitor, {
        furnaces = view,
        bufferCount = #(net.buffers or {}),
        maxInflight = config.max_inflight,
        status = lastStatus,
        queueLabel = queueLabel,
        fedTotal = fed,
        drainedTotal = drained,
    })
end

local function rescan(reason, showBoot)
    net = discover.scan(config)
    states = furnace.mergeStates(states, net.furnaces or {})
    packList = furnace.listByIndex(states)
    dirty = false
    packRr = 1
    activeBuf = nil
    drainSweep = 0
    if reason then
        print("ebf: rescan (" .. tostring(reason) .. ")")
    end
    discover.printSummary(net)
    if #packList == 0 then
        setStatus("no hatch packs", true)
    elseif #(net.buffers or {}) == 0 then
        setStatus("no recipe buffers", true)
    elseif not net.hotSink then
        setStatus("missing hot_sink", true)
    elseif not net.aeSink then
        setStatus("missing ae_sink", true)
    end
    if showBoot or not booted then
        ui.boot(net.monitor, "scanning...")
        booted = true
    end
    refreshUi(true)
end

local function ensureNet()
    if dirty or #packList == 0 then
        rescan(dirty and "hotplug" or "init", not booted)
    end
    return #packList > 0
end

local function flushEvents()
    net_watch.flushEvents("ebf_flush")
end

--- Prefer sticky buffer; only scan all when we have no active source.
local function resolveActiveBuffer(buffers)
    buffers = buffers or {}
    local n = #buffers
    if n == 0 then
        activeBuf = nil
        return nil
    end

    if activeBuf then
        local known = false
        for i = 1, n do
            if buffers[i] == activeBuf then
                known = true
                break
            end
        end
        if known and recipe.isNonEmpty(activeBuf) then
            return activeBuf
        end
        -- AE one-recipe lock: same buffer often refills next. Wait briefly.
        if known then
            for _ = 1, 6 do
                sleep(0)
                if recipe.isNonEmpty(activeBuf) then
                    return activeBuf
                end
            end
        end
        activeBuf = nil
    end

    for i = 1, n do
        local name = buffers[i]
        if recipe.isNonEmpty(name) then
            activeBuf = name
            return activeBuf
        end
    end
    return nil
end

--- Drain packs with work; rare full sweep catches missed outputs.
local function drainPass(fullSweep)
    local hotPer = tonumber(config.hot_per_recipe) or 1
    local itemsPer = tonumber(config.items_per_recipe) or 1
    local grace = tonumber(config.craft_grace) or 8
    local done = 0
    for i = 1, #packList do
        local st = packList[i]
        local busy = (st.inflight or 0) > 0
        if fullSweep or busy then
            local _, _, _, d = furnace.drain(st, net.hotSink, net.aeSink, hotPer)
            done = done + d
            if (st.inflight or 0) > 0 then
                done = done + furnace.reconcile(st, itemsPer, grace)
            end
        end
    end
    return done
end

--- Fan out from one sticky AE buffer across furnace packs (least-loaded).
local function feedPass()
    local maxInf = tonumber(config.max_inflight) or 8
    local itemsPer = tonumber(config.items_per_recipe) or 1
    local fluidPer = tonumber(config.fluid_per_recipe) or 0
    local buffers = net.buffers or {}
    if #buffers == 0 then
        return 0
    end

    local buf = resolveActiveBuffer(buffers)
    if not buf then
        return 0
    end

    local fed = 0
    local maxVisits = math.max(4, #packList)

    for _ = 1, maxVisits do
        local st
        st, packRr = furnace.pickTarget(states, maxInf, packList, packRr)
        if not st then
            -- All packs full — keep sticky buf, wait for drain.
            break
        end

        local ok, units, _, _, err, movedSnap = recipe.pushRecipeUnits(
            buf,
            st.inputBus,
            st.inputHatch,
            itemsPer,
            fluidPer,
            1, -- AE lock: one full recipe (dust + N2) per push
            false
        )
        if ok and (units or 0) > 0 then
            st.inflight = (st.inflight or 0) + units
            st.fed = (st.fed or 0) + units
            st.lastFeedAt = furnace._nowSeconds()
            st.lastRecipe = recipe.label(movedSnap)
            st.lastError = nil
            fed = fed + units
            quietFed = quietFed + units
            queueLabel = st.lastRecipe or queueLabel
            -- Buffer emptied; AE may refill the same one — stay sticky, re-resolve.
            if not recipe.isNonEmpty(buf) then
                local again = resolveActiveBuffer(buffers)
                if not again then
                    break
                end
                buf = again
            end
        elseif err and err ~= "empty" then
            st.lastError = err
            if tostring(err):find("stuck", 1, true) then
                st.inflight = maxInf
            else
                setStatus("push fail " .. tostring(st.label) .. ": " .. tostring(err), true)
                break
            end
        else
            -- empty: try sticky wait / other buffers once
            activeBuf = nil
            buf = resolveActiveBuffer(buffers)
            if not buf then
                break
            end
        end
    end

    if fed == 0 and not activeBuf then
        queueLabel = "-"
    end
    return fed
end

local function tick()
    if not ensureNet() then
        refreshUi(false)
        return false
    end

    local worked = false
    for _ = 1, 8 do
        drainSweep = drainSweep + 1
        local fullSweep = (drainSweep % 24 == 0) or not anyInflight()
        local done = drainPass(fullSweep)
        if done > 0 then
            quietDone = quietDone + done
            worked = true
        end
        local fed = feedPass()
        if fed > 0 then
            worked = true
        end
        if fed == 0 and done == 0 then
            break
        end
        sleep(0)
    end

    if quietFed > 0 or quietDone > 0 then
        if (os.clock() - lastStatusAt) >= 2 then
            flushQuiet()
        else
            lastStatus = ("fed +%d  done +%d"):format(quietFed, quietDone)
        end
    elseif not worked then
        local st = furnace.pickTarget(states, config.max_inflight, packList, packRr)
        if not st then
            setStatus("full — waiting on outputs")
        elseif activeBuf then
            setStatus("waiting AE refill " .. tostring(activeBuf))
        else
            setStatus("idle — waiting for recipes")
        end
    end

    refreshUi(false)
    return worked
end

print(("ebf: cfg %s%s"):format(
    tostring(cfgPath),
    cfgLoaded and " (loaded)" or " (defaults)"
))
print(("ebf: max_inflight=%s sticky-buffer fan-out"):format(
    tostring(config.max_inflight)
))
rescan("start", true)
flushEvents()
dirty = false

local poll = tonumber(config.poll) or 0
local idleWait = math.max(poll, 0.05)

while true do
    local worked = tick()
    if net_watch.sleepWatch(worked and 0 or idleWait) then
        dirty = true
    end
end
