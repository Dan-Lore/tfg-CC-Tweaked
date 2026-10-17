-- One hatch index = one pack = furnaces NL + NR (shared 4 hatches).
-- Sticky inflight; concentrate fill; reconcile against input bus when drains miss.

local transfer = require("transfer")
local recipe = require("recipe")

local furnace = {}

local function isHotIngot(itemName)
    if not itemName then
        return false
    end
    local short = itemName:match("([^:/]+)$") or itemName
    if short:find("^hot_") == nil then
        return false
    end
    return short:find("ingot") ~= nil
end

local function invItemCount(name)
    if not name or not peripheral.isPresent(name) then
        return 0
    end
    local inv = peripheral.wrap(name)
    if not inv or type(inv.list) ~= "function" then
        return 0
    end
    local listed = inv.list()
    if not listed then
        return 0
    end
    local n = 0
    for _, item in pairs(listed) do
        if item and (item.count or 0) > 0 then
            n = n + (item.count or 0)
        end
    end
    return n
end

local function nowSeconds()
    if os.epoch then
        return os.epoch("utc") / 1000
    end
    return os.clock()
end

function furnace.newState(desc)
    return {
        index = desc.index,
        pair = desc.pair or ((desc.index or 0) + 1),
        id = desc.id,
        label = desc.label or ("#" .. tostring(desc.index)),
        paired = 2,
        inputBus = desc.inputBus,
        inputHatch = desc.inputHatch,
        outputBus = desc.outputBus,
        outputHatch = desc.outputHatch,
        inflight = 0,
        fed = 0,
        drained = 0,
        lastRecipe = nil,
        lastError = nil,
        lastFeedAt = nil,
        lastDrainAt = nil,
        wrapOutBus = nil,
        wrapOutHatch = nil,
    }
end

function furnace.mergeStates(oldMap, furnaceList)
    oldMap = oldMap or {}
    local newMap = {}
    for i = 1, #furnaceList do
        local desc = furnaceList[i]
        local prev = oldMap[desc.index]
        local st = furnace.newState(desc)
        if prev then
            st.inflight = math.max(0, tonumber(prev.inflight) or 0)
            st.fed = tonumber(prev.fed) or 0
            st.drained = tonumber(prev.drained) or 0
            st.lastRecipe = prev.lastRecipe
            st.lastError = prev.lastError
            st.lastFeedAt = prev.lastFeedAt
            st.lastDrainAt = prev.lastDrainAt
        end
        newMap[desc.index] = st
    end
    return newMap
end

