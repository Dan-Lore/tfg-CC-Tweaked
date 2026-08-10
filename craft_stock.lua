-- Stock counting and recipe input availability (count == pull sources).
-- Supports a per-tick snapshot so planners don't re-scan peripherals repeatedly.

local transfer = require("transfer")

local craft_stock = {}

local function extraInvOpts(opts)
    local extra = {}
    if opts then
        if opts.from then
            extra[#extra + 1] = opts.from
        end
        if opts.out and opts.out ~= opts.from then
            extra[#extra + 1] = opts.out
        end
    end
    return extra
end

function craft_stock.isCraftableName(name)
    return name and name:sub(1, 1) ~= "#"
end

function craft_stock.pullSourcesFor(store, itemName, opts)
    if store and store.pullSources then
        return store.pullSources(itemName, extraInvOpts(opts))
    end
    local list = {}
    local seen = {}
    local function add(inv)
        if inv and not seen[inv] and peripheral.isPresent(inv) then
            seen[inv] = true
            list[#list + 1] = inv
        end
    end
    if opts then
        add(opts.from)
        add(opts.out)
    end
    return list
end

function craft_stock.countAvailable(store, itemName, opts)
    return transfer.countFromMany(craft_stock.pullSourcesFor(store, itemName, opts), itemName)
end

function craft_stock.countFluidAvailable(store, fluidOrTag)
    if not store then
        return 0, nil
    end
    local info = store.fluidSourceOf(fluidOrTag)
    if not info or not info.peripheral or not info.fluid then
        return 0, nil
    end
    if not peripheral.isPresent(info.peripheral) then
        return 0, nil
    end
    return transfer.countFluid(info.peripheral, info.fluid), info
end

--- Lazy stock snapshot: counts each item/fluid at most once per tick.
function craft_stock.snapshot(store, opts)
    local snap = {
        store = store,
        opts = opts,
        items = {},
        fluids = {}, -- name -> { have=, info= }
        _itemDone = {},
        _fluidDone = {},
    }

    function snap.item(name)
        if not name then
            return 0
        end
        if snap._itemDone[name] then
            return snap.items[name] or 0
        end
        snap._itemDone[name] = true
        local n = craft_stock.countAvailable(store, name, opts)
        snap.items[name] = n
        return n
    end

    function snap.fluid(fluidOrTag)
        if not fluidOrTag then
            return 0, nil
        end
        if snap._fluidDone[fluidOrTag] then
            local slot = snap.fluids[fluidOrTag]
            if not slot then
                return 0, nil
            end
            return slot.have, slot.info
        end
        snap._fluidDone[fluidOrTag] = true
        local have, info = craft_stock.countFluidAvailable(store, fluidOrTag)
        snap.fluids[fluidOrTag] = { have = have, info = info }
        return have, info
    end

    return snap
end

--- List missing inputs for `times` craft runs (items + fluids). Does not recurse.
function craft_stock.findMissingInputs(recipe, store, opts, times)
    times = math.max(1, math.floor(tonumber(times) or 1))
    local fluids = {}
    local items = {}
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        local need = input.count * times
        if input.fluid then
            local have, info = craft_stock.countFluidAvailable(store, input.name)
            if not info then
                fluids[#fluids + 1] = {
                    name = input.name,
                    count = need,
                    fluid = true,
                    error = "no_fluid_source",
                }
            elseif have < need then
                fluids[#fluids + 1] = {
                    name = input.name,
                    count = need - have,
                    fluid = true,
                }
            end
        elseif craft_stock.isCraftableName(input.name) then
            local have = craft_stock.countAvailable(store, input.name, opts)
            if have < need then
                items[#items + 1] = {
                    name = input.name,
                    count = need - have,
                    fluid = false,
                }
            end
        else
            local sources = craft_stock.pullSourcesFor(store, input.name, opts)
            local have = transfer.countFromMany(sources, input.name)
            if have < need then
                items[#items + 1] = {
                    name = input.name,
                    count = need - have,
                    fluid = false,
                    tag = true,
                }
            end
        end
    end
    local missing = {}
    for i = 1, #fluids do
        missing[#missing + 1] = fluids[i]
    end
    for i = 1, #items do
        missing[#missing + 1] = items[i]
    end
    return missing
end

--- How many balanced recipe sets can be fed. Grow (no inputs) is always ready.
-- Optional `snap` uses cached counts.
function craft_stock.countCompleteSets(recipe, store, opts, snap)
    if not recipe or not recipe.inputs then
        return 0
    end
    if #recipe.inputs == 0 then
        return 1000000
    end
    local sets = nil
    for i = 1, #recipe.inputs do
        local input = recipe.inputs[i]
        local per = input.count
        if not per or per <= 0 then
            return 0
        end
        local have
        if input.fluid then
            if snap then
                have = snap.fluid(input.name)
            else
                have = craft_stock.countFluidAvailable(store, input.name)
            end
        else
            if snap then
                have = snap.item(input.name)
            else
                have = craft_stock.countAvailable(store, input.name, opts)
            end
        end
        local can = math.floor(have / per)
        if sets == nil or can < sets then
            sets = can
        end
    end
    return sets or 0
end

return craft_stock
