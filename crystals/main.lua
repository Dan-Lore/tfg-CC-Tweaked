-- Laser engraver gem upgrade controller (CC: Tweaked / TFG).
-- Buffer on top, monitor on left, HV laser engravers on the network.
--
-- Bundle:  python tools/bundle_project.py crystals
-- Deploy:  dist/crystals.lua (config embedded; optional crystals.cfg overrides)

package.path = package.path
    .. ";/crystals/?.lua;crystals/?.lua;/shared/?.lua;shared/?.lua"

local configMod = require("config")
local discover = require("discover")
local feed = require("feed")
local sort = require("sort")
local ui = require("ui")

local config = configMod.load()
local net = { machines = {}, buffer = nil, monitor = nil, monitorName = nil }
local dirty = false
local lastStatus = ""
local lastSortAt = 0
local SORT_COOLDOWN = 3

local function setStatus(msg)
    lastStatus = msg
    print("crystals: " .. msg)
end

local function rescan(reason)
    net = discover.scan(config)
    dirty = false
    if reason then
        print("crystals: rescan (" .. tostring(reason) .. ")")
    end
    discover.printSummary(net)
    if not net.buffer then
        setStatus("no buffer: set buffer | top")
    elseif #net.machines == 0 then
        setStatus("no engravers found")
    end
    ui.boot(net.monitor, "scanning...")
end

local function ensureNet()
    if dirty or not net.buffer or #net.machines == 0 then
        rescan(dirty and "hotplug" or "init")
    end
    if net.buffer and not peripheral.isPresent(net.buffer) then
        dirty = true
        return false
    end
    return net.buffer ~= nil and #net.machines > 0
end

local function flushEvents()
    os.queueEvent("crystals_flush")
    while true do
        local ev = os.pullEvent()
        if ev == "crystals_flush" then
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
            dirty = true
            return true
        end
    end
end

local function tick()
    if not ensureNet() then
        ui.draw(net.monitor, {
            status = lastStatus,
            engravers = #(net.machines or {}),
            stock = {},
        })
        return false
    end

    local result = feed.tick(net.buffer, net.machines, {
        maxStack = config.MAX_STACK,
        batch = config.BATCH,
    })

    local didWork = (result.moved or 0) > 0
    local status = result.status

    if not didWork then
        local now = os.clock()
        if now - lastSortAt >= SORT_COOLDOWN then
            local sorted, detail = sort.buffer(net.buffer, { maxStack = config.MAX_STACK })
            lastSortAt = now
            if detail == "ok" then
                status = result.status
            else
                status = detail or (sorted and "sorted" or result.status)
                if detail and detail ~= result.status then
                    setStatus(tostring(detail))
                end
            end
        end
    else
        setStatus(status)
    end

    ui.draw(net.monitor, {
        engravers = result.engravers,
        busy = result.busy,
        queued = result.queued,
        empty = result.empty,
        stock = result.stock,
        moved = result.moved,
        status = status,
    })

    return didWork
end

print(("crystals: batch=%d max_stack=%d poll=%.2fs"):format(
    config.BATCH, config.MAX_STACK, config.POLL
))
rescan("start")
flushEvents()
dirty = false

while true do
    local worked = tick()
    if worked then
        sleepWatch(0)
    else
        sleepWatch(config.POLL)
    end
end
