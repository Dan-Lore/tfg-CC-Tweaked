-- Idle sort: same material tiers adjacent; odd leftovers stay as count=1.

local gems = require("gems")

local sort = {}

local function getInv(name)
    if not name or not peripheral.isPresent(name) then
        return nil
    end
    local inv = peripheral.wrap(name)
    if not inv or not inv.list or not inv.pushItems or not inv.size then
        return nil
    end
    return inv
end

local function itemAt(list, slot)
    return list and list[slot] or nil
end

local function push(inv, name, fromSlot, limit, toSlot)
    local ok, moved
    if toSlot ~= nil then
        ok, moved = pcall(inv.pushItems, name, fromSlot, limit, toSlot)
    else
        ok, moved = pcall(inv.pushItems, name, fromSlot, limit)
    end
    if not ok then
        return 0
    end
    return tonumber(moved) or 0
end

local function aggregateGems(list)
    local byName = {}
    for _, item in pairs(list) do
        if item and item.name and gems.isGem(item.name) then
            local info = gems.parse(item.name)
            local cur = byName[item.name]
            if not cur then
                cur = {
                    name = item.name,
                    material = info.material,
                    tier = info.tier,
                    count = 0,
                }
                byName[item.name] = cur
            end
            cur.count = cur.count + (item.count or 0)
        end
    end
    return byName
end

