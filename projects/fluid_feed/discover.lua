-- Discover fluid buffer, EV input hatches, and monitor.

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

local function isTank(name)
    if not name or not peripheral.isPresent(name) then
        return false
    end
    local p = peripheral.wrap(name)
    return p and type(p.tanks) == "function" and type(p.pushFluid) == "function"
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

local function resolveName(preferred)
    if not preferred or preferred == "" then
        return nil
    end
    if peripheral.isPresent(preferred) then
        return preferred
    end
    return nil
end

function discover.monitor(preferred)
    local name = resolveName(preferred)
    if name then
        local m = peripheral.wrap(name)
        if m and m.clear then
            return m, name
        end
    end
    local names = peripheral.getNames()
    for i = 1, #names do
        local n = names[i]
        if peripheral.getType(n) == "monitor" then
            local m = peripheral.wrap(n)
            if m and m.clear then
                return m, n
            end
        end
    end
    return nil, nil
end

function discover.buffer(preferred)
    if preferred and isTank(preferred) then
        return preferred
    end
    if preferred then
        print("fluid_feed: missing buffer " .. tostring(preferred))
    end
    return nil
end

function discover.hatches(cfg)
    cfg = cfg or {}
    local list = {}

    if type(cfg.HATCHES) == "table" and #cfg.HATCHES > 0 then
        for i = 1, #cfg.HATCHES do
            local name = cfg.HATCHES[i]
            if isTank(name) then
                list[#list + 1] = name
            else
                print("fluid_feed: missing hatch " .. tostring(name))
            end
        end
        return sortNames(list)
    end

    local needles = cfg.HATCH_SUBSTR or "gtceu:ev_input_hatch_4x"
    local names = peripheral.getNames()
    for i = 1, #names do
        local name = names[i]
        local types = peripheralTypes(name)
        if not shouldSkip(name, types) and isTank(name) and matchesAny(name, types, needles) then
            list[#list + 1] = name
        end
        if i % 8 == 0 then
            sleep(0)
        end
    end
    return sortNames(list)
end

--- Returns { buffer, hatches, monitor, monitorName }.
function discover.scan(cfg)
    cfg = cfg or {}
    local buffer = discover.buffer(cfg.BUFFER)
    local hatches = discover.hatches(cfg)
    local monitor, monitorName = discover.monitor(cfg.MONITOR)
    return {
        buffer = buffer,
        hatches = hatches,
        monitor = monitor,
        monitorName = monitorName,
    }
end

function discover.printSummary(net)
    net = net or {}
    local h = net.hatches or {}
    print(("fluid_feed: buffer=%s  hatches=%d  monitor=%s"):format(
        tostring(net.buffer),
        #h,
        tostring(net.monitorName)
    ))
    for i = 1, #h do
        print("  hatch: " .. h[i])
    end
end

return discover
