-- Electric greenhouse control for grow recipes.

local Greenhouse = {}

--- Enable a greenhouse for `duration` seconds, then disable it.
function Greenhouse.runFor(machineName, duration)
    local machine = peripheral.wrap(machineName)

    if not machine then
        print("Ошибка: Теплица '" .. tostring(machineName) .. "' не найдена")
        return false
    end

    duration = duration or 10

    machine.setWorkingEnabled(true)
    sleep(duration)
    machine.setWorkingEnabled(false)

    return true
end

return Greenhouse
