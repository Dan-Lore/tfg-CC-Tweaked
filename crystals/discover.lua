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

local BUFFER_NEEDLES = {
    "crate",
    "chest",
    "barrel",
    "drawer",
    "shulker",
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
    if not name or not peripheral.isPresent(name) then
        return false
    end
    local inv = peripheral.wrap(name)
    return inv and type(inv.list) == "function" and type(inv.pushItems) == "function"
end

--- GT crate ids sometimes drop the underscore: tungsten_steel <-> tungstensteel
local function nameAliases(name)
    local out = { name }
    if not name then
        return out
    end
    local alt = name:gsub("tungsten_steel", "tungstensteel", 1)
    if alt ~= name then
        out[#out + 1] = alt
    else
        alt = name:gsub("tungstensteel", "tungsten_steel", 1)
        if alt ~= name then
            out[#out + 1] = alt
        end
    end
    return out
end

local function resolveInventory(preferred, label, machineSet)
    machineSet = machineSet or {}
    if not preferred then
        return nil
    end
    local aliases = nameAliases(preferred)
    for i = 1, #aliases do
        local name = aliases[i]
        if isInventory(name) and not machineSet[name] then
            if name ~= preferred then
                print(("crystals: %s %s -> %s"):format(label, preferred, name))
            end
            return name
        end
    end
    print(("crystals: missing %s %s"):format(label, tostring(preferred)))
    return nil
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

local function isLocalSide(name)
    return name and LOCAL_SIDES[tostring(name):lower()] == true
end

--- Network inventories that can pushItems to modem-connected engravers.
local function findNetworkBuffers(machineSet)
    machineSet = machineSet or {}
    local list = {}
    local names = peripheral.getNames()
    for i = 1, #names do
        local name = names[i]
        if not machineSet[name] and not isLocalSide(name) then
            local types = peripheralTypes(name)
            if not shouldSkip(name, types) and isInventory(name)
                and matchesAny(name, types, BUFFER_NEEDLES)
            then
                list[#list + 1] = name
            end
        end
        if i % 8 == 0 then
            sleep(0)
        end
    end
    table.sort(list)
    return list
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

--- Buffer: explicit network name > networked crate/chest > local side (last resort).
-- Local sides often cannot pushItems to modem engravers.
function discover.buffer(preferred, machineSet, skip)
    machineSet = machineSet or {}
    skip = skip or {}

    -- Explicit networked peripheral name (not a side).
    if preferred and not isLocalSide(preferred) then
        local name = resolveInventory(preferred, "buffer", machineSet)
        if name and not skip[name] then
            return name
        end
    end

    local netBufs = findNetworkBuffers(machineSet)
    local filtered = {}
    for i = 1, #netBufs do
        if not skip[netBufs[i]] then
            filtered[#filtered + 1] = netBufs[i]
        end
    end
    netBufs = filtered
    if #netBufs == 1 then
        if preferred and isLocalSide(preferred) then
            print("crystals: using networked buffer " .. netBufs[1]
                .. " (local " .. preferred .. " cannot reach modem engravers)")
        end
        return netBufs[1]
    end
    if #netBufs > 1 then
        local pick = netBufs[1]
        for i = 1, #netBufs do
            local n = netBufs[i]:lower()
            if n:find("tungsten", 1, true) or n:find("stainless", 1, true) then
                pick = netBufs[i]
                break
            end
        end
        print("crystals: multiple buffers, using " .. pick)
        return pick
    end

    -- Local side fallback.
    if preferred and isLocalSide(preferred) and isInventory(preferred) and not machineSet[preferred] then
        print("crystals: warning: buffer " .. preferred
            .. " is local-only; put a modem on the crate")
        return preferred
    end
    for _, side in ipairs({ "top", "bottom", "front", "back", "left", "right" }) do
        if isInventory(side) and not machineSet[side] then
            print("crystals: warning: buffer " .. side
                .. " is local-only; put a modem on the crate")
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

function discover.overflow(cfg, machineSet, primary)
    machineSet = machineSet or {}
    cfg = cfg or {}
    local names = {}
    if type(cfg.OVERFLOW) == "table" then
        names = cfg.OVERFLOW
    elseif type(cfg.OVERFLOW) == "string" and cfg.OVERFLOW ~= "" then
        names = { cfg.OVERFLOW }
    end
    local out = {}
    local seen = {}
    if primary then
        seen[primary] = true
    end
    for i = 1, #names do
        local resolved = resolveInventory(names[i], "overflow", machineSet)
        if resolved and not seen[resolved] then
            seen[resolved] = true
            out[#out + 1] = resolved
        end
    end
    return out
end

function discover.scan(cfg)
    local machines, machineSet = discover.machines(cfg)
    local skip = {}
    local overflowNames = {}
    if type(cfg.OVERFLOW) == "table" then
        overflowNames = cfg.OVERFLOW
    elseif type(cfg.OVERFLOW) == "string" then
        overflowNames = { cfg.OVERFLOW }
    end
    for i = 1, #overflowNames do
        local aliases = nameAliases(overflowNames[i])
        for a = 1, #aliases do
            skip[aliases[a]] = true
        end
    end
    local buffer = discover.buffer(cfg.BUFFER, machineSet, skip)
    local overflow = discover.overflow(cfg, machineSet, buffer)
    local monitor, monitorName = discover.monitor(cfg.MONITOR)
    return {
        machines = machines,
        buffer = buffer,
        overflow = overflow,
        monitor = monitor,
        monitorName = monitorName,
    }
end

function discover.printSummary(net)
    local ov = net.overflow or {}
    print(("crystals: buffer=%s  overflow=%d  engravers=%d  monitor=%s"):format(
        tostring(net.buffer),
        #ov,
        #(net.machines or {}),
        tostring(net.monitorName)
    ))
    for i = 1, #ov do
        print("  overflow: " .. ov[i])
    end
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
