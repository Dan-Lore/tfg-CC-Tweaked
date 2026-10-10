-- AE stats display: resource list on power computer (right monitor).
-- Sends focus_set to graphview PC; does not draw local charts.
--
-- Bundle:  python tools/bundle_project.py ae_stats display
-- Deploy:  dist/display.lua + display.cfg + labels.cfg
-- Tip: keep this tab focused in multishell so monitor_touch is delivered.

package.path = package.path
    .. ";/shared/?.lua;shared/?.lua;/ae_stats/?.lua;ae_stats/?.lua"

local util = require("util")
local protocol = require("protocol")
local graph = require("graph")
local config_common = require("config_common")
local labels = require("labels")

local function defaults()
    return {
        monitor = "right",
        modem = "top",
        text_scale = "auto",
        host_id = nil,
        graph_id = nil,
        refresh_interval = 5,
    }
end

local function loadConfig()
    local cfg = defaults()
    local lines, path, ok = config_common.loadLines(nil, "display.cfg")
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
        elseif key == "graph_id" then
            cfg.graph_id = tonumber(val)
        elseif key == "refresh_interval" or key == "auto_refresh" then
            cfg.refresh_interval = tonumber(val) or cfg.refresh_interval
        elseif key == "window" or key == "step" or key == "interp" then
            -- ignored on list PC (graphview owns chart settings)
        elseif key then
            error(("display.cfg line %s: unknown key %q"):format(tostring(n), key))
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

local NEED_W, NEED_H = 36, 14

local function applyScale()
    local chosen = 0.5
    if cfg.text_scale == "auto" then
        for scale = 5, 0.5, -0.5 do
            mon.setTextScale(scale)
            local w, h = mon.getSize()
            if w >= NEED_W and h >= NEED_H then
                chosen = scale
                break
            end
        end
    else
        chosen = cfg.text_scale
    end
    mon.setTextScale(chosen)
    return chosen, mon.getSize()
end

local textScale, W, H = applyScale()

