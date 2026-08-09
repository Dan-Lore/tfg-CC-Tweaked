local function transfer(from, to, itemName, amount)
    local source = assert(peripheral.wrap(from), "Source not found: " .. from)
    local movedTotal = 0
    local moveAll = amount == -1

    for slot, item in pairs(source.list()) do
        local matches = itemName == nil or item.name == itemName

        if matches and (moveAll or movedTotal < amount) then
            local limit = moveAll and item.count or amount - movedTotal
            local moved = source.pushItems(to, slot, limit)
            movedTotal = movedTotal + moved
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

--- Push fluid from tank peripheral into target (machine hatch etc.).
-- Returns moved millibuckets.
function transfer.fluid(from, to, fluidName, amount)
    local source = peripheral.wrap(from)
    if not source then
        error("Fluid source not found: " .. tostring(from), 2)
    end
    if type(source.pushFluid) ~= "function" then
        error("No pushFluid on " .. tostring(from), 2)
    end
    amount = tonumber(amount) or 0
    if amount <= 0 then
        return 0
    end
    local moved = source.pushFluid(to, amount, fluidName)
    return tonumber(moved) or 0
end

return transfer
