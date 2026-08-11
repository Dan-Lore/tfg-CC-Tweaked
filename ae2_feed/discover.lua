-- Classify wired-network inventories into pattern providers vs machines.

local discover = {}

local SKIP_TYPES = {
    modem = true,
    wired_modem = true,
    wireless_modem = true,
    monitor = true,
    computer = true,
    turtle = true,
    speaker = true,
    drive = true,
    printer = true,
    command = true,
    redstone = true,
}

local function peripheralTypes(name)
    local ok, ptype = pcall(peripheral.getType, name)
    if not ok or not ptype then
        return {}
    end
    if type(ptype) == "table" then
        return ptype
    end
    return { ptype }
end

local function shouldSkip(name, types)
    local lowerName = tostring(name):lower()
    for i = 1, #types do
        local t = tostring(types[i]):lower()
        if SKIP_TYPES[t] then
            return true
        end
    end
    if lowerName:find("modem", 1, true) or lowerName:find("monitor", 1, true) then
        return true
    end
    return false
end

local function isInventory(name)
    if not peripheral.isPresent(name) then
        return false
    end
    local inv = peripheral.wrap(name)
    return inv and type(inv.list) == "function" and type(inv.pushItems) == "function"
end

local function matchesSubstr(name, types, substr)
    if not substr or substr == "" then
        return false
    end
    local needle = tostring(substr):lower()
    if tostring(name):lower():find(needle, 1, true) then
        return true
    end
    for i = 1, #types do
        if tostring(types[i]):lower():find(needle, 1, true) then
            return true
        end
    end
    return false
end

local function sortNames(list)
    table.sort(list)
    return list
end

--- Scan the network. Returns { machines = {...}, providers = {...} }.
-- cfg.PROVIDER_SUBSTR — required match for providers (default pattern_provider).
-- cfg.MACHINE_SUBSTR — optional filter for machines; nil = all non-provider inventories.
function discover.scan(cfg)
    cfg = cfg or {}
    local providerSub = cfg.PROVIDER_SUBSTR or "pattern_provider"
    local machineSub = cfg.MACHINE_SUBSTR

    local names = peripheral.getNames()
    local machines = {}
    local providers = {}

    for i = 1, #names do
        local name = names[i]
        local types = peripheralTypes(name)
        if not shouldSkip(name, types) and isInventory(name) then
            if matchesSubstr(name, types, providerSub) then
                providers[#providers + 1] = name
            elseif machineSub == nil or machineSub == "" or matchesSubstr(name, types, machineSub) then
                machines[#machines + 1] = name
            end
        end
        if i % 8 == 0 then
            sleep(0)
        end
    end

    return {
        machines = sortNames(machines),
        providers = sortNames(providers),
    }
end

function discover.printSummary(net)
    local m = net and net.machines or {}
    local p = net and net.providers or {}
    print(("ae2_feed: %d machine(s), %d provider(s)"):format(#m, #p))
    for i = 1, #p do
        print("  provider: " .. p[i])
    end
    for i = 1, #m do
        print("  machine:  " .. m[i])
    end
end

return discover
