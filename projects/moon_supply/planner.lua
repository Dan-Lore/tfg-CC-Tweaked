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
-- skip[name]=true → ignore (e.g. «Нет в AE» / not craftable) so a partial package can fire.
function planner.packageDone(wants, have, skip)
    have = have or {}
    skip = skip or {}
    local any = false
    for name, want in pairs(wants) do
        if not skip[name] then
            any = true
            if (tonumber(have[name]) or 0) < (tonumber(want) or 0) then
                return false
            end
        end
    end
    return any
end

--- First obtainable package item still short in the loaders. Never returns skipped («Нет в AE»).
function planner.waitItem(wants, order, have, skip)
    have = have or {}
    skip = skip or {}
    order = order or {}
    for i = 1, #order do
        local name = order[i]
        local want = tonumber(wants and wants[name]) or 0
        if want > 0 and not skip[name] then
            if (tonumber(have[name]) or 0) < want then
                return name
            end
        end
    end
    return nil
end

--- Drop unobtainable ids from the shot package.
function planner.filterObtainable(wants, order, skip)
    wants = wants or {}
    order = order or {}
    skip = skip or {}
    local w2, o2 = {}, {}
    for i = 1, #order do
        local name = order[i]
        local want = tonumber(wants[name]) or 0
        if want > 0 and not skip[name] then
            w2[name] = want
            o2[#o2 + 1] = name
        end
    end
    return w2, o2
end

--- Human list of skipped package names (for status lines).
function planner.skippedNames(order, skip)
    order = order or {}
    skip = skip or {}
    local out = {}
    for i = 1, #order do
        local name = order[i]
        if skip[name] then
            out[#out + 1] = name
        end
    end
    return out
end

--- Fire when the package is in the loaders, or every loader is slot-full.
-- moreToLoad: obtainable shortfall still on Earth/buffer/craft — do not fire a WARN
-- package early while gold (etc.) can still be pushed in. Loaders-full always fires
-- (no free slots left); WARN zone rules themselves are unchanged.
function planner.shouldFire(packageDone, loadersFull, moreToLoad)
    if loadersFull == true then
        return true
    end
    if moreToLoad == true then
        return false
    end
    return packageDone == true
end

--- Leave cargo in the loaders and poll again when the package cannot be finished.
-- Craft-wait, keepCrafting (still short + can order AE), and a ready gun stay in the shot loop.
-- keepCrafting prevents the expensive full Moon poll while we should keep scheduling AE jobs.
function planner.shouldYield(inCraftWait, canLoadMore, packageDone, loadersFull, keepCrafting)
    if packageDone or loadersFull then
        return false
    end
    if inCraftWait or keepCrafting then
        return false
    end
    return not canLoadMore
end

--- Expand an in-flight shot with fresh Moon deficits (never shrink mid-shot).
-- New WARN/ALARM ids append in cfg/zone order; existing wants take max(old, new deficit).
function planner.mergePackage(wants, order, rows, mode)
    wants = wants or {}
    order = order or {}
    local addW, addO = planner.packageWants(rows, mode)
    local w2, o2, seen = {}, {}, {}
    for i = 1, #order do
        local name = order[i]
        local prev = tonumber(wants[name]) or 0
        if prev > 0 then
            w2[name] = prev
            o2[#o2 + 1] = name
            seen[name] = true
        end
    end
    for i = 1, #addO do
        local name = addO[i]
        local d = tonumber(addW[name]) or 0
        if d > 0 then
            local prev = tonumber(w2[name]) or 0
            if d > prev then
                w2[name] = d
            elseif prev < 1 then
                w2[name] = d
            end
            if not seen[name] then
                seen[name] = true
                o2[#o2 + 1] = name
            end
        end
    end
    return w2, o2
end

--- Clamp AE craft count so finished output already in earth/staged is not double-counted.
-- want<=0 → return crafting unchanged (no package target to clamp against).
function planner.effectiveCraft(crafting, want, staged, earth)
    crafting = math.max(0, math.floor(tonumber(crafting) or 0))
    want = math.max(0, math.floor(tonumber(want) or 0))
    if want < 1 then
        return crafting
    end
    local covered = math.max(0, math.floor(tonumber(staged) or 0))
        + math.max(0, math.floor(tonumber(earth) or 0))
    return math.min(crafting, math.max(0, want - covered))
end

return planner
