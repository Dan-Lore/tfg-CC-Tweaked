-- Adapter: gtceu large gas turbines (TurbineMachinePeripheral).

local common = require("machine_common")

local M = {}
M.kind = "turbine"
M.labelRu = "турбина"
M.defaultSubstr = "gas_large_turbine"

local MERGE = {
    "totalRunTime", "lastSpeed", "lastProduction", "lastDurability",
    "lastProgress", "enabledAt", "hasRotor",
}

local function newUnit(name, index, kind)
    return {
        name = name,
        index = index,
        kind = kind,
        totalRunTime = 0,
        lastSpeed = 0,
        lastProduction = 0,
        lastDurability = 100,
        lastProgress = 0,
        hasRotor = true,
        isActive = false,
        workingEnabled = false,
        enabledAt = nil,
        engineWait = false,
    }
end

function M.discover(substr)
    return common.discover(substr or M.defaultSubstr, M.kind, newUnit)
end

function M.apply(list, prev)
    return common.applyList(list, prev, MERGE)
end

local function rotorSpeedPct(unit)
    local current = common.safeCall(unit.name, "getRotorSpeed") or 0
    local max = common.safeCall(unit.name, "getMaxRotorHolderSpeed") or 1
    if max == 0 then
        max = 1
    end
    return (current / max) * 100
end

function M.updateStats(unit, measureInterval)
    unit.isActive = common.safeCall(unit.name, "isActive") == true
    unit.lastProduction = common.safeCall(unit.name, "getCurrentProduction") or 0
    common.isWorking(unit)

    local has = common.safeCall(unit.name, "hasRotor")
    unit.hasRotor = (has ~= false)
    unit.lastSpeed = rotorSpeedPct(unit)
    unit.lastDurability = common.safeCall(unit.name, "getRotorDurabilityPercent")
        or unit.lastDurability or 100
    unit.lastProgress = unit.lastSpeed
    unit.engineWait = false

    if unit.isActive then
        unit.totalRunTime = unit.totalRunTime + measureInterval
    end
end

function M.isRamping(unit, rampSpeedPct)
    return unit.workingEnabled and (unit.lastSpeed or 0) < rampSpeedPct
end

function M.canEnable(unit)
    return not common.isWorking(unit) and unit.hasRotor ~= false
end

function M.status(unit, rampSpeedPct, rotorWarnPct)
    if not unit.hasRotor then
        return "NOR", colors.red
    end
    if unit.workingEnabled and (unit.lastSpeed or 0) < rampSpeedPct then
        return "RMP", colors.yellow
    end
    if unit.workingEnabled then
        local color = colors.lime
        local dur = unit.lastDurability or 0
        if dur <= rotorWarnPct then
            color = colors.orange
        end
        return "ON ", color
    end
    return "OFF", colors.white
end

function M.title(wide)
    if wide then
        return "Турбины (скорость/EU/t/прочность/аптайм):"
    end
    return "Турбины (скр/EU/t/прч/раб):"
end

function M.formatLine(unit, status)
    return string.format(
        "%2d:[%s] %3.0f%% %5s %3.0f%% %dm",
        unit.slot or 0,
        status,
        unit.lastSpeed or 0,
        common.fmtNum(unit.lastProduction or 0),
        unit.lastDurability or 0,
        math.floor((unit.totalRunTime or 0) / 60)
    )
end

function M.label(unit)
    return M.labelRu .. " #" .. tostring(unit.slot)
end

M.isWorking = common.isWorking
M.setWorking = common.setWorking

return M
