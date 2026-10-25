-- Storage → machine feed helpers (wraps shared transfer.lua).

local transfer = require("transfer")

local move = {}

function move.firstItem(invNames)
    if not invNames then
        return nil
    end
    for i = 1, #invNames do
        local name = invNames[i]
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

function move.countInMany(invNames, itemName)
    return transfer.countFromMany(invNames, itemName)
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

--- Push exactly N of item into each machine from storages (sequential, no stock races).
-- Returns how many machines received a full N.
function move.distribute(storages, machines, itemName, n)
    n = tonumber(n) or 0
    if n <= 0 or not storages or not machines or not itemName or #machines == 0 then
        return 0
    end

    local okCount = 0
    for i = 1, #machines do
        local moved = transfer.fromMany(storages, machines[i], itemName, n)
        if moved >= n then
            okCount = okCount + 1
        end
        sleep(0)
    end
    return okCount
end

return move