local function materialOrder(byName)
    local mats, seen = {}, {}
    for _, g in pairs(byName) do
        if not seen[g.material] then
            seen[g.material] = true
            mats[#mats + 1] = g.material
        end
    end
    table.sort(mats)
    return mats
end

local function buildPlan(byName, maxStack)
    maxStack = maxStack or 64
    local evenCap = maxStack - (maxStack % 2)
    if evenCap < 2 then
        evenCap = 2
    end
    local plan = {}
    local mats = materialOrder(byName)

    for mi = 1, #mats do
        local mat = mats[mi]
        for tier = 1, 5 do
            local itemName, count = nil, 0
            for _, g in pairs(byName) do
                if g.material == mat and g.tier == tier then
                    itemName, count = g.name, g.count
                    break
                end
            end
            if itemName and count > 0 then
                local even = count - (count % 2)
                local single = count % 2
                while even >= 2 do
                    local n = math.min(even, evenCap)
                    plan[#plan + 1] = { name = itemName, count = n }
                    even = even - n
                end
                if single > 0 then
                    plan[#plan + 1] = { name = itemName, count = 1 }
                end
            end
        end
    end
    return plan
end

local function layoutMatches(list, plan, size)
    for i = 1, #plan do
        local item = itemAt(list, i)
        local want = plan[i]
        if not item or item.name ~= want.name or (item.count or 0) ~= want.count then
            return false
        end
    end
    for i = #plan + 1, size do
        local item = itemAt(list, i)
        if item and gems.isGem(item.name) then
            return false
        end
    end
    return true
end

local function findFree(list, size, avoid)
    for slot = size, 1, -1 do
        if slot ~= avoid and not itemAt(list, slot) then
            return slot
        end
    end
    return nil
end

local function findLowestGem(list, size, maxSlot)
    maxSlot = maxSlot or size
    for slot = 1, maxSlot do
        local item = itemAt(list, slot)
        if item and gems.isGem(item.name) then
            return slot, item
        end
    end
    return nil
end

local function findSource(list, size, itemName, minSlot)
    for slot = minSlot, size do
        local item = itemAt(list, slot)
        if item and item.name == itemName and (item.count or 0) > 0 then
            return slot
        end
    end
    return nil
end

--- Park every gem into the highest free slots so low slots are clear for the plan.
local function parkGemsHigh(inv, name, size)
    local moved = false
    local guard = 0
    while guard < size * 2 do
        guard = guard + 1
        local list = inv.list() or {}
        local free = findFree(list, size, nil)
        if not free then
            break
        end
        -- Only park gems that sit below the free slot (otherwise already high enough).
        local src = findLowestGem(list, size, free - 1)
        if not src then
            break
        end
        local item = itemAt(list, src)
        if push(inv, name, src, item.count, free) > 0 then
            moved = true
        else
            break
        end
        sleep(0)
    end
    return moved
end

local function placePlan(inv, name, size, plan)
    local moved = false
    for dest = 1, #plan do
        local want = plan[dest]
        local guard = 0
        while guard < 48 do
            guard = guard + 1
            local list = inv.list() or {}
            local cur = itemAt(list, dest)

            if cur and cur.name == want.name and (cur.count or 0) == want.count then
                break
            end

            if cur and cur.name == want.name and (cur.count or 0) > want.count then
                local free = findFree(list, size, dest)
                if not free then
                    return moved, false
                end
                if push(inv, name, dest, cur.count - want.count, free) <= 0 then
                    return moved, false
                end
                moved = true
                sleep(0)
            elseif cur then
                local free = findFree(list, size, dest)
                if not free then
                    return moved, false
                end
                if push(inv, name, dest, cur.count, free) <= 0 then
                    return moved, false
                end
                moved = true
                sleep(0)
            else
                local need = want.count
                local src = findSource(inv.list() or {}, size, want.name, dest + 1)
                if not src then
                    break
                end
                local got = push(inv, name, src, need, dest)
                if got <= 0 then
                    -- Fallback: untarged push then hope it lands / retry targeted later.
                    got = push(inv, name, src, need, nil)
                    if got <= 0 then
                        break
                    end
                end
                moved = true
                sleep(0)
            end
        end
        if dest % 4 == 0 then
            sleep(0)
        end
    end
    return moved, true
end

--- Try to free one slot by merging identical partial stacks.
local function tryFreeSlot(inv, name, size, maxStack)
    local list = inv.list() or {}
    if findFree(list, size, nil) then
        return true
    end
    for a = 1, size do
        list = inv.list() or {}
        local ia = itemAt(list, a)
        if ia and gems.isGem(ia.name) and ia.count < maxStack then
            for b = a + 1, size do
                list = inv.list() or {}
                local ib = itemAt(list, b)
                if ib and ib.name == ia.name then
                    if push(inv, name, b, ib.count, a) > 0 then
                        sleep(0)
                        list = inv.list() or {}
                        if findFree(list, size, nil) then
                            return true
                        end
                        ia = itemAt(list, a)
                        if not ia or ia.count >= maxStack then
                            break
                        end
                    end
                end
            end
        end
        if a % 8 == 0 then
            sleep(0)
        end
    end
    list = inv.list() or {}
    return findFree(list, size, nil) ~= nil
end

function sort.buffer(bufferName, opts)
    opts = opts or {}
    local maxStack = opts.maxStack or 64
    local inv = getInv(bufferName)
    if not inv then
        return false, "no buffer"
    end

    local size = inv.size()
    if not size or size < 1 then
        return false, "bad size"
    end

    local list = inv.list() or {}
    local plan = buildPlan(aggregateGems(list), maxStack)
    if #plan == 0 then
        return false, "empty"
    end
    if #plan > size then
        return false, "plan>slots"
    end
    if layoutMatches(list, plan, size) then
        return false, "ok"
    end

    if not tryFreeSlot(inv, bufferName, size, maxStack) then
        return false, "chest full"
    end

    local movedAny = false
    for _ = 1, 3 do
        list = inv.list() or {}
        plan = buildPlan(aggregateGems(list), maxStack)
        if layoutMatches(list, plan, size) then
            return movedAny, ("sorted %d"):format(#plan)
        end

        if parkGemsHigh(inv, bufferName, size) then
            movedAny = true
        end

        local moved, okSpace = placePlan(inv, bufferName, size, plan)
        if moved then
            movedAny = true
        end
        if not okSpace then
            if not tryFreeSlot(inv, bufferName, size, maxStack) then
                return movedAny, "chest full"
            end
        end

        list = inv.list() or {}
        if layoutMatches(list, plan, size) then
            return true, ("sorted %d"):format(#plan)
        end
        sleep(0)
    end

    list = inv.list() or {}
    plan = buildPlan(aggregateGems(list), maxStack)
    if layoutMatches(list, plan, size) then
        return true, ("sorted %d"):format(#plan)
    end
    if movedAny then
        return true, "sort partial"
    end
    return false, "sort failed"
end

return sort
