-- Advanced Peripherals ME Bridge helpers (TFG AP ~0.7).

local ae_bridge = {}

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

function ae_bridge.wrap(want)
    if want and peripheral.isPresent(want) then
        local p = peripheral.wrap(want)
        if p and (p.getItem or p.listItems or p.exportItem or p.craftItem) then
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

--- Full getItem row: amount + isCraftable (AP reports craftable even at amount 0).
-- opts.allow_list: fall back to listItems (SLOW on large ME — avoid in hot paths).
function ae_bridge.getItemInfo(bridge, name, opts)
    if not bridge or not name then
        return { amount = 0, craftable = nil }
    end
    opts = opts or {}
    if type(bridge.getItem) == "function" then
        local ok, info = pcall(function()
            return bridge.getItem({ name = name })
        end)
        if ok and type(info) == "table" then
            local craftable = info.isCraftable
            if craftable == nil then
                craftable = info.craftable
            end
            if type(craftable) ~= "boolean" then
                craftable = nil
            end
            return {
                amount = tonumber(info.amount or info.count) or 0,
                craftable = craftable,
                fingerprint = info.fingerprint,
                displayName = info.displayName,
            }
        end
    end
    if opts.allow_list ~= true then
        return { amount = 0, craftable = nil }
    end
    local items = callList(bridge, "listItems")
    if type(items) ~= "table" then
        return { amount = 0, craftable = nil }
    end
    local found = 0
    local craftable = nil
    local function check(it)
        if type(it) == "table" and tostring(it.name) == name then
            found = tonumber(it.amount or it.count) or 0
            local c = it.isCraftable
            if c == nil then
                c = it.craftable
            end
            if type(c) == "boolean" then
                craftable = c
            end
        end
    end
    if #items > 0 then
        for i = 1, #items do
            check(items[i])
        end
    else
        for _, it in pairs(items) do
            check(it)
        end
    end
    return { amount = found, craftable = craftable }
end

function ae_bridge.getItemAmount(bridge, name)
    return ae_bridge.getItemInfo(bridge, name).amount
end

-- Cached listCraftableItems names (bridge object identity + TTL).
local craftableCacheBridge = nil
local craftableCacheAt = 0
local craftableCacheSet = {}
local CRAFTABLE_CACHE_S = 8

local function craftableSetContains(bridge, name)
    if craftableCacheBridge ~= bridge or (os.clock() - craftableCacheAt) > CRAFTABLE_CACHE_S then
        craftableCacheBridge = bridge
        craftableCacheAt = os.clock()
        craftableCacheSet = {}
        local list = callList(bridge, "listCraftableItems")
        if type(list) == "table" then
            local function add(it)
                if type(it) == "table" and type(it.name) == "string" then
                    craftableCacheSet[it.name] = true
                end
            end
            if #list > 0 then
                for i = 1, #list do
                    add(list[i])
                end
            else
                for _, it in pairs(list) do
                    add(it)
                end
            end
        end
    end
    return craftableCacheSet[name] == true
end

local function normalizeExport(ok, a, b)
    if not ok then
        return 0, tostring(a)
    end
    if type(a) == "number" then
        return a, b
    end
    if type(a) == "table" and (a.count or a.amount) then
        return tonumber(a.count or a.amount) or 0, b
    end
    if a == nil and type(b) == "string" then
        return 0, b
    end
    return tonumber(a) or 0, b
end

--- AP 0.7: exportItem(item, direction). Some builds take (direction, item).
function ae_bridge.exportItem(bridge, name, count, direction)
    if not bridge or type(bridge.exportItem) ~= "function" then
        return 0, "no exportItem"
    end
    count = math.max(0, math.floor(tonumber(count) or 0))
    if count < 1 then
        return 0, nil
    end
    local filter = { name = name, count = count }
    local ok, a, b = pcall(bridge.exportItem, filter, direction)
    local n, err = normalizeExport(ok, a, b)
    if n > 0 or (ok and err == nil) then
        return n, err
    end
    local ok2, a2, b2 = pcall(bridge.exportItem, direction, filter)
    return normalizeExport(ok2, a2, b2)
end

