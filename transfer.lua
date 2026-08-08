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

return transfer
