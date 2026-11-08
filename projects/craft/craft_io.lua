-- Feed / drain / craft.run for processing recipes.
-- Burst-pushes complete sets; short poll only while waiting on the machine.

require("food") -- register tag/spoil helpers into transfer
local transfer = require("transfer")
local craft_stock = require("craft_stock")
local craft_err = require("craft_err")
local craft_log = require("craft_log")

local craft_io = {}

local DEFAULT_CRAFT_WAIT = 300

local function shortId(id)
    return (id and tostring(id):match("([^/]+)$")) or tostring(id or "?")
end

local function ioLog(msg)
    pcall(craft_log.write, msg)
end

--- GT keeps the programmed circuit in the machine inventory — never pull it.
local function isConfigItem(name)
    if not name then
        return false
    end
    return name == "gtceu:programmed_circuit"
        or name:find("programmed_circuit", 1, true) ~= nil
end

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
    local t0 = os.clock()
    if dest and dest ~= from and peripheral.isPresent(from) then
        -- preferPull: GT food machines often need the fridge to pull, not machine push.
        -- Retry: output can show in list() a tick before GT allows extraction.
        for attempt = 1, 4 do
            n = transfer(from, dest, itemName, amount, { preferPull = true })
            if n > 0 then
                break
            end
            local have = transfer.countItem(from, itemName) or 0
            if have < 1 then
                break
            end
            if attempt < 4 then
                sleep(0.15)
            end
        end
    end
    -- No spill of fridge food into the room-temp overflow crate.
    -- Overflow is only used when destFor already points there (e.g. basil leaves).
    if n > 0 then
        ioLog(string.format(
            "out %s x%d %s->%s %dms",
            shortId(itemName), n, shortId(from), shortId(dest), craft_log.msSince(t0)
        ))
    elseif dest and peripheral.isPresent(from) then
        local have = transfer.countItem(from, itemName) or 0
        if have > 0 then
            ioLog(string.format(
                "out FAIL %s have=%d ->%s %dms",
                shortId(itemName), have, shortId(dest), craft_log.msSince(t0)
            ))
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

-- preferPull: yanking OUT of GT food machines (rollback / evacuate via transfer).
local CLEAR_OPTS = { allowSpoiled = true, preferPull = true }

