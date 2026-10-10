-- AE stats sampler: ME bridge + wireless rednet.
-- Continuously records ALL AE items/fluids so graphs have history
-- before the first time you open a resource on the display.
--
-- Bundle:  python tools/bundle_project.py ae_stats sampler
-- Deploy:  dist/sampler.lua + sampler.cfg on the ME computer
--          (meBridge bottom, wireless modem top)

package.path = package.path
    .. ";/shared/?.lua;shared/?.lua;/ae_stats/?.lua;ae_stats/?.lua"

local util = require("util")
local protocol = require("protocol")
local history = require("history")
local config_common = require("config_common")

local function defaults()
    return {
        modem = "top",
        bridge = "bottom",
        sample_interval = 30,
        retain_hours = 2.5,
        persist_every = 60,
        max_series = 512,
    }
end

local function loadConfig()
    local cfg = defaults()
    local lines, path, ok = config_common.loadLines(nil, "sampler.cfg")
    if not ok then
        return cfg, path, false
    end
    for n = 1, #lines do
        local key, val = config_common.splitLine(lines[n])
        if key == "modem" then
            cfg.modem = val
        elseif key == "bridge" then
            cfg.bridge = val
        elseif key == "sample_interval" then
            cfg.sample_interval = tonumber(val) or cfg.sample_interval
        elseif key == "retain_hours" then
            cfg.retain_hours = tonumber(val) or cfg.retain_hours
        elseif key == "persist_every" then
            cfg.persist_every = tonumber(val) or cfg.persist_every
        elseif key == "max_series" then
            cfg.max_series = tonumber(val) or cfg.max_series
        elseif key == "watchlist" or key == "track" then
            -- ignored: sampler records every AE resource
        elseif key then
            error(("sampler.cfg line %s: unknown key %q"):format(tostring(n), key))
        end
    end
    return cfg, path, true
end

local cfg = loadConfig()

local hist = history.new({
    retain = cfg.retain_hours * 3600,
    max_series = cfg.max_series,
    path = util.resolvePath(nil, "ae_stats_hist"),
})
hist:load()

local lastSampleCount = 0

local function openModem()
    local side = cfg.modem
    if not peripheral.isPresent(side) then
        error("No modem on " .. tostring(side))
    end
    rednet.open(side)
    rednet.host(protocol.NAME, protocol.HOST)
end

local function wrapBridge()
    local want = cfg.bridge
    if want and peripheral.isPresent(want) then
        local p = peripheral.wrap(want)
        if p and (p.getItem or p.listItems or p.listFluid) then
            return p, want
        end
    end
    for _, n in ipairs(peripheral.getNames()) do
        local t = peripheral.getType(n)
        if t == "meBridge" or t == "me_bridge" then
            return peripheral.wrap(n), n
        end
    end
    return nil, nil
end

local function callList(bridge, method)
    if not bridge or type(bridge[method]) ~= "function" then
        return nil
    end
    local ok, a = pcall(function()
        local r = bridge[method]()
        if type(r) == "table" then
            return r
        end
        r = bridge[method]({})
        if type(r) == "table" then
            return r
        end
        return nil
    end)
    if ok then
        return a
    end
    return nil
end

local function iterList(items, fn)
    if type(items) ~= "table" then
        return
    end
    if #items > 0 then
        for i = 1, #items do
            fn(items[i])
        end
    else
        for _, it in pairs(items) do
            fn(it)
        end
    end
end

local function fluidAmount(entry)
    if type(entry) ~= "table" then
        return 0
    end
    return tonumber(entry.amount or entry.count or entry.mb) or 0
end

local function getAmount(bridge, trackId)
    local kind, name = config_common.parseTrackId(trackId)
    if kind == "fluid" then
        if bridge and type(bridge.getFluid) == "function" then
            local ok, info = pcall(function()
                return bridge.getFluid({ name = name })
            end)
            if ok and type(info) == "table" then
                return fluidAmount(info)
            end
        end
        local fluids = callList(bridge, "listFluid") or callList(bridge, "listFluids")
        local found = 0
        iterList(fluids, function(it)
            if type(it) == "table" and tostring(it.name) == name then
                found = fluidAmount(it)
            end
        end)
        return found
    end

    if not bridge or type(bridge.getItem) ~= "function" then
        return 0
    end
    local ok, info = pcall(function()
        return bridge.getItem({ name = name })
    end)
    if not ok or type(info) ~= "table" then
        return 0
    end
    return tonumber(info.amount) or 0
end

