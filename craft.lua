-- Run `processing` / `craft` / `grow` recipes from recipes.cfg.
--
-- Sections: lock | stock | feed | wait/drain | grow | ensure | public API
-- Ingredient sources and output destinations come from storage.cfg.

local transfer = require("transfer")
local recipes = require("recipes")
local greenhouse = require("greenhouse")
local peripherals = require("peripherals")

local craft = {}

local DEFAULT_CFG = "recipes.cfg"
local DEFAULT_GROW_PULSE = 3
local DEFAULT_GROW_WAIT = 600
local DEFAULT_CRAFT_WAIT = 300

craft.resolveMachine = peripherals.resolveMachine

---------------------------------------------------------------------------
-- Machine lock (recipe-aware): exclusive per peripheral; same recipe queues.
---------------------------------------------------------------------------

local machineLocks = {} -- name -> { key = recipeKey }

local function withMachineLock(machine, recipeKey, fn)
    recipeKey = recipeKey or "unknown"
    while true do
        local lock = machineLocks[machine]
        if not lock then
            machineLocks[machine] = { key = recipeKey }
            break
        end
        -- Busy: wait whether same or different key (exclusive machine use).
        -- Same key may "stack" by running after the current holder finishes.
        sleep(0.25)
    end

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

---------------------------------------------------------------------------
-- Stock (count == pull sources)
---------------------------------------------------------------------------

