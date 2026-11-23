-- ALARM/WARN assessment, deficit package, craft-wait policy.

local planner = {}

planner.ZONE_OK = "OK"
planner.ZONE_WARN = "WARN"
planner.ZONE_ALARM = "ALARM"

function planner.redLine(target, redFrac)
    target = tonumber(target) or 0
    redFrac = tonumber(redFrac) or 0.25
    return math.floor(target * redFrac)
end

--- Annotate watchlist with moon amounts and per-item zone.
-- returns rows, globalMode ("OK"|"WARN"|"ALARM")
function planner.assess(items, moonStocks, redFrac)
    moonStocks = moonStocks or {}
    local rows = {}
    local anyAlarm = false
    local anyWarn = false
    for i = 1, #items do
        local it = items[i]
        local moon = tonumber(moonStocks[it.name]) or 0
        local target = tonumber(it.target) or 0
        local red = planner.redLine(target, redFrac)
        local deficit = math.max(0, target - moon)
        local zone = planner.ZONE_OK
        if moon < red then
            zone = planner.ZONE_ALARM
            anyAlarm = true
        elseif moon < target then
            zone = planner.ZONE_WARN
            anyWarn = true
        end
        rows[i] = {
            name = it.name,
            target = target,
            moon = moon,
            red_line = red,
            deficit = deficit,
            zone = zone,
        }
    end
    local mode = planner.ZONE_OK
    if anyAlarm then
        mode = planner.ZONE_ALARM
    elseif anyWarn then
        mode = planner.ZONE_WARN
    end
    return rows, mode
end

function planner.craftWaitSeconds(cfg, mode)
    if mode == planner.ZONE_ALARM then
        return tonumber(cfg.craft_wait_red) or 60
    end
    if mode == planner.ZONE_WARN then
        return tonumber(cfg.craft_wait_green) or 120
    end
    return 0
end

--- Build want map for this shot: item name -> amount to send.
-- ALARM: alarm deficits first (row order), then warn deficits into the same shot.
-- WARN: warn deficits only, row order.
function planner.packageWants(rows, mode)
    local wants = {}
    local alarms = {}
    local warns = {}
    local alarmMode = mode == planner.ZONE_ALARM
    local warnMode = mode == planner.ZONE_WARN
    for i = 1, #rows do
        local r = rows[i]
        local deficit = tonumber(r.deficit) or 0
        if deficit > 0 then
            if alarmMode and r.zone == planner.ZONE_ALARM then
                wants[r.name] = deficit
                alarms[#alarms + 1] = r.name
            elseif (alarmMode or warnMode) and r.zone == planner.ZONE_WARN then
                wants[r.name] = deficit
                warns[#warns + 1] = r.name
            end
        end
    end
    local order = {}
    for i = 1, #alarms do
        order[#order + 1] = alarms[i]
    end
    for i = 1, #warns do
        order[#order + 1] = warns[i]
    end
    return wants, order
end

--- have: name -> count already in the loaders.
function planner.packageDone(wants, have)
    have = have or {}
    for name, want in pairs(wants) do
        if (tonumber(have[name]) or 0) < (tonumber(want) or 0) then
            return false
        end
    end
    return true
end

--- Fire when the package is in the loaders, or every loader is slot-full.
function planner.shouldFire(packageDone, loadersFull)
    return packageDone == true or loadersFull == true
end

--- Leave cargo in the loaders and poll again when the package cannot be finished.
-- Craft-wait and a ready gun stay in the shot loop.
function planner.shouldYield(inCraftWait, canLoadMore, packageDone, loadersFull)
    if packageDone or loadersFull then
        return false
    end
    if inCraftWait then
        return false
    end
    return not canLoadMore
end

return planner
