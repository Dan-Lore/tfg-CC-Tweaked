-- Goal stack + resource monitor: craft root amount via crafted counter.

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

local function activityText(recipe, itemId)
    local out = recipes.primaryOutput(recipe)
    local n = out and out.count or 1
    local name = itemId:match("([^/]+)$") or itemId
    if recipe.flag == "grow" then
        return "grow " .. name .. " x" .. tostring(n)
    end
    return name .. " x" .. tostring(n)
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
                if machine and not machine_lock.isBusy(machine) and not seenMachine[machine] then
                    local should = isRoot or (have < wantUnits)
                    if should then
                        seenMachine[machine] = true
                        candidates[#candidates + 1] = {
                            itemId = itemId,
                            recipe = recipe,
                            outStack = outStack,
                            machine = machine,
                            recipeKey = recipes.recipeKey(recipe),
                            isRoot = isRoot,
                        }
                    end
                end
            end

            visiting[itemId] = nil
        end

        consider(rootItemId, rootWant - rootCrafted)
        return candidates, hard
    end

    local function runOne(job)
        emitActivity(opts, activityText(job.recipe, job.itemId))
        local ok, detail = machine_lock.tryLock(job.machine, job.recipeKey, function()
            if job.recipe.flag == "grow" then
                return deps.runGrow(job.recipe, job.machine, opts)
            end
            return deps.run(job.recipe, {
                from = opts.from,
                out = opts.out,
                store = store,
                machine = job.machine,
                pullFrom = opts.pullFrom,
                waitTicks = opts.waitTicks,
                craftWaitTimeout = opts.craftWaitTimeout,
                times = 1,
            })
        end)

        if detail and detail.error == "busy" then
            return true
        end
        if not ok then
            return false, detail
        end
        if detail and detail.skipped then
            return true
        end

        local gained = job.outStack.count
        if detail and detail.sets_pushed and detail.sets_pushed > 0 then
            gained = job.outStack.count * detail.sets_pushed
        elseif detail and detail.times then
            gained = job.outStack.count * detail.times
        end

        if job.isRoot then
            rootCrafted = rootCrafted + gained
            emitProgress(opts, rootCrafted, rootWant)
        end

        log[#log + 1] = {
            item = job.itemId,
            machine = job.machine,
            flag = job.recipe.flag,
            detail = detail,
            times = 1,
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