local function extraInvOpts(opts)
    local extra = {}
    if opts then
        if opts.from then
            extra[#extra + 1] = opts.from
        end
        if opts.out and opts.out ~= opts.from then
            extra[#extra + 1] = opts.out
        end
    end
    return extra
end

local function pullSourcesFor(store, itemName, opts)
    if store and store.pullSources then
        return store.pullSources(itemName, extraInvOpts(opts))
    end
    local list = {}
    local seen = {}
    local function add(inv)
        if inv and not seen[inv] and peripheral.isPresent(inv) then
            seen[inv] = true
            list[#list + 1] = inv
        end
    end
    if opts then
        add(opts.from)
        add(opts.out)
    end
    return list
end

local function countAvailable(store, itemName, opts)
    return transfer.countFromMany(pullSourcesFor(store, itemName, opts), itemName)
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
        return 0, nil
    end
    return transfer.countFluid(info.peripheral, info.fluid), info
end

--- List missing inputs for `times` craft runs (items + fluids). Does not recurse.
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
            local sources = pullSourcesFor(store, input.name, opts)
            local have = transfer.countFromMany(sources, input.name)
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

--- Missing inputs that cannot be crafted further (fluids, tags, no recipe).
local function hardMissingInputs(list, missingList)
    local hard = {}
    if not missingList then
        return hard
    end
    for i = 1, #missingList do
        local m = missingList[i]
        local leaf = false
        if m.fluid or m.tag or m.error == "no_fluid_source" then
            leaf = true
        elseif not isCraftableName(m.name) then
            leaf = true
        elseif not list or not craft.findByOutput(list, m.name) then
            leaf = true
        end
        if leaf then
            hard[#hard + 1] = m
        end
    end
    return hard
end

---------------------------------------------------------------------------
-- Feed: balanced set-by-set push + rollback
---------------------------------------------------------------------------

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

local function pullItemAmount(from, itemName, amount, store, fallbackOut, recipe)
    amount = tonumber(amount) or 0
    if amount <= 0 or not from then
        return 0
    end
    local dest = outputDest(store, recipe, itemName, fallbackOut)
    if not dest or not peripheral.isPresent(dest) then
        dest = nil
    end
    local n = 0
    if dest and dest ~= from and peripheral.isPresent(from) then
        n = transfer(from, dest, itemName, amount)
    end
    if store and n < amount then
        local overflow = store.overflow()
        if overflow and overflow ~= dest and overflow ~= from and peripheral.isPresent(overflow) then
            n = n + transfer(from, overflow, itemName, amount - n)
        end
    end
    return n
end

local function pullOutputs(from, stacks, store, fallbackOut, recipe)
    local moved = {}
    for i = 1, #stacks do
        local stack = stacks[i]
        if not stack.fluid then
            local n = pullItemAmount(from, stack.name, stack.count, store, fallbackOut, recipe)
            moved[stack.name] = (moved[stack.name] or 0) + n
        end
    end
    return moved
end

--- Rollback items from machine into storage pull-sources (as destinations).
-- Prefer main/dest first so leftovers land where craft expects them.
local function rollbackItems(machine, movedItems, store, opts)
    for name, count in pairs(movedItems) do
        if count and count > 0 then
            local dests = pullSourcesFor(store, name, opts)
            -- Reverse order: overflow/main first often better for return path;
            -- pullSources is source→dest→main→overflow; prefer dest/main for rollback.
            local preferred = {}
            for i = #dests, 1, -1 do
                preferred[#preferred + 1] = dests[i]
            end
            if #preferred == 0 and opts and opts.out then
                preferred[1] = opts.out
            end
            transfer.toMany(machine, preferred, name, count)
        end
    end
end

--- Check that one full recipe set is available in storage (no moves).
local function setAvailable(recipe, store, opts)
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        if input.fluid then
            local have, info = countFluidAvailable(store, input.name)
            if not info then
                return false, {
                    name = input.name,
                    count = input.count,
                    fluid = true,
                    error = "no_fluid_source",
                }
            end
            if have < input.count then
                return false, {
                    name = input.name,
                    count = input.count - have,
                    fluid = true,
                }
            end
        else
            local have = countAvailable(store, input.name, opts)
            if have < input.count then
                return false, {
                    name = input.name,
                    count = input.count - have,
                    fluid = false,
                }
            end
        end
    end
    return true, nil
end

--- Push exactly one recipe unit into the machine. Rolls back items on mid-set failure.
-- Returns ok, movedTotals, missing
local function pushOneSet(recipe, machine, store, opts)
    local okAvail, missing = setAvailable(recipe, store, opts)
    if not okAvail then
        return false, {}, missing
    end

    local movedItems = {}
    local movedFluids = {}

    -- Items first (rollbackable), then fluids.
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        if not input.fluid then
            local sources = pullSourcesFor(store, input.name, opts)
            local n = transfer.fromMany(sources, machine, input.name, input.count)
            movedItems[input.name] = (movedItems[input.name] or 0) + n
            if n < input.count then
                rollbackItems(machine, movedItems, store, opts)
                return false, movedItems, {
                    name = input.name,
                    count = input.count - n,
                    fluid = false,
                    error = "push_short",
                }
            end
        end
    end

    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        if input.fluid then
            local _, info = countFluidAvailable(store, input.name)
            if not info then
                rollbackItems(machine, movedItems, store, opts)
                return false, movedItems, {
                    name = input.name,
                    count = input.count,
                    fluid = true,
                    error = "no_fluid_source",
                }
            end
            local n = transfer.fluid(info.peripheral, machine, info.fluid, input.count)
            movedFluids[input.name] = (movedFluids[input.name] or 0) + n
            if n < input.count then
                rollbackItems(machine, movedItems, store, opts)
                return false, movedItems, {
                    name = input.name,
                    count = input.count - n,
                    fluid = true,
                    error = "push_short",
                }
            end
        end
    end

    local moved = {}
    for k, v in pairs(movedItems) do
        moved[k] = v
    end
    for k, v in pairs(movedFluids) do
        moved[k] = (moved[k] or 0) + v
    end
    return true, moved, nil
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

--- Drain toward expected totals; returns whether complete.
local function drainToward(pullFrom, need, pulled, store, fallbackOut, recipe)
    local complete = true
    for name, want in pairs(need) do
        local remaining = want - (pulled[name] or 0)
        if remaining > 0 then
            local n = pullItemAmount(pullFrom, name, remaining, store, fallbackOut, recipe)
            pulled[name] = (pulled[name] or 0) + n
            if pulled[name] < want then
                complete = false
            end
        end
    end
    return complete
end

local function buildNeedMap(outputs, times)
    local need = {}
    local anyItem = false
    for i = 1, #outputs do
        local o = outputs[i]
        if not o.fluid then
            anyItem = true
            need[o.name] = (need[o.name] or 0) + o.count * times
        end
    end
    return need, anyItem
end

---------------------------------------------------------------------------
-- Public recipe helpers
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
-- craft.run: set-by-set feed + continuous drain
---------------------------------------------------------------------------

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
    local missingList = findMissingInputs(recipe, store, opts, times)
    if #missingList > 0 then
        return false, {
            error = "missing_input",
            missing = missingList[1],
            missing_all = missingList,
        }
    end

    local oneshot = recipe.oneshot == true
    local targetSets = times
    local need, anyItem = buildNeedMap(recipe.outputs, targetSets)
    local pulled = {}
    for name in pairs(need) do
        pulled[name] = 0
    end

    local pullFrom = opts.pullFrom or opts.machine
    local timeout = craftWaitTimeout(opts, times)
    local deadline = os.clock() + timeout
    local setsPushed = 0
    local movedTotals = {}
    local lastMissing = nil
    local stallSleeps = 0
    local pushing = true

    local function rebuildNeed(sets)
        need, anyItem = buildNeedMap(recipe.outputs, sets)
        for name in pairs(need) do
            if not pulled[name] then
                pulled[name] = 0
            end
        end
    end

    local function outputsComplete()
        if not anyItem then
            return setsPushed >= targetSets
        end
        for name, want in pairs(need) do
            if (pulled[name] or 0) < want then
                return false
            end
        end
        return true
    end

    --- For oneshot recipes: only feed the next set after current outputs are pulled.
    local function readyForNextSet()
        if not oneshot or setsPushed == 0 then
            return true
        end
        if not anyItem then
            return true
        end
        local needSoFar = buildNeedMap(recipe.outputs, setsPushed)
        for name, want in pairs(needSoFar) do
            if (pulled[name] or 0) < want then
                return false
            end
        end
        return true
    end

    local function successDetail()
        return {
            inputs = movedTotals,
            outputs = pulled,
            machine = recipe.machine,
            circuit = recipe.circuit,
            flag = recipe.flag,
            times = targetSets,
            sets_pushed = setsPushed,
        }
    end

    local function finishOk()
        local detail = successDetail()
        if targetSets < times then
            local shortName = nil
            local shortCount = 0
            for i = 1, #recipe.outputs do
                local o = recipe.outputs[i]
                if not o.fluid then
                    shortName = o.name
                    shortCount = shortCount + o.count * (times - targetSets)
                end
            end
            return false, {
                error = "craft_short",
                missing = {
                    name = shortName or (recipe.outputs[1] and recipe.outputs[1].name),
                    count = math.max(1, shortCount),
                },
                outputs = pulled,
                times = targetSets,
                sets_pushed = setsPushed,
                wanted_times = times,
            }
        end
        return true, detail
    end

    while os.clock() < deadline do
        drainToward(pullFrom, need, pulled, store, out, recipe)
        if outputsComplete() then
            return finishOk()
        end

        if pushing and setsPushed < targetSets and readyForNextSet() then
            local ok, moved, missing = pushOneSet(recipe, opts.machine, store, opts)
            if ok then
                setsPushed = setsPushed + 1
                stallSleeps = 0
                for k, v in pairs(moved) do
                    movedTotals[k] = (movedTotals[k] or 0) + v
                end
            else
                lastMissing = missing
                -- Machine input full: keep trying. Stock short: finish sets already pushed.
                if missing and missing.error == "push_short" then
                    stallSleeps = 0
                else
                    stallSleeps = stallSleeps + 1
                    -- Be patient: parallel gather may still be topping up ingredients.
                    if setsPushed > 0 and stallSleeps > 12 then
                        pushing = false
                        targetSets = setsPushed
                        rebuildNeed(targetSets)
                    elseif setsPushed == 0 and stallSleeps > 20 then
                        return false, {
                            error = "missing_input",
                            missing = missing,
                            moved = movedTotals,
                            times = times,
                            sets_pushed = setsPushed,
                        }
                    end
                end
            end
        end

        sleep(0.5)
    end

    drainToward(pullFrom, need, pulled, store, out, recipe)
    if outputsComplete() then
        return finishOk()
    end

    local shortName, shortCount = nil, 0
    for name, want in pairs(need) do
        local left = want - (pulled[name] or 0)
        if left > shortCount then
            shortName = name
            shortCount = left
        end
    end
    return false, {
        error = "craft_timeout",
        missing = lastMissing or {
            name = shortName or (recipe.outputs[1] and recipe.outputs[1].name) or recipe.machine,
            count = shortCount > 0 and shortCount or 1,
        },
        outputs = pulled,
        hint = "machine stalled or timed out (output slots / power / circuit)",
        times = targetSets,
        sets_pushed = setsPushed,
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

---------------------------------------------------------------------------
-- Grow
---------------------------------------------------------------------------

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

local function runGrow(recipe, machine, opts)
    local pulse = opts.growPulse or DEFAULT_GROW_PULSE
    local waitTimeout = opts.growWaitTimeout or DEFAULT_GROW_WAIT
    local store = opts.store
    local pullFrom = growPullFrom(recipe, machine, opts)
    local outStack = recipes.primaryOutput(recipe)
    local before = outStack and transfer.countItem(pullFrom, outStack.name) or 0
    local need = outStack and outStack.count or 1

    local ok, err = greenhouse.pulse(machine, pulse)
    greenhouse.disable(machine)
    if not ok then
        return false, {
            error = "grow_failed",
            missing = { name = machine, count = 1 },
            detail = err,
        }
    end

    local deadline = os.clock() + waitTimeout
    local ready = false
    while os.clock() < deadline do
        greenhouse.disable(machine)
        if outStack and transfer.countItem(pullFrom, outStack.name) >= before + need then
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

---------------------------------------------------------------------------
-- Ensure (pipeline: craft ready packs by min set, gather rest in parallel)
---------------------------------------------------------------------------

local ensure

--- How many balanced recipe sets can be fed from current stock (items + fluids).
local function countCompleteSets(recipe, store, opts)
    if not recipe or not recipe.inputs or #recipe.inputs == 0 then
        return 0
    end
    local sets = nil
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        local per = input.count
        if not per or per <= 0 then
            return 0
        end
        local have
        if input.fluid then
            have = countFluidAvailable(store, input.name)
        else
            have = countAvailable(store, input.name, opts)
        end
        local can = math.floor(have / per)
        if sets == nil or can < sets then
            sets = can
        end
    end
    return sets or 0
end

local function recipeHasCraftableInputs(recipe)
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        if not input.fluid and isCraftableName(input.name) then
            return true
        end
    end
    return false
end

--- Ensure craftable inputs toward absolute stock for `runs` parent cycles.
local function ensureInputsParallel(list, recipe, runs, opts, visiting, log, cancelled)
    runs = math.max(1, math.floor(tonumber(runs) or 1))
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
        if cancelled and cancelled[1] then
            return false, cancelled[2]
        end
        return ensure(list, jobs[1].name, jobs[1].amount, opts, visiting, log, cancelled)
    end

    local firstErr = nil
    local cancelFlag = cancelled or { false, nil }
    local funcs = {}
    for i = 1, #jobs do
        local job = jobs[i]
        funcs[i] = function()
            if cancelFlag[1] then
                return
            end
            local have = countAvailable(opts.store, job.name, opts)
            if have >= job.amount then
                return
            end
            local localVisiting = {}
            for k, v in pairs(visiting) do
                localVisiting[k] = v
            end
            local ok, err = ensure(list, job.name, job.amount, opts, localVisiting, log, cancelFlag)
            if not ok and not cancelFlag[1] then
                cancelFlag[1] = true
                cancelFlag[2] = err
                firstErr = err
            end
        end
    end

    parallel.waitForAll(table.unpack(funcs))
    if cancelFlag[1] then
        return false, cancelFlag[2] or firstErr
    end
    return true
end

local function runCraftBatch(recipe, machine, recipeKey, store, opts, itemId, amount, outStack, log, times)
    times = math.max(1, math.floor(tonumber(times) or 1))
    local ok, detail = withMachineLock(machine, recipeKey, function()
        local readyNow = countCompleteSets(recipe, store, opts)
        local n = math.min(times, readyNow)
        if n <= 0 then
            return true, { skipped = true }
        end
        local stillMissing = findMissingInputs(recipe, store, opts, n)
        if #stillMissing > 0 then
            return false, {
                error = "missing_input",
                missing = stillMissing[1],
                missing_all = stillMissing,
            }
        end
        return craft.run(recipe, {
            from = opts.from,
            out = opts.out,
            store = store,
            machine = machine,
            pullFrom = opts.pullFrom,
            waitTicks = opts.waitTicks,
            craftWaitTimeout = opts.craftWaitTimeout,
            times = n,
        })
    end)
    if ok and detail and not detail.skipped then
        log[#log + 1] = {
            item = itemId,
            machine = machine,
            flag = recipe.flag,
            detail = detail,
            times = detail.times,
        }
    end
    return ok, detail
end

ensure = function(list, itemId, amount, opts, visiting, log, cancelled)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then
        return true
    end
    if cancelled and cancelled[1] then
        return false, cancelled[2]
    end

    local store = opts.store
    local before = countAvailable(store, itemId, opts)
    local need = amount - before
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
    if not outStack or not outStack.count or outStack.count <= 0 then
        return false, {
            error = "missing_input",
            missing = { name = itemId, count = need },
            hint = "recipe has no item output count",
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
    local recipeKey = recipes.recipeKey(recipe)
    local produced = 0

    local function fail(err)
        visiting[itemId] = nil
        return false, err
    end

    local function noteProduced(detail, fallbackSets)
        local sets = fallbackSets or 0
        if detail and not detail.skipped then
            sets = tonumber(detail.sets_pushed) or tonumber(detail.times) or sets
        end
        if sets > 0 then
            produced = produced + sets * outStack.count
        end
    end

    -- Production-based success: a parallel parent (oven) may consume intermediates.
    local function fulfilled()
        if produced >= need then
            return true
        end
        return countAvailable(store, itemId, opts) >= amount
    end

    if recipe.flag == "grow" then
        local runs = math.ceil(need / outStack.count)
        for _ = 1, runs do
            if cancelled and cancelled[1] then
                return fail(cancelled[2])
            end
            if fulfilled() then
                break
            end

            local okIn, errIn = ensureInputsParallel(list, recipe, 1, opts, visiting, log, cancelled)
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

            local ok, detail = withMachineLock(machine, recipeKey, function()
                if fulfilled() then
                    return true, { skipped = true }
                end
                return runGrow(recipe, machine, opts)
            end)
            if not ok then
                return fail(detail)
            end
            if detail and not detail.skipped then
                noteProduced(detail, 1)
                log[#log + 1] = {
                    item = itemId,
                    machine = machine,
                    flag = recipe.flag,
                    detail = detail,
                }
            end
        end
    else
        local stop = { false, nil }
        local function shouldStop()
            if stop[1] then
                return true
            end
            if cancelled and cancelled[1] then
                stop[1] = true
                stop[2] = cancelled[2]
                return true
            end
            return fulfilled()
        end

        local function remainingRuns()
            if fulfilled() then
                return 0
            end
            local byProd = math.ceil((need - produced) / outStack.count)
            local haveOut = countAvailable(store, itemId, opts)
            local byStock = math.max(0, math.ceil((amount - haveOut) / outStack.count))
            return math.max(byProd, byStock)
        end

        local function handleBatchResult(ok, detail)
            if detail then
                noteProduced(detail, 0)
            end
            if ok then
                return true
            end
            -- Partial oneshot progress: keep going for the rest.
            if detail and detail.error == "craft_short" and not fulfilled() then
                return true
            end
            stop[1] = true
            stop[2] = detail
            return false
        end

        local function consumerCraft()
            while not shouldStop() do
                local rem = remainingRuns()
                if rem <= 0 then
                    return
                end
                local ready = countCompleteSets(recipe, store, opts)
                local n = math.min(ready, rem)
                if n > 0 then
                    local ok, detail = runCraftBatch(
                        recipe, machine, recipeKey, store, opts, itemId, amount, outStack, log, n
                    )
                    if not handleBatchResult(ok, detail) then
                        return
                    end
                else
                    sleep(0.25)
                end
            end
        end

        local function isSoftEnsureErr(err)
            if type(err) ~= "table" then
                return false
            end
            local e = err
            -- craft.request wraps as { error = inner }; ensure may return inner directly
            for _ = 1, 3 do
                if type(e) ~= "table" then
                    break
                end
                if e.error == "craft_short" then
                    return true
                end
                if e.error == "missing_input" and e.missing then
                    return #hardMissingInputs(list, { e.missing }) == 0
                end
                if type(e.error) == "table" then
                    e = e.error
                else
                    break
                end
            end
            return false
        end

        local function producerGather()
            while not shouldStop() do
                local rem = remainingRuns()
                if rem <= 0 then
                    return
                end
                local ready = countCompleteSets(recipe, store, opts)
                if ready >= rem then
                    sleep(0.25)
                else
                    local wantSets = math.min(rem, ready + 1)
                    local okIn, errIn = ensureInputsParallel(
                        list, recipe, wantSets, opts, visiting, log, cancelled
                    )
                    if not okIn then
                        if isSoftEnsureErr(errIn) then
                            sleep(0.25)
                        else
                            stop[1] = true
                            stop[2] = errIn
                            return
                        end
                    elseif countCompleteSets(recipe, store, opts) < 1 and not shouldStop() then
                        -- Empty after ensure: often consumed by oven. Abort only on leaf shortages.
                        local stillMissing = findMissingInputs(recipe, store, opts, 1)
                        local hard = hardMissingInputs(list, stillMissing)
                        if #hard > 0 then
                            stop[1] = true
                            stop[2] = {
                                error = "missing_input",
                                missing = hard[1],
                                missing_all = hard,
                            }
                            return
                        end
                    end
                    sleep(0.05)
                end
            end
        end

        if recipeHasCraftableInputs(recipe) then
            parallel.waitForAll(producerGather, consumerCraft)
        else
            while not shouldStop() do
                local rem = remainingRuns()
                if rem <= 0 then
                    break
                end
                local ready = countCompleteSets(recipe, store, opts)
                local n = math.min(ready, rem)
                if n > 0 then
                    local ok, detail = runCraftBatch(
                        recipe, machine, recipeKey, store, opts, itemId, amount, outStack, log, n
                    )
                    if not handleBatchResult(ok, detail) then
                        return fail(detail)
                    end
                else
                    local stillMissing = findMissingInputs(recipe, store, opts, 1)
                    if #stillMissing > 0 then
                        return fail({
                            error = "missing_input",
                            missing = stillMissing[1],
                            missing_all = stillMissing,
                        })
                    end
                    sleep(0.5)
                end
            end
        end

        if stop[1] then
            return fail(stop[2])
        end
    end

    visiting[itemId] = nil

    if not fulfilled() then
        return false, {
            error = "craft_short",
            missing = { name = itemId, count = math.max(1, need - produced) },
        }
    end

    return true
end

---------------------------------------------------------------------------
-- Public request API
---------------------------------------------------------------------------

--- Craft/grow until at least `amount` of the output item is available.
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

    local ok, err = ensure(list, itemId, before + amount, ensureOpts, {}, log, { false, nil })
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
