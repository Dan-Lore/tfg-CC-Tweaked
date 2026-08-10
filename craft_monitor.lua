-- Continuous craft monitor: top-down demand, bottom-up dispatch.
-- Planning uses inventory snapshot + cached machine resolve; steps logged via craft_log.

local recipes = require("recipes")
local craft_stock = require("craft_stock")
local craft_plan = require("craft_plan")
local machine_lock = require("machine_lock")
local craft_log = require("craft_log")

local craft_monitor = {}

local IDLE_SLEEP = 0.05

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

local function log(msg)
    pcall(craft_log.write, msg)
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

local function unitsFromDetail(job, detail, fallbackSets)
    local per = job.outStack.count
    if detail and detail.outputs then
        local n = detail.outputs[job.itemId]
        if type(n) == "number" and n > 0 then
            return n
        end
    end
    local sets = 0
    if detail and detail.sets_pushed and detail.sets_pushed > 0 then
        sets = detail.sets_pushed
    elseif detail and detail.times and detail.times > 0 then
        sets = detail.times
    elseif fallbackSets and fallbackSets > 0 then
        sets = fallbackSets
    end
    if sets < 1 then
        return 0
    end
    return per * sets
end

local function planTick(deps, index, store, opts, rootItemId, rootStill, inflight, preloadItems, preloadFluids, machineCache)
    log("plan snap")
    local snap = craft_stock.snapshot(store, opts, preloadItems, preloadFluids)
    log("plan demand")
    local _need, deficit, hard = craft_plan.computeDemand(
        index,
        rootItemId,
        rootStill,
        snap,
        inflight
    )
    local nDef = 0
    for _ in pairs(deficit) do
        nDef = nDef + 1
    end
    log("deficits " .. tostring(nDef))
    log("plan jobs")
    local resolve = function(recipe)
        return deps.resolveMachine(recipe, machineCache)
    end
    local jobs = craft_plan.readyJobs(
        index,
        deficit,
        snap,
        resolve,
        nil,
        rootItemId
    )
    log("jobs " .. tostring(#jobs))
    return {
        deficit = deficit,
        hard = hard,
        jobs = jobs,
    }
end

--- deps: findByOutput, resolveMachine, run, runGrow
function craft_monitor.request(deps, list, rootItemId, amount, opts, logSteps)
    local store = opts.store
    local rootWant = amount
    local rootCrafted = 0
    local hardSticky = nil
    local inflight = {}
    local machineCache = {}

    log("index build")
    local index = craft_plan.buildIndex(list, deps.findByOutput)
    log("collect names")
    local preloadItems, preloadFluids = craft_plan.collectNames(index, rootItemId)
    log("items " .. tostring(#preloadItems) .. " fluids " .. tostring(#preloadFluids))

    log("cache machines")
    for _, entry in pairs(index.byOutput) do
        deps.resolveMachine(entry.recipe, machineCache)
        sleep(0)
    end
    log("machines ok")

    local function rootDone()
        return rootCrafted >= rootWant
    end

    local function runsStillNeeded(job)
        local per = job.outStack.count
        if per <= 0 then
            return 0
        end
        if job.isRoot then
            return math.ceil(math.max(0, rootWant - rootCrafted) / per)
        end
        local have = craft_stock.countAvailable(store, job.itemId, opts)
        local reserved = job.reserved or 0
        local others = math.max(0, (inflight[job.itemId] or 0) - reserved)
        local still = math.max(0, (job.runsWanted * per) - have - others)
        return math.ceil(still / per)
    end

    local function executeJob(job)
        local ok, detail = machine_lock.runOrStack(job.machine, job.recipeKey, function()
            if job.recipe.flag == "grow" then
                if not job.isRoot then
                    local have = craft_stock.countAvailable(store, job.itemId, opts)
                    if have >= (job.deficit or 0) then
                        return false, { error = "skipped", skipped = true }
                    end
                elseif rootCrafted >= rootWant then
                    return false, { error = "skipped", skipped = true }
                end
                emitActivity(opts, activityText(job.recipe, job.itemId, 1))
                log("grow " .. (job.itemId:match("([^/]+)$") or job.itemId))
                return deps.runGrow(job.recipe, job.machine, opts)
            end

            local runsLeft = runsStillNeeded(job)
            local ready = craft_stock.countCompleteSets(job.recipe, store, opts)
            if ready < 1 or runsLeft < 1 then
                return false, { error = "skipped", skipped = true }
            end
            local batch = craft_plan.batchTimes(job.recipe, ready, runsLeft)
            local label = activityText(job.recipe, job.itemId, batch)
            emitActivity(opts, label)
            log("run " .. label)
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
                    local gained = 0
                    if type(fromPulled) == "number" and fromPulled > 0 then
                        gained = fromPulled
                    elseif setsPushed and setsPushed > 0 then
                        gained = job.outStack.count * setsPushed
                    end
                    if gained > 0 then
                        emitProgress(opts, math.min(rootWant, rootCrafted + gained), rootWant)
                    end
                end,
            })
        end)

        if type(detail) == "table" and (detail.error == "busy" or detail.skipped) then
            return true, detail, 0
        end
        if not ok then
            return false, detail, 0
        end
        return true, detail, unitsFromDetail(job, detail, job.times)
    end

    local function applyResult(job, ok, detail, gained)
        local reserved = job.reserved or 0
        inflight[job.itemId] = math.max(0, (inflight[job.itemId] or 0) - reserved)

        if not ok then
            if type(detail) == "table" and (detail.skipped or detail.error == "busy") then
                return nil
            end
            return detail or { error = "craft_failed" }
        end

        if gained and gained > 0 then
            log("ok +" .. tostring(gained) .. " " .. (job.itemId:match("([^/]+)$") or ""))
            if job.isRoot then
                rootCrafted = rootCrafted + gained
                emitProgress(opts, math.min(rootWant, rootCrafted), rootWant)
            end
            logSteps[#logSteps + 1] = {
                item = job.itemId,
                machine = job.machine,
                flag = job.recipe.flag,
                detail = detail,
                times = (type(detail) == "table" and detail.sets_pushed) or job.times,
            }
        end
        return nil
    end

    local function safeRun(job, slot)
        local ran, ok, detail, gained = pcall(function()
            return executeJob(job)
        end)
        if not ran then
            slot.ok = false
            slot.detail = {
                error = "exception",
                missing = { name = tostring(ok), count = 1 },
            }
            slot.gained = 0
            log("ERR " .. tostring(ok))
            return
        end
        slot.ok = ok
        slot.detail = detail
        slot.gained = gained or 0
    end

    emitProgress(opts, 0, rootWant)
    emitActivity(opts, "planning...")
    log("request " .. (rootItemId:match("([^/]+)$") or rootItemId) .. " x" .. tostring(rootWant))

    while not rootDone() do
        sleep(0)

        local tickOk, tick = pcall(planTick,
            deps, index, store, opts, rootItemId, rootWant - rootCrafted,
            inflight, preloadItems, preloadFluids, machineCache
        )
        if not tickOk then
            log("PLAN FAIL " .. tostring(tick))
            return false, {
                error = "exception",
                missing = { name = "planning: " .. tostring(tick), count = 1 },
            }
        end

        local hard = tick.hard
        local jobs = tick.jobs
        if hard then
            hardSticky = hard
            local m = hard.missing and hard.missing.name
            log("hard " .. tostring(m and (m:match("([^/]+)$") or m)))
        end

        local wave = {}
        local claimed = {}
        for i = 1, #jobs do
            local job = jobs[i]
            if job.machine and not claimed[job.machine] and not machine_lock.isBusy(job.machine) then
                claimed[job.machine] = true
                local reserved = job.times * job.outStack.count
                job.reserved = reserved
                inflight[job.itemId] = (inflight[job.itemId] or 0) + reserved
                wave[#wave + 1] = job
                hardSticky = nil
            end
        end
        log("wave " .. tostring(#wave))

        if #wave == 0 then
            if hardSticky and not machine_lock.busyAny() then
                log("fail hard miss")
                return false, hardSticky
            end
            emitActivity(opts, "waiting...")
            log("wait")
            sleep(IDLE_SLEEP)
        else
            local slots = {}
            local fns = {}
            for i = 1, #wave do
                local job = wave[i]
                local slot = { job = job, ok = true, detail = nil, gained = 0 }
                slots[i] = slot
                fns[i] = function()
                    safeRun(job, slot)
                end
            end

            local parOk, parErr = pcall(function()
                if #fns == 1 then
                    fns[1]()
                else
                    parallel.waitForAll(table.unpack(fns))
                end
            end)
            if not parOk then
                for i = 1, #wave do
                    local job = wave[i]
                    local reserved = job.reserved or 0
                    inflight[job.itemId] = math.max(0, (inflight[job.itemId] or 0) - reserved)
                end
                log("PAR FAIL " .. tostring(parErr))
                return false, {
                    error = "exception",
                    missing = { name = tostring(parErr), count = 1 },
                }
            end

            local firstErr = nil
            for i = 1, #slots do
                local slot = slots[i]
                local err = applyResult(slot.job, slot.ok, slot.detail, slot.gained)
                if err and not firstErr then
                    firstErr = err
                end
            end
            if firstErr then
                local m = firstErr.missing and firstErr.missing.name or firstErr.error
                log("fail " .. tostring(m))
                return false, firstErr
            end

            if not rootDone() then
                emitActivity(opts, "planning...")
            end
        end
    end

    log("done " .. tostring(rootCrafted))
    return true, rootCrafted
end

return craft_monitor
