-- Craft UI: pick output item + amount on a monitor.
-- Inventory / monitor settings come from storage.cfg (no hard-coded fridge).

local craft = require("craft")
local storage = require("storage")

local store = storage.load()

local CONFIG = {
    monitor = store.get("monitor", "right"),
    textScale = store.getNumber("text_scale", 0.5),
    waitTicks = store.getNumber("wait_ticks", 100),
    growPulse = store.getNumber("grow_pulse", 3),
    growWaitTimeout = store.getNumber("grow_wait_timeout", 600),
    maxAmount = store.getNumber("max_amount", 64),
}

local mon = assert(peripheral.wrap(CONFIG.monitor), "No monitor on " .. CONFIG.monitor)
mon.setTextScale(CONFIG.textScale)

local W, H = mon.getSize()

local state = {
    catalog = {},
    selected = 1,
    scroll = 0,
    amount = 1,
    storageLabel = "",
    status = "Ready",
    statusKind = "info", -- info | ok | error | busy
    busy = false,
}

local buttons = {}

local function short(id)
    return id:match("([^/]+)$") or id
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function fill(x, y, w, h, color)
    mon.setBackgroundColor(color)
    for row = y, y + h - 1 do
        mon.setCursorPos(x, row)
        mon.write((" "):rep(w))
    end
end

