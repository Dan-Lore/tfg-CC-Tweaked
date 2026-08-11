-- Even N-per-machine feed from storages. No drain, no pattern providers.
--
-- Bundle:  python tools/bundle_project.py ae2_feed
-- Deploy:  dist/ae2_feed.lua  (startup: shell.run("ae2_feed"))

package.path = package.path
    .. ";/ae2_feed/?.lua;ae2_feed/?.lua;/shared/?.lua;shared/?.lua"

local config = require("config")
local discover = require("discover")
local move = require("move")

local N = tonumber(config.N) or 0
if N <= 0 then
    error("ae2_feed/config.lua: set N > 0")
end

local net = { machines = {}, storages = {} }
local dirty = false
-- Ignore peripheral events until the first start scan finishes (boot queues attaches).
local armed = false
local lastStatus = ""
local lastStatusAt = 0

local function setStatus(msg)
    local now = os.clock()
    if msg == lastStatus and (now - lastStatusAt) < 2 then
        return
    end
    lastStatus = msg
    lastStatusAt = now
    print("ae2_feed: " .. msg)
end

local function rescan(reason)
    net = discover.scan(config)
    dirty = false
    if reason then
        print("ae2_feed: rescan (" .. tostring(reason) .. ")")
    end
    discover.printSummary(net)
    if #net.storages == 0 then
        setStatus("no storages — auto crate/barrel/chest… or STORAGES = { \"name\" }")
    elseif #net.machines == 0 then
        setStatus("no machines found")
    end
end

local function ensureNet()
    if dirty or #net.machines == 0 or #net.storages == 0 then
        rescan(dirty and "hotplug" or "init")
    end
    return #net.machines > 0 and #net.storages > 0
end

local function watchPeripherals()
    while true do
        local ev = os.pullEvent()
        if armed and (ev == "peripheral" or ev == "peripheral_detach") then
            dirty = true
        end
    end
end

local function tick()
    if not ensureNet() then
        return
    end

    local storages = net.storages
    local machines = net.machines
    local inputItem = move.firstItem(storages)
    if not inputItem then
        return
    end

    local free = move.freeMachines(machines, inputItem)
    if #free == 0 then
        setStatus("wait — no free machine for " .. inputItem)
        return
    end

    local stock = move.countInMany(storages, inputItem)
    local feeds = math.min(math.floor(stock / N), #free)
    if feeds <= 0 then
        setStatus(("wait — need %d x %s (have %d)"):format(N, inputItem, stock))
        return
    end

    local targets = {}
    for i = 1, feeds do
        targets[i] = free[i]
    end

    local fed = move.distribute(storages, targets, inputItem, N)
    if fed > 0 then
        setStatus(("fed %d x%d %s"):format(fed, N, inputItem))
    else
        setStatus("push failed — machine rejected items")
    end
end

local function mainLoop()
    print(("ae2_feed: N=%d"):format(N))
    rescan("start")
    dirty = false
    armed = true
    while true do
        tick()
        sleep(0)
    end
end

parallel.waitForAny(mainLoop, watchPeripherals)
