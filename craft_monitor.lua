-- Goal stack + resource monitor: craft root amount via crafted counter.
-- Non-oneshot processing: batch max complete sets (min resource); oneshot/grow: 1.
-- Same recipe on a busy machine stacks (queues); different recipe waits elsewhere.

local transfer = require("transfer")
local recipes = require("recipes")
local craft_stock = require("craft_stock")
local machine_lock = require("machine_lock")

local craft_monitor = {}

local function emitActivity(opts, text)
    if opts and type(opts.onActivity) == "function" then
        pcall(opts.onActivity, text)
    end
end

local function emitProgress(opts, done, total)
    if opts and type(opts.onProgress) == "function" then
        pcall(opts.onProgress, done, total)
    end
end

local function activityText(recipe, itemId, times)
    times = math.max(1, math.floor(tonumber(times) or 1))
    local out = recipes.primaryOutput(recipe)
    local n = (out and out.count or 1) * times
    local name = itemId:match("([^/]+)$") or itemId
    if recipe.flag == "grow" then
        return "grow " .. name .. " x" .. tostring(n)
    end
    return name .. " x" .. tostring(n)
end

--- How many recipe runs to push now.
-- oneshot / grow → 1; else min(stock complete sets, runs still needed).
local function batchTimes(recipe, ready, runsWanted)
    if recipe.flag == "grow" or recipe.oneshot == true then
        return 1
    end
    return math.max(1, math.min(ready, runsWanted))
end

