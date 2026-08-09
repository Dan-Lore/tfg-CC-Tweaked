-- Run `processing` / `craft` / `grow` recipes from recipes.cfg.
-- Ingredient sources and output destinations come from storage.cfg when provided.

local transfer = require("transfer")
local recipes = require("recipes")
local greenhouse = require("greenhouse")
local peripherals = require("peripherals")

local craft = {}

local DEFAULT_CFG = "recipes.cfg"
local DEFAULT_GROW_PULSE = 3 -- seconds on; enough to latch one grow cycle
local DEFAULT_GROW_WAIT = 600 -- max seconds to wait for bus output after pulse

craft.resolveMachine = peripherals.resolveMachine

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

local function countAvailable(store, itemName, opts)
    if not store then
        local total = countItem(opts.from, itemName)
        if opts.out and opts.out ~= opts.from then
            total = total + countItem(opts.out, itemName)
        end
        return total
    end

    local seen = {}
    local total = 0
    local function add(inv)
        if inv and not seen[inv] and peripheral.isPresent(inv) then
            seen[inv] = true
            total = total + countItem(inv, itemName)
        end
    end

    add(store.sourceOf(itemName))
    add(store.destFor(itemName))
    add(store.main())
    add(store.overflow())
    if opts and opts.from then
        add(opts.from)
    end
    if opts and opts.out then
        add(opts.out)
    end
    return total
end

local function isCraftableName(name)
    return name and name:sub(1, 1) ~= "#"
end

local function countFluidAvailable(store, fluidOrTag)
    if not store then
        return 0, nil
    end
    local info = store.fluidSourceOf(fluidOrTag)
    if not info or not info.peripheral or not info.fluid then
        return 0, nil
    end
    if not peripheral.isPresent(info.peripheral) then
        return 0, info
    end
    return transfer.countFluid(info.peripheral, info.fluid), info
end

