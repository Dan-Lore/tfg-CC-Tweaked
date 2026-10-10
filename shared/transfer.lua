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

--- Detail for #tags (match + spoil). Exact ids stay fast (list only) until food spoil path enabled.
local function slotDetail(inv, slot, itemQuery, _itemName)
    if not transfer.isTag(itemQuery) or not inv.getItemDetail then
        return nil
    end
    local ok, detail = pcall(inv.getItemDetail, slot)
    if ok then
        return detail
    end
    return nil
end

local function slotUsable(itemName, detail, itemQuery)
    if transfer.isSpoiled(detail) then
        return false
    end
    return transfer.matches(itemName, itemTagsFromDetail(detail), itemQuery)
end

local function transferItems(from, to, itemQuery, amount)
    if not from or not to or from == to then
        return 0
    end
    if not peripheral.isPresent(from) or not peripheral.isPresent(to) then
        return 0
    end
    local source = peripheral.wrap(from)
    if not source or not source.list or not source.pushItems then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    amount = tonumber(amount) or 0
    if not moveAll and amount <= 0 then
        return 0
    end

    local listed = source.list()
    if not listed then
        return 0
    end

    local n = 0
    for slot, item in pairs(listed) do
        if moveAll or movedTotal < amount then
            local detail = slotDetail(source, slot, itemQuery, item.name)
            if slotUsable(item.name, detail, itemQuery) then
                local limit = moveAll and item.count or (amount - movedTotal)
                local moved = source.pushItems(to, slot, limit) or 0
                movedTotal = movedTotal + moved
            end
        end
        n = n + 1
        if n % 8 == 0 then
            sleep(0)
        end
    end

    return movedTotal
end

setmetatable(transfer, {
    __call = function(_, from, to, itemName, amount)
        return transferItems(from, to, itemName, amount)
    end,
})

function transfer.countItem(invName, itemQuery)
    if not invName or not peripheral.isPresent(invName) then
        return 0
    end
    local inv = peripheral.wrap(invName)
    if not inv or not inv.list then
        return 0
    end
    local total = 0
    local listed = inv.list()
    if not listed then
        return 0
    end
    local n = 0
    for slot, item in pairs(listed) do
        local detail = slotDetail(inv, slot, itemQuery, item.name)
        if slotUsable(item.name, detail, itemQuery) then
            total = total + (item.count or 0)
        end
        n = n + 1
        if n % 8 == 0 then
            sleep(0)
        end
    end
    return total
end

function transfer.countFromMany(sources, itemQuery)
    local total = 0
    if not sources then
        return 0
    end
    for i = 1, #sources do
        total = total + transfer.countItem(sources[i], itemQuery)
    end
    return total
end

function transfer.fromMany(sources, to, itemQuery, amount)
    if not sources or not to then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    for i = 1, #sources do
        local from = sources[i]
        if from and from ~= to and peripheral.isPresent(from) then
            if moveAll then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, -1)
            elseif movedTotal < amount then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, amount - movedTotal)
            end
            if not moveAll and movedTotal >= amount then
                break
            end
        end
    end
    return movedTotal
end

function transfer.toMany(from, destinations, itemQuery, amount)
    if not from or not destinations then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    for i = 1, #destinations do
        local to = destinations[i]
        if to and to ~= from and peripheral.isPresent(to) then
            if moveAll then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, -1)
            elseif movedTotal < amount then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, amount - movedTotal)
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
