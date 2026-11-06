-- One hatch index = one pack = furnaces NL + NR (shared 4 hatches).
-- Sticky inflight; sibling debt (owed) so a finished craft does not look like
-- an unfed L or R; reconcile against input bus when drains miss.

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

local function isRealItemName(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    if name == "minecraft:air" or name == "minecraft:empty" then
        return false
    end
    return name:find(":", 1, true) ~= nil
end

--- GT puts the integrated/programmable circuit in the bus inventory; ignore it.
local function isConfigCircuit(name)
    if not isRealItemName(name) then
        return false
    end
    local short = name:match("([^:/]+)$") or name
    short = short:lower()
    if short:find("circuit", 1, true) then
        return true
    end
    if short:find("programmable", 1, true) then
        return true
    end
    return false
end

local function isCargoItem(name)
    return isRealItemName(name) and not isConfigCircuit(name)
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
        if item then
            local count = tonumber(item.count) or 0
            if count > 0 and isCargoItem(item.name) then
                n = n + count
            end
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
        -- nil until the first noteFeed. A number is sibling recipes still due
        -- (1 = L was fed, R was not). Completions do not raise this.
        owed = nil,
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
            if prev.owed ~= nil then
                st.owed = math.max(0, tonumber(prev.owed) or 0)
            end
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

--- Sibling still due. Once noteFeed has run, `owed` is the source of truth:
-- a craft finishing drops inflight but must not jump the queue ahead of packs
-- that have never been opened. Missing `owed` keeps the inflight 1→2 heuristic.
local function owesSibling(st, inf, paired)
    if st.owed ~= nil then
        return (tonumber(st.owed) or 0) > 0
    end
    local p = math.max(1, tonumber(st.paired) or paired)
    return inf > 0 and inf < p
end

--- Record a successful push. Call after inflight has already been increased.
-- The first recipe of an idle pack owes (paired-1) siblings. Paying that down
-- does not start a new debt. Top-ups after the pair was satisfied stay at 0,
-- even if a completion has since dropped inflight below `paired`.
function furnace.noteFeed(st, units)
    if not st then
        return 0
    end
    units = math.max(0, math.floor(tonumber(units) or 0))
    local p = math.max(1, tonumber(st.paired) or 2)
    local inf = tonumber(st.inflight) or 0
    local before = inf - units
    if before < 0 then
        before = 0
    end
    local owed = st.owed
    if owed == nil then
        owed = 0
    else
        owed = math.max(0, tonumber(owed) or 0)
    end
    if units == 0 then
        st.owed = owed
        return owed
    end
    if owed > 0 then
        owed = owed - units
        if owed < 0 then
            owed = 0
        end
    elseif before == 0 then
        local rem = units % p
        owed = (rem == 0) and 0 or (p - rem)
    end
    st.owed = owed
    return owed
end

--- One hatch pack = L+R. Pick order:
-- 1) packs that still owe the sibling furnace
-- 2) empty packs (bring another L+R pair online)
-- 3) packs under max (buffer)
-- Within a tier: least load, then round-robin from rrCursor.
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

    local function pickInTier(pred)
        local bestLoad = nil
        for i = 1, n do
            local st = packList[i]
            local inf = st.inflight or 0
            if inf < maxInflight and pred(st, inf) then
                if not bestLoad or inf < bestLoad then
                    bestLoad = inf
                end
            end
        end
        if bestLoad == nil then
            return nil
        end
        for offset = 0, n - 1 do
            local i = ((rrCursor - 1 + offset) % n) + 1
            local st = packList[i]
            local inf = st.inflight or 0
            if inf == bestLoad and inf < maxInflight and pred(st, inf) then
                return st, (i % n) + 1
            end
        end
        return nil
    end

    local paired = 2
    local st, nextRr = pickInTier(function(s, inf)
        return owesSibling(s, inf, paired)
    end)
    if st then
        return st, nextRr
    end

    st, nextRr = pickInTier(function(_, inf)
        return inf == 0
    end)
    if st then
        return st, nextRr
    end

    st, nextRr = pickInTier(function(_, inf)
        return inf >= 0
    end)
    if st then
        return st, nextRr
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

local function invHasItems(name)
    return invItemCount(name) > 0
end

