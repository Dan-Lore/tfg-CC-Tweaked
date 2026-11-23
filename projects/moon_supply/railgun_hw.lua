-- Railgun loader fill checks + relay pulse (ported from projects/railgun).

local railgun_hw = {}

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

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
    if type(inv.list) == "function" then
        local ok, listed = pcall(inv.list)
        if ok and type(listed) == "table" then
            for slot, item in pairs(listed) do
                list[slot] = item
            end
        end
    end
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
function railgun_hw.loaderFill(name)
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

    local freeAllowed = circuitSeen and 0 or 1
    local full = cargoOccupied > 0 and cargoEmpty <= freeAllowed
    return full, cargoOccupied, cargoEmpty, size
end

--- Sum cargo counts across loaders. Programmed-circuit slots are omitted.
function railgun_hw.cargoTotals(loaders)
    local totals = {}
    loaders = loaders or {}
    for i = 1, #loaders do
        local name = loaders[i]
        if name and peripheral.isPresent(name) then
            local inv = peripheral.wrap(name)
            if inv then
                local size = 0
                if type(inv.size) == "function" then
                    local ok, n = pcall(inv.size)
                    if ok then
                        size = tonumber(n) or 0
                    end
                end
                local list = readSlotMap(inv, size)
                for _, item in pairs(list) do
                    if item and not isConfigCircuit(item.name) then
                        local count = tonumber(item.count) or 0
                        if count > 0 and item.name then
                            totals[item.name] = (totals[item.name] or 0) + count
                        end
                    end
                end
            end
        end
        if i % 4 == 0 then
            sleep(0)
        end
    end
    return totals
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
