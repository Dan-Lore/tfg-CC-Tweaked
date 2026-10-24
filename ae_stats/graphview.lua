-- AE stats graphview: large-monitor chart PC.
-- Receives focus_set from display; pulls history from sampler.
--
-- Bundle:  python tools/bundle_project.py ae_stats graphview
-- Deploy:  dist/graphview.lua + graphview.cfg + labels.cfg

package.path = package.path
    .. ";/shared/?.lua;shared/?.lua;/ae_stats/?.lua;ae_stats/?.lua"

local util = require("util")
local protocol = require("protocol")
local history = require("history")
local graph = require("graph")
local config_common = require("config_common")
local labels = require("labels")

local function defaults()
    return {
        monitor = "right",
        modem = "top",
        text_scale = "auto",
        host_id = nil,
        window = "30m",
        step = "5m",
        interp = "i1",
        refresh_interval = 5,
    }
end

local function loadConfig()
    local cfg = defaults()
    local lines, path, ok = config_common.loadLines(nil, "graphview.cfg")
    if not ok then
        return cfg, path, false
    end
    for n = 1, #lines do
        local key, val = config_common.splitLine(lines[n])
        if key == "monitor" then
            cfg.monitor = val
        elseif key == "modem" then
            cfg.modem = val
        elseif key == "text_scale" or key == "monitor_scale" then
            cfg.text_scale = config_common.parseScale(val)
        elseif key == "host_id" then
            cfg.host_id = tonumber(val)
        elseif key == "window" then
            cfg.window = val
        elseif key == "step" then
            cfg.step = val
        elseif key == "interp" then
            cfg.interp = val
        elseif key == "refresh_interval" or key == "auto_refresh" then
            cfg.refresh_interval = tonumber(val) or cfg.refresh_interval
        elseif key then
            error(("graphview.cfg line %s: unknown key %q"):format(tostring(n), key))
        end
    end
    return cfg, path, true
end

local cfg = loadConfig()
labels.load()

local monName = cfg.monitor
local mon = assert(peripheral.wrap(monName), "No monitor on " .. monName)
if peripheral.getName then
    local ok, n = pcall(peripheral.getName, mon)
    if ok and n then
        monName = n
    end
end

-- Graphs need max resolution: auto => 0.5 (many cells, thin line).
local function applyScale()
    local chosen = 0.5
    if cfg.text_scale ~= "auto" then
        chosen = cfg.text_scale
    end
    mon.setTextScale(chosen)
    return chosen, mon.getSize()
end

local textScale, W, H = applyScale()
local localHist = history.new({ retain = 2.5 * 3600 })

local state = {
    sampler = cfg.host_id, -- pinned once set; do not hop between samplers
    samplerPinned = cfg.host_id ~= nil,
    status = "Waiting for focus...",
    selected = nil,
    amount = 0,
    displayName = nil,
    window = cfg.window,
    step = cfg.step,
    interp = cfg.interp,
    viewMin = nil, -- smoothed Y axis
    viewMax = nil,
}

local buttons = {}
local pendingTouches = {}

local function fill(x, y, w, h, color)
    mon.setBackgroundColor(color)
    for row = y, y + h - 1 do
        mon.setCursorPos(x, row)
        mon.write((" "):rep(w))
    end
end