local function invHasFluid(name)
    if not name or not peripheral.isPresent(name) then
        return false
    end
    local inv = peripheral.wrap(name)
    if not inv or type(inv.tanks) ~= "function" then
        return false
    end
    local ok, tanks = pcall(inv.tanks)
    if not ok or type(tanks) ~= "table" then
        return false
    end
    for _, t in pairs(tanks) do
        if t then
            local amt = tonumber(t.amount) or 0
            local cname = t.name
            if amt > 0 and isRealItemName(cname) then
                return true
            end
        end
    end
    return false
end

local function invHasContent(name)
    return invHasItems(name) or invHasFluid(name)
end

local function outputItemCount(st)
    if not st then
        return 0
    end
    return invItemCount(st.outputBus) + invItemCount(st.outputHatch)
end

local function hatchPresent(name)
    return name and peripheral.isPresent(name)
end

--- Complete hatch set: item+fluid in and out (all present on the network).
function furnace.isCompletePack(st)
    return st
        and hatchPresent(st.inputBus)
        and hatchPresent(st.inputHatch)
        and hatchPresent(st.outputBus)
        and hatchPresent(st.outputHatch)
end

--- empty | busy | warn_* | err_no_*
-- Missing hatch → err_no_*; content mismatch → warn_*; else empty/busy.
function furnace.packHatchStatus(st)
    if not st then
        return "empty"
    end

    -- Structural errors first (why packs count < list length).
    if not hatchPresent(st.inputBus) then
        return "err_no_item_in"
    end
    if not hatchPresent(st.inputHatch) then
        return "err_no_fluid_in"
    end
    if not hatchPresent(st.outputBus) then
        return "err_no_item_out"
    end
    if not hatchPresent(st.outputHatch) then
        return "err_no_fluid_out"
    end

    local hasItems = invHasItems(st.inputBus)
    local hasFluid = invHasFluid(st.inputHatch)
    if hasItems and not hasFluid then
        return "warn_item"
    end
    if hasFluid and not hasItems then
        return "warn_fluid"
    end
    if hasItems and hasFluid then
        return "busy"
    end
    if invHasItems(st.outputBus) or invHasContent(st.outputHatch) then
        return "busy"
    end
    return "empty"
end

--- Hot-sink fill 0..100. GT hot ingots stack to 16 (not 64).
-- Uses item maxCount when available; default stack 16 for empty slots.
function furnace.hotFillPercent(hotSink)
    if not hotSink or not peripheral.isPresent(hotSink) then
        return nil
    end
    local inv = peripheral.wrap(hotSink)
    if not inv or type(inv.list) ~= "function" then
        return nil
    end
    local size = 0
    if type(inv.size) == "function" then
        size = tonumber(inv.size()) or 0
    end
    local listed = inv.list() or {}
    local total = 0
    local stackMax = 16
    for slot, it in pairs(listed) do
        if it then
            local count = tonumber(it.count) or 0
            if count > 0 then
                total = total + count
                if type(inv.getItemDetail) == "function" then
                    local ok, detail = pcall(inv.getItemDetail, slot)
                    if ok and detail then
                        local m = tonumber(detail.maxCount)
                            or tonumber(detail.maxStackSize)
                        if m and m > 0 then
                            stackMax = m
                        end
                    end
                end
            end
        end
    end
    if size <= 0 then
        return total > 0 and 100 or 0
    end
    local cap = size * stackMax
    if cap <= 0 then
        return 0
    end
    local pct = math.floor((100 * total) / cap + 0.5)
    if pct > 100 then
        pct = 100
    end
    return pct
end

furnace.invHasContent = invHasContent
furnace.invHasItems = invHasItems
furnace.invHasFluid = invHasFluid

--- Cap sticky inflight used for feed limiting (UI uses bufferedUnits separately).
-- While craft_grace after last feed: do NOT touch sticky (drain alone decrements).
-- Early clear was zeroing packs mid-smelt → next wave fed 1/pack and idled L or R.
-- After grace with empty I/O: snap to bus count (usually 0).
-- optional `now` (seconds) for tests.
function furnace.reconcile(st, itemsPerRecipe, craftGrace, now)
    if not st then
        return 0
    end
    craftGrace = tonumber(craftGrace) or 90
    now = tonumber(now) or nowSeconds()
    local feedAt = tonumber(st.lastFeedAt)
    if feedAt and (now - feedAt) < craftGrace then
        return 0
    end

    local buffered = furnace.bufferedUnits(st, itemsPerRecipe)
    local outN = outputItemCount(st)
    local credit = buffered
    if outN > 0 then
        credit = math.max(buffered, 1)
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
    furnace.noteFeed(st, 1)
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
