-- Railgun loader fill checks + relay pulse (ported from projects/railgun).

local par = require("par")

local railgun_hw = {}

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

-- Loader slot counts never change for a given peripheral name; size() is a main-thread call.
local sizeCache = {}

function railgun_hw.resetCache()
    sizeCache = {}
end

local function invSize(name, inv)
    local s = sizeCache[name]
    if s then
        return s
    end
    s = 0
    if type(inv.size) == "function" then
        local ok, n = pcall(inv.size)
        if ok then
            s = tonumber(n) or 0
        end
    end
    if s > 0 then
        sizeCache[name] = s
    end
    return s
end

--- GT programmed-circuit ghost/item in the bus inventory — not cargo.
local function isConfigCircuit(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    local short = (name:match("([^:/]+)$") or name):lower()
    -- Universal circuits are cargo. Only the GT programmed slot is ignored.
    return short:find("programmed", 1, true) ~= nil
        or short:find("programmable", 1, true) ~= nil
end

local function readSlotMap(inv, size)
    local list = {}
    local listedOk = false
    if type(inv.list) == "function" then
        local ok, listed = pcall(inv.list)
        if ok and type(listed) == "table" then
            listedOk = true
            for slot, item in pairs(listed) do
                list[slot] = item
            end
        end
    end
    -- An empty list() is a genuinely empty inventory; per-slot probing costs one tick per slot.
    if not listedOk and type(inv.getItemDetail) == "function" and size > 0 then
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
local function fillFromList(list, size)
    if size < 1 then
        return false, 0, 0, 0
    end
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

    local freeAllowed = circuitSeen and 0 or 1
    local full = cargoOccupied > 0 and cargoEmpty <= freeAllowed
    return full, cargoOccupied, cargoEmpty, size
end

local function addCargo(totals, list)
    for _, item in pairs(list) do
        if item and not isConfigCircuit(item.name) then
            local count = tonumber(item.count) or 0
            if count > 0 and item.name then
                totals[item.name] = (totals[item.name] or 0) + count
            end
        end
    end
end

--- Read one inventory: slot map + size, or nil when absent.
local function readLoader(name)
    if not name or not peripheral.isPresent(name) then
        return nil
    end
    local inv = peripheral.wrap(name)
    if not inv then
        return nil
    end
    local size = invSize(name, inv)
    return readSlotMap(inv, size), size
end

function railgun_hw.loaderFill(name)
    local list, size = readLoader(name)
    if not list then
        return false, 0, 0, 0
    end
    return fillFromList(list, size)
end

--- Sum cargo counts across loaders. Programmed-circuit slots are omitted.
function railgun_hw.cargoTotals(loaders, width)
    local totals = {}
    loaders = loaders or {}
    local lists = {}
    par.each(#loaders, function(i)
        lists[i] = readLoader(loaders[i])
    end, width)
    for i = 1, #loaders do
        if lists[i] then
            addCargo(totals, lists[i])
        end
    end
    return totals
end

--- One list() per loader → cargo totals + fill state (replaces separate cargoTotals /
-- loaderFull / fillSnapshot passes, each of which re-read every loader).
-- Returns { totals, full = {name=true}, present = {name=true}, fullCount, missing, n, at }.
function railgun_hw.scan(loaders, width)
    loaders = loaders or {}
    local at = os.clock()
    local lists, sizes = {}, {}
    par.each(#loaders, function(i)
        lists[i], sizes[i] = readLoader(loaders[i])
    end, width)
    local res = {
        totals = {},
        full = {},
        present = {},
        fullCount = 0,
        missing = 0,
        n = #loaders,
        at = at,
    }
    for i = 1, #loaders do
        local name = loaders[i]
        local list = lists[i]
        if not list then
            res.missing = res.missing + 1
        else
            res.present[name] = true
            addCargo(res.totals, list)
            if fillFromList(list, sizes[i] or 0) then
                res.full[name] = true
                res.fullCount = res.fullCount + 1
            end
        end
    end
    return res
end

--- allFull() equivalent on a scan result (absent loaders count as not full).
function railgun_hw.scanAllFull(scan, loaders, expected)
    loaders = loaders or {}
    if #loaders == 0 or not scan then
        return false
    end
    expected = tonumber(expected) or 0
    if expected > 0 and #loaders < expected then
        return false
    end
    for i = 1, #loaders do
        if not scan.full[loaders[i]] then
            return false
        end
    end
    return true
end

function railgun_hw.loaderFull(name)
    local full = railgun_hw.loaderFill(name)
    return full
end

function railgun_hw.fillSnapshot(loaders)
    local full = 0
    local missing = 0
    local sample = nil
    for i = 1, #loaders do
        local name = loaders[i]
        if not peripheral.isPresent(name) then
            missing = missing + 1
        else
            local isFull, cargo, empty, size = railgun_hw.loaderFill(name)
            if isFull then
                full = full + 1
            elseif not sample then
                sample = { name = name, cargo = cargo, empty = empty, size = size }
            end
        end
    end
    return full, #loaders, missing, sample
end

function railgun_hw.allFull(loaders, expected)
    if #loaders == 0 then
        return false
    end
    expected = tonumber(expected) or 0
    if expected > 0 and #loaders < expected then
        return false
    end
    for i = 1, #loaders do
        if not railgun_hw.loaderFull(loaders[i]) then
            return false
        end
    end
    return true
end

local function setRelayOutputs(relay, sideCfg, on)
    sideCfg = tostring(sideCfg or "back"):lower()
    if sideCfg == "all" then
        for i = 1, #SIDES do
            pcall(relay.setOutput, SIDES[i], on)
        end
        return
    end
    pcall(relay.setOutput, sideCfg, on)
end

--- Pulse relay. cfg: relay_side, pulse (seconds).
function railgun_hw.pulseRelay(relayName, cfg)
    cfg = cfg or {}
    local pulse = tonumber(cfg.pulse) or 3
    if pulse < 0.05 then
        pulse = 0.05
    end
    if not relayName or not peripheral.isPresent(relayName) then
        return false, "нет реле"
    end
    local relay = peripheral.wrap(relayName)
    if not relay or type(relay.setOutput) ~= "function" then
        if redstone and type(redstone.setOutput) == "function"
            and (relayName == "top" or relayName == "bottom"
                or relayName == "left" or relayName == "right"
                or relayName == "front" or relayName == "back") then
            redstone.setOutput(relayName, true)
            sleep(pulse)
            redstone.setOutput(relayName, false)
            return true
        end
        return false, "реле без выхода"
    end

    setRelayOutputs(relay, cfg.relay_side, true)
    sleep(pulse)
    setRelayOutputs(relay, cfg.relay_side, false)
    return true
end

return railgun_hw
