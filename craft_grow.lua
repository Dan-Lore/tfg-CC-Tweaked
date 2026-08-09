-- Greenhouse grow: pulse machine, wait for output bus, pull products.

local transfer = require("transfer")
local recipes = require("recipes")
local greenhouse = require("greenhouse")
local craft_io = require("craft_io")

local craft_grow = {}

local DEFAULT_GROW_PULSE = 3
local DEFAULT_GROW_WAIT = 600

craft_grow.DEFAULT_GROW_PULSE = DEFAULT_GROW_PULSE
craft_grow.DEFAULT_GROW_WAIT = DEFAULT_GROW_WAIT

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

function craft_grow.run(recipe, machine, opts)
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
    local outputs = craft_io.pullOutputs(pullFrom, recipe.outputs, store, out, recipe)
    return true, {
        inputs = {},
        outputs = outputs,
        machine = recipe.machine,
        circuit = recipe.circuit,
        flag = "grow",
        pulse = pulse,
    }
end

return craft_grow
