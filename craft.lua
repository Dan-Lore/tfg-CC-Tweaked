-- Run `processing` / `craft` recipes from recipes.cfg.
-- Grow recipes are handled separately by on.lua.
-- Storage peripherals are always passed by the caller — no hard-coded inventories.

local transfer = require("transfer")
local recipes = require("recipes")

local craft = {}

local DEFAULT_CFG = "recipes.cfg"

--- Move all non-fluid inputs from inventory into the machine.
-- Fluids must be handled by the caller (tanks / GT fluid hatches).
local function pushItems(from, to, stacks)
    local moved = {}
    for i = 1, #stacks do
        local stack = stacks[i]
        if not stack.fluid then
            local n = transfer(from, to, stack.name, stack.count)
            moved[stack.name] = (moved[stack.name] or 0) + n
            if n < stack.count then
                return false, moved, stack
            end
        end
    end
    return true, moved, nil
end

--- Pull recipe outputs from the machine into an inventory.
local function pullItems(from, to, stacks)
    local moved = {}
    for i = 1, #stacks do
        local stack = stacks[i]
        if not stack.fluid then
            local n = transfer(from, to, stack.name, stack.count)
            moved[stack.name] = (moved[stack.name] or 0) + n
        end
    end
    return moved
end

--- Load recipes and keep only craftable flags.
function craft.load(path)
    local all = recipes.load(path or DEFAULT_CFG)
    return recipes.filter(all, function(r)
        return r.flag == "processing" or r.flag == "craft"
    end)
end

--- All recipes for a machine id (with circuit suffix).
function craft.findAll(list, machine)
    return recipes.byMachine(list, machine)
end

--- Find recipe by machine. If several share the same circuit, pass `wantOutput`
--- item id to disambiguate (e.g. "firmalife:food/pizza_dough").
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

--- Execute one processing recipe once.
-- @param recipe table from recipes.lua
-- @param opts.from     peripheral name of input inventory (required)
-- @param opts.machine  peripheral name of the machine (required)
-- @param opts.out      peripheral name of output inventory (required)
-- @param opts.pullFrom optional; where to pull outputs from (defaults to opts.machine)
-- @return ok, detail
function craft.run(recipe, opts)
    assert(recipe, "recipe required")
    assert(opts and opts.from and opts.machine and opts.out, "opts.from, opts.machine, opts.out required")

    if recipe.flag == "grow" then
        return false, "grow recipes belong in on.lua"
    end

    local ok, moved, missing = pushItems(opts.from, opts.machine, recipe.inputs)
    if not ok then
        return false, {
            error = "missing_input",
            missing = missing,
            moved = moved,
        }
    end

    -- Machines craft on their own once items/fluids/EU are present.
    if opts.waitTicks and opts.waitTicks > 0 then
        sleep(opts.waitTicks / 20)
    end

    local pullFrom = opts.pullFrom or opts.machine
    local outputs = pullItems(pullFrom, opts.out, recipe.outputs)

    return true, {
        inputs = moved,
        outputs = outputs,
        machine = recipe.machine,
        circuit = recipe.circuit,
        flag = recipe.flag,
    }
end

--- Convenience: load cfg, pick machine recipe, run once.
-- opts.wantOutput disambiguates when several recipes share one circuit.
function craft.once(machine, opts)
    local list = craft.load(opts and opts.cfg)
    local recipe = craft.find(list, machine, opts and opts.wantOutput)
    if not recipe then
        return false, "no recipe for " .. tostring(machine)
    end
    return craft.run(recipe, opts)
end

return craft
