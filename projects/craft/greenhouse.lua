-- Electric greenhouse control.
-- Greenhouses stay disabled by default. A short enable pulse is enough for
-- GregTech to finish one grow recipe after the machine is turned off again.

local Greenhouse = {}

local DEFAULT_PULSE = 3 -- seconds; enough to latch one grow cycle

local function wrapMachine(machineName)
    local machine = peripheral.wrap(machineName)
    if not machine then
        return nil, "greenhouse not found: " .. tostring(machineName)
    end
    if type(machine.setWorkingEnabled) ~= "function" then
        return nil, "no setWorkingEnabled: " .. tostring(machineName)
    end
    return machine
end

function Greenhouse.setEnabled(machineName, enabled)
    local machine, err = wrapMachine(machineName)
    if not machine then
        return false, err
    end
    machine.setWorkingEnabled(enabled and true or false)
    return true
end

--- Keep greenhouse off (default state).
function Greenhouse.disable(machineName)
    return Greenhouse.setEnabled(machineName, false)
end

function Greenhouse.enable(machineName)
    return Greenhouse.setEnabled(machineName, true)
end

--- Brief on-pulse, then force off. Recipe continues to completion on its own.
-- @return ok, err
function Greenhouse.pulse(machineName, pulseSeconds)
    local machine, err = wrapMachine(machineName)
    if not machine then
        return false, err
    end

    pulseSeconds = tonumber(pulseSeconds) or DEFAULT_PULSE
    if pulseSeconds < 1 then
        pulseSeconds = DEFAULT_PULSE
    end

    machine.setWorkingEnabled(true)
    sleep(pulseSeconds)
    machine.setWorkingEnabled(false)
    return true
end

--- Disable every resolved grow machine (call on cleaner/craft startup).
-- @param resolveFn function(recipe) -> peripheral name | nil
-- @param growRecipes list of grow recipes
function Greenhouse.disableAll(resolveFn, growRecipes)
    if type(resolveFn) ~= "function" or type(growRecipes) ~= "table" then
        return
    end
    local seen = {}
    for i = 1, #growRecipes do
        local name = resolveFn(growRecipes[i])
        if name and not seen[name] then
            seen[name] = true
            Greenhouse.disable(name)
        end
    end
end

-- Back-compat alias used by older callers
Greenhouse.runFor = Greenhouse.pulse

return Greenhouse
