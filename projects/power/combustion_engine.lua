-- Adapter: gtceu extreme/large combustion engines.
--
-- CC has no getCurrentProduction for these (turbine-only peripheral).
-- Controller getOutputPerSec is often 0 because EU leaves via dynamo hatches.
-- So we infer RUN from Workable progress mid-cycle, and WAIT when stuck at
-- recipe end («Недостаточно вывода») with isActive and no measured output.

local common = require("machine_common")

local M = {}
M.kind = "engine"
M.labelRu = "двигатель"
M.defaultSubstr = "extreme_combustion_engine"
-- LuV extreme CE @ full parallels (override in power.cfg)
M.defaultRatedEuT = 32768

local MERGE = {
    "totalRunTime", "lastSpeed", "lastProduction", "lastDurability",
    "lastProgress", "enabledAt", "engineWait", "prevProgress",
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
        prevProgress = nil,
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

local function measuredEuT(unit)
    local outSec = common.safeCall(unit.name, "getOutputPerSec")
    if outSec ~= nil and outSec > 0 then
        return outSec / 20
    end
    local cur = common.safeCall(unit.name, "getCurrentProduction")
    if cur ~= nil and cur > 0 then
        return cur
    end
    return 0
end

--- @param ratedEuT number|nil assumed EU/t while cycling if hatch flow is invisible
function M.updateStats(unit, measureInterval, ratedEuT)
    ratedEuT = tonumber(ratedEuT) or M.defaultRatedEuT

    unit.isActive = common.safeCall(unit.name, "isActive") == true
    common.isWorking(unit)
    unit.hasRotor = true
    unit.lastDurability = 100

    local prog = common.safeCall(unit.name, "getProgress") or 0
    local maxProg = common.safeCall(unit.name, "getMaxProgress") or 0
    local pct = 0
    if maxProg > 0 then
        pct = (prog / maxProg) * 100
    end
    unit.lastProgress = pct

    local measured = measuredEuT(unit)
    -- Mid-cycle = actually burning fuel / generating (smoke, GT "Производит …")
    local cycling = unit.isActive and maxProg > 0 and prog > 0 and prog < maxProg
    -- Stuck at end of recipe waiting to push EU (GT "Недостаточно вывода")
    local stuckOut = unit.isActive and maxProg > 0 and prog >= maxProg

    if measured > 0 then
        unit.lastProduction = measured
        unit.engineWait = false
    elseif cycling then
        unit.lastProduction = ratedEuT
        unit.engineWait = false
    elseif stuckOut then
        unit.lastProduction = 0
        unit.engineWait = true
    elseif unit.isActive then
        -- Active but progress 0: start of tick or odd wait
        unit.lastProduction = 0
        unit.engineWait = true
    else
        unit.lastProduction = 0
        unit.engineWait = false
    end

    if (unit.lastProduction or 0) > 0 then
        unit.lastSpeed = 100
        unit.totalRunTime = unit.totalRunTime + measureInterval
    else
        unit.lastSpeed = 0
    end

    unit.prevProgress = pct
end

function M.isRamping(_unit, _rampSpeedPct)
    return false
end

function M.canEnable(unit)
    return not common.isWorking(unit)
end

function M.status(unit, _rampSpeedPct, _rotorWarnPct)
    if not unit.workingEnabled then
        return "OFF", colors.white
    end
    if (unit.lastProduction or 0) > 0 then
        return "ON ", colors.lime
    end
    if unit.engineWait then
        return "WAIT", colors.orange
    end
    if unit.isActive then
        return "WAIT", colors.orange
    end
    return "IDLE", colors.yellow
end

function M.title(wide)
    if wide then
        return "Двигатели (EU/t/прогресс/аптайм):"
    end
    return "Двигатели (EU/t/прог/раб):"
end

function M.formatLine(unit, status)
    return string.format(
        "%2d:[%s] %5s %3.0f%% %dm",
        unit.slot or 0,
        status,
        common.fmtNum(unit.lastProduction or 0),
        unit.lastProgress or 0,
        math.floor((unit.totalRunTime or 0) / 60)
    )
end

function M.label(unit)
    return M.labelRu .. " #" .. tostring(unit.slot)
end

M.isWorking = common.isWorking
M.setWorking = common.setWorking

return M
