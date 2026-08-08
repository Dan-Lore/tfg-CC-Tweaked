-- Craft UI: pick output item + amount on a right-side 3x2 monitor.
--
-- Setup (edit CONFIG for your world):
--   Monitor attached on the right (3 wide, 2 tall).
--   Storage / machine peripherals must be networked to this computer.

local craft = require("craft")

local CONFIG = {
    monitor = "right",
    -- Example: "tfg:ev_food_refrigerator_0"
    storage = nil,
    textScale = 0.5,
    waitTicks = 100,
    maxAmount = 64,
}

local mon = assert(peripheral.wrap(CONFIG.monitor), "No monitor on " .. CONFIG.monitor)
mon.setTextScale(CONFIG.textScale)

local W, H = mon.getSize()

local state = {
    catalog = {},
    selected = 1,
    scroll = 0,
    amount = 1,
    status = "Ready",
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

local function listWindow()
    -- Title row 1, status row 2, list, bottom controls (2 rows)
    local listTop = 3
    local listBottom = H - 2
    local listH = math.max(1, listBottom - listTop + 1)
    return listTop, listH
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

    local status = state.status
    if #status > W then
        status = status:sub(1, W)
    end
    writeAt(1, 2, status, colors.lightGray, colors.black)

    local listTop, listH = listWindow()
    ensureVisible()

    for row = 0, listH - 1 do
        local idx = state.scroll + row + 1
        local y = listTop + row
        local entry = state.catalog[idx]
        if entry then
            local selected = idx == state.selected
            local bg = selected and colors.blue or colors.black
            local fg = selected and colors.white or colors.lightGray
            fill(1, y, W, 1, bg)
            local mark = selected and ">" or " "
            local label = mark .. short(entry.id)
            if #label > W then
                label = label:sub(1, W)
            end
            writeAt(1, y, label, fg, bg)
            addButton("pick:" .. idx, 1, y, W, 1, label, fg, bg)
        else
            fill(1, y, W, 1, colors.black)
        end
    end

    -- Bottom controls: [-] [+] [GO]
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

local function resolveStorage()
    if CONFIG.storage and peripheral.isPresent(CONFIG.storage) then
        return CONFIG.storage
    end
    for _, name in ipairs(peripheral.getNames()) do
        if name:find("refrigerator", 1, true) or name:find("chest", 1, true) then
            return name
        end
    end
    return nil
end

local function doCraft()
    if state.busy then
        return
    end
    local entry = state.catalog[state.selected]
    if not entry then
        state.status = "Nothing selected"
        draw()
        return
    end

    local storage = resolveStorage()
    if not storage then
        state.status = "Set CONFIG.storage"
        draw()
        return
    end

    state.busy = true
    state.status = "Crafting " .. short(entry.id) .. "..."
    draw()

    local ok, detail = craft.request(entry.id, state.amount, {
        from = storage,
        out = storage,
        waitTicks = CONFIG.waitTicks,
    })

    state.busy = false
    if ok then
        state.status = "OK +" .. tostring(detail.produced)
    else
        local err = detail
        if type(detail) == "table" then
            if detail.error and detail.error.missing then
                err = "Need " .. short(detail.error.missing.name)
            elseif detail.error and detail.error.error then
                err = tostring(detail.error.error)
            else
                err = textutils.serialize(detail):sub(1, W)
            end
        end
        state.status = tostring(err)
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

    local storage = resolveStorage()
    if storage then
        state.status = "Store: " .. short(storage)
    else
        state.status = "Set CONFIG.storage"
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
