-- Item and fluid transfers between peripherals.
-- Item queries: exact id, or #namespace:path (item tag via getItemDetail / fallbacks).

local transfer = {}

-- Helpers defined BEFORE the table — CC Lua can resolve self-refs inside
-- `local T = { f = function() return T[...] end }` as a nil global.
local function isRawMeatName(name)
    if type(name) ~= "string" or name:find("/cooked_", 1, true) then
        return false
    end
    local leaf = name:match("([^/]+)$") or ""
    -- TFC/TFG meats + fish (incl. largemouth / smallmouth bass).
    local raw = {
        beef = true, pork = true, chicken = true, mutton = true, bear = true,
        horse_meat = true, venison = true, wolf = true, rabbit = true, hyena = true,
        duck = true, quail = true, chevon = true, camelidae = true, gran_feline = true,
        turtle = true, frog_legs = true, cod = true, salmon = true, tropical_fish = true,
        bluegill = true, largemouth_bass = true, smallmouth_bass = true, rainbow_trout = true,
        lake_trout = true, lake_whitefish = true, crappie = true, oysters = true,
        calamari = true,
    }
    if raw[leaf] then
        return true
    end
    if leaf:find("bass", 1, true) or leaf:find("trout", 1, true)
        or leaf:find("fish", 1, true) or leaf:find("meat", 1, true) then
        return name:sub(1, 9) == "tfc:food/" or name:sub(1, 9) == "tfg:food/"
            or name:sub(1, 15) == "firmalife:food/"
    end
    return false
end

local function isCookedMeatName(name)
    -- cooked_X ↔ same raw leaf (avoids cooked_egg / cooked_rice false positives).
    if type(name) ~= "string" then
        return false
    end
    local rawName = name:gsub("/cooked_", "/", 1)
    if rawName == name then
        return false
    end
    return isRawMeatName(rawName)
end

--- Known tag fallbacks when inventory getItemDetail().tags is unavailable.
local TAG_FALLBACKS = {
    ["tfc:foods/raw_meats"] = isRawMeatName,
    ["tfc:foods/cooked_meats"] = isCookedMeatName,
    ["firmalife:foods/cooked_meats_and_substitutes"] = isCookedMeatName,
    ["firmalife:foods/pizza_ingredients"] = function(name)
        if isCookedMeatName(name) then
            return true
        end
        return name == "tfg:food/magmango"
    end,
}

function transfer.isTag(query)
    return type(query) == "string" and query:sub(1, 1) == "#"
end

function transfer.tagId(query)
    if not transfer.isTag(query) then
        return query
    end
    return query:sub(2)
end