--- AP 0.7: export straight to a named inventory on the CC network (no adjacent chest).
function ae_bridge.exportItemToPeripheral(bridge, name, count, container)
    if not bridge or not container then
        return 0, "no target"
    end
    count = math.max(0, math.floor(tonumber(count) or 0))
    if count < 1 then
        return 0, nil
    end
    local filter = { name = name, count = count }
    if type(bridge.exportItemToPeripheral) == "function" then
        local ok, a, b = pcall(bridge.exportItemToPeripheral, filter, container)
        local n, err = normalizeExport(ok, a, b)
        if n > 0 or ok then
            return n, err
        end
    end
    -- Some AP builds accept a peripheral name as the exportItem "direction".
    if type(bridge.exportItem) == "function" then
        return ae_bridge.exportItem(bridge, name, count, container)
    end
    return 0, "no exportItemToPeripheral"
end

function ae_bridge.isItemCraftable(bridge, name, count)
    if not bridge or not name then
        return false, "no bridge"
    end
    count = math.max(1, math.floor(tonumber(count) or 1))

    -- 1) getItem.isCraftable — works for 0-stock patterned items (e.g. gold ingot).
    local info = ae_bridge.getItemInfo(bridge, name)
    if info.craftable == true then
        return true, "getItem"
    end

    -- 2) listCraftableItems cache (isItemCraftable alone is flaky on some AP builds).
    if craftableSetContains(bridge, name) then
        return true, "list"
    end

    -- 3) Direct API; prefer count=1 (large counts sometimes false-negative).
    if type(bridge.isItemCraftable) == "function" then
        local function probe(n)
            local filter = { name = name, count = n }
            local ok, res, err = pcall(bridge.isItemCraftable, filter)
            if not ok then
                return nil, tostring(res)
            end
            if res == true then
                return true, nil
            end
            if res == false then
                return false, err or "not craftable"
            end
            return res and true or false, err
        end
        local ok1, why1 = probe(1)
        if ok1 == true then
            return true, why1
        end
        if count > 1 then
            local okN, whyN = probe(count)
            if okN == true then
                return true, whyN
            end
            return false, whyN or why1 or "not craftable"
        end
        if ok1 == false then
            return false, why1 or "not craftable"
        end
    end

    -- Explicit false from getItem beats unverified attempt.
    if info.craftable == false then
        return false, "not craftable"
    end

    if type(bridge.craftItem) ~= "function" then
        return false, "no craftItem"
    end
    -- Probe without committing: if craftable check missing, allow attempt.
    return true, "unverified"
end

local function filterName(obj)
    if type(obj) ~= "table" then
        return nil
    end
    if type(obj.name) == "string" then
        return obj.name
    end
    if type(obj.item) == "table" and type(obj.item.name) == "string" then
        return obj.item.name
    end
    if type(obj.getItem) == "function" then
        local ok, item = pcall(obj.getItem)
        if ok and type(item) == "table" and type(item.name) == "string" then
            return item.name
        end
    end
    if type(obj.getRequestedItem) == "function" then
        local ok, item = pcall(obj.getRequestedItem)
        if ok and type(item) == "table" and type(item.name) == "string" then
            return item.name
        end
    end
    return nil
end

local function filterCount(obj)
    if type(obj) ~= "table" then
        return 0
    end
    local n = tonumber(obj.count or obj.amount or obj.total or obj.requested)
    if n then
        return math.max(0, math.floor(n))
    end
    if type(obj.item) == "table" then
        n = tonumber(obj.item.count or obj.item.amount)
        if n then
            return math.max(0, math.floor(n))
        end
    end
    if type(obj.getRequestedItem) == "function" then
        local ok, item = pcall(obj.getRequestedItem)
        if ok and type(item) == "table" then
            n = tonumber(item.count or item.amount)
            if n then
                return math.max(0, math.floor(n))
            end
        end
    end
    return 0
end

--- AP 0.7 isItemCrafting; 0.8+ isCrafting. True if any job for name is active.
function ae_bridge.isItemCrafting(bridge, name)
    if not bridge or not name then
        return false
    end
    local filter = { name = name }
    if type(bridge.isItemCrafting) == "function" then
        local ok, res = pcall(bridge.isItemCrafting, filter)
        if ok then
            return res == true
        end
    end
    if type(bridge.isCrafting) == "function" then
        local ok, res = pcall(bridge.isCrafting, filter)
        if ok then
            return res == true
        end
    end
    return false
