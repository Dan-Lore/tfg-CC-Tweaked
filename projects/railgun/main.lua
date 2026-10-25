-- Pulse redstone_relay when every HV railgun input loader has no free slots.
-- After all-full, wait settle so stacks can top up; then pulse; then cooldown.
--
-- Bundle:  python tools/bundle_project.py railgun
-- Deploy:  dist/railgun.lua + railgun.cfg  (startup: shell.run("railgun"))

package.path = package.path
    .. ";/projects/railgun/?.lua;projects/railgun/?.lua;/projects/shared/?.lua;projects/shared/?.lua"

local configMod = require("config")
local discover = require("discover")
local net_watch = require("net_watch")

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

local config = configMod.load()
local net = { loaders = {}, relay = nil }
local dirty = false
local lastStatus = ""
local lastStatusAt = 0
local lastFireAt = 0
local settleSince = nil -- os.clock when all-full first held; nil if not settling

local function setStatus(msg)
    local now = os.clock()
    if msg == lastStatus and (now - lastStatusAt) < 2 then
        return
    end
    lastStatus = msg
    lastStatusAt = now
    print("railgun: " .. msg)
end

--- GT programmed-circuit ghost/item in the bus inventory — not cargo.
local function isConfigCircuit(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    local short = (name:match("([^:/]+)$") or name):lower()
    return short:find("circuit", 1, true) ~= nil
        or short:find("programmable", 1, true) ~= nil
end

local function readSlotMap(inv, size)
    local list = {}
    if type(inv.list) == "function" then
        local ok, listed = pcall(inv.list)
        if ok and type(listed) == "table" then
            for slot, item in pairs(listed) do
                list[slot] = item
            end
        end
    end
    -- Fallback when list() is empty/sparse but getItemDetail works.
    if next(list) == nil and type(inv.getItemDetail) == "function" and size > 0 then
        for slot = 1, size do
            local ok, detail = pcall(inv.getItemDetail, slot)
            if ok and detail and (tonumber(detail.count) or 0) > 0 then
                list[slot] = detail
            end
        end
    end
    return list
end

--- Space exhausted: every cargo slot occupied (partial stacks OK).
-- Ignores one reserved programmed-circuit slot (empty or holding a circuit item).
local function loaderFill(name)
    if not name or not peripheral.isPresent(name) then
        return false, 0, 0, 0
    end
    local inv = peripheral.wrap(name)
    if not inv then
        return false, 0, 0, 0
    end
    local size = 0
    if type(inv.size) == "function" then
        local ok, n = pcall(inv.size)
        if ok then
            size = tonumber(n) or 0
        end
    end
    if size < 1 then
        return false, 0, 0, 0
    end

    local list = readSlotMap(inv, size)
    local cargoOccupied = 0
    local cargoEmpty = 0
    local circuitSeen = false
    for slot = 1, size do
        local item = list[slot]
        if item and isConfigCircuit(item.name) then
            circuitSeen = true
        elseif item and (tonumber(item.count) or 0) > 0 then
            cargoOccupied = cargoOccupied + 1
        else
            cargoEmpty = cargoEmpty + 1
        end
    end

    -- One empty slot allowed for circuit when it is not present as an item.
    local freeAllowed = circuitSeen and 0 or 1
    local full = cargoOccupied > 0 and cargoEmpty <= freeAllowed
    return full, cargoOccupied, cargoEmpty, size
end

local function loaderFull(name)
    local full = loaderFill(name)
    return full
end

local function fillSnapshot(loaders)
    local full = 0
    local missing = 0
    local sample = nil
    for i = 1, #loaders do
        local name = loaders[i]
        if not peripheral.isPresent(name) then
            missing = missing + 1
        else
            local isFull, cargo, empty, size = loaderFill(name)
            if isFull then
                full = full + 1
            elseif not sample then
                sample = { name = name, cargo = cargo, empty = empty, size = size }
            end
        end
    end
    return full, #loaders, missing, sample
end

local function allFull(loaders)
    if #loaders == 0 then
        return false
    end
    local expected = tonumber(config.expected) or 0
    if expected > 0 and #loaders < expected then
        return false
    end
    for i = 1, #loaders do
        if not loaderFull(loaders[i]) then
            return false
        end
    end
    return true
end

local function setRelayOutputs(relay, on)
    local sideCfg = tostring(config.relay_side or "back"):lower()
    if sideCfg == "all" then
        for i = 1, #SIDES do
            pcall(relay.setOutput, SIDES[i], on)
        end
        return
    end
    pcall(relay.setOutput, sideCfg, on)
end

local function pulseRelay(relayName)
    if not relayName or not peripheral.isPresent(relayName) then
        return false, "no relay"
    end
    local relay = peripheral.wrap(relayName)
    if not relay or type(relay.setOutput) ~= "function" then
        if redstone and type(redstone.setOutput) == "function"
            and (relayName == "top" or relayName == "bottom"
                or relayName == "left" or relayName == "right"
                or relayName == "front" or relayName == "back") then
            redstone.setOutput(relayName, true)
            sleep(config.pulse)
            redstone.setOutput(relayName, false)
            return true
        end
        return false, "relay has no setOutput"
    end

    setRelayOutputs(relay, true)
    sleep(config.pulse)
    setRelayOutputs(relay, false)
    return true
end

local function rescan(reason)
    net = discover.scan(config)
    dirty = false
    settleSince = nil
    if reason then
        print("railgun: rescan (" .. tostring(reason) .. ")")
    end
    discover.printSummary(net, config)
end

local function ensureNet()
    if dirty or #net.loaders == 0 or not net.relay then
        rescan(dirty and "hotplug" or "init")
    end
    return #net.loaders > 0 and net.relay ~= nil
end

local function tick()
    if not ensureNet() then
        settleSince = nil
        if #net.loaders == 0 then
            setStatus("no loaders — check modem / loader_prefix")
        else
            setStatus("no relay — place redstone_relay on top (or set relay | name)")
        end
        return
    end

    local now = os.clock()
    local sinceFire = now - lastFireAt
    if lastFireAt > 0 and sinceFire < config.cooldown then
        settleSince = nil
        setStatus(("cooldown %.0fs"):format(config.cooldown - sinceFire))
        return
    end

    local full, total, missing, sample = fillSnapshot(net.loaders)
    if missing > 0 then
        dirty = true
        settleSince = nil
        setStatus(("missing %d loader(s) — rescanning"):format(missing))
        return
    end

    if not allFull(net.loaders) then
        settleSince = nil
        if sample then
            setStatus(("waiting %d/%d full (%s cargo=%d empty=%d size=%d)"):format(
                full,
                total,
                tostring(sample.name):gsub("^.*:", ""),
                sample.cargo,
                sample.empty,
                sample.size
            ))
        else
            setStatus(("waiting %d/%d full"):format(full, total))
        end
        return
    end

    local settleNeed = tonumber(config.settle) or 0
    if settleNeed > 0 then
        if not settleSince then
            settleSince = now
            setStatus(("settle 0/%.0fs — topping stacks"):format(settleNeed))
            return
        end
        local held = now - settleSince
        if held < settleNeed then
            setStatus(("settle %.0f/%.0fs — topping stacks"):format(held, settleNeed))
            return
        end
    end

    setStatus(("all %d full — pulse %ss"):format(total, tostring(config.pulse)))
    local ok, err = pulseRelay(net.relay)
    settleSince = nil
    lastFireAt = os.clock()
    if ok then
        setStatus(("fired — cooldown %ss"):format(tostring(config.cooldown)))
    else
        setStatus("pulse failed: " .. tostring(err))
    end
end

print(("railgun: prefix=%s expected=%s settle=%ss pulse=%ss poll=%ss cooldown=%ss side=%s"):format(
    tostring(config.loader_prefix),
    tostring(config.expected),
    tostring(config.settle),
    tostring(config.pulse),
    tostring(config.poll),
    tostring(config.cooldown),
    tostring(config.relay_side)
))
rescan("start")
net_watch.flushEvents("railgun_flush")
dirty = false

while true do
    tick()
    if net_watch.sleepWatch(config.poll) then
        dirty = true
    end
end
