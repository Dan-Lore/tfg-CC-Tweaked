-- Exclusive peripheral locks shared across craft / miller on the same computer.

local machine_lock = {}

local locks = {} -- name -> { key = recipeKey }

function machine_lock.isBusy(machine)
    return machine ~= nil and locks[machine] ~= nil
end

function machine_lock.busyAny()
    for _ in pairs(locks) do
        return true
    end
    return false
end

--- Wait until free, then run fn under lock.
function machine_lock.withLock(machine, recipeKey, fn)
    recipeKey = recipeKey or "unknown"
    while true do
        if not locks[machine] then
            locks[machine] = { key = recipeKey }
            break
        end
        sleep(0.25)
    end

    local ok, a, b = pcall(fn)
    locks[machine] = nil
    if not ok then
        return false, {
            error = "exception",
            missing = { name = tostring(a), count = 1 },
        }
    end
    return a, b
end

--- Non-blocking: fail with error=busy if already held.
function machine_lock.tryLock(machine, recipeKey, fn)
    if not machine then
        return false, { error = "no_machine" }
    end
    if locks[machine] then
        return false, { error = "busy" }
    end
    locks[machine] = { key = recipeKey or "unknown" }
    local ok, a, b = pcall(fn)
    locks[machine] = nil
    if not ok then
        return false, {
            error = "exception",
            missing = { name = tostring(a), count = 1 },
        }
    end
    return a, b
end

return machine_lock