end

--- Sum requested counts from active craft jobs for name.
-- Returns amount, known. known=false means a job exists but amount is opaque —
-- caller must not schedule another craft for that item.
function ae_bridge.craftingAmount(bridge, name)
    if not bridge or not name then
        return 0, true
    end
    local total = 0
    local sawJob = false
    local listed = false
    local tasks = callList(bridge, "getCraftingTasks")
    if type(tasks) ~= "table" then
        tasks = callList(bridge, "listCraftingJobs")
    end
    if type(tasks) == "table" then
        listed = true
        local function consider(job)
            if filterName(job) == name then
                sawJob = true
                local n = filterCount(job)
                if n > 0 then
                    total = total + n
                end
            end
        end
        if #tasks > 0 then
            for i = 1, #tasks do
                consider(tasks[i])
            end
        else
            for _, job in pairs(tasks) do
                consider(job)
            end
        end
    end
    if listed then
        if sawJob and total == 0 then
            return 0, false
        end
        return total, true
    end
    if ae_bridge.isItemCrafting(bridge, name) then
        return 0, false
    end
    return 0, true
end

local function ingestItemRow(into, it)
    if type(it) ~= "table" or type(it.name) ~= "string" then
        return
    end
    local craftable = it.isCraftable
    if craftable == nil then
        craftable = it.craftable
    end
    if type(craftable) ~= "boolean" then
        craftable = nil
    end
    into[it.name] = {
        amount = tonumber(it.amount or it.count) or 0,
        craftable = craftable,
    }
end

--- Watchlist ME pass: crafting tasks first, then per-id getItem.
-- opts.yield: sleep(0) between getItems so a parallel UI coroutine can paint mid-scan.
-- opts.base: previous snapshot to copy amounts for names not in opts.focus.
-- opts.focus: optional name list to refresh; others kept from base (fast partial).
-- Never calls listItems (full ME dump stalls large nets).
function ae_bridge.snapshot(bridge, names, opts)
    opts = opts or {}
    local t0 = os.clock()
    local amount, craftable, crafting, craftKnown = {}, {}, {}, {}
    names = names or {}
    local base = opts.base
    local focus = opts.focus
    local focusSet = nil
    if type(focus) == "table" and #focus > 0 then
        focusSet = {}
        for i = 1, #focus do
            focusSet[focus[i]] = true
        end
    end

    for i = 1, #names do
        local n = names[i]
        amount[n] = 0
        crafting[n] = 0
        craftKnown[n] = true
        if base and base.amount and (not focusSet or not focusSet[n]) then
            amount[n] = tonumber(base.amount[n]) or 0
            craftable[n] = base.craftable and base.craftable[n] or nil
        end
    end

    -- Crafting jobs first (one call) — UI can show Крафт before stock scan finishes.
    local tasks = callList(bridge, "getCraftingTasks")
    if type(tasks) ~= "table" then
        tasks = callList(bridge, "listCraftingJobs")
    end
    if type(tasks) == "table" then
        local saw = {}
        local function consider(job)
            local n = filterName(job)
            if not n then
                return
            end
            saw[n] = true
            local c = filterCount(job)
            if c > 0 then
                crafting[n] = (tonumber(crafting[n]) or 0) + c
            end
        end
        if #tasks > 0 then
            for i = 1, #tasks do
                consider(tasks[i])
            end
        else
            for _, job in pairs(tasks) do
                consider(job)
            end
        end
        for i = 1, #names do
            local n = names[i]
            if saw[n] and (tonumber(crafting[n]) or 0) < 1 then
                craftKnown[n] = false
            end
        end
    else
        for i = 1, #names do
            local n = names[i]
            if (not focusSet or focusSet[n]) and ae_bridge.isItemCrafting(bridge, n) then
                craftKnown[n] = false
            end
        end
    end

    local scan = focusSet and focus or names
    if not scan then
        scan = names
    end
    for i = 1, #scan do
        local n = scan[i]
        local info = ae_bridge.getItemInfo(bridge, n)
        amount[n] = info.amount
        craftable[n] = info.craftable
        if opts.yield and (i % 4 == 0) then
            sleep(0)
        end
    end

    return {
        amount = amount,
        craftable = craftable,
        crafting = crafting,
        craftKnown = craftKnown,
        ms = math.floor((os.clock() - t0) * 1000 + 0.5),
        mode = focusSet and "focus" or "getItem",
    }
