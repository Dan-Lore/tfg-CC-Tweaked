-- Advanced Peripherals ME Bridge helpers (TFG AP ~0.7).

local ae_bridge = {}

local function callList(bridge, method)
    if not bridge or type(bridge[method]) ~= "function" then
        return nil
    end
    local ok, a = pcall(function()
        local r = bridge[method]()
        if type(r) == "table" then
            return r
        end
        r = bridge[method]({})
        if type(r) == "table" then
            return r
        end
        return nil
    end)
    if ok then
        return a
    end
    return nil
end

function ae_bridge.wrap(want)
    if want and peripheral.isPresent(want) then
        local p = peripheral.wrap(want)
        if p and (p.getItem or p.listItems or p.exportItem or p.craftItem) then
            return p, want
        end
    end
    for _, n in ipairs(peripheral.getNames()) do
        local t = peripheral.getType(n)
        if t == "meBridge" or t == "me_bridge" then
            return peripheral.wrap(n), n
        end
    end
    return nil, nil
end

function ae_bridge.getItemAmount(bridge, name)
    if not bridge or not name then
        return 0
    end
    if type(bridge.getItem) == "function" then
        local ok, info = pcall(function()
            return bridge.getItem({ name = name })
        end)
        if ok and type(info) == "table" then
            return tonumber(info.amount or info.count) or 0
        end
    end
    local items = callList(bridge, "listItems")
    if type(items) ~= "table" then
        return 0
    end
    local found = 0
    local function check(it)
        if type(it) == "table" and tostring(it.name) == name then
            found = tonumber(it.amount or it.count) or 0
        end
    end
    if #items > 0 then
        for i = 1, #items do
            check(items[i])
        end
    else
        for _, it in pairs(items) do
            check(it)
        end
    end
    return found
end

local function normalizeExport(ok, a, b)
    if not ok then
        return 0, tostring(a)
    end
    if type(a) == "number" then
        return a, b
    end
    if type(a) == "table" and (a.count or a.amount) then
        return tonumber(a.count or a.amount) or 0, b
    end
    if a == nil and type(b) == "string" then
        return 0, b
    end
    return tonumber(a) or 0, b
end

--- AP 0.7: exportItem(item, direction). Some builds take (direction, item).
function ae_bridge.exportItem(bridge, name, count, direction)
    if not bridge or type(bridge.exportItem) ~= "function" then
        return 0, "no exportItem"
    end
    count = math.max(0, math.floor(tonumber(count) or 0))
    if count < 1 then
        return 0, nil
    end
    local filter = { name = name, count = count }
    local ok, a, b = pcall(bridge.exportItem, filter, direction)
    local n, err = normalizeExport(ok, a, b)
    if n > 0 or (ok and err == nil) then
        return n, err
    end
    local ok2, a2, b2 = pcall(bridge.exportItem, direction, filter)
    return normalizeExport(ok2, a2, b2)
end

--- AP 0.7: export straight to a named inventory on the CC network (no adjacent chest).
function ae_bridge.exportItemToPeripheral(bridge, name, count, container)
    if not bridge or not container then
        return 0, "no target"
    end
    count = math.max(0, math.floor(tonumber(count) or 0))
    if count < 1 then
        return 0, nil
    end
    local filter = { name = name, count = count }
    if type(bridge.exportItemToPeripheral) == "function" then
        local ok, a, b = pcall(bridge.exportItemToPeripheral, filter, container)
        local n, err = normalizeExport(ok, a, b)
        if n > 0 or ok then
            return n, err
        end
    end
    -- Some AP builds accept a peripheral name as the exportItem "direction".
    if type(bridge.exportItem) == "function" then
        return ae_bridge.exportItem(bridge, name, count, container)
    end
    return 0, "no exportItemToPeripheral"
end