local function listResources(bridge, q, offset, limit)
    offset = offset or 0
    limit = limit or 40
    q = util.trim(tostring(q or "")):lower()

    local filtered = {}

    local function push(kind, it)
        if type(it) ~= "table" or not it.name then
            return
        end
        local name = tostring(it.name)
        local disp = tostring(it.displayName or name)
        local amount = (kind == "fluid") and fluidAmount(it) or (tonumber(it.amount) or 0)
        if q == ""
            or name:lower():find(q, 1, true)
            or disp:lower():find(q, 1, true)
            or kind:find(q, 1, true)
        then
            filtered[#filtered + 1] = {
                name = name,
                displayName = disp,
                amount = amount,
                kind = kind,
                id = config_common.trackId(kind, name),
            }
        end
    end

    iterList(callList(bridge, "listItems"), function(it)
        push("item", it)
    end)
    iterList(callList(bridge, "listFluid") or callList(bridge, "listFluids"), function(it)
        push("fluid", it)
    end)

    -- fluids first by amount desc, then items by amount desc
    table.sort(filtered, function(a, b)
        if a.kind ~= b.kind then
            return a.kind == "fluid"
        end
        if a.amount ~= b.amount then
            return a.amount > b.amount
        end
        return a.name < b.name
    end)

    local total = #filtered
    local page = {}
    for i = offset + 1, math.min(total, offset + limit) do
        page[#page + 1] = filtered[i]
    end
    return page, total
end

--- Snapshot every AE item + fluid into history (no rednet flood).
local function sampleOnce(bridge)
    local t = os.epoch("utc") / 1000
    local n = 0

    local function record(kind, it)
        if type(it) ~= "table" or not it.name then
            return
        end
        local id = config_common.trackId(kind, it.name)
        local amount = (kind == "fluid") and fluidAmount(it) or (tonumber(it.amount) or 0)
        hist:add(id, amount, t)
        n = n + 1
        if n % 40 == 0 then
            sleep(0) -- yield so CC does not abort long loops
        end
    end

    iterList(callList(bridge, "listItems"), function(it)
        record("item", it)
    end)
    iterList(callList(bridge, "listFluid") or callList(bridge, "listFluids"), function(it)
        record("fluid", it)
    end)

    lastSampleCount = n
    return n
end

local function handleMessage(sender, msg, bridge)
    if msg.kind == "hello" then
        protocol.send(sender, {
            kind = "hello",
            role = "sampler",
            resources = lastSampleCount,
            series = #(hist:items()),
        })
    elseif msg.kind == "list_req" then
        local items, total = listResources(bridge, msg.q, msg.offset, msg.limit)
        protocol.send(sender, {
            kind = "list_res",
            items = items,
            total = total,
            q = msg.q or "",
        })
    elseif msg.kind == "track_set" or msg.kind == "track_get" then
        -- legacy no-op: everything is recorded continuously
        protocol.send(sender, { kind = "track_ack", items = {} })
    elseif msg.kind == "history_req" then
        local item = msg.item
        local since = msg.since
        -- always refresh with live AE amount so graph matches the list
        local live = bridge and getAmount(bridge, item) or nil
        if live ~= nil then
            hist:add(item, live)
        end
        local pts = hist:get(item, since)
        local latest = hist:latest(item)
        protocol.send(sender, {
            kind = "history_res",
            item = item,
            points = pts,
            amount = live or (latest and latest.amount) or 0,
            pointCount = #pts,
        })
    end
end

local function main()
    openModem()
    local bridge, bridgeName = wrapBridge()
    if not bridge then
        print("Waiting for meBridge...")
    else
        print("meBridge: " .. tostring(bridgeName))
    end
    print("Recording ALL AE items/fluids every " .. tostring(cfg.sample_interval) .. "s")
    print("Rednet host: " .. protocol.HOST)

    -- first full snapshot immediately
    if bridge then
        local ok, err = pcall(sampleOnce, bridge)
        if ok then
            print("Initial sample: " .. tostring(lastSampleCount) .. " resources")
            hist:save()
        else
            print("Initial sample err: " .. tostring(err))
        end
    end

    local sampleTimer = os.startTimer(1)
    local persistTimer = os.startTimer(cfg.persist_every)
    local lastSample = os.clock()

    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "timer" then
            if a == sampleTimer then
                if not bridge then
                    bridge, bridgeName = wrapBridge()
                end
                if bridge and (os.clock() - lastSample) >= cfg.sample_interval then
                    local ok, err = pcall(sampleOnce, bridge)
                    if not ok then
                        print("sample err: " .. tostring(err))
                        bridge = nil
                    else
                        print("sample " .. tostring(lastSampleCount) .. " @ " .. tostring(cfg.sample_interval) .. "s")
                    end
                    lastSample = os.clock()
                end
                sampleTimer = os.startTimer(1)
            elseif a == persistTimer then
                hist:save()
                persistTimer = os.startTimer(cfg.persist_every)
            end
        elseif ev == "rednet_message" and c == protocol.NAME then
            local msg = protocol.decode(b)
            if msg then
                if not bridge then
                    bridge, bridgeName = wrapBridge()
                end
                local ok, err = pcall(handleMessage, a, msg, bridge)
                if not ok then
                    print("msg err: " .. tostring(err))
                end
            end
        elseif ev == "peripheral" or ev == "peripheral_detach" then
            bridge, bridgeName = wrapBridge()
        end
    end
end

main()