local function destsForItem(store, opts, itemName)
    local dests = craft_stock.pullSourcesFor(store, itemName, opts)
    local preferred = {}
    for i = #dests, 1, -1 do
        preferred[#preferred + 1] = dests[i]
    end
    if #preferred == 0 and opts and opts.out then
        preferred[1] = opts.out
    end
    if #preferred == 0 and store and store.main then
        preferred[1] = store.main()
    end
    return preferred
end

--- Rollback items from machine into storage pull-sources (as destinations).
function craft_io.rollbackItems(machine, movedItems, store, opts)
    for name, count in pairs(movedItems) do
        if count and count > 0 then
            transfer.toMany(machine, destsForItem(store, opts, name), name, count, CLEAR_OPTS)
        end
    end
end

--- Ordered sinks for machine evacuate: trash first (homes often full), then recipe homes/main.
local function clearSinks(store, opts, itemName)
    local sinks = {}
    local seen = {}
    local function add(dest)
        if dest and not seen[dest] and dest ~= "" and peripheral.isPresent(dest) then
            seen[dest] = true
            sinks[#sinks + 1] = dest
        end
    end
    if store and store.trash then
        add(store.trash())
    end
    if itemName then
        local dests = destsForItem(store, opts, itemName)
        for i = 1, #dests do
            add(dests[i])
        end
    end
    if store and store.main then
        add(store.main())
    end
    if store and store.overflow then
        add(store.overflow())
    end
    return sinks
end

--- Try evacuate one slot into sinks. Returns moved, lastErr, lastSink.
local function pushSlotOut(inv, machine, store, opts, slot, itemName, count, sinks)
    local left = tonumber(count) or 64
    if left <= 0 then
        return 0, nil, nil
    end
    local movedTotal = 0
    local lastErr = nil
    local lastSink = nil
    sinks = sinks or clearSinks(store, opts, itemName)
    for i = 1, #sinks do
        if left <= 0 then
            break
        end
        local dest = sinks[i]
        if dest ~= machine then
            lastSink = dest
            -- GT often only moves when the SINK pulls.
            local sink = peripheral.wrap(dest)
            if sink and sink.pullItems then
                local ok, n = pcall(sink.pullItems, machine, slot, left)
                if not ok then
                    lastErr = "pull:" .. tostring(n)
                    n = 0
                else
                    n = tonumber(n) or 0
                end
                movedTotal = movedTotal + n
                left = left - n
            end
            if left > 0 and inv.pushItems then
                local ok, n = pcall(inv.pushItems, dest, slot, left)
                if not ok then
                    lastErr = "push:" .. tostring(n)
                    n = 0
                else
                    n = tonumber(n) or 0
                end
                movedTotal = movedTotal + n
                left = left - n
            end
        end
    end
    return movedTotal, lastErr, lastSink
end

local function dumpFluid(machine, store, fluid, amount)
    amount = tonumber(amount) or 0
    if amount <= 0 or not fluid then
        return 0
    end
    local left = amount
    local function tryTank(peri)
        if left <= 0 or not peri or peri == machine or not peripheral.isPresent(peri) then
            return
        end
        local n = transfer.fluid(machine, peri, fluid, left) or 0
        left = left - n
    end

    local info = store.fluidSourceOf(fluid)
    if (not info) and store.fluids then
        for _, entry in pairs(store.fluids) do
            if entry and entry.fluid == fluid then
                info = entry
                break
            end
        end
    end
    if info and info.peripheral then
        tryTank(info.peripheral)
    end
    -- Home oil/water tanks often full — dump to fluid_trash if configured.
    if store.fluidTrash then
        tryTank(store.fluidTrash())
    end
    return amount - left
end

local function clearMachineFluids(inv, machine, store, recipe)
    if not store or type(inv.tanks) ~= "function" then
        return
    end
    local okTanks, tanks = pcall(inv.tanks)
    if not okTanks or not tanks then
        return
    end

    local allowFluid = nil
    if recipe then
        allowFluid = {}
        for i = 1, #recipe.inputs do
            local input = recipe.inputs[i]
            if input.fluid then
                local info = store.fluidSourceOf(input.name)
                if info and info.fluid then
                    allowFluid[info.fluid] = true
                end
                allowFluid[input.name] = true
            end
        end
    end

    for _, tank in pairs(tanks) do
        local fluid = tank and tank.name
        local amount = tank and tonumber(tank.amount) or 0
        -- Full clear (no recipe): dump everything. Junk clear: dump non-recipe fluids.
        -- Also dump recipe fluids when calling clearMachine (recipe=nil).
        if fluid and amount > 0 and (not allowFluid or not allowFluid[fluid]) then
            dumpFluid(machine, store, fluid, amount)
        end
    end
end

--- Empty every free processing machine (list-only; no empty-slot spam).
function craft_io.sweepProcessors(list, resolveMachine, store, opts, machineCache, isBusy)
    if not list or not resolveMachine then
        return 0
    end
    local seen = {}
    local cleared = 0
    for i = 1, #list do
        local recipe = list[i]
        if recipe and (recipe.flag == "processing" or recipe.flag == "craft") then
            local machine = resolveMachine(recipe, machineCache)
            if machine and not seen[machine] then
                seen[machine] = true
                if not (isBusy and isBusy(machine)) then
                    cleared = cleared + (craft_io.clearMachine(machine, store, opts) or 0)
                end
            end
        end
    end
    return cleared
end

--- Evacuate occupied slots (+ fluids) via list(). Never poke empty slots (GT hang).
function craft_io.clearMachine(machine, store, opts)
    local t0 = os.clock()
    if not machine or not peripheral.isPresent(machine) then
        return 0
    end
    local inv = peripheral.wrap(machine)
    if not inv or type(inv.list) ~= "function" then
        return 0
    end

    local sinks = clearSinks(store, opts, nil)
    if #sinks == 0 then
        ioLog("clr NOSINK " .. shortId(machine))
        return 0
    end

    local okList, listed = pcall(inv.list)
    if not okList or type(listed) ~= "table" then
        ioLog("clr listfail " .. shortId(machine))
        return 0
    end

    local cleared = 0
    local tried = 0
    for rawSlot, item in pairs(listed) do
        local slot = tonumber(rawSlot) or rawSlot
        if item and item.name and not isConfigItem(item.name) then
            tried = tried + 1
            local n, err, sink = pushSlotOut(
                inv, machine, store, opts, slot, item.name, item.count or 64, sinks
            )
            if n > 0 then
                cleared = cleared + n
                ioLog(string.format(
                    "clr %s s%d %s x%d ->%s",
                    shortId(machine), slot, shortId(item.name), n, shortId(sink)
                ))
            else
                ioLog(string.format(
                    "clr FAIL %s s%d %s x%d %s",
                    shortId(machine),
                    slot,
                    shortId(item.name),
                    item.count or 0,
                    err and tostring(err):sub(1, 20) or "moved0"
                ))
            end
        end
    end

    clearMachineFluids(inv, machine, store, nil)

    if tried > 0 then
        ioLog(string.format(
            "clr %s +%d/%d %dms",
            shortId(machine), cleared, tried, craft_log.msSince(t0)
        ))
    end
    return cleared
end

--- Pull spoiled / non-recipe stacks (list-only).
function craft_io.clearJunk(machine, recipe, store, opts)
    if not machine or not recipe or not peripheral.isPresent(machine) then
        return 0
    end
    local inv = peripheral.wrap(machine)
    if not inv or type(inv.list) ~= "function" then
        return 0
    end

    local queries = {}
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        if not input.fluid then
            queries[#queries + 1] = input.name
        end
    end

    local okList, listed = pcall(inv.list)
    if not okList or not listed then
        return 0
    end

    local cleared = 0
    for rawSlot, item in pairs(listed) do
        local slot = tonumber(rawSlot) or rawSlot
        if item and item.name and not isConfigItem(item.name) then
            local detail = nil
            if inv.getItemDetail then
                local ok, d = pcall(inv.getItemDetail, slot)
                if ok then
                    detail = d
                end
            end
            local accepted = false
            for q = 1, #queries do
                if transfer.matches(item.name, detail and detail.tags, queries[q]) then
                    accepted = true
                    break
                end
            end
            if (not accepted) or transfer.isSpoiled(detail) then
                cleared = cleared + (pushSlotOut(
                    inv, machine, store, opts, slot, item.name, item.count or 64
                ) or 0)
            end
        end
    end

    clearMachineFluids(inv, machine, store, recipe)
    return cleared
end

--- Rollback fluids from machine into configured fluid_source tanks.
function craft_io.rollbackFluids(machine, movedFluids, store)
    if not store or not movedFluids then
        return
    end
    for name, count in pairs(movedFluids) do
        if count and count > 0 then
            local info = store.fluidSourceOf(name)
            if info and info.peripheral and info.fluid and peripheral.isPresent(info.peripheral) then
                transfer.fluid(machine, info.peripheral, info.fluid, count)
            end
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

local function rollbackAll(machine, movedItems, movedFluids, store, opts)
    craft_io.rollbackItems(machine, movedItems, store, opts)
    craft_io.rollbackFluids(machine, movedFluids, store)
end

--- Push exactly one recipe unit into the machine. Rolls back items+fluids on mid-set failure.
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
            local t0 = os.clock()
            local n = transfer.fromMany(sources, machine, input.name, input.count)
            ioLog(string.format(
                "in %s x%d/%d ->%s %dms",
                shortId(input.name), n, input.count, shortId(machine), craft_log.msSince(t0)
            ))
            movedItems[input.name] = (movedItems[input.name] or 0) + n
            if n < input.count then
                rollbackAll(machine, movedItems, movedFluids, store, opts)
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
                rollbackAll(machine, movedItems, movedFluids, store, opts)
                return false, movedItems, {
                    name = input.name,
                    count = input.count,
                    fluid = true,
                    error = "no_fluid_source",
                }
            end
            local t0 = os.clock()
            local n = transfer.fluid(info.peripheral, machine, info.fluid, input.count)
            ioLog(string.format(
                "inF %s %d/%d ->%s %dms",
                shortId(input.name), n, input.count, shortId(machine), craft_log.msSince(t0)
            ))
            movedFluids[input.name] = (movedFluids[input.name] or 0) + n
            if n < input.count then
                rollbackAll(machine, movedItems, movedFluids, store, opts)
                local moved = {}
                for k, v in pairs(movedItems) do
                    moved[k] = v
                end
                for k, v in pairs(movedFluids) do
                    moved[k] = (moved[k] or 0) + v
                end
                return false, moved, {
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

--- Pull fluid from machine into the fluid_source tank for this recipe fluid/tag.
function craft_io.pullFluidAmount(from, fluidOrTag, amount, store)
    amount = tonumber(amount) or 0
    if amount <= 0 or not from or not store then
        return 0
    end
    local info = store.fluidSourceOf(fluidOrTag)
    if not info or not info.peripheral or not info.fluid then
        return 0
    end
    if not peripheral.isPresent(from) or not peripheral.isPresent(info.peripheral) then
        return 0
    end
    return transfer.fluid(from, info.peripheral, info.fluid, amount)
end

function craft_io.drainToward(pullFrom, need, pulled, store, fallbackOut, recipe, fluidKeys)
    local complete = true
    for name, want in pairs(need) do
        local remaining = want - (pulled[name] or 0)
        if remaining > 0 then
            local n
            if fluidKeys and fluidKeys[name] then
                n = craft_io.pullFluidAmount(pullFrom, name, remaining, store)
            else
                n = craft_io.pullItemAmount(pullFrom, name, remaining, store, fallbackOut, recipe)
            end
            pulled[name] = (pulled[name] or 0) + n
            if pulled[name] < want then
                complete = false
            end
        end
    end
    return complete
end

--- Build item+fluid output need maps.
-- @return need, anyItem, fluidKeys, anyFluid
function craft_io.buildNeedMap(outputs, times)
    local need = {}
    local fluidKeys = {}
    local anyItem = false
    local anyFluid = false
    for i = 1, #outputs do
        local o = outputs[i]
        need[o.name] = (need[o.name] or 0) + o.count * times
        if o.fluid then
            anyFluid = true
            fluidKeys[o.name] = true
        else
            anyItem = true
        end
    end
    return need, anyItem, fluidKeys, anyFluid
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
        return craft_err.fail("use_request", {
            message = "use craft.request for grow recipes",
        })
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

    -- Shared processors (e.g. _0 dough/feta, _1 dough/sauce) keep leftover/spoiled
    -- stacks that block the next recipe — empty them first.
    craft_io.clearMachine(opts.machine, store, opts)

    local oneshot = recipe.oneshot == true
    local targetSets = times
    local need, anyItem, fluidKeys, anyFluid = craft_io.buildNeedMap(recipe.outputs, targetSets)
    local anyOutput = anyItem or anyFluid
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
    local outStallSince = nil -- no output progress after sets pushed
    local lastPulledTotal = 0
    local lastBeatAt = 0
    local lastJunkAt = 0
    local POLL = 0.05
    local JUNK_EVERY = 1.0 -- clearJunk is expensive (getItemDetail); not every poll
    local STALL_STOP_PUSH = 6 -- seconds
    local STALL_FAIL = 10 -- seconds
    -- Absolute craft_wait_timeout can be 300s; abort much sooner if GT produces nothing.
    local OUT_STALL = math.min(45, math.max(15, timeout * 0.25))
    local BEAT_EVERY = 5

    local function maybeClearJunk(force)
        local now = os.clock()
        if force or (now - lastJunkAt) >= JUNK_EVERY then
            lastJunkAt = now
            craft_io.clearJunk(opts.machine, recipe, store, opts)
        end
    end

    local function abortClear()
        craft_io.drainToward(pullFrom, need, pulled, store, out, recipe, fluidKeys)
        craft_io.clearMachine(opts.machine, store, opts)
    end

    local function pulledTotal()
        local n = 0
        for _, v in pairs(pulled) do
            n = n + (tonumber(v) or 0)
        end
        return n
    end

    local function shortNeed()
        local name, left = nil, 0
        for id, want in pairs(need) do
            local rem = want - (pulled[id] or 0)
            if rem > left then
                name, left = id, rem
            end
        end
        return name, left
    end

    local function noteOutputProgress()
        local total = pulledTotal()
        if total > lastPulledTotal then
            lastPulledTotal = total
            outStallSince = nil
            return
        end
        if setsPushed < 1 then
            return
        end
        local now = os.clock()
        if not outStallSince then
            outStallSince = now
        end
        if (now - lastBeatAt) >= BEAT_EVERY then
            lastBeatAt = now
            local name, left = shortNeed()
            ioLog(string.format(
                "wait out %s %d left %ds",
                shortId(name or "?"),
                left,
                math.floor(now - outStallSince)
            ))
        end
        if (now - outStallSince) >= OUT_STALL then
            return true
        end
        return false
    end

    local function rebuildNeed(sets)
        need, anyItem, fluidKeys, anyFluid = craft_io.buildNeedMap(recipe.outputs, sets)
        anyOutput = anyItem or anyFluid
        for name in pairs(need) do
            if not pulled[name] then
                pulled[name] = 0
            end
        end
    end

    local function outputsComplete()
        if not anyOutput then
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
        if not anyOutput then
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
        craft_io.clearMachine(opts.machine, store, opts)
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

    local runT0 = os.clock()
    ioLog(string.format(
        "run %s x%d m=%s",
        shortId(recipe.outputs[1] and recipe.outputs[1].name or recipe.machine),
        targetSets,
        shortId(opts.machine)
    ))

    while os.clock() < deadline do
        craft_io.drainToward(pullFrom, need, pulled, store, out, recipe, fluidKeys)
        maybeClearJunk(false)
        emitSetsProgress()
        if outputsComplete() then
            ioLog(string.format("run ok %dms", craft_log.msSince(runT0)))
            return finishOk()
        end
        if noteOutputProgress() then
            abortClear()
            local name, left = shortNeed()
            ioLog(string.format(
                "run stall %dms no out %ds",
                craft_log.msSince(runT0),
                math.floor(OUT_STALL)
            ))
            return false, {
                error = "craft_timeout",
                missing = {
                    name = name or (recipe.outputs[1] and recipe.outputs[1].name),
                    count = left > 0 and left or 1,
                },
                outputs = pulled,
                hint = "no output progress (power / circuit / wrong recipe)",
                times = targetSets,
                sets_pushed = setsPushed,
            }
        end

        -- Burst: push as many sets as possible without sleeping between successes.
        while pushing and setsPushed < targetSets and readyForNextSet() and os.clock() < deadline do
            maybeClearJunk(false)
            local ok, moved, missing = craft_io.pushOneSet(recipe, opts.machine, store, opts)
            if ok then
                setsPushed = setsPushed + 1
                stallSince = nil
                if not outStallSince then
                    outStallSince = os.clock()
                end
                for k, v in pairs(moved) do
                    movedTotals[k] = (movedTotals[k] or 0) + v
                end
                emitSetsProgress()
                craft_io.drainToward(pullFrom, need, pulled, store, out, recipe, fluidKeys)
                if outputsComplete() then
                    ioLog(string.format("run ok %dms", craft_log.msSince(runT0)))
                    return finishOk()
                end
                -- Yield so CC never hits "too long without yielding" on large batches.
                sleep(0)
                if oneshot then
                    break
                end
            else
                lastMissing = missing
                if missing and missing.error == "push_short" then
                    -- Full of junk or unconsumed inputs: yank non-recipe/spoil, retry.
                    maybeClearJunk(true)
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
                        abortClear()
                        ioLog(string.format("run miss %dms", craft_log.msSince(runT0)))
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
            ioLog(string.format("run ok %dms", craft_log.msSince(runT0)))
            return finishOk()
        end
        -- Brief yield while waiting on GT / oneshot / stock.
        sleep(POLL)
    end

    craft_io.drainToward(pullFrom, need, pulled, store, out, recipe, fluidKeys)
    emitSetsProgress()
    if outputsComplete() then
        ioLog(string.format("run ok %dms", craft_log.msSince(runT0)))
        return finishOk()
    end

    abortClear()
    ioLog(string.format("run timeout %dms sets=%d", craft_log.msSince(runT0), setsPushed))
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
