-- TFC/Firmalife food helpers for craft (tag fallbacks + spoil).
-- Registers into shared/transfer on require so craft stock/push skip rotten food.

local transfer = require("transfer")

local food = {}

local function isRawMeatName(name)
    if type(name) ~= "string" or name:find("/cooked_", 1, true) then
        return false
    end
    local leaf = name:match("([^/]+)$") or ""
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
    if type(name) ~= "string" then
        return false
    end
    local rawName = name:gsub("/cooked_", "/", 1)
    if rawName == name then
        return false
    end
    return isRawMeatName(rawName)
end

food.isRawMeatName = isRawMeatName
food.isCookedMeatName = isCookedMeatName

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

function food.isFoodItem(name)
    if type(name) ~= "string" then
        return false
    end
    return name:sub(1, 9) == "tfc:food/"
        or name:sub(1, 9) == "tfg:food/"
        or name:sub(1, 15) == "firmalife:food/"
        or name:sub(1, 16) == "firmalife:spice/"
        or name:find(":food/", 1, true) ~= nil
end

function food.isSpoiled(detail)
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
        local f = detail.food
        if f.rotten == true or f.spoiled == true then
            return true
        end
        decay = tonumber(f.decay)
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

--- Wire food checks into a transfer module (defaults to shared transfer).
function food.register(t)
    t = t or transfer
    if t.setSpoilCheck then
        t.setSpoilCheck(food.isSpoiled)
    end
    if t.setFoodItemCheck then
        t.setFoodItemCheck(food.isFoodItem)
    end
    if t.registerTagFallback then
        for tag, fn in pairs(TAG_FALLBACKS) do
            t.registerTagFallback(tag, fn)
        end
    end
    return t
end

food.register(transfer)

return food
