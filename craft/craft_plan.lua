-- Recipe index, depth, top-down demand, bottom-up ready jobs.

local recipes = require("recipes")
local craft_stock = require("craft_stock")
local machine_lock = require("machine_lock")

local craft_plan = {}

local function batchTimes(recipe, ready, runsWanted)
    if recipe.flag == "grow" or recipe.oneshot == true then
        return 1
    end
    return math.max(1, math.min(ready, runsWanted))
end

--- Build once per craft.request: recipeByOutput, depth.
function craft_plan.buildIndex(list, findByOutput)
    local byOutput = {}
    for i = 1, #list do
        local recipe = list[i]
        for j = 1, #recipe.outputs do
            local out = recipe.outputs[j]
            if not out.fluid and not byOutput[out.name] then
                byOutput[out.name] = {
                    recipe = recipe,
                    outStack = out,
                }
            end
        end
    end

    if findByOutput then
        for name in pairs(byOutput) do
            local recipe, outStack = findByOutput(list, name)
            if recipe and outStack then
                byOutput[name] = { recipe = recipe, outStack = outStack }
            end
        end
    end

    local depthMemo = {}
    local visiting = {}

    local function depthOf(itemId)
        if depthMemo[itemId] ~= nil then
            return depthMemo[itemId]
        end
        if visiting[itemId] then
            return 0
        end
        local entry = byOutput[itemId]
        if not entry then
            depthMemo[itemId] = 0
            return 0
        end
        visiting[itemId] = true
        local maxChild = 0
        local recipe = entry.recipe
        for i = 1, #recipe.inputs do
            local input = recipe.inputs[i]
            if not input.fluid and craft_stock.isCraftableName(input.name) and byOutput[input.name] then
                local d = depthOf(input.name)
                if d > maxChild then
                    maxChild = d
                end
            end
        end
        visiting[itemId] = nil
        depthMemo[itemId] = maxChild + 1
        return depthMemo[itemId]
    end

    for name in pairs(byOutput) do
        depthOf(name)
    end

    return {
        byOutput = byOutput,
        depth = depthMemo,
    }
end

function craft_plan.batchTimes(recipe, ready, runsWanted)
    return batchTimes(recipe, ready, runsWanted)
end

