-- Autonomous greenhouse output sorter.
-- Requires on this computer: storage.cfg, recipes.cfg, and the lua modules below.
-- Works on any computer attached to the same peripheral network.

local transfer = require("transfer")
local recipes = require("recipes")
local storage = require("storage")
local peripherals = require("peripherals")

local FLORA_ITEM = "tfg:flora_pellets"

local function short(id)
    return (id and id:match("([^/]+)$")) or tostring(id)
end

local function countItem(invName, itemName)
    local inv = peripheral.wrap(invName)
    if not inv or not inv.list then
        return 0
    end
    local total = 0
    for _, item in pairs(inv.list()) do
        if item.name == itemName then
            total = total + item.count
        end
    end
    return total
end

local function moveAll(from, to, itemName)
    if not from or not to or not peripheral.isPresent(from) or not peripheral.isPresent(to) then
        return 0
    end
    if from == to then
        return 0
    end
    return transfer(from, to, itemName, -1)
end

--- Seed/plant chest for this item, if it matches any grow recipe seed mapping.
local function seedDestForItem(store, growRecipes, itemName)
    for i = 1, #growRecipes do
        local recipe = growRecipes[i]
        local crop = recipe.outputs[1] and recipe.outputs[1].name
        local seedItem = crop and store.seedForCrop(crop)
        if seedItem and seedItem == itemName then
            return store.seedDest(recipe.circuit or 0)
        end
    end
    return nil
end

local function destForItem(store, growRecipes, recipe, itemName)
    if itemName == FLORA_ITEM then
        return store.flora()
    end

    local seedDest = seedDestForItem(store, growRecipes, itemName)
    if seedDest then
        return seedDest
    end

    if store.routes[itemName] then
        return store.destFor(itemName)
    end

    -- Primary crop of this greenhouse → destFor (usually main)
    for i = 1, #recipe.outputs do
        local out = recipe.outputs[i]
        if not out.fluid and out.name == itemName then
            return store.destFor(itemName)
        end
    end

    return store.destFor(itemName)
end

local function moveWithOverflow(store, from, dest, itemName)
    local before = countItem(from, itemName)
    if before <= 0 then
        return 0
    end

    local moved = moveAll(from, dest, itemName)
    local left = countItem(from, itemName)
    local overflow = store.overflow()

    if left > 0 and overflow and dest ~= overflow and peripheral.isPresent(overflow) then
        local buffered = moveAll(from, overflow, itemName)
        if buffered > 0 then
            print(("overflow: %s x%s -> %s (dest full: %s)"):format(
                short(itemName), tostring(buffered), short(overflow), short(dest)
            ))
        end
        moved = moved + buffered
    end

    return moved
end

local function drainOverflow(store, growRecipes)
    local overflow = store.overflow()
    if not overflow or not peripheral.isPresent(overflow) then
        return
    end

    local inv = peripheral.wrap(overflow)
    if not inv or not inv.list then
        return
    end

    local seen = {}
    for _, item in pairs(inv.list()) do
        local name = item.name
        if not seen[name] then
            seen[name] = true
            -- Use first grow recipe as context for crop dest; seedDestForItem scans all.
            local recipe = growRecipes[1]
            local dest = destForItem(store, growRecipes, recipe or { outputs = {} }, name)
            -- Routed items (basil leaves) stay in overflow — that IS their home.
            if store.routes[name] then
                dest = nil
            end
            if dest and dest ~= overflow and peripheral.isPresent(dest) then
                local n = moveAll(overflow, dest, name)
                if n > 0 then
                    print(("drain: %s x%s -> %s"):format(short(name), tostring(n), short(dest)))
                end
            end
        end
    end
end

local function cleanGreenhouse(store, growRecipes, recipe)
    -- Products leave via GT output bus, not the greenhouse controller inventory.
    local source = store.outputBus(recipe.circuit or 0)
    if not peripheral.isPresent(source) then
        -- Fallback: greenhouse peripheral itself (older setups)
        source = peripherals.resolveMachine(recipe)
    end
    if not source then
        print(("no output bus/greenhouse for %s"):format(recipe.machine))
        return
    end

    local inv = peripheral.wrap(source)
    if not inv or not inv.list then
        return
    end

    local seen = {}
    for _, item in pairs(inv.list()) do
        local name = item.name
        if not seen[name] then
            seen[name] = true
            local dest = destForItem(store, growRecipes, recipe, name)
            if dest and peripheral.isPresent(dest) then
                moveWithOverflow(store, source, dest, name)
            elseif dest then
                print(("missing dest %s for %s"):format(tostring(dest), short(name)))
            end
        end
    end
end

local function main()
    local store = storage.load()
    local all = recipes.load()
    local growRecipes = recipes.byFlag(all, "grow")
    local interval = store.getNumber("clean_interval", 2)

    print(("greenhouse_clean: %s grow recipes, interval %ss"):format(
        tostring(#growRecipes), tostring(interval)
    ))

    while true do
        drainOverflow(store, growRecipes)
        for i = 1, #growRecipes do
            local ok, err = pcall(cleanGreenhouse, store, growRecipes, growRecipes[i])
            if not ok then
                print("clean error: " .. tostring(err))
            end
        end
        sleep(interval)
    end
end

main()
