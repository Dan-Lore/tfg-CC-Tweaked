-- Minimal CC: Tweaked API stubs for desktop Lua unit tests.

local M = {}

local files = {} -- path -> content string
local peripherals = {} -- name -> wrap table
local present = {} -- name -> true
local clock_now = 0
local epoch_ms = 1700000000000
local event_queue = {}
local next_timer_id = 1
local timers = {} -- id -> fire_at_clock
local running_program = "tests/program.lua"

local function normalize(path)
    path = tostring(path or ""):gsub("\\", "/")
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    -- collapse // and .
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then
                parts[#parts] = nil
            end
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return "/" .. table.concat(parts, "/")
end

function M.reset()
    files = {}
    peripherals = {}
    present = {}
    clock_now = 0
    epoch_ms = 1700000000000
    event_queue = {}
    next_timer_id = 1
    timers = {}
    running_program = "tests/program.lua"
end

function M.setClock(t)
    clock_now = tonumber(t) or 0
end

function M.advanceClock(dt)
    clock_now = clock_now + (tonumber(dt) or 0)
    for id, fire_at in pairs(timers) do
        if fire_at <= clock_now then
            event_queue[#event_queue + 1] = { "timer", id }
            timers[id] = nil
        end
    end
end

function M.setEpochMs(ms)
    epoch_ms = tonumber(ms) or epoch_ms
end

function M.writeFile(path, content)
    files[normalize(path)] = tostring(content or "")
end

function M.readFile(path)
    return files[normalize(path)]
end

function M.addPeripheral(name, wrap)
    present[name] = true
    peripherals[name] = wrap or {}
end

function M.removePeripheral(name)
    present[name] = nil
    peripherals[name] = nil
end

function M.setRunningProgram(path)
    running_program = path
end

function M.install()
    -- fs
    fs = {
        combine = function(a, b)
            a = tostring(a or "")
            b = tostring(b or "")
            if b:sub(1, 1) == "/" then
                return normalize(b)
            end
            if a == "" or a == "/" then
                return normalize("/" .. b)
            end
            return normalize(a .. "/" .. b)
        end,
        getDir = function(path)
            path = normalize(path)
            local dir = path:match("^(.*)/[^/]+$")
            return dir or "/"
        end,
        getName = function(path)
            path = normalize(path)
            return path:match("([^/]+)$") or path
        end,
        exists = function(path)
            return files[normalize(path)] ~= nil
        end,
        open = function(path, mode)
            path = normalize(path)
            mode = mode or "r"
            if mode:find("r", 1, true) then
                local content = files[path]
                if content == nil then
                    return nil
                end
                -- CC file handles: dot-call, no self
                return {
                    readAll = function()
                        return content
                    end,
                    close = function() end,
                }
            end
            if mode:find("w", 1, true) then
                local buf = {}
                return {
                    write = function(data)
                        buf[#buf + 1] = tostring(data)
                    end,
                    close = function()
                        files[path] = table.concat(buf)
                    end,
                }
            end
            return nil
        end,
    }

    -- shell
    shell = {
        getRunningProgram = function()
            return running_program
        end,
    }

    -- os
    os = {
        clock = function()
            return clock_now
        end,
        epoch = function(_kind)
            return epoch_ms
        end,
        queueEvent = function(name, ...)
            event_queue[#event_queue + 1] = { name, ... }
        end,
        pullEvent = function(filter)
            while true do
                if #event_queue > 0 then
                    local ev = table.remove(event_queue, 1)
                    if not filter or ev[1] == filter then
                        return table.unpack(ev)
                    end
                else
                    -- fire any due timers, else advance slightly
                    local fired = false
                    for id, fire_at in pairs(timers) do
                        if fire_at <= clock_now then
                            event_queue[#event_queue + 1] = { "timer", id }
                            timers[id] = nil
                            fired = true
                        end
                    end
                    if not fired then
                        -- find next timer
                        local next_at = nil
                        for _, fire_at in pairs(timers) do
                            if not next_at or fire_at < next_at then
                                next_at = fire_at
                            end
                        end
                        if next_at then
                            clock_now = next_at
                        else
                            clock_now = clock_now + 0.05
                            return "timer", -1
                        end
                    end
                end
            end
        end,
        startTimer = function(seconds)
            local id = next_timer_id
            next_timer_id = next_timer_id + 1
            timers[id] = clock_now + (tonumber(seconds) or 0)
            return id
        end,
        sleep = function(seconds)
            M.advanceClock(tonumber(seconds) or 0)
        end,
    }

    sleep = function(seconds)
        os.sleep(seconds)
    end

    -- peripheral
    peripheral = {
        isPresent = function(name)
            return present[name] == true
        end,
        wrap = function(name)
            return peripherals[name]
        end,
        getNames = function()
            local names = {}
            for n in pairs(present) do
                names[#names + 1] = n
            end
            table.sort(names)
            return names
        end,
        getType = function(name)
            local p = peripherals[name]
            return p and p._type or nil
        end,
        call = function(name, method, ...)
            local p = peripherals[name]
            if not p or type(p[method]) ~= "function" then
                error("no method " .. tostring(method))
            end
            return p[method](p, ...)
        end,
        getName = function(obj)
            for n, p in pairs(peripherals) do
                if p == obj then
                    return n
                end
            end
            return nil
        end,
    }

    -- textutils (enough for history save/load)
    textutils = {
        serialize = function(value)
            local function ser(v, depth)
                depth = depth or 0
                local t = type(v)
                if t == "nil" then
                    return "nil"
                elseif t == "boolean" then
                    return v and "true" or "false"
                elseif t == "number" then
                    return tostring(v)
                elseif t == "string" then
                    return string.format("%q", v)
                elseif t == "table" then
                    local parts = {}
                    local n = #v
                    local isArray = n > 0
                    if isArray then
                        for i = 1, n do
                            parts[#parts + 1] = ser(v[i], depth + 1)
                        end
                        return "{" .. table.concat(parts, ",") .. "}"
                    end
                    for k, val in pairs(v) do
                        local key
                        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                            key = k .. "="
                        else
                            key = "[" .. ser(k, depth + 1) .. "]="
                        end
                        parts[#parts + 1] = key .. ser(val, depth + 1)
                    end
                    return "{" .. table.concat(parts, ",") .. "}"
                end
                error("cannot serialize " .. t)
            end
            return ser(value)
        end,
        unserialize = function(str)
            local fn, err = load("return " .. tostring(str), "=unserialize", "t", {})
            if not fn then
                error(err)
            end
            return fn()
        end,
    }

    -- rednet noop
    rednet = {
        open = function() end,
        host = function() end,
        send = function() end,
        receive = function()
            return nil
        end,
    }
end

--- Build a simple inventory peripheral mock.
-- CC wrap methods are called with dot syntax and NO self (bound to peripheral.call).
function M.makeInventory(slots)
    -- slots: { [slot] = { name=, count=, detail?= } }
    slots = slots or {}
    local inv = { _type = "inventory", _slots = slots }

    function inv.list()
        local out = {}
        for slot, item in pairs(slots) do
            out[slot] = { name = item.name, count = item.count }
        end
        return out
    end

    function inv.getItemDetail(slot)
        local item = slots[slot]
        if not item then
            return nil
        end
        if item.detail then
            return item.detail
        end
        return { name = item.name, count = item.count, tags = item.tags }
    end

    function inv.pushItems(toName, fromSlot, limit, _toSlot)
        local item = slots[fromSlot]
        if not item then
            return 0
        end
        local n = math.min(item.count, tonumber(limit) or item.count)
        if n <= 0 then
            return 0
        end
        local dest = peripherals[toName]
        if not dest then
            return 0
        end
        local movedName = item.name
        item.count = item.count - n
        if item.count <= 0 then
            slots[fromSlot] = nil
        end
        if dest._receive then
            dest._receive(movedName, n)
        end
        return n
    end

    function inv._receive(name, count)
        for _, item in pairs(slots) do
            if item.name == name then
                item.count = item.count + count
                return
            end
        end
        local free = 1
        while slots[free] do
            free = free + 1
        end
        slots[free] = { name = name, count = count }
    end

    return inv
end

--- Build a simple fluid tank mock (CC-style, no self).
function M.makeTank(fluids)
    -- fluids: { { name=, amount= }, ... }
    fluids = fluids or {}
    local tank = { _type = "tank", _fluids = fluids }

    function tank.tanks()
        return fluids
    end

    function tank.pushFluid(toName, amount, fluidName)
        amount = tonumber(amount) or 0
        for _, t in ipairs(fluids) do
            if t.name == fluidName and t.amount > 0 then
                local n = math.min(t.amount, amount)
                t.amount = t.amount - n
                local dest = peripherals[toName]
                if dest and dest._receiveFluid then
                    dest._receiveFluid(fluidName, n)
                end
                return n
            end
        end
        return 0
    end

    function tank._receiveFluid(fluidName, amount)
        for _, t in ipairs(fluids) do
            if t.name == fluidName then
                t.amount = t.amount + amount
                return
            end
        end
        fluids[#fluids + 1] = { name = fluidName, amount = amount }
    end

    return tank
end

return M
