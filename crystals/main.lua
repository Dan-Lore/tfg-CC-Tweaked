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
local lastRescanAt = -100
local SORT_COOLDOWN = 3
local RESCAN_COOLDOWN = 5
local booted = false

local function setStatus(msg)
    lastStatus = msg
    print("crystals: " .. msg)
end

local function rescan(reason, showBoot)
    net = discover.scan(config)
    dirty = false
    lastRescanAt = os.clock()
    if reason then
        print("crystals: rescan (" .. tostring(reason) .. ")")
    end
    discover.printSummary(net)
    if not net.buffer then
        setStatus("no buffer: set buffer | top")
    elseif #net.machines == 0 then
        setStatus("no engravers found")
    end
    -- Only flash "scanning..." on the very first boot, not on every hotplug.
    if showBoot or not booted then
        ui.boot(net.monitor, "scanning...")
        booted = true
    end
end

local function ensureNet()
    local now = os.clock()
    local needScan = false
    local reason = nil

    if not net.buffer or not peripheral.isPresent(net.buffer or "") then
        needScan = true
        reason = "buffer"
    elseif #net.machines == 0 then
        needScan = true
        reason = "machines"
    elseif dirty and (now - lastRescanAt) >= RESCAN_COOLDOWN then
        needScan = true
        reason = "hotplug"
    end

    if needScan then
        rescan(reason, reason == "buffer" and not booted)
    end

    if net.buffer and not peripheral.isPresent(net.buffer) then
        dirty = true
        return false
    end
    return net.buffer ~= nil
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
            -- Do not wake early into a rescan storm; finish the sleep.
        end
    end
end

local function countPairs(stock)
    local n = 0
    if not stock then
        return 0
    end
    for _, s in pairs(stock) do
        n = n + math.floor((s.even or 0) / 2)
    end
    return n
end

local function tick()
    if not ensureNet() then
        ui.draw(net.monitor, {
            status = lastStatus,
            engravers = 0,
            engraverTotal = #(net.machines or {}),
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
    local pairsLeft = countPairs(result.stock)

    -- Rescan later if many engravers dropped; ignore single blips.
    if (result.engravers or 0) == 0 and #net.machines > 0 then
        dirty = true
        status = "no live engravers"
    elseif result.missing and (result.engravers or 0) < math.max(1, math.floor(#net.machines / 2)) then
        dirty = true
    end

    if result.xferFail then
        status = "buffer not networked"
        setStatus(status)
    elseif #net.machines == 0 then
        dirty = true
        status = "no engravers found"
    end

    local canSort = not didWork
        and not result.xferFail
        and pairsLeft == 0
        and (result.engravers or 0) > 0

    if canSort then
        local now = os.clock()
        if now - lastSortAt >= SORT_COOLDOWN then
            local sorted, detail = sort.buffer(net.buffer, { maxStack = config.MAX_STACK })
            lastSortAt = now
            if detail == "ok" then
                status = result.status
            else
                status = detail or (sorted and "sorted" or result.status)
                if detail and detail ~= "ok" then
                    setStatus(tostring(detail))
                end
                if detail == "sort partial" then
                    lastSortAt = now - SORT_COOLDOWN
                end
            end
        end
    elseif didWork then
        setStatus(status)
    end

    ui.draw(net.monitor, {
        engravers = result.engravers,
        engraverTotal = #(net.machines or {}),
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
rescan("start", true)
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
