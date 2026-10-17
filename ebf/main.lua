-- Electric blast furnace recipe feeder (CC: Tweaked / TFG).
-- Hatch index N = pair (N+1)L + (N+1)R sharing one set of 4 hatches.
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
local bufCursor = 1
local packRr = 1

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
        -- Show items actually in the input bus, not sticky ghosts.
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
    bufCursor = 1
    packRr = 1
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

local function drainAll()
    local hotPer = tonumber(config.hot_per_recipe) or 1
    local itemsPer = tonumber(config.items_per_recipe) or 1
    local grace = tonumber(config.craft_grace) or 45
    local done = 0
    for i = 1, #packList do
        local st = packList[i]
        local _, _, _, d = furnace.drain(st, net.hotSink, net.aeSink, hotPer)
        done = done + d
        done = done + furnace.reconcile(st, itemsPer, grace)
    end
    return done
end

local function feedPass()
    local maxInf = tonumber(config.max_inflight) or 6
    local itemsPer = tonumber(config.items_per_recipe) or 1
    local fluidPer = tonumber(config.fluid_per_recipe) or 0
    local buffers = net.buffers or {}
    local nBuf = #buffers
    if nBuf == 0 then
        return 0
    end

    local fed = 0
    local maxPushes = math.max(8, #packList * maxInf)

    for _ = 1, maxPushes do
        local st
        st, packRr = furnace.pickTarget(states, maxInf, packList, packRr)
        if not st then
            break
        end

        local pushed = false
        local checked = 0
        while checked < nBuf do
            if bufCursor > nBuf then
                bufCursor = 1
            end
            local buf = buffers[bufCursor]
            bufCursor = bufCursor + 1
            checked = checked + 1

            local ok, _, _, err, movedSnap = recipe.pushOneRecipe(
                buf,
                st.inputBus,
                st.inputHatch,
                itemsPer,
                fluidPer
            )
            if ok then
                st.inflight = (st.inflight or 0) + 1
                st.fed = (st.fed or 0) + 1
                st.lastFeedAt = furnace._nowSeconds()
                st.lastRecipe = recipe.label(movedSnap)
                st.lastError = nil
                fed = fed + 1
                quietFed = quietFed + 1
                queueLabel = st.lastRecipe or queueLabel
                pushed = true
                break
            elseif err and err ~= "empty" then
                st.lastError = err
                setStatus("push fail " .. tostring(st.label) .. ": " .. tostring(err), true)
                break
            end
        end

        if not pushed then
            break
        end
    end

    if fed == 0 then
        queueLabel = "-"
    end
    return fed
end

local function tick()
    if not ensureNet() then
        refreshUi(false)
        return false
    end

    -- One drain+feed per wake: a 64× loop re-flooded packs after sticky clear.
    local done = drainAll()
    if done > 0 then
        quietDone = quietDone + done
    end
    local fed = feedPass()
    local worked = fed > 0 or done > 0

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
print(("ebf: max_inflight=%s items_per_recipe=%s (fill pack before next)"):format(
    tostring(config.max_inflight),
    tostring(config.items_per_recipe or 1)
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
