-- Product tank discovery + capacity / readTank (CC: Tweaked / TFG).

local net_watch = require("net_watch")

local M = {}

local function safeCall(name, method, ...)
    return net_watch.safeCall(name, method, ...)
end

local function indexFromName(name)
    return tonumber(name:match("_(%d+)$"))
end

function M.isProductTank(name, cfg)
    if name:find(cfg.tank_substr, 1, true) then
        return true
    end
    if cfg.tank_also and cfg.tank_also ~= "" and name:find(cfg.tank_also, 1, true) then
        return true
    end
    return false
end

local function capacityFromTierName(name, cfg)
    local lower = name:lower()
    local tierName = lower:match("^gtceu:(%w+)_super_tank")
        or lower:match("^gtceu:(%w+)_quantum_tank")
        or lower:match(":(%w+)_super_tank")
        or lower:match(":(%w+)_quantum_tank")
    if not tierName then
        return nil
    end
    local tier = (cfg.tier_from_name or {})[tierName]
    if tier == nil then
        return nil
    end
    local base = cfg.tier_base_mb or (4000 * 1000)
    if tier < 1 then
        return base -- ULV edge: treat as base
    end
    return base * (2 ^ (tier - 1))
end

--- Probe capacity: tanks().capacity → getTankCapacity/getCapacity → GT tier from name → cache.
local function resolveCapacity(name, tanksTable, cached, cfg)
    if cached and cached > 0 then
        return cached, "cache"
    end

    if type(tanksTable) == "table" then
        for _, slot in pairs(tanksTable) do
            if type(slot) == "table" then
                local cap = tonumber(slot.capacity) or tonumber(slot.maxAmount) or tonumber(slot.max_amount)
                if cap and cap > 0 then
                    return cap, "tanks()"
                end
            end
        end
    end

    local methods = {
        { "getTankCapacity", 1 },
        { "getTankCapacity", 0 },
        { "getCapacity" },
        { "getFluidCapacity" },
        { "getMaxFluidAmount" },
    }
    for i = 1, #methods do
        local m = methods[i]
        local v
        if m[2] ~= nil then
            v = safeCall(name, m[1], m[2])
        else
            v = safeCall(name, m[1])
        end
        v = tonumber(v)
        if v and v > 0 then
            return v, m[1]
        end
    end

    local fromTier = capacityFromTierName(name, cfg)
    if fromTier and fromTier > 0 then
        return fromTier, "tier"
    end

    return nil, "unknown"
end

function M.readTank(name, prev, cfg)
    local amount, fluid = 0, nil
    local ok, list = pcall(function()
        return peripheral.call(name, "tanks")
    end)
    if ok and type(list) == "table" then
        for _, slot in pairs(list) do
            if type(slot) == "table" and slot.amount then
                amount = amount + (tonumber(slot.amount) or 0)
                if not fluid and slot.name then
                    fluid = slot.name
                end
            end
        end
    end

    local prevCap = prev and prev.capacity or nil
    local capacity, src = resolveCapacity(name, ok and list or nil, prevCap, cfg)
    if not capacity or capacity <= 0 then
        capacity = math.max(amount, 1)
        src = src or "fallback"
    end

    local ratio = amount / capacity
    if ratio > 1 then
        ratio = 1
    end
    if ratio < 0 then
        ratio = 0
    end

    return {
        name = name,
        index = indexFromName(name) or 0,
        amount = amount,
        capacity = capacity,
        capacitySrc = src,
        ratio = ratio,
        fluid = fluid or (prev and prev.fluid) or nil,
    }
end

--- Discover product tanks; preserve previous capacity cache by name.
function M.discover(cfg, prevList)
    local prev = {}
    if prevList then
        for _, t in ipairs(prevList) do
            prev[t.name] = t
        end
    end

    local list = {}
    for _, name in ipairs(peripheral.getNames()) do
        if M.isProductTank(name, cfg) then
            list[#list + 1] = M.readTank(name, prev[name], cfg)
        end
    end
    table.sort(list, function(a, b)
        if a.index == b.index then
            return a.name < b.name
        end
        return a.index < b.index
    end)
    return list
end

--- Re-read amounts for known tanks. Returns true if any tank missing (hotplug).
function M.refresh(list, cfg)
    local prev = {}
    for _, t in ipairs(list) do
        prev[t.name] = t
    end
    local dirty = false
    for i, t in ipairs(list) do
        if peripheral.isPresent(t.name) then
            list[i] = M.readTank(t.name, prev[t.name], cfg)
        else
            dirty = true
        end
    end
    return dirty
end

return M
