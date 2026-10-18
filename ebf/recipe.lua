-- Snapshot / push atomic recipe units from HV buffers into EBF inputs.

local transfer = require("transfer")

local recipe = {}

local function sortKeys(map)
    local keys = {}
    for k in pairs(map) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

local function buildSnapFromMaps(items, fluids)
    local snap = { items = items or {}, fluids = fluids or {}, empty = true }
    for _, c in pairs(snap.items) do
        if c > 0 then
            snap.empty = false
            break
        end
    end
    if snap.empty then
        for _, a in pairs(snap.fluids) do
            if a > 0 then
                snap.empty = false
                break
            end
        end
    end
    return snap
end

--- skipFluids: skip tanks() (faster for dust-only Al runs).
function recipe.inspect(bufferName, skipFluids)
    local empty = buildSnapFromMaps({}, {})
    if not bufferName or not peripheral.isPresent(bufferName) then
        return empty, nil, nil
    end
    local inv = peripheral.wrap(bufferName)
    if not inv or type(inv.list) ~= "function" then
        return empty, nil, nil
    end

    local listed = inv.list() or {}
    local items = {}
    for _, item in pairs(listed) do
        if item and item.name and (item.count or 0) > 0 then
            items[item.name] = (items[item.name] or 0) + (item.count or 0)
        end
    end

    local fluids = {}
    if not skipFluids and type(inv.tanks) == "function" then
        local ok, tanks = pcall(inv.tanks)
        if ok and type(tanks) == "table" then
            for _, t in pairs(tanks) do
                if t and t.name and (t.amount or 0) > 0 then
                    fluids[t.name] = (fluids[t.name] or 0) + (t.amount or 0)
                end
            end
        end
    end

    return buildSnapFromMaps(items, fluids), listed, inv
end

function recipe.snapshot(bufferName)
    return (recipe.inspect(bufferName, false))
end

function recipe.isEmpty(snap)
    return not snap or snap.empty == true
end

function recipe.hasContent(snap)
    return snap and snap.empty == false
end

--- Cheap non-empty check (list + tanks). Used for sticky AE buffer pick.
function recipe.isNonEmpty(bufferName)
    return recipe.hasContent(recipe.snapshot(bufferName))
end

function recipe.label(snap)
    if not snap or snap.empty then
        return "-"
    end
    local items = sortKeys(snap.items)
    if #items > 0 then
        local name = items[1]
        local short = name:match("([^:/]+)$") or name
        if #items > 1 then
            return short .. "+"
        end
        local c = snap.items[name]
        if c and c > 1 then
            return short .. " x" .. tostring(c)
        end
        return short
    end
    local fluids = sortKeys(snap.fluids)
    if #fluids > 0 then
        local name = fluids[1]
        return (name:match("([^:/]+)$") or name) .. " mb"
    end
    return "?"
end

local function countTypes(map)
    local n = 0
    for _ in pairs(map or {}) do
        n = n + 1
    end
    return n
end

--- How many item units to push for one recipe from this snap.
-- Single item-type buffers (Al dust stacks): split by itemsPerRecipe.
-- Multi-item AE dumps: whole buffer = one recipe.
local function planItemWants(snap, itemsPerRecipe)
    itemsPerRecipe = math.max(1, tonumber(itemsPerRecipe) or 1)
    local wants = {}
    local nTypes = countTypes(snap.items)
    if nTypes == 0 then
        return wants, true
    end
    if nTypes == 1 then
        for name, count in pairs(snap.items) do
            local want = math.min(count, itemsPerRecipe)
            if want <= 0 then
                return wants, false
            end
            wants[name] = want
        end
        return wants, true
    end
    -- Multi-item: take everything currently listed (one AE pattern).
    for name, count in pairs(snap.items) do
        wants[name] = count
    end
    return wants, true
end