--- Collect item/fluid names reachable from root (for snapshot preload). Lightweight, no peripherals.
function craft_plan.collectNames(index, rootItemId)
    local items = {}
    local fluids = {}
    local seenItem = {}
    local seenFluid = {}
    local visiting = {}

    local function addItem(name)
        if name and not seenItem[name] then
            seenItem[name] = true
            items[#items + 1] = name
        end
    end

    local function addFluid(name)
        if name and not seenFluid[name] then
            seenFluid[name] = true
            fluids[#fluids + 1] = name
        end
    end

    local function walk(itemId)
        if not itemId or visiting[itemId] then
            return
        end
        visiting[itemId] = true
        addItem(itemId)
        local entry = index.byOutput[itemId]
        if not entry then
            visiting[itemId] = nil
            return
        end
        local recipe = entry.recipe
        for i = 1, #recipe.inputs do
            local input = recipe.inputs[i]
            if input.fluid then
                addFluid(input.name)
            else
                addItem(input.name)
                if craft_stock.isCraftableName(input.name) and index.byOutput[input.name] then
                    walk(input.name)
                end
            end
        end
        visiting[itemId] = nil
    end

    walk(rootItemId)
    return items, fluids
end

--- Top-down demand using snap only (no extra peripheral scans).
function craft_plan.computeDemand(index, rootItemId, rootStill, snap, inflight)
    local need = {}
    local deficit = {}
    local hard = nil
    local visiting = {}

    local function consider(itemId, wantUnits)
        if wantUnits <= 0 or visiting[itemId] then
            return
        end
        visiting[itemId] = true

        local entry = index.byOutput[itemId]
        if not entry then
            visiting[itemId] = nil
            return
        end

        local recipe = entry.recipe
        local outStack = entry.outStack
        local per = outStack.count
        if not per or per <= 0 then
            visiting[itemId] = nil
            return
        end
        local isRoot = itemId == rootItemId
        local have = snap.item(itemId)
        local inFlight = (inflight and inflight[itemId]) or 0

        local still
        if isRoot then
            still = math.max(0, rootStill - inFlight)
        else
            still = math.max(0, wantUnits - have - inFlight)
        end

        need[itemId] = math.max(need[itemId] or 0, wantUnits)
        if still <= 0 then
            deficit[itemId] = 0
            visiting[itemId] = nil
            return
        end
        deficit[itemId] = math.max(deficit[itemId] or 0, still)

        local runsWanted = math.ceil(still / per)

        for i = 1, #recipe.inputs do
            local input = recipe.inputs[i]
            local needAmt = input.count * runsWanted
            if input.fluid then
                local haveF, info = snap.fluid(input.name)
                if not info then
                    hard = {
                        error = "missing_input",
                        missing = {
                            name = input.name,
                            count = needAmt,
                            fluid = true,
                            error = "no_fluid_source",
                        },
                    }
                elseif haveF < input.count then
                    -- Only hard-fail when not even one set can run.
                    hard = hard or {
                        error = "missing_input",
                        missing = {
                            name = input.name,
                            count = input.count - haveF,
                            fluid = true,
                        },
                    }
                end
            elseif craft_stock.isCraftableName(input.name) then
                if index.byOutput[input.name] then
                    consider(input.name, needAmt)
                else
                    local haveI = snap.item(input.name)
                    if haveI < input.count then
                        hard = hard or {
                            error = "missing_input",
                            missing = {
                                name = input.name,
                                count = input.count - haveI,
                                fluid = false,
                            },
                        }
                    end
                end
            else
                local haveI = snap.item(input.name)
                if haveI < input.count then
                    hard = hard or {
                        error = "missing_input",
                        missing = {
                            name = input.name,
                            count = input.count - haveI,
                            fluid = false,
                            tag = true,
                        },
                    }
                end
            end
        end

        visiting[itemId] = nil
    end

    consider(rootItemId, rootStill)
    return need, deficit, hard
end

--- Ready jobs sorted depth DESC, batch DESC, itemId ASC.
function craft_plan.readyJobs(index, deficit, snap, resolveMachine, reservedMachines, rootItemId)
    local candidates = {}

    for itemId, still in pairs(deficit) do
        if still and still > 0 then
            local entry = index.byOutput[itemId]
            if entry then
                local recipe = entry.recipe
                local outStack = entry.outStack
                local per = outStack.count
                if per and per > 0 then
                local ready = craft_stock.countCompleteSets(recipe, snap.store, snap.opts, snap)
                if ready >= 1 then
                    local machine = resolveMachine(recipe)
                    sleep(0)
                    local recipeKey = recipes.recipeKey(recipe)
                        local reserved = reservedMachines and reservedMachines[machine]
                        local okMachine = machine
                            and machine_lock.canStack(machine, recipeKey)
                            and (not reserved or reserved == recipeKey)
                        if okMachine then
                        local runsWanted = math.ceil(still / per)
                        local times = batchTimes(recipe, ready, runsWanted)
                        local have = snap.item(itemId)
                        -- Absolute want for intermediates (deficit already subtracted have once).
                        local wantUnits = still
                        if itemId ~= rootItemId then
                            wantUnits = still + have
                        end
                        candidates[#candidates + 1] = {
                            itemId = itemId,
                            recipe = recipe,
                            outStack = outStack,
                            machine = machine,
                            recipeKey = recipeKey,
                            isRoot = itemId == rootItemId,
                            runsWanted = runsWanted,
                            times = times,
                            depth = index.depth[itemId] or 0,
                            deficit = still,
                            wantUnits = wantUnits,
                        }
                        end
                    end
                end
            end
        end
        sleep(0) -- yield while scanning candidates
    end

    table.sort(candidates, function(a, b)
        if a.depth ~= b.depth then
            return a.depth > b.depth
        end
        if a.times ~= b.times then
            return a.times > b.times
        end
        return tostring(a.itemId) < tostring(b.itemId)
    end)

    local jobs = {}
    local seenMachine = {}
    for i = 1, #candidates do
        local job = candidates[i]
        if job.machine and not seenMachine[job.machine] then
            if not machine_lock.isBusy(job.machine) or machine_lock.keyOf(job.machine) == job.recipeKey then
                seenMachine[job.machine] = true
                jobs[#jobs + 1] = job
            end
        end
    end

    return jobs
end

return craft_plan
