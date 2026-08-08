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

--- First recipe that produces itemId (non-fluid output).
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

--- Unique craftable output items: { { id, label, recipe, perCraft }, ... }
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

--- Resolve a physical machine peripheral for a recipe.
-- Tries recipe.machine, then recipe.base, then peripherals starting with base.
function craft.resolveMachine(recipe)
    if peripheral.isPresent(recipe.machine) then
        return recipe.machine
    end
    if peripheral.isPresent(recipe.base) then
        return recipe.base
    end
    local prefix = recipe.base .. "_"
    local names = peripheral.getNames()
    table.sort(names)
    for i = 1, #names do
        local name = names[i]
        if name == recipe.base or name:sub(1, #prefix) == prefix then
            return name
        end
    end
    return nil
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

local function countAvailable(opts, itemName)
    local total = countItem(opts.from, itemName)
    if opts.out and opts.out ~= opts.from then
        total = total + countItem(opts.out, itemName)
    end
    return total
end

local function isCraftableName(name)
    return name and name:sub(1, 1) ~= "#"
end

--- Ensure `amount` of itemId exists in storage, recursively crafting dependencies.
-- Fluids and tags are not auto-crafted.
local function ensure(list, itemId, amount, opts, visiting, log)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then
        return true
    end

    local have = countAvailable(opts, itemId)
    local need = amount - have
    if need <= 0 then
        return true
    end

    if visiting[itemId] then
        return false, {
            error = "cycle",
            missing = { name = itemId, count = need },
        }
    end

    local recipe, outStack = craft.findByOutput(list, itemId)
    if not recipe then
        return false, {
            error = "missing_input",
            missing = { name = itemId, count = need },
        }
    end

    local machine = opts.machine or craft.resolveMachine(recipe)
    if not machine then
        return false, {
            error = "no_machine",
            missing = { name = recipe.base, count = 1 },
            item = itemId,
        }
    end

    visiting[itemId] = true
    local runs = math.ceil(need / outStack.count)

    for _ = 1, runs do
        for i = 1, #recipe.inputs do
            local input = recipe.inputs[i]
            if not input.fluid and isCraftableName(input.name) then
                local ok, err = ensure(list, input.name, input.count, opts, visiting, log)
                if not ok then
                    visiting[itemId] = nil
                    return false, err
                end
            end
        end

        local ok, detail = craft.run(recipe, {
            from = opts.from,
            out = opts.out,
            machine = machine,
            pullFrom = opts.pullFrom,
            waitTicks = opts.waitTicks,
        })
        if not ok then
            -- Missing fluid/tag/etc. that we cannot recurse into.
            visiting[itemId] = nil
            return false, detail
        end
        log[#log + 1] = {
            item = itemId,
            machine = machine,
            detail = detail,
        }
    end

    visiting[itemId] = nil

    have = countAvailable(opts, itemId)
    if have < amount then
        return false, {
            error = "craft_short",
            missing = { name = itemId, count = amount - have },
        }
    end

    return true
end

--- Craft until at least `amount` of the output item is available.
-- Recursively crafts missing non-fluid, non-tag inputs from recipes.cfg.
-- opts.from / opts.out required. opts.machine optional (auto-resolved per recipe).
function craft.request(itemId, amount, opts)
    assert(opts and opts.from and opts.out, "opts.from and opts.out required")
    amount = math.max(1, math.floor(tonumber(amount) or 1))

    local list = craft.load(opts.cfg)
    local before = countAvailable(opts, itemId)
    local log = {}

    -- Don't pin opts.machine for the whole tree — each step resolves its own.
    local ensureOpts = {
        from = opts.from,
        out = opts.out,
        pullFrom = opts.pullFrom,
        waitTicks = opts.waitTicks,
        cfg = opts.cfg,
    }

    local ok, err = ensure(list, itemId, before + amount, ensureOpts, {}, log)
    if not ok then
        return false, {
            error = err,
            produced = math.max(0, countAvailable(opts, itemId) - before),
            steps = log,
        }
    end

    local after = countAvailable(opts, itemId)
    return true, {
        item = itemId,
        produced = after - before,
        steps = log,
    }
end

return craft
