-- Discover recipe buffers, EBF hatch packs, sinks, and monitor.
-- One hatch index N = one pack = furnaces NL + NR sharing those 4 hatches.

local discover = {}

local function isInventory(name)
    if not name or not peripheral.isPresent(name) then
        return false
    end
    local inv = peripheral.wrap(name)
    return inv and type(inv.list) == "function" and type(inv.pushItems) == "function"
end

local function indexFromName(name)
    return tonumber(tostring(name):match("_(%d+)$"))
end

local function prefixedIndex(name, prefix)
    if not name or not prefix then
        return nil
    end
    local n = tostring(name)
    local p = tostring(prefix)
    if n:sub(1, #p) ~= p then
        return nil
    end
    local rest = n:sub(#p + 1)
    return tonumber(rest:match("^_(%d+)$"))
end

local function sortByIndex(list)
    table.sort(list, function(a, b)
        local ia, ib = indexFromName(a), indexFromName(b)
        if ia and ib and ia ~= ib then
            return ia < ib
        end
        if ia and not ib then
            return true
        end
        if ib and not ia then
            return false
        end
        return a < b
    end)
    return list
end

local function resolvePresent(name, label)
    if name and peripheral.isPresent(name) then
        return name
    end
    if name then
        print(("ebf: missing %s %s"):format(label, tostring(name)))
    end
    return nil
end

function discover.monitor(preferred)
    local name = resolvePresent(preferred, "monitor")
    if name then
        local m = peripheral.wrap(name)
        if m and m.clear then
            return m, name
        end
    end
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "monitor" then
            local m = peripheral.wrap(n)
            if m and m.clear then
                return m, n
            end
        end
    end
    return nil, nil
end

function discover.recipeBuffers(cfg)
    cfg = cfg or {}
    local prefix = cfg.recipe_buffer_prefix or "gtceu:hv_buffer"
    local minIdx = tonumber(cfg.recipe_buffer_min) or 1
    local hotSink = cfg.hot_sink
    local list = {}
    local names = peripheral.getNames()
    for i = 1, #names do
        local name = names[i]
        if name ~= hotSink then
            local idx = prefixedIndex(name, prefix)
            if idx and idx >= minIdx and isInventory(name) then
                list[#list + 1] = name
            end
        end
        if i % 8 == 0 then
            sleep(0)
        end
    end
    return sortByIndex(list)
end

--- One complete hatch index = pack for furnaces (N)L + (N)R.
function discover.furnaces(cfg)
    cfg = cfg or {}
    local ibP = cfg.input_bus_prefix or "gtceu:lv_input_bus"
    local ihP = cfg.input_hatch_prefix or "gtceu:ev_input_hatch_4x"
    local obP = cfg.output_bus_prefix or "gtceu:lv_output_bus"
    local ohP = cfg.output_hatch_prefix or "gtceu:lv_output_hatch"
    local maxN = tonumber(cfg.max_furnaces) or 0

    local byIdx = {}
    local names = peripheral.getNames()
    for i = 1, #names do
        local name = names[i]
        local role, idx = nil, nil
        idx = prefixedIndex(name, ibP)
        if idx then
            role = "inputBus"
        else
            idx = prefixedIndex(name, ihP)
            if idx then
                role = "inputHatch"
            else
                idx = prefixedIndex(name, obP)
                if idx then
                    role = "outputBus"
                else
                    idx = prefixedIndex(name, ohP)
                    if idx then
                        role = "outputHatch"
                    end
                end
            end
        end
        if role and idx then
            local g = byIdx[idx]
            if not g then
                g = { index = idx }
                byIdx[idx] = g
            end
            g[role] = name
        end
        if i % 8 == 0 then
            sleep(0)
        end
    end

    local indices = {}
    for idx in pairs(byIdx) do
        indices[#indices + 1] = idx
    end
    table.sort(indices)

    local furnaces = {}
    for i = 1, #indices do
        local idx = indices[i]
        local g = byIdx[idx]
        if g.inputBus and g.outputBus then
            -- Display index as 1-based pair id when hatches are 0-based (0→1L/1R).
            furnaces[#furnaces + 1] = {
                index = idx,
                pair = idx + 1,
                id = "ebf_" .. tostring(idx),
                label = tostring(idx + 1),
                paired = 2,
                inputBus = g.inputBus,
                inputHatch = g.inputHatch,
                outputBus = g.outputBus,
                outputHatch = g.outputHatch,
            }
            if maxN > 0 and #furnaces >= maxN then
                break
            end
        else
            print(("ebf: skip hatch index %d (need input+output bus)"):format(idx))
        end
    end
    return furnaces
end

function discover.scan(cfg)
    cfg = cfg or {}
    local monitor, monitorName = discover.monitor(cfg.monitor)
    local hotSink = resolvePresent(cfg.hot_sink, "hot_sink")
    local aeSink = resolvePresent(cfg.ae_sink, "ae_sink")
    if hotSink and not isInventory(hotSink) then
        print("ebf: hot_sink is not an inventory: " .. tostring(hotSink))
        hotSink = nil
    end
    if aeSink and not isInventory(aeSink) then
        print("ebf: warning: ae_sink may not list/push: " .. tostring(aeSink))
    end

    return {
        buffers = discover.recipeBuffers(cfg),
        furnaces = discover.furnaces(cfg),
        hotSink = hotSink,
        aeSink = aeSink,
        monitor = monitor,
        monitorName = monitorName,
    }
end

function discover.printSummary(net)
    net = net or {}
    local f = net.furnaces or {}
    local b = net.buffers or {}
    print(("ebf: %d pair(s) (NL+NR each), %d recipe buffer(s), hot=%s, ae=%s, mon=%s"):format(
        #f,
        #b,
        tostring(net.hotSink),
        tostring(net.aeSink),
        tostring(net.monitorName)
    ))
    local showF = math.min(#f, 10)
    for i = 1, showF do
        local p = f[i]
        print(("  %s hatch=%d bus=%s out=%s"):format(
            tostring(p.label or p.id),
            p.index,
            tostring(p.inputBus),
            tostring(p.outputBus)
        ))
    end
    if #f > showF then
        print(("  ... +%d more pairs"):format(#f - showF))
    end
end

discover._prefixedIndex = prefixedIndex
discover._isInventory = isInventory

return discover
