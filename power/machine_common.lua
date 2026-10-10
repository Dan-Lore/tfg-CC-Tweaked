-- Shared CC peripheral helpers for power generators.

local M = {}

function M.safeCall(name, method, ...)
    local ok, a, b, c = pcall(peripheral.call, name, method, ...)
    if not ok then
        return nil
    end
    return a, b, c
end

function M.indexFromName(name)
    return tonumber(name:match("_(%d+)$"))
end

function M.discover(substr, kind, newUnit)
    local list = {}
    if not substr or substr == "" then
        return list
    end
    for _, name in ipairs(peripheral.getNames()) do
        if name:find(substr, 1, true) then
            local idx = M.indexFromName(name)
            if idx == nil then
                idx = #list
            end
            list[#list + 1] = newUnit(name, idx, kind)
        end
    end
    table.sort(list, function(a, b)
        if a.index == b.index then
            return a.name < b.name
        end
        return a.index < b.index
    end)
    return list
end

function M.isWorking(unit)
    local v = M.safeCall(unit.name, "isWorkingEnabled")
    if v == nil then
        return unit.workingEnabled
    end
    unit.workingEnabled = v and true or false
    return unit.workingEnabled
end

function M.setWorking(unit, state, graceful)
    if state then
        M.safeCall(unit.name, "setSuspendAfterFinish", false)
        M.safeCall(unit.name, "setWorkingEnabled", true)
        unit.workingEnabled = true
        unit.enabledAt = os.clock()
    else
        if graceful then
            M.safeCall(unit.name, "setSuspendAfterFinish", true)
            M.safeCall(unit.name, "setWorkingEnabled", false)
        else
            M.safeCall(unit.name, "setWorkingEnabled", false)
        end
        unit.workingEnabled = false
        unit.enabledAt = nil
    end
end

function M.syncWorkingFlags(list)
    for _, u in ipairs(list) do
        u.workingEnabled = M.safeCall(u.name, "isWorkingEnabled") == true
        if u.workingEnabled and not u.enabledAt then
            u.enabledAt = os.clock()
        elseif not u.workingEnabled then
            u.enabledAt = nil
        end
    end
end

--- Merge discovered list onto previous units (keep runtime stats).
function M.applyList(list, prevList, mergeFields)
    local prev = {}
    for _, u in ipairs(prevList) do
        prev[u.name] = u
    end
    for _, u in ipairs(list) do
        local old = prev[u.name]
        if old then
            for _, key in ipairs(mergeFields) do
                u[key] = old[key]
            end
        end
    end
    M.syncWorkingFlags(list)
    for i, u in ipairs(list) do
        u.slot = i
    end
    return list
end

function M.fmtNum(n)
    n = tonumber(n) or 0
    local sign = n < 0 and "-" or ""
    local a = math.abs(n)
    if a >= 1e9 then
        return sign .. string.format("%.2fG", a / 1e9)
    elseif a >= 1e6 then
        return sign .. string.format("%.2fM", a / 1e6)
    elseif a >= 1e4 then
        return sign .. string.format("%.1fk", a / 1e3)
    end
    return sign .. string.format("%.0f", a)
end

return M