--- deps: findByOutput(list,id), resolveMachine(recipe), run(recipe,opts), runGrow(recipe,machine,opts)
function craft_monitor.request(deps, list, rootItemId, amount, opts, log)
    local store = opts.store
    local rootWant = amount
    local rootCrafted = 0
    local hardSticky = nil

    local function rootDone()
        return rootCrafted >= rootWant
    end

    local function gather()
        local candidates = {}
        local seenMachine = {}
        local visiting = {}
        local hard = nil

        local function consider(itemId, wantUnits)
            if wantUnits <= 0 or visiting[itemId] then
                return
            end
            visiting[itemId] = true

            local recipe, outStack = deps.findByOutput(list, itemId)
            if not recipe or not outStack then
                visiting[itemId] = nil
                return
            end

            local per = outStack.count
            local isRoot = itemId == rootItemId
            local have = craft_stock.countAvailable(store, itemId, opts)
            local stillProduce
            if isRoot then
                stillProduce = rootWant - rootCrafted
            else
                stillProduce = wantUnits - have
            end
            if stillProduce <= 0 then
                visiting[itemId] = nil
                return
            end

            local runsWanted = math.ceil(stillProduce / per)

            for i = 1, #recipe.inputs do
                local input = recipe.inputs[i]
                if input.fluid then
                    local haveF, info = craft_stock.countFluidAvailable(store, input.name)
                    if (not info or haveF < input.count) and craft_stock.countCompleteSets(recipe, store, opts) < 1 then
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
                    local childRecipe = deps.findByOutput(list, input.name)
                    if childRecipe then
                        consider(input.name, input.count * runsWanted)
                    else
                        local haveI = craft_stock.countAvailable(store, input.name, opts)
                        if haveI < input.count * runsWanted then
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
                else
                    local sources = craft_stock.pullSourcesFor(store, input.name, opts)
                    local haveI = transfer.countFromMany(sources, input.name)
                    if haveI < input.count * runsWanted then
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

            local ready = craft_stock.countCompleteSets(recipe, store, opts)
            if ready >= 1 then
                local machine = deps.resolveMachine(recipe)
                local recipeKey = recipes.recipeKey(recipe)
                -- Free, or same recipe already on machine (stack/queue).
                if machine and machine_lock.canStack(machine, recipeKey) and not seenMachine[machine] then
                    local should = isRoot or (have < wantUnits)
                    if should then
                        seenMachine[machine] = true
                        candidates[#candidates + 1] = {
                            itemId = itemId,
                            recipe = recipe,
                            outStack = outStack,
                            machine = machine,
                            recipeKey = recipeKey,
                            isRoot = isRoot,
                            runsWanted = runsWanted,
                            times = batchTimes(recipe, ready, runsWanted),
                        }
                    end
                end
            end

            visiting[itemId] = nil
        end

        consider(rootItemId, rootWant - rootCrafted)
        return candidates, hard
    end

    local function runsStillNeeded(job)
        local per = job.outStack.count
        if job.isRoot then
            return math.ceil(math.max(0, rootWant - rootCrafted) / per)
        end
        local have = craft_stock.countAvailable(store, job.itemId, opts)
        -- Cap by what gather asked for this tick (avoid overproducing siblings).
        local wantUnits = job.runsWanted * per
        local still = math.max(0, wantUnits - have)
        return math.ceil(still / per)
    end

    local function unitsFromDetail(job, detail, fallbackSets)
        local per = job.outStack.count
        if detail and detail.outputs and detail.outputs[job.itemId] then
            return detail.outputs[job.itemId]
        end
        local sets = fallbackSets or 0
        if detail and detail.sets_pushed and detail.sets_pushed > 0 then
            sets = detail.sets_pushed
        elseif detail and detail.times and detail.times > 0 then
            sets = detail.times
        end
        if sets < 1 then
            sets = 1
        end
        return per * sets
    end

    local function runOne(job)
        local times = job.times or 1
        emitActivity(opts, activityText(job.recipe, job.itemId, times))
        local ok, detail = machine_lock.runOrStack(job.machine, job.recipeKey, function()
            if job.recipe.flag == "grow" then
                local gOk, gDetail = deps.runGrow(job.recipe, job.machine, opts)
                if gOk and job.isRoot then
                    -- Grow finishes in one pulse; bump progress when pull completes.
                    local gained = unitsFromDetail(job, gDetail, 1)
                    emitProgress(opts, math.min(rootWant, rootCrafted + gained), rootWant)
                end
                return gOk, gDetail
            end
            -- Recompute batch under lock (stock / progress may have changed while queued).
            local runsLeft = runsStillNeeded(job)
            local ready = craft_stock.countCompleteSets(job.recipe, store, opts)
            if ready < 1 or runsLeft < 1 then
                return false, { error = "skipped", skipped = true }
            end
            local batch = batchTimes(job.recipe, ready, runsLeft)
            emitActivity(opts, activityText(job.recipe, job.itemId, batch))
            return deps.run(job.recipe, {
                from = opts.from,
                out = opts.out,
                store = store,
                machine = job.machine,
                pullFrom = opts.pullFrom,
                waitTicks = opts.waitTicks,
                craftWaitTimeout = opts.craftWaitTimeout,
                times = batch,
                onSetsProgress = function(setsPushed, _targetSets, pulled)
                    if not job.isRoot then
                        return
                    end
                    local fromPulled = pulled and pulled[job.itemId]
                    local gained = fromPulled or (job.outStack.count * (setsPushed or 0))
                    emitProgress(opts, math.min(rootWant, rootCrafted + gained), rootWant)
                end,
            })
        end)

        if type(detail) == "table" and detail.error == "busy" then
            return true
        end
        if not ok then
            if type(detail) == "table" and detail.skipped then
                return true
            end
            return false, detail
        end
        if type(detail) == "table" and detail.skipped then
            return true
        end

        local gained = unitsFromDetail(job, detail, times)

        if job.isRoot then
            rootCrafted = rootCrafted + gained
            emitProgress(opts, math.min(rootWant, rootCrafted), rootWant)
        end

        log[#log + 1] = {
            item = job.itemId,
            machine = job.machine,
            flag = job.recipe.flag,
            detail = detail,
            times = (type(detail) == "table" and detail.sets_pushed) or times,
        }
        return true
    end

    emitProgress(opts, 0, rootWant)
    emitActivity(opts, "planning...")

    while not rootDone() do
        local candidates, hard = gather()
        if hard then
            hardSticky = hard
        end

        if #candidates == 0 then
            if hardSticky and not machine_lock.busyAny() then
                return false, hardSticky
            end
            emitActivity(opts, "waiting...")
            sleep(0.35)
        else
            hardSticky = nil
            if #candidates == 1 then
                local ok, err = runOne(candidates[1])
                if not ok then
                    return false, err
                end
            else
                local firstErr = nil
                local funcs = {}
                for i = 1, #candidates do
                    local job = candidates[i]
                    funcs[i] = function()
                        if firstErr then
                            return
                        end
                        local ok, err = runOne(job)
                        if not ok and not firstErr then
                            firstErr = err
                        end
                    end
                end
                parallel.waitForAll(table.unpack(funcs))
                if firstErr then
                    return false, firstErr
                end
            end
        end
    end

    return true, rootCrafted
end

return craft_monitor
