-- Autonomous greenhouse output sorter.
-- Requires on this computer: storage.cfg, recipes.cfg, and the lua modules below.
-- Works on any computer attached to the same peripheral network.
--
-- Bundle:  python tools/bundle_project.py craft greenhouse_clean
-- Deploy:  dist/greenhouse_clean.lua + recipes.cfg + storage.cfg

package.path = package.path
    .. ";/shared/?.lua;shared/?.lua;/craft/?.lua;craft/?.lua"

local transfer = require("transfer")
local recipes = require("recipes")
local storage = require("storage")
local peripherals = require("peripherals")
local util = require("util")

local FLORA_ITEM = "tfg:flora_pellets"

--- Seed/plant chest for this item, if it matches any grow recipe seed mapping.
local function seedDestForItem(store, growRecipes, itemName)
    for i = 1, #growRecipes do
        local recipe = growRecipes[i]
        local primary = recipes.primaryOutput(recipe)
        local crop = primary and primary.name
        local seedItem = crop and store.seedForCrop(crop)
        if seedItem and seedItem == itemName then
            return store.seedDest(recipe.circuit or 0)
        end
    end
    return nil
end

local function destForItem(store, growRecipes, itemName)
    if itemName == FLORA_ITEM then
        return store.flora()
    end

    local seedDest = seedDestForItem(store, growRecipes, itemName)
    if seedDest then
        return seedDest
    end

    return store.destFor(itemName)
end

local function moveWithOverflow(store, from, dest, itemName)
    local before = transfer.countItem(from, itemName)
    if before <= 0 then
        return 0
    end
    if not dest or not peripheral.isPresent(dest) or from == dest then
        return 0
    end

    local moved = transfer(from, dest, itemName, -1)
    local left = transfer.countItem(from, itemName)
    local overflow = store.overflow()

    if left > 0 and overflow and dest ~= overflow and peripheral.isPresent(overflow) then
        local buffered = transfer(from, overflow, itemName, -1)
        if buffered > 0 then
            print(("overflow: %s x%s -> %s (dest full: %s)"):format(
                util.short(itemName), tostring(buffered), util.short(overflow), util.short(dest)
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
            -- Routed items (basil leaves) stay in overflow — that IS their home.
            if store.routes[name] then
                -- keep
            else
                local dest = destForItem(store, growRecipes, name)
                if dest and dest ~= overflow and peripheral.isPresent(dest) then
                    local n = transfer(overflow, dest, name, -1)
                    if n > 0 then
                        print(("drain: %s x%s -> %s"):format(
                            util.short(name), tostring(n), util.short(dest)
                        ))
                    end
                end
            end
        end
    end
end

local function cleanGreenhouse(store, growRecipes, recipe)
    -- Products leave via GT output bus, not the greenhouse controller inventory.
    local source = store.outputBus(recipe.circuit or 0)
    if not peripheral.isPresent(source) then
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
            local dest = destForItem(store, growRecipes, name)
            if dest and peripheral.isPresent(dest) then
                moveWithOverflow(store, source, dest, name)
            elseif dest then
                print(("missing dest %s for %s"):format(tostring(dest), util.short(name)))
            end
        end
    end
end

local function main()
    local greenhouse = require("greenhouse")
    local store = storage.load()
    local all = recipes.load()
    local growRecipes = recipes.byFlag(all, "grow")
    local interval = store.getNumber("clean_interval", 2)

    greenhouse.disableAll(peripherals.resolveMachine, growRecipes)

    print(("greenhouse_clean: %s grow recipes, interval %ss (GH off)"):format(
        tostring(#growRecipes), tostring(interval)
    ))

    while true do
        greenhouse.disableAll(peripherals.resolveMachine, growRecipes)
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
