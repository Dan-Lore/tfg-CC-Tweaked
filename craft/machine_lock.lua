-- Exclusive peripheral locks shared across craft / miller on the same computer.
-- Same recipeKey can queue (stack); different crafts wait for the machine to free.

local machine_lock = {}

local locks = {} -- name -> { key = recipeKey }
local LOCK_POLL = 0.05

function machine_lock.isBusy(machine)
    return machine ~= nil and locks[machine] ~= nil
end

function machine_lock.keyOf(machine)
    local lock = machine and locks[machine]
    return lock and lock.key or nil
end

function machine_lock.busyAny()
    for _ in pairs(locks) do
        return true
    end
    return false
end

--- True if free, or held by the same recipe (caller may queue/stack).
function machine_lock.canStack(machine, recipeKey)
    if not machine then
        return false
    end
    local lock = locks[machine]
    if not lock then
        return true
    end
    return lock.key == (recipeKey or "unknown")
end

--- Wait until free, then run fn under lock.
function machine_lock.withLock(machine, recipeKey, fn)
    recipeKey = recipeKey or "unknown"
    while true do
        if not locks[machine] then
            locks[machine] = { key = recipeKey }
            break
        end
        sleep(LOCK_POLL)
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

--- If free → tryLock; if same recipe already running → withLock (stack/queue).
-- Different recipe holding the machine → busy (do not steal).
function machine_lock.runOrStack(machine, recipeKey, fn)
    recipeKey = recipeKey or "unknown"
    if not machine then
        return false, { error = "no_machine" }
    end
    local lock = locks[machine]
    if not lock then
        return machine_lock.tryLock(machine, recipeKey, fn)
    end
    if lock.key == recipeKey then
        return machine_lock.withLock(machine, recipeKey, fn)
    end
    return false, { error = "busy" }
end

return machine_lock
