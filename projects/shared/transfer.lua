-- Item and fluid transfers between peripherals.
-- Item queries: exact id, or #namespace:path (item tag via getItemDetail / fallbacks).
-- Domain food/spoil/tag fallbacks are registered by craft/food.lua (optional).

local transfer = {}

local tagFallbacks = {} -- tagId -> predicate(itemName) -> bool
local spoilCheck = nil -- function(detail) -> bool
local foodItemCheck = nil -- function(name) -> bool

function transfer.registerTagFallback(tagId, fn)
    if type(tagId) == "string" and type(fn) == "function" then
        tagFallbacks[tagId] = fn
    end
end

function transfer.setSpoilCheck(fn)
    spoilCheck = fn
end

function transfer.setFoodItemCheck(fn)
    foodItemCheck = fn
end

function transfer.isTag(query)
    return type(query) == "string" and query:sub(1, 1) == "#"
end

function transfer.tagId(query)
    if not transfer.isTag(query) then
        return query
    end
    return query:sub(2)
end

--- Does inventory item (name + optional tags list) match query (exact or #tag)?
function transfer.matches(itemName, tags, query)
    if not query or query == "" then
        return true
    end
    if not transfer.isTag(query) then
        return itemName == query
    end
    local tagId = transfer.tagId(query)
    if type(tags) == "table" then
        for i = 1, #tags do
            if tags[i] == tagId then
                return true
            end
        end
        if tags[tagId] then
            return true
        end
    end
    local fb = tagFallbacks[tagId]
    if fb then
        return fb(itemName) == true
    end
    return false
end

--- TFC/Firmalife food we should inspect for spoil (when food module registered).
function transfer.isFoodItem(name)
    if foodItemCheck then
        return foodItemCheck(name) == true
    end
    return false
end

--- Best-effort spoil detect (delegates to registered check).
function transfer.isSpoiled(detail)
    if spoilCheck then
        return spoilCheck(detail) == true
    end
    return false
end

local function itemTagsFromDetail(detail)
    if not detail then
        return nil
    end
    if type(detail.tags) == "table" then
        return detail.tags
    end
    return nil
end

local function getDetail(inv, slot)
    if not inv or not inv.getItemDetail then
        return nil
    end
    local ok, detail = pcall(inv.getItemDetail, slot)
    if ok then
        return detail
    end
    return nil
end

-- GT/CC list() keys are sometimes strings; pullItems/pushItems need numeric slots.
local function slotNum(slot)
    local n = tonumber(slot)
    if n then
        return n
    end
    return slot
end

--- Fast slot filter: name-fallback tags skip getItemDetail on non-matches (huge fridge win).
local function slotUsable(inv, slot, itemName, itemQuery, allowSpoiled)
    if not itemName then
        return false
    end

    if not transfer.isTag(itemQuery) then
        if itemName ~= itemQuery then
            return false
        end
        if allowSpoiled or not transfer.isFoodItem(itemName) then
            return true
        end
        return not transfer.isSpoiled(getDetail(inv, slot))
    end

    local tagId = transfer.tagId(itemQuery)
    local fb = tagFallbacks[tagId]
    if fb and fb(itemName) == true then
        if allowSpoiled or not transfer.isFoodItem(itemName) then
            return true
        end
        return not transfer.isSpoiled(getDetail(inv, slot))
    end

    -- No name fallback: need NBT tags (and spoil) from detail.
    local detail = getDetail(inv, slot)
    if not allowSpoiled and transfer.isSpoiled(detail) then
        return false
    end
    return transfer.matches(itemName, itemTagsFromDetail(detail), itemQuery)
end

--- Move items from -> to matching itemQuery.
-- opts.preferPull: extract FROM a machine into storage (GT food often needs sink.pullItems).
-- Inserts into machines must NOT use machine.pullItems(storage) — GT can grab the wrong
-- fridge stack (e.g. cooked_pizza into processor_30 while asking for feta).
local function transferItems(from, to, itemQuery, amount, opts)
    if not from or not to or from == to then
        return 0
    end
    if not peripheral.isPresent(from) or not peripheral.isPresent(to) then
        return 0
    end
    local source = peripheral.wrap(from)
    if not source or not source.list then
        return 0
    end
    local sink = peripheral.wrap(to)
    local preferPull = opts and opts.preferPull == true
    if preferPull then
        if not (sink and sink.pullItems) and not source.pushItems then
            return 0
        end
    elseif not source.pushItems then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    amount = tonumber(amount) or 0
    if not moveAll and amount <= 0 then
        return 0
    end
    local allowSpoiled = opts and opts.allowSpoiled == true

    local listed = source.list()
    if not listed then
        return 0
    end

    local n = 0
    for rawSlot, item in pairs(listed) do
        local slot = slotNum(rawSlot)
        if not moveAll and movedTotal >= amount then
            break
        end
        if (moveAll or movedTotal < amount) and item and item.name then
            if slotUsable(source, slot, item.name, itemQuery, allowSpoiled) then
                local limit = moveAll and item.count or (amount - movedTotal)
                local moved = 0
                if preferPull and sink and sink.pullItems then
                    local ok, got = pcall(sink.pullItems, from, slot, limit)
                    if ok then
                        moved = tonumber(got) or 0
                    end
                end
                if moved < limit and source.pushItems then
                    local ok, got = pcall(source.pushItems, to, slot, limit - moved)
                    if ok then
                        moved = moved + (tonumber(got) or 0)
                    end
                end
                if preferPull and moved < limit and sink and sink.pullItems then
                    local ok, got = pcall(sink.pullItems, from, slot, limit - moved)
                    if ok then
                        moved = moved + (tonumber(got) or 0)
                    end
                end
                movedTotal = movedTotal + moved
            end
        end
        n = n + 1
        if n % 16 == 0 then
            sleep(0)
        end
    end

    return movedTotal
end

setmetatable(transfer, {
    __call = function(_, from, to, itemName, amount, opts)
        return transferItems(from, to, itemName, amount, opts)
    end,
})

--- opts.allowSpoiled: count rotten food too (greenhouse bus drain).
-- opts.stopAt: stop scanning once total reaches this (faster meat pulls).
function transfer.countItem(invName, itemQuery, opts)
    if not invName or not peripheral.isPresent(invName) then
        return 0
    end
    local inv = peripheral.wrap(invName)
    if not inv or not inv.list then
        return 0
    end
    local allowSpoiled = opts and opts.allowSpoiled == true
    local stopAt = opts and tonumber(opts.stopAt) or nil
    local total = 0
    local listed = inv.list()
    if not listed then
        return 0
    end
    local n = 0
    for rawSlot, item in pairs(listed) do
        local slot = slotNum(rawSlot)
        if item and item.name and slotUsable(inv, slot, item.name, itemQuery, allowSpoiled) then
            total = total + (item.count or 0)
            if stopAt and total >= stopAt then
                return total
            end
        end
        n = n + 1
        if n % 16 == 0 then
            sleep(0)
        end
    end
    return total
end

function transfer.countFromMany(sources, itemQuery, opts)
    local total = 0
    if not sources then
        return 0
    end
    local stopAt = opts and tonumber(opts.stopAt) or nil
    for i = 1, #sources do
        local left = stopAt and math.max(0, stopAt - total) or nil
        local subOpts = opts
        if left then
            subOpts = {}
            for k, v in pairs(opts) do
                subOpts[k] = v
            end
            subOpts.stopAt = left
        end
        total = total + transfer.countItem(sources[i], itemQuery, subOpts)
        if stopAt and total >= stopAt then
            return total
        end
    end
    return total
end

function transfer.fromMany(sources, to, itemQuery, amount, opts)
    if not sources or not to then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    for i = 1, #sources do
        local from = sources[i]
        if from and from ~= to and peripheral.isPresent(from) then
            if moveAll then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, -1, opts)
            elseif movedTotal < amount then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, amount - movedTotal, opts)
            end
            if not moveAll and movedTotal >= amount then
                break
            end
        end
    end
    return movedTotal
end

function transfer.toMany(from, destinations, itemQuery, amount, opts)
    if not from or not destinations then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    for i = 1, #destinations do
        local to = destinations[i]
        if to and to ~= from and peripheral.isPresent(to) then
            if moveAll then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, -1, opts)
            elseif movedTotal < amount then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, amount - movedTotal, opts)
            end
            if not moveAll and movedTotal >= amount then
                break
            end
        end
    end
    return movedTotal
end

function transfer.countFluid(tankName, fluidName)
    local tank = peripheral.wrap(tankName)
    if not tank or type(tank.tanks) ~= "function" then
        return 0
    end
    local total = 0
    for _, t in pairs(tank.tanks()) do
        if t and t.name == fluidName then
            total = total + (t.amount or 0)
        end
    end
    return total
end

function transfer.fluid(from, to, fluidName, amount)
    if not from or not to then
        return 0
    end
    local source = peripheral.wrap(from)
    if not source or type(source.pushFluid) ~= "function" then
        return 0
    end
    amount = tonumber(amount) or 0
    if amount <= 0 then
        return 0
    end
    local moved = source.pushFluid(to, amount, fluidName)
    return tonumber(moved) or 0
end

return transfer
