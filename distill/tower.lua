-- Distillation tower discovery + enable/disable (CC: Tweaked / TFG).

local net_watch = require("net_watch")

local M = {}

local function safeCall(name, method, ...)
    return net_watch.safeCall(name, method, ...)
end

--- Find tower by pinned name or substr. Returns wrap, name.
function M.discover(cfg)
    local pinned = cfg.tower
    if pinned and peripheral.isPresent(pinned) then
        return peripheral.wrap(pinned), pinned
    end
    local substr = cfg.tower_substr or "distillation_tower"
    for _, name in ipairs(peripheral.getNames()) do
        if name:find(substr, 1, true) then
            return peripheral.wrap(name), name
        end
    end
    return nil, nil
end

--- state: { enabled, enabledAt, offAt, cooldownLeft }
function M.isWorking(towerName, state)
    local v = safeCall(towerName, "isWorkingEnabled")
    if v == nil then
        return state.enabled
    end
    state.enabled = v and true or false
    return state.enabled
end

function M.setWorking(towerName, state, on, cooldownSec)
    safeCall(towerName, "setWorkingEnabled", on and true or false)
    local was = state.enabled
    state.enabled = on and true or false
    if state.enabled and not was then
        state.enabledAt = os.clock()
        state.offAt = nil
    elseif not state.enabled and was then
        state.enabledAt = nil
        state.offAt = os.clock()
        state.cooldownLeft = cooldownSec or 0
    end
end

function M.runAge(state)
    if not state.enabledAt then
        return 0
    end
    return os.clock() - state.enabledAt
end

function M.newState()
    return {
        enabled = false,
        enabledAt = nil,
        offAt = nil,
        cooldownLeft = 0,
    }
end

return M
