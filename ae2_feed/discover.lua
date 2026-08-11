-- Classify wired-network inventories into storages vs machines.

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

local LOCAL_SIDES = {
    left = true,
    right = true,
    top = true,
    bottom = true,
    front = true,
    back = true,
}

local DEFAULT_STORAGE_NEEDLES = {
    "crate",
    "barrel",
    "chest",
    "drawer",
    "shulker",
    "drum",
    "toolbox",
    "locker",
    "cabinet",
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
    if LOCAL_SIDES[lowerName] then
        return true
    end
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

local function matchesNeedle(name, types, needle)
    if not needle or needle == "" then
        return false
    end
    local n = tostring(needle):lower()
    if tostring(name):lower():find(n, 1, true) then
        return true
    end
    for i = 1, #types do
        if tostring(types[i]):lower():find(n, 1, true) then
            return true
        end
    end
    return false
end

local function matchesAny(name, types, needles)
    if not needles then
        return false
    end
    if type(needles) == "string" then
        return matchesNeedle(name, types, needles)
    end
    for i = 1, #needles do
        if matchesNeedle(name, types, needles[i]) then
            return true
        end
    end
    return false
end

local function sortNames(list)
    table.sort(list)
    return list
end

local function explicitList(cfgValue)
    if type(cfgValue) ~= "table" or #cfgValue == 0 then
        return nil
    end
    return cfgValue
end

local function resolveExplicit(names, label)
    local out = {}
    for i = 1, #names do
        local name = names[i]
        if peripheral.isPresent(name) and isInventory(name) then
            out[#out + 1] = name
        else
            print(("ae2_feed: missing %s %s"):format(label, tostring(name)))
        end
    end
    return sortNames(out)
end

local function nameSet(list)
    local set = {}
    for i = 1, #list do
        set[list[i]] = true
    end
    return set
end

--- Returns { machines = {...}, storages = {...} }.
function discover.scan(cfg)
    cfg = cfg or {}

    local explicitStorages = explicitList(cfg.STORAGES)
    local explicitMachines = explicitList(cfg.MACHINES)

    local storageNeedles = cfg.STORAGE_SUBSTR
    if storageNeedles == nil then
        storageNeedles = DEFAULT_STORAGE_NEEDLES
    end
    local machineNeedles = cfg.MACHINE_SUBSTR

    local storages = explicitStorages and resolveExplicit(explicitStorages, "storage") or {}
    local machines = explicitMachines and resolveExplicit(explicitMachines, "machine") or {}

    local taken = nameSet(storages)
    for i = 1, #machines do
        taken[machines[i]] = true
    end

    local names = peripheral.getNames()
    for i = 1, #names do
        local name = names[i]
        if not taken[name] then
            local types = peripheralTypes(name)
            if not shouldSkip(name, types) and isInventory(name) then
                if not explicitStorages and matchesAny(name, types, storageNeedles) then
                    storages[#storages + 1] = name
                    taken[name] = true
                elseif not explicitMachines then
                    if machineNeedles == nil or machineNeedles == "" or matchesAny(name, types, machineNeedles) then
                        machines[#machines + 1] = name
                        taken[name] = true
                    end
                end
            end
        end
        if i % 8 == 0 then
            sleep(0)
        end
    end

    return {
        machines = sortNames(machines),
        storages = sortNames(storages),
    }
end

function discover.printSummary(net)
    local m = net and net.machines or {}
    local s = net and net.storages or {}
    print(("ae2_feed: %d machine(s), %d storage(s)"):format(#m, #s))
    for i = 1, #s do
        print("  storage: " .. s[i])
    end
    for i = 1, #m do
        print("  machine: " .. m[i])
    end
end

return discover
