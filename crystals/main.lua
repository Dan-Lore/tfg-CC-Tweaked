-- Laser engraver gem upgrade controller (CC: Tweaked / TFG).
-- Buffer on top, monitor on left, HV laser engravers on the network.
--
-- Bundle:  python tools/bundle_project.py crystals
-- Deploy:  dist/crystals.lua + crystals.cfg  (startup: shell.run("crystals"))

package.path = package.path
    .. ";/crystals/?.lua;crystals/?.lua;/shared/?.lua;shared/?.lua"

local configMod = require("config")
local discover = require("discover")
local feed = require("feed")
local sort = require("sort")
local ui = require("ui")
local gems = require("gems")
local net_watch = require("net_watch")

local config = configMod.load()
if config.ALIASES then
    for i = 1, #config.ALIASES do
        local a = config.ALIASES[i]
        gems.addAlias(a.item, a.material, a.tier)
    end
end
local net = { machines = {}, buffer = nil, overflow = {}, monitor = nil, monitorName = nil }
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

local function bufferList()
    local list = {}
    if net.buffer then
        list[#list + 1] = net.buffer
    end
    local ov = net.overflow or {}
    for i = 1, #ov do
        if ov[i] ~= net.buffer then
            list[#list + 1] = ov[i]
        end
    end
    return list
end

local function rescan(reason, showBoot)
    net = discover.scan(config)
    if not net.overflow then
        net.overflow = {}
    end
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
    net_watch.flushEvents("crystals_flush")
end

--- Sleep full duration; note hotplug but do not wake early (avoid rescan storms).
local function sleepWatch(seconds)
    net_watch.sleepDrain(seconds, function()
        dirty = true
    end)
    return false
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

    local result = feed.tick(bufferList(), net.machines, {
        maxStack = config.MAX_STACK,
        batch = config.BATCH,
    })

    local didWork = (result.moved or 0) > 0
    local status = result.status
    local pairsLeft = countPairs(result.stock)

    -- Main crate is the intake; CC spills bulk even stacks into overflow to keep room.
    local ov = net.overflow or {}
    if #ov > 0 and not result.xferFail then
        local spilled, spillMsg = sort.spillTo(net.buffer, ov, {
            keepFree = config.KEEP_FREE,
            maxMoves = 12,
        })
        if spilled and spilled > 0 then
            didWork = true
            status = spillMsg or ("spill " .. spilled)
            setStatus(status)
        elseif spillMsg == "overflow full" then
            status = "overflow full"
        elseif spillMsg == "overflow missing" then
            dirty = true
        end
    end

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
            if detail == "ok" or detail == "chest full" then
                -- Main may be packed; still tidy overflow crates.
                local ov = net.overflow or {}
                for i = 1, #ov do
                    sort.buffer(ov[i], { maxStack = config.MAX_STACK })
                    sleep(0)
                end
            end
            if detail == "ok" then
                status = result.status
            elseif detail == "chest full" and #(net.overflow or {}) > 0 then
                local spilled = sort.spillTo(net.buffer, net.overflow, {
                    keepFree = config.KEEP_FREE,
                    maxMoves = 8,
                })
                if spilled and spilled > 0 then
                    lastSortAt = now - SORT_COOLDOWN
                    status = "spill then sort"
                else
                    status = "main full, using overflow"
                end
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