--- List missing inputs for one craft run (items + fluids). Does not recurse.
-- Fluids are listed first so UI/errors surface tank issues before mid-chain items.
local function findMissingInputs(recipe, store, opts)
    local fluids = {}
    local items = {}
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        if input.fluid then
            local have, info = countFluidAvailable(store, input.name)
            if not info then
                fluids[#fluids + 1] = {
                    name = input.name,
                    count = input.count,
                    fluid = true,
                    error = "no_fluid_source",
                }
            elseif have < input.count then
                fluids[#fluids + 1] = {
                    name = input.name,
                    count = input.count - have,
                    fluid = true,
                }
            end
        elseif isCraftableName(input.name) then
            local have = countAvailable(store, input.name, opts)
            if have < input.count then
                items[#items + 1] = {
                    name = input.name,
                    count = input.count - have,
                    fluid = false,
                }
            end
        else
            -- Item tags (#...) are not auto-resolved; report as missing unless sourced.
            local from = store and store.sourceOf(input.name)
            local have = (from and countItem(from, input.name)) or 0
            if have < input.count then
                items[#items + 1] = {
                    name = input.name,
                    count = input.count - have,
                    fluid = false,
                    tag = true,
                }
            end
        end
    end
    local missing = {}
    for i = 1, #fluids do
        missing[#missing + 1] = fluids[i]
    end
    for i = 1, #items do
        missing[#missing + 1] = items[i]
    end
    return missing
end

--- Pull item + fluid inputs into the machine. Fails before any move if something is missing.
local function pushInputs(stacks, machine, store, fallbackFrom)
    -- Dry-run availability for fluids (items assumed ensured by caller).
    for i = 1, #stacks do
        local stack = stacks[i]
        if stack.fluid then
            local have, info = countFluidAvailable(store, stack.name)
            if not info then
                return false, {}, {
                    name = stack.name,
                    count = stack.count,
                    fluid = true,
                    error = "no_fluid_source",
                }
            end
            if have < stack.count then
                return false, {}, {
                    name = stack.name,
                    count = stack.count - have,
                    fluid = true,
                }
            end
        end
    end

    local moved = {}
    for i = 1, #stacks do
        local stack = stacks[i]
        if stack.fluid then
            local _, info = countFluidAvailable(store, stack.name)
            local n = transfer.fluid(info.peripheral, machine, info.fluid, stack.count)
            moved[stack.name] = (moved[stack.name] or 0) + n
            if n < stack.count then
                return false, moved, {
                    name = stack.name,
                    count = stack.count - n,
                    fluid = true,
                }
            end
        else
            local from = fallbackFrom
            if store then
                from = store.sourceOf(stack.name) or fallbackFrom
            end
            local n = transfer(from, machine, stack.name, stack.count)
            moved[stack.name] = (moved[stack.name] or 0) + n
            if n < stack.count then
                return false, moved, {
                    name = stack.name,
                    count = stack.count - n,
                    fluid = false,
                }
            end
        end
    end
    return true, moved, nil
end

--- Destination for a recipe output (routes, seed-chest for plant-as-seed crops).
local function outputDest(store, recipe, itemName, fallbackOut)
    if not store then
        return fallbackOut
    end
    if recipe and recipe.flag == "grow" then
        local seedItem = store.seedForCrop(itemName)
        -- Basil-like: crop id is also the "seed" → seed chest, not fridge.
        if seedItem and seedItem == itemName and recipe.circuit ~= nil then
            return store.seedDest(recipe.circuit)
        end
    end
    return store.destFor(itemName) or fallbackOut
end

--- Pull recipe outputs into per-item destinations (route-aware).
local function pullOutputs(from, stacks, store, fallbackOut, recipe)
    local moved = {}
    for i = 1, #stacks do
        local stack = stacks[i]
        if not stack.fluid then
            local dest = outputDest(store, recipe, stack.name, fallbackOut)
            local n = transfer(from, dest, stack.name, stack.count)
            if store and n < stack.count then
                local overflow = store.overflow()
                if overflow and overflow ~= dest and peripheral.isPresent(overflow) then
                    n = n + transfer(from, overflow, stack.name, stack.count - n)
                end
            end
            moved[stack.name] = (moved[stack.name] or 0) + n
        end
    end
    return moved
end

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

function craft.run(recipe, opts)
    assert(recipe, "recipe required")
    assert(opts and opts.machine, "opts.machine required")
    local store = opts.store
    local from = opts.from or (store and store.main())
    local out = opts.out or (store and store.main())
    assert(from and out, "opts.from/opts.out or opts.store required")

    if recipe.flag == "grow" then
        return false, "use craft.request for grow recipes"
    end

    local missingList = findMissingInputs(recipe, store, opts)
    if #missingList > 0 then
        return false, {
            error = "missing_input",
            missing = missingList[1],
            missing_all = missingList,
        }
    end

    local ok, moved, missing = pushInputs(recipe.inputs, opts.machine, store, from)
    if not ok then
        return false, {
            error = "missing_input",
            missing = missing,
            moved = moved,
        }
    end

    local pullFrom = opts.pullFrom or opts.machine
    local beforeCounts = {}
    for i = 1, #recipe.outputs do
        local o = recipe.outputs[i]
        if not o.fluid then
            beforeCounts[o.name] = countItem(pullFrom, o.name)
        end
    end

    if opts.waitTicks and opts.waitTicks > 0 then
        sleep(opts.waitTicks / 20)
    else
        sleep(1)
    end

    local produced = false
    for i = 1, #recipe.outputs do
        local o = recipe.outputs[i]
        if not o.fluid then
            local have = countItem(pullFrom, o.name)
            if have >= (beforeCounts[o.name] or 0) + o.count then
                produced = true
                break
            end
        end
    end

    if not produced then
        return false, {
            error = "craft_no_output",
            missing = recipe.outputs[1] and {
                name = recipe.outputs[1].name,
                count = recipe.outputs[1].count,
            } or { name = recipe.machine, count = 1 },
            hint = "machine did not produce output (check fluids/power/circuit)",
        }
    end

    local outputs = pullOutputs(pullFrom, recipe.outputs, store, out, recipe)

    return true, {
        inputs = moved,
        outputs = outputs,
        machine = recipe.machine,
        circuit = recipe.circuit,
        flag = recipe.flag,
    }
end

function craft.once(machine, opts)
    local list = craft.load(opts and opts.cfg)
    local recipe = craft.find(list, machine, opts and opts.wantOutput)
    if not recipe then
        return false, "no recipe for " .. tostring(machine)
    end
    return craft.run(recipe, opts)
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

local function growPullFrom(recipe, machine, opts)
    local store = opts.store
    if opts.pullFrom then
        return opts.pullFrom
    end
    if store then
        local bus = store.outputBus(recipe.circuit or 0)
        if bus and peripheral.isPresent(bus) then
            return bus
        end
    end
    return machine
end

local function primaryGrowOutput(recipe)
    for i = 1, #recipe.outputs do
        if not recipe.outputs[i].fluid then
            return recipe.outputs[i]
        end
    end
    return nil
end

--- Pulse greenhouse briefly (default off), wait until one craft appears on the bus, pull it.
local function runGrow(recipe, machine, opts)
    local pulse = opts.growPulse or DEFAULT_GROW_PULSE
    local waitTimeout = opts.growWaitTimeout or DEFAULT_GROW_WAIT
    local store = opts.store
    local pullFrom = growPullFrom(recipe, machine, opts)
    local outStack = primaryGrowOutput(recipe)
    local before = outStack and countItem(pullFrom, outStack.name) or 0
    local need = outStack and outStack.count or 1

    -- Always leave machine off after the pulse.
    local ok = greenhouse.pulse(machine, pulse)
    greenhouse.disable(machine)
    if not ok then
        return false, {
            error = "grow_failed",
            missing = { name = machine, count = 1 },
        }
    end

    local deadline = os.clock() + waitTimeout
    local ready = false
    while os.clock() < deadline do
        greenhouse.disable(machine)
        if outStack and countItem(pullFrom, outStack.name) >= before + need then
            ready = true
            break
        end
        sleep(1)
    end

    greenhouse.disable(machine)

    if outStack and not ready then
        return false, {
            error = "grow_timeout",
            missing = { name = outStack.name, count = need },
            machine = machine,
        }
    end

    local out = opts.out or (store and store.main())
    local outputs = pullOutputs(pullFrom, recipe.outputs, store, out, recipe)
    return true, {
        inputs = {},
        outputs = outputs,
        machine = recipe.machine,
        circuit = recipe.circuit,
        flag = "grow",
        pulse = pulse,
    }
end

local function ensure(list, itemId, amount, opts, visiting, log)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then
        return true
    end

    local store = opts.store
    local have = countAvailable(store, itemId, opts)
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
        -- 1) Recurse into craftable item inputs first.
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

        -- 2) Refuse to start if anything is still missing (fluids, items, tags).
        local stillMissing = findMissingInputs(recipe, store, opts)
        if #stillMissing > 0 then
            visiting[itemId] = nil
            return false, {
                error = "missing_input",
                missing = stillMissing[1],
                missing_all = stillMissing,
            }
        end

        local ok, detail
        if recipe.flag == "grow" then
            ok, detail = runGrow(recipe, machine, opts)
        else
            ok, detail = craft.run(recipe, {
                from = opts.from,
                out = opts.out,
                store = store,
                machine = machine,
                pullFrom = opts.pullFrom,
                waitTicks = opts.waitTicks,
            })
        end

        if not ok then
            visiting[itemId] = nil
            return false, detail
        end
        log[#log + 1] = {
            item = itemId,
            machine = machine,
            flag = recipe.flag,
            detail = detail,
        }
    end

    visiting[itemId] = nil

    have = countAvailable(store, itemId, opts)
    if have < amount then
        return false, {
            error = "craft_short",
            missing = { name = itemId, count = amount - have },
        }
    end

    return true
end

--- Craft/grow until at least `amount` of the output item is available.
-- opts.store = storage.load() result (preferred). Otherwise opts.from/out required.
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
        opts.growPulse = opts.growPulse or store.getNumber("grow_pulse", DEFAULT_GROW_PULSE)
        opts.growWaitTimeout = opts.growWaitTimeout or store.getNumber("grow_wait_timeout", DEFAULT_GROW_WAIT)
        opts.waitTicks = opts.waitTicks or store.getNumber("wait_ticks", nil)
    end

    assert(opts.from and opts.out, "opts.from and opts.out (or opts.store) required")

    local list = craft.loadRequest(opts.cfg)
    local before = countAvailable(store, itemId, opts)
    local log = {}

    local ensureOpts = {
        from = opts.from,
        out = opts.out,
        store = store,
        pullFrom = opts.pullFrom,
        waitTicks = opts.waitTicks,
        growPulse = opts.growPulse,
        growWaitTimeout = opts.growWaitTimeout,
        cfg = opts.cfg,
    }

    local ok, err = ensure(list, itemId, before + amount, ensureOpts, {}, log)
    if not ok then
        return false, {
            error = err,
            produced = math.max(0, countAvailable(store, itemId, opts) - before),
            steps = log,
        }
    end

    local after = countAvailable(store, itemId, opts)
    return true, {
        item = itemId,
        produced = after - before,
        steps = log,
    }
end

return craft