local state = {
    host = cfg.host_id,
    graph = cfg.graph_id,
    status = "Looking up sampler...",
    filter = "",
    filterEdit = false,
    items = {},
    total = 0,
    scroll = 0,
    selected = nil,
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
end

local function resolveHost()
    if state.host then
        return state.host
    end
    local id = rednet.lookup(protocol.NAME, protocol.HOST)
    if id then
        state.host = id
    end
    return state.host
end

local function resolveGraph()
    if state.graph then
        return state.graph
    end
    local id = rednet.lookup(protocol.NAME, protocol.GRAPH_HOST)
    if id then
        state.graph = id
    end
    return state.graph
end

local function req(msg, wantKind, timeout)
    local host = resolveHost()
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
                    state.host = a
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

local function refreshList()
    local res = req({
        kind = "list_req",
        q = state.filter,
        offset = state.scroll,
        limit = math.max(5, H - 6),
    }, "list_res", 5)
    if res then
        state.items = res.items or {}
        state.total = res.total or 0
        state.status = ("AE %d/%d sc:%.1f"):format(#state.items, state.total, textScale)
    end
end

local function findSelectedItem()
    for i = 1, #state.items do
        local it = state.items[i]
        local id = it.id or config_common.trackId(it.kind or "item", it.name)
        if id == state.selected then
            return it
        end
    end
    return nil
end

local function sendFocus()
    if not state.selected then
        return
    end
    local gid = resolveGraph()
    if not gid then
        state.status = "No graph PC (lookup)"
        return
    end
    local it = findSelectedItem()
    local msg = {
        kind = "focus_set",
        item = state.selected,
        displayName = it and it.displayName or nil,
    }
    protocol.send(gid, msg)
    local kind, name = config_common.parseTrackId(state.selected)
    local shown = labels.resolve(name, it and it.displayName or name)
    state.status = "graph ← " .. shown
end

local function drawChrome()
    fill(1, 1, W, 1, colors.gray)
    writeAt(1, 1, " AE STATS ", colors.white, colors.gray)
    local right = state.status or ""
    if #right > W - 12 then
        right = right:sub(1, W - 12)
    end
    writeAt(math.max(12, W - #right + 1), 1, right, colors.lightGray, colors.gray)
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

local AMT_COL = 11

local function padLeft(s, width)
    s = tostring(s or "")
    if #s > width then
        return s:sub(1, width)
    end
    return string.rep(" ", width - #s) .. s
end

local function padRight(s, width)
    s = tostring(s or "")
    if #s > width then
        return s:sub(1, width)
    end
    return s .. string.rep(" ", width - #s)
end

local function formatListRow(it)
    local tag = (it.kind == "fluid") and "F" or "I"
    local name = labels.resolve(it.name, it.displayName)
    local amt = padLeft(graph.fmtAmount(it.amount, it.kind == "fluid"), AMT_COL)
    local line = (" %s %s %s"):format(tag, amt, name)
    if #line > W then
        line = line:sub(1, W)
    else
        line = padRight(line, W)
    end
    return line
end

local function draw()
    buttons = {}
    textScale, W, H = applyScale()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    drawChrome()

    local filterLine = state.filterEdit
        and ("> " .. state.filter .. "_")
        or ("Filter: " .. (state.filter ~= "" and state.filter or "(tap to type)"))
    fill(1, 2, W, 1, state.filterEdit and colors.blue or colors.black)
    writeAt(1, 2, filterLine:sub(1, W), colors.yellow, state.filterEdit and colors.blue or colors.black)
    addButton("filter", 1, 2, W, 1, "", colors.yellow, colors.black)

    local listTop = 3
    local listBot = H - 3
    local rows = math.max(1, listBot - listTop + 1)
    for i = 1, rows do
        local it = state.items[i]
        local y = listTop + i - 1
        if it then
            local id = it.id or config_common.trackId(it.kind or "item", it.name)
            local sel = state.selected == id
            local bg = sel and colors.blue or colors.black
            local fg = sel and colors.white or colors.lightGray
            if it.kind == "fluid" and not sel then
                fg = colors.cyan
            end
            fill(1, y, W, 1, bg)
            writeAt(1, y, formatListRow(it), fg, bg)
            addButton("pick:" .. id, 1, y, W, 1, "", fg, bg)
        end
    end

    local by = H - 2
    addButton("up", 1, by, 5, 2, " ^ ", colors.white, colors.gray)
    addButton("dn", 7, by, 5, 2, " v ", colors.white, colors.gray)
    addButton("refresh", 13, by, 8, 2, "reload", colors.white, colors.gray)
    if state.selected then
        addButton("open", W - 10, by, 10, 2, " graph ", colors.black, colors.lime)
    end

    drawButtons()
    writeAt(1, H, ("scroll %d  total %d  tap rows"):format(state.scroll, state.total), colors.lightGray, colors.black)
end

local function pageSize()
    return math.max(3, H - 6)
end

local function onTouch(x, y)
    local b = hitButton(x, y)
    if not b then
        state.status = ("miss %d,%d"):format(x, y)
        draw()
        return
    end
    local id = b.id
    if id == "filter" then
        state.filterEdit = not state.filterEdit
        if state.filterEdit then
            state.status = "Type filter on PC, Enter=done"
        end
    elseif id == "up" then
        state.scroll = math.max(0, state.scroll - pageSize())
        refreshList()
    elseif id == "dn" then
        state.scroll = state.scroll + pageSize()
        if state.total > 0 then
            state.scroll = math.min(state.scroll, math.max(0, state.total - 1))
        end
        refreshList()
    elseif id == "refresh" or id == "reload" then
        refreshList()
    elseif id == "open" then
        sendFocus()
    elseif id:sub(1, 5) == "pick:" then
        local tid = id:sub(6)
        if state.selected == tid then
            sendFocus()
        else
            state.selected = tid
        end
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
    resolveHost()
    resolveGraph()
    if state.host then
        local hello = req({ kind = "hello", role = "display" }, "hello", 2)
        if hello then
            state.status = "sampler #" .. tostring(state.host)
        end
    end
    refreshList()
    drainPendingTouches()
    draw()
    print(("AE display on %s scale=%.1f size=%dx%d"):format(monName, textScale, W, H))
    print("Keep this tab focused for touch input.")

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
            if not state.host then
                resolveHost()
            end
            if not state.graph then
                resolveGraph()
            end
            if refreshSec > 0 and not state.filterEdit then
                refreshList()
                drainPendingTouches()
            end
            draw()
            redrawTimer = os.startTimer(math.max(0.5, refreshSec > 0 and refreshSec or 2))
        elseif ev == "rednet_message" and c == protocol.NAME then
            local msg = protocol.decode(b)
            if msg and msg.kind == "hello" and msg.role == "sampler" then
                state.host = a
                state.status = "sampler #" .. tostring(a)
            end
        elseif ev == "char" and state.filterEdit then
            state.filter = state.filter .. a
            draw()
        elseif ev == "key" and state.filterEdit then
            if a == keys.backspace then
                state.filter = state.filter:sub(1, math.max(0, #state.filter - 1))
                draw()
            elseif a == keys.enter then
                state.filterEdit = false
                state.scroll = 0
                refreshList()
                drainPendingTouches()
                draw()
            elseif a == keys.escape then
                state.filterEdit = false
                draw()
            end
        elseif ev == "key" and a == keys.q and not state.filterEdit then
            break
        end
    end
end

main()