local function planFluidWants(snap, itemWants, itemsPerRecipe, fluidPerRecipe)
    local wants = {}
    itemsPerRecipe = math.max(1, tonumber(itemsPerRecipe) or 1)
    fluidPerRecipe = tonumber(fluidPerRecipe) or 0

    local nFluids = countTypes(snap.fluids)
    if nFluids == 0 then
        return wants
    end

    if fluidPerRecipe > 0 then
        for name, amount in pairs(snap.fluids) do
            local want = math.min(amount, fluidPerRecipe)
            if want > 0 then
                wants[name] = want
            end
        end
        return wants
    end

    -- Proportional to item fraction when splitting a single-item stack.
    local nItemTypes = countTypes(snap.items)
    if nItemTypes == 1 then
        local totalItems = 0
        local takeItems = 0
        for name, count in pairs(snap.items) do
            totalItems = count
            takeItems = itemWants[name] or 0
        end
        if totalItems > 0 and takeItems > 0 then
            for name, amount in pairs(snap.fluids) do
                local want = math.floor(amount * takeItems / totalItems)
                if want < 1 and amount > 0 and takeItems > 0 then
                    want = 1
                end
                want = math.min(amount, want)
                if want > 0 then
                    wants[name] = want
                end
            end
            return wants
        end
    end

    -- Multi-item / fallback: push all fluid in the buffer with the recipe.
    for name, amount in pairs(snap.fluids) do
        wants[name] = amount
    end
    return wants
end

local function pushWantedItems(inv, listed, inputBus, wants)
    local remaining = {}
    for name, want in pairs(wants) do
        remaining[name] = want
    end
    local movedItems = 0
    local movedItemMap = {}

    for slot, item in pairs(listed or {}) do
        if item and item.name and (item.count or 0) > 0 then
            local left = remaining[item.name]
            if left and left > 0 then
                local want = math.min(item.count, left)
                local got = inv.pushItems(inputBus, slot, want) or 0
                movedItems = movedItems + got
                if got > 0 then
                    movedItemMap[item.name] = (movedItemMap[item.name] or 0) + got
                    remaining[item.name] = left - got
                end
                if got < want then
                    return false, movedItems, movedItemMap, "item stuck: " .. item.name
                end
            end
        end
    end

    for name, left in pairs(remaining) do
        if left > 0 then
            return false, movedItems, movedItemMap, "item short: " .. name
        end
    end
    return true, movedItems, movedItemMap, nil
end

--- Push up to maxUnits recipe units. Single-item stacks = one pushItems.
-- Returns ok, units, movedItems, movedFluids, err, movedSnap
function recipe.pushRecipeUnits(
    bufferName,
    inputBus,
    inputHatch,
    itemsPerRecipe,
    fluidPerRecipe,
    maxUnits,
    skipFluids
)
    maxUnits = math.max(1, math.floor(tonumber(maxUnits) or 1))
    itemsPerRecipe = math.max(1, tonumber(itemsPerRecipe) or 1)
    -- Always read tanks: AE one-recipe buffers hold nitrogen with the dust.
    -- Skipping fluids left N2 behind → buffer never emptied → AE lock stalled.
    local snap, listed, inv = recipe.inspect(bufferName, false)
    if recipe.isEmpty(snap) then
        return false, 0, 0, 0, "empty", nil
    end
    if not inputBus or not peripheral.isPresent(inputBus) then
        return false, 0, 0, 0, "no input bus", nil
    end
    if not inv or type(inv.pushItems) ~= "function" then
        return false, 0, 0, 0, "bad buffer", nil
    end

    local nItemTypes = countTypes(snap.items)
    local nFluids = countTypes(snap.fluids)
    -- Fluid recipes must move as one atomic unit (do not batch dust ahead of N2).
    if nFluids > 0 then
        maxUnits = 1
    end

    local itemWants = {}
    local units = 1

    if nItemTypes == 1 then
        local name, count
        for n, c in pairs(snap.items) do
            name, count = n, c
        end
        units = math.min(maxUnits, math.floor((count or 0) / itemsPerRecipe))
        if units < 1 then
            return false, 0, 0, 0, "empty", nil
        end
        itemWants[name] = units * itemsPerRecipe
    elseif nItemTypes > 1 then
        -- Multi-item AE dump: one whole buffer = one recipe.
        units = 1
        for name, count in pairs(snap.items) do
            itemWants[name] = count
        end
    elseif nFluids == 0 then
        return false, 0, 0, 0, "empty", nil
    end

    local okItems, movedItems, movedItemMap, errItems = pushWantedItems(
        inv,
        listed,
        inputBus,
        itemWants
    )
    if not okItems then
        return false, 0, movedItems, 0, errItems, nil
    end

    -- With maxUnits forced to 1 when fluids exist, take all fluid in the buffer
    -- (AE lock = one full recipe). Otherwise scale by fluid_per_recipe / proportion.
    local fluidWants
    if nFluids > 0 and maxUnits == 1 and (tonumber(fluidPerRecipe) or 0) <= 0 then
        fluidWants = {}
        for name, amount in pairs(snap.fluids) do
            if (amount or 0) > 0 then
                fluidWants[name] = amount
            end
        end
    elseif nItemTypes == 1 and (tonumber(fluidPerRecipe) or 0) > 0 then
        fluidWants = {}
        local per = tonumber(fluidPerRecipe) or 0
        for name, amount in pairs(snap.fluids) do
            local want = math.min(amount, per * units)
            if want > 0 then
                fluidWants[name] = want
            end
        end
    else
        fluidWants = planFluidWants(snap, itemWants, itemsPerRecipe, fluidPerRecipe)
    end

    local movedFluids = 0
    local movedFluidMap = {}
    if countTypes(fluidWants) > 0 then
        if not inputHatch or not peripheral.isPresent(inputHatch) then
            return false, 0, movedItems, 0, "no input hatch", nil
        end
        for name, want in pairs(fluidWants) do
            local got = transfer.fluid(bufferName, inputHatch, name, want) or 0
            movedFluids = movedFluids + got
            if got > 0 then
                movedFluidMap[name] = (movedFluidMap[name] or 0) + got
            end
            if got < want then
                return false, 0, movedItems, movedFluids, "fluid stuck: " .. name, nil
            end
        end
    end

    return true, units, movedItems, movedFluids, nil, buildSnapFromMaps(movedItemMap, movedFluidMap)
