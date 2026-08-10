-- Continuous craft monitor: top-down demand, bottom-up dispatch.
-- Parallel across different machines (e.g. assemble raw pizza while oven cooks).
-- Workers never touch the log/UI monitors — that was killing CC.

local recipes = require("recipes")
local craft_stock = require("craft_stock")
local craft_plan = require("craft_plan")
local machine_lock = require("machine_lock")
local craft_log = require("craft_log")

local craft_monitor = {}

local IDLE_SLEEP = 0.1
local SKIP_SLEEP = 0.25
local MAX_PARALLEL = 6

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

local function shortName(id)
    return (id and id:match("([^/]+)$")) or tostring(id)
end

local function activityText(recipe, itemId, times)
    times = math.max(1, math.floor(tonumber(times) or 1))
    local out = recipes.primaryOutput(recipe)
    local n = (out and out.count or 1) * times
    local name = shortName(itemId)
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
    local snap = craft_stock.snapshot(store, opts, preloadItems, preloadFluids)
    local _need, deficit, hard = craft_plan.computeDemand(
        index,
        rootItemId,
        rootStill,
        snap,
        inflight
    )
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
    local skipStreak = 0

    log("index build")
    local index = craft_plan.buildIndex(list, deps.findByOutput)
    local preloadItems, preloadFluids = craft_plan.collectNames(index, rootItemId)
    log("tree i" .. tostring(#preloadItems) .. " f" .. tostring(#preloadFluids))

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
        local want = job.wantUnits or job.deficit or 0
        local still = math.max(0, want - have)
        return math.ceil(still / per)
    end

    -- No log/UI inside workers (parallel-safe).
    local function executeJob(job)
        local ok, detail = machine_lock.tryLock(job.machine, job.recipeKey, function()
            if job.recipe.flag == "grow" then
                if not job.isRoot then
                    local have = craft_stock.countAvailable(store, job.itemId, opts)
                    if have >= (job.deficit or 0) then
                        return false, { error = "skipped", skipped = true, reason = "have" }
                    end
                elseif rootCrafted >= rootWant then
                    return false, { error = "skipped", skipped = true, reason = "root_done" }
                end
                return deps.runGrow(job.recipe, job.machine, opts)
            end

            local runsLeft = runsStillNeeded(job)
            local ready = craft_stock.countCompleteSets(job.recipe, store, opts)
            if ready < 1 or runsLeft < 1 then
                return false, {
                    error = "skipped",
                    skipped = true,
                    reason = "ready=" .. tostring(ready) .. " left=" .. tostring(runsLeft),
                }
            end
            local batch = craft_plan.batchTimes(job.recipe, ready, runsLeft)
            job._batch = batch
            return deps.run(job.recipe, {
                from = opts.from,
                out = opts.out,
                store = store,
                machine = job.machine,
                pullFrom = opts.pullFrom,
                waitTicks = opts.waitTicks,
                craftWaitTimeout = opts.craftWaitTimeout,
                times = batch,
                -- Progress only after wave joins (avoid parallel UI draws).
            })
        end)

        if type(detail) == "table" and (detail.error == "busy" or detail.skipped) then
            return true, detail, 0
        end
        if not ok then
            return false, detail, 0
        end
        return true, detail, unitsFromDetail(job, detail, job._batch or job.times)
    end

    emitProgress(opts, 0, rootWant)
    emitActivity(opts, "planning...")
    log("req " .. shortName(rootItemId) .. " x" .. tostring(rootWant))

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

        if tick.hard then
            hardSticky = tick.hard
        end

        -- One job per free machine, depth-first (cooked oven + raw assembler together).
        local wave = {}
        local claimed = {}
        for i = 1, #tick.jobs do
            if #wave >= MAX_PARALLEL then
                break
            end
            local cand = tick.jobs[i]
            if cand.machine and not claimed[cand.machine] and not machine_lock.isBusy(cand.machine) then
                claimed[cand.machine] = true
                local reserved = cand.times * cand.outStack.count
                cand.reserved = reserved
                inflight[cand.itemId] = (inflight[cand.itemId] or 0) + reserved
                wave[#wave + 1] = cand
                hardSticky = nil
            end
        end

        if #wave == 0 then
            if hardSticky and not machine_lock.busyAny() then
                local m = hardSticky.missing and hardSticky.missing.name
                log("fail " .. shortName(m))
                return false, hardSticky
            end
            emitActivity(opts, "waiting...")
            if skipStreak == 0 then
                log("wait")
            end
            sleep(IDLE_SLEEP)
        else
            local names = {}
            for i = 1, #wave do
                names[i] = shortName(wave[i].itemId)
            end
            log("wave " .. table.concat(names, "+"))
            emitActivity(opts, table.concat(names, " | "))

            local slots = {}
            local fns = {}
            for i = 1, #wave do
                local job = wave[i]
                local slot = { job = job, ok = true, detail = nil, gained = 0, err = nil }
                slots[i] = slot
                fns[i] = function()
                    local ran, ok, detail, gained = pcall(function()
                        return executeJob(job)
                    end)
                    if not ran then
                        slot.ok = false
                        slot.err = tostring(ok)
                        slot.detail = {
                            error = "exception",
                            missing = { name = tostring(ok), count = 1 },
                        }
                        slot.gained = 0
                    else
                        slot.ok = ok
                        slot.detail = detail
                        slot.gained = gained or 0
                    end
                end
            end

            local parOk, parErr = pcall(function()
                if #fns == 1 then
                    fns[1]()
                else
                    parallel.waitForAll(table.unpack(fns))
                end
            end)

            -- Always release inflight reservations.
            for i = 1, #wave do
                local job = wave[i]
                local reserved = job.reserved or 0
                inflight[job.itemId] = math.max(0, (inflight[job.itemId] or 0) - reserved)
            end

            if not parOk then
                log("PAR FAIL " .. tostring(parErr))
                return false, {
                    error = "exception",
                    missing = { name = tostring(parErr), count = 1 },
                }
            end

            local firstErr = nil
            local anyProgress = false
            local anySkip = false

            for i = 1, #slots do
                local slot = slots[i]
                local job = slot.job
                if slot.err then
                    log("ERR " .. shortName(job.itemId) .. " " .. slot.err)
                    firstErr = firstErr or slot.detail
                elseif type(slot.detail) == "table" and slot.detail.skipped then
                    anySkip = true
                    log("skip " .. shortName(job.itemId) .. " " .. tostring(slot.detail.reason or ""))
                elseif not slot.ok then
                    local m = (type(slot.detail) == "table" and slot.detail.missing and slot.detail.missing.name)
                        or (type(slot.detail) == "table" and slot.detail.error)
                        or "fail"
                    log("fail " .. shortName(job.itemId) .. " " .. tostring(m))
                    firstErr = firstErr or slot.detail
                elseif slot.gained and slot.gained > 0 then
                    anyProgress = true
                    log("ok +" .. tostring(slot.gained) .. " " .. shortName(job.itemId))
                    if job.isRoot then
                        rootCrafted = rootCrafted + slot.gained
                        emitProgress(opts, math.min(rootWant, rootCrafted), rootWant)
                    end
                    logSteps[#logSteps + 1] = {
                        item = job.itemId,
                        machine = job.machine,
                        flag = job.recipe.flag,
                        detail = slot.detail,
                        times = (type(slot.detail) == "table" and slot.detail.sets_pushed) or job.times,
                    }
                else
                    anySkip = true
                    log("noop " .. shortName(job.itemId))
                end
            end

            if firstErr then
                return false, firstErr
            end

            if anyProgress then
                skipStreak = 0
            else
                skipStreak = skipStreak + 1
                sleep(SKIP_SLEEP)
            end

            if skipStreak >= 30 then
                log("stuck skips")
                return false, {
                    error = "exception",
                    missing = { name = "stuck: jobs skip without progress", count = 1 },
                }
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
