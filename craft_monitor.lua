-- Continuous craft monitor: top-down demand, bottom-up dispatch, realtime replan.
-- Planner + worker pool run in parallel; no stage waitForAll barrier.
-- Activity only after a confirmed batch under lock.

local recipes = require("recipes")
local craft_stock = require("craft_stock")
local craft_plan = require("craft_plan")
local machine_lock = require("machine_lock")

local craft_monitor = {}

local IDLE_SLEEP = 0.05
local WORKER_COUNT = 6
local DONE_EVENT = "craft_job_done"

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

--- deps: findByOutput, resolveMachine, run, runGrow
function craft_monitor.request(deps, list, rootItemId, amount, opts, log)
    local store = opts.store
    local rootWant = amount
    local rootCrafted = 0
    local hardSticky = nil
    local inflight = {} -- itemId -> units reserved
    local machineBusy = {} -- machine -> recipeKey while job queued/running in pool
    local index = craft_plan.buildIndex(list, deps.findByOutput)

    local jobQueue = {}
    local results = {}
    local shutdown = false
    local fatalErr = nil

    local function rootDone()
        return rootCrafted >= rootWant
    end

    local function queuePush(job)
        jobQueue[#jobQueue + 1] = job
    end

    local function queuePop()
        if #jobQueue == 0 then
            return nil
        end
        local job = jobQueue[1]
        table.remove(jobQueue, 1)
        return job
    end

    local function runsStillNeeded(job)
        local per = job.outStack.count
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
                local gOk, gDetail = deps.runGrow(job.recipe, job.machine, opts)
                if gOk and job.isRoot then
                    local gained = unitsFromDetail(job, gDetail, 1)
                    if gained > 0 then
                        emitProgress(opts, math.min(rootWant, rootCrafted + gained), rootWant)
                    end
                end
                return gOk, gDetail
            end

            local runsLeft = runsStillNeeded(job)
            local ready = craft_stock.countCompleteSets(job.recipe, store, opts)
            if ready < 1 or runsLeft < 1 then
                return false, { error = "skipped", skipped = true }
            end
            local batch = craft_plan.batchTimes(job.recipe, ready, runsLeft)
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

        if type(detail) == "table" and detail.error == "busy" then
            return true, detail, 0
        end
        if not ok then
            if type(detail) == "table" and detail.skipped then
                return true, detail, 0
            end
            return false, detail, 0
        end
        if type(detail) == "table" and detail.skipped then
            return true, detail, 0
        end

        return true, detail, unitsFromDetail(job, detail, job.times)
    end

    local function applyResult(res)
        local job = res.job
        local reserved = job.reserved or 0
        inflight[job.itemId] = math.max(0, (inflight[job.itemId] or 0) - reserved)
        machineBusy[job.machine] = nil

        if not res.ok then
            if not (type(res.detail) == "table" and (res.detail.skipped or res.detail.error == "busy")) then
                fatalErr = fatalErr or res.detail
            end
            return
        end

        if res.gained and res.gained > 0 then
            if job.isRoot then
                rootCrafted = rootCrafted + res.gained
                emitProgress(opts, math.min(rootWant, rootCrafted), rootWant)
            end
            log[#log + 1] = {
                item = job.itemId,
                machine = job.machine,
                flag = job.recipe.flag,
                detail = res.detail,
                times = (type(res.detail) == "table" and res.detail.sets_pushed) or job.times,
            }
        end
    end

    local function drainResults()
        while #results > 0 do
            local res = results[1]
            table.remove(results, 1)
            applyResult(res)
        end
    end

    local function workerLoop()
        while not shutdown do
            local job = queuePop()
            if job then
                local ok, detail, gained = executeJob(job)
                results[#results + 1] = {
                    job = job,
                    ok = ok,
                    detail = detail,
                    gained = gained or 0,
                }
                os.queueEvent(DONE_EVENT)
            else
                sleep(IDLE_SLEEP)
            end
        end
    end

    local function plannerLoop()
        emitProgress(opts, 0, rootWant)
        emitActivity(opts, "planning...")

        while not rootDone() and not fatalErr do
            drainResults()
            if rootDone() or fatalErr then
                break
            end

            local snap = craft_stock.snapshot(store, opts)
            local _need, deficit, hard = craft_plan.computeDemand(
                index,
                rootItemId,
                rootWant - rootCrafted,
                snap,
                inflight
            )
            if hard then
                hardSticky = hard
            end

            local jobs = craft_plan.readyJobs(
                index,
                deficit,
                snap,
                deps.resolveMachine,
                machineBusy,
                rootItemId
            )

            local dispatched = 0
            for i = 1, #jobs do
                local job = jobs[i]
                if not machineBusy[job.machine] and not machine_lock.isBusy(job.machine) then
                    local reserved = job.times * job.outStack.count
                    job.reserved = reserved
                    inflight[job.itemId] = (inflight[job.itemId] or 0) + reserved
                    machineBusy[job.machine] = job.recipeKey
                    hardSticky = nil
                    queuePush(job)
                    dispatched = dispatched + 1
                end
            end

            local busy = next(machineBusy) ~= nil or #jobQueue > 0 or machine_lock.busyAny()
            if dispatched == 0 and not busy then
                if hardSticky then
                    fatalErr = hardSticky
                    break
                end
                emitActivity(opts, "waiting...")
                sleep(IDLE_SLEEP)
            else
                -- Wake on job completion or short tick to replan free machines.
                local timer = os.startTimer(IDLE_SLEEP)
                while true do
                    local ev, p1 = os.pullEvent()
                    if ev == DONE_EVENT then
                        break
                    elseif ev == "timer" and p1 == timer then
                        break
                    end
                end
            end
        end

        -- Wait for in-flight jobs to finish.
        while next(machineBusy) ~= nil or #jobQueue > 0 do
            drainResults()
            if next(machineBusy) == nil and #jobQueue == 0 then
                break
            end
            local timer = os.startTimer(IDLE_SLEEP)
            while true do
                local ev, p1 = os.pullEvent()
                if ev == DONE_EVENT or (ev == "timer" and p1 == timer) then
                    break
                end
            end
        end
        drainResults()
        shutdown = true
    end

    local funcs = { plannerLoop }
    for _ = 1, WORKER_COUNT do
        funcs[#funcs + 1] = workerLoop
    end
    parallel.waitForAll(table.unpack(funcs))

    if fatalErr then
        return false, fatalErr
    end
    return true, rootCrafted
end

return craft_monitor
