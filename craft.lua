-- Public craft API: load/find recipes, run processing, request with monitor stack.
-- Internals: machine_lock, craft_stock, craft_io, craft_grow, craft_monitor.

local recipes = require("recipes")
local peripherals = require("peripherals")
local craft_io = require("craft_io")
local craft_grow = require("craft_grow")
local craft_monitor = require("craft_monitor")
local machine_lock = require("machine_lock")

local craft = {}

local DEFAULT_CFG = "recipes.cfg"
local DEFAULT_CRAFT_WAIT = 300

craft.resolveMachine = peripherals.resolveMachine
craft.withMachineLock = machine_lock.withLock
craft.tryMachineLock = machine_lock.tryLock

---------------------------------------------------------------------------
-- Recipe helpers
---------------------------------------------------------------------------

function craft.load(path)
    local all = recipes.load(path or DEFAULT_CFG)
    return recipes.filter(all, function(r)
        return r.flag == "processing" or r.flag == "craft"
    end)
end

function craft.loadRequest(path)
    local all = recipes.load(path or DEFAULT_CFG)
    return recipes.filter(all, function(r)
        return r.flag == "processing" or r.flag == "craft" or r.flag == "grow"
    end)
end

function craft.findAll(list, machine)
    return recipes.byMachine(list, machine)
end

function craft.find(list, machine, wantOutput)
    local matches = recipes.byMachine(list, machine)
    if #matches == 0 then
        return nil
    end
    if not wantOutput then
        return matches[1]
    end
    for i = 1, #matches do
        local outs = matches[i].outputs
        for j = 1, #outs do
            if outs[j].name == wantOutput then
                return matches[i]
            end
        end
    end
    return nil
end

function craft.findByOutput(list, itemId)
    for i = 1, #list do
        local outs = list[i].outputs
        for j = 1, #outs do
            if not outs[j].fluid and outs[j].name == itemId then
                return list[i], outs[j]
            end
        end
    end
    return nil, nil
end

function craft.catalog(list)
    local seen = {}
    local catalog = {}
    for i = 1, #list do
        local recipe = list[i]
        for j = 1, #recipe.outputs do
            local out = recipe.outputs[j]
            if not out.fluid and not seen[out.name] then
                seen[out.name] = true
                local label = out.name:match("([^/]+)$") or out.name
                catalog[#catalog + 1] = {
                    id = out.name,
                    label = label,
                    recipe = recipe,
                    perCraft = out.count,
                }
            end
        end
    end
    table.sort(catalog, function(a, b) return a.label < b.label end)
    return catalog
end

---------------------------------------------------------------------------
-- Processing run / once
---------------------------------------------------------------------------

function craft.run(recipe, opts)
    return craft_io.run(recipe, opts)
end

function craft.once(machine, opts)
    local list = craft.load(opts and opts.cfg)
    local recipe = craft.find(list, machine, opts and opts.wantOutput)
    if not recipe then
        return false, "no recipe for " .. tostring(machine)
    end
    return craft.run(recipe, opts)
end

---------------------------------------------------------------------------
-- request: monitor until crafted counter hits amount
---------------------------------------------------------------------------

--- Craft/grow until `amount` of the target has been produced (craft counter).
-- opts.onActivity(text), opts.onProgress(done, total) for UI.
function craft.request(itemId, amount, opts)
    opts = opts or {}
    amount = math.max(1, math.floor(tonumber(amount) or 1))

    local store = opts.store
    if not store and opts.from and opts.out then
        -- legacy single-inventory mode
    elseif not store then
        local storageMod = require("storage")
        store = storageMod.load(opts.storageCfg)
        opts.store = store
    end

    if store then
        opts.from = opts.from or store.main()
        opts.out = opts.out or store.main()
        opts.growPulse = opts.growPulse or store.getNumber("grow_pulse", craft_grow.DEFAULT_GROW_PULSE)
        opts.growWaitTimeout = opts.growWaitTimeout or store.getNumber("grow_wait_timeout", craft_grow.DEFAULT_GROW_WAIT)
        opts.craftWaitTimeout = opts.craftWaitTimeout or store.getNumber("craft_wait_timeout", DEFAULT_CRAFT_WAIT)
        opts.waitTicks = opts.waitTicks or store.getNumber("wait_ticks", nil)
    end

    assert(opts.from and opts.out, "opts.from and opts.out (or opts.store) required")

    local list = craft.loadRequest(opts.cfg)
    local foundRecipe, foundOut = craft.findByOutput(list, itemId)
    if not foundRecipe then
        return false, {
            error = {
                error = "missing_input",
                missing = { name = itemId, count = amount },
            },
            produced = 0,
            steps = {},
        }
    end

    local log = {}
    local ok, result = craft_monitor.request({
        findByOutput = craft.findByOutput,
        resolveMachine = craft.resolveMachine,
        run = craft.run,
        runGrow = craft_grow.run,
    }, list, itemId, amount, opts, log)

    if not ok then
        local produced = 0
        local per = foundOut and foundOut.count or 1
        for i = 1, #log do
            if log[i].item == itemId then
                local d = log[i].detail
                if d and d.sets_pushed then
                    produced = produced + d.sets_pushed * per
                else
                    produced = produced + per
                end
            end
        end
        return false, {
            error = result,
            produced = produced,
            steps = log,
        }
    end

    return true, {
        item = itemId,
        produced = result,
        steps = log,
    }
end

return craft
