-- Feed buffer gems into laser engravers (even counts, dual-slot queue).

local gems = require("gems")

local feed = {}

local INPUT_SLOTS = 2 -- main + extra; queue different crystal types

local function listInv(name)
    if not name or not peripheral.isPresent(name) then
        return nil
    end
    local inv = peripheral.wrap(name)
    if not inv or not inv.list then
        return nil
    end
    local ok, list = pcall(inv.list)
    if not ok or type(list) ~= "table" then
        return nil
    end
    return inv, list
end

--- Aggregate gem stock in the buffer (even>0 only for processable tiers).
function feed.bufferStock(bufferName)
    local _, list = listInv(bufferName)
    local byName = {}
    if not list then
        return byName
    end
    for _, item in pairs(list) do
        if item and item.name then
            local info = gems.parse(item.name)
            if info then
                local cur = byName[item.name]
                if not cur then
                    cur = {
                        name = item.name,
                        material = info.material,
                        tier = info.tier,
                        processable = info.processable,
                        count = 0,
                    }
                    byName[item.name] = cur
                end
                cur.count = cur.count + (item.count or 0)
            end
        end
    end
    for _, cur in pairs(byName) do
        if cur.processable then
            cur.even = gems.evenStock(cur.count)
        else
            cur.even = 0
        end
        cur.single = cur.count % 2
    end
    return byName
end

