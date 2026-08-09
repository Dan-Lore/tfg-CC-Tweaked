-- Item and fluid transfers between peripherals.

local function transferItems(from, to, itemName, amount)
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

    for slot, item in pairs(source.list()) do
        local matches = itemName == nil or item.name == itemName
        if matches and (moveAll or movedTotal < amount) then
            local limit = moveAll and item.count or (amount - movedTotal)
            local moved = source.pushItems(to, slot, limit) or 0
            movedTotal = movedTotal + moved
        end
    end

    return movedTotal
end

-- Callable table: transfer(from, to, item, amount) + helpers
local transfer = setmetatable({}, {
    __call = function(_, from, to, itemName, amount)
        return transferItems(from, to, itemName, amount)
    end,
})

function transfer.countItem(invName, itemName)
    if not invName or not peripheral.isPresent(invName) then
        return 0
    end
    local inv = peripheral.wrap(invName)
    if not inv or not inv.list then
        return 0
    end
    local total = 0
    for _, item in pairs(inv.list()) do
        if item.name == itemName then
            total = total + item.count
        end
    end
    return total
end

--- Sum item counts across an ordered list of inventories.
function transfer.countFromMany(sources, itemName)
    local total = 0
    if not sources then
        return 0
    end
    for i = 1, #sources do
        total = total + transfer.countItem(sources[i], itemName)
    end
    return total
end

--- Pull `amount` of item from sources in order into `to`.
-- amount == -1 means move all matching from every source.
function transfer.fromMany(sources, to, itemName, amount)
    if not sources or not to then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    for i = 1, #sources do
        local from = sources[i]
        if from and from ~= to and peripheral.isPresent(from) then
            if moveAll then
                movedTotal = movedTotal + transferItems(from, to, itemName, -1)
            elseif movedTotal < amount then
                movedTotal = movedTotal + transferItems(from, to, itemName, amount - movedTotal)
            end
            if not moveAll and movedTotal >= amount then
                break
            end
        end
    end
    return movedTotal
end

--- Push `amount` of item from `from` into destinations in order (rollback helper).
function transfer.toMany(from, destinations, itemName, amount)
    if not from or not destinations then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    for i = 1, #destinations do
        local to = destinations[i]
        if to and to ~= from and peripheral.isPresent(to) then
            if moveAll then
                movedTotal = movedTotal + transferItems(from, to, itemName, -1)
            elseif movedTotal < amount then
                movedTotal = movedTotal + transferItems(from, to, itemName, amount - movedTotal)
            end
            if not moveAll and movedTotal >= amount then
                break
            end
        end
    end
    return movedTotal
end

--- Count millibuckets of a concrete fluid in a tank peripheral.
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

--- Push fluid from tank peripheral into target. Returns moved millibuckets.
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
