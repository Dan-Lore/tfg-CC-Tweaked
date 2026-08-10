-- Recipe index, depth, top-down demand, bottom-up ready jobs (one stock snapshot per tick).

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

--- Build once per craft.request: recipeByOutput, depth, children.
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

    -- Prefer findByOutput if provided (same order as craft.findByOutput).
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
        if depthMemo[itemId] then
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

--- Top-down demand. Root uses produce-N (ignores fridge); intermediates use have+inflight.
-- Returns: need[item]=wantUnits, deficit[item]=stillProduce, hard missing or nil
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
            if input.fluid then
                local haveF, info = snap.fluid(input.name)
                local ready = craft_stock.countCompleteSets(recipe, snap.store, snap.opts, snap)
                if (not info or haveF < input.count) and ready < 1 then
                    hard = {
                        error = "missing_input",
                        missing = {
                            name = input.name,
                            count = input.count - (haveF or 0),
                            fluid = true,
                            error = (not info) and "no_fluid_source" or nil,
                        },
                    }
                end
            elseif craft_stock.isCraftableName(input.name) then
                if index.byOutput[input.name] then
                    consider(input.name, input.count * runsWanted)
                else
                    local haveI = snap.item(input.name)
                    if haveI < input.count * runsWanted then
                        local ready = craft_stock.countCompleteSets(recipe, snap.store, snap.opts, snap)
                        if ready < 1 then
                            hard = {
                                error = "missing_input",
                                missing = {
                                    name = input.name,
                                    count = input.count * runsWanted - haveI,
                                    fluid = false,
                                },
                            }
                        end
                    end
                end
            else
                local haveI = snap.item(input.name)
                if haveI < input.count * runsWanted then
                    local ready = craft_stock.countCompleteSets(recipe, snap.store, snap.opts, snap)
                    if ready < 1 then
                        hard = {
                            error = "missing_input",
                            missing = {
                                name = input.name,
                                count = input.count * runsWanted - haveI,
                                fluid = false,
                                tag = true,
                            },
                        }
                    end
                end
            end
        end

        visiting[itemId] = nil
    end

    consider(rootItemId, rootStill)
    return need, deficit, hard
end

--- Ready jobs sorted depth DESC, batch DESC, itemId ASC. One job per machine after sort.
-- reservedMachines: recipeKey already running on machine (allow same-key stack only).
function craft_plan.readyJobs(index, deficit, snap, resolveMachine, reservedMachines, rootItemId)
    local candidates = {}

    for itemId, still in pairs(deficit) do
        if still and still > 0 then
            local entry = index.byOutput[itemId]
            if entry then
                local recipe = entry.recipe
                local outStack = entry.outStack
                local per = outStack.count
                local ready = craft_stock.countCompleteSets(recipe, snap.store, snap.opts, snap)
                if ready >= 1 then
                    local machine = resolveMachine(recipe)
                    local recipeKey = recipes.recipeKey(recipe)
                    local reserved = reservedMachines and reservedMachines[machine]
                    local okMachine = machine
                        and machine_lock.canStack(machine, recipeKey)
                        and (not reserved or reserved == recipeKey)
                    if okMachine then
                        local runsWanted = math.ceil(still / per)
                        local times = batchTimes(recipe, ready, runsWanted)
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
                        }
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.depth ~= b.depth then
            return a.depth > b.depth
        end
        if a.times ~= b.times then
            return a.times > b.times
        end
        return a.itemId < b.itemId
    end)

    local jobs = {}
    local seenMachine = {}
    for i = 1, #candidates do
        local job = candidates[i]
        if not seenMachine[job.machine] then
            -- Prefer deepest/largest batch; skip if another worker already holds a different key.
            if not machine_lock.isBusy(job.machine) or machine_lock.keyOf(job.machine) == job.recipeKey then
                seenMachine[job.machine] = true
                jobs[#jobs + 1] = job
            end
        end
    end

    return jobs
end

return craft_plan