local function writeAt(x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    if bg then
        mon.setBackgroundColor(bg)
    end
    if fg then
        mon.setTextColor(fg)
    end
    mon.write(tostring(text))
end

local function addButton(id, x, y, w, h, label, fg, bg)
    buttons[#buttons + 1] = {
        id = id,
        x = x,
        y = y,
        w = w,
        h = h,
        label = label,
        fg = fg or colors.white,
        bg = bg or colors.gray,
    }
end

local function hitButton(x, y)
    for i = #buttons, 1, -1 do
        local b = buttons[i]
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
            return b
        end
    end
    return nil
end

local function isOurMonitor(name)
    if not name then
        return false
    end
    if name == cfg.monitor or name == monName then
        return true
    end
    local p = peripheral.wrap(name)
    return p ~= nil and p == mon
end

local function openModem()
    if not peripheral.isPresent(cfg.modem) then
        error("No modem on " .. tostring(cfg.modem))
    end
    rednet.open(cfg.modem)
    rednet.host(protocol.NAME, protocol.GRAPH_HOST)
end

local function resolveSampler()
    if state.sampler then
        return state.sampler
    end
    local id = rednet.lookup(protocol.NAME, protocol.HOST)
    if id then
        state.sampler = id
        state.samplerPinned = true
        print("Pinned sampler #" .. tostring(id))
    end
    return state.sampler
end

local function noteSampler(id)
    if not id then
        return
    end
    if not state.sampler then
        state.sampler = id
        state.samplerPinned = true
        print("Pinned sampler #" .. tostring(id))
    end
    -- once pinned, ignore other sampler hellos (prevents dual-history flicker)
end

local function ensureStepValid()
    state.step = graph.clampStep(state.window, state.step)
end

local function cycleList(list, curId)
    local idx = 1
    for i = 1, #list do
        if list[i].id == curId then
            idx = i
            break
        end
    end
    idx = idx % #list + 1
    return list[idx].id
end

local function req(msg, wantKind, timeout)
    local host = resolveSampler()
    if not host then
        state.status = "No sampler (lookup)"
        return nil
    end
    protocol.send(host, msg)
    local deadline = os.clock() + (timeout or 3)
    while os.clock() < deadline do
        local left = math.max(0.05, deadline - os.clock())
        local timer = os.startTimer(left)
        local ev, a, b, c = os.pullEvent()
        if ev == "timer" and a == timer then
            -- continue
        elseif ev == "rednet_message" and c == protocol.NAME then
            local m = protocol.decode(b)
            if m then
                if a == host and m.kind == wantKind then
                    return m
                elseif m.kind == "hello" and m.role == "sampler" then
                    noteSampler(a)
                elseif m.kind == "focus_set" then
                    state._pendingFocus = m
                end
            end
        elseif ev == "monitor_touch" and isOurMonitor(a) then
            pendingTouches[#pendingTouches + 1] = { x = b, y = c }
        elseif ev == "monitor_resize" and isOurMonitor(a) then
            textScale, W, H = applyScale()
        end
    end
    state.status = "Timeout: " .. tostring(wantKind)
    return nil
end

local function requestHistory()
    if not state.selected then
        return
    end
    ensureStepValid()
    local win = graph.findWindow(state.window)
    local since = (os.epoch("utc") / 1000) - win.sec
    local res = req({
        kind = "history_req",
        item = state.selected,
        since = since,
    }, "history_res", 5)
    if state._pendingFocus then
        local f = state._pendingFocus
        state._pendingFocus = nil
        state.selected = f.item or state.selected
        if f.window then
            state.window = f.window
        end
        if f.step then
            state.step = f.step
        end
        if f.interp then
            state.interp = f.interp
        end
    end
    if res then
        local pts = res.points or {}
        if #pts > 0 then
            localHist:merge(state.selected, pts)
        end
        if res.amount ~= nil then
            state.amount = res.amount
            localHist:add(state.selected, res.amount)
        end
        local n = #(localHist:get(state.selected) or {})
        state.status = string.format("%d pts", n)
    end
end

local function applyFocus(msg)
    if not msg or not msg.item then
        return
    end
    if state.selected ~= msg.item then
        state.viewMin, state.viewMax = nil, nil
    end
    state.selected = msg.item
    if msg.window then
        state.window = msg.window
    end
    if msg.step then
        state.step = msg.step
    end
    if msg.interp then
        state.interp = msg.interp
    end
    if msg.displayName then
        state.displayName = msg.displayName
    end
    ensureStepValid()
    requestHistory()
end

local AXIS_SMOOTH = 0.35 -- EMA toward new ymin/ymax (less flicker)
local function smoothAxis(ymin, ymax)
    if not state.viewMin then
        state.viewMin, state.viewMax = ymin, ymax
        return ymin, ymax
    end
    state.viewMin = state.viewMin * (1 - AXIS_SMOOTH) + ymin * AXIS_SMOOTH
    state.viewMax = state.viewMax * (1 - AXIS_SMOOTH) + ymax * AXIS_SMOOTH
    -- expand immediately if live tip is outside (never clip "now")
    if state.amount ~= nil then
        if state.amount < state.viewMin then
            state.viewMin = state.amount
        end
        if state.amount > state.viewMax then
            state.viewMax = state.amount
        end
    end
    if state.viewMax <= state.viewMin then
        state.viewMax = state.viewMin + 1
    end
    return state.viewMin, state.viewMax
end

local function drawButtons()
    for i = 1, #buttons do
        local b = buttons[i]
        if b.label and b.label ~= "" then
            fill(b.x, b.y, b.w, b.h, b.bg)
            local label = b.label
            if #label > b.w then
                label = label:sub(1, b.w)
            end
            local lx = b.x + math.floor((b.w - #label) / 2)
            local ly = b.y + math.floor((b.h - 1) / 2)
            writeAt(lx, ly, label, b.fg, b.bg)
        end
    end
end

local function draw()
    buttons = {}
    ensureStepValid()
    textScale, W, H = applyScale()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    if not state.selected then
        fill(1, 1, W, 1, colors.gray)
        writeAt(1, 1, " AE GRAPH ", colors.white, colors.gray)
        writeAt(1, 3, "Select a resource on the list PC", colors.yellow, colors.black)
        writeAt(1, 4, "(tap row / graph button)", colors.lightGray, colors.black)
        return
    end

    local kind, name = config_common.parseTrackId(state.selected)
    local isFluid = kind == "fluid"
    local shown = labels.resolve(name, state.displayName or name)
    local win = graph.findWindow(state.window)
    local step = graph.findStep(state.step)
    local nowT = os.epoch("utc") / 1000
    local pts = localHist:get(state.selected, nowT - win.sec)
    if #pts == 0 and state.amount ~= nil then
        pts = { { t = nowT, amount = state.amount } }
    end
    local nPts = #pts

    -- Header: title + now (no duplicate technical id)
    fill(1, 1, W, 1, colors.gray)
    local head = (" %s %s "):format(isFluid and "F" or "I", shown)
    writeAt(1, 1, head:sub(1, W), colors.white, colors.gray)
    local meta = ("%d pts  %s"):format(nPts, state.window)
    if #meta < W then
        writeAt(W - #meta + 1, 1, meta, colors.lightGray, colors.gray)
    end

    writeAt(1, 2, (" now %s"):format(graph.fmtAmount(state.amount, isFluid)), colors.lime, colors.black)

    -- ensure live amount is in the series used for the chart
    if state.amount ~= nil then
        localHist:add(state.selected, state.amount, nowT)
        pts = localHist:get(state.selected, nowT - win.sec)
    end
    local buckets = graph.bucket(pts, win.sec, step.sec, nowT)
    local chartY = 3
    local chartH = math.max(5, H - 5)
    local chartW = W
    local gutter = math.min(12, math.max(8, math.floor(chartW * 0.18)))
    local plotW = math.max(4, chartW - gutter)
    local ys, ymin, ymax = graph.resample(buckets, plotW, state.interp)
    -- resample already pads; include live tip then smooth axis across frames
    if state.amount ~= nil then
        ymin = math.min(ymin, state.amount)
        ymax = math.max(ymax, state.amount)
        if #ys > 0 then
            ys[#ys] = state.amount
        end
    end
    if ymax <= ymin then
        ymax = ymin + 1
    end
    ymin, ymax = smoothAxis(ymin, ymax)
    graph.draw(mon, 1, chartY, chartW, chartH, ys, ymin, ymax, state.interp, isFluid)

    local by = H - 2
    addButton("win", 1, by, 8, 2, "w:" .. state.window, colors.white, colors.gray)
    addButton("step", 10, by, 8, 2, "s:" .. state.step, colors.white, colors.gray)
    addButton("interp", 19, by, 8, 2, "i:" .. state.interp, colors.white, colors.gray)
    addButton("reload", math.max(1, W - 8), by, 8, 2, "reload", colors.white, colors.gray)
    drawButtons()
end

local function onTouch(x, y)
    local b = hitButton(x, y)
    if not b then
        state.status = ("miss %d,%d"):format(x, y)
        draw()
        return
    end
    local id = b.id
    if id == "reload" then
        requestHistory()
    elseif id == "win" then
        state.window = cycleList(graph.WINDOWS, state.window)
        ensureStepValid()
        requestHistory()
    elseif id == "step" then
        state.step = cycleList(graph.stepsForWindow(state.window), state.step)
    elseif id == "interp" then
        state.interp = cycleList(graph.INTERPS, state.interp)
    end
    draw()
end

local function drainPendingTouches()
    while #pendingTouches > 0 do
        local t = table.remove(pendingTouches, 1)
        onTouch(t.x, t.y)
    end
end

local function main()
    openModem()
    resolveSampler()
    draw()
    print(("AE graphview on %s scale=%.1f %dx%d"):format(monName, textScale, W, H))
    print("Host: " .. protocol.GRAPH_HOST)

    local refreshSec = tonumber(cfg.refresh_interval) or 5
    if refreshSec < 0 then
        refreshSec = 0
    end
    local redrawTimer = os.startTimer(math.max(0.5, refreshSec > 0 and refreshSec or 2))

    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "monitor_touch" and isOurMonitor(a) then
            onTouch(b, c)
        elseif ev == "monitor_resize" and isOurMonitor(a) then
            textScale, W, H = applyScale()
            draw()
        elseif ev == "timer" and a == redrawTimer then
            if not state.sampler then
                resolveSampler()
            end
            if refreshSec > 0 and state.selected then
                requestHistory()
                drainPendingTouches()
            end
            draw()
            redrawTimer = os.startTimer(math.max(0.5, refreshSec > 0 and refreshSec or 2))
        elseif ev == "rednet_message" and c == protocol.NAME then
            local msg = protocol.decode(b)
            if msg and msg.kind == "focus_set" then
                applyFocus(msg)
                drainPendingTouches()
                draw()
            elseif msg and msg.kind == "hello" and msg.role == "sampler" then
                noteSampler(a)
            end
        elseif ev == "key" and a == keys.q then
            break
        end
    end
end

main()
