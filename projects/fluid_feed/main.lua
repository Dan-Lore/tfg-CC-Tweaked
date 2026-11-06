-- Round-robin 144mb fluid feed into empty EV input hatches.
--
-- Bundle:  python tools/bundle_project.py fluid_feed
-- Deploy:  dist/fluid_feed.lua + fluid_feed.cfg  (startup: shell.run("fluid_feed"))

package.path = package.path
    .. ";/projects/fluid_feed/?.lua;projects/fluid_feed/?.lua;/projects/shared/?.lua;projects/shared/?.lua"

local configMod = require("config")
local discover = require("discover")
local move = require("move")
local ui = require("ui")
local net_watch = require("net_watch")

local config = configMod.load()
local amount = tonumber(config.AMOUNT) or 0
if amount <= 0 then
    error("fluid_feed.cfg: set amount | <mb> (> 0)")
end

local net = { buffer = nil, hatches = {}, monitor = nil, monitorName = nil }
local dirty = false
local rr = { fluidRR = 0, hatchRR = 0 }
local lastStatus = ""
local lastStatusAt = 0
local lastFluid = nil
local booted = false

local function setStatus(msg)
    local now = os.clock()
    if msg == lastStatus and (now - lastStatusAt) < 2 then
        return
    end
    lastStatus = msg
    lastStatusAt = now
    print("fluid_feed: " .. msg)
end

local function paint(extra)
    local hatches = net.hatches or {}
    local okN, emptyN, badN = move.hatchStats(hatches, amount)
    local total = #hatches
    -- Alarm: hatch has fluid, but not exactly `amount`. Empty is fine.
    local alarm = badN > 0
    ui.draw(net.monitor, {
        total = total,
        ok = okN,
        empty = emptyN,
        bad = badN,
        amount = amount,
        alarm = alarm,
        lastFluid = lastFluid,
        status = extra or lastStatus,
    })
end

local function rescan(reason, showBoot)
    net = discover.scan(config)
    dirty = false
    if reason then
        print("fluid_feed: rescan (" .. tostring(reason) .. ")")
    end
    discover.printSummary(net)
    if not net.buffer then
        setStatus("no buffer — set buffer | name in fluid_feed.cfg")
    elseif #(net.hatches or {}) == 0 then
        setStatus("no hatches found")
    end
    if showBoot or not booted then
        ui.boot(net.monitor, "scanning...")
        booted = true
    end
    paint()
end

local function ensureNet()
    if dirty or not net.buffer or #(net.hatches or {}) == 0 then
        rescan(dirty and "hotplug" or "init")
    end
    if net.buffer and not peripheral.isPresent(net.buffer) then
        dirty = true
        return false
    end
    return net.buffer ~= nil and #(net.hatches or {}) > 0
end

local function flushEvents()
    net_watch.flushEvents("fluid_feed_flush")
end

local function yieldAndWatch()
    if net_watch.sleepWatch(0) then
        dirty = true
    end
end

local function tick()
    if not ensureNet() then
        paint(lastStatus)
        return
    end

    local hatches = net.hatches
    local okN, emptyN, badN = move.hatchStats(hatches, amount)

    if emptyN == 0 then
        if badN > 0 then
            setStatus(("ALARM bad=%d"):format(badN))
        else
            setStatus(("idle — %d/%d ok"):format(okN, #hatches))
        end
        paint()
        return
    end

    local fluids = move.eligibleFluids(net.buffer, amount)
    if #fluids == 0 then
        setStatus(("wait — need %d mb (empty %d)"):format(amount, emptyN))
        paint()
        return
    end

    local pushed, fluidLabel = move.distribute(net.buffer, hatches, amount, rr, yieldAndWatch)
    if fluidLabel then
        lastFluid = fluidLabel
    end
    if pushed > 0 then
        setStatus(("push %d x%d"):format(pushed, amount))
    else
        setStatus("push failed")
    end
    paint()
end

print(("fluid_feed: amount=%d"):format(amount))
rescan("start", true)
flushEvents()
dirty = false
paint()

while true do
    tick()
    yieldAndWatch()
end