end

--- Hard AE rejects that must not be retried this shot (no pattern / unknown id).
-- AP may return "not craftable", "ITEM_NOT_FOUND", or "NOT_CRAFTABLE".
function ae_bridge.isHardCraftFail(err)
    err = tostring(err or "")
    if err == "" then
        return false
    end
    local lower = err:lower()
    if lower == "not craftable" or lower == "item_not_found" or lower == "not_craftable" then
        return true
    end
    if lower:find("not_craftable", 1, true) or lower:find("not craftable", 1, true) then
        return true
    end
    if lower:find("item_not_found", 1, true) then
        return true
    end
    return false
end

--- Soft rejects: API looked OK but no CPU job (or nil). Retry with cooldown, then skip.
function ae_bridge.isSoftCraftFail(err)
    err = tostring(err or "")
    if err == "" then
        return false
    end
    if err == "API ok, no AE job" or err == "craft returned nil" then
        return true
    end
    local lower = err:lower()
    if lower:find("api ok, no ae job", 1, true) then
        return true
    end
    if lower:find("craft returned nil", 1, true) then
        return true
    end
    return false
end

--- Parse AP craftItem return. Nil alone is NOT success (was a false-positive that
-- showed «заказ AE» with крафт=0 while no CPU job existed).
local function interpretCraftReturn(a, b)
    if a == false then
        return false, b or "craft failed"
    end
    if a == nil then
        if type(b) == "string" and b ~= "" then
            return false, b
        end
        return false, "craft returned nil"
    end
    if a == true then
        return true, nil
    end
    -- 0.8+ may return a job table; some builds return a positive count.
    if type(a) == "table" then
        return true, nil
    end
    if type(a) == "number" and a > 0 then
        return true, nil
    end
    return false, tostring(b or a or "craft failed")
end

--- True if AE already has an active job for name (opaque or counted).
function ae_bridge.hasCraftJob(bridge, name)
    if not bridge or not name then
        return false
    end
    if ae_bridge.isItemCrafting(bridge, name) then
        return true
    end
    local amt, known = ae_bridge.craftingAmount(bridge, name)
    if (tonumber(amt) or 0) > 0 then
        return true
    end
    if known == false then
        return true
    end
    return false
end

--- Request craft. Returns ok, errMessage, scheduledCount.
-- Schedules smaller chunks first (multi-step AE trees often reject huge first requests).
-- After a positive API return, verifies a craft job actually appeared.
function ae_bridge.craftItem(bridge, name, count)
    if not bridge or type(bridge.craftItem) ~= "function" then
        return false, "no craftItem", 0
    end
    count = math.max(1, math.floor(tonumber(count) or 1))

    local function once(n)
        local filter = { name = name, count = n }
        local ok, a, b = pcall(bridge.craftItem, filter)
        if not ok then
            return false, tostring(a)
        end
        return interpretCraftReturn(a, b)
    end

    -- Prefer the full ask (AE handles 1000+ fine); fall back to 256/64/16/1 if needed.
    local raw = { count, 256, 64, 16, 1 }
    local seen, tryOrder = {}, {}
    for i = 1, #raw do
        local n = raw[i]
        if n and n >= 1 and n <= count and not seen[n] then
            seen[n] = true
            tryOrder[#tryOrder + 1] = n
        end
    end

    local err = "craft failed"
    for i = 1, #tryOrder do
        local n = tryOrder[i]
        local ok, why = once(n)
        if ok then
            if ae_bridge.hasCraftJob(bridge, name) then
                return true, nil, n
            end
            sleep(0)
            if ae_bridge.hasCraftJob(bridge, name) then
                return true, nil, n
            end
            -- Ghost success: smaller counts will not create a job either — stop here.
            return false, "API ok, no AE job", 0
        else
            err = why or err
            -- Hard reject — no point trying smaller sizes.
            if ae_bridge.isHardCraftFail(why) then
                return false, err, 0
            end
        end
        sleep(0) -- let UI / aeWatch run between attempts
    end
    return false, err, 0
end

return ae_bridge
