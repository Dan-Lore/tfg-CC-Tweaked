-- Inventory helpers for provider↔machine moves (wraps root transfer.lua).

local transfer = require("transfer")

local move = {}

--- First item name found across providers, or nil if all empty.
function move.firstProviderItem(providers)
    if not providers then
        return nil
    end
    for i = 1, #providers do
        local name = providers[i]
        if peripheral.isPresent(name) then
            local inv = peripheral.wrap(name)
            if inv and inv.list then
                for _, item in pairs(inv.list()) do
                    if item and item.name then
                        return item.name
                    end
                end
            end
        end
    end
    return nil
end

function move.countProviders(providers, itemName)
    return transfer.countFromMany(providers, itemName)
end

function move.countIn(invName, itemName)
    return transfer.countItem(invName, itemName)
end

--- Machines with zero of inputItem (ready for a fresh N-set).
function move.freeMachines(machines, inputItem)
    local free = {}
    if not machines or not inputItem then
        return free
    end
    for i = 1, #machines do
        local m = machines[i]
        if peripheral.isPresent(m) and transfer.countItem(m, inputItem) == 0 then
            free[#free + 1] = m
        end
    end
    return free
end

--- Push exactly `amount` of item from providers into one machine.
function move.feedMachine(providers, machine, itemName, amount)
    return transfer.fromMany(providers, machine, itemName, amount)
end

--- Drain items that are not inputItem from machine into any provider.
-- If inputItem is nil, drain everything (idle return of products).
function move.drainMachine(machine, providers, inputItem)
    if not machine or not providers or #providers == 0 then
        return 0
    end
    if not peripheral.isPresent(machine) then
        return 0
    end
    local inv = peripheral.wrap(machine)
    if not inv or not inv.list then
        return 0
    end

    local movedTotal = 0
    local seen = {}
    for _, item in pairs(inv.list()) do
        local name = item and item.name
        if name and not seen[name] then
            seen[name] = true
            if inputItem == nil or name ~= inputItem then
                movedTotal = movedTotal + transfer.toMany(machine, providers, name, -1)
            end
        end
    end
    return movedTotal
end

--- Parallel drain all machines → providers.
function move.drainAll(machines, providers, inputItem)
    if not machines or #machines == 0 or not providers or #providers == 0 then
        return 0
    end
    local results = {}
    local tasks = {}
    for i = 1, #machines do
        local machine = machines[i]
        local idx = i
        tasks[i] = function()
            results[idx] = move.drainMachine(machine, providers, inputItem)
        end
    end
    parallel.waitForAll(table.unpack(tasks))
    local total = 0
    for i = 1, #results do
        total = total + (results[i] or 0)
    end
    return total
end

--- Parallel feed: push exactly N of item into each of the given machines from providers.
-- Returns how many machines received a full N.
function move.distribute(providers, machines, itemName, n)
    n = tonumber(n) or 0
    if n <= 0 or not providers or not machines or not itemName or #machines == 0 then
        return 0
    end

    local results = {}
    local tasks = {}
    for i = 1, #machines do
        local machine = machines[i]
        local idx = i
        tasks[i] = function()
            results[idx] = move.feedMachine(providers, machine, itemName, n)
        end
    end
    parallel.waitForAll(table.unpack(tasks))

    local okCount = 0
    for i = 1, #results do
        if (results[i] or 0) >= n then
            okCount = okCount + 1
        end
    end
    return okCount
end

return move
