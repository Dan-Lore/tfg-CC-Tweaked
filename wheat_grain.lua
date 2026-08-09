-- Autonomous wheat → wheat_grain miller for bg / dedicated computer.
-- Grain lasts longer than raw wheat; keeps processor_30 busy when craft UI is idle.
--
-- Requires on this computer: storage.cfg, recipes.cfg, and craft modules.
-- Shares machine_lock with craft_ui if both run on the same multishell computer.
--
-- storage.cfg optional keys:
--   mill_interval | 5     -- seconds between idle polls
--   mill_batch    | 32    -- max recipe sets per craft.run

local craft = require("craft")
local storage = require("storage")
local recipes = require("recipes")
local craft_stock = require("craft_stock")
local machine_lock = require("machine_lock")
local util = require("util")

local WHEAT = "tfc:food/wheat"
local GRAIN = "tfc:food/wheat_grain"

local function recipeIsWheatToGrain(recipe)
    if not recipe or recipe.flag == "grow" then
        return false
    end
    local hasWheat, hasGrain = false, false
    for i = 1, #recipe.inputs do
        if recipe.inputs[i].name == WHEAT and not recipe.inputs[i].fluid then
            hasWheat = true
        end
    end
    for i = 1, #recipe.outputs do
        if recipe.outputs[i].name == GRAIN and not recipe.outputs[i].fluid then
            hasGrain = true
        end
    end
    return hasWheat and hasGrain
end

local function findMillRecipe(list)
    local recipe = craft.findByOutput(list, GRAIN)
    if recipe and recipeIsWheatToGrain(recipe) then
        return recipe
    end
    for i = 1, #list do
        if recipeIsWheatToGrain(list[i]) then
            return list[i]
        end
    end
    return nil
end

local function millOnce(store, recipe, opts, batch)
    local have = craft_stock.countAvailable(store, WHEAT, opts)
    if have < 1 then
        return false, "no_wheat"
    end

    local machine = craft.resolveMachine(recipe)
    if not machine then
        return false, "no_machine"
    end
    if machine_lock.isBusy(machine) then
        return false, "busy"
    end

    local times = math.min(have, batch)
    local key = recipes.recipeKey(recipe)
    local ok, detail = machine_lock.withLock(machine, key, function()
        -- Re-check under lock: craft UI may have taken wheat / machine.
        local now = craft_stock.countAvailable(store, WHEAT, opts)
        if now < 1 then
            return false, { error = "no_wheat", skipped = true }
        end
        times = math.min(now, batch)
        return craft.run(recipe, {
            store = store,
            from = opts.from,
            out = opts.out,
            machine = machine,
            times = times,
            craftWaitTimeout = opts.craftWaitTimeout,
            waitTicks = opts.waitTicks,
        })
    end)

    return ok, detail, times
end

local function main()
    local store = storage.load()
    local list = craft.load()
    local recipe = findMillRecipe(list)
    if not recipe then
        error("no wheat → wheat_grain processing recipe in recipes.cfg")
    end

    local interval = store.getNumber("mill_interval", 5)
    local batch = math.max(1, math.floor(store.getNumber("mill_batch", 32)))
    local opts = {
        store = store,
        from = store.main(),
        out = store.main(),
        craftWaitTimeout = store.getNumber("craft_wait_timeout", 300),
        waitTicks = store.getNumber("wait_ticks", nil),
    }

    print(("wheat_grain: %s -> %s on %s, batch %s, interval %ss"):format(
        util.short(WHEAT),
        util.short(GRAIN),
        util.short(recipe.machine),
        tostring(batch),
        tostring(interval)
    ))
    print("run in bg: bg wheat_grain.lua")

    while true do
        local ok, detail, times = millOnce(store, recipe, opts, batch)
        if ok then
            local got = 0
            if detail and detail.outputs and detail.outputs[GRAIN] then
                got = detail.outputs[GRAIN]
            elseif detail and detail.sets_pushed then
                got = detail.sets_pushed
            else
                got = times or 0
            end
            print(("milled x%s -> %s"):format(tostring(got), util.short(GRAIN)))
        elseif detail == "no_wheat" or (type(detail) == "table" and detail.skipped) then
            sleep(interval)
        elseif detail == "busy" or (type(detail) == "table" and detail.error == "busy") then
            sleep(1)
        elseif detail == "no_machine" then
            print("wheat_grain: machine not on network, retrying...")
            sleep(interval)
        else
            local err = detail
            if type(detail) == "table" then
                err = detail.error or detail.missing and detail.missing.name or "failed"
            end
            print("wheat_grain: " .. tostring(err))
            sleep(interval)
        end
    end
end

main()