--- Does inventory item (name + optional tags list) match query (exact or #tag)?
function transfer.matches(itemName, tags, query)
    if not query or query == "" then
        return true
    end
    if not transfer.isTag(query) then
        return itemName == query
    end
    local tagId = transfer.tagId(query)
    if type(tags) == "table" then
        for i = 1, #tags do
            if tags[i] == tagId then
                return true
            end
        end
        -- Some CC builds return a set { ["tfc:foods/cooked_meats"] = true }
        if tags[tagId] then
            return true
        end
    end
    local fb = TAG_FALLBACKS[tagId]
    if fb then
        return fb(itemName) == true
    end
    return false
end

--- TFC/Firmalife food we should inspect for spoil before counting/pushing.
function transfer.isFoodItem(name)
    if type(name) ~= "string" then
        return false
    end
    return name:sub(1, 9) == "tfc:food/"
        or name:sub(1, 9) == "tfg:food/"
        or name:sub(1, 15) == "firmalife:food/"
        or name:sub(1, 16) == "firmalife:spice/"
        or name:find(":food/", 1, true) ~= nil
end

--- Best-effort spoil detect from getItemDetail (fields vary by pack/CC bridge).
function transfer.isSpoiled(detail)
    if type(detail) ~= "table" then
        return false
    end
    if detail.rotten == true or detail.spoiled == true or detail.decayed == true then
        return true
    end
    local decay = tonumber(detail.decay)
    if decay and decay >= 1 then
        return true
    end
    if type(detail.food) == "table" then
        local food = detail.food
        if food.rotten == true or food.spoiled == true then
            return true
        end
        decay = tonumber(food.decay)
        if decay and decay >= 1 then
            return true
        end
    end
    local dn = tostring(detail.displayName or detail.display_name or ""):lower()
    if dn:find("rotten", 1, true)
        or dn:find("spoiled", 1, true)
        or dn:find("испорч", 1, true)
        or dn:find("гниль", 1, true)
    then
        return true
    end
    return false
end

local function itemTagsFromDetail(detail)
    if not detail then
        return nil
    end
    if type(detail.tags) == "table" then
        return detail.tags
    end
    return nil
end

--- Detail only for #tags (match + spoil). Exact ids stay fast (list() only).
local function slotDetail(inv, slot, itemQuery)
    if not transfer.isTag(itemQuery) or not inv.getItemDetail then
        return nil
    end
    local ok, detail = pcall(inv.getItemDetail, slot)
    if ok then
        return detail
    end
    return nil
end

local function slotUsable(itemName, detail, itemQuery)
    if transfer.isSpoiled(detail) then
        return false
    end
    return transfer.matches(itemName, itemTagsFromDetail(detail), itemQuery)
end

local function transferItems(from, to, itemQuery, amount)
    if not from or not to or from == to then
        return 0
    end
    if not peripheral.isPresent(from) or not peripheral.isPresent(to) then
        return 0
    end
    local source = peripheral.wrap(from)
    if not source or not source.list or not source.pushItems then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    amount = tonumber(amount) or 0
    if not moveAll and amount <= 0 then
        return 0
    end

    local listed = source.list()
    if not listed then
        return 0
    end

    local n = 0
    for slot, item in pairs(listed) do
        if moveAll or movedTotal < amount then
            local detail = slotDetail(source, slot, itemQuery)
            if slotUsable(item.name, detail, itemQuery) then
                local limit = moveAll and item.count or (amount - movedTotal)
                local moved = source.pushItems(to, slot, limit) or 0
                movedTotal = movedTotal + moved
            end
        end
        n = n + 1
        if n % 8 == 0 then
            sleep(0)
        end
    end

    return movedTotal
end

setmetatable(transfer, {
    __call = function(_, from, to, itemName, amount)
        return transferItems(from, to, itemName, amount)
    end,
})

function transfer.countItem(invName, itemQuery)
    if not invName or not peripheral.isPresent(invName) then
        return 0
    end
    local inv = peripheral.wrap(invName)
    if not inv or not inv.list then
        return 0
    end
    local total = 0
    local listed = inv.list()
    if not listed then
        return 0
    end
    local n = 0
    for slot, item in pairs(listed) do
        local detail = slotDetail(inv, slot, itemQuery)
        if slotUsable(item.name, detail, itemQuery) then
            total = total + (item.count or 0)
        end
        n = n + 1
        if n % 8 == 0 then
            sleep(0)
        end
    end
    return total
end

function transfer.countFromMany(sources, itemQuery)
    local total = 0
    if not sources then
        return 0
    end
    for i = 1, #sources do
        total = total + transfer.countItem(sources[i], itemQuery)
    end
    return total
end

function transfer.fromMany(sources, to, itemQuery, amount)
    if not sources or not to then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    for i = 1, #sources do
        local from = sources[i]
        if from and from ~= to and peripheral.isPresent(from) then
            if moveAll then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, -1)
            elseif movedTotal < amount then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, amount - movedTotal)
            end
            if not moveAll and movedTotal >= amount then
                break
            end
        end
    end
    return movedTotal
end

function transfer.toMany(from, destinations, itemQuery, amount)
    if not from or not destinations then
        return 0
    end
    local movedTotal = 0
    local moveAll = amount == -1
    for i = 1, #destinations do
        local to = destinations[i]
        if to and to ~= from and peripheral.isPresent(to) then
            if moveAll then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, -1)
            elseif movedTotal < amount then
                movedTotal = movedTotal + transferItems(from, to, itemQuery, amount - movedTotal)
            end
            if not moveAll and movedTotal >= amount then
                break
            end
        end
    end
    return movedTotal
end

function transfer.countFluid(tankName, fluidName)
    local tank = peripheral.wrap(tankName)
    if not tank or type(tank.tanks) ~= "function" then
        return 0
    end
    local total = 0
    for _, t in pairs(tank.tanks()) do
        if t and t.name == fluidName then
            total = total + (t.amount or 0)
        end
    end
    return total
end

function transfer.fluid(from, to, fluidName, amount)
    if not from or not to then
        return 0
    end
    local source = peripheral.wrap(from)
    if not source or type(source.pushFluid) ~= "function" then
        return 0
    end
    amount = tonumber(amount) or 0
    if amount <= 0 then
        return 0
    end
    local moved = source.pushFluid(to, amount, fluidName)
    return tonumber(moved) or 0
end

return transfer
