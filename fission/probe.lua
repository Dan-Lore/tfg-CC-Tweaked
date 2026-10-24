-- Temporary Dea's Fission (deafission) API probe for TFG.
-- Layout: advanced monitor on right (4x3), reactor + optional crate.
--
-- Deploy: copy as probe.lua, run: probe
-- Keys: up/down scroll, pgUp/pgDn page, home/end, r refresh, q quit
-- Full dump always written to fission_probe.txt (scroll the monitor).

local REACTOR = "fission_reactor_0"
local CRATE = "gtceu:steel_crate_1"
local MONITOR = "right"
local TEXT_SCALE = 0.5
local REFRESH = 3

local function add(lines, s)
    lines[#lines + 1] = s
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == "number" and tb == "number" then
            return a < b
        end
        if ta == "number" then
            return true
        end
        if tb == "number" then
            return false
        end
        return tostring(a) < tostring(b)
    end)
    return keys
end

--- Pretty-print any value as indented lines (no key truncation).
local function dumpValue(lines, v, depth)
    depth = depth or 0
    local pad = string.rep("  ", depth)
    local t = type(v)
    if t == "nil" then
        add(lines, pad .. "nil")
    elseif t == "boolean" or t == "number" then
        add(lines, pad .. tostring(v))
    elseif t == "string" then
        add(lines, pad .. string.format("%q", v))
    elseif t ~= "table" then
        add(lines, pad .. "<" .. t .. ">")
    else
        local keys = sortedKeys(v)
        local nArr = #v
        if #keys == 0 then
            add(lines, pad .. "{}")
            return
        end
        for i = 1, #keys do
            local k = keys[i]
            local val = v[k]
            local isIdx = type(k) == "number" and k >= 1 and k <= nArr and k % 1 == 0
            local label = isIdx and ("[" .. tostring(k) .. "]") or tostring(k)
            if type(val) == "table" then
                add(lines, pad .. label .. ":")
                dumpValue(lines, val, depth + 1)
            elseif type(val) == "string" then
                add(lines, pad .. label .. " = " .. string.format("%q", val))
            else
                add(lines, pad .. label .. " = " .. tostring(val))
            end
        end
    end
end

local function dumpCall(lines, title, ...)
    add(lines, title)
    local vals = { ... }
    local last = 0
    for i = 1, #vals do
        if vals[i] ~= nil then
            last = i
        end
    end
    if last == 0 then
        add(lines, "  nil")
        return
    end
    if last == 1 then
        dumpValue(lines, vals[1], 1)
    else
        for i = 1, last do
            add(lines, "  #" .. i .. ":")
            dumpValue(lines, vals[i], 2)
        end
    end
end

local function discoverMonitor()
    if peripheral.isPresent(MONITOR) and peripheral.getType(MONITOR) == "monitor" then
        return peripheral.wrap(MONITOR), MONITOR
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            return peripheral.wrap(name), name
        end
    end
    return nil, nil
end