local function writeAt(x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.write(text)
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
    for i = 1, #buttons do
        local b = buttons[i]
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
            return b
        end
    end
    return nil
end

local function statusLines()
    if state.statusKind == "error" then
        return 2
    end
    return 1
end

local function listWindow()
    local listTop = 3 + statusLines()
    local listBottom = H - 2
    local listH = math.max(1, listBottom - listTop + 1)
    return listTop, listH
end

local function setStatus(text, kind)
    state.status = tostring(text or "")
    state.statusKind = kind or "info"
end

local function formatError(detail)
    local function prettyName(name)
        if not name then
            return "?"
        end
        name = name:gsub("^#", "")
        return short(name)
    end

    local function fromMissing(missing)
        if not missing or not missing.name then
            return nil
        end
        local name = prettyName(missing.name)
        if missing.fluid then
            if missing.error == "no_fluid_source" then
                return "NO TANK " .. name
            end
            local count = missing.count
            if count and count > 0 then
                return "NEED " .. name .. " " .. tostring(count) .. "mb"
            end
            return "NEED " .. name
        end
        local count = missing.count
        if count and count > 1 then
            return "NEED " .. name .. " x" .. tostring(count)
        end
        return "NEED " .. name
    end

    if type(detail) ~= "table" then
        return tostring(detail)
    end

    local err = detail.error or detail
    for _ = 1, 4 do
        if type(err) ~= "table" then
            break
        end
        if err.error == "no_machine" then
            return "NO MACHINE " .. prettyName(err.missing and err.missing.name or err.item or "?")
        end
        if err.error == "grow_failed" then
            return "GROW FAIL " .. prettyName(err.missing and err.missing.name or "?")
        end
        if err.error == "grow_timeout" then
            return "GROW WAIT " .. prettyName(err.missing and err.missing.name or "?")
        end
        if err.error == "craft_no_output" then
            return "NO OUT " .. prettyName(err.missing and err.missing.name or "?")
        end
        if err.error == "cycle" then
            return "CYCLE " .. prettyName(err.missing and err.missing.name or "?")
        end
        -- Prefer fluid failures (often the real blocker) over mid-chain items.
        if type(err.missing_all) == "table" then
            for i = 1, #err.missing_all do
                if err.missing_all[i].fluid then
                    local msg = fromMissing(err.missing_all[i])
                    if msg then
                        return msg
                    end
                end
            end
            if err.missing_all[1] then
                local msg = fromMissing(err.missing_all[1])
                if msg then
                    local extra = #err.missing_all - 1
                    if extra > 0 then
                        return msg .. " +" .. tostring(extra)
                    end
                    return msg
                end
            end
        end
        local msg = fromMissing(err.missing)
        if msg then
            return msg
        end
        if type(err.error) == "string" and not err.missing then
            return err.error
        end
        err = err.error
    end

    return "CRAFT FAIL"
end

local function ensureVisible()
    local _, listH = listWindow()
    if state.selected < state.scroll + 1 then
        state.scroll = state.selected - 1
    elseif state.selected > state.scroll + listH then
        state.scroll = state.selected - listH
    end
    state.scroll = clamp(state.scroll, 0, math.max(0, #state.catalog - listH))
end

local function draw()
    buttons = {}
    mon.setBackgroundColor(colors.black)
    mon.clear()

    writeAt(1, 1, "CRAFT", colors.yellow, colors.black)
    local amtText = "x" .. tostring(state.amount)
    writeAt(W - #amtText + 1, 1, amtText, colors.white, colors.black)

    local storeLine = state.storageLabel
    if #storeLine > W then
        storeLine = storeLine:sub(1, W)
    end
    fill(1, 2, W, 1, colors.gray)
    writeAt(1, 2, storeLine, colors.white, colors.gray)

    local lines = statusLines()
    local status = state.status or ""
    local fg, bg = colors.lightGray, colors.black
    if state.statusKind == "error" then
        fg, bg = colors.white, colors.red
    elseif state.statusKind == "ok" then
        fg, bg = colors.black, colors.lime
    elseif state.statusKind == "busy" then
        fg, bg = colors.black, colors.yellow
    end

    local statusY = 3
    fill(1, statusY, W, lines, bg)
    if lines == 1 then
        if #status > W then
            status = status:sub(1, W)
        end
        writeAt(1, statusY, status, fg, bg)
    else
        local line1, line2 = status, ""
        if #status > W then
            line1 = status:sub(1, W)
            line2 = status:sub(W + 1)
            if #line2 > W then
                line2 = line2:sub(1, W)
            end
        end
        writeAt(1, statusY, line1, fg, bg)
        writeAt(1, statusY + 1, line2, fg, bg)
    end

    local listTop, listH = listWindow()
    ensureVisible()

    for row = 0, listH - 1 do
        local idx = state.scroll + row + 1
        local y = listTop + row
        local entry = state.catalog[idx]
        if entry then
            local selected = idx == state.selected
            local rowBg = selected and colors.blue or colors.black
            local rowFg = selected and colors.white or colors.lightGray
            fill(1, y, W, 1, rowBg)
            local mark = selected and ">" or " "
            local label = mark .. short(entry.id)
            if #label > W then
                label = label:sub(1, W)
            end
            writeAt(1, y, label, rowFg, rowBg)
            addButton("pick:" .. idx, 1, y, W, 1, label, rowFg, rowBg)
        else
            fill(1, y, W, 1, colors.black)
        end
    end

    local y = H - 1
    local btnW = math.max(3, math.floor(W / 3))
    local gap = W - btnW * 3
    local xMinus = 1
    local xPlus = 1 + btnW + math.floor(gap / 2)
    local xGo = W - btnW + 1

    fill(xMinus, y, btnW, 2, colors.red)
    writeAt(xMinus + math.floor((btnW - 1) / 2), y, "-", colors.white, colors.red)
    addButton("minus", xMinus, y, btnW, 2, "-", colors.white, colors.red)

    fill(xPlus, y, btnW, 2, colors.green)
    writeAt(xPlus + math.floor((btnW - 1) / 2), y, "+", colors.white, colors.green)
    addButton("plus", xPlus, y, btnW, 2, "+", colors.white, colors.green)

    fill(xGo, y, btnW, 2, colors.orange)
    local goLabel = state.busy and ".." or "GO"
    writeAt(xGo + math.floor((btnW - #goLabel) / 2), y, goLabel, colors.black, colors.orange)
    addButton("craft", xGo, y, btnW, 2, goLabel, colors.black, colors.orange)
end

local function doCraft()
    if state.busy then
        return
    end
    local entry = state.catalog[state.selected]
    if not entry then
        setStatus("Nothing selected", "error")
        draw()
        return
    end

    local mainInv = store.main()
    if not mainInv or not peripheral.isPresent(mainInv) then
        setStatus("main missing in storage.cfg", "error")
        draw()
        return
    end

    state.busy = true
    setStatus("Crafting " .. short(entry.id) .. "...", "busy")
    draw()

    local ok, detail = craft.request(entry.id, state.amount, {
        store = store,
        waitTicks = CONFIG.waitTicks,
        growPulse = CONFIG.growPulse,
        growWaitTimeout = CONFIG.growWaitTimeout,
    })

    state.busy = false
    if ok then
        setStatus("OK +" .. tostring(detail.produced), "ok")
    else
        setStatus(formatError(detail), "error")
    end
    draw()
end

local function onTouch(x, y)
    if state.busy then
        return
    end

    local btn = hitButton(x, y)
    if not btn then
        return
    end

    if btn.id:sub(1, 5) == "pick:" then
        state.selected = tonumber(btn.id:sub(6))
        draw()
        return
    end

    if btn.id == "minus" then
        state.amount = clamp(state.amount - 1, 1, CONFIG.maxAmount)
        draw()
        return
    end

    if btn.id == "plus" then
        state.amount = clamp(state.amount + 1, 1, CONFIG.maxAmount)
        draw()
        return
    end

    if btn.id == "craft" then
        doCraft()
    end
end

local function main()
    state.catalog = craft.catalog(craft.load())
    if #state.catalog == 0 then
        mon.setBackgroundColor(colors.black)
        mon.clear()
        writeAt(1, 1, "No recipes", colors.red, colors.black)
        return
    end

    local mainInv = store.main()
    if mainInv and peripheral.isPresent(mainInv) then
        state.storageLabel = "Store: " .. short(mainInv)
        setStatus("Ready", "info")
    else
        state.storageLabel = "Store: NONE"
        setStatus("main missing in storage.cfg", "error")
    end

    draw()

    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "monitor_touch" and a == CONFIG.monitor then
            onTouch(b, c)
        elseif ev == "monitor_resize" and a == CONFIG.monitor then
            W, H = mon.getSize()
            draw()
        elseif ev == "key" and a == keys.q then
            break
        end
    end
end

main()