function ae_bridge.isItemCraftable(bridge, name, count)
    if not bridge or not name then
        return false, "no bridge"
    end
    count = math.max(1, math.floor(tonumber(count) or 1))
    local filter = { name = name, count = count }
    if type(bridge.isItemCraftable) == "function" then
        local ok, res, err = pcall(bridge.isItemCraftable, filter)
        if ok then
            if res == true then
                return true, nil
            end
            if res == false then
                return false, err or "not craftable"
            end
            -- some builds return boolean as first only
            return res and true or false, err
        end
    end
    if type(bridge.craftItem) ~= "function" then
        return false, "no craftItem"
    end
    -- Probe without committing: if craftable check missing, allow attempt.
    return true, "unverified"
end

local function filterName(obj)
    if type(obj) ~= "table" then
        return nil
    end
    if type(obj.name) == "string" then
        return obj.name
    end
    if type(obj.item) == "table" and type(obj.item.name) == "string" then
        return obj.item.name
    end
    if type(obj.getItem) == "function" then
        local ok, item = pcall(obj.getItem)
        if ok and type(item) == "table" and type(item.name) == "string" then
            return item.name
        end
    end
    if type(obj.getRequestedItem) == "function" then
        local ok, item = pcall(obj.getRequestedItem)
        if ok and type(item) == "table" and type(item.name) == "string" then
            return item.name
        end
    end
    return nil
end

local function filterCount(obj)
    if type(obj) ~= "table" then
        return 0
    end
    local n = tonumber(obj.count or obj.amount or obj.total or obj.requested)
    if n then
        return math.max(0, math.floor(n))
    end
    if type(obj.item) == "table" then
        n = tonumber(obj.item.count or obj.item.amount)
        if n then
            return math.max(0, math.floor(n))
        end
    end
    if type(obj.getRequestedItem) == "function" then
        local ok, item = pcall(obj.getRequestedItem)
        if ok and type(item) == "table" then
            n = tonumber(item.count or item.amount)
            if n then
                return math.max(0, math.floor(n))
            end
        end
    end
    return 0
end

--- AP 0.7 isItemCrafting; 0.8+ isCrafting. True if any job for name is active.
function ae_bridge.isItemCrafting(bridge, name)
    if not bridge or not name then
        return false
    end
    local filter = { name = name }
    if type(bridge.isItemCrafting) == "function" then
        local ok, res = pcall(bridge.isItemCrafting, filter)
        if ok then
            return res == true
        end
    end
    if type(bridge.isCrafting) == "function" then
        local ok, res = pcall(bridge.isCrafting, filter)
        if ok then
            return res == true
        end
    end
    return false
end

--- Sum requested counts from active craft jobs for name.
-- Returns amount, known. known=false means a job exists but amount is opaque —
-- caller must not schedule another craft for that item.
function ae_bridge.craftingAmount(bridge, name)
    if not bridge or not name then
        return 0, true
    end
    local total = 0
    local sawJob = false
    local listed = false
    local tasks = callList(bridge, "getCraftingTasks")
    if type(tasks) ~= "table" then
        tasks = callList(bridge, "listCraftingJobs")
    end
    if type(tasks) == "table" then
        listed = true
        local function consider(job)
            if filterName(job) == name then
                sawJob = true
                local n = filterCount(job)
                if n > 0 then
                    total = total + n
                end
            end
        end
        if #tasks > 0 then
            for i = 1, #tasks do
                consider(tasks[i])
            end
        else
            for _, job in pairs(tasks) do
                consider(job)
            end
        end
    end
    if listed then
        if sawJob and total == 0 then
            return 0, false
        end
        return total, true
    end
    if ae_bridge.isItemCrafting(bridge, name) then
        return 0, false
    end
    return 0, true
end

--- Request craft. Returns ok, errMessage.
function ae_bridge.craftItem(bridge, name, count)
    if not bridge or type(bridge.craftItem) ~= "function" then
        return false, "no craftItem"
    end
    count = math.max(1, math.floor(tonumber(count) or 1))
    local filter = { name = name, count = count }
    local ok, a, b = pcall(bridge.craftItem, filter)
    if not ok then
        return false, tostring(a)
    end
    if a == false then
        return false, b or "craft failed"
    end
    if a == nil and type(b) == "string" then
        return false, b
    end
    -- 0.8 may return a job table; treat as success.
    if type(a) == "table" or a == true or a == nil then
        return true, nil
    end
    return true, nil
end

return ae_bridge
