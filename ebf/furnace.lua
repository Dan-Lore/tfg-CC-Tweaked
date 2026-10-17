-- One hatch index = one pack = furnaces NL + NR (shared 4 hatches).
-- Load-balance across packs via sticky inflight + round-robin.

local transfer = require("transfer")
local recipe = require("recipe")

local furnace = {}

local function isHotIngot(itemName)
    if not itemName then
        return false
    end
    local short = itemName:match("([^:/]+)$") or itemName
    return short:find("^hot_.*_ingot$") ~= nil or short:find("^hot_.*ingot$") ~= nil
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

--- Least-loaded pack under maxInflight; round-robin among ties.
-- Returns st, newRrCursor
function furnace.pickTarget(stateMap, maxInflight, packList, rrCursor)
    maxInflight = tonumber(maxInflight) or 6
    packList = packList or furnace.listByIndex(stateMap)
    local n = #packList
    if n == 0 then
        return nil, rrCursor or 1
    end
    rrCursor = tonumber(rrCursor) or 1
    if rrCursor < 1 or rrCursor > n then
        rrCursor = 1
    end

    local bestLoad = nil
    for i = 1, n do
        local inf = packList[i].inflight or 0
        if inf < maxInflight then
            if not bestLoad or inf < bestLoad then
                bestLoad = inf
            end
        end
    end
    if bestLoad == nil then
        return nil, rrCursor
    end

    for offset = 0, n - 1 do
        local i = ((rrCursor - 1 + offset) % n) + 1
        local st = packList[i]
        if (st.inflight or 0) == bestLoad then
            return st, (i % n) + 1
        end
    end
    return nil, rrCursor
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
        done = 1
    end
    if done > inflight then
        done = inflight
    end
    return done
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
    st.lastRecipe = recipe.label(movedSnap)
    st.lastError = nil
    return st, nil
end

furnace.isHotIngot = isHotIngot

return furnace