end

--- Push exactly one recipe unit from buffer → inputs.
-- Returns ok, movedItems, movedFluids, err, movedSnap
function recipe.pushOneRecipe(bufferName, inputBus, inputHatch, itemsPerRecipe, fluidPerRecipe)
    local ok, _, mi, mf, err, snap = recipe.pushRecipeUnits(
        bufferName,
        inputBus,
        inputHatch,
        itemsPerRecipe,
        fluidPerRecipe,
        1,
        false
    )
    return ok, mi, mf, err, snap
end

--- Push everything currently in the buffer (legacy / multi-item AE dump).
function recipe.pushAtomic(bufferName, inputBus, inputHatch, _snap)
    local snap, listed, inv = recipe.inspect(bufferName)
    if recipe.isEmpty(snap) then
        return false, 0, 0, "empty", nil
    end
    if not inputBus or not peripheral.isPresent(inputBus) then
        return false, 0, 0, "no input bus", nil
    end
    if not inv or type(inv.pushItems) ~= "function" then
        return false, 0, 0, "bad buffer", nil
    end

    local wants = {}
    for name, count in pairs(snap.items) do
        wants[name] = count
    end
    local okItems, movedItems, movedItemMap, errItems = pushWantedItems(
        inv,
        listed,
        inputBus,
        wants
    )
    if not okItems then
        return false, movedItems, 0, errItems, nil
    end

    local movedFluids = 0
    local movedFluidMap = {}
    if countTypes(snap.fluids) > 0 then
        if not inputHatch or not peripheral.isPresent(inputHatch) then
            return false, movedItems, 0, "no input hatch", nil
        end
        for name, want in pairs(snap.fluids) do
            local got = transfer.fluid(bufferName, inputHatch, name, want) or 0
            movedFluids = movedFluids + got
            if got > 0 then
                movedFluidMap[name] = (movedFluidMap[name] or 0) + got
            end
            if got < want then
                return false, movedItems, movedFluids, "fluid stuck: " .. name, nil
            end
        end
    end

    return true, movedItems, movedFluids, nil, buildSnapFromMaps(movedItemMap, movedFluidMap)
end

-- Kept for older call sites / tests.
function recipe.pushInspected(bufferName, inputBus, inputHatch, snap, listed, inv)
    if recipe.isEmpty(snap) then
        return false, 0, 0, "empty", nil
    end
    return recipe.pushAtomic(bufferName, inputBus, inputHatch, snap)
end

function recipe.isNonEmpty(bufferName)
    return recipe.hasContent(recipe.snapshot(bufferName))
end

function recipe.same(a, b)
    if not a or not b then
        return false
    end
    if a.empty and b.empty then
        return true
    end
    if a.empty ~= b.empty then
        return false
    end
    local function mapsEqual(x, y)
        for k, v in pairs(x) do
            if (y[k] or 0) ~= v then
                return false
            end
        end
        for k, v in pairs(y) do
            if (x[k] or 0) ~= v then
                return false
            end
        end
        return true
    end
    return mapsEqual(a.items, b.items) and mapsEqual(a.fluids, b.fluids)
end

return recipe
