-- Find HV railgun input loaders and the redstone relay.

local discover = {}

local LOCAL_SIDES = {
    left = true,
    right = true,
    top = true,
    bottom = true,
    front = true,
    back = true,
}

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

local function isInventory(name)
    if not name or not peripheral.isPresent(name) then
        return false
    end
    local inv = peripheral.wrap(name)
    return inv and type(inv.list) == "function"
end

local function looksLikeRelay(name)
    if not name or not peripheral.isPresent(name) then
        return false
    end
    local p = peripheral.wrap(name)
    if not p or type(p.setOutput) ~= "function" then
        return false
    end
    local ok, ptype = pcall(peripheral.getType, name)
    if ok and ptype then
        local t = type(ptype) == "table" and table.concat(ptype, ",") or tostring(ptype)
        t = t:lower()
        if t:find("redstone_relay", 1, true) or t:find("redstonerelay", 1, true)
            or t:find("redstoneintegrator", 1, true) then
            return true
        end
    end
    -- Local side with setOutput is good enough (computer wraps adjacent relay).
    return LOCAL_SIDES[tostring(name):lower()] == true
end

function discover.loaders(cfg)
    cfg = cfg or {}
    local prefix = cfg.loader_prefix or "tfg:hv_railgun_item_loader_in"
    local list = {}
    local names = peripheral.getNames()
    for i = 1, #names do
        local name = names[i]
        local idx = prefixedIndex(name, prefix)
        if idx ~= nil and isInventory(name) then
            list[#list + 1] = name
        elseif tostring(name):lower():find(tostring(prefix):lower(), 1, true)
            and isInventory(name) then
            -- Prefix without trailing index still matches (wired modem rename).
            list[#list + 1] = name
        end
        if i % 8 == 0 then
            sleep(0)
        end
    end
    return sortByIndex(list)
end

function discover.relay(cfg)
    cfg = cfg or {}
    local preferred = cfg.relay or "top"
    if looksLikeRelay(preferred) then
        return preferred
    end
    if preferred and peripheral.isPresent(preferred) then
        print("railgun: " .. tostring(preferred) .. " present but no setOutput — trying find")
    end

    local names = peripheral.getNames()
    for i = 1, #names do
        local name = names[i]
        local ok, ptype = pcall(peripheral.getType, name)
        if ok and ptype then
            local t = type(ptype) == "table" and table.concat(ptype, ",") or tostring(ptype)
            if t:lower():find("redstone_relay", 1, true) and looksLikeRelay(name) then
                return name
            end
        end
    end

    for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
        if looksLikeRelay(side) then
            return side
        end
    end
    return nil
end

function discover.scan(cfg)
    return {
        loaders = discover.loaders(cfg),
        relay = discover.relay(cfg),
    }
end

function discover.printSummary(net, cfg)
    local loaders = net and net.loaders or {}
    local expected = cfg and tonumber(cfg.expected) or 0
    print(("railgun: %d loader(s), relay=%s"):format(
        #loaders,
        tostring(net and net.relay or "?")
    ))
    for i = 1, #loaders do
        print("  loader: " .. loaders[i])
    end
    if expected > 0 and #loaders ~= expected then
        print(("railgun: warn — expected %d loaders, found %d"):format(expected, #loaders))
    end
end

return discover