local function discoverReactor()
    if peripheral.isPresent(REACTOR) then
        return peripheral.wrap(REACTOR), REACTOR
    end
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if name:find("fission_reactor", 1, true) then
            found[#found + 1] = name
        end
    end
    table.sort(found)
    if #found > 0 then
        return peripheral.wrap(found[1]), found[1]
    end
    return nil, nil
end

local function countRods(fuels)
    local n = 0
    if type(fuels) ~= "table" then
        return 0
    end
    for i = 1, #fuels do
        local e = fuels[i]
        if e then
            n = n + (tonumber(e.rods) or 0)
        end
    end
    return n
end

local function probeReactor(lines, name)
    local types = { peripheral.getType(name) }
    local t2 = select(2, peripheral.getType(name))
    if t2 then
        types[#types + 1] = t2
    end

    add(lines, "=== Dea's Fission probe ===")
    add(lines, "reactor: " .. name)
    add(lines, "types: " .. table.concat(types, ", "))
    add(lines, "")

    local methods = peripheral.getMethods(name) or {}
    table.sort(methods)
    add(lines, "methods (" .. #methods .. "):")
    for i = 1, #methods do
        add(lines, "  " .. methods[i])
    end
    add(lines, "")

    -- Explicit known API (full expand)
    local okV, ver = pcall(peripheral.call, name, "getVersion")
    dumpCall(lines, "getVersion:", okV and ver or ("ERR " .. tostring(ver)))
    add(lines, "")

    local okM, metrics = pcall(peripheral.call, name, "getMetrics")
    if not okM then
        add(lines, "getMetrics ERR " .. tostring(metrics))
    else
        dumpCall(lines, "getMetrics:", metrics)
    end
    add(lines, "")

    local okF, fuels = pcall(peripheral.call, name, "getFuels")
    if not okF then
        add(lines, "getFuels ERR " .. tostring(fuels))
    else
        add(lines, "getFuels rods_total=" .. tostring(countRods(fuels)))
        dumpCall(lines, "getFuels:", fuels)
    end
end

local function probeCrate(lines, crateName)
    add(lines, "")
    add(lines, "=== crate " .. crateName .. " ===")
    if not peripheral.isPresent(crateName) then
        add(lines, "missing")
        return
    end

    local inv = peripheral.wrap(crateName)
    local types = { peripheral.getType(crateName) }
    add(lines, "types: " .. table.concat(types, ", "))

    local methods = peripheral.getMethods(crateName) or {}
    table.sort(methods)
    add(lines, "methods (" .. #methods .. "):")
    for i = 1, #methods do
        add(lines, "  " .. methods[i])
    end

    local size = nil
    if inv.size then
        local ok, s = pcall(inv.size)
        if ok then
            size = s
        end
    end
    add(lines, "size: " .. tostring(size))

    local list = {}
    if inv.list then
        local ok, listed = pcall(inv.list)
        if ok and type(listed) == "table" then
            list = listed
        end
    end

    local slots = {}
    for slot in pairs(list) do
        slots[#slots + 1] = slot
    end
    table.sort(slots)

    add(lines, "occupied slots: " .. #slots)
    add(lines, "")

    for i = 1, #slots do
        local slot = slots[i]
        local brief = list[slot]
        add(lines, string.format("--- slot %s (list) ---", tostring(slot)))
        dumpValue(lines, brief, 1)

        if inv.getItemDetail then
            local ok, detail = pcall(inv.getItemDetail, slot)
            add(lines, string.format("--- slot %s (getItemDetail) ---", tostring(slot)))
            if not ok then
                add(lines, "  ERR " .. tostring(detail))
            else
                dumpValue(lines, detail, 1)
            end
        end

        if inv.getItemMeta then
            local ok, meta = pcall(inv.getItemMeta, slot)
            add(lines, string.format("--- slot %s (getItemMeta) ---", tostring(slot)))
            if not ok then
                add(lines, "  ERR " .. tostring(meta))
            else
                dumpValue(lines, meta, 1)
            end
        end
        add(lines, "")
    end
end

local function probeNetwork(lines)
    add(lines, "")
    add(lines, "=== network peripherals ===")
    local names = peripheral.getNames()
    table.sort(names)
    for i = 1, #names do
        local n = names[i]
        add(lines, "  " .. n .. "  [" .. tostring(peripheral.getType(n) or "?") .. "]")
    end
end

local function buildReport(reactorName)
    local lines = {}
    probeReactor(lines, reactorName)
    probeCrate(lines, CRATE)
    probeNetwork(lines)
    add(lines, "")
    add(lines, "(end)")
    return lines
end

local function writeDump(lines)
    local f = fs.open("fission_probe.txt", "w")
    if not f then
        return false
    end
    for i = 1, #lines do
        f.writeLine(lines[i])
    end
    f.close()
    return true
end

local function main()
    local mon, monName = discoverMonitor()
    local reactor, reactorName = discoverReactor()

    if not reactor then
        print("No fission_reactor_* peripheral.")
        print("Expected: " .. REACTOR)
        return
    end

    local scroll = 0
    local lines = {}
    local w, h = term.getSize()

    local function refresh()
        lines = buildReport(reactorName)
        writeDump(lines)
        print("Wrote fission_probe.txt (" .. #lines .. " lines)")
    end

    local function draw()
        local out = mon or term
        if mon then
            mon.setTextScale(TEXT_SCALE)
            w, h = mon.getSize()
        else
            w, h = term.getSize()
        end
        out.clear()
        local maxScroll = math.max(0, #lines - h)
        if scroll > maxScroll then
            scroll = maxScroll
        end
        if scroll < 0 then
            scroll = 0
        end
        for row = 1, h do
            local idx = scroll + row
            out.setCursorPos(1, row)
            local text = lines[idx] or ""
            if #text > w then
                text = text:sub(1, w - 1) .. ">"
            end
            out.write(text)
        end
        if mon then
            term.clear()
            term.setCursorPos(1, 1)
            print("probe mon=" .. tostring(monName))
            print("reactor=" .. tostring(reactorName))
            print("crate=" .. CRATE)
            print("scroll " .. scroll .. "/" .. math.max(0, #lines - h)
                .. "  lines=" .. #lines)
            print("keys: up/down pgUp/pgDn home/end r q")
            print("file: fission_probe.txt")
        end
    end

    refresh()
    draw()

    local timer = os.startTimer(REFRESH)
    while true do
        local ev, a = os.pullEvent()
        if ev == "timer" and a == timer then
            refresh()
            draw()
            timer = os.startTimer(REFRESH)
        elseif ev == "key" then
            if a == keys.q then
                break
            elseif a == keys.r then
                refresh()
                draw()
            elseif a == keys.up then
                scroll = scroll - 1
                draw()
            elseif a == keys.down then
                scroll = scroll + 1
                draw()
            elseif a == keys.pageUp then
                scroll = scroll - (h - 1)
                draw()
            elseif a == keys.pageDown then
                scroll = scroll + (h - 1)
                draw()
            elseif a == keys.home then
                scroll = 0
                draw()
            elseif a == keys["end"] then
                scroll = math.max(0, #lines - h)
                draw()
            end
        elseif ev == "peripheral" or ev == "peripheral_detach" then
            reactor, reactorName = discoverReactor()
            mon, monName = discoverMonitor()
            if reactor then
                refresh()
                draw()
            end
        end
    end
end

main()
