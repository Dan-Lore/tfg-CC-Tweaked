-- AE2 feed balancer: even N-per-machine feed from pattern providers + output return.
--
-- In-game layout (dedicated wired network):
--   identical GT machines + AE2 pattern providers + this computer (modems on all).
-- Do NOT let pattern providers auto-insert into a machine face — CC does the split.
--
-- Copy onto the computer: ae2_feed/* and root transfer.lua
-- Run: ae2_feed/main  (or paste startup to run this)

package.path = package.path .. ";/ae2_feed/?.lua;ae2_feed/?.lua;/?/?.lua"

local config = require("config")
local discover = require("discover")
local move = require("move")

local N = tonumber(config.N) or 0
if N <= 0 then
    error("ae2_feed/config.lua: set N to items per machine per cycle (> 0)")
end

local net = { machines = {}, providers = {} }
local dirty = true

local function rescan(reason)
    net = discover.scan(config)
    dirty = false
    if reason then
        print("ae2_feed: rescan (" .. tostring(reason) .. ")")
    end
    discover.printSummary(net)
end

local function ensureNet()
    if dirty or #net.machines == 0 or #net.providers == 0 then
        rescan(dirty and "hotplug" or "init")
    end
    return #net.machines > 0 and #net.providers > 0
end

-- Hotplug: mark dirty; main loop rescans without blocking on os.pullEvent.
local function watchPeripherals()
    while true do
        local ev = os.pullEvent()
        if ev == "peripheral" or ev == "peripheral_detach" then
            dirty = true
        end
    end
end

local function tick()
    if not ensureNet() then
        return false
    end

    local providers = net.providers
    local machines = net.machines
    local inputItem = move.firstProviderItem(providers)

    -- Always return outputs (and any leftovers when idle) to providers first.
    local drained = move.drainAll(machines, providers, inputItem)

    if not inputItem then
        return drained > 0
    end

    local free = move.freeMachines(machines, inputItem)
    if #free == 0 then
        return drained > 0
    end

    local stock = move.countProviders(providers, inputItem)
    local feeds = math.min(math.floor(stock / N), #free)
    if feeds <= 0 then
        return drained > 0
    end

    local targets = {}
    for i = 1, feeds do
        targets[i] = free[i]
    end

    local fed = move.distribute(providers, targets, inputItem, N)
    return drained > 0 or fed > 0
end

local function mainLoop()
    print(("ae2_feed: N=%d"):format(N))
    rescan("start")

    while true do
        local worked = tick()
        -- Yield every pass so CC never hits "too long without yielding".
        -- No timed sleep — poll as fast as the computer allows.
        sleep(0)
        if not worked then
            -- Still no delay beyond yield; next tick immediately after sleep(0).
        end
    end
end

parallel.waitForAny(mainLoop, watchPeripherals)
