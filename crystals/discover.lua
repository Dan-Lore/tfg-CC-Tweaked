-- Discover buffer chest, laser engravers, and monitor.

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

local function indexFromName(name)
    return tonumber(tostring(name):match("_(%d+)$"))
end

local function sortMachines(list)
    table.sort(list, function(a, b)
        local ia, ib = indexFromName(a), indexFromName(b)
        if ia and ib and ia ~= ib then
            return ia < ib
        end
        if ia and not ib then
            return true
        end
        if ib and not ia then
            return false
        end
        return a < b
    end)
    return list
end

local function resolveName(preferred, label)
    if preferred and peripheral.isPresent(preferred) then
        return preferred
    end
    if preferred then
        print(("crystals: missing %s %s"):format(label, tostring(preferred)))
    end
    return nil
end

--- Find monitor: preferred side/name, else first monitor peripheral.
function discover.monitor(preferred)
    local name = resolveName(preferred, "monitor")
    if name then
        local m = peripheral.wrap(name)
        if m and m.clear then
            return m, name
        end
    end
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "monitor" then
            local m = peripheral.wrap(n)
            if m and m.clear then
                return m, n
            end
        end
    end
    return nil, nil
end

--- Buffer inventory: preferred side/name, else first non-machine inventory on sides.
function discover.buffer(preferred, machineSet)
    machineSet = machineSet or {}
    local name = resolveName(preferred, "buffer")
    if name and isInventory(name) and not machineSet[name] then
        return name
    end
    -- Prefer local sides (top/chest attached to computer).
    for _, side in ipairs({ "top", "bottom", "front", "back", "left", "right" }) do
        if isInventory(side) and not machineSet[side] then
            return side
        end
    end
    return nil
end

function discover.machines(cfg)
    cfg = cfg or {}
    local list = {}
    local taken = {}

    if type(cfg.MACHINES) == "table" and #cfg.MACHINES > 0 then
        for i = 1, #cfg.MACHINES do
            local name = cfg.MACHINES[i]
            if peripheral.isPresent(name) and isInventory(name) then
                list[#list + 1] = name
                taken[name] = true
            else
                print("crystals: missing machine " .. tostring(name))
            end
        end
        return sortMachines(list), taken
    end

    local needles = cfg.MACHINE_SUBSTR or "laser_engraver"
    local names = peripheral.getNames()
    for i = 1, #names do
        local name = names[i]
        local types = peripheralTypes(name)
        if not shouldSkip(name, types) and isInventory(name) and matchesAny(name, types, needles) then
            list[#list + 1] = name
            taken[name] = true
        end
        if i % 8 == 0 then
            sleep(0)
        end
    end
    return sortMachines(list), taken
end

function discover.scan(cfg)
    local machines, machineSet = discover.machines(cfg)
    local buffer = discover.buffer(cfg.BUFFER, machineSet)
    local monitor, monitorName = discover.monitor(cfg.MONITOR)
    return {
        machines = machines,
        buffer = buffer,
        monitor = monitor,
        monitorName = monitorName,
    }
end

function discover.printSummary(net)
    print(("crystals: buffer=%s  engravers=%d  monitor=%s"):format(
        tostring(net.buffer),
        #(net.machines or {}),
        tostring(net.monitorName)
    ))
    local m = net.machines or {}
    local show = math.min(#m, 8)
    for i = 1, show do
        print("  engraver: " .. m[i])
    end
    if #m > show then
        print(("  ... +%d more"):format(#m - show))
    end
end

return discover
