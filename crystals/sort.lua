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

local function aggregateGems(list)
    local byName = {}
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
                        count = 0,
                    }
                    byName[item.name] = cur
                end
                cur.count = cur.count + (item.count or 0)
            end
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

--- Per material, tiers 1..5: even stacks, then a single leftover.
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

local function itemAt(list, slot)
    return list and list[slot] or nil
end

--- True only if slots 1..#plan match exactly and no gems sit past the plan.
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

--- Source of itemName in slots after `afterSlot` (do not steal finalized low slots).
local function findSourceAfter(list, size, itemName, afterSlot)
    for slot = afterSlot + 1, size do
        local item = itemAt(list, slot)
        if item and item.name == itemName and (item.count or 0) > 0 then
            return slot
        end
    end
    return nil
end

local function push(inv, name, fromSlot, limit, toSlot)
    local moved = inv.pushItems(name, fromSlot, limit, toSlot)
    return tonumber(moved) or 0
end

--- Move whatever is in `from` into any free slot (prefer high). Returns dest or nil.
local function evacuate(inv, name, list, size, from)
    local item = itemAt(list, from)
    if not item then
        return true
    end
    local free = findFree(list, size, from)
    if not free then
        return false
    end
    return push(inv, name, from, item.count, free) > 0
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

    -- Need at least one empty slot to reshuffle; try merge identical gems first.
    if not findFree(list, size, nil) then
        for a = 1, size do
            list = inv.list() or {}
            local ia = itemAt(list, a)
            if ia and gems.isGem(ia.name) and ia.count < maxStack then
                for b = a + 1, size do
                    list = inv.list() or {}
                    local ib = itemAt(list, b)
                    if ib and ib.name == ia.name then
                        push(inv, bufferName, b, ib.count, a)
                        sleep(0)
                        break
                    end
                end
            end
        end
        list = inv.list() or {}
        if not findFree(list, size, nil) then
            return false, "need 1 free"
        end
    end

    local movedAny = false

    for dest = 1, #plan do
        local want = plan[dest]
        local guard = 0
        while guard < 64 do
            guard = guard + 1
            list = inv.list() or {}
            local cur = itemAt(list, dest)

            if cur and cur.name == want.name and (cur.count or 0) == want.count then
                break -- slot done
            end

            -- Excess of the right item → split out.
            if cur and cur.name == want.name and (cur.count or 0) > want.count then
                local free = findFree(list, size, dest)
                if not free then
                    return movedAny, "need 1 free"
                end
                if push(inv, bufferName, dest, cur.count - want.count, free) > 0 then
                    movedAny = true
                else
                    break
                end
                sleep(0)
            elseif cur and (not gems.isGem(cur.name) or cur.name ~= want.name) then
                -- Wrong occupant → park high.
                if not evacuate(inv, bufferName, list, size, dest) then
                    return movedAny, "need 1 free"
                end
                movedAny = true
                sleep(0)
            else
                -- Empty or short on the right item → pull from later slots.
                list = inv.list() or {}
                cur = itemAt(list, dest)
                local have = (cur and cur.name == want.name) and (cur.count or 0) or 0
                local need = want.count - have
                if need <= 0 then
                    break
                end
                local src = findSourceAfter(inv.list() or {}, size, want.name, dest)
                if not src then
                    -- Should not happen if plan matches totals; stop this slot.
                    break
                end
                local got = push(inv, bufferName, src, need, dest)
                if got <= 0 then
                    break
                end
                movedAny = true
                sleep(0)
            end
        end

        if dest % 3 == 0 then
            sleep(0)
        end
    end

    list = inv.list() or {}
    if layoutMatches(list, plan, size) then
        return true, ("sorted %d"):format(#plan)
    end
    if movedAny then
        return true, "sort partial"
    end
    return false, "sort failed"
end

return sort
