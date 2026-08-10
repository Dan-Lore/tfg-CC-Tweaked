-- Feed / drain / craft.run for processing recipes.
-- Burst-pushes complete sets; short poll only while waiting on the machine.

local transfer = require("transfer")
local craft_stock = require("craft_stock")

local craft_io = {}

local DEFAULT_CRAFT_WAIT = 300

function craft_io.outputDest(store, recipe, itemName, fallbackOut)
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

function craft_io.pullItemAmount(from, itemName, amount, store, fallbackOut, recipe)
    amount = tonumber(amount) or 0
    if amount <= 0 or not from then
        return 0
    end
    local dest = craft_io.outputDest(store, recipe, itemName, fallbackOut)
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

function craft_io.pullOutputs(from, stacks, store, fallbackOut, recipe)
    local moved = {}
    for i = 1, #stacks do
        local stack = stacks[i]
        if not stack.fluid then
            local n = craft_io.pullItemAmount(from, stack.name, stack.count, store, fallbackOut, recipe)
            moved[stack.name] = (moved[stack.name] or 0) + n
        end
    end
    return moved
end

--- Rollback items from machine into storage pull-sources (as destinations).
function craft_io.rollbackItems(machine, movedItems, store, opts)
    for name, count in pairs(movedItems) do
        if count and count > 0 then
            local dests = craft_stock.pullSourcesFor(store, name, opts)
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
function craft_io.setAvailable(recipe, store, opts)
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        if input.fluid then
            local have, info = craft_stock.countFluidAvailable(store, input.name)
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
            local have = craft_stock.countAvailable(store, input.name, opts)
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
function craft_io.pushOneSet(recipe, machine, store, opts)
    local okAvail, missing = craft_io.setAvailable(recipe, store, opts)
    if not okAvail then
        return false, {}, missing
    end

    local movedItems = {}
    local movedFluids = {}

    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        if not input.fluid then
            local sources = craft_stock.pullSourcesFor(store, input.name, opts)
            local n = transfer.fromMany(sources, machine, input.name, input.count)
            movedItems[input.name] = (movedItems[input.name] or 0) + n
            if n < input.count then
                craft_io.rollbackItems(machine, movedItems, store, opts)
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
            local _, info = craft_stock.countFluidAvailable(store, input.name)
            if not info then
                craft_io.rollbackItems(machine, movedItems, store, opts)
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
                craft_io.rollbackItems(machine, movedItems, store, opts)
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

function craft_io.craftWaitTimeout(opts, times)
    times = math.max(1, math.floor(tonumber(times) or 1))
    local base = opts and opts.craftWaitTimeout
    if not base and opts and opts.waitTicks and opts.waitTicks > 0 then
        base = opts.waitTicks / 20
    end
    base = tonumber(base) or DEFAULT_CRAFT_WAIT
    return base * times
end

function craft_io.drainToward(pullFrom, need, pulled, store, fallbackOut, recipe)
    local complete = true
    for name, want in pairs(need) do
        local remaining = want - (pulled[name] or 0)
        if remaining > 0 then
            local n = craft_io.pullItemAmount(pullFrom, name, remaining, store, fallbackOut, recipe)
            pulled[name] = (pulled[name] or 0) + n
            if pulled[name] < want then
                complete = false
            end
        end
    end
    return complete
end

function craft_io.buildNeedMap(outputs, times)
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

--- Set-by-set feed + continuous drain. Does not take the machine lock.
function craft_io.run(recipe, opts)
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
    local missingList = craft_stock.findMissingInputs(recipe, store, opts, times)
    if #missingList > 0 then
        return false, {
            error = "missing_input",
            missing = missingList[1],
            missing_all = missingList,
        }
    end

    local oneshot = recipe.oneshot == true
    local targetSets = times
    local need, anyItem = craft_io.buildNeedMap(recipe.outputs, targetSets)
    local pulled = {}
    for name in pairs(need) do
        pulled[name] = 0
    end

    local pullFrom = opts.pullFrom or opts.machine
    local timeout = craft_io.craftWaitTimeout(opts, times)
    local deadline = os.clock() + timeout
    local setsPushed = 0
    local movedTotals = {}
    local lastMissing = nil
    local pushing = true
    local stallSince = nil -- os.clock when stock-short stall began
    local POLL = 0.05
    local STALL_STOP_PUSH = 6 -- seconds
    local STALL_FAIL = 10 -- seconds

    local function rebuildNeed(sets)
        need, anyItem = craft_io.buildNeedMap(recipe.outputs, sets)
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

    local function readyForNextSet()
        if not oneshot or setsPushed == 0 then
            return true
        end
        if not anyItem then
            return true
        end
        local needSoFar = craft_io.buildNeedMap(recipe.outputs, setsPushed)
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

    local function emitSetsProgress()
        if opts and type(opts.onSetsProgress) == "function" then
            pcall(opts.onSetsProgress, setsPushed, targetSets, pulled)
        end
    end

    while os.clock() < deadline do
        craft_io.drainToward(pullFrom, need, pulled, store, out, recipe)
        emitSetsProgress()
        if outputsComplete() then
            return finishOk()
        end

        -- Burst: push as many sets as possible without sleeping between successes.
        while pushing and setsPushed < targetSets and readyForNextSet() and os.clock() < deadline do
            local ok, moved, missing = craft_io.pushOneSet(recipe, opts.machine, store, opts)
            if ok then
                setsPushed = setsPushed + 1
                stallSince = nil
                for k, v in pairs(moved) do
                    movedTotals[k] = (movedTotals[k] or 0) + v
                end
                emitSetsProgress()
                craft_io.drainToward(pullFrom, need, pulled, store, out, recipe)
                if outputsComplete() then
                    return finishOk()
                end
                -- oneshot: stop burst until this set's outputs are pulled
                if oneshot then
                    break
                end
            else
                lastMissing = missing
                if missing and missing.error == "push_short" then
                    -- Machine input full: wait briefly for GT to consume.
                    stallSince = nil
                else
                    if not stallSince then
                        stallSince = os.clock()
                    end
                    local stalledFor = os.clock() - stallSince
                    if setsPushed > 0 and stalledFor > STALL_STOP_PUSH then
                        pushing = false
                        targetSets = setsPushed
                        rebuildNeed(targetSets)
                    elseif setsPushed == 0 and stalledFor > STALL_FAIL then
                        return false, {
                            error = "missing_input",
                            missing = missing,
                            moved = movedTotals,
                            times = times,
                            sets_pushed = setsPushed,
                        }
                    end
                end
                break
            end
        end

        if outputsComplete() then
            return finishOk()
        end
        -- Brief yield while waiting on GT / oneshot / stock.
        sleep(POLL)
    end

    craft_io.drainToward(pullFrom, need, pulled, store, out, recipe)
    emitSetsProgress()
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

return craft_io