--- Inspect engraver gem occupancy (ignores lenses / non-gems).
function feed.inspectMachine(name, maxStack)
    maxStack = maxStack or 64
    local inv, list = listInv(name)
    local stacks = {}
    local byName = {}
    if list then
        for slot, item in pairs(list) do
            if item and item.name then
                local info = gems.parse(item.name)
                if info then
                    local st = {
                        slot = slot,
                        name = item.name,
                        count = item.count or 0,
                        info = info,
                        room = gems.evenRoom(item.count or 0, maxStack),
                    }
                    stacks[#stacks + 1] = st
                    byName[item.name] = st
                end
            end
        end
    end
    return {
        name = name,
        stacks = stacks,
        byName = byName,
        gemSlots = #stacks,
        freeSlots = math.max(0, INPUT_SLOTS - #stacks),
    }
end

local function scoreTarget(m, itemName, room)
    -- Higher = better. Prefer topping up same item, then queue on busy machine, then empty.
    if m.byName[itemName] then
        return 3000 + (m.byName[itemName].count or 0) + room
    end
    if m.freeSlots > 0 and m.gemSlots > 0 then
        return 2000 + m.gemSlots * 10 + room
    end
    if m.freeSlots > 0 then
        return 1000 + room
    end
    return 0
end

local function machineRoom(m, itemName, maxStack)
    local existing = m.byName[itemName]
    if existing then
        return existing.room, existing.count or 0
    end
    if m.freeSlots > 0 then
        return gems.evenRoom(0, maxStack), 0
    end
    return 0, 0
end

--- How many to push: final machine count even; leave 0/1 in buffer when possible.
local function feedAmount(bufferCount, machineCount, maxStack)
    bufferCount = tonumber(bufferCount) or 0
    machineCount = tonumber(machineCount) or 0
    maxStack = tonumber(maxStack) or 64
    local room = maxStack - machineCount
    if room <= 0 or bufferCount <= 0 then
        return 0
    end

    -- Default: take only even stock, leave a single in the buffer.
    local leave = bufferCount % 2
    local takeMax = bufferCount - leave
    local want = math.min(takeMax, room)

    -- Final stack in the machine must be even (otherwise the recipe stalls).
    if (machineCount + want) % 2 ~= 0 then
        if want > 0 then
            want = want - 1
        end
    end

    -- Odd machine with no even adjustment left: spend 1 from buffer to unstall.
    if want == 0 and machineCount % 2 == 1 and room >= 1 and bufferCount >= 1 then
        want = 1
    end

    if want <= 0 then
        return 0
    end
    if (machineCount + want) % 2 ~= 0 then
        return 0
    end
    return want
end

--- Pick best engraver for itemName that still has feed room.
local function bestMachine(machines, itemName, maxStack, bufferCount)
    local best, bestScore, bestWant = nil, 0, 0
    for i = 1, #machines do
        local m = machines[i]
        local _, cur = machineRoom(m, itemName, maxStack)
        local can = false
        if m.byName[itemName] then
            can = true
        elseif m.freeSlots > 0 then
            can = true
            cur = 0
        end
        if can then
            local want = feedAmount(bufferCount, cur, maxStack)
            if want > 0 then
                local sc = scoreTarget(m, itemName, want)
                if sc > bestScore then
                    best, bestScore, bestWant = m, sc, want
                end
            end
        end
    end
    return best, bestWant
end

--- Push up to `limit` of itemName from buffer into machine (any matching source slots).
local function pushFromBuffer(bufferName, machineName, itemName, limit)
    if limit <= 0 then
        return 0
    end
    local source = peripheral.wrap(bufferName)
    if not source or not source.list or not source.pushItems then
        return 0
    end
    local movedTotal = 0
    local list = source.list()
    if not list then
        return 0
    end
    for slot, item in pairs(list) do
        if item and item.name == itemName and movedTotal < limit then
            local need = limit - movedTotal
            local moved = source.pushItems(machineName, slot, need) or 0
            movedTotal = movedTotal + moved
            if movedTotal >= limit then
                break
            end
        end
    end
    return movedTotal
end

--- Priority: more even stock first, then lower tier (cascade upward), then name.
local function stockPriority(a, b)
    if a.even ~= b.even then
        return a.even > b.even
    end
    if a.tier ~= b.tier then
        return a.tier < b.tier
    end
    return a.name < b.name
end

--- One feed pass. Returns { moved, fed, status, stock, machineStats }.
function feed.tick(bufferName, machineNames, opts)
    opts = opts or {}
    local maxStack = opts.maxStack or 64
    local batch = opts.batch or 2

    local stockMap = feed.bufferStock(bufferName)
    local stockList = {}
    for _, s in pairs(stockMap) do
        if s.processable and (s.count or 0) >= 1 then
            stockList[#stockList + 1] = s
        end
    end
    table.sort(stockList, stockPriority)

    local machines = {}
    local busy, queued, empty, oddFix = 0, 0, 0, 0
    for i = 1, #machineNames do
        local m = feed.inspectMachine(machineNames[i], maxStack)
        machines[#machines + 1] = m
        if m.gemSlots == 0 then
            empty = empty + 1
        elseif m.gemSlots >= INPUT_SLOTS then
            busy = busy + 1
        else
            queued = queued + 1 -- 1 stack → room for a second type
        end
        for _, st in ipairs(m.stacks) do
            if st.count % 2 == 1 then
                oddFix = oddFix + 1
            end
        end
    end

    local anyEven = false
    for i = 1, #stockList do
        if (stockList[i].even or 0) >= batch then
            anyEven = true
            break
        end
    end

    if not anyEven and oddFix == 0 then
        return {
            moved = 0,
            fed = 0,
            status = "idle all singles",
            stock = stockMap,
            stockList = stockList,
            busy = busy,
            queued = queued,
            empty = empty,
            oddFix = oddFix,
            engravers = #machineNames,
        }
    end

    local movedTotal = 0
    local fedOps = 0
    local lastItem = nil

    -- Keep pushing while any stock has pairs and any machine has room.
    local guard = 0
    while guard < 512 do
        guard = guard + 1
        local progressed = false

        for si = 1, #stockList do
            local s = stockList[si]
            local available = s.count or 0
            if available >= 1 then
                local m, want = bestMachine(machines, s.name, maxStack, available)
                if m and want and want > 0 then
                    local moved = pushFromBuffer(bufferName, m.name, s.name, want)
                    if moved > 0 then
                        movedTotal = movedTotal + moved
                        fedOps = fedOps + 1
                        lastItem = s.name
                        s.count = available - moved
                        s.even = gems.evenStock(s.count)
                        s.single = s.count % 2
                        local idx = nil
                        for mi = 1, #machines do
                            if machines[mi].name == m.name then
                                idx = mi
                                break
                            end
                        end
                        if idx then
                            machines[idx] = feed.inspectMachine(m.name, maxStack)
                        end
                        progressed = true
                        sleep(0)
                    end
                end
            end
        end

        if not progressed then
            break
        end
    end

    -- Recompute occupancy after feeds.
    busy, queued, empty = 0, 0, 0
    for i = 1, #machineNames do
        local m = feed.inspectMachine(machineNames[i], maxStack)
        if m.gemSlots == 0 then
            empty = empty + 1
        elseif m.gemSlots >= INPUT_SLOTS then
            busy = busy + 1
        else
            queued = queued + 1
        end
    end

    local status
    if movedTotal > 0 then
        status = ("fed %d (%s)"):format(movedTotal, gems.short(lastItem, 16))
    else
        status = "wait engravers full"
    end

    return {
        moved = movedTotal,
        fed = fedOps,
        status = status,
        stock = stockMap,
        stockList = stockList,
        busy = busy,
        queued = queued,
        empty = empty,
        oddFix = oddFix,
        engravers = #machineNames,
    }
end

return feed