function furnace.listByIndex(stateMap)
    local list = {}
    for _, st in pairs(stateMap or {}) do
        list[#list + 1] = st
    end
    table.sort(list, function(a, b)
        return (a.index or 0) < (b.index or 0)
    end)
    return list
end

--- Fill an open pack before opening the next (L+R share one bus).
-- Prefer highest inflight under maxInflight (concentrate), then lowest index.
-- Returns st, rrCursor (cursor unused; kept for call-site compat)
function furnace.pickTarget(stateMap, maxInflight, packList, rrCursor)
    maxInflight = tonumber(maxInflight) or 6
    packList = packList or furnace.listByIndex(stateMap)
    local n = #packList
    if n == 0 then
        return nil, rrCursor or 1
    end

    local best = nil
    local bestInf = -1
    for i = 1, n do
        local st = packList[i]
        local inf = st.inflight or 0
        if inf < maxInflight then
            if not best
                or inf > bestInf
                or (inf == bestInf and (st.index or 0) < (best.index or 0))
            then
                best = st
                bestInf = inf
            end
        end
    end
    return best, rrCursor or 1
end

local function drainInv(fromName, hotSink, aeSink, cached)
    if not fromName then
        return 0, 0, cached
    end
    local inv = cached
    if not inv then
        if not peripheral.isPresent(fromName) then
            return 0, 0, nil
        end
        inv = peripheral.wrap(fromName)
    end
    if not inv or type(inv.list) ~= "function" or type(inv.pushItems) ~= "function" then
        return 0, 0, nil
    end
    local listed = inv.list()
    if not listed then
        return 0, 0, inv
    end
    local hotMoved, otherMoved = 0, 0
    for slot, item in pairs(listed) do
        if item and item.name and (item.count or 0) > 0 then
            local dest = isHotIngot(item.name) and hotSink or aeSink
            if dest then
                local moved = inv.pushItems(dest, slot, item.count) or 0
                if isHotIngot(item.name) then
                    hotMoved = hotMoved + moved
                else
                    otherMoved = otherMoved + moved
                end
            end
        end
    end
    return hotMoved, otherMoved, inv
end

local function drainFluids(fromName, aeSink, cached)
    if not fromName or not aeSink then
        return 0, cached
    end
    local src = cached
    if not src then
        if not peripheral.isPresent(fromName) then
            return 0, nil
        end
        src = peripheral.wrap(fromName)
    end
    if not src or type(src.tanks) ~= "function" or type(src.pushFluid) ~= "function" then
        return 0, nil
    end
    local ok, tanks = pcall(src.tanks)
    if not ok or type(tanks) ~= "table" then
        return 0, src
    end
    local moved = 0
    for _, t in pairs(tanks) do
        if t and t.name and (t.amount or 0) > 0 then
            local got = src.pushFluid(aeSink, t.amount, t.name)
            moved = moved + (tonumber(got) or 0)
        end
    end
    return moved, src
end

function furnace.estimateDone(hotMoved, otherMoved, fluidMoved, inflight, hotPerRecipe)
    inflight = tonumber(inflight) or 0
    if inflight <= 0 then
        return 0
    end
    hotPerRecipe = math.max(1, tonumber(hotPerRecipe) or 1)
    hotMoved = tonumber(hotMoved) or 0
    otherMoved = tonumber(otherMoved) or 0
    fluidMoved = tonumber(fluidMoved) or 0
    local done = 0
    if hotMoved > 0 then
        done = math.floor(hotMoved / hotPerRecipe)
        if done < 1 then
            done = 1
        end
    elseif otherMoved > 0 or fluidMoved > 0 then
        -- Byproduct-only drain: at least one finish; do not trust stack size.
        done = 1
    end
    if done > inflight then
        done = inflight
    end
    return done
end

--- Items sitting in the shared input bus, as recipe-sized units.
function furnace.bufferedUnits(st, itemsPerRecipe)
    if not st then
        return 0
    end
    itemsPerRecipe = math.max(1, tonumber(itemsPerRecipe) or 1)
    local n = invItemCount(st.inputBus)
    return math.floor(n / itemsPerRecipe)
end

local function outputItemCount(st)
    if not st then
        return 0
    end
    return invItemCount(st.outputBus) + invItemCount(st.outputHatch)
end

--- Cap sticky inflight used for feed limiting (UI uses bufferedUnits separately).
-- Empty input+output → drop sticky (missed drains). Brief craft_grace after a
-- feed keeps up to `paired` so L+R mid-craft does not get immediately re-flooded.
-- optional `now` (seconds) for tests.
function furnace.reconcile(st, itemsPerRecipe, craftGrace, now)
    if not st then
        return 0
    end
    local paired = math.max(1, tonumber(st.paired) or 2)
    craftGrace = tonumber(craftGrace) or 8
    now = tonumber(now) or nowSeconds()
    local buffered = furnace.bufferedUnits(st, itemsPerRecipe)
    local outN = outputItemCount(st)
    local credit
    if buffered > 0 then
        -- Only what still sits in the bus (no +paired bonus — that stuck UI at 3/6).
        credit = buffered
    elseif outN > 0 then
        credit = math.max(tonumber(st.inflight) or 0, 1)
    else
        local feedAt = tonumber(st.lastFeedAt)
        if feedAt and (now - feedAt) < craftGrace then
            credit = math.min(tonumber(st.inflight) or 0, paired)
        else
            credit = 0
        end
    end
    local inf = tonumber(st.inflight) or 0
    if inf <= credit then
        return 0
    end
    local drop = inf - credit
    st.inflight = credit
    st.drained = (st.drained or 0) + drop
    return drop
end

function furnace.drain(st, hotSink, aeSink, hotPerRecipe)
    if not st then
        return 0, 0, 0, 0
    end
    local hot1, other1, wrapBus = drainInv(st.outputBus, hotSink, aeSink, st.wrapOutBus)
    st.wrapOutBus = wrapBus
    local hot2, other2 = 0, 0
    local fluidMoved = 0
    if st.outputHatch then
        hot2, other2, st.wrapOutHatch = drainInv(
            st.outputHatch,
            hotSink,
            aeSink,
            st.wrapOutHatch
        )
        fluidMoved, st.wrapOutHatch = drainFluids(st.outputHatch, aeSink, st.wrapOutHatch)
    end
    local hotMoved = hot1 + hot2
    local otherMoved = other1 + other2
    local done = furnace.estimateDone(
        hotMoved,
        otherMoved,
        fluidMoved,
        st.inflight,
        hotPerRecipe
    )
    if done > 0 then
        st.inflight = (st.inflight or 0) - done
        st.drained = (st.drained or 0) + done
        st.lastDrainAt = nowSeconds()
    end
    return hotMoved, otherMoved, fluidMoved, done
end

function furnace.feedOne(stateMap, bufferName, maxInflight, _snap)
    local packList = furnace.listByIndex(stateMap)
    local st = furnace.pickTarget(stateMap, maxInflight, packList, 1)
    if not st then
        return nil, "all full"
    end
    local ok, _, _, err, movedSnap = recipe.pushOneRecipe(
        bufferName,
        st.inputBus,
        st.inputHatch,
        1,
        0
    )
    if not ok then
        st.lastError = err
        return nil, err or "push failed"
    end
    st.inflight = (st.inflight or 0) + 1
    st.fed = (st.fed or 0) + 1
    st.lastFeedAt = nowSeconds()
    st.lastRecipe = recipe.label(movedSnap)
    st.lastError = nil
    return st, nil
end

furnace.isHotIngot = isHotIngot
furnace._invItemCount = invItemCount
furnace._nowSeconds = nowSeconds

return furnace
