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
local DEFAULT_CRAFT_WAIT = 300 -- max seconds to wait for one processing cycle

craft.resolveMachine = peripherals.resolveMachine

-- Serialize access to the same machine peripheral across parallel ensures.
local machineLocks = {}

local function withMachineLock(machine, fn)
    while machineLocks[machine] do
        sleep(0.25)
    end
    machineLocks[machine] = true
    local ok, a, b = pcall(fn)
    machineLocks[machine] = nil
    if not ok then
        return false, {
            error = "exception",
            missing = { name = tostring(a), count = 1 },
        }
    end
    return a, b
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

local function scaleStacks(stacks, times)
    times = math.max(1, math.floor(tonumber(times) or 1))
    local out = {}
    for i = 1, #stacks do
        local s = stacks[i]
        out[i] = {
            name = s.name,
            count = s.count * times,
            fluid = s.fluid,
        }
    end
    return out
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

--- List missing inputs for `times` craft runs (items + fluids). Does not recurse.
-- Fluids are listed first so UI/errors surface tank issues before mid-chain items.
local function findMissingInputs(recipe, store, opts, times)
    times = math.max(1, math.floor(tonumber(times) or 1))
    local fluids = {}
    local items = {}
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        local need = input.count * times
        if input.fluid then
            local have, info = countFluidAvailable(store, input.name)
            if not info then
                fluids[#fluids + 1] = {
                    name = input.name,
                    count = need,
                    fluid = true,
                    error = "no_fluid_source",
                }
            elseif have < need then
                fluids[#fluids + 1] = {
                    name = input.name,
                    count = need - have,
                    fluid = true,
                }
            end
        elseif isCraftableName(input.name) then
            local have = countAvailable(store, input.name, opts)
            if have < need then
                items[#items + 1] = {
                    name = input.name,
                    count = need - have,
                    fluid = false,
                }
            end
        else
            local from = store and store.sourceOf(input.name)
            local have = (from and countItem(from, input.name)) or 0
            if have < need then
                items[#items + 1] = {
                    name = input.name,
                    count = need - have,
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

local function craftWaitTimeout(opts, times)
    times = math.max(1, math.floor(tonumber(times) or 1))
    local base = opts and opts.craftWaitTimeout
    if not base and opts and opts.waitTicks and opts.waitTicks > 0 then
        base = opts.waitTicks / 20
    end
    base = tonumber(base) or DEFAULT_CRAFT_WAIT
    return base * times
end

local function waitForOutputs(pullFrom, outputs, beforeCounts, timeout)
    local deadline = os.clock() + timeout
    while os.clock() < deadline do
        local ready = true
        local anyItem = false
        for i = 1, #outputs do
            local o = outputs[i]
            if not o.fluid then
                anyItem = true
                if countItem(pullFrom, o.name) < (beforeCounts[o.name] or 0) + o.count then
                    ready = false
                    break
                end
            end
        end
        if anyItem and ready then
            return true
        end
        if not anyItem then
            return true
        end
        sleep(0.5)
    end
    return false
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

    local times = math.max(1, math.floor(tonumber(opts.times) or 1))
    local inputs = scaleStacks(recipe.inputs, times)
    local outputs = scaleStacks(recipe.outputs, times)

    local missingList = findMissingInputs(recipe, store, opts, times)
    if #missingList > 0 then
        return false, {
            error = "missing_input",
            missing = missingList[1],
            missing_all = missingList,
        }
    end

    local ok, moved, missing = pushInputs(inputs, opts.machine, store, from)
    if not ok then
        return false, {
            error = "missing_input",
            missing = missing,
            moved = moved,
        }
    end

    local pullFrom = opts.pullFrom or opts.machine
    local beforeCounts = {}
    for i = 1, #outputs do
        local o = outputs[i]
        if not o.fluid then
            beforeCounts[o.name] = countItem(pullFrom, o.name)
        end
    end

    local timeout = craftWaitTimeout(opts, times)
    local ready = waitForOutputs(pullFrom, outputs, beforeCounts, timeout)
    if not ready then
        local primary = outputs[1]
        return false, {
            error = "craft_timeout",
            missing = primary and {
                name = primary.name,
                count = primary.count,
            } or { name = recipe.machine, count = 1 },
            hint = "machine did not finish in time (check power/circuit/fluids)",
            times = times,
        }
    end

    local pulled = pullOutputs(pullFrom, outputs, store, out, recipe)

    return true, {
        inputs = moved,
        outputs = pulled,
        machine = recipe.machine,
        circuit = recipe.circuit,
        flag = recipe.flag,
        times = times,
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

local ensure

--- Ensure craftable item inputs for `runs` recipe cycles (parallel when multiple).
local function ensureInputsParallel(list, recipe, runs, opts, visiting, log)
    local jobs = {}
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        if not input.fluid and isCraftableName(input.name) then
            local want = input.count * runs
            local have = countAvailable(opts.store, input.name, opts)
            if have < want then
                jobs[#jobs + 1] = {
                    name = input.name,
                    amount = want,
                }
            end
        end
    end

    if #jobs == 0 then
        return true
    end

    if #jobs == 1 then
        return ensure(list, jobs[1].name, jobs[1].amount, opts, visiting, log)
    end

    local firstErr = nil
    local funcs = {}
    for i = 1, #jobs do
        local job = jobs[i]
        funcs[i] = function()
            if firstErr then
                return
            end
            local localVisiting = {}
            for k, v in pairs(visiting) do
                localVisiting[k] = v
            end
            local ok, err = ensure(list, job.name, job.amount, opts, localVisiting, log)
            if not ok and not firstErr then
                firstErr = err
            end
        end
    end

    parallel.waitForAll(table.unpack(funcs))
    if firstErr then
        return false, firstErr
    end
    return true
end

ensure = function(list, itemId, amount, opts, visiting, log)
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

    local function fail(err)
        visiting[itemId] = nil
        return false, err
    end

    if recipe.flag == "grow" then
        for _ = 1, runs do
            local okIn, errIn = ensureInputsParallel(list, recipe, 1, opts, visiting, log)
            if not okIn then
                return fail(errIn)
            end

            local stillMissing = findMissingInputs(recipe, store, opts, 1)
            if #stillMissing > 0 then
                return fail({
                    error = "missing_input",
                    missing = stillMissing[1],
                    missing_all = stillMissing,
                })
            end

            local ok, detail = withMachineLock(machine, function()
                return runGrow(recipe, machine, opts)
            end)
            if not ok then
                return fail(detail)
            end
            log[#log + 1] = {
                item = itemId,
                machine = machine,
                flag = recipe.flag,
                detail = detail,
            }
        end
    else
        local okIn, errIn = ensureInputsParallel(list, recipe, runs, opts, visiting, log)
        if not okIn then
            return fail(errIn)
        end

        local stillMissing = findMissingInputs(recipe, store, opts, runs)
        if #stillMissing > 0 then
            return fail({
                error = "missing_input",
                missing = stillMissing[1],
                missing_all = stillMissing,
            })
        end

        local ok, detail = withMachineLock(machine, function()
            return craft.run(recipe, {
                from = opts.from,
                out = opts.out,
                store = store,
                machine = machine,
                pullFrom = opts.pullFrom,
                waitTicks = opts.waitTicks,
                craftWaitTimeout = opts.craftWaitTimeout,
                times = runs,
            })
        end)
        if not ok then
            return fail(detail)
        end
        log[#log + 1] = {
            item = itemId,
            machine = machine,
            flag = recipe.flag,
            detail = detail,
            times = runs,
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
        opts.craftWaitTimeout = opts.craftWaitTimeout or store.getNumber("craft_wait_timeout", DEFAULT_CRAFT_WAIT)
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
        craftWaitTimeout = opts.craftWaitTimeout or DEFAULT_CRAFT_WAIT,
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
